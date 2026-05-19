#!/bin/bash
# setup-xrc.sh - Install/configure xRC Simulator on the VM
# Template variables (substituted by envsubst in deploy.sh):
#   ${XRC_ADMIN_USERNAME}        - Linux user to run the server
#   ${XRC_DOWNLOAD_URL}          - URL to download xRC server zip
#   ${XRC_GAME_PORT}             - UDP port for game traffic
#   ${XRC_SERVER_PASSWORD}       - Server join password
#   ${XRC_SERVER_USERNAME}       - Admin username for chat commands
#   ${XRC_GAME}                  - Game number (0-22)
#   ${XRC_SERVER_NAME}           - Display name in the xRC server browser
#   ${XRC_WEB_ADMIN_PORT}        - Web admin port (default 8080)
#   ${XRC_WEB_ADMIN_BIND}        - Web admin bind address (default 0.0.0.0)
#   ${XRC_BACKUP_RETENTION}      - Number of previous installs to keep (default 3)
#   ${XRC_DAILY_RESTART_ENABLED} - true/false: install daily restart timer
#   ${XRC_DAILY_RESTART_TIME}    - HH:MM (America/New_York) for daily restart
set -e

INSTALL_DIR="/opt/xrc-simulator"
BACKUPS_DIR="/opt/xrc-simulator-backups"
RUN_USER="${XRC_ADMIN_USERNAME}"

echo "=== xRC Simulator Setup ==="

# Install dependencies
apt-get update -qq
apt-get install -y -qq unzip wget screen htop > /dev/null

# Stop existing service if running
systemctl stop xrc-simulator 2>/dev/null || true

# Create install + backups directories
mkdir -p "$INSTALL_DIR" "$BACKUPS_DIR"
chown "$RUN_USER:$RUN_USER" "$INSTALL_DIR" "$BACKUPS_DIR"

# Derive installed version from the download URL filename (best-effort).
# Matches e.g. xRC_Linux_Server_v19.2c.zip -> 19.2c
INSTALLED_VERSION="unknown"
if [ -n "${XRC_DOWNLOAD_URL}" ]; then
    DERIVED=$(printf '%s' "${XRC_DOWNLOAD_URL}" \
        | grep -oE 'xRC_Linux_Server_v[0-9]+\.[0-9]+[a-z]?\.zip' \
        | sed -E 's/^xRC_Linux_Server_v([0-9]+\.[0-9]+[a-z]?)\.zip$/\1/' \
        | head -1)
    [ -n "$DERIVED" ] && INSTALLED_VERSION="$DERIVED"
fi

