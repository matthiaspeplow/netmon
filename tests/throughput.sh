#!/usr/bin/env bash
# tests/throughput.sh -- bandwidth via speedtest-cli (internet) and/or iperf3
# (internal server). DISABLED by default: a speed test every few minutes
# saturates the link and skews the latency/loss you are trying to measure.
# Enable via THROUGHPUT_ENABLED=1 for occasional/scheduled runs.
_nm_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=../lib/common.sh
. "$_nm_dir/../lib/common.sh"
nm_load_config
nm_init_run

[ "${THROUGHPUT_ENABLED:-0}" = "1" ] || { nm_log "throughput: disabled (set THROUGHPUT_ENABLED=1 to enable)"; exit 0; }

raw="$NM_RUN_DIR/throughput.txt"
: >"$raw"
header="$(nm_ctx_header),method,server,download_mbps,upload_mbps,latency_ms"

record() {
  local method="$1" server="$2" down="$3" up="$4" lat="$5"
  local row
  row="$(nm_ctx_row),$(nm_csv_join "$method" "$server" "$down" "$up" "$lat")"
  nm_csv_append throughput "$header" "$row"
  nm_log "throughput ${method} down=${down:-NA} up=${up:-NA} Mbps lat=${lat:-NA}ms"
}

# --- Internet speed test (speedtest-cli --simple, no jq needed) ---------------
if [ "${THROUGHPUT_USE_SPEEDTEST:-1}" = "1" ] && nm_have speedtest-cli; then
  out="$(speedtest-cli --simple 2>&1)"
  printf 'speedtest-cli --simple\n%s\n\n' "$out" >>"$raw"
  lat="$(awk '/Ping/{print $2}' <<<"$out")"
  down="$(awk '/Download/{print $2}' <<<"$out")"
  up="$(awk '/Upload/{print $2}' <<<"$out")"
  record "speedtest" "ookla" "$down" "$up" "$lat"
elif [ "${THROUGHPUT_USE_SPEEDTEST:-1}" = "1" ]; then
  nm_warn "throughput: speedtest-cli not installed (apt install speedtest-cli)"
fi

# --- Internal iperf3 (client->server = upload; -R = download) -----------------
if [ -n "${IPERF_SERVER:-}" ]; then
  if nm_have iperf3; then
    up_bps=""; down_bps=""
    up_out="$(iperf3 -c "$IPERF_SERVER" -p "${IPERF_PORT:-5201}" --connect-timeout 5000 2>&1)"
    printf 'iperf3 upload\n%s\n\n' "$up_out" >>"$raw"
    down_out="$(iperf3 -c "$IPERF_SERVER" -p "${IPERF_PORT:-5201}" -R --connect-timeout 5000 2>&1)"
    printf 'iperf3 download\n%s\n\n' "$down_out" >>"$raw"
    # Parse the "sender/receiver" summary lines: "... X Mbits/sec ... sender".
    up_bps="$(awk '/sender/{for(i=1;i<=NF;i++) if($i ~ /bits\/sec/) print $(i-1) " " $i}' <<<"$up_out" | tail -n1)"
    down_bps="$(awk '/receiver/{for(i=1;i<=NF;i++) if($i ~ /bits\/sec/) print $(i-1) " " $i}' <<<"$down_out" | tail -n1)"
    to_mbps() { awk -v v="$1" -v u="$2" 'BEGIN{ if(u ~ /^G/) v*=1000; else if(u ~ /^K/) v/=1000; printf "%.1f", v }'; }
    up_m=""; down_m=""
    if [ -n "$up_bps" ];   then read -r _v _u <<<"$up_bps";   up_m="$(to_mbps "$_v" "$_u")"; fi
    if [ -n "$down_bps" ]; then read -r _v _u <<<"$down_bps"; down_m="$(to_mbps "$_v" "$_u")"; fi
    record "iperf3" "$IPERF_SERVER" "$down_m" "$up_m" ""
  else
    nm_warn "throughput: iperf3 not installed but IPERF_SERVER set (apt install iperf3)"
  fi
fi
