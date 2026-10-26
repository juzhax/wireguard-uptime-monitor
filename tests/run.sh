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
config=$(cat)
printf '%s\n' "$config" >> "$MOCK_DIR/curl-config"
if [[ -n ${MOCK_FAIL_TOKEN:-} && $config == *"$MOCK_FAIL_TOKEN"* ]]; then
    printf '%s' "${MOCK_FAIL_HTTP:-503}"
    exit 22
fi
if [[ ${MOCK_RECOVER:-0} == 1 && ! -f $MOCK_DIR/retry-done ]]; then
    : > "$MOCK_DIR/retry-done"
    printf '503'
    exit 22
fi
if [[ ${MOCK_HOLD:-0} == 1 ]]; then
    : > "$MOCK_DIR/ready"
    IFS= read -r _ < "$MOCK_DIR/release"
fi
if [[ ${MOCK_TRACK:-0} == 1 ]]; then
    printf 'start %s\n' "$$" >> "$MOCK_DIR/workers"
    /bin/sleep 0.05
    printf 'end %s\n' "$$" >> "$MOCK_DIR/workers"
fi
printf '%s' "${MOCK_HTTP:-200}"
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
if [[ $2 == ping ]]; then shift; exec "$@"; fi
exit "$MOCK_TCP"
MOCK
cat > "$work/mock/sleep" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$MOCK_DIR/backoff"
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
cat > "$work/mock/mv" <<'MOCK'
#!/usr/bin/env bash
if [[ ${MOCK_MV_FAIL:-0} == 1 ]]; then exit 1; fi
if [[ $(uname -s) == Darwin && $1 == -Tf ]]; then shift; exec /bin/mv -fh "$@"; fi
exec /bin/mv "$@"
MOCK
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
export MOCK_NOW=1299
cli run > "$work/output"
assert_contains "$work/output" 'VPN-CA01-002 vpn=pending'
export MOCK_NOW=1300
cli run > "$work/output"
assert_contains "$work/output" 'VPN-CA01-002 vpn=down'
assert_contains "$work/pushes" 'status=down'
assert_contains "$WUM_ROOT/var/lib/wireguard-uptime-monitor/VPN-CA01-002.state" '1000'
export MOCK_PING=0 MOCK_NOW=1360
cli run > "$work/output"
assert_contains "$work/output" 'VPN-CA01-002 vpn=up'
assert_contains "$WUM_ROOT/var/lib/wireguard-uptime-monitor/VPN-CA01-002.state" '^0'
printf 'PASS: pending, exact threshold, per-peer thresholds, persisted failure, recovery\n'
export MOCK_CURL=22
reject cli run
assert_contains "$work/rejected" 'Push delivery failed'
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
# Representative v0.1.0 files: explicit old defaults, optional labels and TCP,
# and the exact two-column failure history. Synthetic tokens only.
cat > "$WUM_ROOT/etc/wireguard-uptime-monitor/peers.d/VPN-CA01-002.conf" <<'PEER'
NAME=VPN-CA01-002
IP=10.0.0.2
TCP=
PUSH_URL=https://kuma.example.com/api/push/CA01_SYNTHETIC
THRESHOLD=600
ENABLED=yes
CLIENT=private CA01 customer
LOCATION=Canada
PEER
printf '1000\tdown\n' > "$WUM_ROOT/var/lib/wireguard-uptime-monitor/VPN-CA01-002.state"
printf '1100\tpending\n' > "$WUM_ROOT/var/lib/wireguard-uptime-monitor/VPN-SG03-200.state"
cp -R "$WUM_ROOT/etc/wireguard-uptime-monitor" "$work/config-before"
cp -R "$WUM_ROOT/var/lib/wireguard-uptime-monitor" "$work/state-before"
if [[ -n ${WUM_V010_SOURCE:-} ]]; then
    "$WUM_V010_SOURCE/install.sh" > "$work/output"
    "$WUM_ROOT/usr/local/bin/wireguard-uptime-monitor" --version > "$work/output"
    assert_contains "$work/output" '0.1.0'
    "$WUM_ROOT/usr/local/bin/wireguard-uptime-monitor" update --source "$BASE" > "$work/output"
