#!/usr/bin/env bash
# tests/ping.sh -- latency, packet loss and jitter to each configured target.
# Emits one metrics row per target into output/metrics/ping.csv and stores raw
# ping output under the current run directory.
_nm_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=../lib/common.sh
. "$_nm_dir/../lib/common.sh"
nm_load_config
nm_init_run

[ "${PING_ENABLED:-1}" = "1" ] || { nm_log "ping: disabled"; exit 0; }
nm_require ping iputils-ping || exit 0

# Build the target list; optionally prepend the auto-detected default gateway.
declare -a targets gwflag
if [ "${PING_INCLUDE_GATEWAY:-1}" = "1" ]; then
  gw="$(nm_default_gw)"
  if [ -n "$gw" ]; then targets+=("$gw"); gwflag+=("1"); fi
fi
for t in "${PING_TARGETS[@]}"; do targets+=("$t"); gwflag+=("0"); done

if [ "${#targets[@]}" -eq 0 ]; then
  nm_warn "ping: no targets configured"
  exit 0
fi

header="$(nm_ctx_header),target,is_gateway,tx,rx,loss_pct,rtt_min_ms,rtt_avg_ms,rtt_max_ms,rtt_mdev_ms"

read -ra PING_BIND <<<"$(nm_bind_ping)"
nm_have_src_bind && nm_log "ping: bound to ${NM_SRC_IFACE:-$NM_SRC_IP}"

ping_once() {
  local target="$1" is_gw="$2"
  local raw out
  raw="$NM_RUN_DIR/ping_$(nm_slug "$target").txt"
  if nm_is_macos; then
    out="$(ping -n -c "$PING_COUNT" -i "$PING_INTERVAL" -t "$PING_DEADLINE" "${PING_BIND[@]}" "$target" 2>&1)"
  else
    out="$(ping -n -c "$PING_COUNT" -i "$PING_INTERVAL" -w "$PING_DEADLINE" "${PING_BIND[@]}" "$target" 2>&1)"
  fi
  printf '%s\n' "$out" >"$raw"

  # Stats line, commas stripped so parsing is uniform across Linux/macOS:
  #   "N packets transmitted, N (packets )?received, L% packet loss"
  # Track the nearest preceding integer so "packets" is never mistaken for a
  # count, then read tx / rx / loss in one pass.
  local statline tx rx loss
  statline="$(printf '%s\n' "$out" | tr -d ',' | grep 'packets transmitted' | head -n1)"
  read -r tx rx loss <<<"$(awk '{
    for (i=1;i<=NF;i++) {
      if ($i ~ /^[0-9]+$/) last=$i
      if ($i=="transmitted") t=last
      if ($i=="received")    r=last
      if ($i ~ /%$/) { l=$i; sub(/%/,"",l) }
    }
    printf "%s %s %s", t, r, l
  }' <<<"$statline")"

  # RTT summary: "rtt min/avg/max/mdev = a/b/c/d ms" (Linux) or
  #              "round-trip min/avg/max/stddev = a/b/c/d ms" (macOS).
  local stats mn av mx md
  stats="$(printf '%s\n' "$out" | sed -n 's#.* = \([0-9.]*\)/\([0-9.]*\)/\([0-9.]*\)/\([0-9.]*\) ms#\1 \2 \3 \4#p' | head -n1)"
  mn="$(awk '{print $1}' <<<"$stats")"
  av="$(awk '{print $2}' <<<"$stats")"
  mx="$(awk '{print $3}' <<<"$stats")"
  md="$(awk '{print $4}' <<<"$stats")"

  : "${tx:=$PING_COUNT}"; : "${rx:=0}"; : "${loss:=100}"

  local row
  row="$(nm_ctx_row),$(nm_csv_join "$target" "$is_gw" "$tx" "$rx" "$loss" "$mn" "$av" "$mx" "$md")"
  nm_csv_append ping "$header" "$row"
  nm_log "ping ${target} loss=${loss}% avg=${av:-NA}ms jitter=${md:-NA}ms"
}

for i in "${!targets[@]}"; do
  ping_once "${targets[$i]}" "${gwflag[$i]}"
done
