
manage-appservice.ps1 (Wrapper)

<#
.SYNOPSIS
Management script for App Service deployments
#>
param (
    [Parameter(Mandatory, ParameterSetName="Create")]
    [switch] $Create,

    [Parameter(Mandatory, ParameterSetName="Remove")]
    [switch] $Remove,

    [Parameter()]
    [switch] $DryRun
)

# Import modules
Import-Module Az.Websites, Az.Network, Az.PrivateDns -ErrorAction Stop

# Initialize logging
function Write-ActivityLog {
    param(
        [string]$Message,
        [ValidateSet('Info','Warning','Error')]
        [string]$Level = 'Info'
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] [$Level] $Message"
    
    switch ($Level) {
        'Error'   { Write-Error $logEntry -ErrorAction Continue }
        'Warning' { Write-Warning $logEntry }
        default   { Write-Output $logEntry }
    }
    
    $logFile = "AppServiceDeployment_$(Get-Date -Format 'yyyyMMdd').log"
    Add-Content -Path $logFile -Value $logEntry
}

# Clean old logs (3-month retention)
Get-ChildItem "AppServiceDeployment_*.log" | 
    Where-Object { $_.LastWriteTime -lt (Get-Date).AddMonths(-3) } | 
    Remove-Item -Force

try {
    if ($Create) {
        # Example parameter collection
        $params = @{
            AppName = "myapp-eastus-d"
            ResourceGroup = Get-AzResourceGroup -Name "app-rg"
            AppServicePlan = Get-AzAppServicePlan -ResourceGroupName "app-rg" -Name "asp-prod"
            Uami = Get-AzUserAssignedIdentity -ResourceGroupName "identity-rg" -Name "app-uami"
            VirtualNetwork = Get-AzVirtualNetwork -Name "vnet-prod" -ResourceGroupName "network-rg"
            AppServiceSubnet = Get-AzVirtualNetworkSubnetConfig -VirtualNetworkName "vnet-prod" `
                -ResourceGroupName "network-rg" -Name "snet-appservices"
            PrivateEndpointSubnet = Get-AzVirtualNetworkSubnetConfig -VirtualNetworkName "vnet-prod" `
                -ResourceGroupName "network-rg" -Name "snet-privateendpoints"
            PrivateDnsZone = Get-AzPrivateDnsZone -ResourceGroupName "dns-rg" -Name "privatelink.azurewebsites.net"
            AcrImage = "myacr.azurecr.io/myimage:latest"
            AdditionalAppSettings = @{
                NODE_ENV = "production"
                APPINSIGHTS_INSTRUMENTATIONKEY = "12345678-1234-1234-1234-123456789012"
            }
            DryRun = $DryRun
        }

        New-AzAppServiceForContainer @params
    }
    elseif ($Remove) {
        $params = @{
            AppName = "myapp-eastus-d"
            ResourceGroup = Get-AzResourceGroup -Name "app-rg"
            Force = $true
        }

        Remove-AzAppService @params
    }
}
catch {
    Write-ActivityLog "Operation failed: $_" -Level Error
    exit 1
}

# ====== DONE ======

Remove-AzAppService.ps1

