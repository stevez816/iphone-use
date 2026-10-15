#!/bin/zsh
# Read-only diagnostics. Does not pair, reset Bluetooth, or send input.
set -euo pipefail
port="${IPHONE_USE_PORT:-7390}"
sw_vers
curl --fail --show-error --max-time 5 "http://127.0.0.1:${port}/status" || true
printf '\n'
/usr/bin/log show --last 15m --style compact --info \
  --predicate 'subsystem == "ai.new-wave.iphone-use"' 2>/dev/null
