<#
.SYNOPSIS
  Minimal script to enable Azure Monitor diagnostic settings for AVD resources.

.DESCRIPTION
  Discovers AVD resources and configures diagnostic settings to send logs to a Log Analytics workspace.
  Enforces CategoryGroup "allLogs" wherever supported, and verifies it after apply.

.PARAMETER SubscriptionId
  Azure subscription ID. Defaults to "00000000-0000-0000-0000-000000000000" (replace with your subscription ID).

.PARAMETER WorkspaceName
  Name of the Log Analytics workspace. Defaults to "AVD-LAW
.PARAMETER WorkspaceResourceGroup
  Resource group containing the Log Analytics workspace. Defaults to "az-infra-eus2".

.PARAMETER DiagnosticSettingName
  Name for the diagnostic settings to create/update.

.PARAMETER CsvPath
  Path for CSV export file.

.PARAMETER CheckOnly
  Only check and display current diagnostic settings status without making changes.

.EXAMPLE
  .\AvdDiag-minimal.ps1 -SubscriptionId "YOUR-SUBSCRIPTION-ID"
  Runs with specified subscription ID and default workspace values.

.EXAMPLE
  .\AvdDiag-minimal.ps1 -SubscriptionId "YOUR-SUBSCRIPTION-ID" -WorkspaceName "YourLAW" -WorkspaceResourceGroup "YourRG"
  Override all default values with custom subscription and workspace.

.EXAMPLE
  .\AvdDiag-minimal.ps1 -CheckOnly -SubscriptionId "YOUR-SUBSCRIPTION-ID"
  Check current diagnostic settings status without making changes.

.NOTES
  Requires: Azure CLI with Monitoring Contributor permissions
  Version: 1.1 (Enforce allLogs + verify)
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory = $false)]
  [ValidateNotNullOrEmpty()]
  [string]$SubscriptionId = "00000000-0000-0000-0000-000000000000",

  [Parameter(Mandatory = $false)]
  [ValidateNotNullOrEmpty()]
  [string]$WorkspaceName = "AVD-LAW",

  [Parameter(Mandatory = $false)]
  [ValidateNotNullOrEmpty()]
  [string]$WorkspaceResourceGroup = "az-infra-eus2",

  [Parameter(Mandatory = $false)]
  [string]$DiagnosticSettingName = "AVD-Diagnostics",

  [Parameter(Mandatory = $false)]
  [string]$CsvPath = ".\avd-diagnostics-minimal.csv",

  [Parameter(Mandatory = $false)]
  [switch]$CheckOnly
)

$ErrorActionPreference = "Stop"

# Resource types
$resourceTypes = @(
  "Microsoft.DesktopVirtualization/hostPools",
  "Microsoft.DesktopVirtualization/applicationGroups",
  "Microsoft.DesktopVirtualization/workspaces"
)

# =========================
# Helper Functions
# =========================

function Write-Log {
  param($Message, $Color = "White")
  $timestamp = Get-Date -Format "HH:mm:ss"
  Write-Host "[$timestamp] $Message" -ForegroundColor $Color
}

function Get-DiagnosticStatus {
  param(
    [string]$ResourceId,
    [string]$DiagName
  )

  $existing = az monitor diagnostic-settings show --resource $ResourceId --name $DiagName -o json --only-show-errors 2>$null

  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($existing)) {
    return [pscustomobject]@{
      Status            = "Not Configured"
      HasEnabledLogs    = $false
      UsesAllLogs       = $false
      HasEnabledMetrics = $false
    }
  }

  try {
    $settings = $existing | ConvertFrom-Json

    $hasEnabledLogs = $false
    $usesAllLogs    = $false

    if ($settings.logs) {
      $enabledLogs = $settings.logs | Where-Object { $_.enabled -eq $true }
      $hasEnabledLogs = ($enabledLogs.Count -gt 0)

      # True if any enabled log entry uses categoryGroup == "allLogs"
      $usesAllLogs = ($enabledLogs | Where-Object {
        $_.PSObject.Properties.Name -contains "categoryGroup" -and $_.categoryGroup -eq "allLogs"
      }).Count -gt 0
    }

    $hasEnabledMetrics = $false
    if ($settings.metrics) {
      $hasEnabledMetrics = ($settings.metrics | Where-Object { $_.enabled -eq $true }).Count -gt 0
    }

    if ($hasEnabledLogs -or $hasEnabledMetrics) {
      if ($usesAllLogs) {
        $status = "Enabled (allLogs)"
      } else {
        $status = "Enabled (not allLogs)"
      }
    } else {
      $status = "Disabled"
    }

    return [pscustomobject]@{
      Status            = $status
      HasEnabledLogs    = $hasEnabledLogs
      UsesAllLogs       = $usesAllLogs
      HasEnabledMetrics = $hasEnabledMetrics
    }
  }
  catch {
    return [pscustomobject]@{
      Status            = "Unknown"
      HasEnabledLogs    = $false
      UsesAllLogs       = $false
      HasEnabledMetrics = $false
    }
  }
}

