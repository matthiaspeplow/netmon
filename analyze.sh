#!/usr/bin/env bash
# analyze.sh -- quick, dependency-free summary of the collected metrics for a
# recent time window. Surfaces the reauth-relevant signals first (public-IP
# changes / multi-egress), then latency/loss, MTU black holes, DNS, HTTP/TLS,
# captive portal and clock offset.
#
# Usage:
#   ./analyze.sh                # last 60 minutes
#   ./analyze.sh --minutes 240  # last 4 hours
#   ./analyze.sh --all          # everything on record
_nm_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=lib/common.sh
. "$_nm_dir/lib/common.sh"

minutes=60
while [ $# -gt 0 ]; do
  case "$1" in
    --minutes) minutes="$2"; shift 2 ;;
    --all)     minutes="" ; shift ;;
    -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) nm_err "unknown argument: $1"; exit 2 ;;
  esac
done

cutoff=""
if [ -n "$minutes" ]; then
  if nm_is_macos; then
    cutoff="$(date -u -v-"${minutes}"M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
  else
    cutoff="$(date -u -d "-${minutes} min" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
  fi
fi

M="$NM_METRICS_DIR"
col_index() { head -n1 "$1" 2>/dev/null | awk -F, -v n="$2" '{for(i=1;i<=NF;i++){g=$i; gsub(/^"|"$/,"",g); if(g==n){print i; exit}}}'; }
have_csv()  { [ -f "$M/$1.csv" ] && [ "$(wc -l <"$M/$1.csv")" -gt 1 ]; }

echo "==============================================================="
if [ -n "$cutoff" ]; then
  echo " netmon analysis  |  window: last ${minutes} min (since ${cutoff})"
else
  echo " netmon analysis  |  window: all data on record"
fi
echo " metrics dir: $M"
echo "==============================================================="

