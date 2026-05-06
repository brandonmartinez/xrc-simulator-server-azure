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
| `XRC_SERVER_USERNAME` | *(empty)* | Admin name for server chat commands |
| `XRC_SERVER_PASSWORD` | *(empty)* | Password players enter to join |
| `XRC_GAME` | `22` | Game number (0-22, see game list below) |
| `WEB_ADMIN_PORT` | `8080` | Port for the web admin interface |
| `WEB_ADMIN_BIND` | `0.0.0.0` | Bind address (`0.0.0.0` = public, `127.0.0.1` = SSH tunnel only) |

## VM Size Recommendations

| VM Size | vCPUs | RAM | Type | Best For |
|---------|-------|-----|------|----------|
| `Standard_B1s` | 1 | 1GB | Burstable | Testing only |
| `Standard_B2s` | 2 | 4GB | Burstable | Budget hosting (default) |
| `Standard_D2as_v5` | 2 | 8GB | Dedicated | Reliable tournament hosting |

The xRC Simulator with 6 players uses ~85% of a single vCPU at 25ms update rate. `Standard_B2s` provides 2 burstable vCPUs — adequate for most team practice sessions. For tournaments or consistent low-latency performance, use `Standard_D2as_v5`.

## Web Admin Interface

The server includes a lightweight web admin UI for managing the xRC Simulator without SSH access.

**Access:** `http://<PUBLIC_IP>:8080` (protected by Basic Auth using `XRC_SERVER_USERNAME` / `XRC_SERVER_PASSWORD`)

**Features:**
- View server status (active/inactive)
- Start / Stop / Restart the xRC Simulator service
- Change the active game and restart
- View recent server logs

**Security Options:**
- **Public access** (default): Set `WEB_ADMIN_BIND=0.0.0.0` — access restricted by NSG to `SSH_SOURCE_CIDR`
- **SSH tunnel only** (recommended for production): Set `WEB_ADMIN_BIND=127.0.0.1`, then:
  ```bash
  ssh -L 8080:localhost:8080 azureuser@<PUBLIC_IP>
  # Visit http://localhost:8080
  ```

## Available Games

| # | Game | # | Game |
|---|------|---|------|
| 0 | Splash | 12 | Power Play |
| 1 | Relic Recovery | 13 | Charged Up |
| 2 | Rover Ruckus | 14 | Over Under |
| 3 | Skystone | 15 | CENTERSTAGE |
| 4 | Infinite Recharge | 16 | Crescendo |
| 5 | Change Up | 17 | High Stakes |
| 6 | Bot Royale | 18 | INTO THE DEEP |
| 7 | Ultimate Goal | 19 | REEFSCAPE |
| 8 | Tipping Point | 20 | Push Back |
| 9 | Freight Frenzy | 21 | DECODE |
| 10 | Rapid React | 22 | REBUILT |
| 11 | Spin Up | | |

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

## Redeployment

Running `./deploy.sh` again is fully idempotent:
- Infrastructure changes are applied incrementally
- The xRC Simulator binary is re-downloaded (if URL changed) and the server config is updated
- The systemd service is restarted with the new settings

This means you can update `XRC_DOWNLOAD_URL`, `XRC_SERVER_PASSWORD`, or other settings in `.env` and simply re-run `./deploy.sh`.

## Cost Estimates

- **Standard_B2s**: ~$0.042/hour (~$1.01/day if running 24h)
- **Standard_D2as_v5**: ~$0.09/hour (~$2.16/day)
- **Public IP**: ~$0.005/hour when allocated
- **Egress**: First 100GB/month free, then ~$0.087/GB

**Tip**: Deallocate the VM when not in use to stop compute charges. The static public IP persists through deallocations — players don't need to update their connection info.

## Architecture

```
Azure Resource Group
├── Virtual Network (10.0.0.0/16)
│   └── Subnet (10.0.1.0/24)
│       └── Network Security Group
│           ├── SSH (TCP/22)
│           ├── Game Traffic (UDP/11115)
│           ├── Web Admin (TCP/8080)
│           └── ICMP (ping)
├── Public IP (Static - persists through deallocations)
├── Network Interface
└── Virtual Machine (Ubuntu 22.04 LTS)
    ├── xRC Simulator (systemd service via setup-xrc.sh)
    └── xRC Web Admin (systemd service on port 8080)
```

## Based On

This deployment is the Azure equivalent of the [AWS hosting guide](https://xrcsimulator.org/amazon-web-services/) from the xRC Simulator documentation.