function Get-AllLogsSupport {
  param([string]$ResourceId)

  $catsJson = az monitor diagnostic-settings categories list --resource $ResourceId -o json --only-show-errors 2>$null
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($catsJson)) {
    return [pscustomobject]@{ Supported = $false; Categories = @() }
  }

  $cats = ($catsJson | ConvertFrom-Json).value
  if (-not $cats) { $cats = @() }

  $allLogsGroup = $cats | Where-Object { $_.categoryType -eq "CategoryGroup" -and $_.name -eq "allLogs" } | Select-Object -First 1
  return [pscustomobject]@{ Supported = [bool]$allLogsGroup; Categories = $cats }
}

function New-ResultObject {
  param(
    [string]$Name,
    [string]$Type,
    [string]$ResourceGroup,
    [string]$Status,
    [string]$Action = "",
    [bool]$AllLogsSupported = $false,
    [string]$PostStatus = "",
    [string]$Error = ""
  )
  
  return [pscustomobject]@{
    Name            = $Name
    Type            = $Type
    ResourceGroup   = $ResourceGroup
    Status          = $Status
    Action          = $Action
    AllLogsSupported= $AllLogsSupported
    PostStatus      = $PostStatus
    Error           = $Error
  }
}

function Get-ResourceTypeDisplayName {
  param([string]$ResourceType)
  return $ResourceType -replace 'Microsoft.DesktopVirtualization/', ''
}

function Build-CategoryPayload {
  param(
    [array]$Categories,
    [string]$CategoryType
  )
  
  $items = $Categories | Where-Object { $_.categoryType -eq $CategoryType } | Select-Object -ExpandProperty name
  if (-not $items -or $items.Count -eq 0) {
    return "[]"
  }
  
  $objects = $items | ForEach-Object { [pscustomobject]@{ category = $_; enabled = $true } }
  return $objects | ConvertTo-Json -Compress
}

function New-ResultObject {
  param(
    [string]$Name,
    [string]$Type,
    [string]$ResourceGroup,
    [string]$Status,
    [string]$Action = "",
    [bool]$AllLogsSupported = $false,
    [string]$PostStatus = "",
    [string]$Error = ""
  )
  
  return [pscustomobject]@{
    Name            = $Name
    Type            = $Type
    ResourceGroup   = $ResourceGroup
    Status          = $Status
    Action          = $Action
    AllLogsSupported= $AllLogsSupported
    PostStatus      = $PostStatus
    Error           = $Error
  }
}

function Get-ResourceTypeDisplayName {
  param([string]$ResourceType)
  return $ResourceType -replace 'Microsoft.DesktopVirtualization/', ''
}

function Build-CategoryPayload {
  param(
    [array]$Categories,
    [string]$CategoryType
  )
  
  $items = $Categories | Where-Object { $_.categoryType -eq $CategoryType } | Select-Object -ExpandProperty name
  if (-not $items -or $items.Count -eq 0) {
    return "[]"
  }
  
  $objects = $items | ForEach-Object { [pscustomobject]@{ category = $_; enabled = $true } }
  return $objects | ConvertTo-Json -Compress
}

# =========================
# Main Execution
# =========================

