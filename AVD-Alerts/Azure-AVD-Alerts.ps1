#requires -Version 5.1
<#
==============================================================================
QUICK START:
1. Update the default parameter values below (lines 50-60) OR pass them as arguments:
   - ResourceGroup: Your Azure resource group name
   - LawName: Your Log Analytics workspace name  
   - Location: Your Azure region (e.g., eastus, westus2)

2. Run the script:
   .\Azure-AVD-Alerts.ps1 -EmailTo "your-email@domain.com"

3. Or specify all parameters:
   .\Azure-AVD-Alerts.ps1 -EmailTo "your-email@domain.com" `
     -ResourceGroup "rg-avd" -LawName "law-avd" -Location "eastus2"
==============================================================================
.SYNOPSIS
  Creates scheduled query alerts for Azure Virtual Desktop monitoring.

.DESCRIPTION
  Configures Log Analytics-based alerts for common AVD error conditions and sends
  notifications via email action group. Requires Azure CLI and appropriate permissions.
  
  REQUIRED: Update -ResourceGroup, -LawName, and -Location parameters with your values,
  or pass them as arguments when running the script.

.PARAMETER EmailTo
  Email address for alert notifications.

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
  .\Azure-AVD-Alerts.ps1 -EmailTo "admin@contoso.com" -ResourceGroup "rg-avd-prod" -LawName "law-avd-prod"

.EXAMPLE
  .\Azure-AVD-Alerts.ps1 -EmailTo "admin@contoso.com" -Severity 0 -WhatIf
#>

[CmdletBinding(SupportsShouldProcess)]
param(
  [Parameter(Mandatory = $true)]
  [ValidateNotNullOrEmpty()]
  [ValidatePattern('^[\w-\.]+@([\w-]+\.)+[\w-]{2,4}$')]
  [string]$EmailTo,

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

# Alert cadence
$EvalFrequency = "PT5M"   # every 5 minutes
$WindowSize    = "PT5M"   # evaluation window (5 minutes)

# Track created/updated alerts for CSV export
$AlertResults = @()

# ----------------------------
# Helper Functions
# ----------------------------
function Write-Log {
  param($Message, $Color = "White")
  $timestamp = Get-Date -Format "HH:mm:ss"
  Write-Host "[$timestamp] $Message" -ForegroundColor $Color
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

  # Ensure email receiver exists
  Write-Log "Configuring email receiver: $EmailTo" "Gray"
  $emailOutput = az monitor action-group update `
    -g $ResourceGroup `
    -n $ActionGroupName `
    --add-action email "EmailSendTO" $EmailTo 2>&1
  
  if ($LASTEXITCODE -ne 0) {
    # Check if error is about duplicate receiver (expected/acceptable)
    if ($emailOutput -match "already exists|duplicate") {
      Write-Log "Email receiver already configured" "Gray"
    } else {
      Write-Log "Warning: Failed to add email receiver: $emailOutput" "Yellow"
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
  $AgId = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/$ResourceGroup/providers/microsoft.insights/actionGroups/$ActionGroupName"
  Write-Log "Action Group ID (simulated): $AgId" "Gray"
}

# ----------------------------
# Helper: create/update scheduled query alert (Log Alert v2)
# ----------------------------
function New-OrUpdate-ScheduledQueryAlert {
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

  if ($PSCmdlet.ShouldProcess($AlertName, "Create or update scheduled query alert")) {
    Write-Log "Creating/Updating alert: $AlertName (Severity: $severityText)" "Cyan"

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
      } else {
        Write-Log "  ✗ Failed: $output" "Red"
        $status = "Failed"
      }
    }
    catch {
      Write-Log "  ✗ Error: $($_.Exception.Message)" "Red"
      $status = "Error"
    }
  } else {
    Write-Log "[WhatIf] Would create/update alert: $AlertName" "Yellow"
    $status = "WhatIf"
  }

  # Track for CSV export
  $script:AlertResults += [pscustomobject]@{
    AlertName   = $AlertName
    Description = $Description
    Severity    = "$Severity ($severityText)"
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

# ----------------------------
# Export Results to CSV
# ----------------------------
if ($AlertResults.Count -gt 0) {
  $AlertResults | Export-Csv -NoTypeInformation -Path $CsvPath -Force
  Write-Log "" 
  Write-Log "Results exported to: $CsvPath" "Green"
}

# ----------------------------
# Summary
# ----------------------------
Write-Log "" 
Write-Log "=== Summary ===" "Cyan"
Write-Log "Action Group: $ActionGroupName" "White"
Write-Log "Email Recipient: $EmailTo" "White"
Write-Log "Total Alerts: $($AlertResults.Count)" "White"

$successCount = ($AlertResults | Where-Object Status -eq "Success").Count
$failedCount = ($AlertResults | Where-Object Status -eq "Failed").Count
$whatIfCount = ($AlertResults | Where-Object Status -eq "WhatIf").Count

if ($whatIfCount -gt 0) {
  Write-Log "WhatIf Mode: $whatIfCount alerts would be created/updated" "Yellow"
} else {
  Write-Log "Success: $successCount" "Green"
  if ($failedCount -gt 0) {
    Write-Log "Failed: $failedCount" "Red"
  }
}

Write-Log "" 
Write-Log "Done." "Green"
