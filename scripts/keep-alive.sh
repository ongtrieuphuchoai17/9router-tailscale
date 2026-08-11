#!/usr/bin/env bash
# Keep-alive supervisor: ensures 9Router is running and its public tunnel is up.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
LOG_DIR="$ROOT_DIR/logs"
mkdir -p "$LOG_DIR"
SUPERVISOR_LOG="$LOG_DIR/keepalive.log"
PID_FILE="$LOG_DIR/9router.pid"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$SUPERVISOR_LOG"; }

log "keep-alive supervisor started (pid $$)"

while true; do
  if ! ss -ltn 2>/dev/null | grep -q ":20128 "; then
    log "9Router not listening on :20128 — restarting..."
    rm -f "$PID_FILE"
    setsid nohup node "$ROOT_DIR/start.mjs" -l > "$LOG_DIR/9router.log" 2>&1 < /dev/null &
    echo $! > "$PID_FILE"
    # wait for the server to come up before enabling the tunnel
    for i in $(seq 1 60); do
      sleep 1
      if ss -ltn 2>/dev/null | grep -q ":20128 "; then
        log "9Router is listening after ${i}s"
        break
      fi
    done
    sleep 5
    log "enabling public tunnel..."
    node "$ROOT_DIR/scripts/tunnel.mjs" enable >> "$SUPERVISOR_LOG" 2>&1 || true
    sleep 10
    node "$ROOT_DIR/scripts/tunnel.mjs" status >> "$SUPERVISOR_LOG" 2>&1 || true
    log "enabling tailscale..."
    node "$ROOT_DIR/scripts/tunnel.mjs" tailscale-enable >> "$SUPERVISOR_LOG" 2>&1 || true
    sleep 10
    node "$ROOT_DIR/scripts/tunnel.mjs" tailscale-status >> "$SUPERVISOR_LOG" 2>&1 || true
  fi

  # keep the tunnel alive (cheap status check every cycle)
  RUNNING=$(node "$ROOT_DIR/scripts/tunnel.mjs" status 2>/dev/null | grep -o '"running": *true' | head -1)
  if [ -z "$RUNNING" ]; then
    log "tunnel not running — re-enabling..."
    node "$ROOT_DIR/scripts/tunnel.mjs" enable >> "$SUPERVISOR_LOG" 2>&1 || true
  fi

  # keep tailscale alive (daemon must be running and logged in)
  TS_CHECK=$(node "$ROOT_DIR/scripts/tunnel.mjs" tailscale-check 2>/dev/null)
  TS_RUNNING=$(echo "$TS_CHECK" | grep -o '"customDaemonRunning": *true' | head -1)
  TS_LOGGED=$(echo "$TS_CHECK" | grep -o '"loggedIn": *true' | head -1)
  if [ -z "$TS_RUNNING" ] || [ -z "$TS_LOGGED" ]; then
    log "tailscale not running — re-enabling..."
    node "$ROOT_DIR/scripts/tunnel.mjs" tailscale-enable >> "$SUPERVISOR_LOG" 2>&1 || true
  fi

  sleep 30
done
