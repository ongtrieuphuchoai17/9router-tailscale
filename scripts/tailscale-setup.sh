#!/usr/bin/env bash
#
# Tailscale bootstrap for 9router — fully automatic.
#
# 1. Installs the static tailscale/tailscaled binaries into ~/.9router/bin/
#    (the exact path 9router probes as TAILSCALE_BIN) and symlinks them into
#    /usr/local/bin (what 9router spawns on Linux).
# 2. Starts tailscaled the way 9router does (sudo/root when available) and
#    grants the current user operator rights so `tailscale up` works.
# 3. If TAILSCALE_API_KEY or TAILSCALE_CLIENT_ID/SECRET is set, the Tailscale
#    API is used to enable MagicDNS + HTTPS + the `funnel` ACL attr (no browser
#    approval) and to mint an auth key. 9router itself does NOT support
#    TAILSCALE_AUTHKEY yet (PR #1348), so we pre-auth here.
# 4. Enables Tailscale via the 9router API, which persists tailscaleEnabled in
#    its settings DB -> auto-resumes on every 9router startup.
#
# Usage:
#   TAILSCALE_API_KEY=tskey-api-xxxx ./scripts/tailscale-setup.sh
#   TAILSCALE_CLIENT_ID=... TAILSCALE_CLIENT_SECRET=... ./scripts/tailscale-setup.sh
#   TAILSCALE_AUTHKEY=tskey-auth-xxxx ./scripts/tailscale-setup.sh
#
set -euo pipefail

DATA_DIR="${DATA_DIR:-$HOME/.9router}"
BIN_DIR="$DATA_DIR/bin"
TS_DIR="$DATA_DIR/tailscale"
SOCK="$TS_DIR/tailscaled.sock"
DAEMON_LOG="$TS_DIR/daemon.log"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# load .env so TAILSCALE_* are available even without being exported
if [[ -f "$SCRIPT_DIR/../.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/../.env"
  set +a
fi

mkdir -p "$BIN_DIR" "$TS_DIR"

# ---------------------------------------------------------------------------
# 1. Install binaries (static tarball — no sudo needed for the download)
# ---------------------------------------------------------------------------
install_binaries() {
  if [[ -x "$BIN_DIR/tailscale" && -x "$BIN_DIR/tailscaled" ]]; then
    echo "[1/4] binaries already present in $BIN_DIR"
  else
    echo "[1/4] downloading tailscale static binaries..."
    local arch=""
    case "$(uname -m)" in
      x86_64|amd64) arch="amd64" ;;
      aarch64|arm64) arch="arm64" ;;
      armv7l|armv6l|arm) arch="arm" ;;
      *) echo "unsupported arch: $(uname -m)" >&2; exit 1 ;;
    esac
    local ver
    ver="$(curl -fsSL 'https://pkgs.tailscale.com/stable/?mode=json' | grep -o '"TarballsVersion": *"[^"]*"' | head -1 | sed 's/.*"TarballsVersion": *"\([^"]*\)"/\1/')"
    local tmp
    tmp="$(mktemp -d)"
    curl -fsSL "https://pkgs.tailscale.com/stable/tailscale_${ver}_${arch}.tgz" -o "$tmp/ts.tgz"
    tar -xzf "$tmp/ts.tgz" -C "$tmp"
    cp "$tmp/tailscale_${ver}_${arch}/tailscale" "$BIN_DIR/tailscale"
    cp "$tmp/tailscale_${ver}_${arch}/tailscaled" "$BIN_DIR/tailscaled"
    chmod +x "$BIN_DIR/tailscale" "$BIN_DIR/tailscaled"
    rm -rf "$tmp"
    echo "    installed tailscale ${ver} -> $BIN_DIR"
  fi

  # 9router spawns tailscaled as root on Linux (sudo) — make sure it resolves.
  if command -v sudo >/dev/null 2>&1; then
    sudo ln -sf "$BIN_DIR/tailscaled" /usr/local/bin/tailscaled
    sudo ln -sf "$BIN_DIR/tailscale" /usr/local/bin/tailscale
    echo "    linked binaries into /usr/local/bin"
  fi
}

