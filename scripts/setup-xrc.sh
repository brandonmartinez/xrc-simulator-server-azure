#!/bin/bash
# setup-xrc.sh - Install/configure xRC Simulator on the VM
# Template variables (substituted by envsubst in deploy.sh):
#   ${XRC_ADMIN_USERNAME} - Linux user to run the server
#   ${XRC_DOWNLOAD_URL}   - URL to download xRC server zip
#   ${XRC_GAME_PORT}      - UDP port for game traffic
#   ${XRC_SERVER_PASSWORD} - Server join password
#   ${XRC_SERVER_USERNAME} - Admin username for chat commands
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
echo "Starting xRC Simulator Server: $SERVER_BIN on port $XRC_PORT"
exec "$SERVER_BIN" \
  -batchmode -nographics \
  RouterPort=$XRC_PORT \
  Port=$XRC_PORT \
  game=22 \
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

echo "=== xRC Simulator setup complete ==="
