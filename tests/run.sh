#!/usr/bin/env bash
set -euo pipefail
BASE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export WUM_ROOT="$work/root" WUM_TESTING=1 MOCK_DIR="$work" MOCK_NOW=1000 MOCK_PING=0 MOCK_CURL=0 MOCK_TCP=0
mkdir -p "$work/mock" "$WUM_ROOT"
export PATH="$work/mock:$PATH"
cat > "$work/mock/ping" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$MOCK_DIR/pings"
exit "$MOCK_PING"
MOCK
cat > "$work/mock/curl" <<'MOCK'
#!/usr/bin/env bash
cat >> "$MOCK_DIR/curl-config"
printf '%s\n' "$@" >> "$MOCK_DIR/pushes"
exit "$MOCK_CURL"
MOCK
cat > "$work/mock/wg" <<'MOCK'
#!/usr/bin/env bash
[[ $* == 'show all dump' ]] || exit 1
printf 'wg0\tPRIVATE_SECRET\tSERVER_KEY\t51820\toff\n'
printf 'wg0\tPEER_KEY\tPRESHARED_SECRET\t(none)\t10.0.0.2/32,10.0.0.0/24\t0\t0\t0\t0\n'
MOCK
cat > "$work/mock/date" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$MOCK_NOW"
MOCK
cat > "$work/mock/timeout" <<'MOCK'
#!/usr/bin/env bash
exit "$MOCK_TCP"
MOCK
cat > "$work/mock/systemctl" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$MOCK_DIR/systemctl"
MOCK
if ! command -v flock >/dev/null; then
    # macOS-only test compatibility: same inherited file-description lock semantics.
    cat > "$work/mock/flock" <<'MOCK'
#!/usr/bin/env perl
use strict;
use Fcntl qw(LOCK_EX LOCK_NB);
my $fd = $ARGV[-1];
open(my $handle, ">&=$fd") or die $!;
exit(flock($handle, LOCK_EX | LOCK_NB) ? 0 : 1);
MOCK
fi
if [[ $(uname -s) == Darwin ]]; then
    cat > "$work/mock/mv" <<'MOCK'