# ---------------------------------------------------------------------------
# 2. Start tailscaled the way 9router does, grant operator to $USER
# ---------------------------------------------------------------------------
start_daemon() {
  if pgrep -x tailscaled >/dev/null 2>&1; then
    echo "[2/4] tailscaled already running — reusing it"
    return
  fi
  echo "[2/4] starting tailscaled (root/TUN mode)..."
  if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    # match 9router: root daemon via sudo, no --tun flag (real TUN device)
    sudo -n tailscaled --socket="$SOCK" --statedir="$TS_DIR" >"$DAEMON_LOG" 2>&1 &
  else
    # no sudo: run as current user with userspace networking
    "$BIN_DIR/tailscaled" --socket="$SOCK" --statedir="$TS_DIR" --tun=userspace-networking >"$DAEMON_LOG" 2>&1 &
  fi
  for _ in $(seq 1 30); do
    [[ -S "$SOCK" ]] && break
    sleep 0.5
  done
  if [[ ! -S "$SOCK" ]]; then
    echo "    tailscaled failed to start (see $DAEMON_LOG)" >&2
    exit 1
  fi
  # non-root user needs operator rights to run `tailscale up`
  if [[ "$(id -u)" -ne 0 ]] && sudo -n true 2>/dev/null; then
    sudo -n tailscale --socket="$SOCK" set --operator="$USER" || true
  fi
  echo "    daemon up (socket: $SOCK)"
}

# ---------------------------------------------------------------------------
# 3. Resolve an auth key (API credentials -> mint key; else use TAILSCALE_AUTHKEY)
# ---------------------------------------------------------------------------
resolve_authkey() {
  if [[ -n "${TAILSCALE_AUTHKEY:-}" ]]; then
    echo "[3/5] using provided TAILSCALE_AUTHKEY"
    return
  fi
  if [[ -n "${TAILSCALE_API_KEY:-}" || ( -n "${TAILSCALE_CLIENT_ID:-}" && -n "${TAILSCALE_CLIENT_SECRET:-}" ) ]]; then
    echo "[3/5] configuring tailnet + minting auth key via Tailscale API..."
    TAILSCALE_AUTHKEY="$(node "$SCRIPT_DIR/tailscale-autoconfigure.mjs")"
    return
  fi
  echo "[3/5] no TAILSCALE_API_KEY / OAuth client / TAILSCALE_AUTHKEY set -> interactive login will be needed"
}

# ---------------------------------------------------------------------------
# 4. Headless pre-auth with the auth key (optional)
# ---------------------------------------------------------------------------
preauth() {
  if [[ -z "${TAILSCALE_AUTHKEY:-}" ]]; then
    echo "[4/5] no auth key -> interactive login will be needed"
    return
  fi
  echo "[4/5] pre-authenticating (headless)..."
  local tscmd=("$BIN_DIR/tailscale" --socket="$SOCK")
  if [[ "$(id -u)" -ne 0 ]] && sudo -n true 2>/dev/null; then
    tscmd=(sudo -n tailscale --socket="$SOCK")
  fi
  local tags=()
  if [[ -n "${TAILSCALE_TAGS:-}" ]]; then
    read -r -a tags <<< "$(echo "$TAILSCALE_TAGS" | tr ',' ' ')"
  fi
  "${tscmd[@]}" up \
    --auth-key="${TAILSCALE_AUTHKEY}" \
    --hostname="${TAILSCALE_HOSTNAME:-9router}" \
    --accept-routes \
    --operator="$USER" \
    "${tags[@]/#/--advertise-tags=}"
}

# ---------------------------------------------------------------------------
# 5. Enable via 9router API -> after login it persists tailscaleEnabled=true
# ---------------------------------------------------------------------------
enable() {
  echo "[5/5] enabling tailscale via 9router API..."
  local out
  out="$(node "$SCRIPT_DIR/tunnel.mjs" tailscale-enable || true)"
  echo "$out"
  local enable_url
  enable_url="$(echo "$out" | grep -o '"enableUrl": *"[^"]*"' | head -1 | sed 's/.*"enableUrl": *"\([^"]*\)"/\1/')"
  if [[ -n "$enable_url" ]]; then
    echo
    echo "NOTE: Funnel still requires approval in the Tailscale admin console."
    echo "Open: $enable_url"
  fi
}

install_binaries
start_daemon
resolve_authkey
preauth
enable
