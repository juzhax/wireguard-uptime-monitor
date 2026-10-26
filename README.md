# wireguard-uptime-monitor

Version **0.1.0** · MIT · Bash + systemd · Ubuntu, Debian, AlmaLinux and other systemd Linux distributions.

Monitor multiple explicitly enabled WireGuard peers from one installation and send health to Uptime Kuma Push monitors. No Docker, database, PHP, or Python runtime. This tool never changes WireGuard configuration or starts, stops, or restarts WireGuard.

## Install

1. Install dependencies on the machine with the WireGuard tunnel:

   ```bash
   # Ubuntu / Debian
   sudo apt-get update
   sudo apt-get install -y bash curl iputils-ping util-linux coreutils wireguard-tools

   # AlmaLinux (enable your distribution's WireGuard tools repository if needed)
   sudo dnf install -y bash curl iputils util-linux coreutils wireguard-tools
   ```

   A running systemd system, Bash 4+, and standard Linux tools (`awk`, `install`, `mktemp`, `date`, `cmp`) are required. `flock` comes from util-linux; `timeout` comes from coreutils. Packages may have different names on other distributions.

2. Clone and inspect the source, then install:

   ```bash
   git clone https://github.com/juzhax/wireguard-uptime-monitor.git
   cd wireguard-uptime-monitor
   sudo ./install.sh
   ```

   The installer does not download dependencies or execute a remote install script. It starts a 60-second timer, initially with no peers enabled. Repeat installation preserves existing configuration and state.

3. Find candidate tunnel addresses:

   ```bash
   sudo wireguard-uptime-monitor discover
   ```

   Discovery reads `wg show all dump` and displays interface, peer public key, and individual IPv4 `/32` allowed IPs. It discards interface private keys and peer preshared keys, never saves the dump, and never enables or adds peers automatically. Subnet routes cannot identify an individual peer's tunnel address; supply it manually. Version 0.1.0 uses IPv4 tunnel addresses for the naming convention; it does not discover IPv6 `/128` addresses.

4. In Kuma, create a **Push** monitor named `VPN-CA01-002`. Save its bare URL (remove the example `?status=up&msg=OK&ping=` query) to a private file, then add the peer:

   ```bash
   # Paste the bare Push URL into this prompt; input is hidden and stays out of shell history.
   read -r -s -p 'Bare Kuma Push URL: ' PUSH_URL; printf '\n'
   printf '%s\n' "$PUSH_URL" | sudo wireguard-uptime-monitor add \
     --server CA01 --ip 10.0.0.2 --push-url-file - --enabled yes
   unset PUSH_URL
   sudo wireguard-uptime-monitor test VPN-CA01-002
   sudo wireguard-uptime-monitor status
   ```

   Alternatively, `--push-url-file /root/kuma-push-url` reads a one-line file you create with mode 600. Prefer HTTPS; HTTP is supported for trusted local deployments but transmits the token in clear text. Kuma monitors must be created by the operator; this tool only sends pushes.

## Health and failure timing

A peer is healthy when its tunnel IPv4 address answers one ICMP echo within two seconds. If configured, `--tcp HOST:PORT` must also accept a TCP connection within three seconds. TCP is an additional requirement, not a fallback for blocked ICMP. Use a tunnel address for the TCP host to test a service through WireGuard; a public host only proves that host's reachability. Handshake age alone is not treated as liveness because idle peers may have old handshakes.

| Observation | Local state | Kuma action |
| --- | --- | --- |
| Successful check | `up`, failure timestamp cleared | Send `status=up` |
| First failure through threshold minus one second | `pending`, first failure time retained | **Send nothing** |
| Continuous failure for at least threshold seconds | `down`, first failure time retained | Send `status=down` |
| Successful check after pending/down | `up`, failure timestamp cleared | Send `status=up` immediately |

The default threshold is **600 seconds**, measured from the first observed failure. Every enabled peer has its own timer; a success resets only that peer's failure period. For example, failures observed at 12:00 and every minute thereafter produce `down` at approximately 12:10. Detection can be later because checks and pushes take time. Every subsequent failed check beyond the threshold repeats `down`; every successful check repeats `up`. Failed HTTP pushes produce a redacted error, leave health state intact, and retry the current observation next run. A failed push for one peer does not stop other peers.

**Pending never sends an `up` heartbeat.** Kuma may still display its previous status until its own missing-heartbeat timeout expires. Set the Kuma Push monitor's heartbeat interval and retry settings so its missing-push timeout is **longer than 600 seconds plus scheduling/network margin** (for example, 720 seconds with no retries), or longer than your largest custom threshold. Otherwise Kuma may alert before this tool's threshold. If the monitoring host dies or cannot reach Kuma, Kuma will alert on its own timeout. A newly created monitor may remain pending until the first healthy check or explicit down push. This tool does not send a separate Kuma pending status.

