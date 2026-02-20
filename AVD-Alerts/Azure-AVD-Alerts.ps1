#requires -Version 5.1
<#
==============================================================================
SCRIPT VERSION: 2.1
LAST UPDATED: February 2026
==============================================================================
QUICK START:
1. Update the default parameter values in the script with your values:
   - EmailTo: Your email address for alert notifications
   - ResourceGroup: Your Azure resource group name
   - LawName: Your Log Analytics workspace name  
   - Location: Your Azure region (e.g., eastus, westus2)
   - ActionGroupName: Name of the Azure Monitor action group (default: "AVD-Alerts")
   - SubscriptionId: (Optional) Specify if you want to target a specific subscription

2. Run the script with defaults:
   .\Azure-AVD-Alerts.ps1

3. Or override any parameter:
   .\Azure-AVD-Alerts.ps1 -SubscriptionId "12345678-1234-1234-1234-123456789012" `
     -EmailTo "admin@contoso.com" -ResourceGroup "rg-avd" -LawName "law-avd" -Location "eastus2"
==============================================================================
.SYNOPSIS
  Creates scheduled query alerts for Azure Virtual Desktop monitoring.
  Repository: https://github.com/AzaryaShaulov/AVD

.DESCRIPTION
  Configures Log Analytics-based alerts for common AVD error conditions and sends
  notifications via email action group. Requires Azure CLI and appropriate permissions.
  
  REQUIRED: Update default parameter values (EmailTo, ResourceGroup, LawName, Location)
  in the script, or pass them as arguments when running the script.

.PARAMETER EmailTo
  Email address for alert notifications. Default: "your-email@domain.com"

.PARAMETER SubscriptionId
  Azure subscription ID. If not provided, uses the current subscription context.

.PARAMETER ActionGroupName
  Name of the Azure Monitor action group. If it already exists, the specified email will be
  added to it. If it does not exist, a new action group will be created. Default: "AVD-Alerts"

.PARAMETER ResourceGroup
  Resource group containing the Log Analytics workspace and action group.

.PARAMETER LawName
  Name of the Log Analytics workspace.

.PARAMETER Location
  Azure region for scheduled query rules.

.PARAMETER Severity
  Alert severity level (0=Critical, 1=Error, 2=Warning, 3=Informational, 4=Verbose).

.PARAMETER CsvPath
  Path for CSV export of created alerts.

.PARAMETER WhatIf
  Preview changes without creating/updating alerts.

.EXAMPLE
  # Run with default parameters (after updating defaults in script)
  .\Azure-AVD-Alerts.ps1

.EXAMPLE
  # Specify subscription ID
  .\Azure-AVD-Alerts.ps1 -SubscriptionId "12345678-1234-1234-1234-123456789012" -EmailTo "admin@contoso.com" -ResourceGroup "rg-avd-prod" -LawName "law-avd-prod"

.EXAMPLE
  # Override specific parameters
  .\Azure-AVD-Alerts.ps1 -EmailTo "admin@contoso.com" -ResourceGroup "rg-avd-prod" -LawName "law-avd-prod"

.EXAMPLE
  # Preview changes without creating alerts
  .\Azure-AVD-Alerts.ps1 -Severity 0 -WhatIf
#>

[CmdletBinding(SupportsShouldProcess)]
param(
  [Parameter(Mandatory = $false)]
  [ValidateNotNullOrEmpty()]
  [ValidatePattern('^[\w-\.]+@([\w-]+\.)+[\w-]{2,}$')]
  [string]$EmailTo = "your-email@domain.com",

  [Parameter(Mandatory = $false)]
  [ValidateNotNullOrEmpty()]
  [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
  [string]$SubscriptionId,

  [Parameter(Mandatory = $false)]
  [ValidateNotNullOrEmpty()]
  [string]$ActionGroupName = "AVD-Alerts",

  [Parameter(Mandatory = $false)]
  [ValidateNotNullOrEmpty()]
  [string]$ResourceGroup = "your-resource-group",

  [Parameter(Mandatory = $false)]
  [ValidateNotNullOrEmpty()]
  [string]$LawName = "your-log-analytics-workspace",

  [Parameter(Mandatory = $false)]
  [ValidateNotNullOrEmpty()]
  [string]$Location = "your-azure-region",

  [Parameter(Mandatory = $false)]
  [ValidateRange(0, 4)]
  [int]$Severity = 1,

  [Parameter(Mandatory = $false)]
  [string]$CsvPath
)

$ErrorActionPreference = "Stop"

# Track execution time
$ScriptStartTime = Get-Date

# Set CSV path default (include subscription ID if specified)
if (-not $CsvPath) {
  if ($SubscriptionId) {
    $CsvPath = ".\avd-alerts-report-$($SubscriptionId.Substring(0,8)).csv"
  } else {
    $CsvPath = ".\avd-alerts-report.csv"
  }
}

# ----------------------------
# Pre-flight Checks
# ----------------------------

# Check 1: Verify Azure CLI is installed
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
  throw "Azure CLI not found. Please install from https://learn.microsoft.com/cli/azure/install-azure-cli"
}

# Check 2: Verify Azure login
Write-Host "[Pre-flight] Checking Azure authentication..." -ForegroundColor Cyan
$accountInfo = az account show 2>$null | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or $null -eq $accountInfo) {
  throw "Not logged in to Azure. Please run 'az login' first."
}
Write-Host "[Pre-flight] Logged in as: $($accountInfo.user.name)" -ForegroundColor Gray

# Check 3: Set subscription context if specified
if ($SubscriptionId) {
  Write-Host "[Pre-flight] Setting subscription context: $SubscriptionId" -ForegroundColor Cyan
  az account set --subscription $SubscriptionId 2>$null
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to set subscription context to '$SubscriptionId'. Verify the subscription ID and your access."
  }
  # Refresh account info after setting subscription
  $accountInfo = az account show 2>$null | ConvertFrom-Json
}
Write-Host "[Pre-flight] Subscription: $($accountInfo.name) ($($accountInfo.id))" -ForegroundColor Gray

# Check 4: Validate placeholder parameters have been updated
$placeholderParams = @()
if ($EmailTo -eq "your-email@domain.com") { $placeholderParams += "EmailTo" }
if ($ResourceGroup -eq "your-resource-group") { $placeholderParams += "ResourceGroup" }
if ($LawName -eq "your-log-analytics-workspace") { $placeholderParams += "LawName" }
if ($Location -eq "your-azure-region") { $placeholderParams += "Location" }

if ($placeholderParams.Count -gt 0) {
  $paramList = $placeholderParams -join ", "
  throw "Please update the following parameter(s) with actual values: $paramList`nYou can either edit the default values in the script or pass them as arguments."
}

