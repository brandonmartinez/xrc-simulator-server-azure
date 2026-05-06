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
echo "  Auto-Shutdown:  ${SHUTDOWN_TIME:-0400} ET (deallocates VM)"
echo "  Auto-Start:     ${START_TIME:-0800} ET"
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
    --parameters \
        location="$LOCATION" \
        vmName="${VM_NAME}" \
        vmSize="${VM_SIZE:-Standard_B2s}" \
        adminUsername="$ADMIN_USERNAME" \
        sshPublicKey="$SSH_PUBLIC_KEY" \
        gameUdpPort="${GAME_UDP_PORT:-11115}" \
        sshSourceCidr="${SSH_SOURCE_CIDR:-0.0.0.0/0}" \
        gameSourceCidr="${GAME_SOURCE_CIDR:-0.0.0.0/0}" \
        xrcDownloadUrl="${XRC_DOWNLOAD_URL:-}" \
        enableAutoShutdown=true \
        shutdownTime="${SHUTDOWN_TIME:-0400}" \
    --query 'properties.outputs' \
    --output json)

echo "✓ Infrastructure deployed successfully!"

# Set up auto-start via Azure Automation
echo ""
echo "Step 3: Configuring auto-start schedule..."

AUTOMATION_ACCOUNT="${VM_NAME}-automation"
RUNBOOK_NAME="StartXrcSimulatorVM"
START_TIME_VALUE="${START_TIME:-0800}"
# Format start time as HH:MM for schedule
START_HOUR="${START_TIME_VALUE:0:2}"
START_MIN="${START_TIME_VALUE:2:2}"

# Create automation account with system-assigned identity
az automation account create \
    --name "$AUTOMATION_ACCOUNT" \
    --resource-group "$RESOURCE_GROUP" \
    --location "$LOCATION" \
    --output none 2>/dev/null || true

# Enable system-assigned managed identity
az automation account update \
    --name "$AUTOMATION_ACCOUNT" \
    --resource-group "$RESOURCE_GROUP" \
    --identity-type SystemAssigned \
    --output none

# Get the automation account's principal ID
PRINCIPAL_ID=$(az automation account show \
    --name "$AUTOMATION_ACCOUNT" \
    --resource-group "$RESOURCE_GROUP" \
    --query 'identity.principalId' -o tsv)

# Assign VM Contributor role to the automation account
az role assignment create \
    --assignee-object-id "$PRINCIPAL_ID" \
    --assignee-principal-type ServicePrincipal \
    --role "Virtual Machine Contributor" \
    --scope "/subscriptions/$(az account show --query id -o tsv)/resourceGroups/$RESOURCE_GROUP" \
    --output none 2>/dev/null || true

# Create the runbook
az automation runbook create \
    --automation-account-name "$AUTOMATION_ACCOUNT" \
    --resource-group "$RESOURCE_GROUP" \
    --name "$RUNBOOK_NAME" \
    --type PowerShell \
    --output none 2>/dev/null || true

# Write runbook content
RUNBOOK_CONTENT=$(cat <<EOF
# Start xRC Simulator VM using managed identity
Connect-AzAccount -Identity
Start-AzVM -ResourceGroupName "$RESOURCE_GROUP" -Name "$VM_NAME"
Write-Output "VM $VM_NAME started successfully"
EOF
)

echo "$RUNBOOK_CONTENT" > /tmp/xrc-start-runbook.ps1
az automation runbook replace-content \
    --automation-account-name "$AUTOMATION_ACCOUNT" \
    --resource-group "$RESOURCE_GROUP" \
    --name "$RUNBOOK_NAME" \
    --content @/tmp/xrc-start-runbook.ps1 \
    --output none
rm -f /tmp/xrc-start-runbook.ps1

# Publish the runbook
az automation runbook publish \
    --automation-account-name "$AUTOMATION_ACCOUNT" \
    --resource-group "$RESOURCE_GROUP" \
    --name "$RUNBOOK_NAME" \
    --output none

# Create a daily schedule (start tomorrow at the configured time)
TOMORROW=$(date -u -v+1d +%Y-%m-%dT${START_HOUR}:${START_MIN}:00Z 2>/dev/null || date -u -d "+1 day" +%Y-%m-%dT${START_HOUR}:${START_MIN}:00Z)
az automation schedule create \
    --automation-account-name "$AUTOMATION_ACCOUNT" \
    --resource-group "$RESOURCE_GROUP" \
    --name "DailyAutoStart" \
    --frequency Day \
    --interval 1 \
    --start-time "$TOMORROW" \
    --time-zone "Eastern Standard Time" \
    --description "Daily auto-start for xRC Simulator VM at ${START_HOUR}:${START_MIN} ET" \
    --output none 2>/dev/null || true

# Link schedule to runbook
az automation runbook start \
    --automation-account-name "$AUTOMATION_ACCOUNT" \
    --resource-group "$RESOURCE_GROUP" \
    --name "$RUNBOOK_NAME" \
    --output none 2>/dev/null || true

# Create job schedule (link runbook to schedule)
SCHEDULE_LINK=$(az rest \
    --method PUT \
    --uri "/subscriptions/$(az account show --query id -o tsv)/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Automation/automationAccounts/$AUTOMATION_ACCOUNT/jobSchedules/$(uuidgen || python3 -c 'import uuid; print(uuid.uuid4())')?api-version=2023-11-01" \
    --body "{\"properties\":{\"runbook\":{\"name\":\"$RUNBOOK_NAME\"},\"schedule\":{\"name\":\"DailyAutoStart\"}}}" \
    --output none 2>/dev/null || true)

echo "✓ Auto-start schedule configured (${START_HOUR}:${START_MIN} ET daily)"

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
    echo "  The xRC Simulator is being automatically installed via cloud-init."
    echo "  Wait ~2-3 minutes for provisioning to complete, then:"
    echo "    1. SSH in: ssh ${ADMIN_USERNAME}@${PUBLIC_IP}"
    echo "    2. Check status: sudo systemctl status xrc-simulator"
    echo "    3. Or manually: /opt/xrc-simulator/start-server.sh"
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