Failure timestamps are stored atomically under `/var/lib/wireguard-uptime-monitor/` and survive process exits, updates, and reboots. Time spent powered off counts toward an existing failure period; no observations can be made while the host is off. Wall-clock corrections backwards reset a future failure timestamp to the current time; forward jumps may reach the threshold early. Keep the host clock synchronized.

The timer uses `OnCalendar=*-*-* *:*:00` (every minute), `Persistent=true`, and `AccuracySec=1s`. A missed calendar tick is caught up once after downtime. systemd does not start a second copy of an active oneshot service; `flock` also protects manual runs and config edits. Checks run sequentially, so enough slow peers can extend a pass beyond a minute: ticks while the service is active are skipped, and checks resume on a subsequent minute. This lightweight release is intended for modest peer counts. There is no fixed service timeout that would repeatedly starve later peers.

## Names and private labels

Names are generated as `VPN-{SERVER}-{IP_LAST_OCTET_PADDED}`:

| Server | Tunnel IP | Monitor name |
| --- | --- | --- |
| CA01 | 10.0.0.2 | `VPN-CA01-002` |
| SG03 | 10.0.0.50 | `VPN-SG03-050` |
| SG03 | 10.0.0.200 | `VPN-SG03-200` |

Server identifiers accept uppercase letters, digits, and hyphens. Names are unique configuration IDs; use distinct server identifiers if two addresses would otherwise produce the same name. Kuma names are operator managed: use the generated name when creating each monitor.

`--client` and `--location` store optional private labels. They are never included in generated names, list/status output, logs, or Kuma messages. Public messages are only `Tunnel reachable` or `Tunnel unreachable beyond threshold`; tunnel IPs appear in local list/status/discovery output.

## CLI

Run administrative and monitoring commands with `sudo`:

```text
wireguard-uptime-monitor install [--migrate-legacy]
wireguard-uptime-monitor update --source /absolute/path/to/reviewed/checkout
wireguard-uptime-monitor uninstall
wireguard-uptime-monitor add --server SERVER --ip IPV4 --push-url-file FILE|- \
  [--enabled yes|no] [--tcp HOST:PORT] [--threshold SECONDS] \
  [--client LABEL] [--location LABEL]
wireguard-uptime-monitor remove NAME
wireguard-uptime-monitor list
wireguard-uptime-monitor test NAME
wireguard-uptime-monitor status
wireguard-uptime-monitor discover
wireguard-uptime-monitor run
wireguard-uptime-monitor --version
```

`add` defaults to **disabled** (`--enabled no`). Repeating an identical add is safe; conflicting changes are rejected. `test` runs reachability checks even for a disabled peer, without pushing or altering state. It exits 1 on failure. `list` and `status` show local observations, not confirmation that Kuma received a push; inspect the journal for delivery failures. Unknown observations display as `unknown`.

To change enablement, threshold, URL, or labels, edit the private config as root between runs, or remove and re-add the peer. Removing clears its failure history; direct edits retain history. To make several manual edits without a check running, stop **this tool's** timer and service first, then re-enable its timer. Never stop WireGuard. `remove` is safe to repeat and does not delete the Kuma monitor.

Configuration files are literal `KEY=value` records, not shell scripts: no quoting, interpolation, CRLF, or multiline values. See [the disabled example](examples/VPN-CA01-002.conf). Unknown or duplicate keys and invalid addresses, names, URLs, TCP ports, and thresholds are rejected. Supported Push URLs are `http[s]://hostname[:port]/api/push/TOKEN` with letters/digits/underscore/hyphen tokens and no query, fragment, credentials, or IPv6 host literals. Thresholds are positive integer seconds up to 9,999,999. Optional TCP hosts are DNS names or IPv4 literals.

## Upgrade and uninstall

1. Fetch and review the desired source revision in your local checkout. Run `bash tests/check.sh` with ShellCheck and ripgrep installed.
2. Run `sudo wireguard-uptime-monitor update --source /absolute/path/to/checkout` (or `sudo ./install.sh update` from that checkout).
3. Inspect `sudo wireguard-uptime-monitor status` and `sudo journalctl -u wireguard-uptime-monitor.service -n 30`.

Upgrades stage a complete release before atomically switching the installed `current` symlink. An in-flight check finishes with its existing files; the lock prevents an upgrade during that check. The timer remains enabled. Configuration, secrets, and failure history are preserved. Prior staged releases are retained under `/usr/local/lib/wireguard-uptime-monitor/releases/` for operator inspection; this is not a transactional rollback of systemd unit files.