<#
.SYNOPSIS
Removes an App Service and its associated private endpoints
#>
function Remove-AzAppService {
  [CmdletBinding(SupportsShouldProcess=$true)]
  param (
      [Parameter(Mandatory)]
      [string] $AppName,

      [Parameter(Mandatory)]
      [Microsoft.Azure.Commands.ResourceManager.Cmdlets.SdkModels.PSResourceGroup] $ResourceGroup,

      [Parameter()]
      [switch] $Force
  )

  process {
      try {
          if (-not $Force -and -not $PSCmdlet.ShouldProcess("Delete App Service '$AppName'")) {
              return
          }

          # 1. Remove Private Endpoint
          $pe = Get-AzPrivateEndpoint -ResourceGroupName $ResourceGroup.ResourceGroupName `
              -Name "pe-$AppName" -ErrorAction SilentlyContinue
          if ($pe) {
              Remove-AzPrivateEndpoint -ResourceGroupName $ResourceGroup.ResourceGroupName `
                  -Name "pe-$AppName" -Force -Confirm:$false
          }

          # 2. Remove Web App
          Remove-AzWebApp -ResourceGroupName $ResourceGroup.ResourceGroupName `
              -Name $AppName -Force -Confirm:$false

          Write-ActivityLog "Successfully removed App Service '$AppName'" -Level Info
      }
      catch {
          Write-ActivityLog "Removal failed: $_" -Level Error
          throw
      }
  }
}
# ====== DONE ======

New-AzAppServiceForContainer.ps1

<#
.SYNOPSIS
Creates an Azure App Service for Containers with private endpoints and DNS integration

.DESCRIPTION
Deploys a containerized app with:
- Private Endpoint in dedicated subnet
- DNS records in cross-subscription Private DNS Zone
- UAMI integration
- App Insights connectivity
#>
function New-AzAppServiceForContainer {
  [CmdletBinding(SupportsShouldProcess=$true)]
  param (
      [Parameter(Mandatory)]
      [string] $AppName,

      [Parameter(Mandatory)]
      [Microsoft.Azure.Commands.ResourceManager.Cmdlets.SdkModels.PSResourceGroup] $ResourceGroup,

      [Parameter(Mandatory)]
      [Microsoft.Azure.Commands.WebApps.Models.PSAppServicePlan] $AppServicePlan,

      [Parameter(Mandatory)]
      [Microsoft.Azure.Commands.ManagedServiceIdentity.Models.PSUserAssignedIdentity] $Uami,

      [Parameter(Mandatory)]
      [Microsoft.Azure.Commands.Network.Models.PSVirtualNetwork] $VirtualNetwork,

      [Parameter(Mandatory)]
      [Microsoft.Azure.Commands.Network.Models.PSSubnet] $AppServiceSubnet,

      [Parameter(Mandatory)]
      [Microsoft.Azure.Commands.Network.Models.PSSubnet] $PrivateEndpointSubnet,

      [Parameter(Mandatory)]
      [Microsoft.Azure.Commands.PrivateDns.Models.PSPrivateDnsZone] $PrivateDnsZone,

      [Parameter(Mandatory)]
      [string] $AcrImage, # Format: "acrname.azurecr.io/image:tag"

      [Parameter()]
      [hashtable] $AdditionalAppSettings = @{},

      [Parameter()]
      [switch] $DryRun
  )

  begin {
      # Validate DNS zone naming convention
      if (-not $PrivateDnsZone.Name.EndsWith("privatelink.azurewebsites.net")) {
          throw "Private DNS Zone must be for 'privatelink.azurewebsites.net'"
      }
  }

  process {
      try {
          # ===== DRY RUN =====
          if ($DryRun) {
              $armTemplate = @{
                  `$schema = "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#"
                  resources = @(
                      @{
                          type = "Microsoft.Web/sites"
                          name = $AppName
                          apiVersion = "2022-03-01"
                          location = $ResourceGroup.Location
                          identity = @{
                              type = "UserAssigned"
                              userAssignedIdentities = @{
                                  $($Uami.Id) = @{}
                              }
                          }
                          properties = @{
                              serverFarmId = $AppServicePlan.Id
                              siteConfig = @{
                                  linuxFxVersion = "DOCKER|$AcrImage"
                                  appSettings = @(
                                      @{ name = "WEBSITES_PORT"; value = "8080" },
                                      @{ name = "WEBSITES_VNET_ROUTE_ALL"; value = "1" }
                                  ) + ($AdditionalAppSettings.GetEnumerator() | ForEach-Object {
                                      @{ name = $_.Key; value = $_.Value }
                                  })
                              }
                          }
                      }
                  )
              }
              $outputPath = "$PSScriptRoot\$AppName-DryRun-$(Get-Date -Format 'yyyyMMdd').json"
              $armTemplate | ConvertTo-Json -Depth 10 | Out-File $outputPath
              Write-ActivityLog "Dry run complete. ARM template saved to $outputPath" -Level Info
              return Get-Item $outputPath
          }

          # ===== ACTUAL DEPLOYMENT =====
          if (-not $PSCmdlet.ShouldProcess("Create App Service '$AppName'")) { return }

          # 1. Create Web App
          $webAppParams = @{
              ResourceGroupName = $ResourceGroup.ResourceGroupName
              Name = $AppName
              Location = $ResourceGroup.Location
              AppServicePlan = $AppServicePlan.Name
              ContainerImageName = $AcrImage
              IdentityType = "UserAssigned"
              IdentityId = $Uami.Id
          }
          $webApp = New-AzWebApp @webAppParams

          # 2. Configure App Settings
          $appSettings = @{
              WEBSITES_PORT = "8080"
              WEBSITES_VNET_ROUTE_ALL = "1"
              DOCKER_REGISTRY_SERVER_URL = "https://$($AcrImage.Split('/')[0])"
          } + $AdditionalAppSettings

          Update-AzWebApp -ResourceGroupName $ResourceGroup.ResourceGroupName `
              -Name $AppName -AppSettings $appSettings

          # 3. Create Private Endpoint
          $privateIp = (Get-AzVirtualNetworkSubnetConfig -VirtualNetwork $VirtualNetwork `
              -Name $PrivateEndpointSubnet.Name).AddressPrefix.Split('/')[0]

          $peConnection = New-AzPrivateLinkServiceConnection -Name "pls-$AppName" `
              -PrivateLinkServiceId $webApp.Id -GroupId "sites"

          $pe = New-AzPrivateEndpoint -ResourceGroupName $ResourceGroup.ResourceGroupName `
              -Name "pe-$AppName" -Location $ResourceGroup.Location `
              -Subnet $PrivateEndpointSubnet -PrivateLinkServiceConnection $peConnection

          # 4. Configure DNS (cross-subscription)
          $originalContext = Get-AzContext
          try {
              Set-AzContext -Subscription $PrivateDnsZone.SubscriptionId | Out-Null

              $dnsRecords = @(
                  @{ Name = "$AppName-eastus-d"; Zone = $PrivateDnsZone.Name },
                  @{ Name = "$AppName-eastus-d.scm"; Zone = $PrivateDnsZone.Name }
              )

              foreach ($record in $dnsRecords) {
                  New-AzPrivateDnsRecordSet @record -ResourceGroupName $PrivateDnsZone.ResourceGroupName `
                      -RecordType A -Ttl 300 -PrivateDnsRecords $privateIp -Confirm:$false
              }
          }
          finally {
              Set-AzContext -Context $originalContext | Out-Null
          }

          Write-ActivityLog "Successfully deployed App Service '$AppName'" -Level Info
          return $webApp
      }
      catch {
          Write-ActivityLog "Deployment failed: $_" -Level Error
          throw
      }
  }
}
# ====== DONE ======

# Create new (dry-run)
./manage-appservice.ps1 -Create -DryRun

# Actual deployment
./manage-appservice.ps1 -Create

# Remove app
./manage-appservice.ps1 -Remove

# ====== DONE ======


# ====== DONE ======



# ====== DONE ======

