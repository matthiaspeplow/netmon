#!/usr/bin/env bash
# tests/dns.sh -- resolution latency + answer consistency for each name across
# each resolver. Flags failures/timeouts and answers that change over time or
# differ between resolvers (split-horizon surprises, flaky internal DNS).
_nm_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=../lib/common.sh
. "$_nm_dir/../lib/common.sh"
nm_load_config
nm_init_run

[ "${DNS_ENABLED:-1}" = "1" ] || { nm_log "dns: disabled"; exit 0; }

have_dig=0
nm_have dig && have_dig=1
if [ "$have_dig" -eq 0 ]; then
  nm_warn "dns: dig not found (apt install bind9-dnsutils); falling back to getent (system resolver only, no timing)"
fi

header="$(nm_ctx_header),resolver,name,status,query_time_ms,answers,changed"
raw="$NM_RUN_DIR/dns.txt"
: >"$raw"

resolve_dig() {
  # $1=resolver ("system" or IP), $2=name. Echoes: status<TAB>qtime_ms<TAB>answers
  local resolver="$1" name="$2" full status qtime answers server=()
  [ "$resolver" != "system" ] && server=("@$resolver")
  full="$(dig +tries=1 +time="${DNS_TIMEOUT:-2}" "${server[@]}" "$name" A 2>&1)"
  printf '\n### %s @ %s\n%s\n' "$name" "$resolver" "$full" >>"$raw"
  status="$(printf '%s\n' "$full" | sed -n 's/.*status: \([A-Z]*\).*/\1/p' | head -n1)"
  qtime="$(printf '%s\n' "$full" | sed -n 's/.*Query time: \([0-9]*\) msec.*/\1/p' | head -n1)"
  answers="$(printf '%s\n' "$full" | awk '/[ \t]IN[ \t]+A[ \t]/{print $NF}' | sort | tr '\n' ' ' | sed 's/ *$//')"
  [ -z "$status" ] && status="TIMEOUT"
  printf '%s\t%s\t%s' "$status" "$qtime" "$answers"
}

resolve_getent() {
  local name="$1" answers
  answers="$(getent hosts "$name" 2>/dev/null | awk '{print $1}' | sort | tr '\n' ' ' | sed 's/ *$//')"
  if [ -n "$answers" ]; then printf 'NOERROR\t\t%s' "$answers"; else printf 'TIMEOUT\t\t'; fi
}

dns_one() {
  local resolver="$1" name="$2" res status qtime answers changed sigfile prev
  if [ "$have_dig" -eq 1 ]; then
    res="$(resolve_dig "$resolver" "$name")"
  else
    [ "$resolver" != "system" ] && return 0   # getent can't target a resolver
    res="$(resolve_getent "$name")"
  fi
  status="${res%%$'\t'*}"
  qtime="$(printf '%s' "$res" | cut -f2)"
  answers="$(printf '%s' "$res" | cut -f3-)"

  changed=0
  sigfile="$NM_STATE_DIR/dns_$(nm_slug "${resolver}_${name}").ans"
  if [ -f "$sigfile" ]; then
    prev="$(cat "$sigfile" 2>/dev/null)"
    if [ -n "$answers" ] && [ "$answers" != "$prev" ]; then changed=1; fi
  fi
  [ -n "$answers" ] && printf '%s' "$answers" >"$sigfile"

  local row
  row="$(nm_ctx_row),$(nm_csv_join "$resolver" "$name" "$status" "$qtime" "$answers" "$changed")"
  nm_csv_append dns "$header" "$row"
  nm_log "dns ${name} @ ${resolver} status=${status} time=${qtime:-NA}ms changed=${changed}"
}

for r in "${DNS_RESOLVERS[@]}"; do
  for n in "${DNS_NAMES[@]}"; do
    dns_one "$r" "$n"
  done
done
