#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
scripts=(install.sh bin/wireguard-uptime-monitor lib/common.sh tests/run.sh tests/check.sh)
for script in "${scripts[@]}"; do bash -n "$script"; done
shellcheck -x "${scripts[@]}"
bash tests/run.sh
