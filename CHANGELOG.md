# Changelog

## 0.2.0

- Remove obsolete installer migration functionality, documentation and tests.
- Add validated CSV bulk configuration with dry runs, enable/disable/set, and confirmed bulk enablement changes.
- Preserve existing tokens, labels, thresholds and failure history; replace configuration and state files atomically.
- Default new peers to a 300-second threshold; retain the 60-second timer and per-peer thresholds.
- Track observed health separately from acknowledged Push delivery; retry transient failures with bounded backoff and redacted HTTP/curl diagnostics.
- Check up to eight peers concurrently, continue after failures, and allow list/status during monitoring.
- Test v0.1.0 CA01/SG03 compatibility, updates, bulk operations, locking and delivery failures using synthetic endpoints.

## 0.1.0

- Explicit per-peer enablement, safe WireGuard discovery, standard VPN names, and private labels.
- ICMP and optional TCP health checks with persistent failure thresholds and Kuma Push reporting.
- Private configuration, encoded push parameters, URL redaction, and execution locking.
- systemd scheduling, staged installs/upgrades, retained-state uninstall.
- Mocked integration tests, ShellCheck validation, Linux CI, examples, and MIT license.