fi
"$BASE/install.sh" > "$work/output"
[[ -L $WUM_ROOT/usr/local/bin/wireguard-uptime-monitor ]]
"$BASE/install.sh" > "$work/output"
"$WUM_ROOT/usr/local/bin/wireguard-uptime-monitor" --version > "$work/output"
assert_contains "$work/output" '0.2.0'
"$WUM_ROOT/usr/local/bin/wireguard-uptime-monitor" update --source "$BASE" > "$work/output"
diff -r "$work/config-before" "$WUM_ROOT/etc/wireguard-uptime-monitor"
diff -r "$work/state-before" "$WUM_ROOT/var/lib/wireguard-uptime-monitor"
cli status > "$work/output"
assert_contains "$work/output" 'threshold=600s state=down since=1000 reported=unknown'
export MOCK_PING=1 MOCK_NOW=1700
cli run > "$work/output"
assert_contains "$work/output" 'VPN-CA01-002 vpn=down'
assert_contains "$work/output" 'VPN-SG03-200 vpn=down'
export MOCK_PING=0
printf 'PASS: v0.1.0 CA01/SG03 configs, tokens, labels, thresholds and failure history survive repeat installs and updates\n'

conf="$WUM_ROOT/etc/wireguard-uptime-monitor/peers.d"
state="$WUM_ROOT/var/lib/wireguard-uptime-monitor"
cli disable VPN-CA01-002
cli enable VPN-CA01-002
cli set VPN-CA01-002 --threshold 300
assert_contains "$conf/VPN-CA01-002.conf" 'CA01_SYNTHETIC'
assert_contains "$conf/VPN-CA01-002.conf" 'CLIENT=private CA01 customer'
assert_contains "$state/VPN-CA01-002.state" '^1000'
reject cli set VPN-CA01-002 --threshold 0
assert_contains "$conf/VPN-CA01-002.conf" 'THRESHOLD=300'
cp "$conf/VPN-CA01-002.conf" "$work/before-rename"
export MOCK_MV_FAIL=1
reject cli set VPN-CA01-002 --threshold 999
unset MOCK_MV_FAIL
cmp "$work/before-rename" "$conf/VPN-CA01-002.conf"

cat > "$work/peers.csv" <<'CSV'
name,ip,threshold,push_url,enabled
VPN-CA01-002,,450,,
VPN-SG03-003,10.1.0.3,,https://kuma.example.com/api/push/NEW_SYNTHETIC,
CSV
cp -R "$conf" "$work/pre-bulk"
cli bulk-add --file "$work/peers.csv" --dry-run
diff -r "$work/pre-bulk" "$conf"
cli bulk-add --file "$work/peers.csv"
assert_contains "$conf/VPN-CA01-002.conf" 'THRESHOLD=450'
assert_contains "$conf/VPN-CA01-002.conf" 'CA01_SYNTHETIC'
assert_contains "$conf/VPN-SG03-003.conf" 'THRESHOLD=300'
assert_contains "$conf/VPN-SG03-003.conf" 'ENABLED=no'
printf 'name,threshold\nVPN-CA01-002,500\nVPN-CA01-002,600\n' > "$work/duplicate.csv"
reject cli bulk-add --file "$work/duplicate.csv"
assert_contains "$conf/VPN-CA01-002.conf" 'THRESHOLD=450'
for bad in 'VPN-SG03-004,10.0.0.999,,https://kuma.example.com/api/push/OK,yes' \
    'VPN-SG03-004,10.0.0.4,,https://kuma.example.com:99999/api/push/OK,yes' \
    'VPN-SG03-004,10.0.0.4,,https://kuma.example.com/api/push/OK?bad,yes' \
    'VPN-SG03-004,10.0.0.4,0,https://kuma.example.com/api/push/OK,yes' \
    'VPN-SG03-004,10.0.0.4,,https://kuma.example.com/api/push/OK,true'; do
    { printf 'name,ip,threshold,push_url,enabled\nVPN-CA01-002,,999,,\n'; printf '%s\n' "$bad"; } > "$work/bad.csv"
    reject cli bulk-add --file "$work/bad.csv"
    [[ ! -e $conf/VPN-SG03-004.conf ]]
    assert_contains "$conf/VPN-CA01-002.conf" 'THRESHOLD=450'
