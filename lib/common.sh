# shellcheck shell=bash
# =============================================================================
# lib/common.sh -- shared helpers for the netmon toolkit.
#
# Sourced by netmon.sh, analyze.sh and every tests/*.sh. NOT meant to be run
# directly. We deliberately do NOT use `set -e`: network probes are expected to
# fail (unreachable hosts, dropped packets) and a single failure must never
# abort a whole collection run.
# =============================================================================

# --- Locate the repo root from this file's location (lib/common.sh -> ..) ----
if [ -n "${BASH_SOURCE[0]:-}" ]; then
  _nm_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
  _nm_lib_dir="$(cd "$(dirname "$0")" && pwd)"
fi
NM_ROOT="$(cd "$_nm_lib_dir/.." && pwd)"
export NM_ROOT

# --- Paths (overridable via environment) -------------------------------------
NM_CONFIG="${NM_CONFIG:-$NM_ROOT/config/netmon.conf}"
NM_CONFIG_LOCAL="${NM_CONFIG_LOCAL:-$NM_ROOT/config/netmon.local.conf}"
NM_OUTPUT_DIR="${NM_OUTPUT_DIR:-$NM_ROOT/output}"
NM_RUNS_DIR="$NM_OUTPUT_DIR/runs"
NM_METRICS_DIR="$NM_OUTPUT_DIR/metrics"
NM_STATE_DIR="$NM_OUTPUT_DIR/state"
export NM_CONFIG NM_CONFIG_LOCAL NM_OUTPUT_DIR NM_RUNS_DIR NM_METRICS_DIR NM_STATE_DIR

# --- OS detection -------------------------------------------------------------
NM_OS="$(uname -s 2>/dev/null || echo unknown)"
nm_is_linux() { [ "$NM_OS" = "Linux" ]; }
nm_is_macos() { [ "$NM_OS" = "Darwin" ]; }

# --- Timestamps & logging (logs go to stderr; stdout stays data-clean) -------
nm_ts_iso()     { date -u +%Y-%m-%dT%H:%M:%SZ; }
nm_ts_compact() { date -u +%Y%m%dT%H%M%SZ; }
nm_log()  { printf '%s [netmon] %s\n'        "$(nm_ts_iso)" "$*" >&2; }
nm_warn() { printf '%s [netmon][WARN] %s\n'  "$(nm_ts_iso)" "$*" >&2; }
nm_err()  { printf '%s [netmon][ERROR] %s\n' "$(nm_ts_iso)" "$*" >&2; }

# --- Tool availability --------------------------------------------------------
nm_have() { command -v "$1" >/dev/null 2>&1; }
# nm_require CMD [PACKAGE]: warn (don't abort) if a tool is missing.
nm_require() {
  if ! nm_have "$1"; then
    nm_warn "missing tool: $1${2:+ (apt install $2)} -- related checks will be skipped"
    return 1
  fi
  return 0
}

# --- Config loading -----------------------------------------------------------
nm_load_config() {
  if [ -f "$NM_CONFIG" ]; then
    # shellcheck disable=SC1090
    . "$NM_CONFIG"
  else
    nm_warn "config not found: $NM_CONFIG (using built-in defaults)"
  fi
  # Optional, git-ignored local override wins over the tracked config.
  if [ -f "$NM_CONFIG_LOCAL" ]; then
    # shellcheck disable=SC1090
    . "$NM_CONFIG_LOCAL"
  fi
  nm_apply_config_defaults
}

