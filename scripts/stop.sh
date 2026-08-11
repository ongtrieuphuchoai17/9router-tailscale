#!/usr/bin/env bash
# Stop the background 9Router process started by scripts/start-bg.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
LOG_DIR="$ROOT_DIR/logs"
PID_FILE="$LOG_DIR/9router.pid"

# Stop the keep-alive supervisor first (so it doesn't restart the app)
pkill -f "scripts/keep-alive.sh" 2>/dev/null || true

# Disable the public tunnel
node "$ROOT_DIR/scripts/tunnel.mjs" disable > /dev/null 2>&1 || true

if [ ! -f "$PID_FILE" ]; then
  echo "No PID file found at $PID_FILE"
  exit 0
fi

PID="$(cat "$PID_FILE")"
if kill -0 "$PID" 2>/dev/null; then
  kill "$PID"
  echo "Stopped 9Router launcher (pid $PID)"
else
  echo "Process $PID is not running"
fi
rm -f "$PID_FILE"

# Kill the 9Router CLI daemon and Next.js server if still alive
pkill -f "node .*9router" 2>/dev/null || true
pkill -f "next-server" 2>/dev/null || true
echo "Stopped 9Router server."