done
printf 'name,push_url\nVPN-CA01-002,https://kuma.example.com/api/push/REPLACED_SYNTHETIC\n' > "$work/token.csv"
cli bulk-add --file "$work/token.csv"
assert_contains "$conf/VPN-CA01-002.conf" 'REPLACED_SYNTHETIC'
reject cli disable-all < /dev/null
cli disable-all --dry-run
assert_contains "$conf/VPN-CA01-002.conf" 'ENABLED=yes'
cli disable-all --yes
cli enable-all --yes
cli disable-all --yes
printf 'threshold,name\r\n450,VPN-CA01-002' > "$work/reordered.csv"
cli bulk-add --file "$work/reordered.csv" > "$work/output"
for header in 'name,name' 'ip,threshold' 'name,unknown'; do
    printf '%s\n' "$header" > "$work/header.csv"
    reject cli bulk-add --file "$work/header.csv"
done
printf 'name,ip,push_url\nVPN-SG03-004,10.0.0.4,\n' > "$work/missing-url.csv"
reject cli bulk-add --file "$work/missing-url.csv"
[[ ! -e $conf/VPN-SG03-004.conf ]]
printf 'PASS: bulk validation, defaults, token preservation/replacement, dry-run, enable/disable/set and confirmation\n'

# Recovery delivery must remain unacknowledged after exhausted retries.
cli enable VPN-CA01-002
printf '1000\tdown\tdown\tdelivered\n' > "$state/VPN-CA01-002.state"
export MOCK_CURL=22 MOCK_HTTP=503
: > "$work/backoff"
reject cli run
assert_contains "$state/VPN-CA01-002.state" $'^0\tup\tdown\tfailed$'
assert_contains "$work/rejected" 'http=503 curl_exit=22 attempt=3'
[[ $(wc -l < "$work/backoff") -eq 2 ]]
[[ $(cat "$work/backoff") == $'1\n2' ]]
export MOCK_CURL=0 MOCK_HTTP=200 MOCK_RECOVER=1
: > "$work/backoff"
cli run > "$work/output" 2> "$work/errors"
[[ $(wc -l < "$work/backoff") -eq 1 ]]
unset MOCK_RECOVER
assert_contains "$state/VPN-CA01-002.state" $'^0\tup\tup\tdelivered$'
export MOCK_CURL=22 MOCK_HTTP=401
: > "$work/backoff"
reject cli run
[[ ! -s $work/backoff ]]
export MOCK_CURL=22 MOCK_HTTP=SECRET_RESPONSE
reject cli run
assert_contains "$work/rejected" 'http=000 curl_exit=22'
assert_absent "$work/rejected" 'SECRET_RESPONSE|REPLACED_SYNTHETIC'
export MOCK_CURL=28 MOCK_HTTP=000
reject cli run
assert_contains "$work/rejected" 'http=000 curl_exit=28 attempt=3'
export MOCK_CURL=0 MOCK_HTTP=200
# A failing first peer must not prevent subsequent healthy peers from reporting.
cli enable VPN-SG03-003
export MOCK_FAIL_TOKEN=REPLACED_SYNTHETIC MOCK_HTTP=200
reject cli run
assert_contains "$state/VPN-SG03-003.state" $'up\tup\tdelivered$'
unset MOCK_FAIL_TOKEN MOCK_HTTP
printf 'PASS: bounded retry/backoff, permanent errors, independent delivery, recovery acknowledgement\n'