# --- 1. Public egress IP (primary reauth signal) -----------------------------
echo
echo "[1] PUBLIC EGRESS IP  (changes / multi-egress => forced reauth)"
if have_csv publicip; then
  f="$M/publicip.csv"
  awk -F, -v ts="$(col_index "$f" timestamp)" -v v4="$(col_index "$f" ipv4)" \
         -v ch="$(col_index "$f" changed)" -v dis="$(col_index "$f" disagreement)" \
         -v cut="$cutoff" '
    NR==1{next}
    { t=$ts; gsub(/"/,"",t); if(cut!="" && t<cut) next; n++;
      ip=$v4; gsub(/"/,"",ip); if(ip!="" && !(ip in seen)){seen[ip]=1; distinct++}
      if($ch==1) changed++; if($dis==1) disn++ }
    END{ printf "    samples=%d  distinct_v4=%d  changes=%d  disagreements=%d\n", n, distinct+0, changed+0, disn+0;
         if(distinct>0){ printf "    addresses:"; for(k in seen) printf " %s", k; print "" }
         if(changed>0||disn>0) print "    ** egress instability observed -- strong lead for the reauth complaints **" }' "$f"
  if [ -f "$NM_STATE_DIR/publicip_changes.log" ]; then
    echo "    recent change events:"; tail -n 5 "$NM_STATE_DIR/publicip_changes.log" | sed 's/^/      /'
  fi
else
  echo "    (no data)"
fi

# --- 2. Latency / loss / jitter ----------------------------------------------
echo
echo "[2] PING  (avg loss / avg rtt / worst jitter per target)"
if have_csv ping; then
  f="$M/ping.csv"
  awk -F, -v ts="$(col_index "$f" timestamp)" -v tg="$(col_index "$f" target)" \
         -v lo="$(col_index "$f" loss_pct)" -v av="$(col_index "$f" rtt_avg_ms)" \
         -v md="$(col_index "$f" rtt_mdev_ms)" -v cut="$cutoff" '
    NR==1{next}
    { t=$ts; gsub(/"/,"",t); if(cut!="" && t<cut) next;
      g=$tg; gsub(/"/,"",g); c[g]++; sl[g]+=$lo+0; if($av!=""){sa[g]+=$av; na[g]++}
      if($md+0>mj[g]) mj[g]=$md+0 }
    END{ for(k in c) printf "    %-22s loss=%.1f%%  rtt_avg=%.1fms  jitter_max=%.1fms  (n=%d)\n",
           k, sl[k]/c[k], (na[k]?sa[k]/na[k]:0), mj[k], c[k] }' "$f" | sort
else
  echo "    (no data)"
fi

# --- 3. Path MTU / black holes -----------------------------------------------
echo
echo "[3] MTU  (latest path MTU per target; black-hole flags)"
if have_csv mtu; then
  f="$M/mtu.csv"
  awk -F, -v ts="$(col_index "$f" timestamp)" -v tg="$(col_index "$f" target)" \
         -v pm="$(col_index "$f" path_mtu)" -v bh="$(col_index "$f" blackhole_suspected)" \
         -v cut="$cutoff" '
    NR==1{next}
    { t=$ts; gsub(/"/,"",t); if(cut!="" && t<cut) next;
      g=$tg; gsub(/"/,"",g); last[g]=$pm; if($bh==1) bhc[g]++ }
    END{ for(k in last) printf "    %-22s path_mtu=%s  blackhole_samples=%d\n", k, last[k], bhc[k]+0 }' "$f" | sort
else
  echo "    (no data)"
fi

# --- 4. DNS ------------------------------------------------------------------
echo
echo "[4] DNS  (failures / answer changes / avg query time)"
if have_csv dns; then
  f="$M/dns.csv"
  awk -F, -v ts="$(col_index "$f" timestamp)" -v st="$(col_index "$f" status)" \
         -v qt="$(col_index "$f" query_time_ms)" -v cg="$(col_index "$f" changed)" \
         -v cut="$cutoff" '
    NR==1{next}
    { t=$ts; gsub(/"/,"",t); if(cut!="" && t<cut) next; n++;
      s=$st; gsub(/"/,"",s); if(s!="NOERROR") fail++;
      if($qt!=""){sq+=$qt; nq++} if($cg==1) chg++ }
    END{ printf "    queries=%d  failures=%d  answer_changes=%d  avg_query=%.0fms\n",
           n, fail+0, chg+0, (nq?sq/nq:0) }' "$f"
else
  echo "    (no data)"
fi

# --- 5. HTTP / TLS -----------------------------------------------------------
echo
echo "[5] HTTP  (non-2xx/3xx / worst TTFB / soonest cert expiry)"
if have_csv http; then
  f="$M/http.csv"
  awk -F, -v ts="$(col_index "$f" timestamp)" -v cd="$(col_index "$f" http_code)" \
         -v tb="$(col_index "$f" ttfb_ms)" -v ce="$(col_index "$f" cert_days_left)" \
         -v cut="$cutoff" '
    NR==1{next}
    { t=$ts; gsub(/"/,"",t); if(cut!="" && t<cut) next; n++;
      c=$cd+0; if(c<200||c>=400) bad++;
      if($tb+0>maxtb) maxtb=$tb+0;
      if($ce!=""){ if(mind==""||$ce+0<mind) mind=$ce+0 } }
    END{ printf "    requests=%d  non_2xx_3xx=%d  ttfb_max=%dms  cert_days_min=%s\n",
           n, bad+0, maxtb+0, (mind==""?"NA":mind) }' "$f"
else
  echo "    (no data)"
fi

# --- 6. Captive portal -------------------------------------------------------
echo
echo "[6] CAPTIVE PORTAL  (interception on the connectivity check)"
if have_csv captive; then
  f="$M/captive.csv"
  awk -F, -v ts="$(col_index "$f" timestamp)" -v cs="$(col_index "$f" captive_suspected)" \
         -v cut="$cutoff" '
    NR==1{next}
    { t=$ts; gsub(/"/,"",t); if(cut!="" && t<cut) next; n++; if($cs==1) c++ }
    END{ printf "    checks=%d  interception_suspected=%d\n", n, c+0 }' "$f"
else
  echo "    (no data)"
fi

# --- 7. NTP offset -----------------------------------------------------------
echo
echo "[7] NTP  (clock offset; large drift can expire tokens/certs)"
if have_csv ntp; then
  f="$M/ntp.csv"
  awk -F, -v ts="$(col_index "$f" timestamp)" -v of="$(col_index "$f" offset_s)" \
         -v cut="$cutoff" '
    NR==1{next}
    { t=$ts; gsub(/"/,"",t); if(cut!="" && t<cut) next; n++;
      o=$of+0; last=$of; a=(o<0?-o:o); if(a>maxa) maxa=a }
    END{ printf "    samples=%d  last_offset=%ss  max_abs_offset=%.3fs\n", n, (last==""?"NA":last), maxa+0 }' "$f"
else
  echo "    (no data)"
fi

# --- 8. Throughput -----------------------------------------------------------
echo
echo "[8] THROUGHPUT  (down/up Mbps per method; disabled by default)"
if have_csv throughput; then
  f="$M/throughput.csv"
  awk -F, -v ts="$(col_index "$f" timestamp)" -v me="$(col_index "$f" method)" \
         -v dm="$(col_index "$f" download_mbps)" -v um="$(col_index "$f" upload_mbps)" \
         -v la="$(col_index "$f" latency_ms)" -v cut="$cutoff" '
    NR==1{next}
    { t=$ts; gsub(/"/,"",t); if(cut!="" && t<cut) next;
      m=$me; gsub(/"/,"",m); c[m]++;
      d=$dm+0; sd[m]+=d; lastd[m]=$dm; if(mind[m]==""||d<mind[m]) mind[m]=d;
      if($um!=""){su[m]+=$um; nu[m]++} if($la!=""){sl[m]+=$la; nl[m]++} }
    END{ for(k in c) printf "    %-10s down_avg=%.1f  down_min=%.1f  down_last=%s  up_avg=%.1f  lat_avg=%.0fms  (n=%d)\n",
           k, sd[k]/c[k], mind[k]+0, lastd[k], (nu[k]?su[k]/nu[k]:0), (nl[k]?sl[k]/nl[k]:0), c[k] }' "$f" | sort
else
  echo "    (no data -- throughput is off by default; set THROUGHPUT_ENABLED=1)"
fi

echo
echo "Tip: raw per-run detail is under $NM_RUNS_DIR/<timestamp>/"