`sudo wireguard-uptime-monitor uninstall` disables this tool's timer, stops its service, and removes its program and unit files. It preserves private configuration, state, and migration snapshots. Repeating uninstall from the checkout (`sudo ./install.sh uninstall`) is safe. To erase retained data permanently, inspect and remove `/etc/wireguard-uptime-monitor` and `/var/lib/wireguard-uptime-monitor` yourself.

## Existing `/opt/vpn-monitor` installations

The installer detects this directory and stops with a migration offer. It does not overwrite, source, execute, disable, or delete old files or jobs.

1. Inspect the existing files and scheduler yourself. Run `sudo ./install.sh --migrate-legacy` to save a private, one-time snapshot at `/var/lib/wireguard-uptime-monitor/legacy-backup`. Existing snapshots are never overwritten. The original directory remains untouched.
2. Recreate the intended peers using `add`, initially disabled. Legacy formats are unknown and are deliberately not interpreted as shell code. Verify each address using `test`; create separate Kuma Push monitors for a staged comparison if needed.
3. Stop the **legacy monitor's** cron job/timer/service after inspecting its actual name. Avoid two writers to the same Kuma URL. Enable the corresponding new peers and inspect the journal. This tool never stops legacy jobs automatically.

An acknowledged snapshot allows subsequent updates without asking again. Migration is operator-assisted configuration transfer, not automatic activation of legacy peers.

## Files, security, and troubleshooting

| Path | Purpose |
| --- | --- |
| `/etc/wireguard-uptime-monitor/peers.d/*.conf` | Root-private configuration; new files mode 600 |
| `/var/lib/wireguard-uptime-monitor/*.state` | First failure Unix timestamp and local state; mode 600 |
| `/run/lock/wireguard-uptime-monitor.lock` | Shared installation/configuration/execution lock |
| `/usr/local/lib/wireguard-uptime-monitor/current` | Active staged release |
| `/etc/systemd/system/wireguard-uptime-monitor.{service,timer}` | Scheduler and oneshot service |

Configuration/state directories use mode 700 and writes use umask 077. Push URLs go to curl over stdin as a validated config entry, not process arguments; parameters use `--data-urlencode`. User curl configuration is disabled with `-q`. Redirects are not followed, HTTP failures are detected, and curl diagnostics/responses are discarded to avoid leaking tokens. Root can still read secrets; do not enable Bash tracing or publish configuration/legacy backups. Treat the checkout and `WUM_ROOT` environment override as trusted root-level inputs. `WUM_ROOT` is intended for isolated installation tests, not arbitrary untrusted paths.

For diagnostics:

```bash
sudo systemctl status wireguard-uptime-monitor.timer
sudo journalctl -u wireguard-uptime-monitor.service -n 50
sudo wireguard-uptime-monitor test VPN-CA01-002
```

`pending` means reachability has failed but the threshold has not elapsed. `push failed` means curl could not complete a successful HTTP request: verify the private URL, DNS, certificates, and Kuma availability locally. `Another monitor ... is running` means the lock is busy; wait for that pass to finish. Invalid configuration is skipped with a redacted error; valid peers still run. A corrupt failure timestamp blocks that peer rather than silently discarding its history: inspect its state file and repair it or remove/re-add the peer. `status` remains a local view even if pushes fail.

The service runs as root for ping, WireGuard discovery, and private files, with `NoNewPrivileges`, filesystem protection, and a private temporary directory. ICMP/firewall policies can cause a reachable peer to fail checks. On hosts with additional SELinux or custom systemd policies, inspect audit/journal output if access is denied; do not disable those protections globally.

## Development and checks

```bash
# Ubuntu / Debian development tools
sudo apt-get install -y shellcheck ripgrep
bash tests/check.sh
```

Tests isolate all writes in a temporary `WUM_ROOT`, mock `ping`, `curl`, `wg`, time, TCP checks, and `systemctl`, and exercise health, persistence, independent thresholds, secrets, disabled peers, validation, actual inherited file locking, and installation lifecycle/migration. Linux uses real util-linux `flock` and coreutils `mv`; on macOS the tests use a Perl `flock` compatibility command and native `mv` flag translation. Perl is a macOS test-only helper, never a runtime dependency. The checks use Bash syntax validation plus ShellCheck. CI also runs `systemd-analyze verify` on Linux. Tests do not contact WireGuard or Kuma, install live units, or change the host scheduler.

Timer syntax follows the [systemd timer documentation](https://www.freedesktop.org/software/systemd/man/latest/systemd.timer.html); discovery uses the [WireGuard dump format](https://github.com/WireGuard/wireguard-tools/blob/master/src/man/wg.8).