# Exercise reads under the actual lock, plus writes being rejected.
(
    exec 8> "$WUM_ROOT/run/lock/wireguard-uptime-monitor.lock"
    flock -n 8
    cli list > "$work/output"
    cli status > "$work/output"
    reject cli set VPN-CA01-002 --threshold 900
    reject cli bulk-add --file "$work/peers.csv"
    reject "$BASE/install.sh" update
)
assert_contains "$conf/VPN-CA01-002.conf" 'THRESHOLD=450'
printf 'PASS: list/status available under monitor lock; config writes and updates excluded\n'

# Hold a real monitor worker in mocked curl and read safely while it runs.
cli disable-all --yes > "$work/output"
cli enable VPN-CA01-002 > "$work/output"
mkfifo "$work/release"
export MOCK_HOLD=1
cli run > "$work/monitor-output" 2> "$work/monitor-errors" &
monitor_pid=$!
for _ in {1..100}; do
    [[ ! -e $work/ready ]] || break
    /bin/sleep 0.05
done
[[ -e $work/ready ]]
cli list > "$work/output"
cli status > "$work/output"
reject cli run
reject cli disable VPN-CA01-002
printf 'release\n' > "$work/release"
wait "$monitor_pid"
unset MOCK_HOLD
assert_contains "$state/VPN-CA01-002.state" $'^0\tup\tup\tdelivered$'
printf 'PASS: list/status during active monitoring; overlapping runs and writes rejected\n'

# Check the worker cap and full coverage across multiple batches.
cli disable-all --yes > "$work/output"
{
    printf 'name,ip,push_url,enabled\n'
    for n in {1..17}; do
        printf 'VPN-TEST-%03d,10.9.0.%s,https://kuma.example.com/api/push/TEST_%s,yes\n' "$n" "$n" "$n"
    done
} > "$work/many.csv"
cli bulk-add --file "$work/many.csv" > "$work/output"
export MOCK_TRACK=1
cli run > "$work/output"
unset MOCK_TRACK
awk '$1 == "start" { active++; total++; if (active > max) max=active } $1 == "end" { active-- }
    END { if (active != 0 || max > 8 || max < 2 || total != 17) exit 1 }' "$work/workers"
[[ $(rg -c 'vpn=up' "$work/output") -eq 17 ]]
printf 'PASS: bounded parallel workers and all 17 peers checked across three batches\n'

# Repeated outage pushes must never introduce an up/pending heartbeat to Kuma.
cli disable-all --yes > "$work/output"
cli enable VPN-CA01-002 > "$work/output"
printf '1000\tdown\tdown\tdelivered\n' > "$state/VPN-CA01-002.state"
export MOCK_PING=1 MOCK_NOW=2000
: > "$work/pushes"
cli run > "$work/output"
cli run >> "$work/output"
assert_absent "$work/pushes" 'status=up|status=pending'
assert_contains "$state/VPN-CA01-002.state" $'^1000\tdown\tdown\tdelivered$'
# A short subsequent failure after a failed recovery must not send synthetic up.
export MOCK_PING=0 MOCK_CURL=22 MOCK_HTTP=401
reject cli run
export MOCK_PING=1 MOCK_CURL=0 MOCK_HTTP=200
: > "$work/pushes"
cli run > "$work/output"
[[ ! -s $work/pushes ]]
assert_contains "$state/VPN-CA01-002.state" $'pending\tdown\tfailed$'
printf 'PASS: stable outage heartbeats and failed recovery do not create false notification transitions\n'

"$BASE/install.sh" uninstall > "$work/output"
"$BASE/install.sh" uninstall > "$work/output"
[[ -f $conf/VPN-CA01-002.conf && -f $state/VPN-CA01-002.state ]]
assert_absent "$work/systemctl" 'wg-quick|restart.*wg|stop.*wg'
printf 'PASS: idempotent uninstall retains config/state and never changes WireGuard\n'
printf 'All tests passed.\n'
