#requires -Version 5.1
<#
==============================================================================
SCRIPT VERSION: 2.0
LAST UPDATED: February 2026
==============================================================================
QUICK START:
1. Update the default parameter values below (lines 67-93) with your values:
   - EmailTo: Your email address for alert notifications
   - ResourceGroup: Your Azure resource group name
   - LawName: Your Log Analytics workspace name  
   - Location: Your Azure region (e.g., eastus, westus2)

2. Run the script with defaults:
   .\Azure-AVD-Alerts.ps1

3. Or override any parameter:
   .\Azure-AVD-Alerts.ps1 -EmailTo "admin@contoso.com" `
     -ResourceGroup "rg-avd" -LawName "law-avd" -Location "eastus2"
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

.PARAMETER ActionGroupName
  Name of the Azure Monitor action group.

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
  [ValidatePattern('^[\w-\.]+@([\w-]+\.)+[\w-]{2,4}$')]
  [string]$EmailTo = "your-email@domain.com",

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
  [string]$CsvPath = ".\avd-alerts-report.csv"
)

$ErrorActionPreference = "Stop"

# Track execution time
$ScriptStartTime = Get-Date

# ----------------------------
# Pre-flight Checks
# ----------------------------

# Check 1: Verify Azure CLI is installed
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
  throw "Azure CLI not found. Please install from https://learn.microsoft.com/cli/azure/install-azure-cli"
}

# Check 2: Validate placeholder parameters have been updated
$placeholderParams = @()
if ($EmailTo -eq "your-email@domain.com") { $placeholderParams += "EmailTo" }
if ($ResourceGroup -eq "your-resource-group") { $placeholderParams += "ResourceGroup" }
if ($LawName -eq "your-log-analytics-workspace") { $placeholderParams += "LawName" }
if ($Location -eq "your-azure-region") { $placeholderParams += "Location" }

if ($placeholderParams.Count -gt 0) {
  $paramList = $placeholderParams -join ", "
  throw "Please update the following parameter(s) with actual values: $paramList`nYou can either edit the default values in the script or pass them as arguments."
}

# Check 3: Verify Azure login and subscription
Write-Host "[Pre-flight] Checking Azure authentication..." -ForegroundColor Cyan
$accountInfo = az account show 2>$null | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or $null -eq $accountInfo) {
  throw "Not logged in to Azure. Please run 'az login' first."
}
Write-Host "[Pre-flight] Logged in as: $($accountInfo.user.name)" -ForegroundColor Gray
Write-Host "[Pre-flight] Subscription: $($accountInfo.name) ($($accountInfo.id))" -ForegroundColor Gray

# Alert cadence
$EvalFrequency = "PT5M"   # every 5 minutes
$WindowSize    = "PT5M"   # evaluation window (5 minutes)

# Track created/updated alerts for CSV export
$AlertResults = @()
$ExistingAlerts = @()
$NewlyCreatedAlerts = @()
$UpdatedAlerts = @()

# Performance optimization: Get all existing alerts once
Write-Host "[Pre-flight] Checking for existing alerts..." -ForegroundColor Cyan
$existingAlertNamesList = @()
try {
  $existingAlertsOutput = az monitor scheduled-query list -g $ResourceGroup --query "[?starts_with(name,'AVD-')].name" -o tsv 2>$null
  if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($existingAlertsOutput)) {
    $existingAlertNamesList = $existingAlertsOutput -split "`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    Write-Host "[Pre-flight] Found $($existingAlertNamesList.Count) existing AVD alert(s)" -ForegroundColor Gray
  } else {
    Write-Host "[Pre-flight] No existing AVD alerts found or query failed - will check individually" -ForegroundColor Gray
    $existingAlertNamesList = $null  # Signal to use individual checks instead
  }
} catch {
  Write-Host "[Pre-flight] Could not query existing alerts - will check individually" -ForegroundColor Yellow
  $existingAlertNamesList = $null  # Signal to use individual checks instead
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
  
  # Use cached list from pre-flight check if available, otherwise check individually
  if ($null -eq $script:existingAlertNamesList) {
    # Fallback: individual query if cache failed
    az monitor scheduled-query show -g $ResourceGroup -n $AlertName -o json 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
  }
  
  return ($script:existingAlertNamesList -contains $AlertName)
}

# ----------------------------
# Resolve Log Analytics Workspace Resource ID
# ----------------------------
Write-Log "Resolving Log Analytics Workspace: $LawName" "Cyan"

