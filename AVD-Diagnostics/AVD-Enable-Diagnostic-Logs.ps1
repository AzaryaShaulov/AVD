<#
.SYNOPSIS
  Minimal script to enable Azure Monitor diagnostic settings for AVD resources.
  Repository: https://github.com/AzaryaShaulov/AVD

.DESCRIPTION
  Discovers AVD resources and configures diagnostic settings to send logs to a Log Analytics workspace.
  Enforces CategoryGroup "allLogs" wherever supported, and verifies it after apply.

.PARAMETER SubscriptionId
  Azure subscription ID (required).

.PARAMETER WorkspaceName
  Name of the Log Analytics workspace. Defaults to "AVD-LAW".

.PARAMETER WorkspaceResourceGroupName
  Resource group containing the Log Analytics workspace. Defaults to "rg-avd-monitoring".
  Alias: -WorkspaceResourceGroup (backward compatible).

.PARAMETER DiagnosticSettingName
  Name for the diagnostic settings to create/update.

.PARAMETER CsvPath
  Path for CSV export file.

.PARAMETER CheckOnly
  Only check and display current diagnostic settings status without making changes.

.EXAMPLE
  .\AVD-Enable-Diagnostic-Logs.ps1 -SubscriptionId "YOUR-SUBSCRIPTION-ID"
  Runs with specified subscription ID and default workspace values.

.EXAMPLE
  .\AVD-Enable-Diagnostic-Logs.ps1 -SubscriptionId "YOUR-SUBSCRIPTION-ID" -WorkspaceName "YourLAW" -WorkspaceResourceGroupName "YourRG"
  Override all default values with custom subscription and workspace.

.EXAMPLE
  .\AVD-Enable-Diagnostic-Logs.ps1 -CheckOnly -SubscriptionId "YOUR-SUBSCRIPTION-ID"
  Check current diagnostic settings status without making changes.

.NOTES
  Requires: Azure CLI with Monitoring Contributor permissions
  Version: 1.2 (Bug fixes + robustness improvements)
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidateNotNullOrEmpty()]
  [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
  [string]$SubscriptionId,

  [Parameter(Mandatory = $false)]
  [ValidateNotNullOrEmpty()]
  [string]$WorkspaceName = "AVD-LAW",

  [Parameter(Mandatory = $false)]
  [ValidateNotNullOrEmpty()]
  [Alias('WorkspaceResourceGroup')]
  [string]$WorkspaceResourceGroupName = "rg-avd-monitoring",

  [Parameter(Mandatory = $false)]
  [string]$DiagnosticSettingName = "AVD-Diagnostics",

  [Parameter(Mandatory = $false)]
  [string]$CsvPath,

  [Parameter(Mandatory = $false)]
  [switch]$CheckOnly
)

$ErrorActionPreference = "Stop"

# Track execution time
$ScriptStartTime = Get-Date

