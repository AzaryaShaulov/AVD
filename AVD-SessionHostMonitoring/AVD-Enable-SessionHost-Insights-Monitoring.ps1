<#
.SYNOPSIS
  Creates or updates a Data Collection Rule (DCR) for AVD session host monitoring
  and automatically associates it with all session hosts in a host pool.
  Repository: https://github.com/AzaryaShaulov/AVD

.DESCRIPTION
  Builds a DCR that collects performance counters from AVD session hosts into both
  the InsightsMetrics and Perf tables in a Log Analytics workspace. The DCR defines
  two performanceCounter data sources — one mapped to Microsoft-InsightsMetrics and
  one mapped to Microsoft-Perf — with both streams flowing to the same LAW destination.

  When -HostPoolName and -HostPoolRG are provided, the script automatically enumerates
  all session hosts in the host pool and associates the DCR with each underlying VM.
  If those parameters are omitted, the DCR is created but association is skipped and
  the manual association command is printed instead.

.PARAMETER SubscriptionId
  Azure subscription ID (required).

.PARAMETER LawRG
  Resource group containing the Log Analytics workspace.

.PARAMETER LawName
  Name of the Log Analytics workspace.

.PARAMETER DcrRG
  Resource group where the DCR will be created or updated.

.PARAMETER DcrName
  Name of the Data Collection Rule.

.PARAMETER Location
  Azure region for the DCR (e.g. "eastus2").

.PARAMETER HostPoolName
  Name of the AVD host pool whose session hosts will be associated with the DCR.
  When omitted, auto-association is skipped.

.PARAMETER HostPoolRG
  Resource group containing the AVD host pool.
  Required when -HostPoolName is specified.

.PARAMETER SamplingFrequencyInSeconds
  How often to sample performance counters. Defaults to 60.

.PARAMETER CounterSpecifiers
  Array of performance counter specifiers to collect.

.PARAMETER WhatIf
  Built-in common parameter (SupportsShouldProcess). Preview changes without applying them.

.EXAMPLE
  # Create DCR and auto-associate with all session hosts in a host pool
  .\AVD-Enable-SessionHost-Insights-Monitoring.ps1 -SubscriptionId "YOUR-SUB-ID" `
    -LawRG "az-infra-eus2" -LawName "AVD-LAW" -DcrRG "az-infra-eus2" `
    -DcrName "AVD-SessionHost-DCR" -Location "eastus2" `
    -HostPoolName "AVD-HostPool" -HostPoolRG "az-avd-rg"

.EXAMPLE
  # Create DCR only (no auto-association)
  .\AVD-Enable-SessionHost-Insights-Monitoring.ps1 -SubscriptionId "YOUR-SUB-ID" `
    -LawRG "az-infra-eus2" -LawName "AVD-LAW" -DcrRG "az-infra-eus2" `
    -DcrName "AVD-SessionHost-DCR" -Location "eastus2"

.EXAMPLE
  # WhatIf preview — no changes applied
  .\AVD-Enable-SessionHost-Insights-Monitoring.ps1 -SubscriptionId "YOUR-SUB-ID" `
    -LawRG "az-infra-eus2" -LawName "AVD-LAW" -DcrRG "az-infra-eus2" `
    -DcrName "AVD-SessionHost-DCR" -Location "eastus2" `
    -HostPoolName "AVD-HostPool" -HostPoolRG "az-avd-rg" -WhatIf

