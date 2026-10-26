# wireguard-uptime-monitor

Version **0.2.0** · MIT · Bash + systemd · systemd-based Linux

Check WireGuard peer reachability and report to Uptime Kuma Push monitors. No Docker or additional runtime dependencies. This tool never modifies, restarts or disconnects WireGuard.

## Install

1. Install the existing runtime dependencies:

   ```bash
   # Ubuntu / Debian
   sudo apt-get update
   sudo apt-get install -y bash curl iputils-ping util-linux coreutils wireguard-tools
   # AlmaLinux (enable your distribution's WireGuard tools repository if needed)
   sudo dnf install -y bash curl iputils util-linux coreutils wireguard-tools
   ```

   Requires Bash 4+, systemd and standard Linux utilities (`awk`, `install`, `mktemp`, `date`, `cmp`). `flock` is from util-linux; `timeout` is from coreutils.

2. Review the checkout, then install:

   ```bash
   git clone https://github.com/juzhax/wireguard-uptime-monitor.git
   cd wireguard-uptime-monitor
   sudo ./install.sh
   ```

   This starts a **60-second timer**, initially with no peers. Repeating installation preserves existing peer files, tokens and state.

3. Discover candidate addresses and create a separate Kuma **Push** monitor for each peer:

   ```bash
   sudo wireguard-uptime-monitor discover
   ```

   Discovery reads `wg show all dump`, displays interface/public key/IPv4 `/32` addresses, and discards private and preshared keys. It never saves the dump, adds peers or enables them. IPv6 and subnet routes are not discovered as individual peers.

