#!/usr/bin/env bash
# mtu-sweep.sh -- find the exact path MTU to ONE host and say whether a reduced
# MTU is PMTUD signaling (a router told us, usually fine) or a black hole
# (large packets silently dropped, no ICMP -- breaks large TLS/HTTPS). Ad-hoc
# companion to the scheduled tests/mtu.sh.
#
# Usage:
#   ./mtu-sweep.sh [options] <host>
#     -I, --interface N  bind to a source interface (default: config SOURCE_INTERFACE)
#     -S, --source-ip N  bind to a source IP        (default: config SOURCE_IP)
#     --min N   lower bound of the search (default 1200; 1280 for -6)
#     --max N   upper bound (default 1500)
#     -c N      DF probes per size (default 1)
#     -6        probe over IPv6
#     -v        verbose: show every probe
#     -h        help
_nm_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=lib/common.sh
. "$_nm_dir/lib/common.sh"
nm_load_config   # so config SOURCE_INTERFACE/SOURCE_IP apply as defaults

fam=4; MIN=""; MAX=1500; COUNT=1; VERBOSE=0; host=""
while [ $# -gt 0 ]; do
  case "$1" in
    -6) fam=6; shift ;;
    -v) VERBOSE=1; shift ;;
    --min) MIN="$2"; shift 2 ;;
    --max) MAX="$2"; shift 2 ;;
    -c) COUNT="$2"; shift 2 ;;
    -I|--interface) NM_SRC_IFACE="$2"; shift 2 ;;
    -S|--source-ip) NM_SRC_IP="$2"; shift 2 ;;
    -h|--help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) nm_err "unknown option: $1"; exit 2 ;;
    *) host="$1"; shift ;;
  esac
done

[ -n "$host" ] || { nm_err "usage: mtu-sweep.sh [options] <host>"; exit 2; }
nm_require ping iputils-ping || exit 1

# Header overhead and TCP overhead differ by family.
if [ "$fam" = 6 ]; then HDR=48; TCPOVH=60; : "${MIN:=1280}"; else HDR=28; TCPOVH=40; : "${MIN:=1200}"; fi

read -ra SWEEP_BIND <<<"$(nm_bind_ping)"

# One DF-bit probe of a given TOTAL size (payload = size - header); prints raw.
df_probe() {
  local payload=$(( $1 - HDR ))
  if nm_is_macos; then
    if [ "$fam" = 6 ]; then ping6 -c "$COUNT" -s "$payload" "${SWEEP_BIND[@]}" "$host" 2>&1
    else ping -n -c "$COUNT" -t 2 -D -s "$payload" "${SWEEP_BIND[@]}" "$host" 2>&1; fi
  else
    if [ "$fam" = 6 ]; then ping -6 -n -c "$COUNT" -W 2 -M "do" -s "$payload" "${SWEEP_BIND[@]}" "$host" 2>&1
    else ping -n -c "$COUNT" -W 2 -M "do" -s "$payload" "${SWEEP_BIND[@]}" "$host" 2>&1; fi
  fi
}
df_ok() { df_probe "$1" >/dev/null 2>&1; }
plain_ok() {
  if nm_is_macos; then
    if [ "$fam" = 6 ]; then ping6 -c 1 "${SWEEP_BIND[@]}" "$host" >/dev/null 2>&1; else ping -n -c 1 -t 2 "${SWEEP_BIND[@]}" "$host" >/dev/null 2>&1; fi
  else
    if [ "$fam" = 6 ]; then ping -6 -n -c 1 -W 2 "${SWEEP_BIND[@]}" "$host" >/dev/null 2>&1; else ping -n -c 1 -W 2 "${SWEEP_BIND[@]}" "$host" >/dev/null 2>&1; fi
  fi
}
is_num() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

nm_log "MTU sweep to $host (IPv$fam, range ${MIN}-${MAX}, header ${HDR}B)"
nm_have_src_bind && nm_log "  bound to ${NM_SRC_IFACE:-$NM_SRC_IP}"
plain_ok || nm_warn "$host does not answer ICMP echo -- DF probing relies on echo replies; results may be unreliable"

pmtu=""; fail_out=""
if df_ok "$MAX"; then
  pmtu="$MAX"
elif ! plain_ok; then
  nm_err "unreachable: cannot determine path MTU (no echo replies from $host)"; exit 1
elif ! df_ok "$MIN"; then
  pmtu="<$MIN"; fail_out="$(df_probe "$MIN")"
else
  lo="$MIN"; hi="$MAX"
  while [ $(( hi - lo )) -gt 1 ]; do
    mid=$(( (lo + hi) / 2 ))
    if df_ok "$mid"; then [ "$VERBOSE" = 1 ] && nm_log "  size $mid: OK";   lo="$mid"
    else                  [ "$VERBOSE" = 1 ] && nm_log "  size $mid: FAIL"; hi="$mid"; fi
  done
  pmtu="$lo"; fail_out="$(df_probe $(( pmtu + 1 )))"   # capture the smallest FAILING size
fi

# Classify why the next size up failed, from the boundary probe output:
#   signaled  = ICMP frag-needed / router-reported MTU  (PMTUD working; low risk)
#   local     = the probe's own interface MTU is the limit ("message too long")
#   blackhole = silent drop, no ICMP at all              (breaks large TLS/HTTPS)
kind="ok"; router_mtu=""
if [ "$pmtu" != "$MAX" ]; then
  router_mtu="$(printf '%s\n' "$fail_out" | sed -n 's/.*mtu *[=:] *\([0-9][0-9]*\).*/\1/p' | head -n1)"
  if   printf '%s' "$fail_out" | grep -qiE 'frag(mentation)? needed|mtu ?[=:] ?[0-9]'; then kind="signaled"
  elif printf '%s' "$fail_out" | grep -qi  'message too long';                         then kind="local"
  else kind="blackhole"; fi
fi

mss=""; is_num "$pmtu" && mss=$(( pmtu - TCPOVH ))

echo "-----------------------------------------------------------"
echo " host            : $host (IPv$fam)"
echo " path MTU        : $pmtu bytes"
if is_num "$pmtu"; then
  echo " max ICMP payload: $(( pmtu - HDR )) bytes"
  echo " implied TCP MSS : $mss bytes"
fi
case "$kind" in
  ok)
    echo " verdict         : OK -- $MAX passes with DF set (no restriction up to $MAX)" ;;
  signaled)
    echo " verdict         : reduced MTU, PMTUD IS signaling${router_mtu:+ (reported mtu=$router_mtu)}"
    echo "                   -> usually a tunnel/overlay; TCP self-corrects via MSS. Low risk." ;;
  local)
    echo " verdict         : limited by the LOCAL interface MTU (not a path black hole)"
    echo "                   -> the probe's own NIC/tunnel caps the size; check 'ip link' here." ;;
  blackhole)
    echo " verdict         : *** PMTU BLACK HOLE *** larger packets dropped with no ICMP feedback"
    echo "                   -> breaks large TLS/HTTPS. Mitigate on the gateway/path:"
    echo "                      - clamp TCP MSS${mss:+ to $mss} (iptables --clamp-mss-to-pmtu)"
    echo "                      - allow ICMP type 3 code 4 (fragmentation-needed)"
    echo "                      - or lower the path/tunnel MTU to match" ;;
esac
echo "-----------------------------------------------------------"