.NOTES
  Requires: Azure CLI with Monitoring Contributor + Desktop Virtualization Reader permissions
  Version: 1.3 (Auto-association with host pool session hosts)
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
  [Parameter(Mandatory = $true)]
  [ValidateNotNullOrEmpty()]
  [string]$SubscriptionId,

  [Parameter(Mandatory = $false)]
  [ValidateNotNullOrEmpty()]
  [Alias("LawResourceGroup")]
  [string]$LawRG = "AVD-rg",

  [Parameter(Mandatory = $false)]
  [ValidateNotNullOrEmpty()]
  [Alias("LawWorkspace")]
  [string]$LawName = "AVD-Law",

  [Parameter(Mandatory = $false)]
  [ValidateNotNullOrEmpty()]
  [string]$DcrRG = "AVD-rg",

  [Parameter(Mandatory = $false)]
  [ValidateNotNullOrEmpty()]
  [string]$DcrName = "AVD-SessionHost-DCR",

  [Parameter(Mandatory = $false)]
  [ValidateNotNullOrEmpty()]
  [string]$Location = "EastUS2",

  [Parameter(Mandatory = $false)]
  [int]$SamplingFrequencyInSeconds = 60,

  [Parameter(Mandatory = $false)]
  [string]$HostPoolName,

  [Parameter(Mandatory = $false)]
  [string]$HostPoolRG,

  [Parameter(Mandatory = $false)]
  [string[]]$CounterSpecifiers = @(
    "\\Processor(_Total)\\% Processor Time",
    "\\Memory\\Available MBytes",
    "\\Memory\\% Committed Bytes In Use",
    "\\LogicalDisk(_Total)\\% Free Space",
    "\\LogicalDisk(_Total)\\Avg. Disk sec/Read",
    "\\LogicalDisk(_Total)\\Avg. Disk sec/Write",
    "\\LogicalDisk(_Total)\\Current Disk Queue Length",
    "\\Network Adapter(*)\\Bytes Total/sec",
    "\\Network Adapter(*)\\Output Queue Length"
  )
)

$ErrorActionPreference = "Stop"

# Validate host pool parameter combination
if ($HostPoolName -and -not $HostPoolRG) {
  throw "-HostPoolRG is required when -HostPoolName is specified."
}
if ($HostPoolRG -and -not $HostPoolName) {
  throw "-HostPoolName is required when -HostPoolRG is specified."
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
  throw "Azure CLI (az) not found. Please install and try again."
}

$global:LASTEXITCODE = 0
az account show -o none 2>$null
if ($LASTEXITCODE -ne 0) {
  throw "Azure CLI not logged in. Run 'az login' and try again."
}

az account set --subscription $SubscriptionId --only-show-errors 2>$null
if ($LASTEXITCODE -ne 0) { throw "Failed to set subscription: $SubscriptionId" }

# Resolve LAW resourceId
$global:LASTEXITCODE = 0
$LawId = az monitor log-analytics workspace show -g $LawRG -n $LawName --query id -o tsv --only-show-errors 2>$null
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($LawId)) {
  throw "Could not resolve LAW workspace $LawName in RG $LawRG"
}
$LawId = $LawId.Trim()

# Check if DCR exists (distinguish ResourceNotFound from other errors)
$exists = $true
$global:LASTEXITCODE = 0
$dcrCheckErr = az monitor data-collection rule show -g $DcrRG -n $DcrName -o none 2>&1
if ($LASTEXITCODE -ne 0) {
  if ($dcrCheckErr -match "ResourceNotFound|could not be found|not found") {
    $exists = $false
  } else {
    throw "Failed to check DCR existence for '$DcrName': $dcrCheckErr"
  }
}

# Consistent naming for DCR components
$laName = "la-$DcrName-primary"
$perfInsightsName = "perf-$DcrName-insightsmetrics"
$perfTableName = "perf-$DcrName-perftable"

# -------------------------
# Build DCR JSON (Perf + InsightsMetrics)
# -------------------------
$dcrObj = [ordered]@{
  location   = $Location
  properties = [ordered]@{
    dataSources = [ordered]@{
      performanceCounters = @(
        [ordered]@{
          name                       = $perfInsightsName
          streams                    = @("Microsoft-InsightsMetrics")
          samplingFrequencyInSeconds = $SamplingFrequencyInSeconds
          counterSpecifiers          = @($CounterSpecifiers)
        },
        [ordered]@{
          name                       = $perfTableName
          streams                    = @("Microsoft-Perf")
          samplingFrequencyInSeconds = $SamplingFrequencyInSeconds
          counterSpecifiers          = @($CounterSpecifiers)
        }
      )
    }
    destinations = [ordered]@{
      logAnalytics = @(
        [ordered]@{
          name                = $laName
          workspaceResourceId = $LawId
        }
      )
    }
    dataFlows = @(
      [ordered]@{
        streams      = @("Microsoft-InsightsMetrics")
        destinations = @($laName)
      },
      [ordered]@{
        streams      = @("Microsoft-Perf")
        destinations = @($laName)
      }
    )
  }
}

$dcrJson = ConvertTo-Json -InputObject $dcrObj -Depth 10

$tmp = Join-Path $env:TEMP "dcr-$DcrName.json"
[System.IO.File]::WriteAllText($tmp, $dcrJson, [System.Text.UTF8Encoding]::new($false))