if ([string]::IsNullOrWhiteSpace($CsvPath)) {
  $csvBasePath = if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) { "." } else { $PSScriptRoot }
  $CsvPath = Join-Path -Path $csvBasePath -ChildPath 'avd-diagnostics-minimal.csv'
}

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

  try {
    function Get-DiagnosticFlags {
      param([object]$SettingsObject)

      $enabledLogs = @()
      if ($SettingsObject.logs) {
        $enabledLogs = @($SettingsObject.logs | Where-Object { $_.enabled -eq $true })
      }

      $enabledMetrics = @()
      if ($SettingsObject.metrics) {
        $enabledMetrics = @($SettingsObject.metrics | Where-Object { $_.enabled -eq $true })
      }

      $usesAllLogs = ($enabledLogs | Where-Object {
        $_.PSObject.Properties.Name -contains "categoryGroup" -and $_.categoryGroup -eq "allLogs"
      }).Count -gt 0

      return [pscustomobject]@{
        HasEnabledLogs    = ($enabledLogs.Count -gt 0)
        HasEnabledMetrics = ($enabledMetrics.Count -gt 0)
        UsesAllLogs       = $usesAllLogs
      }
    }

    $global:LASTEXITCODE = 0
    $existing = az monitor diagnostic-settings show --resource $ResourceId --name $DiagName -o json --only-show-errors 2>$null
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($existing)) {
      $settings = $existing | ConvertFrom-Json
      $flags = Get-DiagnosticFlags -SettingsObject $settings
      if ($flags.HasEnabledLogs -or $flags.HasEnabledMetrics) {
        $status = if ($flags.UsesAllLogs) { "Enabled (allLogs)" } else { "Enabled (not allLogs)" }
      } else {
        $status = "Disabled"
      }

      return [pscustomobject]@{
        Status            = $status
        HasEnabledLogs    = $flags.HasEnabledLogs
        UsesAllLogs       = $flags.UsesAllLogs
        HasEnabledMetrics = $flags.HasEnabledMetrics
        ActiveSettingName = $DiagName
        IsNamedSetting    = $true
      }
    }

    # If the named setting does not exist, inspect all settings to avoid false "Not Configured".
    $global:LASTEXITCODE = 0
    $allSettingsJson = az monitor diagnostic-settings list --resource $ResourceId -o json --only-show-errors 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($allSettingsJson)) {
      return [pscustomobject]@{
        Status            = "Not Configured"
        HasEnabledLogs    = $false
        UsesAllLogs       = $false
        HasEnabledMetrics = $false
        ActiveSettingName = ""
        IsNamedSetting    = $false
      }
    }

    $allSettings = $allSettingsJson | ConvertFrom-Json
    if ($null -eq $allSettings) {
      $allSettings = @()
    } elseif (-not ($allSettings -is [System.Array])) {
      $allSettings = @($allSettings)
    }

    if ($allSettings.Count -eq 0) {
      return [pscustomobject]@{
        Status            = "Not Configured"
        HasEnabledLogs    = $false
        UsesAllLogs       = $false
        HasEnabledMetrics = $false
        ActiveSettingName = ""
        IsNamedSetting    = $false
      }
    }

    $firstEnabled = $allSettings | Where-Object {
      $flags = Get-DiagnosticFlags -SettingsObject $_
      $flags.HasEnabledLogs -or $flags.HasEnabledMetrics
    } | Select-Object -First 1

    if ($null -eq $firstEnabled) {
      $firstSetting = $allSettings | Select-Object -First 1
      return [pscustomobject]@{
        Status            = "Disabled (other setting)"
        HasEnabledLogs    = $false
        UsesAllLogs       = $false
        HasEnabledMetrics = $false
        ActiveSettingName = $firstSetting.name
        IsNamedSetting    = $false
      }
    }

    $enabledFlags = Get-DiagnosticFlags -SettingsObject $firstEnabled
    $otherStatus = if ($enabledFlags.UsesAllLogs) { "Enabled (allLogs, other setting)" } else { "Enabled (other setting)" }

    return [pscustomobject]@{
      Status            = $otherStatus
      HasEnabledLogs    = $enabledFlags.HasEnabledLogs
      UsesAllLogs       = $enabledFlags.UsesAllLogs
      HasEnabledMetrics = $enabledFlags.HasEnabledMetrics
      ActiveSettingName = $firstEnabled.name
      IsNamedSetting    = $false
    }
  }
  catch {
    return [pscustomobject]@{
      Status            = "Unknown"
      HasEnabledLogs    = $false
      UsesAllLogs       = $false
      HasEnabledMetrics = $false
      ActiveSettingName = ""
      IsNamedSetting    = $false
    }
  }
}

