# netmon — network diagnostics toolkit

A set of Debian shell scripts that gather **longitudinal** network data to help
track down two complaints reported in the Frankfurt office:

1. Poor / unreliable network performance.
2. Users being **forced to re-authenticate** in web apps.

Both happen on **LAN, WiFi and Guest WiFi** — all three share the same internet
egress path, so the tool focuses on the shared upstream (gateway/firewall, WAN,
DNS, egress) and records everything with timestamps so an event ("I just got
logged out at 14:03") can be correlated with the network state at that moment.

The toolkit does **not** assume a root cause. It collects evidence to confirm or
rule out the leading hypotheses (see [Interpreting results](#interpreting-results)).

## Requirements

- Debian/Ubuntu (the probe box). Scripts are plain `bash` wrapping standard CLI
  tools; nothing is compiled.
- Tools installed by `install.sh`: `ping`, `tracepath`, `traceroute`, `mtr`,
  `dig`, `curl`, `openssl`, `iperf3`, `speedtest-cli`, `ethtool`, `jq`.
  Every test **degrades gracefully** if an optional tool is missing.

## Install

```bash
cd netmon
sudo ./install.sh            # install apt dependencies + make scripts executable
sudo ./install.sh --systemd  # ALSO install & enable the scheduled timers
```

`--systemd` writes units to `/etc/systemd/system/` that run from this checkout,
so keep the directory in place (re-run `sudo ./install.sh --no-deps --systemd`
if you move it).

## Configure

Edit `config/netmon.conf`, or (preferred) copy it to `config/netmon.local.conf`
and edit that — the local file is git-ignored and overrides the tracked one.

Fill in the placeholders, especially:

- `SEGMENT` — set to `lan`, `wifi`, or `guest` on each probe so results are
  comparable across segments.
- `HTTP_TARGETS` and `DNS_NAMES` — the **real web apps** where users get logged
  out. The timing/TLS/DNS data is most valuable against those endpoints.
- Internal `PING_TARGETS` / `TRACE_TARGETS` (gateway is auto-added) and, if you
  have one, an `IPERF_SERVER`.
- `IPV6_ENABLED=0` if the site is IPv4-only.

## Usage

One-shot (writes a timestamped run + appends to the rolling CSVs):

```bash
./netmon.sh                 # all enabled tests
./netmon.sh --only publicip # just one test (comma/space separated for several)
./netmon.sh --list          # list test names
```

Scheduled (recommended — intermittent problems need continuous data):

- `sudo ./install.sh --systemd` enables two timers:
  - **netmon.timer** — full suite every 5 min.
  - **netmon-publicip.timer** — lightweight egress-IP check every 60 s (catches
    brief flaps between full runs).
- Follow logs: `journalctl -u netmon.service -u netmon-publicip.service -f`

Cron alternative (if you prefer cron to systemd):

```cron
*/5 * * * *  /opt/netmon/netmon.sh >/dev/null 2>&1
* * * * *    /opt/netmon/tests/publicip.sh >/dev/null 2>&1
```

Summarize what's been collected:

```bash
./analyze.sh                # last 60 minutes
./analyze.sh --minutes 240  # last 4 hours
./analyze.sh --all          # everything on record
```

## Tests

| Test | What it records | Primary tools |
|------|-----------------|---------------|
| `publicip` | Egress public IPv4/IPv6, ASN/org, whether it **changed** vs last sample, and whether services **disagree** in one sample (multi-egress) | `curl` (+`jq`) |
| `ping` | Latency (min/avg/max), packet **loss %**, **jitter** (mdev) per target incl. gateway | `ping` |
| `mtu` | **Path MTU** via DF-bit binary search + PMTU **black-hole** heuristic | `ping -M do`, `tracepath` |
| `traceroute` | Full path per target + **path-change** detection between runs | `mtr` → `traceroute` |
| `dns` | Resolution **latency**, answers, failures, and answer **changes**, per resolver | `dig` |
| `http` | Per web-app timing (DNS/connect/**TLS**/TTFB/total), HTTP status, redirects, **cert days-to-expiry**; plus a **captive-portal** check | `curl`, `openssl` |
| `ntp` | **Clock offset** vs a reference server | `ntpdate`/`sntp`/`chronyc` |
| `throughput` | Down/up bandwidth (internet and/or internal) — **disabled by default** | `speedtest-cli`, `iperf3` |

`throughput` is off by default because running a speed test every few minutes
saturates the link and skews the latency/loss you're measuring. Enable it
(`THROUGHPUT_ENABLED=1`) only for occasional or slower-cadence runs.

## Output layout

```
output/
  runs/<UTC timestamp>/     # raw tool output for one full run
    context.txt             #   segment, iface, local IP, gateway, SSID, OS
    ping_<target>.txt, mtu_<target>.txt, trace_<target>.txt, dns.txt,
    http.txt, ntp.txt, run.log
  metrics/                  # rolling append-only time series (one file per test)
    context.csv publicip.csv ping.csv mtu.csv traceroute.csv dns.csv
    http.csv captive.csv ntp.csv throughput.csv
  state/                    # last-seen values for change detection
    publicip_v4, publicip_changes.log, trace_*.path, dns_*.ans
```

Every metrics row is prefixed with `timestamp,segment,site`, so you can `cat`
the CSVs from all three probes together and slice by segment in any spreadsheet.

## Interpreting results

The two leading, research-backed explanations for **forced reauthentication**
and how the data confirms or rules them out:

1. **Egress public-IP instability** — Many web apps bind a session to the
   client's public source IP; when it changes mid-session (dual-WAN/SD-WAN
   failover, NAT pool, load balancing) the app logs the user out. Look at
   `publicip.csv` / `analyze.sh` section **[1]**:
   - `changed=1` events, especially clustered around logout complaints.
   - `disagreement=1` (services returned different IPs in one sample) ⇒ traffic
     is leaving via more than one egress **right now**.
   - `state/publicip_changes.log` lists every observed change with a timestamp.

2. **PMTU black hole** — A firewall dropping ICMP "fragmentation needed" makes
   large TLS/HTTPS packets vanish silently: small requests work, big ones hang.
   Look at `mtu.csv` / section **[3]**:
   - `path_mtu` well below 1500, or `blackhole_suspected=1`.
   - Corroborate with slow/failed `http` TTFB and `ping` loss.

Supporting signals: `ping` loss/jitter (which segment/hop), `traceroute`
`path_changed=1` (route instability), `dns` failures/changes, `http` non-2xx and
TLS handshake time, `captive` interception (Guest WiFi), and `ntp` offset (clock
drift expiring tokens/certs).

## Notes

- Run the same toolkit on a box on **each** segment (set `SEGMENT` accordingly)
  to compare LAN vs WiFi vs Guest.
- Under systemd the probes run as **root**, so `output/` files will be
  root-owned; set `NM_OUTPUT_DIR` in the unit files to relocate if desired.
- No data leaves the box except the diagnostic probes themselves (public-IP and
  connectivity checks call well-known public endpoints listed in the config).