# Provide safe defaults so any script runs even without a config file present.
nm_apply_config_defaults() {
  : "${SEGMENT:=unknown}"
  : "${SITE:=}"
  : "${IPV6_ENABLED:=0}"

  : "${PING_ENABLED:=1}"; : "${PING_COUNT:=20}"; : "${PING_INTERVAL:=0.2}"
  : "${PING_DEADLINE:=15}"; : "${PING_INCLUDE_GATEWAY:=1}"
  nm_default_array PING_TARGETS "1.1.1.1" "8.8.8.8"

  : "${TRACE_ENABLED:=1}"; : "${TRACE_CYCLES:=3}"; : "${TRACE_MAX_HOPS:=30}"
  nm_default_array TRACE_TARGETS "1.1.1.1" "8.8.8.8"

  : "${MTU_ENABLED:=1}"; : "${MTU_MIN:=1200}"; : "${MTU_MAX:=1500}"
  nm_default_array MTU_TARGETS "1.1.1.1" "8.8.8.8"

  : "${DNS_ENABLED:=1}"; : "${DNS_TIMEOUT:=2}"
  nm_default_array DNS_RESOLVERS "system" "1.1.1.1" "8.8.8.8"
  nm_default_array DNS_NAMES "cloudflare.com"

  : "${PUBLICIP_ENABLED:=1}"; : "${PUBLICIP_TIMEOUT:=5}"
  : "${PUBLICIP_ASN_URL:=}"
  nm_default_array PUBLICIP_SERVICES \
    "https://api.ipify.org" "https://ifconfig.me/ip" \
    "https://icanhazip.com" "https://checkip.amazonaws.com"

  : "${HTTP_ENABLED:=1}"; : "${HTTP_TIMEOUT:=15}"
  : "${CAPTIVE_CHECK_URL:=http://connectivitycheck.gstatic.com/generate_204}"
  nm_default_array HTTP_TARGETS "https://www.cloudflare.com"

  : "${THROUGHPUT_ENABLED:=0}"
  : "${THROUGHPUT_USE_CURL:=1}"
  : "${CURL_SPEEDTEST_DOWN_URL:=https://speed.cloudflare.com/__down?bytes=}"
  : "${CURL_SPEEDTEST_UP_URL:=https://speed.cloudflare.com/__up}"
  : "${CURL_SPEEDTEST_BYTES:=25000000}"; : "${CURL_SPEEDTEST_MAXTIME:=30}"
  : "${THROUGHPUT_USE_SPEEDTEST:=0}"
  : "${IPERF_SERVER:=}"; : "${IPERF_PORT:=5201}"

  : "${NTP_ENABLED:=1}"; : "${NTP_REFERENCE:=pool.ntp.org}"
}

# nm_default_array NAME val1 val2 ...: define NAME as an array only if it is not
# already set (so config values are respected).
nm_default_array() {
  local name="$1"; shift
  if ! declare -p "$name" >/dev/null 2>&1; then
    # Assign all remaining args as array elements in one shot.
    eval "$name=(\"\$@\")"
  fi
}

# --- Run context / output layout ---------------------------------------------
# Establish a single run identity. Honors NM_TS/NM_RUN_DIR from the environment
# so child test scripts launched by netmon.sh share ONE run directory.
nm_init_run() {
  NM_TS="${NM_TS:-$(nm_ts_compact)}"
  NM_TS_ISO="${NM_TS_ISO:-$(nm_ts_iso)}"
  NM_RUN_DIR="${NM_RUN_DIR:-$NM_RUNS_DIR/$NM_TS}"
  NM_SEGMENT="${SEGMENT:-unknown}"
  NM_SITE="${SITE:-}"
  export NM_TS NM_TS_ISO NM_RUN_DIR NM_SEGMENT NM_SITE
  mkdir -p "$NM_RUN_DIR" "$NM_METRICS_DIR" "$NM_STATE_DIR" 2>/dev/null || true
}

# --- Network context helpers (Linux-first, degrade gracefully elsewhere) -----
nm_default_iface() {
  if nm_have ip; then
    ip route show default 2>/dev/null | awk '/default/{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'
  fi
}
nm_default_gw() {
  if nm_have ip; then
    ip route show default 2>/dev/null | awk '/default/{for(i=1;i<=NF;i++) if($i=="via"){print $(i+1); exit}}'
  elif nm_is_macos && nm_have route; then
    route -n get default 2>/dev/null | awk '/gateway:/{print $2; exit}'
  fi
}
nm_local_ip() {
  if nm_have ip; then
    ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}'
  elif nm_is_macos && nm_have ipconfig; then
    ipconfig getifaddr "$(nm_default_iface)" 2>/dev/null
  fi
}
nm_wifi_ssid() {
  if nm_have iwgetid; then
    iwgetid -r 2>/dev/null
  elif nm_have nmcli; then
    nmcli -t -f active,ssid dev wifi 2>/dev/null | awk -F: '/^yes/{print $2; exit}'
  fi
}

