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
  }
}

// Outputs
output publicIpAddress string = network.outputs.publicIpAddress
output fqdn string = network.outputs.fqdn
output vmName string = vm.outputs.vmName
output sshCommand string = 'ssh ${adminUsername}@${network.outputs.publicIpAddress}'
output gameEndpoint string = '${network.outputs.publicIpAddress}:${gameUdpPort}'
