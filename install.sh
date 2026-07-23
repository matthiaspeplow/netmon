#!/usr/bin/env bash
# install.sh -- set up netmon on a Debian/Ubuntu box.
#
#   sudo ./install.sh              # install apt dependencies + chmod scripts
#   sudo ./install.sh --systemd    # also install & enable the systemd timers
#   sudo ./install.sh --no-deps --systemd   # only (re)install the timers
#
# The systemd units run from THIS directory, so keep the checkout where it is
# (or re-run with --systemd after moving it).
_nm_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=lib/common.sh
. "$_nm_dir/lib/common.sh"

do_systemd=0
install_deps=1
while [ $# -gt 0 ]; do
  case "$1" in
    --systemd) do_systemd=1; shift ;;
    --no-deps) install_deps=0; shift ;;
    -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) nm_err "unknown argument: $1"; exit 2 ;;
  esac
done

SUDO=""
[ "$(id -u)" -ne 0 ] && SUDO="sudo"

DEPS=(
  iputils-ping iputils-tracepath traceroute mtr-tiny
  bind9-dnsutils curl ca-certificates openssl
  iperf3 speedtest-cli ethtool jq
)

if [ "$install_deps" -eq 1 ]; then
  if ! nm_have apt-get; then
    nm_err "apt-get not found -- this installer targets Debian/Ubuntu."
    nm_err "Install these tools manually: ${DEPS[*]}"
    exit 1
  fi
  nm_log "installing dependencies via apt-get ..."
  $SUDO apt-get update
  # Don't abort the whole install if one optional package is unavailable.
  for pkg in "${DEPS[@]}"; do
    $SUDO apt-get install -y "$pkg" || nm_warn "could not install $pkg (continuing)"
  done
fi

nm_log "making scripts executable ..."
chmod +x "$_nm_dir/netmon.sh" "$_nm_dir/analyze.sh" "$_nm_dir/mtu-sweep.sh" "$_nm_dir/install.sh" \
         "$_nm_dir"/tests/*.sh 2>/dev/null || true

if [ "$do_systemd" -eq 1 ]; then
  if ! nm_have systemctl; then
    nm_err "systemctl not found -- cannot install timers on this system."
    exit 1
  fi
  nm_log "installing systemd units (pointing at $_nm_dir) ..."
  for tmpl in "$_nm_dir"/systemd/*.service "$_nm_dir"/systemd/*.timer; do
    unit="$(basename "$tmpl")"
    $SUDO sed "s|__NETMON_DIR__|$_nm_dir|g" "$tmpl" | $SUDO tee "/etc/systemd/system/$unit" >/dev/null
  done
  $SUDO systemctl daemon-reload
  $SUDO systemctl enable --now netmon.timer netmon-publicip.timer
  nm_log "timers enabled. Status:"
  $SUDO systemctl --no-pager list-timers 'netmon*' || true
  nm_log "logs: journalctl -u netmon.service -u netmon-publicip.service -f"
fi

nm_log "done. Edit config/netmon.conf (or create config/netmon.local.conf), then run: $_nm_dir/netmon.sh"
