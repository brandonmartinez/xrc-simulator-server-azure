// main.bicep - xRC Simulator Server Infrastructure
// Deploys a Linux VM with networking configured for game server hosting

targetScope = 'resourceGroup'

@description('Azure region for all resources')
param location string

@description('Name of the virtual machine')
param vmName string = 'xrc-simulator-vm'

@description('Size of the virtual machine')
param vmSize string = 'Standard_B2s'

@description('Admin username for SSH access')
param adminUsername string = 'azureuser'

@description('SSH public key for authentication')
@secure()
param sshPublicKey string

@description('UDP port for xRC Simulator game traffic')
param gameUdpPort int = 11115

@description('Source CIDR for SSH access')
param sshSourceCidr string = '0.0.0.0/0'

@description('Source CIDR for game traffic')
param gameSourceCidr string = '0.0.0.0/0'

@description('Download URL for xRC Simulator Linux server (leave empty to upload manually)')
param xrcDownloadUrl string = ''

@description('Enable auto-shutdown schedule')
param enableAutoShutdown bool = true

@description('Auto-shutdown time in HHmm format (24-hour, Eastern Time)')
param shutdownTime string = '0400'

// Generate cloud-init with runtime parameters
var cloudInitContent = format('''#cloud-config
package_update: true
package_upgrade: true

packages:
  - unzip
  - curl
  - wget
  - screen
  - htop

runcmd:
  - mkdir -p /opt/xrc-simulator
  - chown {0}:{0} /opt/xrc-simulator
  - |
    if [ -n "{1}" ]; then
      echo "Downloading xRC Simulator..."
      wget -q -O /opt/xrc-simulator/xrc-server.zip "{1}"
      cd /opt/xrc-simulator
      unzip -o xrc-server.zip
      rm -f xrc-server.zip
      chmod +x /opt/xrc-simulator/*.x86_64 2>/dev/null || true
      chmod +x /opt/xrc-simulator/*.sh 2>/dev/null || true
      chown -R {0}:{0} /opt/xrc-simulator
    fi
  - |
    cat > /opt/xrc-simulator/start-server.sh << 'SCRIPT'
    #!/bin/bash
    cd /opt/xrc-simulator
    SERVER_BIN=$(find . -name "*.x86_64" -type f | head -1)
    if [ -z "$SERVER_BIN" ]; then
      echo "ERROR: No server binary found in /opt/xrc-simulator/"
      echo "Upload the Linux server zip and unzip it here."
      exit 1
    fi
    echo "Starting xRC Simulator Server: $SERVER_BIN"
    screen -dmS xrc-server bash -c "$SERVER_BIN -batchmode -nographics; exec bash"
    echo "Server started in screen session 'xrc-server'"
    echo "  Attach: screen -r xrc-server"
    echo "  Detach: Ctrl+A, D"
    SCRIPT
    chmod +x /opt/xrc-simulator/start-server.sh
    chown {0}:{0} /opt/xrc-simulator/start-server.sh
  - |
    cat > /etc/systemd/system/xrc-simulator.service << EOF
    [Unit]
    Description=xRC Simulator Game Server
    After=network.target

    [Service]
    Type=simple
    User={0}
    WorkingDirectory=/opt/xrc-simulator
    ExecStart=/bin/bash -c 'SERVER_BIN=$(find /opt/xrc-simulator -name "*.x86_64" -type f | head -1); exec $SERVER_BIN -batchmode -nographics'
    Restart=on-failure
    RestartSec=10

    [Install]
    WantedBy=multi-user.target
    EOF
    systemctl daemon-reload
  - |
    if find /opt/xrc-simulator -name "*.x86_64" -type f | grep -q .; then
      systemctl enable --now xrc-simulator
    fi
  - echo "xRC Simulator VM provisioning complete" | tee /var/log/xrc-provision.log

final_message: "xRC Simulator server ready. Cloud-init completed in $UPTIME seconds."
''', adminUsername, xrcDownloadUrl)

// Network module - VNet, NSG, Public IP, NIC
module network 'modules/network.bicep' = {
  name: 'network-deployment'
  params: {
    location: location
    baseName: vmName
    gameUdpPort: gameUdpPort
    sshSourceCidr: sshSourceCidr
    gameSourceCidr: gameSourceCidr
  }
}

// VM module - Virtual Machine
module vm 'modules/vm.bicep' = {
  name: 'vm-deployment'
  params: {
    location: location
    vmName: vmName
    vmSize: vmSize
    adminUsername: adminUsername
    sshPublicKey: sshPublicKey
    nicId: network.outputs.nicId
    cloudInitContent: cloudInitContent
  }
}

// Schedule module - Auto-shutdown (deallocates VM to save costs)
module schedule 'modules/schedule.bicep' = if (enableAutoShutdown) {
  name: 'schedule-deployment'
  params: {
    location: location
    vmName: vmName
    vmId: vm.outputs.vmId
    shutdownTime: shutdownTime
  }
}

// Outputs
output publicIpAddress string = network.outputs.publicIpAddress
output fqdn string = network.outputs.fqdn
output vmName string = vm.outputs.vmName
output sshCommand string = 'ssh ${adminUsername}@${network.outputs.publicIpAddress}'
output gameEndpoint string = '${network.outputs.publicIpAddress}:${gameUdpPort}'
