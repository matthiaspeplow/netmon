#!/usr/bin/env bash
# tests/mtu.sh -- Path MTU discovery via Don't-Fragment pings, with a heuristic
# for PMTU black holes (large packets silently dropped, no ICMP frag-needed).
# A reduced path MTU or a suspected black hole is a strong lead for HTTPS hangs
# and "some pages load, big ones stall" performance complaints.
_nm_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=../lib/common.sh
. "$_nm_dir/../lib/common.sh"
nm_load_config
nm_init_run

[ "${MTU_ENABLED:-1}" = "1" ] || { nm_log "mtu: disabled"; exit 0; }
nm_require ping iputils-ping || exit 0

MTU_MIN="${MTU_MIN:-1200}"
MTU_MAX="${MTU_MAX:-1500}"

read -ra MTU_BIND <<<"$(nm_bind_ping)"
nm_have_src_bind && nm_log "mtu: bound to ${NM_SRC_IFACE:-$NM_SRC_IP}"

# DF ping at a given total MTU size (payload = size - 28 bytes IP+ICMP header).
# Prints raw output; returns ping's exit status.
df_ping_out() {
  local target="$1" payload=$(( $2 - 28 ))
  if nm_is_macos; then
    ping -n -c1 -t2 -D -s "$payload" "${MTU_BIND[@]}" "$target" 2>&1
  else
    ping -n -c1 -W2 -M "do" -s "$payload" "${MTU_BIND[@]}" "$target" 2>&1
  fi
}
df_ok() { df_ping_out "$1" "$2" >/dev/null 2>&1; }
plain_ok() {
  if nm_is_macos; then ping -n -c1 -t2 "${MTU_BIND[@]}" "$1" >/dev/null 2>&1
  else ping -n -c1 -W2 "${MTU_BIND[@]}" "$1" >/dev/null 2>&1; fi
}

header="$(nm_ctx_header),target,reachable,path_mtu,pmtud_signaled,blackhole_suspected,note"

mtu_one() {
  local target="$1"
  local raw max_out reachable path_mtu frag note blackhole lo hi mid
  raw="$NM_RUN_DIR/mtu_$(nm_slug "$target").txt"

  max_out="$(df_ping_out "$target" "$MTU_MAX")"
  printf 'DF ping @ MTU=%s\n%s\n' "$MTU_MAX" "$max_out" >"$raw"

  # Did a router explicitly signal a smaller MTU (PMTUD working)?
  frag=0
  if printf '%s' "$max_out" | grep -qiE 'frag(mentation)? needed|message too long|mtu ?= ?[0-9]'; then
    frag=1
  fi

  blackhole=0
  if df_ok "$target" "$MTU_MAX"; then
    reachable=1; path_mtu="$MTU_MAX"; note="full-1500-ok"
  elif plain_ok "$target"; then
    reachable=1
    if ! df_ok "$target" "$MTU_MIN"; then
      # Reachable, small unfragmented pings work, but even MTU_MIN with DF fails.
      path_mtu="<${MTU_MIN}"; note="pmtu-below-min"
      [ "$frag" -eq 0 ] && blackhole=1
    else
      lo="$MTU_MIN"; hi="$MTU_MAX"
      while [ $(( hi - lo )) -gt 1 ]; do
        mid=$(( (lo + hi) / 2 ))
        if df_ok "$target" "$mid"; then lo="$mid"; else hi="$mid"; fi
      done
      path_mtu="$lo"; note="reduced-pmtu"
      # Large packets don't get through and no ICMP frag-needed was seen => black hole.
      [ "$frag" -eq 0 ] && blackhole=1
    fi
  else
    reachable=0; path_mtu="0"; note="unreachable"
  fi

  if nm_have tracepath; then
    { echo; echo "tracepath:"; tracepath -n "$target" 2>&1; } >>"$raw"
  fi

  local row
  row="$(nm_ctx_row),$(nm_csv_join "$target" "$reachable" "$path_mtu" "$frag" "$blackhole" "$note")"
  nm_csv_append mtu "$header" "$row"
  nm_log "mtu ${target} path_mtu=${path_mtu} pmtud_signaled=${frag} blackhole=${blackhole} (${note})"
}

for t in "${MTU_TARGETS[@]}"; do
  mtu_one "$t"
done
