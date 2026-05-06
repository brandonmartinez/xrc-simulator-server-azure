#!/bin/bash
# deploy.sh - Deploy xRC Simulator Server to Azure
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== xRC Simulator Server - Azure Deployment ==="
echo ""

# Load environment configuration
if [[ ! -f "$SCRIPT_DIR/.env" ]]; then
    echo "ERROR: .env file not found!"
    echo "Copy .env.sample to .env and configure your settings:"
    echo "  cp .env.sample .env"
    exit 1
fi

set -a
source "$SCRIPT_DIR/.env"
set +a

# Validate required settings
if [[ -z "${LOCATION:-}" ]]; then echo "ERROR: LOCATION not set in .env"; exit 1; fi
if [[ -z "${RESOURCE_GROUP:-}" ]]; then echo "ERROR: RESOURCE_GROUP not set in .env"; exit 1; fi
if [[ -z "${VM_NAME:-}" ]]; then echo "ERROR: VM_NAME not set in .env"; exit 1; fi
if [[ -z "${ADMIN_USERNAME:-}" ]]; then echo "ERROR: ADMIN_USERNAME not set in .env"; exit 1; fi
if [[ -z "${SSH_PUBLIC_KEY_PATH:-}" ]]; then echo "ERROR: SSH_PUBLIC_KEY_PATH not set in .env"; exit 1; fi

# Expand tilde in SSH key path
SSH_PUBLIC_KEY_PATH="${SSH_PUBLIC_KEY_PATH/#\~/$HOME}"

if [[ ! -f "$SSH_PUBLIC_KEY_PATH" ]]; then
    echo "ERROR: SSH public key not found at: $SSH_PUBLIC_KEY_PATH"
    echo "Generate one with: ssh-keygen -t rsa -b 4096"
    exit 1
fi

SSH_PUBLIC_KEY=$(cat "$SSH_PUBLIC_KEY_PATH")

# Check Azure CLI login
echo "Checking Azure CLI login status..."
if ! az account show &> /dev/null; then
    echo "ERROR: Not logged in to Azure CLI."
    echo "Run ./login.sh first to authenticate."
    exit 1
fi
echo "✓ Logged in to Azure"
echo ""

# Display deployment configuration
echo "Deployment Configuration:"
echo "  Location:       $LOCATION"
echo "  Resource Group: $RESOURCE_GROUP"
echo "  VM Name:        $VM_NAME"
echo "  VM Size:        ${VM_SIZE:-Standard_B2s}"
echo "  Admin User:     $ADMIN_USERNAME"
echo "  Game Port:      ${GAME_UDP_PORT:-11115} (UDP)"
echo "  SSH Access:     ${SSH_SOURCE_CIDR:-0.0.0.0/0}"
echo ""

read -p "Proceed with deployment? (y/n): " CONFIRM
if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
    echo "Deployment cancelled."
    exit 0
fi

echo ""
echo "Step 1: Creating resource group..."
az group create \
    --name "$RESOURCE_GROUP" \
    --location "$LOCATION" \
    --output none

echo "✓ Resource group '$RESOURCE_GROUP' ready"

echo ""
echo "Step 2: Deploying infrastructure (this may take a few minutes)..."
DEPLOYMENT_OUTPUT=$(az deployment group create \
    --resource-group "$RESOURCE_GROUP" \
    --template-file "$SCRIPT_DIR/infra/main.bicep" \
    --mode Incremental \
    --parameters \
        location="$LOCATION" \
        vmName="${VM_NAME}" \
        vmSize="${VM_SIZE:-Standard_B2s}" \
        adminUsername="$ADMIN_USERNAME" \
        sshPublicKey="$SSH_PUBLIC_KEY" \
        gameUdpPort="${GAME_UDP_PORT:-11115}" \
        sshSourceCidr="${SSH_SOURCE_CIDR:-0.0.0.0/0}" \
        gameSourceCidr="${GAME_SOURCE_CIDR:-0.0.0.0/0}" \
    --query 'properties.outputs' \
    --output json)

echo "✓ Infrastructure deployed successfully!"

# Configure and install xRC Simulator on VM via run-command
# This runs on every deploy (idempotent) — handles both first deploy and updates
echo ""
echo "Step 2b: Configuring xRC Simulator on VM..."

# Render the setup script with current env values
export XRC_ADMIN_USERNAME="$ADMIN_USERNAME"
export XRC_DOWNLOAD_URL="${XRC_DOWNLOAD_URL:-}"
export XRC_GAME_PORT="${GAME_UDP_PORT:-11115}"
export XRC_SERVER_PASSWORD="${XRC_SERVER_PASSWORD:-}"
export XRC_SERVER_USERNAME="${XRC_SERVER_USERNAME:-}"
envsubst '${XRC_ADMIN_USERNAME} ${XRC_DOWNLOAD_URL} ${XRC_GAME_PORT} ${XRC_SERVER_PASSWORD} ${XRC_SERVER_USERNAME}' \
    < "$SCRIPT_DIR/scripts/setup-xrc.sh" \
    > "$SCRIPT_DIR/scripts/.setup-xrc-rendered.sh"

az vm run-command invoke \
    --resource-group "$RESOURCE_GROUP" \
    --name "$VM_NAME" \
    --command-id RunShellScript \
    --scripts @"$SCRIPT_DIR/scripts/.setup-xrc-rendered.sh" \
    --output none

echo "✓ xRC Simulator configured on VM"

# Extract outputs
PUBLIC_IP=$(echo "$DEPLOYMENT_OUTPUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['publicIpAddress']['value'])" 2>/dev/null || echo "unknown")
FQDN=$(echo "$DEPLOYMENT_OUTPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('fqdn',{}).get('value','N/A'))" 2>/dev/null || echo "N/A")

echo ""
echo "=========================================="
echo "  xRC Simulator Server - Deployed! 🎮"
echo "=========================================="
echo ""
echo "  Public IP:      $PUBLIC_IP"
echo "  Game Endpoint:  $PUBLIC_IP:${GAME_UDP_PORT:-11115} (UDP)"
echo "  SSH Command:    ssh ${ADMIN_USERNAME}@${PUBLIC_IP}"
echo ""
echo "  Resource Group: $RESOURCE_GROUP"
echo "  VM Name:        $VM_NAME"
echo "  VM Size:        ${VM_SIZE:-Standard_B2s}"
echo ""
echo "=========================================="
echo ""
echo "Next Steps:"
if [[ -n "${XRC_DOWNLOAD_URL:-}" ]]; then
    echo "  The xRC Simulator has been installed and started."
    echo "    1. SSH in: ssh ${ADMIN_USERNAME}@${PUBLIC_IP}"
    echo "    2. Check status: sudo systemctl status xrc-simulator"
    echo "    3. View logs: journalctl -u xrc-simulator -f"
else
    echo "  1. SSH into the server: ssh ${ADMIN_USERNAME}@${PUBLIC_IP}"
    echo "  2. Upload the xRC Simulator Linux Server zip to /opt/xrc-simulator/"
    echo "  3. Unzip and run: sudo systemctl enable --now xrc-simulator"
fi
echo ""
echo "To stop the VM (save costs when not in use):"
echo "  az vm deallocate --resource-group $RESOURCE_GROUP --name $VM_NAME"
echo ""
echo "To start the VM again:"
echo "  az vm start --resource-group $RESOURCE_GROUP --name $VM_NAME"
echo ""
echo "To delete everything:"
echo "  ./teardown.sh"
