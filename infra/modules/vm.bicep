// vm.bicep - Virtual Machine for xRC Simulator Server

@description('Azure region for resources')
param location string

@description('Name of the virtual machine')
param vmName string

@description('Size of the virtual machine')
param vmSize string = 'Standard_B2s'

@description('Admin username')
param adminUsername string

@description('SSH public key')
param sshPublicKey string

@description('Network interface ID')
param nicId string

@description('Cloud-init script content')
param cloudInitContent string = ''

resource vm 'Microsoft.Compute/virtualMachines@2024-03-01' = {
  name: vmName
  location: location
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    osProfile: {
      computerName: vmName
      adminUsername: adminUsername
      customData: !empty(cloudInitContent) ? base64(cloudInitContent) : null
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: sshPublicKey
            }
          ]
        }
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: '0001-com-ubuntu-server-jammy'
        sku: '22_04-lts-gen2'
        version: 'latest'
      }
      osDisk: {
        name: '${vmName}-osdisk'
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'StandardSSD_LRS'
        }
        diskSizeGB: 30
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nicId
        }
      ]
    }
  }
}

output vmId string = vm.id
output vmName string = vm.name
