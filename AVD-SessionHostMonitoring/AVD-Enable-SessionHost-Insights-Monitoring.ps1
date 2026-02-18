<#
.SYNOPSIS
  Creates or updates a Data Collection Rule (DCR) for AVD session host monitoring.
  Repository: https://github.com/AzaryaShaulov/AVD

.DESCRIPTION
  Builds a DCR that collects performance counters from AVD session hosts into both
  the InsightsMetrics and Perf tables in a Log Analytics workspace. The DCR defines
  two performanceCounter data sources — one mapped to Microsoft-InsightsMetrics and
  one mapped to Microsoft-Perf — with both streams flowing to the same LAW destination.

  After the DCR is created, you must associate it with your session host VMs separately.

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

.PARAMETER SamplingFrequencyInSeconds
  How often to sample performance counters. Defaults to 60.

.PARAMETER CounterSpecifiers
  Array of performance counter specifiers to collect.

.PARAMETER WhatIf
  Preview changes without applying them.

.EXAMPLE
  .\AVD-Enable-SessionHost-Insights-Monitoring.ps1 -SubscriptionId "YOUR-SUB-ID" `
    -LawRG "az-infra-eus2" -LawName "AVD-LAW" -DcrRG "az-infra-eus2" `
    -DcrName "AVD-SessionHost-DCR" -Location "eastus2"

.EXAMPLE
  .\AVD-Enable-SessionHost-Insights-Monitoring.ps1 -SubscriptionId "YOUR-SUB-ID" `
    -LawRG "az-infra-eus2" -LawName "AVD-LAW" -DcrRG "az-infra-eus2" `
    -DcrName "AVD-SessionHost-DCR" -Location "eastus2" -WhatIf

.NOTES
  Requires: Azure CLI with Monitoring Contributor permissions
  Version: 1.1 (Bug fixes + robustness improvements)

  After running this script, associate the DCR with your AVD session host VMs:
    az monitor data-collection rule association create `
      --name "assoc-<DcrName>" `
      --resource "<VM-Resource-Id>" `
      --rule-id "<DCR-Id>"
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory = $false)]
  [ValidateNotNullOrEmpty()]
  [string]$SubscriptionId = "00000000000",

  [Parameter(Mandatory = $false)]
  [Alias("LawResourceGroup")]
  [string]$LawRG = "AVD-rg",

  [Parameter(Mandatory = $false)]
  [Alias("LawWorkspace")]
  [string]$LawName = "AVD-Law",

  [Parameter(Mandatory = $false)]
  [string]$DcrRG = "AVD-LAW",

  [Parameter(Mandatory = $false)]
  [string]$DcrName = "AVD-SessionHost-DCR",

  [Parameter(Mandatory = $false)]
  [string]$Location = "EastUS2",

  [int]$SamplingFrequencyInSeconds = 60,

  [string[]]$CounterSpecifiers = @(
    "\\Processor(_Total)\\% Processor Time",
    "\\Memory\\Available MBytes",
    "\\Memory\\% Committed Bytes In Use",
    "\\LogicalDisk(_Total)\\% Free Space",
    "\\LogicalDisk(_Total)\\Avg. Disk sec/Read",
    "\\LogicalDisk(_Total)\\Avg. Disk sec/Write",
    "\\LogicalDisk(_Total)\\Current Disk Queue Length",
    "\\Network Interface(*)\\Bytes Total/sec",
    "\\Network Interface(*)\\Output Queue Length"
  ),

  [switch]$WhatIf
)

$ErrorActionPreference = "Stop"

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

if (-not (Test-Path $tmp) -or ((Get-Item $tmp).Length -eq 0)) {
  throw "DCR JSON temp file missing or empty: $tmp"
}

Write-Host "DCR JSON written to: $tmp" -ForegroundColor DarkGray

if ($WhatIf) {
  Write-Host "[WHATIF] Would create/update DCR: $DcrName in RG: $DcrRG"
  Remove-Item $tmp -ErrorAction SilentlyContinue
  return
}

try {
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
  $DcrId = az monitor data-collection rule show -g $DcrRG -n $DcrName --query id -o tsv --only-show-errors 2>$null
  if ([string]::IsNullOrWhiteSpace($DcrId)) { throw "Failed to resolve DCR id after create/update." }
} finally {
  Remove-Item $tmp -ErrorAction SilentlyContinue
}

Write-Host "DCR ready: $DcrName" -ForegroundColor Green
Write-Host "DCR Id: $DcrId"
Write-Host ""
Write-Host "Next: associate this DCR with your AVD session host VMs:" -ForegroundColor Yellow
Write-Host "  az monitor data-collection rule association create ``"
Write-Host "    --name 'assoc-$DcrName' ``"
Write-Host "    --resource '<VM-Resource-Id>' ``"
Write-Host "    --rule-id '$DcrId'"
Write-Host ""
Write-Host "After 5-15 minutes, you should see data in BOTH tables:"
Write-Host "  - InsightsMetrics"
Write-Host "  - Perf"