# --- Filename slug ------------------------------------------------------------
nm_slug() {
  printf '%s' "$1" | tr '/:@ ' '____' | tr -cd '[:alnum:]_.-'
}

# --- CSV helpers --------------------------------------------------------------
# Quote a single field if it contains a comma or double quote (RFC-4180-ish).
nm_csv_field() {
  local s="$1"
  case "$s" in
    *[,\"]*)
      s=${s//\"/\"\"}
      printf '"%s"' "$s"
      ;;
    *)
      printf '%s' "$s"
      ;;
  esac
}

# Join args into one CSV row with proper escaping.
nm_csv_join() {
  local out="" first=1 f
  for f in "$@"; do
    if [ "$first" -eq 1 ]; then first=0; else out+=","; fi
    out+="$(nm_csv_field "$f")"
  done
  printf '%s' "$out"
}

# Shared leading columns present on every metric row.
nm_ctx_header() { printf 'timestamp,segment,site'; }
nm_ctx_row()    { nm_csv_join "${NM_TS_ISO:-$(nm_ts_iso)}" "${NM_SEGMENT:-unknown}" "${NM_SITE:-}"; }

# nm_csv_append METRIC HEADER ROW: append ROW to output/metrics/METRIC.csv,
# writing HEADER first if the file is new. HEADER/ROW must be complete CSV lines
# (build ROW with nm_csv_join).
nm_csv_append() {
  local name="$1" header="$2" row="$3"
  local f="$NM_METRICS_DIR/$name.csv"
  mkdir -p "$NM_METRICS_DIR" 2>/dev/null || true
  if [ ! -f "$f" ]; then
    printf '%s\n' "$header" >"$f"
  fi
  printf '%s\n' "$row" >>"$f"
}

# --- URL parsing (best-effort, for http.sh) ----------------------------------
nm_url_scheme() { printf '%s' "$1" | sed -n 's,^\([a-zA-Z][a-zA-Z0-9+.-]*\)://.*,\1,p'; }
nm_url_hostport() {
  printf '%s' "$1" | sed -e 's,^[a-zA-Z][a-zA-Z0-9+.-]*://,,' -e 's,[/?#].*,,' -e 's,^[^@]*@,,'
}
nm_url_host() {
  local hp; hp="$(nm_url_hostport "$1")"
  case "$hp" in
    \[*\]*) hp="${hp#\[}"; printf '%s' "${hp%%\]*}" ;;   # [IPv6]
    *:*)    printf '%s' "${hp%%:*}" ;;
    *)      printf '%s' "$hp" ;;
  esac
}
nm_url_port() {
  local hp scheme; hp="$(nm_url_hostport "$1")"; scheme="$(nm_url_scheme "$1")"
  case "$hp" in
    \[*\]:*) printf '%s' "${hp##*\]:}" ;;
    \[*\])   [ "$scheme" = "https" ] && printf '443' || printf '80' ;;
    *:*)     printf '%s' "${hp##*:}" ;;
    *)       [ "$scheme" = "https" ] && printf '443' || printf '80' ;;
  esac
}

# --- Date -> epoch (for TLS cert expiry math) --------------------------------
nm_epoch_from_date() {
  local d="$1"
  if nm_is_macos; then
    # openssl prints e.g. "May  1 12:00:00 2027 GMT"; assume UTC.
    date -j -u -f "%b %e %H:%M:%S %Y" "${d% GMT}" +%s 2>/dev/null
  else
    date -u -d "$d" +%s 2>/dev/null
  fi
}
nm_now_epoch() { date -u +%s; }