$LawId = az monitor log-analytics workspace show `
  -g $ResourceGroup `
  -n $LawName `
  --query id -o tsv 2>$null

if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($LawId)) {
  throw "Could not resolve Log Analytics workspace id for '$LawName' in RG '$ResourceGroup'."
}

Write-Log "Log Analytics Workspace ID: $LawId" "Gray"

# ----------------------------
# Create / ensure Action Group (email)
# ----------------------------
Write-Log "Ensuring Action Group: $ActionGroupName (email -> $EmailTo)" "Cyan"

if ($PSCmdlet.ShouldProcess($ActionGroupName, "Create or update action group")) {
  # Check if action group exists
  az monitor action-group show -g $ResourceGroup -n $ActionGroupName -o json 2>$null | Out-Null
  $agExists = ($LASTEXITCODE -eq 0)

  if (-not $agExists) {
    Write-Log "Creating action group: $ActionGroupName" "Yellow"
    $agOutput = az monitor action-group create `
      -g $ResourceGroup `
      -n $ActionGroupName `
      --short-name "AVDAlerts" 2>&1
    
    if ($LASTEXITCODE -ne 0) {
      throw "Failed to create action group: $agOutput"
    }
  } else {
    Write-Log "Action group already exists" "Gray"
  }

  # Ensure email receiver exists (use hash-based unique name to avoid collisions)
  Write-Log "Configuring email receiver: $EmailTo" "Gray"
  # Create unique receiver name using first 8 chars + hash to prevent collisions
  $emailHash = [BitConverter]::ToString([System.Security.Cryptography.SHA256]::Create().ComputeHash([System.Text.Encoding]::UTF8.GetBytes($EmailTo))).Replace('-','').Substring(0,8)
  $emailPrefix = ($EmailTo -replace '[^a-zA-Z0-9]', '').Substring(0, [Math]::Min(12, ($EmailTo -replace '[^a-zA-Z0-9]', '').Length))
  $receiverName = "AVD$emailPrefix$emailHash"
  
  # Check if receiver already exists with different email
  $agDetails = az monitor action-group show -g $ResourceGroup -n $ActionGroupName -o json 2>$null | ConvertFrom-Json
  $existingReceiver = $agDetails.emailReceivers | Where-Object { $_.name -eq $receiverName }
  
  if ($existingReceiver -and $existingReceiver.emailAddress -ne $EmailTo) {
    Write-Log "Updating email receiver to new address: $EmailTo" "Yellow"
    # Remove old receiver and add new one
    $removeOutput = az monitor action-group update -g $ResourceGroup -n $ActionGroupName --remove emailReceivers name=$receiverName 2>&1
    if ($LASTEXITCODE -ne 0) {
      Write-Log "Warning: Failed to remove old email receiver: $removeOutput" "Yellow"
      Write-Log "Attempting to add new receiver anyway..." "Yellow"
    }
  }
  
  # Add or update email receiver
  $emailOutput = az monitor action-group update `
    -g $ResourceGroup `
    -n $ActionGroupName `
    --add-action email $receiverName $EmailTo 2>&1
  
  if ($LASTEXITCODE -ne 0) {
    # Parse error to determine if it's expected (duplicate) or actual failure
    $errorLower = $emailOutput.ToString().ToLower()
    if ($errorLower -match "already exists" -or $errorLower -match "duplicate" -or $errorLower -match "receiver.*exists") {
      Write-Log "Email receiver already configured" "Gray"
    } else {
      Write-Log "Warning: Failed to add email receiver: $emailOutput" "Yellow"
      Write-Log "This may not affect alert functionality if the receiver already exists" "Yellow"
    }
  }
  
  $AgId = az monitor action-group show `
    -g $ResourceGroup `
    -n $ActionGroupName `
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

  if ($PSCmdlet.ShouldProcess($AlertName, "Create or update scheduled query alert")) {
    if ($alertExists) {
      Write-Log "Updating existing alert: $AlertName (Severity: $severityText)" "Yellow"
    } else {
      Write-Log "Creating new alert: $AlertName (Severity: $severityText)" "Cyan"
    }

    try {
      # Convert multi-line query to single line and escape quotes for Azure CLI
      $queryEscaped = $Kql -replace "`r", "" -replace "`n", " " -replace '"', '\"'
      
      $output = az monitor scheduled-query create `
        -g $ResourceGroup `
        -n $AlertName `
        -l $Location `
        --scopes $LawId `
        --evaluation-frequency $EvalFrequency `
        --window-size $WindowSize `
        --severity $Severity `
        --description $Description `
        --condition "count 'Query1' > 0" `
        --condition-query "Query1=$queryEscaped" `
        --action-groups $AgId 2>&1
      
      if ($LASTEXITCODE -eq 0) {
        Write-Log "  ✓ Success" "Green"
        $status = "Success"
        $action = if ($alertExists) { "Updated" } else { "Created" }
        
        if ($alertExists) {
          $script:UpdatedAlerts += $AlertName
        } else {
          $script:NewlyCreatedAlerts += $AlertName
        }
      } else {
        Write-Log "  ✗ Failed: $output" "Red"
        $status = "Failed"
        $action = "Failed"
      }
    }
    catch {
      Write-Log "  ✗ Error: $($_.Exception.Message)" "Red"
      $status = "Error"
      $action = "Error"
    }
  } else {
    Write-Log "[WhatIf] Would $(if ($alertExists) { 'update' } else { 'create' }) alert: $AlertName" "Yellow"
    $status = "WhatIf"
    $action = if ($alertExists) { "WouldUpdate" } else { "WouldCreate" }
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
Write-Log "Creating/Updating AVD Alerts..." "Cyan"
Write-Log "" 

# Alert: User password must be changed before login
New-OrUpdate-ScheduledQueryAlert -AlertName "AVD-PasswordMustChange" -Description "Detects users who must change their password before logging into AVD. Triggers when a user's password policy requires a mandatory change." -Kql @"
union isfuzzy=true WVDHostRegistration, WVDErrors
| where TimeGenerated > ago(5m)
| where CodeSymbolic == "PasswordMustChange"
| project UserName, Source, CodeSymbolic, Message, Operation, _ResourceId
"@

# Alert: User account is locked out
New-OrUpdate-ScheduledQueryAlert -AlertName "AVD-AccountLockedOut" -Description "Detects user accounts that are locked out due to failed login attempts. Indicates potential security issues or users needing assistance." -Kql @"
union isfuzzy=true WVDHostRegistration, WVDErrors
| where TimeGenerated > ago(5m)
| where CodeSymbolic == "AccountLockedOut"
| project UserName, Source, Code, CodeSymbolic, Message, Operation, _ResourceId
"@

# Alert: Personal desktop failed to start
New-OrUpdate-ScheduledQueryAlert -AlertName "AVD-ConnectionFailedPersonalDesktopFailedToBeStarted" -Description "Detects when a personal desktop VM fails to start for a connection attempt. May indicate VM configuration issues or Azure capacity problems." -Kql @"
union isfuzzy=true WVDHostRegistration, WVDErrors
| where TimeGenerated > ago(5m)
| where CodeSymbolic == "ConnectionFailedPersonalDesktopFailedToBeStarted"
| project UserName, Source, CodeSymbolic, Message, Operation, _ResourceId
"@

# Alert: User password has expired
New-OrUpdate-ScheduledQueryAlert -AlertName "AVD-PasswordExpired" -Description "Detects users attempting to connect with expired passwords. Users must reset their password before accessing AVD." -Kql @"
union isfuzzy=true WVDHostRegistration, WVDErrors
| where TimeGenerated > ago(5m)
| where CodeSymbolic == "PasswordExpired"
| project UserName, Source, CodeSymbolic, Message, Operation, _ResourceId
"@

# Alert: User account is disabled in Active Directory
New-OrUpdate-ScheduledQueryAlert -AlertName "AVD-AccountDisabled" -Description "Detects connection attempts from disabled user accounts. Indicates terminated users trying to access AVD or account provisioning issues." -Kql @"
union isfuzzy=true WVDHostRegistration, WVDErrors
| where TimeGenerated > ago(5m)
| where CodeSymbolic == "AccountDisabled"
| project UserName, Source, CodeSymbolic, Message, Operation, _ResourceId
"@

# Alert: No healthy session hosts available
New-OrUpdate-ScheduledQueryAlert -AlertName "AVD-ConnectionFailedNoHealthyRdshAvailable" -Description "Detects when no healthy session hosts are available in a host pool. Critical issue preventing all user connections - requires immediate attention." -Kql @"
union isfuzzy=true WVDHostRegistration, WVDErrors
| where TimeGenerated > ago(5m)
| where CodeSymbolic == "ConnectionFailedNoHealthyRdshAvailable"
| project UserName, Source, CodeSymbolic, Message, Operation, _ResourceId
"@

# Alert: File sharing violation error
New-OrUpdate-ScheduledQueryAlert -AlertName "AVD-ERROR_SHARING_VIOLATION" -Description "Detects file sharing violations during user profile loading or application access. Often related to FSLogix profile conflicts or locked files." -Kql @"
union isfuzzy=true WVDHostRegistration, WVDErrors
| where TimeGenerated > ago(5m)
| where CodeSymbolic == "ERROR_SHARING_VIOLATION"
| project UserName, Source, CodeSymbolic, Message, Operation, _ResourceId
"@

# Alert: User logon failed
New-OrUpdate-ScheduledQueryAlert -AlertName "AVD-LogonFailed" -Description "Detects failed user logon attempts to AVD session hosts. May indicate authentication issues, incorrect credentials, or account problems." -Kql @"
union isfuzzy=true WVDHostRegistration, WVDErrors
| where TimeGenerated > ago(5m)
| where CodeSymbolic == "LogonFailed"
| project UserName, Source, CodeSymbolic, Message, Operation, _ResourceId
"@

# Alert: User profile unload waiting for user action
New-OrUpdate-ScheduledQueryAlert -AlertName "AVD-UnloadWaitingForUserAction" -Description "Detects when FSLogix profile unload is delayed waiting for user action. User may have unsaved work or active processes blocking logoff." -Kql @"
union isfuzzy=true WVDHostRegistration, WVDErrors
| where TimeGenerated > ago(5m)
| where CodeSymbolic == "UnloadWaitingForUserAction"
| project UserName, Source, CodeSymbolic, Message, Operation, _ResourceId
"@

# Alert: User not authorized to connect
New-OrUpdate-ScheduledQueryAlert -AlertName "AVD-ConnectionFailedUserNotAuthorized" -Description "Detects unauthorized connection attempts to AVD. User lacks permissions on the application group or workspace." -Kql @"
union isfuzzy=true WVDHostRegistration, WVDErrors
| where TimeGenerated > ago(5m)
| where CodeSymbolic == "ConnectionFailedUserNotAuthorized"
| project UserName, Source, CodeSymbolic, Message, Operation, _ResourceId
"@

# Alert: No personal desktop assigned to user
New-OrUpdate-ScheduledQueryAlert -AlertName "AVD-ConnectionFailedNoPreAssignedPersonalDesktopForUser" -Description "Detects connection attempts when user has no personal desktop assigned. Occurs in personal host pools without desktop assignment." -Kql @"
union isfuzzy=true WVDHostRegistration, WVDErrors
| where TimeGenerated > ago(5m)
| where CodeSymbolic == "ConnectionFailedNoPreAssignedPersonalDesktopForUser"
| project UserName, Source, CodeSymbolic, Message, Operation, _ResourceId
"@

# Alert: Client connection timing issue
New-OrUpdate-ScheduledQueryAlert -AlertName "AVD-ConnectionFailedClientConnectedTooLateReverseConnectionAlreadyClosed" -Description "Detects when client connects too late and reverse connection is already closed. May indicate network latency or timeout issues." -Kql @"
union isfuzzy=true WVDHostRegistration, WVDErrors
| where TimeGenerated > ago(5m)
| where CodeSymbolic == "ConnectionFailedClientConnectedTooLateReverseConnectionAlreadyClosed"
| project UserName, Source, CodeSymbolic, Message, Operation, _ResourceId
"@

# Alert: Input device initialization error
New-OrUpdate-ScheduledQueryAlert -AlertName "AVD-GetInputDeviceHandlesError" -Description "Detects errors initializing input device handles. May indicate driver issues or peripheral compatibility problems." -Kql @"
union isfuzzy=true WVDHostRegistration, WVDErrors
| where TimeGenerated > ago(5m)
| where CodeSymbolic == "GetInputDeviceHandlesError"
| project UserName, Source, CodeSymbolic, Message, Operation, _ResourceId
"@

# Alert: Graphics capabilities not received
New-OrUpdate-ScheduledQueryAlert -AlertName "AVD-GraphicsCapsNotReceived" -Description "Detects when graphics capabilities are not received during session initialization. May indicate GPU or graphics driver issues." -Kql @"
union isfuzzy=true WVDHostRegistration, WVDErrors
| where TimeGenerated > ago(5m)
| where CodeSymbolic == "GraphicsCapsNotReceived"
| project UserName, Source, CodeSymbolic, Message, Operation, _ResourceId
"@

# Alert: Invalid authentication token
New-OrUpdate-ScheduledQueryAlert -AlertName "AVD-InvalidAuthToken" -Description "Detects invalid or expired authentication tokens. Indicates authentication token validation failures or token expiration issues." -Kql @"
union isfuzzy=true WVDHostRegistration, WVDErrors
| where TimeGenerated > ago(5m)
| where CodeSymbolic == "InvalidAuthToken"
| project UserName, Source, CodeSymbolic, Message, Operation, _ResourceId
"@

# Alert: Invalid user credentials
New-OrUpdate-ScheduledQueryAlert -AlertName "AVD-InvalidCredentials" -Description "Detects login attempts with invalid credentials (wrong username or password). Indicates user credential issues or potential security concerns." -Kql @"
union isfuzzy=true WVDHostRegistration, WVDErrors
| where TimeGenerated > ago(5m)
| where CodeSymbolic == "InvalidCredentials"
| project UserName, Source, CodeSymbolic, Message, Operation, _ResourceId
"@

# Alert: Logon type not granted
New-OrUpdate-ScheduledQueryAlert -AlertName "AVD-LogonTypeNotGranted" -Description "Detects when requested logon type is not granted by policy. User may lack required logon rights or policy restrictions are in place." -Kql @"
union isfuzzy=true WVDHostRegistration, WVDErrors
| where TimeGenerated > ago(5m)
| where CodeSymbolic == "LogonTypeNotGranted"
| project UserName, Source, CodeSymbolic, Message, Operation, _ResourceId
"@

# Alert: User not authorized for logon
New-OrUpdate-ScheduledQueryAlert -AlertName "AVD-NotAuthorizedForLogon" -Description "Detects users not authorized for logon. May indicate missing logon permissions or policy restrictions preventing access." -Kql @"
union isfuzzy=true WVDHostRegistration, WVDErrors
| where TimeGenerated > ago(5m)
| where CodeSymbolic == "NotAuthorizedForLogon"
| project UserName, Source, CodeSymbolic, Message, Operation, _ResourceId
"@

# Alert: Session host out of memory
New-OrUpdate-ScheduledQueryAlert -AlertName "AVD-OutOfMemory" -Description "Detects session hosts running out of memory. Critical issue requiring immediate attention - may cause session crashes or prevent new connections." -Kql @"
union isfuzzy=true WVDHostRegistration, WVDErrors
| where TimeGenerated > ago(5m)
| where CodeSymbolic == "OutOfMemory"
| project UserName, Source, CodeSymbolic, Message, Operation, _ResourceId
"@

# Alert: Session host resources unavailable
New-OrUpdate-ScheduledQueryAlert -AlertName "AVD-SessionHostResourceNotAvailable" -Description "Detects when session host resources are unavailable. May indicate capacity issues, host health problems, or resource exhaustion." -Kql @"
union isfuzzy=true WVDHostRegistration, WVDErrors
| where TimeGenerated > ago(5m)
| where CodeSymbolic == "SessionHostResourceNotAvailable"
| project UserName, Source, CodeSymbolic, Message, Operation, _ResourceId
"@


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

$successCount = ($AlertResults | Where-Object Status -eq "Success").Count
$failedCount = ($AlertResults | Where-Object Status -eq "Failed").Count
$whatIfCount = ($AlertResults | Where-Object Status -eq "WhatIf").Count

if ($whatIfCount -gt 0) {
  Write-Log "WhatIf Mode: $whatIfCount alerts would be created/updated" "Yellow"
} else {
  Write-Log "=== Alert Statistics ===" "Cyan"
  Write-Log "Alerts Already Existed: $($ExistingAlerts.Count)" "Yellow"
  Write-Log "Alerts Newly Created: $($NewlyCreatedAlerts.Count)" "Green"
  Write-Log "Alerts Updated: $($UpdatedAlerts.Count)" "Cyan"
  if ($failedCount -gt 0) {
    Write-Log "Failed: $failedCount" "Red"
  }
  
  if ($ExistingAlerts.Count -gt 0) {
    Write-Log "" 
    Write-Log "=== Existing Alerts Detected ===" "Yellow"
    Write-Log "The following $($ExistingAlerts.Count) alert(s) were updated (already existed):" "Yellow"
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
