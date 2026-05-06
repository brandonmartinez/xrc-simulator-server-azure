#!/bin/bash
# teardown.sh - Delete all xRC Simulator Azure resources
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== xRC Simulator Server - Teardown ==="
echo ""

# Load environment configuration
if [[ ! -f "$SCRIPT_DIR/.env" ]]; then
    echo "ERROR: .env file not found!"
    exit 1
fi

set -a
source "$SCRIPT_DIR/.env"
set +a

echo "⚠️  WARNING: This will permanently delete ALL resources in:"
echo "  Resource Group: $RESOURCE_GROUP"
echo ""
echo "  This includes the VM, disk, network, and all data."
echo ""

read -p "Are you sure you want to delete everything? (yes/no): " CONFIRM
if [[ "$CONFIRM" != "yes" ]]; then
    echo "Teardown cancelled."
    exit 0
fi

echo ""
echo "Deleting resource group '$RESOURCE_GROUP'..."
az group delete \
    --name "$RESOURCE_GROUP" \
    --yes \
    --no-wait

echo ""
echo "✓ Resource group deletion initiated."
echo "  Resources will be removed in the background (may take a few minutes)."
