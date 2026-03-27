<#
.SYNOPSIS
  Creates or updates a Data Collection Rule (DCR) for AVD session host monitoring,
  discovers all AVD host pools in the subscription, and interactively associates
  the DCR with session hosts across selected host pools.
  Repository: https://github.com/AzaryaShaulov/AVD

.DESCRIPTION
  Builds a DCR that collects performance counters from AVD session hosts into both
  the InsightsMetrics and Perf tables in a Log Analytics workspace. The DCR defines
  two performanceCounter data sources - one mapped to Microsoft-InsightsMetrics and
  one mapped to Microsoft-Perf - with both streams flowing to the same LAW destination.

  After the DCR is created, the script scans the subscription for all AVD host pools
  and prompts the user to associate the DCR with:
    [A] All host pools
    [S] A selection of specific host pools (by number)
    [N] Skip association

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
  Array of performance counter specifiers to collect. Defaults include CPU, memory, disk latency 
  (logical and physical), disk queue depth, network bandwidth (sent/received/total), and network queue length.

.PARAMETER TranscriptPath
  Optional path to save a transcript of the script execution.

.PARAMETER InstallAma
  Also check and install Azure Monitor Agent (AMA) extension on session host VMs during DCR association.
  Without this switch the script creates/updates the DCR and associates it but skips AMA install checks.

.PARAMETER AmaOnly
  Run AMA validation/install workflow only. Skips LAW/DCR validation, DCR create/update, and DCR associations.
  Implies -InstallAma.

.PARAMETER WhatIf
  Built-in common parameter (SupportsShouldProcess). Preview changes without applying them.

.EXAMPLE
  # Create DCR, discover all host pools, and interactively associate (no AMA install)
  .\AVD-Insights-Enable-PerfMetrics-Monitoring.ps1 -SubscriptionId "YOUR-SUB-ID" `
    -LawRG "rg-avd-monitoring" -LawName "law-avd-prod" -DcrRG "rg-avd-monitoring" `
    -DcrName "AVD-SessionHost-DCR" -Location "eastus2"

.EXAMPLE
  # Same as above, but also install AMA on VMs that are missing it
  .\AVD-Insights-Enable-PerfMetrics-Monitoring.ps1 -SubscriptionId "YOUR-SUB-ID" `
    -LawRG "rg-avd-monitoring" -LawName "law-avd-prod" -DcrRG "rg-avd-monitoring" `
    -DcrName "AVD-SessionHost-DCR" -Location "eastus2" -InstallAma

.EXAMPLE
  # WhatIf preview - no changes applied, host pools listed
  .\AVD-Insights-Enable-PerfMetrics-Monitoring.ps1 -SubscriptionId "YOUR-SUB-ID" `
    -LawRG "rg-avd-monitoring" -LawName "law-avd-prod" -DcrRG "rg-avd-monitoring" `
    -DcrName "AVD-SessionHost-DCR" -Location "eastus2" -WhatIf

