#requires -Version 5.1
<#
==============================================================================
SCRIPT VERSION: 2.1
LAST UPDATED: February 2026
REPOSITORY: https://github.com/AzaryaShaulov/AVD
DISCLAIMER: This script is provided AS IS, without warranties or support guarantees.
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
  Deploys and maintains Azure Monitor scheduled query alerts for Azure Virtual Desktop (AVD).

.DESCRIPTION
  Creates and updates Log Analytics-based AVD category alerts, configures the email action
  group, and optionally configures a detailed webhook action group.

  The script requires Azure CLI and sufficient Azure RBAC permissions.
  
  REQUIRED: Update default parameter values (EmailTo, ResourceGroup, LawName, Location)
  in the script, or pass them as arguments when running the script.

.PARAMETER EmailTo
  Email address for alert notifications. Default: "your-email@domain.com"

.PARAMETER SubscriptionId
  Azure subscription ID. If not provided, uses the current subscription context.

.PARAMETER ActionGroupName
  Name of the Azure Monitor action group. If it already exists, the specified email will be
  added to it. If it does not exist, a new action group will be created. Default: "AVD-Alerts"

.PARAMETER DetailedResultsWebhookUrl
  Optional HTTPS webhook URL for detailed alert payload delivery (for example, a Logic App
  or Automation endpoint that can email query results).

.PARAMETER DetailedActionGroupName
  Name of the optional webhook action group used for detailed notifications.
  Default: "AVD-Alerts-Detailed"

.PARAMETER DetailedWebhookReceiverName
  Receiver name for the webhook action in the detailed action group.
  Default: "AVDAlertsDetailedWebhook"

.PARAMETER UseCommonAlertSchemaForWebhook
  When true, webhook receiver uses Azure Monitor common alert schema.

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

.PARAMETER CreateOnly
  Controls behavior for existing alerts. Default: $true (existing alerts are skipped and unchanged).

.PARAMETER WhatIf
  Preview changes without creating or modifying alerts.

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

.EXAMPLE
  # Send standard email alerts and detailed payloads to webhook endpoint
  .\Azure-AVD-Alerts.ps1 -EmailTo "admin@contoso.com" -DetailedResultsWebhookUrl "https://contoso.logic.azure.com/workflows/..."
#>