function Get-AllLogsSupport {
  param([string]$ResourceId)

  $global:LASTEXITCODE = 0
  $catsJson = az monitor diagnostic-settings categories list --resource $ResourceId -o json --only-show-errors 2>$null
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($catsJson)) {
    return [pscustomobject]@{ Supported = $false; Categories = @() }
  }

  $parsedCats = $catsJson | ConvertFrom-Json
  if ($null -eq $parsedCats) {
    $cats = @()
  } elseif ($parsedCats -is [System.Array]) {
    $cats = $parsedCats
  } elseif ($parsedCats.PSObject.Properties.Name -contains "value") {
    $cats = @($parsedCats.value)
  } else {
    $cats = @($parsedCats)
  }

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
    [string]$ErrorMessage = ""
  )
  
  return [pscustomobject]@{
    Name            = $Name
    Type            = $Type
    ResourceGroup   = $ResourceGroup
    Status          = $Status
    Action          = $Action
    AllLogsSupported= $AllLogsSupported
    PostStatus      = $PostStatus
    Error           = $ErrorMessage
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
  
  $objects = @($items | ForEach-Object { [pscustomobject]@{ category = $_; enabled = $true } })
  return ConvertTo-Json -InputObject $objects -Compress
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
    if ([string]::IsNullOrWhiteSpace($WorkspaceResourceGroupName)) {
      throw "WorkspaceResourceGroupName is required when not using -CheckOnly mode"
    }
  }
  
  Write-Log "Using Subscription: $SubscriptionId" "Gray"
  if (-not $CheckOnly) {
    Write-Log "Using Workspace: $WorkspaceName (RG: $WorkspaceResourceGroupName)" "Gray"
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
      -g $WorkspaceResourceGroupName `
      -n $WorkspaceName `
      --subscription $SubscriptionId `
      --query id `
      -o tsv `
      --only-show-errors 2>$null

    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($lawId)) {
      throw "Log Analytics Workspace '$WorkspaceName' not found in resource group '$WorkspaceResourceGroupName'"
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
        Action          = "N/A"
        AllLogsSupported= $support.Supported
        PostStatus      = $diag.Status
        Error           = ""
      }

      $statusColor = switch -Wildcard ($diag.Status) {
        "Enabled (allLogs*)"    { "Green" }
        "Enabled (not allLogs)" { "Yellow" }
        "Enabled (other setting)" { "Yellow" }
        "Not Configured"        { "Yellow" }
        "Disabled*"             { "Red" }
        default                 { "Gray" }
      }

      $suffix = if ($support.Supported) { "allLogsSupported" } else { "noAllLogsGroup" }
      Write-Log "  $($resource.name) [$typeDisplay] - $($diag.Status) ($suffix)" $statusColor
    }

    Write-Log ""
    Write-Log "Summary:" "Cyan"
    $enabledAllLogs = ($statusResults | Where-Object { $_.Status -like "Enabled (allLogs*" }).Count
    $enabledNotAll  = ($statusResults | Where-Object { $_.Status -eq "Enabled (not allLogs)" -or $_.Status -eq "Enabled (other setting)" }).Count
    $notConfigured  = ($statusResults | Where-Object Status -eq "Not Configured").Count
    $disabled       = ($statusResults | Where-Object { $_.Status -like "Disabled*" }).Count

    Write-Log "  Enabled (allLogs): $enabledAllLogs" "Green"
    Write-Log "  Enabled (not allLogs): $enabledNotAll" "Yellow"
    Write-Log "  Not Configured: $notConfigured" "Yellow"
    Write-Log "  Disabled: $disabled" $(if ($disabled -gt 0) { "Red" } else { "White" })

    # Export status
    if ($statusResults.Count -gt 0) {
      try {
        $csvDirectory = Split-Path $CsvPath -Parent
        if ($csvDirectory -and -not (Test-Path $csvDirectory)) {
          New-Item -ItemType Directory -Path $csvDirectory -Force | Out-Null
        }
        $statusResults | Export-Csv -NoTypeInformation -Path $CsvPath -Force -ErrorAction Stop
        Write-Log ""
        Write-Log "Status exported to: $CsvPath" "Green"
      }
      catch {
        Write-Log "Warning: Failed to export status to CSV: $($_.Exception.Message)" "Yellow"
        Write-Log "CSV Path attempted: $CsvPath" "Gray"
      }
    }

    $duration = (Get-Date) - $ScriptStartTime
    Write-Log ""
    Write-Log "Execution time: $($duration.TotalSeconds.ToString('F1')) seconds" "Gray"
    exit 0
  }

  # Process each resource
  $results = @()
  $success = 0
  $failed  = 0
  $skippedAlreadyEnabled = 0
  $skippedAlreadyAllLogs = 0
  $skippedConflicts = 0
  $resourceCount = 0

  foreach ($resource in $allResources) {
    $resourceCount++
    $percentComplete = [Math]::Round(($resourceCount / $allResources.Count) * 100)
    Write-Progress -Activity "Configuring Diagnostic Settings" -Status "Processing $($resource.name) ($resourceCount of $($allResources.Count))" -PercentComplete $percentComplete
    
    Write-Log "Processing: $($resource.name)" "Cyan"

    try {
      $typeDisplay = Get-ResourceTypeDisplayName -ResourceType $resource.type
      $diag = Get-DiagnosticStatus -ResourceId $resource.id -DiagName $DiagnosticSettingName
      $targetDiagnosticSettingName = if (-not [string]::IsNullOrWhiteSpace($diag.ActiveSettingName)) { $diag.ActiveSettingName } else { $DiagnosticSettingName }

      # Determine category support and categories up-front (also used to build payload)
      $supportObj = Get-AllLogsSupport -ResourceId $resource.id
      $cats = $supportObj.Categories
      $allLogsSupported = $supportObj.Supported

      # Enforce allLogs where supported; otherwise keep previous behavior and skip any enabled diagnostics.
      $shouldSkip = $false
      $isAllLogs = $diag.Status -like "Enabled (allLogs*"

      if ($isAllLogs) {
        $shouldSkip = $true
      } elseif ((-not $allLogsSupported) -and ($diag.Status -match "^Enabled")) {
        $shouldSkip = $true
      }

      if ($shouldSkip) {
        $action = if ($isAllLogs) { "allLogs" } else { "without-allLogs" }
        $detail = if ($isAllLogs) { "with allLogs" } else { "(not using allLogs$(if (-not $allLogsSupported) { ' - not supported' }))" }
        Write-Log "  [OK] Already enabled $detail - skipping" "Green"
        $results += New-ResultObject -Name $resource.name -Type $typeDisplay -ResourceGroup $resource.resourceGroup `
          -Status "AlreadyEnabled" -Action $action -AllLogsSupported $allLogsSupported -PostStatus $diag.Status
        if ($isAllLogs) { $skippedAlreadyAllLogs++ } else { $skippedAlreadyEnabled++ }
        continue
      }

      if ($allLogsSupported -and $diag.Status -match "^Enabled") {
        if (-not $diag.IsNamedSetting -and -not [string]::IsNullOrWhiteSpace($diag.ActiveSettingName)) {
          Write-Log "  i Enforcing allLogs on existing setting '$($diag.ActiveSettingName)'" "Yellow"
        } else {
          Write-Log "  i Enforcing allLogs on existing setting '$DiagnosticSettingName'" "Yellow"
        }
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

      # Apply diagnostic settings using 'create' (idempotent - creates or updates)
      $azArgs = @(
        'monitor', 'diagnostic-settings', 'create',
        '--name', $targetDiagnosticSettingName,
        '--resource', $resource.id,
        '--workspace', $lawId,
        '--logs', $logsJson
      )
      if ($metricsJson -ne "[]") {
        $azArgs += @('--metrics', $metricsJson)
      }
      $azArgs += @('-o', 'json', '--only-show-errors')

      $global:LASTEXITCODE = 0
      $output = & az @azArgs 2>&1 | Out-String
      
      if ($LASTEXITCODE -ne 0) {
        # Try to parse JSON error response for structured error handling
        $errorMessage = $output
        try {
          $errorObj = $output | ConvertFrom-Json -ErrorAction SilentlyContinue
          if ($errorObj.error.code -eq 'Conflict' -or $errorObj.error.message -match 'already used|can''t be reused') {
            Write-Log "  [OK] Already configured (different diagnostic setting name) - skipping" "Green"
            $results += New-ResultObject -Name $resource.name -Type $typeDisplay -ResourceGroup $resource.resourceGroup `
              -Status "AlreadyEnabled" -Action "conflict" -AllLogsSupported $allLogsSupported `
              -PostStatus "Enabled (other diagnostic setting)" -ErrorMessage "No changes made - logs already being sent to this workspace"
            $skippedConflicts++
            continue
          }
          if ($errorObj.error.message) { $errorMessage = $errorObj.error.message }
        }
        catch {
          # Not a JSON error response - check raw text as fallback
          if ($output -match "Conflict.*Data sink.*already used" -or $output -match "can't be reused") {
            Write-Log "  [OK] Already configured (different diagnostic setting name) - skipping" "Green"
            $results += New-ResultObject -Name $resource.name -Type $typeDisplay -ResourceGroup $resource.resourceGroup `
              -Status "AlreadyEnabled" -Action "conflict" -AllLogsSupported $allLogsSupported `
              -PostStatus "Enabled (other diagnostic setting)" -ErrorMessage "No changes made - logs already being sent to this workspace"
            $skippedConflicts++
            continue
          }
        }
        throw "Command failed with exit code $LASTEXITCODE. Error: $errorMessage"
      }

      # Post-apply verification: ensure allLogs is used when supported.
      $post = Get-DiagnosticStatus -ResourceId $resource.id -DiagName $targetDiagnosticSettingName
      if ($allLogsSupported -and ($post.Status -notlike "Enabled (allLogs*)")) {
        throw "Verification failed: expected Enabled (allLogs) but got '$($post.Status)'"
      }
      if (-not $allLogsSupported -and $post.Status -notmatch "^Enabled") {
        throw "Verification failed: expected enabled diagnostics but got '$($post.Status)'"
      }

      $operation = if ($diag.Status -match "^Enabled" -or $diag.Status -like "Disabled (*") { "update" } else { "create" }
      Write-Log "  [OK] Success ($operation) - $($post.Status)" "Green"
      $success++

      $results += New-ResultObject -Name $resource.name -Type $typeDisplay -ResourceGroup $resource.resourceGroup `
        -Status "Success" -Action $operation -AllLogsSupported $allLogsSupported -PostStatus $post.Status
    }
    catch {
      Write-Log "  [FAIL] Failed: $($_.Exception.Message)" "Red"
      $failed++

      $results += New-ResultObject -Name $resource.name -Type $typeDisplay -ResourceGroup $resource.resourceGroup `
        -Status "Failed" -ErrorMessage $_.Exception.Message
    }
  }
  
  Write-Progress -Activity "Configuring Diagnostic Settings" -Completed

  # Export results
  if ($results.Count -gt 0) {
    try {
      $csvDirectory = Split-Path $CsvPath -Parent
      if ($csvDirectory -and -not (Test-Path $csvDirectory)) {
        New-Item -ItemType Directory -Path $csvDirectory -Force | Out-Null
      }
      $results | Export-Csv -NoTypeInformation -Path $CsvPath -Force -ErrorAction Stop
      Write-Log "Results exported to: $CsvPath" "Green"
    }
    catch {
      Write-Log "Warning: Failed to export results to CSV: $($_.Exception.Message)" "Yellow"
      Write-Log "CSV Path attempted: $CsvPath" "Gray"
    }
  }

  # Summary
  $skipped = ($results | Where-Object Status -eq "AlreadyEnabled").Count
  $created = ($results | Where-Object Action -eq "create").Count
  $updated = ($results | Where-Object Action -eq "update").Count

  Write-Log ""
  Write-Log "=== Diagnostic Settings Summary ===" "Cyan"
  Write-Log ""
  Write-Log "Total Resources Processed: $($allResources.Count)" "White"
  Write-Log ""
  Write-Log "Already Enabled (no changes made):" "Cyan"
  Write-Log "  - With allLogs: $skippedAlreadyAllLogs" "Green"
  Write-Log "  - Without allLogs: $skippedAlreadyEnabled" "Green"
  Write-Log "  - Conflicts (other diagnostic setting): $skippedConflicts" "Green"
  Write-Log "  - Total Skipped: $skipped" "Green"
  Write-Log ""
  Write-Log "Changes Made:" "Cyan"
  Write-Log "  - Created: $created" $(if ($created -gt 0) { "Green" } else { "White" })
  Write-Log "  - Updated: $updated" $(if ($updated -gt 0) { "Green" } else { "White" })
  Write-Log "  - Success: $success" "Green"
  Write-Log "  - Failed: $failed" $(if ($failed -gt 0) { "Red" } else { "Green" })
  Write-Log ""

  if ($results.Count -gt 0) {
    Write-Log "Detailed Breakdown by Resource Type:" "Cyan"
    $results | Group-Object { $_.Type } | ForEach-Object {
      $type = $_.Name
      $typeResults = $_.Group
      $typeEnabled = ($typeResults | Where-Object Status -eq "AlreadyEnabled").Count
      $typeSuccess = ($typeResults | Where-Object Status -eq "Success").Count
      $typeFailed = ($typeResults | Where-Object Status -eq "Failed").Count
      Write-Log "  $type - Total: $($typeResults.Count), Enabled: $typeEnabled, Success: $typeSuccess, Failed: $typeFailed" "Gray"
    }
    Write-Log ""
  }

  if ($failed -gt 0) {
    Write-Log ""
    Write-Log "Failed resources:" "Yellow"
    $results | Where-Object Status -eq "Failed" | ForEach-Object {
      Write-Log "  - $($_.Name): $($_.Error)" "Yellow"
    }
    exit 1
  }

  $duration = (Get-Date) - $ScriptStartTime
  Write-Log ""
  Write-Log "Execution time: $($duration.TotalSeconds.ToString('F1')) seconds" "Gray"
  exit 0
}
catch {
  Write-Log "FATAL ERROR: $($_.Exception.Message)" "Red"
  $duration = (Get-Date) - $ScriptStartTime
  Write-Log "Execution time: $($duration.TotalSeconds.ToString('F1')) seconds" "Gray"
  exit 2
}