Write-Host "DCR JSON written to: $tmp" -ForegroundColor DarkGray

$DcrId = $null
try {
  if (-not (Test-Path $tmp) -or ((Get-Item $tmp).Length -eq 0)) {
    throw "DCR JSON temp file missing or empty: $tmp"
  }

  if (-not $PSCmdlet.ShouldProcess("$DcrName in RG $DcrRG", "Create/Update DCR")) {
    return
  }

  $action = if ($exists) { "Updating" } else { "Creating" }
  Write-Host "$action DCR $DcrName (Perf + InsightsMetrics)..." -ForegroundColor Cyan

  # 'create' is idempotent (ARM PUT) — works for both new and existing DCRs
  $global:LASTEXITCODE = 0
  az monitor data-collection rule create `
    --name $DcrName `
    --resource-group $DcrRG `
    --rule-file $tmp `
    --only-show-errors `
    -o none
  if ($LASTEXITCODE -ne 0) { throw "Failed to create/update DCR: $DcrName" }

  # Validate
  $global:LASTEXITCODE = 0
  $DcrId = az monitor data-collection rule show -g $DcrRG -n $DcrName --query id -o tsv --only-show-errors 2>$null
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($DcrId)) { throw "Failed to resolve DCR id after create/update." }
  $DcrId = $DcrId.Trim()
} finally {
  Remove-Item $tmp -ErrorAction SilentlyContinue
}

Write-Host "DCR ready: $DcrName" -ForegroundColor Green
Write-Host "DCR Id: $DcrId"
Write-Host ""

# -------------------------
# Associate DCR with all session hosts in the host pool
# -------------------------
if ($HostPoolName) {
  Write-Host "Enumerating session hosts in host pool: $HostPoolName..." -ForegroundColor Cyan

  # Ensure the desktopvirtualization CLI extension is present
  $global:LASTEXITCODE = 0
  az extension show --name desktopvirtualization -o none 2>$null
  if ($LASTEXITCODE -ne 0) {
    Write-Host "Installing required Azure CLI extension: desktopvirtualization..." -ForegroundColor DarkGray
    az extension add --name desktopvirtualization --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw "Failed to install 'desktopvirtualization' Azure CLI extension." }
  }

  $global:LASTEXITCODE = 0
  $vmIdsRaw = az desktopvirtualization sessionhost list `
    -g $HostPoolRG `
    --host-pool-name $HostPoolName `
    --query "[].properties.resourceId" `
    -o tsv --only-show-errors 2>$null

  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($vmIdsRaw)) {
    Write-Warning "Could not enumerate session hosts from host pool '$HostPoolName'. Skipping auto-association."
  } else {
    $vmIds = ($vmIdsRaw -split "`n") | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
    Write-Host "Found $($vmIds.Count) session host(s). Associating DCR..." -ForegroundColor Cyan

    $assocName  = "assoc-$DcrName"
    $successCount = 0
    $failCount    = 0

    foreach ($vmId in $vmIds) {
      $vmName = ($vmId -split '/')[-1]

      if (-not $PSCmdlet.ShouldProcess($vmName, "Associate DCR '$DcrName'")) {
        continue
      }

      Write-Host "  Associating: $vmName" -ForegroundColor Gray
      $global:LASTEXITCODE = 0
      az monitor data-collection rule association create `
        --name $assocName `
        --resource $vmId `
        --rule-id $DcrId `
        --only-show-errors `
        -o none 2>$null

      if ($LASTEXITCODE -ne 0) {
        Write-Warning "  Failed to associate DCR with $vmName"
        $failCount++
      } else {
        $successCount++
      }
    }

    $assocColor = if ($failCount -gt 0) { 'Yellow' } else { 'Green' }
    Write-Host "Association complete: $successCount succeeded, $failCount failed." -ForegroundColor $assocColor
  }
} else {
  Write-Host "No host pool specified. To associate this DCR with session hosts, run:" -ForegroundColor Yellow
  Write-Host "  az monitor data-collection rule association create ``"
  Write-Host "    --name 'assoc-$DcrName' ``"
  Write-Host "    --resource '<VM-Resource-Id>' ``"
  Write-Host "    --rule-id '$DcrId'"
}

Write-Host ""
Write-Host "After 5-15 minutes, you should see data in BOTH tables:"
Write-Host "  - InsightsMetrics"
Write-Host "  - Perf"