try {
  Write-Log "Starting AVD Diagnostics Configuration (enforce allLogs)" "Cyan"
  
  # Validate parameters based on mode
  if (-not $CheckOnly) {
    if ([string]::IsNullOrWhiteSpace($WorkspaceName)) {
      throw "WorkspaceName is required when not using -CheckOnly mode"
    }
    if ([string]::IsNullOrWhiteSpace($WorkspaceResourceGroup)) {
      throw "WorkspaceResourceGroup is required when not using -CheckOnly mode"
    }
  }
  
  Write-Log "Using Subscription: $SubscriptionId" "Gray"
  if (-not $CheckOnly) {
    Write-Log "Using Workspace: $WorkspaceName (RG: $WorkspaceResourceGroup)" "Gray"
  }

  # Check Azure CLI
  if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw "Azure CLI not found. Please install from: https://docs.microsoft.com/cli/azure/install-azure-cli"
  }

  # Set subscription
  Write-Log "Setting subscription context..."
  az account set --subscription $SubscriptionId --only-show-errors 2>$null
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to set subscription. Please run 'az login' first."
  }

  # Get LAW ID (skip in CheckOnly mode)
  $lawId = $null
  if (-not $CheckOnly) {
    Write-Log "Getting Log Analytics Workspace ID..."
    $lawId = az monitor log-analytics workspace show `
      -g $WorkspaceResourceGroup `
      -n $WorkspaceName `
      --subscription $SubscriptionId `
      --query id `
      -o tsv `
      --only-show-errors 2>$null

    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($lawId)) {
      throw "Log Analytics Workspace '$WorkspaceName' not found in resource group '$WorkspaceResourceGroup'"
    }

    Write-Log "LAW ID: $lawId" "Gray"
  }

  # Discover AVD resources
  Write-Log "Discovering AVD resources..."
  $allResources = @()

  foreach ($type in $resourceTypes) {
    $json = az resource list --subscription $SubscriptionId --resource-type $type -o json --only-show-errors 2>$null
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($json)) {
      $resources = $json | ConvertFrom-Json
      $allResources += $resources
    }
  }

  if ($allResources.Count -eq 0) {
    Write-Log "No AVD resources found in subscription. Exiting." "Yellow"
    exit 0
  }

  Write-Log "Found $($allResources.Count) AVD resources" "Green"

  # If CheckOnly mode, display status and exit
  if ($CheckOnly) {
    Write-Log ""
    Write-Log "=== Current Diagnostic Settings Status (allLogs enforcement view) ===" "Cyan"
    Write-Log ""

    $statusResults = @()

    foreach ($resource in $allResources) {
      $diag = Get-DiagnosticStatus -ResourceId $resource.id -DiagName $DiagnosticSettingName
      $support = Get-AllLogsSupport -ResourceId $resource.id
      $typeDisplay = Get-ResourceTypeDisplayName -ResourceType $resource.type

      $statusResults += [pscustomobject]@{
        Name            = $resource.name
        Type            = $typeDisplay
        ResourceGroup   = $resource.resourceGroup
        Status          = $diag.Status
        AllLogsSupported= $support.Supported
      }

      $statusColor = switch -Wildcard ($diag.Status) {
        "Enabled (allLogs)"     { "Green" }
        "Enabled (not allLogs)" { "Yellow" }
        "Not Configured"        { "Yellow" }
        "Disabled"              { "Red" }
        default                 { "Gray" }
      }

      $suffix = if ($support.Supported) { "allLogsSupported" } else { "noAllLogsGroup" }
      Write-Log "  $($resource.name) [$typeDisplay] - $($diag.Status) ($suffix)" $statusColor
    }

    Write-Log ""
    Write-Log "Summary:" "Cyan"
    $enabledAllLogs = ($statusResults | Where-Object Status -eq "Enabled (allLogs)").Count
    $enabledNotAll  = ($statusResults | Where-Object Status -eq "Enabled (not allLogs)").Count
    $notConfigured  = ($statusResults | Where-Object Status -eq "Not Configured").Count
    $disabled       = ($statusResults | Where-Object Status -eq "Disabled").Count

    Write-Log "  Enabled (allLogs): $enabledAllLogs" "Green"
    Write-Log "  Enabled (not allLogs): $enabledNotAll" "Yellow"
    Write-Log "  Not Configured: $notConfigured" "Yellow"
    Write-Log "  Disabled: $disabled" $(if ($disabled -gt 0) { "Red" } else { "White" })

    # Export status
    if ($statusResults.Count -gt 0) {
      $statusResults | Export-Csv -NoTypeInformation -Path $CsvPath -Force
      Write-Log ""
      Write-Log "Status exported to: $CsvPath" "Green"
    }

    exit 0
  }

  # Process each resource
  $results = @()
  $success = 0
  $failed  = 0

  foreach ($resource in $allResources) {
    Write-Log "Processing: $($resource.name)" "Cyan"

    try {
      $diag = Get-DiagnosticStatus -ResourceId $resource.id -DiagName $DiagnosticSettingName

      # Determine category support and categories up-front (also used to build payload)
      $supportObj = Get-AllLogsSupport -ResourceId $resource.id
      $cats = $supportObj.Categories
      $allLogsSupported = $supportObj.Supported

      # Skip ONLY if already enabled AND uses allLogs (when supported)
      if ($diag.Status -eq "Enabled (allLogs)") {
        Write-Log "  ⚠ Already configured with allLogs - skipping" "Yellow"
        $results += New-ResultObject -Name $resource.name -Type $resource.type -ResourceGroup $resource.resourceGroup `
          -Status "Skipped" -Action "already-allLogs" -AllLogsSupported $allLogsSupported -PostStatus $diag.Status
        continue
      }

      if ($diag.Status -eq "Enabled (not allLogs)" -and $allLogsSupported) {
        Write-Log "  ⚠ Configured but NOT using allLogs (supported) - will update" "Yellow"
      } elseif ($diag.Status -eq "Enabled (not allLogs)" -and -not $allLogsSupported) {
        Write-Log "  ⚠ Configured without allLogs (not supported) - will proceed to ensure logs/metrics are enabled" "Yellow"
      }

      # Need categories to proceed
      if (-not $cats -or $cats.Count -eq 0) {
        throw "No diagnostic categories available"
      }

      # Build logs payload (enforce allLogs if available)
      if ($allLogsSupported) {
        $logsJson = '[{ "categoryGroup": "allLogs", "enabled": true }]'
      } else {
        $logsJson = Build-CategoryPayload -Categories $cats -CategoryType "Logs"
      }

      # Build metrics payload
      $metricsJson = Build-CategoryPayload -Categories $cats -CategoryType "Metrics"

      # Determine create vs update
      $existing = az monitor diagnostic-settings show --resource $resource.id --name $DiagnosticSettingName -o json --only-show-errors 2>$null
      $operation = if ($LASTEXITCODE -eq 0) { "update" } else { "create" }

      # Apply diagnostic settings (use --metrics only if any)
      $cmd = "az monitor diagnostic-settings $operation --name $DiagnosticSettingName --resource `"$($resource.id)`" --workspace `"$lawId`" --logs '$logsJson'"
      if ($metricsJson -ne "[]") {
        $cmd += " --metrics '$metricsJson'"
      }
      $cmd += " -o json --only-show-errors 2>&1"

      $output = Invoke-Expression $cmd
      
      if ($LASTEXITCODE -ne 0) {
        # Check if it's a conflict error about duplicate diagnostic settings
        if ($output -match "Conflict.*Data sink.*already used" -or $output -match "can't be reused") {
          throw "Conflict detected: Logs are already being sent to workspace '$WorkspaceName' by another diagnostic setting. Cannot have duplicate settings for the same category."
        }
        throw "Command failed with exit code $LASTEXITCODE. Error: $output"
      }

      # Post-apply verification: ensure allLogs is used when supported
      $post = Get-DiagnosticStatus -ResourceId $resource.id -DiagName $DiagnosticSettingName
      if ($allLogsSupported -and $post.Status -ne "Enabled (allLogs)") {
        throw "Verification failed: expected Enabled (allLogs) but got '$($post.Status)'"
      }

      Write-Log "  ✓ Success ($operation) - $($post.Status)" "Green"
      $success++

      $results += New-ResultObject -Name $resource.name -Type $resource.type -ResourceGroup $resource.resourceGroup `
        -Status "Success" -Action $operation -AllLogsSupported $allLogsSupported -PostStatus $post.Status
    }
    catch {
      Write-Log "  ✗ Failed: $($_.Exception.Message)" "Red"
      $failed++

      $results += New-ResultObject -Name $resource.name -Type $resource.type -ResourceGroup $resource.resourceGroup `
        -Status "Failed" -Error $_.Exception.Message
    }
  }

  # Export results
  if ($results.Count -gt 0) {
    $results | Export-Csv -NoTypeInformation -Path $CsvPath -Force
    Write-Log "Results exported to: $CsvPath" "Green"
  }

  # Summary
  $skipped = ($results | Where-Object Status -eq "Skipped").Count

  Write-Log ""
  Write-Log "=== Summary ===" "Cyan"
  Write-Log "Total: $($allResources.Count)" "White"
  Write-Log "Success: $success" "Green"
  Write-Log "Skipped (already allLogs): $skipped" "Yellow"
  Write-Log "Failed: $failed" $(if ($failed -gt 0) { "Red" } else { "Green" })

  if ($failed -gt 0) {
    Write-Log ""
    Write-Log "Failed resources:" "Yellow"
    $results | Where-Object Status -eq "Failed" | ForEach-Object {
      Write-Log "  - $($_.Name): $($_.Error)" "Yellow"
    }
    exit 1
  }

  exit 0
}
catch {
  Write-Log "FATAL ERROR: $($_.Exception.Message)" "Red"
  exit 2
}