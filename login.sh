#!/bin/bash
# login.sh - Azure CLI login helper for xRC Simulator deployment
set -euo pipefail

echo "=== xRC Simulator Server - Azure Login ==="
echo ""

# Check if az CLI is installed
if ! command -v az &> /dev/null; then
    echo "ERROR: Azure CLI (az) is not installed."
    echo "Install it from: https://docs.microsoft.com/en-us/cli/azure/install-azure-cli"
    exit 1
fi

# Check if already logged in
if az account show &> /dev/null; then
    ACCOUNT=$(az account show --query '{name:name, id:id}' -o tsv)
    echo "Already logged in to Azure."
    echo "Account: $ACCOUNT"
    echo ""
    read -p "Continue with this account? (y/n): " CONTINUE
    if [[ "$CONTINUE" != "y" && "$CONTINUE" != "Y" ]]; then
        echo "Logging in with a different account..."
        az login
    fi
else
    echo "Not currently logged in. Opening browser for Azure login..."
    az login
fi

echo ""
echo "✓ Azure login complete!"
echo ""

# Show current subscription
echo "Active subscription:"
az account show --query '{Name:name, ID:id, State:state}' -o table