4. Add a peer using a bare Push URL (remove Kuma's example query string):

   ```bash
   read -r -s -p 'Bare Kuma Push URL: ' PUSH_URL; printf '\n'
   printf '%s\n' "$PUSH_URL" | sudo wireguard-uptime-monitor add \
     --server CA01 --ip 10.0.0.2 --push-url-file - --enabled yes
   unset PUSH_URL
   sudo wireguard-uptime-monitor test VPN-CA01-002
   sudo wireguard-uptime-monitor status
   ```

   Alternatively supply a private mode-600 URL file. Prefer HTTPS. HTTP is supported for trusted networks and sends tokens in clear text. New peers default to **disabled** and a **300-second threshold**.

## Peer management

Names use `VPN-{SERVER}-{LAST_OCTET_PADDED}`, for example `VPN-CA01-002` for `10.0.0.2` and `VPN-SG03-200` for `10.0.0.200`. Server identifiers use uppercase letters, digits and hyphens. Distinct peers need distinct names and separate Kuma Push monitors. Only IPv4 tunnel addresses are supported.

```bash
sudo wireguard-uptime-monitor enable VPN-CA01-002
sudo wireguard-uptime-monitor disable VPN-CA01-002
sudo wireguard-uptime-monitor set VPN-CA01-002 --threshold 300
sudo wireguard-uptime-monitor set VPN-CA01-002 --push-url-file /root/new-push-url
sudo wireguard-uptime-monitor list
```

Changes retain the failure history, private labels, TCP check and existing token unless you explicitly supply a replacement URL. Disabling pauses checks; it does not reset an outage timestamp. Time disabled counts toward an existing outage when re-enabled. `add` rejects conflicting existing names and accepts an identical repeated add. Use `set` or CSV updates for changes. `remove NAME` explicitly deletes that peer's configuration and failure history, and is safe to repeat; it does not delete the Kuma monitor.

For many peers, prepare a private CSV like [examples/peers.csv](examples/peers.csv):

```csv
name,ip,threshold,push_url,enabled
VPN-CA01-002,10.0.0.2,300,https://kuma.example.com/api/push/REPLACE_CA01,no
VPN-SG03-050,10.0.0.50,,https://kuma.example.com/api/push/REPLACE_SG03,no
```

```bash
chmod 600 peers.csv
sudo wireguard-uptime-monitor bulk-add --file peers.csv --dry-run
sudo wireguard-uptime-monitor bulk-add --file peers.csv
sudo wireguard-uptime-monitor enable-all --dry-run
sudo wireguard-uptime-monitor enable-all --yes
sudo wireguard-uptime-monitor disable-all --yes
```

CSV is a simple, unquoted format with a header. Columns may appear in any order; only `name` is mandatory in the header. New peers require `ip` and `push_url`. Omitted columns and empty fields preserve existing values; new rows default to threshold 300 and enabled `no`. For example, `name,threshold` updates thresholds without supplying tokens. `enabled` accepts `yes` or `no`. CRLF records and a final line without a newline are accepted; quoted fields, embedded commas, whitespace padding, duplicate columns/names, invalid addresses and invalid URLs are rejected. Existing names are updated, while repeated names within one CSV are rejected.

Every row is validated before any peer file is replaced. A validation failure changes no peers. Each replacement is atomic and private (mode 600); readers never see a partially written file. A batch is **not a filesystem-wide transaction**: interruption or a disk failure during commit can leave a completed subset. Re-running the same CSV is safe. Dry runs validate and stage temporary files, then remove them without changing peer files or monitoring state. Bulk enable/disable requires `--yes` or typing `yes` at an interactive prompt; dry runs need no confirmation.

## Monitoring and delivery

The timer runs every **60 seconds**. A healthy peer must answer one ICMP echo within two seconds, with a hard three-second process timeout. An optional `--tcp HOST:PORT` must also connect within three seconds. TCP supplements ICMP; it is not a fallback. Use a tunnel address to test a service through WireGuard. Idle handshake age is not a liveness check.

| Observation | Local state | Kuma action |
| --- | --- | --- |
| Healthy | `up`, failure timestamp cleared | Send `up` heartbeat |
| Unreachable, below threshold | `pending`, first failure time retained | Send nothing |
| Unreachable for at least threshold | `down`, first failure time retained | Send `down` heartbeat |
| Recovery | `up`, failure timestamp cleared | Send `up` immediately |

Each peer has an independent threshold. The default for new peers is **300 seconds**, measured from the first observed failure. Existing v0.1.0 files with `THRESHOLD=600` keep 600. Upgrades never rewrite peer configuration. Change selected thresholds explicitly with `set` or CSV.

Local health and Push delivery are separate. `status` shows `state`, `since`, `reported` (last successfully delivered health) and `delivery` (latest attempted delivery result). A failed recovery Push leaves `reported=down` until an `up` succeeds. No synthetic `up` is sent while pending, and no extra recovery transition is introduced after a delivery failure. Stable up/down heartbeats retain the same Kuma status. Discord notifications are managed by Kuma; this tool has no direct Discord integration.

Push requests have an eight-second total timeout and three-second connect timeout. Transient network errors and HTTP 408/429/500/502/503/504 retry up to **three total attempts**, with **one- and two-second backoff**. Permanent errors such as 401 do not retry within the pass. Failed peers are attempted again on the next pass. Logs include peer name, HTTP status, curl exit code and attempt; URLs, tokens, response bodies and raw curl errors are suppressed. Successful reporting requires a 2xx response. One failed peer never stops the others; the pass exits nonzero for configuration, state or delivery errors.

At most **eight peers run concurrently**, in bounded batches. Each peer uses at most approximately **33 seconds** of health/request/backoff time, so a worst-case pass is approximately `33 × ceil(peer_count / 8)` seconds, plus process and filesystem overhead. The monitor holds the write lock until every worker finishes. systemd skips overlapping ticks; it does not kill a long pass and repeatedly starve later peers. Large installations must allow for this pass duration in their alert timing.

**Pending sends no heartbeat.** Set Kuma's missing-push timeout longer than the largest peer threshold **plus scheduling/network margin**: for a 300-second threshold and a small installation, 420 seconds is an example starting point. A host outage or Kuma delivery outage can still trigger Kuma's missing-heartbeat alert independently of VPN health. Adjust the margin for your peer count and network. A new Kuma monitor can remain pending until the first up/down Push.

Failure timestamps persist across updates, exits and reboots. Time powered off counts toward a recorded outage. Backwards clock corrections reset a future failure timestamp to now; forward jumps can reach a threshold early. Keep the host clock synchronized. Corrupt state blocks that peer and produces a redacted diagnostic rather than silently resetting its history.

## CLI reference

```text
install
update --source CHECKOUT
uninstall
add --server SERVER --ip IPV4 --push-url-file FILE|-
    [--enabled yes|no] [--tcp HOST:PORT] [--threshold SECONDS]
    [--client LABEL] [--location LABEL]
bulk-add --file peers.csv [--dry-run]
enable NAME
disable NAME
set NAME [--threshold SECONDS] [--push-url-file FILE|-]
enable-all [--yes] [--dry-run]
disable-all [--yes] [--dry-run]
remove NAME
list
status
discover
test NAME
run
--help
--version
```

Run administrative commands with `sudo`. `test` checks even disabled peers without pushing or changing state; it exits 1 for an unreachable peer. `list` and `status` work during monitoring and do not take the write lock. Each file is read atomically; a listing across several files is not a single snapshot. Configuration writes, monitoring and installation share an exclusive nonblocking lock; if busy, retry after the pass finishes.

Peer files are literal `KEY=value` records, never sourced as shell code. See [the peer example](examples/VPN-CA01-002.conf). Unknown/duplicate keys and invalid values are rejected. Thresholds are positive integer seconds up to 9,999,999. Bare Push URLs use `http[s]://hostname[:port]/api/push/TOKEN`, with alphanumeric/underscore/hyphen tokens and no credentials, query, fragment or IPv6 host literal. URL ports are 1–65535. Optional TCP hosts are DNS names or IPv4 literals. Private `CLIENT` and `LOCATION` labels never appear in names, logs, status or Kuma messages.

## Safe v0.1.0 upgrade (when ready)

CA01 and SG03 can continue running v0.1.0 until you choose to upgrade. Publishing v0.2.0 to GitHub does not update installed copies or change either server. No immediate production action is required.

When ready, run the steps below on one host first, verify its status and journal, then repeat on the other host. From a clean checkout, fetch the published source with `git pull --ff-only` and review the changes before installation. Do not run the installer until you intend to upgrade that host.

Run on each host from the reviewed v0.2.0 checkout. These commands stop only this monitor's scheduling and wait for an active pass to finish; WireGuard remains running. If validation or installation fails, keep the timer stopped until the issue is resolved.

```bash
cd /absolute/path/to/wireguard-uptime-monitor
bash tests/check.sh
sudo systemctl stop wireguard-uptime-monitor.timer
# Wait for an in-flight pass to finish, without interrupting its state write.
sudo flock /run/lock/wireguard-uptime-monitor.lock true
sudo ./install.sh update
sudo wireguard-uptime-monitor --version
sudo wireguard-uptime-monitor status
sudo systemctl status wireguard-uptime-monitor.timer --no-pager
sudo journalctl -u wireguard-uptime-monitor.service -n 30 --no-pager
```

The installer re-enables this monitor's timer. An equivalent update entry point is `sudo wireguard-uptime-monitor update --source "$PWD"`. A manual monitor command can still contend for the lock after the wait; if installation reports a busy lock, let that pass finish and repeat the update.

Upgrades stage the program before atomically switching `current`, retaining all `/etc/wireguard-uptime-monitor/peers.d/` files and `/var/lib/wireguard-uptime-monitor/` state byte-for-byte during installation. v0.1.0 two-column states are readable; the next check retains the failure timestamp and adds delivery fields. Old states start with `reported=unknown` because v0.1.0 did not record successful delivery. Prior program releases remain under `releases/`; systemd unit replacement is not a transactional rollback.

`sudo wireguard-uptime-monitor uninstall` removes only this tool's program and units, retaining private configuration and state. To repeat uninstall after the command is removed, use `sudo ./install.sh uninstall` from the checkout. Retained data is never automatically purged.

## Files and troubleshooting

| Path | Purpose |
| --- | --- |
| `/etc/wireguard-uptime-monitor/peers.d/*.conf` | Private peer files, mode 600 |
| `/var/lib/wireguard-uptime-monitor/*.state` | Failure timestamp, observed health, reported health, delivery result |
| `/run/lock/wireguard-uptime-monitor.lock` | Exclusive monitor/configuration/installation lock |
| `/usr/local/lib/wireguard-uptime-monitor/current` | Active staged program |
| `/etc/systemd/system/wireguard-uptime-monitor.{service,timer}` | This tool's scheduler |

Configuration/state directories are mode 700. Secrets go to curl through stdin, not arguments. User curl configuration and redirects are disabled. Do not enable shell tracing or publish peer/CSV/state files. Treat the checkout and the isolated-test `WUM_ROOT` override as trusted root inputs.

Use `sudo journalctl -u wireguard-uptime-monitor.service -n 50` and `sudo wireguard-uptime-monitor test NAME` for diagnostics. `vpn=pending/down` describes reachability; `Push delivery failed` describes the separate HTTP path to Kuma. Check DNS, certificates and the private URL locally for delivery errors. Repair corrupt state after inspecting its failure history. Invalid peer files are skipped while other peers continue.

The service retains systemd filesystem protection, `NoNewPrivileges` and a private temporary directory. Inspect audit/journal output for custom SELinux or systemd restrictions instead of disabling protections.

## Development

```bash
sudo apt-get install -y shellcheck ripgrep
bash tests/check.sh
```

Tests use temporary roots and synthetic CA01/SG03 configuration and tokens. `ping`, TCP, curl, time, sleep, `wg` and `systemctl` are mocked; no real Kuma endpoints, WireGuard changes or live units are used. They cover thresholds, recovery delivery, retries, bulk validation/defaults, secret preservation, concurrency, locking and retained-data install/update/uninstall. Optional `WUM_V010_SOURCE=/path/to/v0.1.0/checkout bash tests/check.sh` also installs that historical source before upgrading. Linux uses real `flock`/`mv`; macOS tests use a Perl locking shim and native `mv` translation. These are test-only helpers. CI also verifies systemd units on Linux.