# Download and extract if URL provided
if [ -n "${XRC_DOWNLOAD_URL}" ]; then
    echo "Downloading xRC Simulator from: ${XRC_DOWNLOAD_URL}"
    wget -q -O "$INSTALL_DIR/xrc-server.zip" "${XRC_DOWNLOAD_URL}"
    cd "$INSTALL_DIR"
    unzip -o xrc-server.zip
    rm -f xrc-server.zip
    chmod +x "$INSTALL_DIR"/*.x86_64 2>/dev/null || true
    chmod +x "$INSTALL_DIR"/*.sh 2>/dev/null || true
    chown -R "$RUN_USER:$RUN_USER" "$INSTALL_DIR"
    echo "xRC Simulator downloaded and extracted (version: $INSTALLED_VERSION)"
else
    echo "No download URL provided - skipping download"
fi

# Write server config (sourced by runserver.sh at runtime).
# Preserve XRC_INSTALLED_VERSION / XRC_INSTALLED_URL / XRC_SERVER_NAME if the
# web UI has already updated them (i.e. this is a re-deploy and the user has
# updated the server via the web UI since the last `./deploy.sh`).
EXISTING_INSTALLED_VERSION=""
EXISTING_INSTALLED_URL=""
EXISTING_SERVER_NAME=""
if [ -f "$INSTALL_DIR/server.env" ]; then
    # `eval` lets us read shell-quoted values written by us / the web admin.
    # shellcheck disable=SC1090
    EXISTING_INSTALLED_VERSION=$( (set +u; . "$INSTALL_DIR/server.env"; printf '%s' "${XRC_INSTALLED_VERSION:-}") || true)
    EXISTING_INSTALLED_URL=$( (set +u; . "$INSTALL_DIR/server.env"; printf '%s' "${XRC_INSTALLED_URL:-}") || true)
    EXISTING_SERVER_NAME=$( (set +u; . "$INSTALL_DIR/server.env"; printf '%s' "${XRC_SERVER_NAME:-}") || true)
fi
# If we just re-downloaded, the freshly installed bits win.
if [ -n "${XRC_DOWNLOAD_URL}" ]; then
    EFFECTIVE_INSTALLED_VERSION="$INSTALLED_VERSION"
    EFFECTIVE_INSTALLED_URL="${XRC_DOWNLOAD_URL}"
else
    EFFECTIVE_INSTALLED_VERSION="${EXISTING_INSTALLED_VERSION:-$INSTALLED_VERSION}"
    EFFECTIVE_INSTALLED_URL="${EXISTING_INSTALLED_URL:-${XRC_DOWNLOAD_URL}}"
fi
# Server name: prefer existing (web-UI-edited) value, fall back to .env value.
EFFECTIVE_SERVER_NAME="${EXISTING_SERVER_NAME:-${XRC_SERVER_NAME:-xRC Azure Server}}"

# Single-quote a value for safe sourcing by bash. Escapes embedded single quotes.
shq() {
    local s=${1//\'/\'\\\'\'}
    printf "'%s'" "$s"
}

{
    printf 'XRC_PORT=%s\n'                  "$(shq "${XRC_GAME_PORT}")"
    printf 'XRC_PASSWORD=%s\n'              "$(shq "${XRC_SERVER_PASSWORD}")"
    printf 'XRC_ADMIN=%s\n'                 "$(shq "${XRC_SERVER_USERNAME}")"
    printf 'XRC_GAME=%s\n'                  "$(shq "${XRC_GAME:-22}")"
    printf 'XRC_SERVER_NAME=%s\n'           "$(shq "${EFFECTIVE_SERVER_NAME}")"
    printf 'XRC_INSTALLED_VERSION=%s\n'     "$(shq "${EFFECTIVE_INSTALLED_VERSION}")"
    printf 'XRC_INSTALLED_URL=%s\n'         "$(shq "${EFFECTIVE_INSTALLED_URL}")"
    printf 'XRC_BACKUP_RETENTION=%s\n'      "$(shq "${XRC_BACKUP_RETENTION:-3}")"
} > "$INSTALL_DIR/server.env"
chown "$RUN_USER:$RUN_USER" "$INSTALL_DIR/server.env"
echo "server.env written"

# Generate runserver.sh (sources server.env for config)
cat > "$INSTALL_DIR/runserver.sh" << 'ENDSCRIPT'
#!/bin/bash
cd /opt/xrc-simulator
SERVER_BIN=$(find . -name "*.x86_64" -type f | head -1)
if [ -z "$SERVER_BIN" ]; then
  echo "ERROR: No server binary found in /opt/xrc-simulator/"
  exit 1
fi
chmod +x "$SERVER_BIN"
kill $(pgrep xRC) 2>/dev/null || true
grep -a "[0-9]" log.txt >> log_old.txt 2>/dev/null || true
source /opt/xrc-simulator/server.env
echo "Starting xRC Simulator Server: $SERVER_BIN on port $XRC_PORT (game=${XRC_GAME:-22})"
exec "$SERVER_BIN" \
  -batchmode -nographics \
  RouterPort=$XRC_PORT \
  Port=$XRC_PORT \
  game=${XRC_GAME:-22} \
  FrameRate=60 \
  tmode=On \
  register=On \
  Spectators=2 \
  minplayers=2 \
  updatetime=20 \
  maxdata=99000 \
  startwhenready=On \
  comment="${XRC_SERVER_NAME:-xRC Azure Server}" \
  password="$XRC_PASSWORD" \
  admin="$XRC_ADMIN"
ENDSCRIPT
chmod +x "$INSTALL_DIR/runserver.sh"
chown "$RUN_USER:$RUN_USER" "$INSTALL_DIR/runserver.sh"
echo "runserver.sh written"

# Create/update systemd service
cat > /etc/systemd/system/xrc-simulator.service << ENDSERVICE
[Unit]
Description=xRC Simulator Game Server
After=network.target

[Service]
Type=simple
User=$RUN_USER
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/runserver.sh
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
ENDSERVICE
systemctl daemon-reload
echo "systemd service configured"

# Start service if binary exists
if find "$INSTALL_DIR" -name "*.x86_64" -type f | grep -q .; then
    systemctl enable --now xrc-simulator
    echo "xRC Simulator service started"
else
    echo "No server binary found - service configured but not started"
fi

# --- Web Admin Setup ---

# Install web-admin script
cp /tmp/web-admin.py "$INSTALL_DIR/web-admin.py" 2>/dev/null || true
if [ ! -f "$INSTALL_DIR/web-admin.py" ]; then
    echo "WARNING: web-admin.py not found - skipping web admin setup"
else
    chown "$RUN_USER:$RUN_USER" "$INSTALL_DIR/web-admin.py"
    chmod +x "$INSTALL_DIR/web-admin.py"

    # Install the privileged filesystem helper used by the web admin to
    # perform the install-dir swap during updates. /opt is root-owned so
    # the unprivileged web admin cannot rename /opt/xrc-simulator itself;
    # this helper is the only thing it is allowed to invoke via sudo to
    # mutate that path, and it strictly validates its arguments so the
    # sudoers grant cannot be leveraged into arbitrary filesystem writes.
    cat > /usr/local/sbin/xrc-fs-helper << 'ENDHELPER'
#!/bin/bash
# xrc-fs-helper - privileged install-dir swap operations for web-admin.
# All timestamp arguments are validated against a strict regex; the only
# paths ever touched are /opt/xrc-simulator and well-formed entries
# directly under /opt/xrc-simulator-backups.
set -e
INSTALL_DIR=/opt/xrc-simulator
BACKUPS_DIR=/opt/xrc-simulator-backups
TS_RE='^[0-9]{8}T[0-9]{6}Z$'

usage() {
    echo "usage: $0 {swap-out|swap-in|restore|discard-old|discard-failed} <timestamp>" >&2
    exit 2
}

[ $# -eq 2 ] || usage
cmd=$1
ts=$2
[[ $ts =~ $TS_RE ]] || { echo "invalid timestamp: $ts" >&2; exit 2; }

old="$BACKUPS_DIR/old-$ts"
staging="$BACKUPS_DIR/staging-$ts"
failed="$BACKUPS_DIR/failed-$ts"

case "$cmd" in
    swap-out)
        # Move the live install aside so a new one can take its place.
        [ -d "$INSTALL_DIR" ] || { echo "install dir missing" >&2; exit 1; }
        [ ! -e "$old" ] || { echo "old dir already exists" >&2; exit 1; }
        mv -T "$INSTALL_DIR" "$old"
        ;;
    swap-in)
        # Promote staging-<ts> to be the live install.
        [ -d "$staging" ] || { echo "staging dir missing" >&2; exit 1; }
        [ ! -e "$INSTALL_DIR" ] || { echo "install dir already exists" >&2; exit 1; }
        mv -T "$staging" "$INSTALL_DIR"
        ;;
    restore)
        # Roll back: if a (broken) live install is present, move it aside
        # to failed-<ts> first so we never delete data before the restore
        # is safely in place. Then move old-<ts> back into position.
        [ -d "$old" ] || { echo "old dir missing" >&2; exit 1; }
        if [ -e "$INSTALL_DIR" ]; then
            [ ! -e "$failed" ] || { echo "failed dir already exists" >&2; exit 1; }
            mv -T "$INSTALL_DIR" "$failed"
        fi
        mv -T "$old" "$INSTALL_DIR"
        ;;
    discard-old)
        # Clean up old-<ts> after a successful update.
        [ -d "$old" ] && rm -rf -- "$old"
        ;;
    discard-failed)
        # Clean up failed-<ts> after the user (or stale-cleanup) decides
        # the failed install is no longer needed for inspection.
        [ -d "$failed" ] && rm -rf -- "$failed"
        ;;
    *)
        usage
        ;;
esac
ENDHELPER
    chown root:root /usr/local/sbin/xrc-fs-helper
    chmod 0755 /usr/local/sbin/xrc-fs-helper

    # Configure sudoers for web admin (limited systemctl access + the
    # filesystem helper above).
    cat > /etc/sudoers.d/xrc-web-admin << ENDSUDOERS
# Allow xRC admin user to manage the xrc-simulator service
$RUN_USER ALL=NOPASSWD: /bin/systemctl start xrc-simulator
$RUN_USER ALL=NOPASSWD: /bin/systemctl stop xrc-simulator
$RUN_USER ALL=NOPASSWD: /bin/systemctl restart xrc-simulator
$RUN_USER ALL=NOPASSWD: /bin/systemctl is-active xrc-simulator
$RUN_USER ALL=NOPASSWD: /bin/journalctl -u xrc-simulator *
# Allow the web admin to manage the update lockfile used to coordinate
# with the daily-restart timer.
$RUN_USER ALL=NOPASSWD: /usr/bin/touch /run/xrc-update.lock
$RUN_USER ALL=NOPASSWD: /bin/rm -f /run/xrc-update.lock
# Allow the web admin to perform the privileged install-dir swap. The
# helper strictly validates its own arguments, so the wildcard here
# cannot be leveraged into arbitrary filesystem writes.
$RUN_USER ALL=NOPASSWD: /usr/local/sbin/xrc-fs-helper *
ENDSUDOERS
    chmod 0440 /etc/sudoers.d/xrc-web-admin
    echo "sudoers configured for web admin"

    # Create web admin systemd service
    cat > /etc/systemd/system/xrc-web-admin.service << ENDWEBSERVICE
[Unit]
Description=xRC Simulator Web Admin
After=network.target

[Service]
Type=simple
User=$RUN_USER
WorkingDirectory=$INSTALL_DIR
Environment=WEB_ADMIN_PORT=${XRC_WEB_ADMIN_PORT:-8080}
Environment=WEB_ADMIN_BIND=${XRC_WEB_ADMIN_BIND:-0.0.0.0}
ExecStart=/usr/bin/python3 $INSTALL_DIR/web-admin.py
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
ENDWEBSERVICE
    systemctl daemon-reload
    systemctl enable xrc-web-admin
    # Explicit restart: `enable --now` is a no-op for an already-active
    # unit, which would leave stale web-admin.py code running on redeploy.
    systemctl restart xrc-web-admin
    echo "xRC Web Admin service (re)started on port ${XRC_WEB_ADMIN_PORT:-8080}"
fi

# --- Daily Auto-Restart Timer ---

RESTART_SERVICE_PATH="/etc/systemd/system/xrc-simulator-restart.service"
RESTART_TIMER_PATH="/etc/systemd/system/xrc-simulator-restart.timer"

if [ "${XRC_DAILY_RESTART_ENABLED:-true}" = "true" ]; then
    # Default to 04:00 if not set or malformed
    RESTART_TIME="${XRC_DAILY_RESTART_TIME:-04:00}"
    if ! printf '%s' "$RESTART_TIME" | grep -qE '^[0-2][0-9]:[0-5][0-9]$'; then
        echo "WARNING: XRC_DAILY_RESTART_TIME='${RESTART_TIME}' is not HH:MM; falling back to 04:00"
        RESTART_TIME="04:00"
    fi

    cat > "$RESTART_SERVICE_PATH" << ENDRESTARTSVC
[Unit]
Description=Daily restart of xRC Simulator (mitigates engine memory/physics drift)
After=xrc-simulator.service

[Service]
Type=oneshot
# Skip the restart if a web-UI-triggered update is in progress.
# The web admin creates /run/xrc-update.lock while swapping the install.
ExecStart=/bin/sh -c '[ ! -e /run/xrc-update.lock ] && /bin/systemctl restart xrc-simulator || /bin/echo "xRC update in progress; skipping scheduled restart"'
ENDRESTARTSVC

    cat > "$RESTART_TIMER_PATH" << ENDRESTARTTIMER
[Unit]
Description=Run xRC Simulator daily restart at ${RESTART_TIME} America/New_York

[Timer]
OnCalendar=*-*-* ${RESTART_TIME}:00 America/New_York
Persistent=true
Unit=xrc-simulator-restart.service

[Install]
WantedBy=timers.target
ENDRESTARTTIMER

    systemctl daemon-reload
    systemctl enable --now xrc-simulator-restart.timer
    echo "Daily restart timer enabled at ${RESTART_TIME} America/New_York"
else
    # Disable and remove the timer/service if previously installed.
    systemctl disable --now xrc-simulator-restart.timer 2>/dev/null || true
    rm -f "$RESTART_TIMER_PATH" "$RESTART_SERVICE_PATH"
    systemctl daemon-reload
    echo "Daily restart timer disabled"
fi

echo "=== xRC Simulator setup complete ==="
