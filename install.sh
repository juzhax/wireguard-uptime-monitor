#!/usr/bin/env bash
set -euo pipefail
BASE=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$BASE/lib/common.sh"
require_root
mode=install
if [[ ${1:-} != --migrate-legacy && $# != 0 ]]; then mode=$1; shift; fi
migrate=no
if [[ ${1:-} == --migrate-legacy ]]; then migrate=yes; shift; fi
[[ $# == 0 ]] || fail 'Usage: install.sh [install|update|uninstall] [--migrate-legacy]'
[[ $mode == install || $mode == update || $mode == uninstall ]] || fail 'Unknown installer command.'
[[ $(uname -s) == Linux || ${WUM_TESTING:-0} == 1 ]] || fail 'A systemd-based Linux distribution is required.'
if [[ $mode != uninstall ]]; then
    for dependency in bash curl ping flock wg timeout systemctl awk mktemp; do
        command -v "$dependency" >/dev/null || fail "Missing dependency: $dependency (see README package commands)."
    done
    (( BASH_VERSINFO[0] >= 4 )) || fail 'Bash 4 or newer is required.'
    if [[ -d $ROOT/opt/vpn-monitor && ! -d $STATE/legacy-backup && $migrate != yes ]]; then
        fail 'Legacy /opt/vpn-monitor found. Review README migration steps, then rerun with --migrate-legacy to create a private snapshot. The old installation is never changed.'
    fi
fi
init_dirs
lock_all
unitdir="$ROOT/etc/systemd/system"
libdir="$ROOT/usr/local/lib/wireguard-uptime-monitor"
bindir="$ROOT/usr/local/bin"
if [[ $mode == uninstall ]]; then
    systemctl disable --now wireguard-uptime-monitor.timer || true
    systemctl stop wireguard-uptime-monitor.service || true
    rm -f "$unitdir/wireguard-uptime-monitor.timer" "$unitdir/wireguard-uptime-monitor.service"
    rm -f "$bindir/wireguard-uptime-monitor"
    rm -rf -- "$libdir"
    systemctl daemon-reload
    printf 'Uninstalled. Private configuration, state, and legacy snapshots retained.\n'
    exit 0
fi
if [[ $migrate == yes && -d $ROOT/opt/vpn-monitor && ! -e $STATE/legacy-backup ]]; then
    cp -a "$ROOT/opt/vpn-monitor" "$STATE/legacy-backup"
    chmod -R go-rwx "$STATE/legacy-backup"
    printf 'Private legacy snapshot saved. Configure peers explicitly; legacy jobs remain unchanged.\n'
fi
mkdir -p "$unitdir" "$libdir/releases" "$bindir"
# Fully stage a release before atomically switching the current link.
release=$(mktemp -d "$libdir/releases/$VERSION.XXXXXX")
mkdir -p "$release/bin" "$release/lib" "$release/systemd"
install -m 755 "$BASE/bin/wireguard-uptime-monitor" "$release/bin/"
install -m 600 "$BASE/lib/common.sh" "$release/lib/"
install -m 755 "$BASE/install.sh" "$release/"
install -m 644 "$BASE/systemd/"* "$release/systemd/"
chmod 755 "$release" "$release/bin" "$release/lib" "$release/systemd"
ln -s "$release" "$libdir/.current.$$"
mv -Tf "$libdir/.current.$$" "$libdir/current"
ln -sfn "$libdir/current/bin/wireguard-uptime-monitor" "$bindir/wireguard-uptime-monitor"
install -m 644 "$BASE/systemd/"* "$unitdir/"
systemctl daemon-reload
systemctl enable --now wireguard-uptime-monitor.timer
printf 'Installed version %s. Use sudo wireguard-uptime-monitor add to configure peers.\n' "$VERSION"
