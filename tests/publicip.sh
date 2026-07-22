#!/usr/bin/env bash
# tests/publicip.sh -- observe the egress public IP (v4/v6) from several
# independent services each run.
#
# This is the primary signal for the "forced reauthentication" complaint:
#   * changed=1     -> the egress IP changed since the last sample; web apps
#                      that bind a session to the source IP will log users out.
#   * disagreement=1-> services returned different v4 addresses in ONE sample,
#                      i.e. traffic is leaving via >1 egress (dual-WAN / NAT
#                      pool / load balancer) -- sessions will flap constantly.
#
# It is intentionally lightweight and safe to run on a high-frequency timer, so
# it does NOT create a per-run directory when invoked standalone.
_nm_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=../lib/common.sh
. "$_nm_dir/../lib/common.sh"
nm_load_config

# --- Lightweight init: reuse the parent run dir if present, else none --------
NM_TS_ISO="${NM_TS_ISO:-$(nm_ts_iso)}"
NM_SEGMENT="${SEGMENT:-unknown}"
NM_SITE="${SITE:-}"
export NM_TS_ISO NM_SEGMENT NM_SITE   # consumed by nm_ctx_row in common.sh
mkdir -p "$NM_METRICS_DIR" "$NM_STATE_DIR" 2>/dev/null || true
raw="${NM_RUN_DIR:+$NM_RUN_DIR/publicip.txt}"
[ -n "${NM_RUN_DIR:-}" ] && mkdir -p "$NM_RUN_DIR" 2>/dev/null || true
: "${raw:=$NM_STATE_DIR/publicip_last_raw.txt}"

[ "${PUBLICIP_ENABLED:-1}" = "1" ] || { nm_log "publicip: disabled"; exit 0; }
nm_require curl curl || exit 0

is_ipv4() { printf '%s' "$1" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; }
is_ipv6() { printf '%s' "$1" | grep -Eq '^[0-9A-Fa-f:]+:[0-9A-Fa-f:]*$'; }

: >"$raw"
declare -a v4seen
ok=0; total=0
for svc in "${PUBLICIP_SERVICES[@]}"; do
  total=$((total+1))
  resp="$(curl -4 -fsS --max-time "${PUBLICIP_TIMEOUT:-5}" "$svc" 2>/dev/null | tr -d '[:space:]')"
  printf '%s -> %s\n' "$svc" "$resp" >>"$raw"
  if is_ipv4 "$resp"; then
    ok=$((ok+1))
    v4seen+=("$resp")
  fi
done

# Distinct v4 addresses seen this sample.
distinct_v4="$(printf '%s\n' "${v4seen[@]}" | grep -v '^$' | sort -u)"
distinct_count="$(printf '%s\n' "$distinct_v4" | grep -c '[^[:space:]]')"
primary_v4="$(printf '%s\n' "$distinct_v4" | head -n1)"
disagreement=0; [ "${distinct_count:-0}" -gt 1 ] && disagreement=1

# IPv6 (best effort, single answer).
ipv6=""
if [ "${IPV6_ENABLED:-0}" = "1" ]; then
  for svc in "${PUBLICIP_SERVICES[@]}"; do
    resp="$(curl -6 -fsS --max-time "${PUBLICIP_TIMEOUT:-5}" "$svc" 2>/dev/null | tr -d '[:space:]')"
    if is_ipv6 "$resp"; then ipv6="$resp"; printf '%s -> %s (v6)\n' "$svc" "$resp" >>"$raw"; break; fi
  done
fi

# Change detection vs persisted state.
statefile="$NM_STATE_DIR/publicip_v4"
prev_v4=""; [ -f "$statefile" ] && prev_v4="$(cat "$statefile" 2>/dev/null)"
changed=0
if [ -n "$primary_v4" ] && [ -n "$prev_v4" ] && [ "$primary_v4" != "$prev_v4" ]; then
  changed=1
  printf '%s %s -> %s\n' "$NM_TS_ISO" "$prev_v4" "$primary_v4" >>"$NM_STATE_DIR/publicip_changes.log"
fi
[ -n "$primary_v4" ] && printf '%s' "$primary_v4" >"$statefile"

# Optional ASN/org enrichment (needs jq + a JSON endpoint).
asn=""; org=""
if [ -n "${PUBLICIP_ASN_URL:-}" ] && nm_have jq; then
  j="$(curl -fsS --max-time "${PUBLICIP_TIMEOUT:-5}" "$PUBLICIP_ASN_URL" 2>/dev/null)"
  if [ -n "$j" ]; then
    asn="$(printf '%s' "$j" | jq -r '.asn // empty' 2>/dev/null)"
    org="$(printf '%s' "$j" | jq -r '.asn_org // .org // empty' 2>/dev/null)"
  fi
fi

header="$(nm_ctx_header),ipv4,ipv6,distinct_v4_count,disagreement,changed,prev_ipv4,asn,org,services_ok,services_total"
row="$(nm_ctx_row),$(nm_csv_join "$primary_v4" "$ipv6" "$distinct_count" "$disagreement" "$changed" "$prev_v4" "$asn" "$org" "$ok" "$total")"
nm_csv_append publicip "$header" "$row"

if [ "$changed" = "1" ] || [ "$disagreement" = "1" ]; then
  nm_warn "publicip v4=${primary_v4:-NONE} changed=${changed} disagreement=${disagreement} (distinct=${distinct_count}) <-- reauth-relevant"
else
  nm_log "publicip v4=${primary_v4:-NONE} distinct=${distinct_count} changed=0"
fi