.EXAMPLE
  # With transcript logging
  .\AVD-Insights-Enable-PerfMetrics-Monitoring.ps1 -SubscriptionId "YOUR-SUB-ID" `
    -LawRG "rg-avd-monitoring" -LawName "law-avd-prod" -DcrRG "rg-avd-monitoring" `
    -DcrName "AVD-SessionHost-DCR" -Location "eastus2" `
    -TranscriptPath "C:\Logs\DCR-Setup.log" -Verbose

.NOTES
  Requires: Azure CLI with Monitoring Contributor + Desktop Virtualization Reader permissions
  Version: 1.8 (Added AVD-specific counters: input delay, RTT, UDP, GPU, Terminal Services; disk instances changed to per-volume)
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
  [Parameter(Mandatory = $true)]
  [ValidateNotNullOrEmpty()]
  [string]$SubscriptionId,

  [Parameter(Mandatory = $false)]
  [ValidateNotNullOrEmpty()]
  [Alias("LawResourceGroup")]
  [string]$LawRG = "rg-avd-monitoring",

  [Parameter(Mandatory = $false)]
  [ValidateNotNullOrEmpty()]
  [Alias("LawWorkspace")]
  [string]$LawName = "law-avd-prod",

  [Parameter(Mandatory = $false)]
  [ValidateNotNullOrEmpty()]
  [string]$DcrRG = "rg-avd-monitoring",

  [Parameter(Mandatory = $false)]
  [ValidateNotNullOrEmpty()]
  [string]$DcrName = "AVD-SessionHost-DCR",

  [Parameter(Mandatory = $false)]
  [ValidateNotNullOrEmpty()]
  [string]$Location = "EastUS2",

  [Parameter(Mandatory = $false)]
  [ValidateRange(10, 3600)]
  [int]$SamplingFrequencyInSeconds = 60,

  [Parameter(Mandatory = $false)]
  [string[]]$CounterSpecifiers = @(
    # CPU
    "\\Processor Information(_Total)\\% Processor Time",
    # Memory
    "\\Memory\\Available MBytes",
    "\\Memory\\% Committed Bytes In Use",
    "\\Memory\\Pages/sec",
    "\\Memory\\Page Faults/sec",
    # Disk - Capacity (per-volume for C: and other drives)
    "\\LogicalDisk(*)\\% Free Space",
    # Disk - Latency (per-volume and per-physical-disk)
    "\\LogicalDisk(*)\\Avg. Disk sec/Read",
    "\\LogicalDisk(*)\\Avg. Disk sec/Write",
    "\\LogicalDisk(*)\\Avg. Disk sec/Transfer",
    "\\PhysicalDisk(*)\\Avg. Disk sec/Read",
    "\\PhysicalDisk(*)\\Avg. Disk sec/Write",
    "\\PhysicalDisk(*)\\Avg. Disk sec/Transfer",
    # Disk - Queue
    "\\LogicalDisk(*)\\Current Disk Queue Length",
    "\\PhysicalDisk(*)\\Avg. Disk Queue Length",
    # AVD Session Quality - User Input Delay
    "\\User Input Delay per Process(*)\\Max Input Delay",
    "\\User Input Delay per Session(*)\\Max Input Delay",
    # AVD Session Quality - RemoteFX Network
    "\\RemoteFX Network(*)\\Current TCP RTT",
    "\\RemoteFX Network(*)\\Current UDP Bandwidth",
    # AVD Session Quality - RemoteFX Graphics (GPU hosts)
    "\\RemoteFX Graphics(*)\\Average Encoding Time",
    # AVD Session Lifecycle - Terminal Services
    "\\Terminal Services\\Active Sessions",
    "\\Terminal Services\\Inactive Sessions",
    "\\Terminal Services\\Total Sessions",
    # Network - Bandwidth (bytes per second)
    "\\Network Adapter(*)\\Bytes Total/sec",
    "\\Network Adapter(*)\\Bytes Received/sec",
    "\\Network Adapter(*)\\Bytes Sent/sec",
    "\\Network Adapter(*)\\Current Bandwidth",
    # Network - Queue
    "\\Network Adapter(*)\\Output Queue Length"
  ),

  [Parameter(Mandatory = $false)]
  [string]$TranscriptPath,

  [Parameter(Mandatory = $false)]
  [switch]$InstallAma,

  [Parameter(Mandatory = $false)]
  [switch]$AmaOnly
)

$ErrorActionPreference = "Stop"
$scriptStart = Get-Date

function Get-VMInfoFromResourceId {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceId
  )

  $pattern = '^/subscriptions/[^/]+/resourceGroups/(?<rg>[^/]+)/providers/Microsoft\.Compute/virtualMachines/(?<vm>[^/]+)$'
  if ($ResourceId -match $pattern) {
    return [PSCustomObject]@{
      ResourceGroup = $matches['rg']
      VmName        = $matches['vm']
    }
  }

  return $null
}

function Test-AmaExtensionInstalled {
  param(
    [Parameter(Mandatory = $true)]
    [string]$VmResourceGroup,

    [Parameter(Mandatory = $true)]
    [string]$VmName,

    [Parameter(Mandatory = $true)]
    [string]$ExtensionName
  )

  $global:LASTEXITCODE = 0
  az vm extension show `
    --resource-group $VmResourceGroup `
    --vm-name $VmName `
    --name $ExtensionName `
    --only-show-errors `
    -o none 2>$null

  return ($LASTEXITCODE -eq 0)
}

