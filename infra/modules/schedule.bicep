// schedule.bicep - Auto-shutdown schedule for the VM
// Uses Azure DevTestLab auto-shutdown (free, built-in)
// Auto-start is handled via deploy.sh using az vm auto-shutdown isn't available
// for start, so we use a separate mechanism

@description('Azure region for resources')
param location string

@description('VM name')
param vmName string

@description('VM resource ID')
param vmId string

@description('Time zone for schedules')
param timeZone string = 'Eastern Standard Time'

@description('Auto-shutdown time in HHmm format (24-hour, local time)')
param shutdownTime string = '0400'

// Auto-shutdown using DevTestLab schedule (free, built-in to Azure)
resource autoShutdown 'Microsoft.DevTestLab/schedules@2018-09-15' = {
  name: 'shutdown-computevm-${vmName}'
  location: location
  properties: {
    status: 'Enabled'
    taskType: 'ComputeVmShutdownTask'
    dailyRecurrence: {
      time: shutdownTime
    }
    timeZoneId: timeZone
    targetResourceId: vmId
    notificationSettings: {
      status: 'Disabled'
    }
  }
}

