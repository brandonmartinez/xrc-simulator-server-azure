#!/bin/bash
# setup-xrc.sh - Install/configure xRC Simulator on the VM
# Template variables (substituted by envsubst in deploy.sh):
#   ${XRC_ADMIN_USERNAME} - Linux user to run the server
#   ${XRC_DOWNLOAD_URL}   - URL to download xRC server zip
#   ${XRC_GAME_PORT}      - UDP port for game traffic
#   ${XRC_SERVER_PASSWORD} - Server join password
#   ${XRC_SERVER_USERNAME} - Admin username for chat commands
#   ${XRC_GAME}           - Game number (0-22)
#   ${XRC_WEB_ADMIN_PORT} - Web admin port (default 8080)
#   ${XRC_WEB_ADMIN_BIND} - Web admin bind address (default 0.0.0.0)
set -e

INSTALL_DIR="/opt/xrc-simulator"
RUN_USER="${XRC_ADMIN_USERNAME}"

echo "=== xRC Simulator Setup ==="

# Install dependencies
apt-get update -qq
apt-get install -y -qq unzip wget screen htop > /dev/null

# Stop existing service if running
systemctl stop xrc-simulator 2>/dev/null || true

# Create install directory
mkdir -p "$INSTALL_DIR"
chown "$RUN_USER:$RUN_USER" "$INSTALL_DIR"

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
    echo "xRC Simulator downloaded and extracted"
else
    echo "No download URL provided - skipping download"
fi

# Write server config (sourced by runserver.sh at runtime)
cat > "$INSTALL_DIR/server.env" << EOF
XRC_PORT=${XRC_GAME_PORT}
XRC_PASSWORD=${XRC_SERVER_PASSWORD}
XRC_ADMIN=${XRC_SERVER_USERNAME}
XRC_GAME=${XRC_GAME:-22}
EOF
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
  comment="xRC Azure Server" \
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

    # Configure sudoers for web admin (limited systemctl access)
    cat > /etc/sudoers.d/xrc-web-admin << ENDSUDOERS
# Allow xRC admin user to manage the xrc-simulator service
$RUN_USER ALL=NOPASSWD: /bin/systemctl start xrc-simulator
$RUN_USER ALL=NOPASSWD: /bin/systemctl stop xrc-simulator
$RUN_USER ALL=NOPASSWD: /bin/systemctl restart xrc-simulator
$RUN_USER ALL=NOPASSWD: /bin/systemctl is-active xrc-simulator
$RUN_USER ALL=NOPASSWD: /bin/journalctl -u xrc-simulator *
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
    systemctl enable --now xrc-web-admin
    echo "xRC Web Admin service started on port ${XRC_WEB_ADMIN_PORT:-8080}"
fi

echo "=== xRC Simulator setup complete ==="
