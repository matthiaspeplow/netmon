#!/usr/bin/env bash
# netmon.sh -- run the enabled diagnostic tests once as a single timestamped
# run. Raw per-test output lands in output/runs/<ts>/, and each test appends a
# row to its rolling time-series in output/metrics/<test>.csv.
#
# Usage:
#   ./netmon.sh                 # run all enabled tests
#   ./netmon.sh --only publicip # run just one (comma/space separated for more)
#   ./netmon.sh --config PATH   # use an alternate config file
#   ./netmon.sh --list          # list known tests and exit
_nm_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=lib/common.sh
. "$_nm_dir/lib/common.sh"

# Order matters: publicip early (cheap, reauth-critical); throughput last.
ALL_TESTS=(publicip ping mtu traceroute dns http ntp throughput)

usage() { sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; }

only=""
while [ $# -gt 0 ]; do
  case "$1" in
    --config) NM_CONFIG="$2"; export NM_CONFIG; shift 2 ;;
    --only)   only="$2"; shift 2 ;;
    --list)   printf '%s\n' "${ALL_TESTS[@]}"; exit 0 ;;
    -h|--help) usage; exit 0 ;;
    *) nm_err "unknown argument: $1"; usage; exit 2 ;;
  esac
done

nm_load_config
nm_init_run
# Children reuse this exact run identity (arrays can't be exported, so each
# child re-sources the config; timestamps/paths are inherited via env).
export NM_TS NM_TS_ISO NM_RUN_DIR NM_CONFIG NM_CONFIG_LOCAL

runlog="$NM_RUN_DIR/run.log"

# --- Capture the network context this run was collected under ----------------
iface="$(nm_default_iface)"; lip="$(nm_local_ip)"; gw="$(nm_default_gw)"
ssid="$(nm_wifi_ssid)"; kernel="$(uname -r 2>/dev/null)"
{
  echo "netmon run $NM_TS_ISO"
  echo "segment    : $NM_SEGMENT"
  echo "site       : $NM_SITE"
  echo "interface  : $iface"
  echo "local_ip   : $lip"
  echo "gateway    : $gw"
  echo "wifi_ssid  : $ssid"
  echo "os/kernel  : $NM_OS $kernel"
} >"$NM_RUN_DIR/context.txt"
ctx_header="$(nm_ctx_header),interface,local_ip,gateway,wifi_ssid,os,kernel"
ctx_row="$(nm_ctx_row),$(nm_csv_join "$iface" "$lip" "$gw" "$ssid" "$NM_OS" "$kernel")"
nm_csv_append context "$ctx_header" "$ctx_row"

# --- Select which tests to run -----------------------------------------------
declare -a run_list
if [ -n "$only" ]; then
  for t in ${only//,/ }; do run_list+=("$t"); done
else
  run_list=("${ALL_TESTS[@]}")
fi

nm_log "run $NM_TS (segment=$NM_SEGMENT) -> $NM_RUN_DIR"
rc_overall=0
for t in "${run_list[@]}"; do
  script="$_nm_dir/tests/$t.sh"
  if [ ! -f "$script" ]; then
    nm_warn "no such test: $t (see --list)"; continue
  fi
  nm_log "--- $t ---"
  bash "$script" 2>&1 | tee -a "$runlog"
  rc="${PIPESTATUS[0]}"
  [ "$rc" -ne 0 ] && { rc_overall=1; nm_warn "$t exited with status $rc"; }
done

nm_log "done. raw: $NM_RUN_DIR  metrics: $NM_METRICS_DIR"
exit "$rc_overall"
