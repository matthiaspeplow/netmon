#!/usr/bin/env bash
# tests/ntp.sh -- clock offset of this box versus a reference NTP server.
# A drifting clock can make JWTs / session cookies / TLS certs look expired,
# which some apps handle by forcing a re-login -- worth ruling in or out.
_nm_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=../lib/common.sh
. "$_nm_dir/../lib/common.sh"
nm_load_config
nm_init_run

[ "${NTP_ENABLED:-1}" = "1" ] || { nm_log "ntp: disabled"; exit 0; }

ref="${NTP_REFERENCE:-pool.ntp.org}"
raw="$NM_RUN_DIR/ntp.txt"
method=""; offset=""

if nm_have ntpdate; then
  method="ntpdate"
  out="$(ntpdate -q "$ref" 2>&1)"
  printf '%s\n' "$out" >"$raw"
  # "...offset -0.001234 sec" (take the last reported offset).
  offset="$(printf '%s\n' "$out" | sed -n 's/.*offset \(-\{0,1\}[0-9.]*\) sec.*/\1/p' | tail -n1)"
  [ -z "$offset" ] && offset="$(printf '%s\n' "$out" | awk '/offset/{for(i=1;i<=NF;i++) if($i=="offset"){print $(i+1); exit}}')"
elif nm_have sntp; then
  method="sntp"
  out="$(sntp "$ref" 2>&1)"
  printf '%s\n' "$out" >"$raw"
  # e.g. "... +0.001234 +/- 0.05 ..." -> take the leading signed offset.
  offset="$(printf '%s\n' "$out" | grep -Eo '[-+][0-9]+\.[0-9]+' | head -n1)"
elif nm_have chronyc; then
  method="chronyc"
  out="$(chronyc tracking 2>&1)"
  printf '%s\n' "$out" >"$raw"
  # "System time : 0.000012 seconds slow of NTP time" (slow => behind => negative).
  val="$(printf '%s\n' "$out" | sed -n 's/.*System time *: *\([0-9.]*\) seconds.*/\1/p')"
  if printf '%s' "$out" | grep -q 'slow of'; then offset="-$val"; else offset="$val"; fi
  ref="system(chronyd)"
else
  nm_warn "ntp: no offset tool found (apt install ntpdate, or use sntp/chronyc)"
  exit 0
fi

header="$(nm_ctx_header),reference,method,offset_s"
row="$(nm_ctx_row),$(nm_csv_join "$ref" "$method" "$offset")"
nm_csv_append ntp "$header" "$row"
nm_log "ntp ref=${ref} method=${method} offset=${offset:-NA}s"
