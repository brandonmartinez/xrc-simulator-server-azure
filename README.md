# xRC Simulator Server - Azure

An infrastructure-as-code deployment pipeline to run the [xRC Simulator](https://xrcsimulator.org/) game server on Azure, using Bicep templates and the Azure CLI.

Deploy a fully configured Ubuntu VM with the xRC Simulator automatically installed and ready to host matches for up to 6 players.

## Prerequisites

- [Azure CLI](https://docs.microsoft.com/en-us/cli/azure/install-azure-cli) installed
- An Azure account (free tier works for testing)
- An SSH key pair (`ssh-keygen -t rsa -b 4096` if you don't have one)

## Quick Start

### Step 1: Configure

```bash
cp .env.sample .env
# Edit .env with your preferences (defaults work out of the box)
```

### Step 2: Deploy

```bash
./login.sh   # Authenticate with Azure (one-time)
./deploy.sh  # Deploy the server infrastructure
```

That's it! The server will be provisioned with the xRC Simulator automatically downloaded and configured as a systemd service.

## Configuration (.env)

| Variable | Default | Description |
|----------|---------|-------------|
| `LOCATION` | `eastus` | Azure region |
| `RESOURCE_GROUP` | `xrc-simulator-rg` | Resource group name |
| `VM_NAME` | `xrc-simulator-vm` | Virtual machine name |
| `VM_SIZE` | `Standard_B2s` | VM size (see below) |
| `ADMIN_USERNAME` | `azureuser` | SSH login username |
| `SSH_PUBLIC_KEY_PATH` | `~/.ssh/id_rsa.pub` | Path to SSH public key |
| `GAME_UDP_PORT` | `11115` | UDP port for game traffic |
| `SSH_SOURCE_CIDR` | `0.0.0.0/0` | Restrict SSH access by IP |
| `GAME_SOURCE_CIDR` | `0.0.0.0/0` | Restrict game access by IP |
| `XRC_DOWNLOAD_URL` | Latest v19.2c | Download URL for server zip |
| `SHUTDOWN_TIME` | `0400` | Daily auto-shutdown (24h ET) |
| `START_TIME` | `0800` | Daily auto-start (24h ET) |

## VM Size Recommendations

| VM Size | vCPUs | RAM | Type | Best For |
|---------|-------|-----|------|----------|
| `Standard_B1s` | 1 | 1GB | Burstable | Testing only |
| `Standard_B2s` | 2 | 4GB | Burstable | Budget hosting (default) |
| `Standard_D2as_v5` | 2 | 8GB | Dedicated | Reliable tournament hosting |

The xRC Simulator with 6 players uses ~85% of a single vCPU at 25ms update rate. `Standard_B2s` provides 2 burstable vCPUs — adequate for most team practice sessions. For tournaments or consistent low-latency performance, use `Standard_D2as_v5`.

## Managing the Server

```bash
# SSH into the server
ssh azureuser@<PUBLIC_IP>

# Check server status
sudo systemctl status xrc-simulator

# Restart the server
sudo systemctl restart xrc-simulator

# View server logs
journalctl -u xrc-simulator -f

# Stop VM (saves compute costs, keeps disk)
az vm deallocate --resource-group xrc-simulator-rg --name xrc-simulator-vm

# Start VM again
az vm start --resource-group xrc-simulator-rg --name xrc-simulator-vm

# Delete everything
./teardown.sh
```

## Cost Estimates

- **Standard_B2s**: ~$0.042/hour (~$1.01/day if running 24h)
- **Standard_D2as_v5**: ~$0.09/hour (~$2.16/day)
- **Public IP**: ~$0.005/hour when allocated
- **Egress**: First 100GB/month free, then ~$0.087/GB
- **Azure Automation (auto-start)**: Free tier (500 min/month)

**With auto-shutdown (4 AM–8 AM ET off) — saves ~17% on compute:**
- **Standard_B2s**: ~$0.84/day (~$25/month)
- **Standard_D2as_v5**: ~$1.80/day (~$54/month)

**Tip**: The VM is automatically deallocated from 4 AM to 8 AM ET by default. The static public IP and DNS label persist through deallocations — players don't need to update their connection info.

## Architecture

```
Azure Resource Group
├── Virtual Network (10.0.0.0/16)
│   └── Subnet (10.0.1.0/24)
│       └── Network Security Group
│           ├── SSH (TCP/22)
│           ├── Game Traffic (UDP/11115)
│           └── ICMP (ping)
├── Public IP (Static - persists through deallocations)
├── Network Interface
├── Virtual Machine (Ubuntu 22.04 LTS)
│   └── cloud-init → xRC Simulator (systemd service)
├── DevTestLab Schedule (auto-shutdown at 4 AM ET)
└── Automation Account (auto-start at 8 AM ET)
```

## Based On

This deployment is the Azure equivalent of the [AWS hosting guide](https://xrcsimulator.org/amazon-web-services/) from the xRC Simulator documentation.
