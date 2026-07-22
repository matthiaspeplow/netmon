#!/usr/bin/env bash
# tests/traceroute.sh -- capture the network path to each target and flag when
# the path changes between runs (route instability / failover / asymmetry).
# Prefers `mtr --report` (path + per-hop loss); falls back to `traceroute`.
_nm_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=../lib/common.sh
. "$_nm_dir/../lib/common.sh"
nm_load_config
nm_init_run

[ "${TRACE_ENABLED:-1}" = "1" ] || { nm_log "traceroute: disabled"; exit 0; }

tool=""
if nm_have mtr; then tool="mtr"
elif nm_have traceroute; then tool="traceroute"
else
  nm_warn "traceroute: neither mtr nor traceroute present (apt install mtr-tiny traceroute)"
  exit 0
fi

header="$(nm_ctx_header),target,tool,hop_count,dest_reached,path_changed,path_signature"

trace_one() {
  local target="$1"
  local slug raw sigfile out hops sig prev changed reached
  slug="$(nm_slug "$target")"
  raw="$NM_RUN_DIR/trace_${slug}.txt"
  sigfile="$NM_STATE_DIR/trace_${slug}.path"

  if [ "$tool" = "mtr" ]; then
    out="$(mtr -n --report --report-cycles="${TRACE_CYCLES:-3}" -m "${TRACE_MAX_HOPS:-30}" "$target" 2>&1)"
    hops="$(printf '%s\n' "$out" | awk '/\|--/{print $2}')"
  else
    out="$(traceroute -n -m "${TRACE_MAX_HOPS:-30}" "$target" 2>&1)"
    # Hop lines begin with the hop number; column 2 is the first IP (or '*').
    hops="$(printf '%s\n' "$out" | awk '/^[ ]*[0-9]+/{print $2}')"
  fi
  printf '%s\n' "$out" >"$raw"

  local hop_count
  hop_count="$(printf '%s\n' "$hops" | grep -c '[^[:space:]]')"
  sig="$(printf '%s' "$hops" | tr '\n' '>' | sed 's/>$//')"

  reached=0
  printf '%s\n' "$out" | grep -qF "$target" && reached=1

  changed=0
  if [ -f "$sigfile" ]; then
    prev="$(cat "$sigfile" 2>/dev/null)"
    if [ -n "$sig" ] && [ "$sig" != "$prev" ]; then changed=1; fi
  fi
  [ -n "$sig" ] && printf '%s' "$sig" >"$sigfile"

  local row
  row="$(nm_ctx_row),$(nm_csv_join "$target" "$tool" "$hop_count" "$reached" "$changed" "$sig")"
  nm_csv_append traceroute "$header" "$row"
  nm_log "traceroute ${target} hops=${hop_count} reached=${reached} changed=${changed}"
}

for t in "${TRACE_TARGETS[@]}"; do
  trace_one "$t"
done