# Check 5: Verify RBAC permissions
# Required operations:
#   - Microsoft.Insights/scheduledQueryRules/*        (create/update/list alerts)
#   - Microsoft.Insights/actionGroups/*               (create/update action group)
#   - Microsoft.OperationalInsights/workspaces/read   (resolve LAW resource ID)
#
# Roles that satisfy all of the above:
#   Fully sufficient  : Owner | Contributor
#   Partially sufficient (both needed together): Monitoring Contributor + Log Analytics Contributor/Reader
Write-Host "[Pre-flight] Checking RBAC permissions..." -ForegroundColor Cyan

$rgScope = "/subscriptions/$($accountInfo.id)/resourceGroups/$ResourceGroup"

# Determine the signed-in principal's object ID (works for user and service principal)
$principalId = az ad signed-in-user show --query id -o tsv 2>$null
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($principalId)) {
  # Fallback: service principal / managed identity path
  $principalId = $accountInfo.user.name
}

# Fetch all role assignments at RG scope (inherited from sub/MG included)
$roleAssignmentsJson = az role assignment list `
  --assignee $principalId `
  --scope $rgScope `
  --include-inherited `
  --include-groups `
  --output json 2>$null

if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($roleAssignmentsJson)) {
  Write-Host "[Pre-flight] WARNING: Could not retrieve role assignments. Continuing, but ensure you have:" -ForegroundColor Yellow
  Write-Host "  - Microsoft.Insights/scheduledQueryRules/* on RG '$ResourceGroup'" -ForegroundColor Yellow
  Write-Host "  - Microsoft.Insights/actionGroups/* on RG '$ResourceGroup'" -ForegroundColor Yellow
  Write-Host "  - Microsoft.OperationalInsights/workspaces/read on RG '$ResourceGroup'" -ForegroundColor Yellow
} else {
  $roleAssignments = $roleAssignmentsJson | ConvertFrom-Json
  $assignedRoleNames = $roleAssignments | Select-Object -ExpandProperty roleDefinitionName

  # Built-in role IDs for programmatic matching (display names can be localised)
  $fullyQualifiedRoleIds = @(
    '8e3af657-a8ff-443c-a75c-2fe8c4bcb635'  # Owner
    'b24988ac-6180-42a0-ab88-20f7382dd24c'  # Contributor
  )
  $monitoringContributorId   = '749f88d5-cbae-40b8-bcfc-e573ddc772fa'
  $logAnalyticsContribId     = '92aaf0da-9dab-42b6-94a3-d43ce8d16293'
  $logAnalyticsReaderId      = '73c42c96-874c-492b-b04d-ab87d138a893'

  # Extract just the GUID portion from each roleDefinitionId
  $assignedRoleIds = $roleAssignments | ForEach-Object {
    ($_.roleDefinitionId -split '/')[-1]
  }

  $hasFullRole            = ($assignedRoleIds | Where-Object { $fullyQualifiedRoleIds -contains $_ }).Count -gt 0
  $hasMonitoringContrib   = $assignedRoleIds -contains $monitoringContributorId
  $hasLAWContribOrReader  = ($assignedRoleIds -contains $logAnalyticsContribId) -or
                             ($assignedRoleIds -contains $logAnalyticsReaderId)

  # ---- Evaluate coverage ----
  if ($hasFullRole) {
    $matchedRole = ($assignedRoleNames | Where-Object { $_ -in @('Owner','Contributor') } | Select-Object -First 1)
    Write-Host "[Pre-flight] RBAC OK - '$matchedRole' covers all required permissions." -ForegroundColor Green
  } elseif ($hasMonitoringContrib -and $hasLAWContribOrReader) {
    Write-Host "[Pre-flight] RBAC OK - 'Monitoring Contributor' + Log Analytics role cover all required permissions." -ForegroundColor Green
  } else {
    # Partial coverage - report exactly what is missing
    Write-Host "[Pre-flight] WARNING: Insufficient RBAC permissions detected." -ForegroundColor Yellow
    Write-Host ""  -ForegroundColor Yellow
    Write-Host "  Assigned roles on scope '$rgScope':" -ForegroundColor Yellow
    if ($assignedRoleNames.Count -gt 0) {
      $assignedRoleNames | ForEach-Object { Write-Host "    - $_" -ForegroundColor Gray }
    } else {
      Write-Host "    (none found)" -ForegroundColor Gray
    }
    Write-Host ""
    Write-Host "  Required permissions and recommended roles:" -ForegroundColor Yellow
    if (-not $hasMonitoringContrib) {
      Write-Host "  [MISSING] Microsoft.Insights/scheduledQueryRules/* and Microsoft.Insights/actionGroups/*" -ForegroundColor Red
      Write-Host "            -> Assign 'Monitoring Contributor' on RG '$ResourceGroup'" -ForegroundColor Red
    }
    if (-not $hasLAWContribOrReader) {
      Write-Host "  [MISSING] Microsoft.OperationalInsights/workspaces/read" -ForegroundColor Red
      Write-Host "            -> Assign 'Log Analytics Reader' on RG '$ResourceGroup'" -ForegroundColor Red
    }
    Write-Host ""
    Write-Host "  Quick fix - run these Azure CLI commands:" -ForegroundColor Cyan
    Write-Host "    az role assignment create --assignee '$principalId' --role 'Monitoring Contributor' --scope '$rgScope'" -ForegroundColor Cyan
    Write-Host "    az role assignment create --assignee '$principalId' --role 'Log Analytics Reader'   --scope '$rgScope'" -ForegroundColor Cyan
    Write-Host ""
    throw "Insufficient RBAC permissions. Please assign the roles listed above and re-run the script."
  }
}

# Alert cadence
$EvalFrequency = "PT5M"   # every 5 minutes
$WindowSize    = "PT5M"   # evaluation window (5 minutes)

# Track created alerts for CSV export
$AlertResults = @()
$ExistingAlerts = @()
$NewlyCreatedAlerts = @()

# Performance optimization: Get all existing alerts once
# Run in a background job with a timeout so a slow or hanging API call does not block the script.
Write-Host "[Pre-flight] Checking for existing alerts (timeout: 25s)..." -ForegroundColor Cyan
$script:existingAlertNamesList = $null  # Default: fall back to individual checks
try {
  $_listJobRg    = $ResourceGroup
  $_listJobSubId = $accountInfo.id
  $listJob = Start-Job -ScriptBlock {
    az monitor scheduled-query list -g $using:_listJobRg --subscription $using:_listJobSubId --query "[?starts_with(name, 'AVD-')].name" -o tsv 2>$null
  }

  $completed = Wait-Job $listJob -Timeout 25

  if ($null -ne $completed) {
    $existingAlertsOutput = Receive-Job $listJob -ErrorAction SilentlyContinue
    if (-not [string]::IsNullOrWhiteSpace($existingAlertsOutput)) {
      $script:existingAlertNamesList = $existingAlertsOutput -split "[\r\n]+" |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { $_.Trim() }
      Write-Host "[Pre-flight] Found $($script:existingAlertNamesList.Count) existing AVD alert(s)" -ForegroundColor Gray
    } else {
      Write-Host "[Pre-flight] No existing AVD alerts found - all will be created" -ForegroundColor Gray
      $script:existingAlertNamesList = @()  # Empty list (not null) = confirmed zero alerts exist
    }
  } else {
    Stop-Job $listJob -ErrorAction SilentlyContinue
    Write-Host "[Pre-flight] Alert list query timed out - will check each alert individually" -ForegroundColor Yellow
    $script:existingAlertNamesList = $null  # Trigger individual API calls for each alert
  }
  Remove-Job $listJob -Force -ErrorAction SilentlyContinue
} catch {
  Write-Host "[Pre-flight] Could not query existing alerts - will check individually" -ForegroundColor Yellow
  $script:existingAlertNamesList = $null
}

# ----------------------------
# Helper Functions
# ----------------------------
function Write-Log {
  param($Message, $Color = "White")
  $timestamp = Get-Date -Format "HH:mm:ss"
  Write-Host "[$timestamp] $Message" -ForegroundColor $Color
}

function Test-AlertExists {
  param([string]$AlertName)

  # Priority 1: Pre-built definitive map (built in main scope - most reliable)
  if ($null -ne $script:alertExistenceMap -and $script:alertExistenceMap.ContainsKey($AlertName)) {
    return $script:alertExistenceMap[$AlertName]
  }

  # Priority 2: Bulk-query cache from pre-flight (fast string compare)
  if ($null -ne $script:existingAlertNamesList) {
    return ($script:existingAlertNamesList -contains $AlertName)
  }

  # Priority 3: Individual API query (fallback when both cache sources are unavailable)
  az monitor scheduled-query show -g $ResourceGroup -n $AlertName --subscription $accountInfo.id -o none 2>$null
  return ($LASTEXITCODE -eq 0)
}

# ----------------------------
# Resolve Log Analytics Workspace Resource ID
# ----------------------------
Write-Log "Resolving Log Analytics Workspace: $LawName" "Cyan"

$LawId = az monitor log-analytics workspace show `
  -g $ResourceGroup `
  -n $LawName `
  --subscription $accountInfo.id `
  --query id -o tsv 2>$null

if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($LawId)) {
  throw "Could not resolve Log Analytics workspace id for '$LawName' in RG '$ResourceGroup'."
}

Write-Log "Log Analytics Workspace ID: $LawId" "Gray"

# ----------------------------
# Create / ensure Action Group (email)
# ----------------------------
Write-Log "Action Group  : $ActionGroupName" "Cyan"
Write-Log "Email Receiver: $EmailTo" "Cyan"

if ($PSCmdlet.ShouldProcess($ActionGroupName, "Create or update action group")) {
  # Check if action group exists
  $agDetailsJson = az monitor action-group show -g $ResourceGroup -n $ActionGroupName --subscription $accountInfo.id -o json 2>$null
  $agExists = ($LASTEXITCODE -eq 0)

  if (-not $agExists) {
    Write-Log "Action group '$ActionGroupName' not found - creating new action group..." "Yellow"
    $agOutput = az monitor action-group create `
      -g $ResourceGroup `
      -n $ActionGroupName `
      --subscription $accountInfo.id `
      --short-name "AVDAlerts" 2>&1
    
    if ($LASTEXITCODE -ne 0) {
      throw "Failed to create action group: $agOutput"
    }
    Write-Log "Action group '$ActionGroupName' created successfully." "Green"
    # Refresh details after creation
    $agDetailsJson = az monitor action-group show -g $ResourceGroup -n $ActionGroupName --subscription $accountInfo.id -o json 2>$null
  } else {
    Write-Log "Action group '$ActionGroupName' already exists - will add email '$EmailTo' to the existing action group." "Yellow"
  }

  # Parse action group details
  $agDetails = $agDetailsJson | ConvertFrom-Json
  
  # Create unique receiver name using first 8 chars + hash to prevent collisions
  $sha256 = [System.Security.Cryptography.SHA256]::Create()
  try {
    $emailHash = [BitConverter]::ToString($sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($EmailTo))).Replace('-','').Substring(0,8)
  } finally {
    $sha256.Dispose()
  }
  $emailPrefix = ($EmailTo -replace '[^a-zA-Z0-9]', '').Substring(0, [Math]::Min(12, ($EmailTo -replace '[^a-zA-Z0-9]', '').Length))
  $receiverName = "AVD$emailPrefix$emailHash"
  
  # Check if email receiver already exists with correct email (Phase 1 optimization)
  $existingReceiver = $agDetails.emailReceivers | Where-Object { $_.emailAddress -eq $EmailTo }
  
  if ($existingReceiver) {
    Write-Log "Email '$EmailTo' is already a receiver on action group '$ActionGroupName' - no change needed." "Gray"
  } else {
    Write-Log "Adding email receiver '$EmailTo' to action group '$ActionGroupName'..." "Gray"
    
    # Check if receiver exists with different email
    $receiverWithName = $agDetails.emailReceivers | Where-Object { $_.name -eq $receiverName }
    if ($receiverWithName -and $receiverWithName.emailAddress -ne $EmailTo) {
      Write-Log "Updating email receiver to new address: $EmailTo" "Yellow"
      # Remove old receiver first
      az monitor action-group update -g $ResourceGroup -n $ActionGroupName --subscription $accountInfo.id --remove emailReceivers name=$receiverName 2>&1 | Out-Null
    }
    
    # Add or update email receiver
    $emailOutput = az monitor action-group update `
      -g $ResourceGroup `
      -n $ActionGroupName `
      --subscription $accountInfo.id `
      --add-action email $receiverName $EmailTo 2>&1
    
    if ($LASTEXITCODE -ne 0) {
      # Parse error to determine if it's expected (duplicate) or actual failure
      $errorLower = ($emailOutput | Out-String).ToLower()
      if ($errorLower -match "already exists" -or $errorLower -match "duplicate" -or $errorLower -match "receiver.*exists") {
        Write-Log "Email receiver already configured" "Gray"
      } else {
        Write-Log "Warning: Failed to add email receiver: $emailOutput" "Yellow"
        Write-Log "This may not affect alert functionality if the receiver already exists" "Yellow"
      }
    }
  }
  
  $AgId = az monitor action-group show `
    -g $ResourceGroup `
    -n $ActionGroupName `
    --subscription $accountInfo.id `
    --query id -o tsv 2>$null

  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($AgId)) {
    throw "Failed to retrieve action group ID"
  }

  Write-Log "Action Group ID: $AgId" "Gray"
} else {
  Write-Log "[WhatIf] Would retrieve action group ID" "Yellow"
  # Get actual subscription ID for realistic WhatIf mode
  $subId = $accountInfo.id
  $AgId = "/subscriptions/$subId/resourceGroups/$ResourceGroup/providers/microsoft.insights/actionGroups/$ActionGroupName"
  Write-Log "Action Group ID (simulated): $AgId" "Gray"
}

# ----------------------------
# Helper: create/update scheduled query alert (Log Alert v2)
# ----------------------------
function New-OrUpdate-ScheduledQueryAlert {
  [CmdletBinding(SupportsShouldProcess)]
  param(
    [Parameter(Mandatory)][string]$AlertName,
    [Parameter(Mandatory)][string]$Kql,
    [Parameter(Mandatory)][string]$Description
  )

  $severityText = switch ($Severity) {
    0 { "Critical" }
    1 { "Error" }
    2 { "Warning" }
    3 { "Informational" }
    4 { "Verbose" }
  }

  # Check if alert already exists
  $alertExists = Test-AlertExists -AlertName $AlertName
  
  if ($alertExists) {
    $script:ExistingAlerts += $AlertName
  }

  if ($alertExists) {
    Write-Log "Skipping existing alert: $AlertName (already exists)" "Gray"
    $status = "Skipped"
    $action  = "Skipped"
  } elseif ($PSCmdlet.ShouldProcess($AlertName, "Create scheduled query alert")) {
    Write-Log "Creating new alert: $AlertName (Severity: $severityText)" "Cyan"

    try {
      # Convert multi-line query to single line for Azure CLI
      $queryEscaped = $Kql -replace "`r", "" -replace "`n", " "
      
      $azCmdArgs = @(
        'monitor', 'scheduled-query', 'create',
        '-g', $ResourceGroup, '-n', $AlertName, '-l', $Location,
        '--subscription', $accountInfo.id, '--scopes', $LawId,
        '--evaluation-frequency', $EvalFrequency, '--window-size', $WindowSize,
        '--severity', "$Severity", '--description', $Description,
        '--condition', "count 'Query1' > 0", '--condition-query', "Query1=$queryEscaped",
        '--action-groups', $AgId
      )
      $output = az @azCmdArgs 2>&1
      
      if ($LASTEXITCODE -eq 0) {
        Write-Log "  ✓ Success" "Green"
        $status = "Success"
        $action  = "Created"
        $script:NewlyCreatedAlerts += $AlertName
      } else {
        $errStr = ($output | Out-String).ToLower()
        if ($errStr -match "conflict|already exists") {
          Write-Log "  ~ Already exists (skipped)" "Gray"
          $status = "Skipped"
          $action  = "Skipped"
          $script:ExistingAlerts += $AlertName
        } else {
          Write-Log "  ✗ Failed: $output" "Red"
          $status = "Failed"
          $action  = "Failed"
        }
      }
    }
    catch {
      Write-Log "  ✗ Error: $($_.Exception.Message)" "Red"
      $status = "Error"
      $action  = "Error"
    }
  } else {
    Write-Log "[WhatIf] Would create alert: $AlertName" "Yellow"
    $status = "WhatIf"
    $action  = "WouldCreate"
  }

  # Track for CSV export
  $script:AlertResults += [pscustomobject]@{
    AlertName   = $AlertName
    Description = $Description
    Severity    = "$Severity ($severityText)"
    Action      = $action
    Status      = $status
  }
}

# ----------------------------
# Alerts (name must match CodeSymbolic)
# ----------------------------
Write-Log "" 
Write-Log "Processing AVD Alerts..." "Cyan"
Write-Log "" 

# Start timer for WhatIf status reporting
$alertProcessingStart = Get-Date
$lastStatusReport = $alertProcessingStart

# Alert definitions
$alertDefinitions = @(
  @{ Name = "AVD-PasswordMustChange"; Description = "Detects users who must change their password before logging into AVD. Triggers when a user's password policy requires a mandatory change."; CodeSymbolic = "PasswordMustChange" },
  @{ Name = "AVD-AccountLockedOut"; Description = "Detects user accounts that are locked out due to failed login attempts. Indicates potential security issues or users needing assistance."; CodeSymbolic = "AccountLockedOut" },
  @{ Name = "AVD-ConnectionFailedPersonalDesktopFailedToBeStarted"; Description = "Detects when a personal desktop VM fails to start for a connection attempt. May indicate VM configuration issues or Azure capacity problems."; CodeSymbolic = "ConnectionFailedPersonalDesktopFailedToBeStarted" },
  @{ Name = "AVD-PasswordExpired"; Description = "Detects users attempting to connect with expired passwords. Users must reset their password before accessing AVD."; CodeSymbolic = "PasswordExpired" },
  @{ Name = "AVD-AccountDisabled"; Description = "Detects connection attempts from disabled user accounts. Indicates terminated users trying to access AVD or account provisioning issues."; CodeSymbolic = "AccountDisabled" },
  @{ Name = "AVD-ConnectionFailedNoHealthyRdshAvailable"; Description = "Detects when no healthy session hosts are available in a host pool. Critical issue preventing all user connections - requires immediate attention."; CodeSymbolic = "ConnectionFailedNoHealthyRdshAvailable" },
  @{ Name = "AVD-ERROR_SHARING_VIOLATION"; Description = "Detects file sharing violations during user profile loading or application access. Often related to FSLogix profile conflicts or locked files."; CodeSymbolic = "ERROR_SHARING_VIOLATION" },
  @{ Name = "AVD-LogonFailed"; Description = "Detects failed user logon attempts to AVD session hosts. May indicate authentication issues, incorrect credentials, or account problems."; CodeSymbolic = "LogonFailed" },
  @{ Name = "AVD-UnloadWaitingForUserAction"; Description = "Detects when FSLogix profile unload is delayed waiting for user action. User may have unsaved work or active processes blocking logoff."; CodeSymbolic = "UnloadWaitingForUserAction" },
  @{ Name = "AVD-ConnectionFailedUserNotAuthorized"; Description = "Detects unauthorized connection attempts to AVD. User lacks permissions on the application group or workspace."; CodeSymbolic = "ConnectionFailedUserNotAuthorized" },
  @{ Name = "AVD-ConnectionFailedNoPreAssignedPersonalDesktopForUser"; Description = "Detects connection attempts when user has no personal desktop assigned. Occurs in personal host pools without desktop assignment."; CodeSymbolic = "ConnectionFailedNoPreAssignedPersonalDesktopForUser" },
  @{ Name = "AVD-ConnectionFailedClientConnectedTooLateReverseConnectionAlreadyClosed"; Description = "Detects when client connects too late and reverse connection is already closed. May indicate network latency or timeout issues."; CodeSymbolic = "ConnectionFailedClientConnectedTooLateReverseConnectionAlreadyClosed" },
  @{ Name = "AVD-GetInputDeviceHandlesError"; Description = "Detects errors initializing input device handles. May indicate driver issues or peripheral compatibility problems."; CodeSymbolic = "GetInputDeviceHandlesError" },
  @{ Name = "AVD-GraphicsCapsNotReceived"; Description = "Detects when graphics capabilities are not received during session initialization. May indicate GPU or graphics driver issues."; CodeSymbolic = "GraphicsCapsNotReceived" },
  @{ Name = "AVD-InvalidAuthToken"; Description = "Detects invalid or expired authentication tokens. Indicates authentication token validation failures or token expiration issues."; CodeSymbolic = "InvalidAuthToken" },
  @{ Name = "AVD-InvalidCredentials"; Description = "Detects login attempts with invalid credentials (wrong username or password). Indicates user credential issues or potential security concerns."; CodeSymbolic = "InvalidCredentials" },
  @{ Name = "AVD-LogonTypeNotGranted"; Description = "Detects when requested logon type is not granted by policy. User may lack required logon rights or policy restrictions are in place."; CodeSymbolic = "LogonTypeNotGranted" },
  @{ Name = "AVD-NotAuthorizedForLogon"; Description = "Detects users not authorized for logon. May indicate missing logon permissions or policy restrictions preventing access."; CodeSymbolic = "NotAuthorizedForLogon" },
  @{ Name = "AVD-OutOfMemory"; Description = "Detects session hosts running out of memory. Critical issue requiring immediate attention - may cause session crashes or prevent new connections."; CodeSymbolic = "OutOfMemory" },
  @{ Name = "AVD-SessionHostResourceNotAvailable"; Description = "Detects when session host resources are unavailable. May indicate capacity issues, host health problems, or resource exhaustion."; CodeSymbolic = "SessionHostResourceNotAvailable" }
)

# Build a definitive per-alert existence map in the main scope before any parallelism.
# This is the authoritative source - built with reliable $LASTEXITCODE using Test-AlertExists,
# which itself uses the bulk-query cache or individual API calls as needed.
$script:alertExistenceMap = @{}
Write-Log "Verifying existence of all $($alertDefinitions.Count) alerts..." "Cyan"
foreach ($alertDef in $alertDefinitions) {
  $script:alertExistenceMap[$alertDef.Name] = Test-AlertExists -AlertName $alertDef.Name
}
$existingCount = ($script:alertExistenceMap.Values | Where-Object { $_ -eq $true }).Count
$newCount = $alertDefinitions.Count - $existingCount
Write-Log "Verification complete: $existingCount alert(s) already exist, $newCount will be created." "Gray"
Write-Log "" 

# Phase 2: Parallel processing for faster execution
# Note: ForEach-Object -Parallel requires PowerShell 7+
if ($PSVersionTable.PSVersion.Major -ge 7) {
  Write-Log "Using parallel processing (PowerShell 7+)" "Cyan"
  
  # Parallel processing with throttling
  $throttleLimit = 5  # Process 5 alerts simultaneously
  $isWhatIf = $PSBoundParameters.ContainsKey('WhatIf')
  # Capture the pre-verified existence map into a regular variable for $using: scope
  $alertExistenceMapLocal = $script:alertExistenceMap

  $results = $alertDefinitions | ForEach-Object -ThrottleLimit $throttleLimit -Parallel {
    $alert = $_

    # Import shared variables using $using: scope
    $ResourceGroup    = $using:ResourceGroup
    $Location         = $using:Location
    $accountInfo      = $using:accountInfo
    $LawId            = $using:LawId
    $EvalFrequency    = $using:EvalFrequency
    $WindowSize       = $using:WindowSize
    $Severity         = $using:Severity
    $AgId             = $using:AgId
    $alertExistenceMap = $using:alertExistenceMapLocal
    $isWhatIf         = $using:isWhatIf
    
    # Build KQL query
    $kql = @"
WVDErrors
| where TimeGenerated > ago(5m)
| where CodeSymbolic == '$($alert.CodeSymbolic)'
| project UserName, Source, CodeSymbolic, Message, Operation, _ResourceId
"@
    
    # Check if alert exists using the pre-verified existence map
    $alertExists = $alertExistenceMap[$alert.Name] -eq $true
    
    $result = [PSCustomObject]@{
      AlertName = $alert.Name
      Description = $alert.Description
      Status = "Processing"
      Action = ""
      ErrorOutput = ""
      AlreadyExisted = $alertExists
    }
    
    if ($isWhatIf) {
      # WhatIf mode - don't execute Azure CLI commands
      $result.Status = "WhatIf"
      $result.Action = if ($alertExists) { "WouldSkip" } else { "WouldCreate" }
    } elseif ($alertExists) {
      # Alert already exists - skip it
      $result.Status = "Skipped"
      $result.Action = "Skipped"
    } else {
      # Execute actual Azure CLI commands
      try {
        # Convert multi-line query to single line for Azure CLI
        $queryEscaped = $kql -replace "`r", "" -replace "`n", " "
        
        $azCmdArgs = @(
          'monitor', 'scheduled-query', 'create',
          '-g', $ResourceGroup, '-n', $alert.Name, '-l', $Location,
          '--subscription', $accountInfo.id, '--scopes', $LawId,
          '--evaluation-frequency', $EvalFrequency, '--window-size', $WindowSize,
          '--severity', "$Severity", '--description', $alert.Description,
          '--condition', "count 'Query1' > 0", '--condition-query', "Query1=$queryEscaped",
          '--action-groups', $AgId
        )
        $output = az @azCmdArgs 2>&1
        
        if ($LASTEXITCODE -eq 0) {
          $result.Status = "Success"
          $result.Action = "Created"
        } else {
          $errStr = ($output | Out-String).ToLower()
          if ($errStr -match "conflict|already exists") {
            $result.Status = "Skipped"
            $result.Action = "Skipped"
            $result.AlreadyExisted = $true
          } else {
            $result.Status = "Failed"
            $result.Action = "Failed"
            $result.ErrorOutput = $output | Out-String
          }
        }
      } catch {
        $result.Status = "Error"
        $result.Action = "Error"
        $result.ErrorOutput = $_.Exception.Message
      }
    }
    
    # Return result
    $result
  }
  
  # Process results
  $alertCount = 0
  foreach ($result in $results) {
    $alertCount++
    $percentComplete = [Math]::Round(($alertCount / $alertDefinitions.Count) * 100)
    Write-Progress -Activity "Collecting Results" -Status "Processed $alertCount of $($alertDefinitions.Count) alerts" -PercentComplete $percentComplete
    
    # Add to tracking arrays
    if ($result.AlreadyExisted) {
      $ExistingAlerts += $result.AlertName
    } elseif ($result.Status -eq "Success") {
      $NewlyCreatedAlerts += $result.AlertName
    }
    
    # Log output
    $severityText = switch ($Severity) {
      0 { "Critical" } 1 { "Error" } 2 { "Warning" } 3 { "Informational" } 4 { "Verbose" }
    }
    
    if ($result.Status -eq "WhatIf") {
      Write-Log "[WhatIf] Would $(if ($result.AlreadyExisted) { 'skip (already exists)' } else { 'create' }) alert: $($result.AlertName)" "Yellow"
    } elseif ($result.Status -eq "Skipped") {
      Write-Log "Skipping existing alert: $($result.AlertName) (already exists)" "Gray"
    } else {
      Write-Log "Creating new alert: $($result.AlertName) (Severity: $severityText)" "Cyan"
      
      if ($result.Status -eq "Success") {
        Write-Log "  ✓ Success" "Green"
      } else {
        $errDetail = if ($result.ErrorOutput) { ": $($result.ErrorOutput.Trim())" } else { "" }
        Write-Log "  ✗ $($result.Status)$errDetail" "Red"
      }
    }
    
    # Add to CSV results
    $AlertResults += [pscustomobject]@{
      AlertName   = $result.AlertName
      Description = $result.Description
      Severity    = "$Severity ($severityText)"
      Action      = $result.Action
      Status      = $result.Status
    }
  }
  
  Write-Progress -Activity "Collecting Results" -Completed
  
} else {
  # Fallback: Sequential processing for PowerShell 5.1
  Write-Log "Using sequential processing (PowerShell 5.1)" "Yellow"
  
  $alertCount = 0
  foreach ($alert in $alertDefinitions) {
    $alertCount++
    $percentComplete = [Math]::Round(($alertCount / $alertDefinitions.Count) * 100)
    Write-Progress -Activity "Creating/Updating AVD Alerts" -Status "Processing alert $alertCount of $($alertDefinitions.Count): $($alert.Name)" -PercentComplete $percentComplete
    
    # Status report for WhatIf mode if running longer than 30 seconds
    if ($PSBoundParameters.ContainsKey('WhatIf')) {
      $elapsed = (Get-Date) - $alertProcessingStart
      $timeSinceLastReport = (Get-Date) - $lastStatusReport
      
      if ($elapsed.TotalSeconds -ge 30 -and $timeSinceLastReport.TotalSeconds -ge 30) {
        Write-Log "" 
        Write-Log "=== WhatIf Status Report ===" "Yellow"
        Write-Log "Elapsed Time: $([Math]::Round($elapsed.TotalSeconds, 1))s" "Yellow"
        Write-Log "Progress: $alertCount of $($alertDefinitions.Count) alerts processed ($percentComplete%)" "Yellow"
        Write-Log "Current: $($alert.Name)" "Yellow"
        Write-Log "" 
        $lastStatusReport = Get-Date
      }
    }
    
    $kql = @"
WVDErrors
| where TimeGenerated > ago(5m)
| where CodeSymbolic == '$($alert.CodeSymbolic)'
| project UserName, Source, CodeSymbolic, Message, Operation, _ResourceId
"@
    
    New-OrUpdate-ScheduledQueryAlert -AlertName $alert.Name -Description $alert.Description -Kql $kql
  }
  
  Write-Progress -Activity "Creating/Updating AVD Alerts" -Completed
}

# ----------------------------
# Export Results to CSV
# ----------------------------
if ($AlertResults.Count -gt 0) {
  try {
    # Validate CSV path
    $csvDirectory = Split-Path $CsvPath -Parent
    if ($csvDirectory -and -not (Test-Path $csvDirectory)) {
      New-Item -ItemType Directory -Path $csvDirectory -Force | Out-Null
    }
    
    $AlertResults | Export-Csv -NoTypeInformation -Path $CsvPath -Force -ErrorAction Stop
    Write-Log "" 
    Write-Log "Results exported to: $CsvPath" "Green"
  }
  catch {
    Write-Log "Warning: Failed to export results to CSV: $($_.Exception.Message)" "Yellow"
    Write-Log "CSV Path attempted: $CsvPath" "Gray"
  }
}

# ----------------------------
# Summary
# ----------------------------
Write-Log "" 
Write-Log "=== Summary ===" "Cyan"
Write-Log "Action Group: $ActionGroupName" "White"
Write-Log "Email Recipient: $EmailTo" "White"
Write-Log "Total Alerts Processed: $($AlertResults.Count)" "White"
Write-Log "" 

$failedCount = ($AlertResults | Where-Object Status -eq "Failed").Count
$whatIfCount = ($AlertResults | Where-Object Status -eq "WhatIf").Count

if ($whatIfCount -gt 0) {
  Write-Log "WhatIf Mode: $whatIfCount alert(s) would be created; $($ExistingAlerts.Count) would be skipped (already exist)" "Yellow"
} else {
  Write-Log "=== Alert Statistics ===" "Cyan"
  Write-Log "Alerts Newly Created: $($NewlyCreatedAlerts.Count)" "Green"
  Write-Log "Alerts Skipped (already existed): $($ExistingAlerts.Count)" "Yellow"
  if ($failedCount -gt 0) {
    Write-Log "Failed: $failedCount" "Red"
  }
  
  if ($NewlyCreatedAlerts.Count -gt 0) {
    Write-Log "" 
    Write-Log "=== Newly Created Alerts ===" "Green"
    Write-Log "The following $($NewlyCreatedAlerts.Count) alert(s) were created:" "Green"
    foreach ($alert in $NewlyCreatedAlerts) {
      Write-Log "  - $alert" "Gray"
    }
  }
  
  if ($ExistingAlerts.Count -gt 0) {
    Write-Log "" 
    Write-Log "=== Existing Alerts Detected ===" "Yellow"
    Write-Log "The following $($ExistingAlerts.Count) alert(s) were skipped (already exist):" "Yellow"
    foreach ($alert in $ExistingAlerts) {
      Write-Log "  - $alert" "Gray"
    }
    Write-Log "" 
    Write-Log "NOTE: If you want to recreate these alerts from scratch, you can:" "Yellow"
    Write-Log "1. Delete existing alerts using Azure Portal or Azure CLI" "Yellow"
    Write-Log "2. Run this PowerShell command to delete all AVD alerts:" "Yellow"
    Write-Log "" 
    $deleteCmd = @"
`$alerts = az monitor scheduled-query list -g $ResourceGroup --query "[?starts_with(name,'AVD-')].name" -o tsv
`$alerts | ForEach-Object { 
  if (`$_) { az monitor scheduled-query delete -g $ResourceGroup -n `$_ -y } 
}
"@
    Write-Log $deleteCmd "Gray"
    Write-Log "" 
    Write-Log "3. Re-run this script to create fresh alerts" "Yellow"
  }
}

$duration = (Get-Date) - $ScriptStartTime
Write-Log "" 
Write-Log "Execution time: $($duration.TotalSeconds.ToString('F1')) seconds" "Gray"
Write-Log "Done." "Green"