[CmdletBinding(SupportsShouldProcess)]
param(
  [Parameter(Mandatory = $false)]
  [ValidateNotNullOrEmpty()]
  [ValidatePattern('^[^@\s]+@[^@\s]+\.[^@\s]+$')]
  [string]$EmailTo = "your-email@domain.com",

  [Parameter(Mandatory = $false)]
  [ValidateNotNullOrEmpty()]
  [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
  [string]$SubscriptionId,

  [Parameter(Mandatory = $false)]
  [ValidateNotNullOrEmpty()]
  [string]$ActionGroupName = "AVD-Alerts",

  [Parameter(Mandatory = $false)]
  [ValidatePattern('^$|^https?://.+')]
  [string]$DetailedResultsWebhookUrl,

  [Parameter(Mandatory = $false)]
  [ValidateNotNullOrEmpty()]
  [string]$DetailedActionGroupName = "AVD-Alerts-Detailed",

  [Parameter(Mandatory = $false)]
  [ValidateNotNullOrEmpty()]
  [string]$DetailedWebhookReceiverName = "AVDAlertsDetailedWebhook",

  [Parameter(Mandatory = $false)]
  [bool]$UseCommonAlertSchemaForWebhook = $true,

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
  [bool]$CreateOnly = $true,

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

# Check 1b: Verify required Azure CLI extension is available
Write-Host "[Pre-flight] Checking required Azure CLI extension: scheduled-query..." -ForegroundColor Cyan
az extension show --name scheduled-query -o none 2>$null
if ($LASTEXITCODE -ne 0) {
  Write-Host "[Pre-flight] 'scheduled-query' extension not found. Installing..." -ForegroundColor Yellow
  az extension add --name scheduled-query --yes -o none 2>$null
  if ($LASTEXITCODE -ne 0) {
    throw "Required Azure CLI extension 'scheduled-query' is not available and could not be installed."
  }
  Write-Host "[Pre-flight] 'scheduled-query' extension installed." -ForegroundColor Green
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
$EvalFrequency = "PT10M"  # every 10 minutes
$WindowSize    = "PT15M"  # evaluation window (15 minutes)

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
# Optional detailed webhook Action Group
# ----------------------------
$DetailedAgId = $null
if (-not [string]::IsNullOrWhiteSpace($DetailedResultsWebhookUrl)) {
  Write-Log "Detailed Webhook URL: $DetailedResultsWebhookUrl" "Cyan"
  Write-Log "Detailed Action Group: $DetailedActionGroupName" "Cyan"

  if ($PSCmdlet.ShouldProcess($DetailedActionGroupName, "Create or update detailed webhook action group")) {
    $detailedAgJson = az monitor action-group show -g $ResourceGroup -n $DetailedActionGroupName --subscription $accountInfo.id -o json 2>$null
    $detailedAgExists = ($LASTEXITCODE -eq 0)

    if (-not $detailedAgExists) {
      Write-Log "Detailed action group '$DetailedActionGroupName' not found - creating..." "Yellow"
      $createArgs = @(
        'monitor', 'action-group', 'create',
        '-g', $ResourceGroup, '-n', $DetailedActionGroupName,
        '--subscription', $accountInfo.id,
        '--short-name', 'AVDDetl',
        '--action', 'webhook', $DetailedWebhookReceiverName, ('"' + $DetailedResultsWebhookUrl + '"')
      )
      if ($UseCommonAlertSchemaForWebhook) {
        $createArgs += 'usecommonalertschema'
      }
      $detailedAgCreateOutput = az @createArgs 2>&1
      if ($LASTEXITCODE -ne 0) {
        throw "Failed to create detailed webhook action group: $detailedAgCreateOutput"
      }
      Write-Log "Detailed action group '$DetailedActionGroupName' created." "Green"
      $detailedAgJson = az monitor action-group show -g $ResourceGroup -n $DetailedActionGroupName --subscription $accountInfo.id -o json 2>$null
    } else {
      Write-Log "Detailed action group '$DetailedActionGroupName' already exists - validating webhook receiver..." "Gray"
      $detailedAg = $detailedAgJson | ConvertFrom-Json
      $webhookReceivers = @($detailedAg.webhookReceivers)
      $receiverByName = $webhookReceivers | Where-Object { $_.name -eq $DetailedWebhookReceiverName } | Select-Object -First 1
      $receiverWithUrl = $webhookReceivers | Where-Object { $_.serviceUri -eq $DetailedResultsWebhookUrl } | Select-Object -First 1

      # Self-heal: remove legacy receiver name to prevent duplicate webhook notifications.
      $legacyDetailedWebhookReceiverName = 'AVDAlertDetails'
      if ($DetailedWebhookReceiverName -ne $legacyDetailedWebhookReceiverName) {
        $legacyReceiver = $webhookReceivers | Where-Object { $_.name -eq $legacyDetailedWebhookReceiverName } | Select-Object -First 1
        if ($null -ne $legacyReceiver) {
          Write-Log "Legacy detailed webhook receiver '$legacyDetailedWebhookReceiverName' found - removing to avoid duplicates." "Yellow"
          az monitor action-group update -g $ResourceGroup -n $DetailedActionGroupName --subscription $accountInfo.id --remove-action $legacyDetailedWebhookReceiverName 2>&1 | Out-Null
        }
      }

      if ($null -eq $receiverWithUrl) {
        if ($null -ne $receiverByName) {
          Write-Log "Webhook receiver name exists with different URL - replacing receiver '$DetailedWebhookReceiverName'." "Yellow"
          az monitor action-group update -g $ResourceGroup -n $DetailedActionGroupName --subscription $accountInfo.id --remove-action $DetailedWebhookReceiverName 2>&1 | Out-Null
        }

        $updateArgs = @(
          'monitor', 'action-group', 'update',
          '-g', $ResourceGroup, '-n', $DetailedActionGroupName,
          '--subscription', $accountInfo.id,
          '--add-action', 'webhook', $DetailedWebhookReceiverName, ('"' + $DetailedResultsWebhookUrl + '"')
        )
        if ($UseCommonAlertSchemaForWebhook) {
          $updateArgs += 'usecommonalertschema'
        }
        $detailedAgUpdateOutput = az @updateArgs 2>&1
        if ($LASTEXITCODE -ne 0) {
          Write-Log "Warning: Failed to add/update webhook receiver: $detailedAgUpdateOutput" "Yellow"
        } else {
          Write-Log "Webhook receiver ensured on '$DetailedActionGroupName'." "Green"
        }
      } else {
        Write-Log "Webhook URL already present on detailed action group - no change needed." "Gray"
      }
    }

    $DetailedAgId = az monitor action-group show `
      -g $ResourceGroup `
      -n $DetailedActionGroupName `
      --subscription $accountInfo.id `
      --query id -o tsv 2>$null

    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($DetailedAgId)) {
      throw "Failed to retrieve detailed action group ID"
    }

    Write-Log "Detailed Action Group ID: $DetailedAgId" "Gray"
  } else {
    Write-Log "[WhatIf] Would create/update detailed action group: $DetailedActionGroupName" "Yellow"
    $subId = $accountInfo.id
    $DetailedAgId = "/subscriptions/$subId/resourceGroups/$ResourceGroup/providers/microsoft.insights/actionGroups/$DetailedActionGroupName"
    Write-Log "Detailed Action Group ID (simulated): $DetailedAgId" "Gray"
  }
}

$ActionGroupIds = @($AgId)
if (-not [string]::IsNullOrWhiteSpace($DetailedAgId)) {
  $ActionGroupIds += $DetailedAgId
}

# ----------------------------
# Helper: create scheduled query alert only (skip if exists)
# ----------------------------
function New-OrSkip-ScheduledQueryAlert {
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

  if ($alertExists -and $CreateOnly) {
    Write-Log "Create-only mode: skipping existing alert: $AlertName" "Gray"
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
        '--condition', "count 'Query1' > 0", '--condition-query', "Query1=$queryEscaped"
      )
      $azCmdArgs += '--action-groups'
      $azCmdArgs += $ActionGroupIds
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
# Alerts
# ----------------------------
Write-Log "" 
Write-Log "Processing AVD Alerts..." "Cyan"
Write-Log "" 

# Start timer for WhatIf status reporting
$alertProcessingStart = Get-Date
$lastStatusReport = $alertProcessingStart

# Alert definitions
$alertDefinitions = @(
  @{ Name = "AVD-Category-AuthenticationIdentity"; Description = "Consolidated authentication and identity failures in AVD."; Kql = "WVDErrors`n| where TimeGenerated > ago(15m)`n| where CodeSymbolic in ('PasswordMustChange', 'PasswordExpired', 'InvalidAuthToken', 'InvalidCredentials', 'AccountLockedOut', 'AccountDisabled', 'LogonFailed', 'AuthenticationLogonFailed', 'NoAuthenticatingAuthority', 'LocalSecurityAuthorityError')`n| project UserName, Source, CodeSymbolic, Message, Operation, _ResourceId" },
  @{ Name = "AVD-Category-AuthorizationPolicy"; Description = "Consolidated authorization and logon rights failures in AVD."; Kql = "WVDErrors`n| where TimeGenerated > ago(15m)`n| where CodeSymbolic in ('ConnectionFailedUserNotAuthorized', 'LogonTypeNotGranted', 'NotAuthorizedForLogon')`n| project UserName, Source, CodeSymbolic, Message, Operation, _ResourceId" },
  @{ Name = "AVD-Category-ConnectionNetworkGateway"; Description = "Consolidated AVD client, DNS, reverse connect, and gateway transport failures."; Kql = "WVDErrors`n| where TimeGenerated > ago(15m)`n| where CodeSymbolic in ('Client', 'DnsLookupFailed', 'GatewayServerNotFound', 'ReverseConnectDnsLookupFailed', 'ConnectionFailedClientConnectedTooLateReverseConnectionAlreadyClosed')`n| project UserName, Source, CodeSymbolic, Message, Operation, _ResourceId" },
  @{ Name = "AVD-Category-SessionHostHealthCapacity"; Description = "Consolidated session host availability and capacity issues."; Kql = "WVDErrors`n| where TimeGenerated > ago(15m)`n| where CodeSymbolic in ('ConnectionFailedNoHealthyRdshAvailable', 'SessionHostResourceNotAvailable', 'OutOfMemory')`n| project UserName, Source, CodeSymbolic, Message, Operation, _ResourceId" },
  @{ Name = "AVD-Category-PersonalDesktopAssignment"; Description = "Consolidated personal desktop assignment and startup failures."; Kql = "WVDErrors`n| where TimeGenerated > ago(15m)`n| where CodeSymbolic in ('ConnectionFailedPersonalDesktopFailedToBeStarted', 'ConnectionFailedNoPreAssignedPersonalDesktopForUser')`n| project UserName, Source, CodeSymbolic, Message, Operation, _ResourceId" },
  @{ Name = "AVD-Category-DeviceGraphicsInput"; Description = "Consolidated input and graphics subsystem failures."; Kql = "WVDErrors`n| where TimeGenerated > ago(15m)`n| where CodeSymbolic in ('GetInputDeviceHandlesError', 'GraphicsCapsNotReceived', 'GraphicsSubsystemFailed', 'DWMProcessAccessFailure')`n| project UserName, Source, CodeSymbolic, Message, Operation, _ResourceId" },
  @{ Name = "AVD-Category-FSLogixProfileStorage"; Description = "Consolidated FSLogix profile and storage attach/detach/access issues."; Kql = "WVDErrors`n| where TimeGenerated > ago(15m)`n| where CodeSymbolic in ('ERROR_SHARING_VIOLATION', 'UnloadWaitingForUserAction', 'ERROR_ACCESS_DENIED', 'ERROR_PATH_NOT_FOUND', 'ERROR_FILE_NOT_FOUND', 'ERROR_BAD_NETPATH', 'ERROR_BAD_NET_NAME', 'ERROR_NETNAME_DELETED', 'ERROR_DISK_FULL', 'ERROR_LOCK_VIOLATION') or Source has 'fslogix' or Message has_any ('frxsvc', 'frxshell', 'temporary profile', 'default profile', 'profile failed', 'vhd attach', 'vhdx attach', 'container attach', 'container detach', 'odfc')`n| project UserName, Source, CodeSymbolic, Message, Operation, _ResourceId" },
  @{ Name = "AVD-Category-UnknownUnclassified"; Description = "Consolidated unknown or unclassified AVD error symbols for triage."; Kql = "WVDErrors`n| where TimeGenerated > ago(15m)`n| where CodeSymbolic == 'Unknown CodeSymbolic - review Message for details.'`n| project UserName, Source, CodeSymbolic, Message, Operation, _ResourceId" }
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

# If detailed webhook mode is enabled, ensure existing alerts also include the configured action groups.
# This prevents a common drift where alerts created earlier have only the email action group attached.
if (-not [string]::IsNullOrWhiteSpace($DetailedAgId) -and $existingCount -gt 0) {
  Write-Log "Ensuring existing alerts include all configured action groups (email + detailed webhook)..." "Cyan"
  foreach ($alertDef in $alertDefinitions) {
    if (-not $script:alertExistenceMap[$alertDef.Name]) {
      continue
    }

    if (-not $PSCmdlet.ShouldProcess($alertDef.Name, "Ensure action groups on existing scheduled query alert")) {
      Write-Log "[WhatIf] Would ensure action groups for existing alert: $($alertDef.Name)" "Yellow"
      continue
    }

    $currentAgOutput = az monitor scheduled-query show `
      -g $ResourceGroup `
      -n $alertDef.Name `
      --subscription $accountInfo.id `
      --query "actions.actionGroups[].actionGroupId" -o tsv 2>$null

    $currentActionGroupIds = @()
    if (-not [string]::IsNullOrWhiteSpace($currentAgOutput)) {
      $currentActionGroupIds = $currentAgOutput -split "[\r\n]+" |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { $_.Trim().ToLowerInvariant() }
    }

    $desiredActionGroupIds = $ActionGroupIds | ForEach-Object { $_.ToLowerInvariant() }
    $missingActionGroupIds = $desiredActionGroupIds | Where-Object { $currentActionGroupIds -notcontains $_ }

    if ($missingActionGroupIds.Count -eq 0) {
      Write-Log "Action groups already correct on existing alert: $($alertDef.Name)" "Gray"
      continue
    }

    $updateArgs = @(
      'monitor', 'scheduled-query', 'update',
      '-g', $ResourceGroup,
      '-n', $alertDef.Name,
      '--subscription', $accountInfo.id,
      '--action-groups'
    )
    $updateArgs += $ActionGroupIds

    $updateOutput = az @updateArgs 2>&1
    if ($LASTEXITCODE -eq 0) {
      Write-Log "Updated action groups on existing alert: $($alertDef.Name)" "Green"
    } else {
      Write-Log "Warning: Failed to update action groups on '$($alertDef.Name)': $updateOutput" "Yellow"
    }
  }
  Write-Log "" 
}

# Phase 2: Parallel processing for faster execution
# Note: ForEach-Object -Parallel requires PowerShell 7+
if ($PSVersionTable.PSVersion.Major -ge 7) {
  Write-Log "Using parallel processing (PowerShell 7+)" "Cyan"
  
  # Parallel processing with throttling
  $throttleLimit = 5  # Process 5 alerts simultaneously
  $isWhatIf = $PSBoundParameters.ContainsKey('WhatIf')
  $createOnlyLocal = $CreateOnly
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
    $CreateOnly       = $using:createOnlyLocal
    $ActionGroupIds   = $using:ActionGroupIds
    $alertExistenceMap = $using:alertExistenceMapLocal
    $isWhatIf         = $using:isWhatIf
    
    # Build KQL query (custom per alert or default CodeSymbolic-based)
    if ($alert.ContainsKey('Kql')) {
      $kql = $alert.Kql
    } else {
      $kql = @"
WVDErrors
| where TimeGenerated > ago(15m)
| where CodeSymbolic == '$($alert.CodeSymbolic)'
| project UserName, Source, CodeSymbolic, Message, Operation, _ResourceId
"@
    }
    
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
      if ($alertExists -and $CreateOnly) {
        $result.Action = "WouldSkip"
      } else {
        $result.Action = "WouldCreate"
      }
    } elseif ($alertExists -and $CreateOnly) {
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
          '--condition', "count 'Query1' > 0", '--condition-query', "Query1=$queryEscaped"
        )
        $azCmdArgs += '--action-groups'
        $azCmdArgs += $ActionGroupIds
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
      Write-Log "Create-only mode: skipping existing alert: $($result.AlertName)" "Gray"
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
    Write-Progress -Activity "Creating AVD Alerts (create-only)" -Status "Processing alert $alertCount of $($alertDefinitions.Count): $($alert.Name)" -PercentComplete $percentComplete
    
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
    
    if ($alert.ContainsKey('Kql')) {
      $kql = $alert.Kql
    } else {
      $kql = @"
WVDErrors
| where TimeGenerated > ago(15m)
| where CodeSymbolic == '$($alert.CodeSymbolic)'
| project UserName, Source, CodeSymbolic, Message, Operation, _ResourceId
"@
    }
    
    New-OrSkip-ScheduledQueryAlert -AlertName $alert.Name -Description $alert.Description -Kql $kql
  }
  
  Write-Progress -Activity "Creating AVD Alerts (create-only)" -Completed
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
if (-not [string]::IsNullOrWhiteSpace($DetailedResultsWebhookUrl)) {
  Write-Log "Detailed Webhook: Enabled ($DetailedActionGroupName)" "White"
} else {
  Write-Log "Detailed Webhook: Disabled" "Gray"
}
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