function Get-VmOsType {
  param(
    [Parameter(Mandatory = $true)]
    [string]$VmResourceGroup,

    [Parameter(Mandatory = $true)]
    [string]$VmName
  )

  $global:LASTEXITCODE = 0
  $osType = az vm show `
    --resource-group $VmResourceGroup `
    --name $VmName `
    --query "storageProfile.osDisk.osType" `
    --only-show-errors `
    -o tsv 2>$null

  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($osType)) {
    return $null
  }

  return $osType.Trim()
}

function Install-AmaExtension {
  param(
    [Parameter(Mandatory = $true)]
    [string]$VmResourceGroup,

    [Parameter(Mandatory = $true)]
    [string]$VmName,

    [Parameter(Mandatory = $true)]
    [string]$ExtensionName
  )

  $global:LASTEXITCODE = 0
  $installErr = $null
  $prevEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  $installOutput = az vm extension set `
    --resource-group $VmResourceGroup `
    --vm-name $VmName `
    --publisher "Microsoft.Azure.Monitor" `
    --name $ExtensionName `
    --enable-auto-upgrade true `
    --only-show-errors `
    -o none 2>&1
  $installExitCode = $LASTEXITCODE
  $ErrorActionPreference = $prevEAP
  if ($installExitCode -ne 0) {
    $installErr = $installOutput
  }

  if ($installExitCode -ne 0) {
    return [PSCustomObject]@{
      Success = $false
      Error   = $installErr
    }
  }

  return [PSCustomObject]@{
    Success = $true
    Error   = $null
  }
}

if ($TranscriptPath) {
  try {
    Start-Transcript -Path $TranscriptPath -Append -ErrorAction Stop
    Write-Verbose "Transcript started: $TranscriptPath"
  } catch {
    Write-Warning "Failed to start transcript: $_"
  }
}

