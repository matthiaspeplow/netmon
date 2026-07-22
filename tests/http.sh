#!/usr/bin/env bash
# tests/http.sh -- per web-app request timing breakdown, HTTP status, TLS
# handshake time + certificate days-to-expiry, and a captive-portal /
# connectivity probe (relevant on Guest WiFi). Slow TLS/TTFB or non-2xx on the
# affected apps helps localize the reauth/performance complaints.
_nm_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=../lib/common.sh
. "$_nm_dir/../lib/common.sh"
nm_load_config
nm_init_run

[ "${HTTP_ENABLED:-1}" = "1" ] || { nm_log "http: disabled"; exit 0; }
nm_require curl curl || exit 0

raw="$NM_RUN_DIR/http.txt"
: >"$raw"

# curl writes these fields (seconds, with decimals) in a fixed order.
CURL_FMT='%{http_code} %{time_namelookup} %{time_connect} %{time_appconnect} %{time_starttransfer} %{time_total} %{num_redirects} %{ssl_verify_result} %{remote_ip}'

ms() { awk -v s="$1" 'BEGIN{ if(s=="") s=0; printf "%.0f", s*1000 }'; }

cert_days_left() {
  # $1=host $2=port -> integer days until the leaf cert expires (or empty).
  local host="$1" port="$2" enddate exp now
  nm_have openssl || return 0
  local tmo=(); nm_have timeout && tmo=(timeout 10)
  enddate="$(printf '' | "${tmo[@]}" openssl s_client -connect "${host}:${port}" -servername "$host" 2>/dev/null \
    | openssl x509 -noout -enddate 2>/dev/null | sed 's/notAfter=//')"
  [ -z "$enddate" ] && return 0
  exp="$(nm_epoch_from_date "$enddate")"; now="$(nm_now_epoch)"
  [ -n "$exp" ] && awk -v e="$exp" -v n="$now" 'BEGIN{printf "%d", (e-n)/86400}'
}

header="$(nm_ctx_header),url,http_code,dns_ms,connect_ms,tls_ms,ttfb_ms,total_ms,redirects,ssl_verify,remote_ip,cert_days_left"

http_one() {
  local url="$1" line code dns conn appconn ttfb total redir sslv rip
  line="$(curl -sS -o /dev/null --max-time "${HTTP_TIMEOUT:-15}" -w "$CURL_FMT" "$url" 2>>"$raw")"
  printf '%s => %s\n' "$url" "$line" >>"$raw"
  read -r code dns conn appconn ttfb total redir sslv rip <<<"$line"

  local dns_ms conn_ms tls_ms ttfb_ms total_ms
  dns_ms="$(ms "$dns")"; conn_ms="$(ms "$conn")"; ttfb_ms="$(ms "$ttfb")"; total_ms="$(ms "$total")"
  # TLS handshake time = appconnect - connect (0 for plain http).
  tls_ms="$(awk -v a="${appconn:-0}" -v c="${conn:-0}" 'BEGIN{d=(a-c)*1000; if(d<0)d=0; printf "%.0f", d}')"

  local cdays=""
  if [ "$(nm_url_scheme "$url")" = "https" ]; then
    cdays="$(cert_days_left "$(nm_url_host "$url")" "$(nm_url_port "$url")")"
  fi

  local row
  row="$(nm_ctx_row),$(nm_csv_join "$url" "${code:-0}" "$dns_ms" "$conn_ms" "$tls_ms" "$ttfb_ms" "$total_ms" "${redir:-0}" "${sslv:-}" "${rip:-}" "$cdays")"
  nm_csv_append http "$header" "$row"
  nm_log "http ${url} code=${code:-0} tls=${tls_ms}ms ttfb=${ttfb_ms}ms total=${total_ms}ms cert_days=${cdays:-NA}"
}

for u in "${HTTP_TARGETS[@]}"; do
  http_one "$u"
done

# --- Captive portal / connectivity probe -------------------------------------
if [ -n "${CAPTIVE_CHECK_URL:-}" ]; then
  cline="$(curl -sS -o /dev/null --max-time "${HTTP_TIMEOUT:-15}" \
    -w '%{http_code} %{num_redirects} %{url_effective}' "$CAPTIVE_CHECK_URL" 2>>"$raw")"
  ccode="$(awk '{print $1}' <<<"$cline")"
  credir="$(awk '{print $2}' <<<"$cline")"
  ceff="$(awk '{print $3}' <<<"$cline")"
  captive=0
  # A healthy generate_204 endpoint returns 204 with no redirect. Anything else
  # (redirect to a portal, or a 200 with a body) means traffic is intercepted.
  if [ "${ccode:-0}" != "204" ] || [ "${credir:-0}" != "0" ]; then captive=1; fi
  cheader="$(nm_ctx_header),check_url,http_code,redirects,effective_url,captive_suspected"
  crow="$(nm_ctx_row),$(nm_csv_join "$CAPTIVE_CHECK_URL" "${ccode:-0}" "${credir:-0}" "${ceff:-}" "$captive")"
  nm_csv_append captive "$cheader" "$crow"
  if [ "$captive" = "1" ]; then
    nm_warn "captive-portal check: code=${ccode} redirects=${credir} -> interception suspected"
  else
    nm_log "captive-portal check: clean (204, no redirect)"
  fi
fi