#!/usr/bin/env bash
if [[ $1 == -Tf ]]; then shift; exec /bin/mv -fh "$@"; fi
exec /bin/mv "$@"
MOCK
fi
chmod +x "$work/mock/"*
cli() { "$BASE/bin/wireguard-uptime-monitor" "$@"; }
assert_absent() { if rg -q -- "$2" "$1"; then printf 'FAIL: unexpected content in %s\n' "$1" >&2; exit 1; fi; }
assert_contains() { rg -q -- "$2" "$1" || { printf 'FAIL: expected %s in %s\n' "$2" "$1" >&2; exit 1; }; }
reject() { if "$@" > "$work/rejected" 2>&1; then printf 'FAIL: command unexpectedly succeeded\n' >&2; exit 1; fi; }
secret='https://kuma.example.com/api/push/SECRET_TOKEN'
printf '%s\n' "$secret" > "$work/url"
cli add --server CA01 --ip 10.0.0.2 --push-url-file "$work/url" --enabled yes
cli add --server CA01 --ip 10.0.0.2 --push-url-file "$work/url" --enabled yes
cli add --server SG03 --ip 10.0.0.50 --push-url-file "$work/url"
cli add --server SG03 --ip 10.0.0.200 --push-url-file "$work/url" --enabled yes --tcp 10.0.0.200:443 --threshold 120 --client PRIVATE_CLIENT --location PRIVATE_LOCATION
cli run > "$work/output"
assert_contains "$work/pushes" 'status=up'
assert_contains "$work/pushes" '--data-urlencode'
assert_absent "$work/pushes" 'SECRET_TOKEN'
assert_contains "$work/curl-config" 'SECRET_TOKEN'
[[ $(wc -l < "$work/pings") -eq 2 ]]
assert_absent "$work/output" 'SECRET|PRIVATE'
printf 'PASS: multiple peers, names, explicit enablement, healthy pushes, idempotent add\n'
: > "$work/pushes"
export MOCK_PING=1
cli run > "$work/output"
assert_contains "$work/output" pending
[[ ! -s $work/pushes ]]
export MOCK_NOW=1599
cli run > "$work/output"
assert_contains "$work/output" 'VPN-CA01-002 pending'
export MOCK_NOW=1600
cli run > "$work/output"
assert_contains "$work/output" 'VPN-CA01-002 down'
assert_contains "$work/pushes" 'status=down'
assert_contains "$WUM_ROOT/var/lib/wireguard-uptime-monitor/VPN-CA01-002.state" '1000'
export MOCK_PING=0 MOCK_NOW=1660
cli run > "$work/output"
assert_contains "$work/output" 'VPN-CA01-002 up'
assert_contains "$WUM_ROOT/var/lib/wireguard-uptime-monitor/VPN-CA01-002.state" '^0'
printf 'PASS: pending, exact threshold, per-peer thresholds, persisted failure, recovery\n'
export MOCK_CURL=22
reject cli run
assert_contains "$work/rejected" 'push failed'
assert_absent "$work/rejected" 'SECRET_TOKEN'
export MOCK_CURL=0 MOCK_TCP=1
reject cli test VPN-SG03-200
export MOCK_TCP=0
cli test VPN-CA01-002 > "$work/output"
cli discover > "$work/output"
assert_contains "$work/output" '10.0.0.2'
assert_absent "$work/output" 'PRIVATE_SECRET|PRESHARED_SECRET|10.0.0.0'
cli list > "$work/output"
assert_absent "$work/output" 'SECRET_TOKEN|PRIVATE_CLIENT|PRIVATE_LOCATION'
printf 'PASS: TCP checks, test command, discovery filters, secret and label redaction\n'
printf '08\tdown\n' > "$WUM_ROOT/var/lib/wireguard-uptime-monitor/VPN-CA01-002.state"
reject cli run
assert_contains "$work/rejected" 'invalid state'
printf '2000\tpending\n' > "$WUM_ROOT/var/lib/wireguard-uptime-monitor/VPN-CA01-002.state"
export MOCK_PING=1 MOCK_NOW=1700
cli run > "$work/output"
assert_contains "$WUM_ROOT/var/lib/wireguard-uptime-monitor/VPN-CA01-002.state" '^1700'
export MOCK_PING=0
printf 'PASS: corrupt state rejected and backwards clock handled\n'
reject cli add --server BAD --ip 10.0.0.999 --push-url-file "$work/url"
reject cli add --server BAD --ip 10.0.0.002 --push-url-file "$work/url"
reject cli add --server BAD --ip 10.0.0.3 --push-url-file "$work/url" --threshold 0
printf 'https://kuma.example.com/api/push/SECRET?status=up\n' > "$work/badurl"
reject cli add --server BAD --ip 10.0.0.3 --push-url-file "$work/badurl"
# shellcheck disable=SC2016
printf 'EVIL=$(touch %s/injected)\n' "$work" >> "$WUM_ROOT/etc/wireguard-uptime-monitor/peers.d/VPN-CA01-002.conf"
reject cli run
[[ ! -e $work/injected ]]
cli remove VPN-CA01-002
cli remove VPN-CA01-002
printf 'PASS: validation, non-executable configs, idempotent removal\n'
(
    exec 8>"$WUM_ROOT/run/lock/wireguard-uptime-monitor.lock"
    flock -n 8
    reject cli run
    assert_contains "$work/rejected" 'Another monitor'
)
printf 'PASS: real inherited file lock prevents overlap\n'
mkdir -p "$WUM_ROOT/opt/vpn-monitor"
printf 'original\n' > "$WUM_ROOT/opt/vpn-monitor/legacy.conf"
reject "$BASE/install.sh"
"$BASE/install.sh" --migrate-legacy > "$work/output"
[[ -L $WUM_ROOT/usr/local/bin/wireguard-uptime-monitor ]]
cmp "$WUM_ROOT/opt/vpn-monitor/legacy.conf" "$WUM_ROOT/var/lib/wireguard-uptime-monitor/legacy-backup/legacy.conf"
"$BASE/install.sh" --migrate-legacy > "$work/output"
"$WUM_ROOT/usr/local/bin/wireguard-uptime-monitor" --version > "$work/output"
assert_contains "$work/output" '0.1.0'
"$WUM_ROOT/usr/local/bin/wireguard-uptime-monitor" update --source "$BASE" > "$work/output"
"$BASE/install.sh" update --migrate-legacy > "$work/output"
"$BASE/install.sh" uninstall > "$work/output"
"$BASE/install.sh" uninstall > "$work/output"
[[ -f $WUM_ROOT/opt/vpn-monitor/legacy.conf && -d $WUM_ROOT/etc/wireguard-uptime-monitor/peers.d ]]
assert_absent "$work/systemctl" 'wg-quick|restart.*wg|stop.*wg'
printf 'PASS: staged install, update, uninstall, retained config, safe migration, no WireGuard changes\n'
printf 'All tests passed.\n'