try {
  if ($AmaOnly) {
    $InstallAma = [switch]::new($true)
    Write-Verbose "-AmaOnly implies -InstallAma; AMA checks will run."
  }

  #region Prerequisites Check
  if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw "Azure CLI (az) not found. Please install and try again."
  }

  Write-Verbose "Checking Azure CLI login status..."
  $global:LASTEXITCODE = 0
  az account show -o none 2>$null
  if ($LASTEXITCODE -ne 0) {
    throw "Azure CLI not logged in. Run 'az login' and try again."
  }

  Write-Verbose "Setting subscription: $SubscriptionId"
  az account set --subscription $SubscriptionId --only-show-errors 2>$null
  if ($LASTEXITCODE -ne 0) { throw "Failed to set subscription: $SubscriptionId" }

  $LawId = $null
  $DcrId = $null

  if (-not $AmaOnly) {
    # Validate resource groups exist
    Write-Verbose "Validating resource groups..."
    foreach ($rg in @($LawRG, $DcrRG) | Select-Object -Unique) {
      $rgExists = az group exists --name $rg 2>$null
      if ($rgExists -ne "true") {
        throw "Resource group '$rg' does not exist in subscription $SubscriptionId"
      }
    }

    # Resolve LAW resourceId
    Write-Verbose "Resolving Log Analytics Workspace ID..."
    $global:LASTEXITCODE = 0
    $LawId = az monitor log-analytics workspace show -g $LawRG -n $LawName --query id -o tsv --only-show-errors 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($LawId)) {
      throw "Could not resolve LAW workspace $LawName in RG $LawRG"
    }
    $LawId = $LawId.Trim()

    # Check if DCR exists (distinguish ResourceNotFound from other errors)
    Write-Verbose "Checking if DCR '$DcrName' exists..."
    $exists = $true
    $global:LASTEXITCODE = 0
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $dcrCheckErr = az monitor data-collection rule show -g $DcrRG -n $DcrName -o none --only-show-errors 2>&1
    $dcrCheckExitCode = $LASTEXITCODE
    $ErrorActionPreference = $prevEAP
    if ($dcrCheckExitCode -ne 0) {
      $errText = ($dcrCheckErr | Out-String)
      if ($errText -match "ResourceNotFound|could not be found|not found") {
        $exists = $false
        Write-Verbose "DCR does not exist; will create new."
      } else {
        throw "Failed to check DCR existence for '$DcrName': $errText"
      }
    } else {
      Write-Verbose "DCR exists; will update."
    }
  } else {
    Write-Verbose "AmaOnly enabled: skipping LAW/DCR validation and DCR provisioning."
  }
  #endregion

  if (-not $AmaOnly) {
    #region DCR Creation
    # Consistent naming for DCR components (names must be <=32 chars)
    $laName = "destination-LAW"
    $perfInsightsName = "datasource-InsightsMetrics"
    $perfTableName = "datasource-Perf"

  # Build DCR JSON (Perf + InsightsMetrics)
  Write-Verbose "Building DCR JSON payload..."
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

  Write-Verbose "DCR JSON written to: $tmp"

    try {
    if (-not (Test-Path $tmp) -or ((Get-Item $tmp).Length -eq 0)) {
      throw "DCR JSON temp file missing or empty: $tmp"
    }

    $action = if ($exists) { "Updating" } else { "Creating" }

    if ($PSCmdlet.ShouldProcess("$DcrName in RG $DcrRG", "$action DCR")) {
      Write-Host "$action DCR $DcrName (Perf + InsightsMetrics)..." -ForegroundColor Cyan

      # 'create' is idempotent (ARM PUT) - works for both new and existing DCRs
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
      Write-Verbose "DCR ID resolved: $DcrId"
    } else {
      Write-Host "[WhatIf] Would $($action.ToLower()) DCR '$DcrName' in RG '$DcrRG'." -ForegroundColor DarkYellow
      $DcrId = "<WhatIf-DcrId>"
    }
  } finally {
    Remove-Item $tmp -ErrorAction SilentlyContinue
  }

    Write-Host "DCR ready: $DcrName" -ForegroundColor Green
    Write-Host "DCR Id: $DcrId"
    Write-Host ""
    #endregion
  } else {
    Write-Host "AmaOnly mode enabled: skipping DCR create/update and associations." -ForegroundColor DarkGray
    Write-Host ""
  }

  #region Host Pool Association
  # Ensure the desktopvirtualization CLI extension is present
  Write-Verbose "Checking for desktopvirtualization CLI extension..."
  $global:LASTEXITCODE = 0
  az extension show --name desktopvirtualization -o none 2>$null
  if ($LASTEXITCODE -ne 0) {
    Write-Host "Installing required Azure CLI extension: desktopvirtualization..." -ForegroundColor DarkGray
    az extension add --name desktopvirtualization --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw "Failed to install 'desktopvirtualization' Azure CLI extension." }
  }

  Write-Host "Scanning for AVD host pools in subscription..." -ForegroundColor Cyan
  $global:LASTEXITCODE = 0
  $hostPoolsErr = $null
  $prevEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  $hostPoolsJson = az desktopvirtualization hostpool list `
    --query "[].{name:name, rg:resourceGroup}" `
    -o json --only-show-errors 2>&1
  $hpExitCode = $LASTEXITCODE
  $ErrorActionPreference = $prevEAP
  if ($hpExitCode -ne 0) {
    $hostPoolsErr = $hostPoolsJson
  }

  if ($hpExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($hostPoolsJson)) {
    Write-Warning "Could not enumerate host pools: $hostPoolsErr"
    Write-Warning "Skipping association."
  } else {
  [array]$hostPools = ($hostPoolsJson -join "`n") | ConvertFrom-Json

  if ($hostPools.Count -eq 0) {
    Write-Warning "No host pools found in subscription. Skipping association."
  } else {
    Write-Host ""
    Write-Host "Discovered $($hostPools.Count) host pool(s):" -ForegroundColor Yellow
    for ($i = 0; $i -lt $hostPools.Count; $i++) {
      Write-Host ("  [{0}] {1}  (RG: {2})" -f ($i + 1), $hostPools[$i].name, $hostPools[$i].rg)
    }
    Write-Host ""

    $operationTarget = if ($AmaOnly) { "process AMA checks/installs" } else { "associate DCR '$DcrName'" }

    if ($WhatIfPreference) {
      Write-Host "[WhatIf] Would prompt to $operationTarget across the above host pool(s)." -ForegroundColor DarkYellow
    } else {
      if ($AmaOnly) {
        Write-Host "Process AMA checks/installs for session hosts in:" -ForegroundColor Cyan
      } else {
        Write-Host "Associate DCR '$DcrName' with session hosts in:" -ForegroundColor Cyan
      }
      Write-Host "  [A] All host pools"
      Write-Host "  [S] Select specific host pools"
      Write-Host "  [N] Skip"
      Write-Host ""
      $choice = (Read-Host "Choice").Trim().ToUpper()

      $selectedPools = @()
      switch ($choice) {
        'A' {
          $selectedPools = $hostPools
        }
        'S' {
          $raw = Read-Host "Enter pool numbers (comma-separated, e.g. 1,3)"
          foreach ($idx in ($raw -split '\s*,\s*')) {
            $n = 0
            if ([int]::TryParse($idx.Trim(), [ref]$n) -and $n -ge 1 -and $n -le $hostPools.Count) {
              $selectedPools += $hostPools[$n - 1]
            } else {
              Write-Warning "Invalid selection '$idx' - skipped."
            }
          }
        }
        'N' {
          Write-Host "Skipping association." -ForegroundColor DarkGray
        }
        default {
          Write-Warning "Unrecognized choice '$choice'. Skipping association."
        }
      }

      if ($selectedPools.Count -gt 0) {
        $totalSuccess = 0
        $totalFail    = 0
        $totalSkipped = 0
        $amaAlreadyInstalled = 0
        $amaInstalledNow     = 0
        $amaInstallFailed    = 0
        $amaCheckFailed      = 0
        $poolCount    = 0

        # Count total VMs for progress
        Write-Verbose "Counting total session hosts..."
        $totalVMs = 0
        foreach ($pool in $selectedPools) {
          $vmCountRaw = az rest --method get `
            --uri "/subscriptions/$SubscriptionId/resourceGroups/$($pool.rg)/providers/Microsoft.DesktopVirtualization/hostPools/$($pool.name)/sessionHosts?api-version=2021-07-12" `
            --query "length(value)" `
            -o tsv 2>$null
          if ($LASTEXITCODE -eq 0 -and $vmCountRaw) {
            $totalVMs += [int]$vmCountRaw.Trim()
          }
        }
        Write-Verbose "Total session hosts to process: $totalVMs"

        $currentVM = 0
        foreach ($pool in $selectedPools) {
          $poolCount++
          Write-Host ""
          Write-Host "[$poolCount/$($selectedPools.Count)] Host pool: $($pool.name)  (RG: $($pool.rg))" -ForegroundColor Cyan

          $global:LASTEXITCODE = 0
          $vmIdsErr = $null
          $prevEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
          $vmIdsRaw = az rest --method get `
            --uri "/subscriptions/$SubscriptionId/resourceGroups/$($pool.rg)/providers/Microsoft.DesktopVirtualization/hostPools/$($pool.name)/sessionHosts?api-version=2021-07-12" `
            --query "value[].properties.resourceId" `
            -o tsv 2>&1
          $vmIdsExitCode = $LASTEXITCODE
          $ErrorActionPreference = $prevEAP
          if ($vmIdsExitCode -ne 0) {
            $vmIdsErr = $vmIdsRaw
          }

          if ($vmIdsExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($vmIdsRaw)) {
            Write-Warning "  Could not enumerate session hosts: $vmIdsErr"
            continue
          }

          $vmIds = ($vmIdsRaw -split "`n") | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
          Write-Host "  Found $($vmIds.Count) session host(s). Associating..." -ForegroundColor Gray

          foreach ($vmId in $vmIds) {
            $currentVM++
            $vmName = ($vmId -split '/')[-1]
            $assocName = "assoc-$DcrName-$vmName" # Unique per VM

            $vmInfo = Get-VMInfoFromResourceId -ResourceId $vmId
            if (-not $InstallAma) {
              Write-Verbose "Skipping AMA check/install for $vmName (use -InstallAma to enable)."
            } elseif (-not $vmInfo) {
              Write-Warning "    Unable to parse VM resource ID: $vmId"
              $amaCheckFailed++
            } else {
              Write-Verbose "Checking AMA extension on VM: $($vmInfo.VmName) (RG: $($vmInfo.ResourceGroup))"
              $osType = Get-VmOsType -VmResourceGroup $vmInfo.ResourceGroup -VmName $vmInfo.VmName
              if ([string]::IsNullOrWhiteSpace($osType)) {
                Write-Warning "    Could not determine OS type for VM '$($vmInfo.VmName)'."
                $amaCheckFailed++
              } else {
                $amaExtensionName = if ($osType -eq 'Linux') { 'AzureMonitorLinuxAgent' } else { 'AzureMonitorWindowsAgent' }
                $isAmaInstalled = Test-AmaExtensionInstalled -VmResourceGroup $vmInfo.ResourceGroup -VmName $vmInfo.VmName -ExtensionName $amaExtensionName

                if ($isAmaInstalled) {
                  Write-Verbose "    AMA extension already installed ($amaExtensionName)."
                  $amaAlreadyInstalled++
                } else {
                  if ($PSCmdlet.ShouldProcess($vmInfo.VmName, "Install AMA extension '$amaExtensionName'")) {
                    Write-Host "    AMA extension missing. Installing $amaExtensionName on $($vmInfo.VmName)..." -ForegroundColor Gray
                    $installResult = Install-AmaExtension -VmResourceGroup $vmInfo.ResourceGroup -VmName $vmInfo.VmName -ExtensionName $amaExtensionName
                    if ($installResult.Success) {
                      Write-Verbose "    AMA extension installed successfully on $($vmInfo.VmName)."
                      $amaInstalledNow++
                    } else {
                      Write-Warning "    Failed to install AMA extension on $($vmInfo.VmName)."
                      if ($installResult.Error) {
                        Write-Verbose "    AMA install error details: $($installResult.Error)"
                      }
                      $amaInstallFailed++
                    }
                  } else {
                    Write-Host "`[WhatIf`] Would install AMA extension '${amaExtensionName}' on '$($vmInfo.VmName)'." -ForegroundColor DarkYellow
                  }
                }
              }
            }

            if ($AmaOnly) {
              continue
            }

            if (-not $PSCmdlet.ShouldProcess($vmName, "Associate DCR '$DcrName'")) {
              continue
            }

            # Show progress (guard against division by zero)
            $percentComplete = if ($totalVMs -gt 0) { 
              [math]::Round(($currentVM / $totalVMs) * 100, 1) 
            } else { 
              0 
            }
            $statusMessage = ('Processing {0} ({1}/{2})' -f $vmName, $currentVM, $totalVMs)
            Write-Progress -Activity "Associating DCR with Session Hosts" -Status $statusMessage -PercentComplete $percentComplete

            # Check if association already exists
            Write-Verbose "Checking existing association for $vmName..."
            $global:LASTEXITCODE = 0
            az monitor data-collection rule association show `
              --name $assocName `
              --resource $vmId `
              -o none 2>$null

            if ($LASTEXITCODE -eq 0) {
              Write-Verbose "    Association already exists for $vmName. Skipping."
              $totalSkipped++
              continue
            }

            Write-Host "    Associating: $vmName" -ForegroundColor Gray
            $global:LASTEXITCODE = 0
            $assocErr = $null
            $prevEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
            $assocOutput = az monitor data-collection rule association create `
              --name $assocName `
              --resource $vmId `
              --rule-id $DcrId `
              --only-show-errors `
              -o none 2>&1
            $assocExitCode = $LASTEXITCODE
            $ErrorActionPreference = $prevEAP
            if ($assocExitCode -ne 0) {
              $assocErr = $assocOutput
            }

            if ($assocExitCode -ne 0) {
              Write-Warning "    Failed to associate DCR with $vmName"
              if ($assocErr) {
                Write-Verbose "    Error details: $assocErr"
              }
              $totalFail++
            } else {
              $totalSuccess++
            }
          }
        }

        Write-Progress -Activity "Associating DCR with Session Hosts" -Completed

        # Enhanced summary report
        $duration = (Get-Date) - $scriptStart
        Write-Host ""
        Write-Host "=== Association Summary ===" -ForegroundColor Cyan
        Write-Host "Total Pools Processed: $($selectedPools.Count)"
        if ($AmaOnly) {
          Write-Host "DCR association: skipped by parameter (-AmaOnly)" -ForegroundColor DarkGray
        } else {
          Write-Host "Successful: $totalSuccess" -ForegroundColor Green
          if ($totalSkipped -gt 0) {
            Write-Host "Skipped (already associated): $totalSkipped" -ForegroundColor DarkGray
          }
          if ($totalFail -gt 0) {
            Write-Host "Failed: $totalFail" -ForegroundColor Yellow
          }
        }
        if (-not $InstallAma) {
          Write-Host "AMA check/install: skipped (use -InstallAma to enable)" -ForegroundColor DarkGray
        } else {
          Write-Host "AMA already installed: $amaAlreadyInstalled" -ForegroundColor DarkGray
          Write-Host "AMA installed by script: $amaInstalledNow" -ForegroundColor Green
          if ($amaCheckFailed -gt 0) {
            Write-Host "AMA check failed: $amaCheckFailed" -ForegroundColor Yellow
          }
          if ($amaInstallFailed -gt 0) {
            Write-Host "AMA install failed: $amaInstallFailed" -ForegroundColor Yellow
          }
        }
        Write-Host "Duration: $($duration.ToString('mm\:ss'))"
      }
    }
  }
}
  #endregion

  Write-Host ""
  if ($AmaOnly) {
    Write-Host "AmaOnly run completed. DCR operations and associations were not executed." -ForegroundColor DarkGray
  } else {
    Write-Host "After 5-15 minutes, you should see data in BOTH tables:"
    Write-Host "  - InsightsMetrics"
    Write-Host "  - Perf"
  }

  #region Next Steps Report
  if (-not $AmaOnly -and $DcrId -and $DcrId -ne '<WhatIf-DcrId>') {
    Write-Host ""
    Write-Host "===============================================================================" -ForegroundColor Cyan
    Write-Host " NEXT STEPS - Azure Policy for AMA Deployment" -ForegroundColor Cyan
    Write-Host "===============================================================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "To automatically install the Azure Monitor Agent on all session hosts," -ForegroundColor Yellow
    Write-Host "assign the following built-in Azure Policy:" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Policy: Configure Windows machines to run Azure Monitor Agent" -ForegroundColor White
    Write-Host "          and associate them to a Data Collection Rule" -ForegroundColor White
    Write-Host ""
    Write-Host "  DCR Resource Id to use as the policy parameter:" -ForegroundColor White
    Write-Host "  $DcrId" -ForegroundColor Green
    Write-Host ""
    Write-Host "Assign the policy at the subscription or resource-group scope that" -ForegroundColor Yellow
    Write-Host "contains your AVD session hosts." -ForegroundColor Yellow
    Write-Host "===============================================================================" -ForegroundColor Cyan

    # Generate README_NextSteps.txt
    $nextStepsFile = Join-Path $PSScriptRoot "README_NextSteps.txt"
    $nextStepsContent = @"
================================================================================
 NEXT STEPS - Azure Policy for Azure Monitor Agent (AMA) Deployment
================================================================================

After running AVD-Insights-Enable-PerfMetrics-Monitoring.ps1, the Data
Collection Rule (DCR) has been created and associated with your host pools.

To ensure the Azure Monitor Agent is installed (and stays installed) on every
session host, assign the following built-in Azure Policy:

  Policy name:
    Configure Windows machines to run Azure Monitor Agent and associate
    them to a Data Collection Rule

  Policy definition ID:
    /providers/Microsoft.Authorization/policyDefinitions/244efd75-0d92-453c-b9a3-7d73ca36ed52

  DCR Resource Id (use as the policy parameter "dcrResourceId"):
    $DcrId

How to assign in the Azure Portal:
  1. Go to Azure Policy > Definitions
  2. Search for "Configure Windows machines to run Azure Monitor Agent"
  3. Click the policy, then click "Assign"
  4. Set the scope to the subscription or resource group(s) containing
     your AVD session hosts
  5. On the Parameters tab, paste the DCR Resource Id shown above
  6. On the Remediation tab, check "Create a remediation task" to
     install AMA on existing VMs
  7. Review and create the assignment

DCR Details:
  Name:           $DcrName
  Resource Group: $DcrRG
  Location:       $Location

Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') UTC
================================================================================
"@
    $nextStepsContent | Out-File -FilePath $nextStepsFile -Encoding utf8 -Force
    Write-Host ""
    Write-Host "Saved: $nextStepsFile" -ForegroundColor Green
  }
  #endregion
} finally {
  if ($TranscriptPath) {
    try {
      Stop-Transcript -ErrorAction SilentlyContinue | Out-Null
      Write-Verbose "Transcript stopped."
    } catch {
      # Suppress transcript stop errors
    }
  }
}
