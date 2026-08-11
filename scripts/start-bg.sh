#!/usr/bin/env bash
# Start 9Router in the background (keeps running after the terminal closes).
# Logs go to logs/9router.log; PID is stored in logs/9router.pid.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
LOG_DIR="$ROOT_DIR/logs"
mkdir -p "$LOG_DIR"

if [ -f "$LOG_DIR/9router.pid" ] && kill -0 "$(cat "$LOG_DIR/9router.pid")" 2>/dev/null; then
  echo "9Router is already running (pid $(cat "$LOG_DIR/9router.pid")). Use: npm run stop"
  exit 0
fi

nohup node "$ROOT_DIR/start.mjs" -l > "$LOG_DIR/9router.log" 2>&1 &
echo $! > "$LOG_DIR/9router.pid"
echo "9Router started in background (pid $!). Logs: logs/9router.log"
