#requires -Version 5.1
<#
==============================================================================
SCRIPT VERSION: 1.2
LAST UPDATED: March 2026
REPOSITORY: https://github.com/AzaryaShaulov/AVD
DISCLAIMER: This script is provided AS IS, without warranties or support guarantees.
==============================================================================
.SYNOPSIS
  Deploys and configures a Logic App webhook processor for detailed AVD alerts.

.DESCRIPTION
  Creates or updates a Logic App (Consumption) that receives Azure Monitor webhook alerts,
  formats alert context, and sends detailed notifications using Office 365 (default) or SendGrid.

  The script outputs a callback URL that can be used with Azure-AVD-Alerts.ps1 via
  -DetailedResultsWebhookUrl.

  Optionally, this script can call Azure-AVD-Alerts.ps1 directly to wire the webhook URL
  into alert deployment immediately.


.PARAMETER ResourceGroup
  Resource group where the Logic App will be deployed.

.PARAMETER Location
  Azure region for the Logic App.

.PARAMETER LogicAppName
  Logic App workflow name. Default follows AVD alerts naming convention.

.PARAMETER SendGridApiKey
  SendGrid API key with Mail Send permission. Required when EmailProvider is SendGrid.

.PARAMETER EmailProvider
  Email delivery provider for Logic App notifications. Use Office365 to avoid SendGrid.

.PARAMETER Office365ConnectionName
  Name of the Microsoft.Web/connections resource for Office 365 connector.

.PARAMETER DetailedActionGroupName
  Name of detailed-results action group in Azure-AVD-Alerts.ps1 when auto-configuring alerts.

.PARAMETER DetailedWebhookReceiverName
  Receiver name used for detailed webhook action in Azure-AVD-Alerts.ps1 when auto-configuring alerts.

.PARAMETER Office365ConnectionResourceId
  Optional full resource ID of an existing Office 365 connector connection.

.PARAMETER SendFromEmail
  Verified sender email in SendGrid.

.PARAMETER SendToEmail
  Recipient email for detailed alert notifications.

.PARAMETER SubscriptionId
  Optional subscription ID to target.

.PARAMETER CreateResourceGroupIfMissing
  Create resource group automatically if it does not exist.

.PARAMETER Tags
  Optional hashtable of resource tags.

.PARAMETER SkipTestInvoke
  Skip sending a test payload to the deployed Logic App callback URL.

.PARAMETER ConfigureAlertsAfterDeploy
  If set, invoke Azure-AVD-Alerts.ps1 with the callback URL.

.PARAMETER AlertsEmailTo
  Email recipient for standard Azure Monitor action-group emails.

.PARAMETER AlertsResourceGroup
  Resource group for AVD alerts deployment.

.PARAMETER AlertsLawName
  Log Analytics workspace name for AVD alerts deployment.

.PARAMETER AlertsLocation
  Location for AVD scheduled-query alerts deployment.

.PARAMETER AlertsActionGroupName
  Action group name for standard alert emails.

.PARAMETER AlertsSeverity
  Severity for AVD scheduled-query alerts (0-4).

.PARAMETER AlertsCreateOnly
  Skip existing alerts when true.

.PARAMETER WhatIf
  Preview changes without creating/updating resources.

.EXAMPLE
  .\Deploy-AVD-AlertWebhook-LogicApp.ps1 `
    -ResourceGroup "rg-avd-prod" `
    -Location "eastus2" `
    -LogicAppName "la-avd-alert-details" `
    -SendGridApiKey "<key>" `
    -SendFromEmail "alerts@contoso.com" `
    -SendToEmail "ops@contoso.com"

.EXAMPLE
  .\Deploy-AVD-AlertWebhook-LogicApp.ps1 `
    -ResourceGroup "rg-avd-prod" `
    -Location "eastus2" `
    -LogicAppName "la-avd-alert-details" `
    -SendGridApiKey "<key>" `
    -SendFromEmail "alerts@contoso.com" `
    -SendToEmail "ops@contoso.com" `
    -ConfigureAlertsAfterDeploy `
    -AlertsEmailTo "noc@contoso.com" `
    -AlertsResourceGroup "rg-avd-prod" `
    -AlertsLawName "law-avd-prod" `
    -AlertsLocation "eastus2"
#>

[CmdletBinding(SupportsShouldProcess)]
param(
  [Parameter(Mandatory = $true)]
  [ValidateNotNullOrEmpty()]
  [string]$ResourceGroup,

  [Parameter(Mandatory = $true)]
  [ValidateNotNullOrEmpty()]
  [string]$Location,

  [Parameter(Mandatory = $false)]
  [ValidateNotNullOrEmpty()]
  [string]$LogicAppName = "la-avd-alerts-detailed",

  [Parameter(Mandatory = $false)]
  [ValidateSet('SendGrid', 'Office365')]
  [string]$EmailProvider = 'Office365',

  [Parameter(Mandatory = $false)]
  [ValidateNotNullOrEmpty()]
  [string]$SendGridApiKey,

  [Parameter(Mandatory = $true)]
  [ValidatePattern('^[^@\s]+@[^@\s]+\.[^@\s]+$')]
  [string]$SendFromEmail,

  [Parameter(Mandatory = $true)]
  [ValidatePattern('^[^@\s]+@[^@\s]+\.[^@\s]+$')]
  [string]$SendToEmail,

  [Parameter(Mandatory = $false)]
  [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
  [string]$SubscriptionId,

  [Parameter(Mandatory = $false)]
  [ValidateNotNullOrEmpty()]
  [string]$Office365ConnectionName = 'avd-alerts-office365',

  [Parameter(Mandatory = $false)]
  [string]$Office365ConnectionResourceId,

  [Parameter(Mandatory = $false)]
  [bool]$CreateResourceGroupIfMissing = $true,

  [Parameter(Mandatory = $false)]
  [hashtable]$Tags = @{},

  [Parameter(Mandatory = $false)]
  [switch]$SkipTestInvoke,

  [Parameter(Mandatory = $false)]
  [switch]$ConfigureAlertsAfterDeploy,

  [Parameter(Mandatory = $false)]
  [ValidatePattern('^[^@\s]+@[^@\s]+\.[^@\s]+$')]
  [string]$AlertsEmailTo,

  [Parameter(Mandatory = $false)]
  [string]$AlertsResourceGroup,

  [Parameter(Mandatory = $false)]
  [string]$AlertsLawName,

  [Parameter(Mandatory = $false)]
  [string]$AlertsLocation,

  [Parameter(Mandatory = $false)]
  [string]$AlertsActionGroupName = "AVD-Alerts",

  [Parameter(Mandatory = $false)]
  [string]$DetailedActionGroupName = "AVD-Alerts-Detailed",

  [Parameter(Mandatory = $false)]
  [string]$DetailedWebhookReceiverName = "AVDAlertsDetailedWebhook",

  [Parameter(Mandatory = $false)]
  [ValidateRange(0, 4)]
  [int]$AlertsSeverity = 1,

  [Parameter(Mandatory = $false)]
  [bool]$AlertsCreateOnly = $true
)

$ErrorActionPreference = "Stop"

function Write-Log {
  param([string]$Message, [string]$Color = "White")
  $ts = Get-Date -Format "HH:mm:ss"
  Write-Host "[$ts] $Message" -ForegroundColor $Color
}

Write-Log "Starting Logic App webhook deployment..." "Cyan"

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
  throw "Azure CLI not found. Install from https://learn.microsoft.com/cli/azure/install-azure-cli"
}

$account = az account show -o json 2>$null | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or $null -eq $account) {
  throw "Not logged in to Azure. Run 'az login' first."
}

if ($SubscriptionId) {
  Write-Log "Setting subscription context: $SubscriptionId" "Cyan"
  az account set --subscription $SubscriptionId -o none 2>$null
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to set subscription '$SubscriptionId'."
  }
  $account = az account show -o json 2>$null | ConvertFrom-Json
}

$subscriptionId = $account.id
Write-Log "Using subscription: $($account.name) ($subscriptionId)" "Gray"

$rgExists = az group exists --name $ResourceGroup -o tsv 2>$null
if ($LASTEXITCODE -ne 0) {
  throw "Failed to verify resource group '$ResourceGroup'."
}

if ($rgExists -ne 'true') {
  if (-not $CreateResourceGroupIfMissing) {
    throw "Resource group '$ResourceGroup' not found and CreateResourceGroupIfMissing is false."
  }
  if ($PSCmdlet.ShouldProcess($ResourceGroup, "Create resource group in $Location")) {
    Write-Log "Creating resource group: $ResourceGroup" "Yellow"
    $rgCreateOutput = az group create --name $ResourceGroup --location $Location --subscription $subscriptionId -o json 2>&1
    if ($LASTEXITCODE -ne 0) {
      throw "Azure CLI command failed: az group create --name $ResourceGroup --location $Location --subscription $subscriptionId`n$rgCreateOutput"
    }
    Write-Log "Resource group created." "Green"
  } else {
    Write-Log "[WhatIf] Would create resource group: $ResourceGroup" "Yellow"
  }
}

$alertEmailHtmlExpr = "@{concat('<h2>Azure Monitor AVD Alert</h2>', '<p><b>Rule:</b> ', coalesce(triggerBody()?['data']?['essentials']?['alertRule'], 'N/A'), '</p>', '<p><b>Severity:</b> ', string(triggerBody()?['data']?['essentials']?['severity']), '</p>', '<p><b>Condition:</b> ', coalesce(triggerBody()?['data']?['essentials']?['monitorCondition'], 'N/A'), '</p>', '<p><b>Fired At:</b> ', coalesce(triggerBody()?['data']?['essentials']?['firedDateTime'], 'N/A'), '</p>', '<hr/>', '<p><b>Query/Search Results (if present):</b></p><pre>', string(triggerBody()?['data']?['alertContext']?['SearchResults']), '</pre>', '<hr/>', '<p><b>Alert Context:</b></p><pre>', string(triggerBody()?['data']?['alertContext']), '</pre>')}"

$workflowParametersDefinition = @{
  sendFromEmail = @{ type = 'String' }
  sendToEmail   = @{ type = 'String' }
}

$workflowRuntimeParameters = @{
  sendFromEmail = @{ value = $SendFromEmail }
  sendToEmail   = @{ value = $SendToEmail }
}

$sendEmailAction = $null
if ($EmailProvider -eq 'SendGrid') {
  if ([string]::IsNullOrWhiteSpace($SendGridApiKey)) {
    throw "SendGridApiKey is required when EmailProvider is SendGrid."
  }

  $workflowParametersDefinition.sendGridApiKey = @{ type = 'SecureString' }
  $workflowRuntimeParameters.sendGridApiKey = @{ value = $SendGridApiKey }

  $sendEmailAction = @{
    type = 'Http'
    inputs = @{
      method = 'POST'
      uri = 'https://api.sendgrid.com/v3/mail/send'
      headers = @{
        Authorization = "@{concat('Bearer ', parameters('sendGridApiKey'))}"
        'Content-Type' = 'application/json'
      }
      body = @{
        personalizations = @(
          @{
            to = @(
              @{ email = "@{parameters('sendToEmail')}" }
            )
          }
        )
        from = @{ email = "@{parameters('sendFromEmail')}" }
        subject = "@{concat('[AVD Alert] ', coalesce(triggerBody()?['data']?['essentials']?['alertRule'], 'Unknown Rule'))}"
        content = @(
          @{
            type = 'text/html'
            value = $alertEmailHtmlExpr
          }
        )
      }
    }
    runAfter = @{}
  }
} else {
  if ([string]::IsNullOrWhiteSpace($Office365ConnectionResourceId)) {
    $Office365ConnectionResourceId = "/subscriptions/$subscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Web/connections/$Office365ConnectionName"
  }

  $office365ApiId = "/subscriptions/$subscriptionId/providers/Microsoft.Web/locations/$Location/managedApis/office365"

  $existingConnection = az resource show --ids $Office365ConnectionResourceId -o json 2>$null
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($existingConnection)) {
    if ($PSCmdlet.ShouldProcess($Office365ConnectionName, "Create Office 365 API connection")) {
      Write-Log "Creating Office 365 API connection resource: $Office365ConnectionName" "Yellow"
      $connBody = @{
        location = $Location
        properties = @{
          displayName = $Office365ConnectionName
          api = @{ id = $office365ApiId }
        }
      }

      $connTmpFile = Join-Path $env:TEMP ("office365-connection-{0}.json" -f [guid]::NewGuid().ToString('N'))
      try {
        $connBody | ConvertTo-Json -Depth 10 | Set-Content -Path $connTmpFile -Encoding utf8
        $connUri = "${Office365ConnectionResourceId}?api-version=2016-06-01"
        $connCreateOutput = az rest --method put --uri $connUri --body "@$connTmpFile" -o json 2>&1
        if ($LASTEXITCODE -ne 0) {
          throw "Failed to create Office 365 API connection '$Office365ConnectionName': $connCreateOutput"
        }
      } finally {
        Remove-Item -Path $connTmpFile -ErrorAction SilentlyContinue
      }
      Write-Log "Office 365 API connection resource created. Authorize it in Portal if prompted." "Yellow"
    }
  }

  $workflowParametersDefinition['$connections'] = @{ type = 'Object' }
  $workflowRuntimeParameters['$connections'] = @{ value = @{ office365 = @{ id = $office365ApiId; connectionId = $Office365ConnectionResourceId; connectionName = $Office365ConnectionName } } }

  $sendEmailAction = @{
    type = 'ApiConnection'
    inputs = @{
      host = @{
        connection = @{
          name = "@parameters('`$connections')['office365']['connectionId']"
        }
      }
      method = 'post'
      path = '/v2/Mail'
      body = @{
        From = "@{parameters('sendFromEmail')}"
        To = "@{parameters('sendToEmail')}"
        Subject = "@{concat('[AVD Alert] ', coalesce(triggerBody()?['data']?['essentials']?['alertRule'], 'Unknown Rule'))}"
        Body = $alertEmailHtmlExpr
        Importance = 'Normal'
      }
    }
    runAfter = @{}
  }
}

$workflowDefinition = @{
  '$schema' = 'https://schema.management.azure.com/schemas/2016-06-01/Microsoft.Logic.json'
  contentVersion = '1.0.0.0'
  parameters = $workflowParametersDefinition
  triggers = @{
    manual = @{
      type = 'Request'
      kind = 'Http'
      inputs = @{
        method = 'POST'
      }
    }
  }
  actions = @{
    Send_Detailed_Email = $sendEmailAction
    Response_Success = @{
      type = 'Response'
      runAfter = @{
        Send_Detailed_Email = @('Succeeded')
      }
      inputs = @{
        statusCode = 202
        body = @{ status = 'accepted' }
      }
    }
    Response_Failure = @{
      type = 'Response'
      runAfter = @{
        Send_Detailed_Email = @('Failed', 'TimedOut')
      }
      inputs = @{
        statusCode = 500
        body = @{ status = 'email_send_failed' }
      }
    }
  }
  outputs = @{}
}

$workflowProperties = @{
  state = 'Enabled'
  definition = $workflowDefinition
  parameters = $workflowRuntimeParameters
}

$body = @{
  location = $Location
  tags = $Tags
  properties = $workflowProperties
}

$tmpFile = Join-Path $env:TEMP ("logicapp-{0}-{1}.json" -f $LogicAppName, [guid]::NewGuid().ToString('N'))
$body | ConvertTo-Json -Depth 30 | Set-Content -Path $tmpFile -Encoding utf8

$workflowResourceId = "/subscriptions/$subscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Logic/workflows/$LogicAppName"
$workflowUri = "${workflowResourceId}?api-version=2019-05-01"

try {
  if ($PSCmdlet.ShouldProcess($LogicAppName, "Deploy/update Logic App workflow")) {
    Write-Log "Deploying Logic App workflow '$LogicAppName'..." "Cyan"
    $putOutput = az rest --method put --uri $workflowUri --body "@$tmpFile" -o json 2>&1
    if ($LASTEXITCODE -ne 0) {
      throw "Azure CLI command failed: az rest --method put --uri $workflowUri --body @$tmpFile`n$putOutput"
    }
    Write-Log "Logic App deployed/updated." "Green"
  } else {
    Write-Log "[WhatIf] Would deploy/update Logic App workflow '$LogicAppName'." "Yellow"
  }
}
finally {
  Remove-Item -Path $tmpFile -ErrorAction SilentlyContinue
}

$callbackUrl = $null
if ($PSBoundParameters.ContainsKey('WhatIf')) {
  $callbackUrl = "https://example.logic.azure.com/workflows/$LogicAppName/triggers/manual/paths/invoke?api-version=2016-10-01"
  Write-Log "[WhatIf] Callback URL (simulated): $callbackUrl" "Yellow"
} else {
  $callbackEndpoint = "${workflowResourceId}/triggers/manual/listCallbackUrl?api-version=2019-05-01"
  $callbackUrl = az rest --method post --uri $callbackEndpoint --query value -o tsv 2>$null
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($callbackUrl)) {
    throw "Logic App deployed but failed to retrieve callback URL."
  }
  Write-Log "Callback URL resolved." "Green"
}

if (-not $SkipTestInvoke -and -not $PSBoundParameters.ContainsKey('WhatIf')) {
  Write-Log "Sending test payload to callback URL..." "Cyan"
  $testPayload = @{
    schemaId = 'azureMonitorCommonAlertSchema'
    data = @{
      essentials = @{
        alertRule = 'AVD-Webhook-Deployment-Test'
        severity = 'Sev3'
        monitorCondition = 'Fired'
        firedDateTime = (Get-Date).ToString('o')
      }
      alertContext = @{
        SearchResults = @{
          tables = @(
            @{
              name = 'PrimaryResult'
              rows = @(
                @('TestUser', 'TestSource', 'TestCode', 'Sample message')
              )
            }
          )
        }
      }
    }
  } | ConvertTo-Json -Depth 10

  try {
    $resp = Invoke-WebRequest -Method Post -Uri $callbackUrl -ContentType 'application/json' -Body $testPayload -UseBasicParsing
    if ($resp.StatusCode -ge 200 -and $resp.StatusCode -lt 300) {
      Write-Log "Test invoke succeeded with status $($resp.StatusCode)." "Green"
    } else {
      Write-Log "Test invoke returned status $($resp.StatusCode)." "Yellow"
    }
  } catch {
    Write-Log "Warning: Test invoke failed: $($_.Exception.Message)" "Yellow"
  }
}

Write-Log "" 
Write-Log "=== Deployment Output ===" "Cyan"
Write-Log "Logic App Name: $LogicAppName" "White"
Write-Log "Resource Group: $ResourceGroup" "White"
Write-Log "Callback URL: $callbackUrl" "Green"
Write-Log "" 
Write-Log "Use this webhook URL with Azure-AVD-Alerts.ps1 parameter: -DetailedResultsWebhookUrl" "Gray"

# Always normalize the detailed action group receiver so webhook naming stays consistent
# even when ConfigureAlertsAfterDeploy is not used.
if ($PSCmdlet.ShouldProcess($DetailedActionGroupName, "Ensure standardized detailed webhook receiver")) {
  $detailedAgJson = az monitor action-group show -g $ResourceGroup -n $DetailedActionGroupName --subscription $subscriptionId -o json 2>$null
  $detailedAgExists = ($LASTEXITCODE -eq 0)

  if (-not $detailedAgExists) {
    Write-Log "Detailed action group '$DetailedActionGroupName' not found - creating..." "Yellow"
    $createArgs = @(
      'monitor', 'action-group', 'create',
      '-g', $ResourceGroup, '-n', $DetailedActionGroupName,
      '--subscription', $subscriptionId,
      '--short-name', 'AVDDetl',
      '--action', 'webhook', $DetailedWebhookReceiverName, ('"' + $callbackUrl + '"'),
      'usecommonalertschema'
    )
    $createOutput = az @createArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
      throw "Failed to create detailed action group '$DetailedActionGroupName': $createOutput"
    }
    Write-Log "Detailed action group '$DetailedActionGroupName' created." "Green"
  } else {
    $detailedAg = $detailedAgJson | ConvertFrom-Json
    $webhookReceivers = @($detailedAg.webhookReceivers)
    $receiverWithUrl = $webhookReceivers | Where-Object { $_.serviceUri -eq $callbackUrl } | Select-Object -First 1

    # Remove legacy receiver name to avoid duplicate webhook notifications.
    $legacyDetailedWebhookReceiverName = 'AVDAlertDetails'
    if ($DetailedWebhookReceiverName -ne $legacyDetailedWebhookReceiverName) {
      $legacyReceiver = $webhookReceivers | Where-Object { $_.name -eq $legacyDetailedWebhookReceiverName } | Select-Object -First 1
      if ($null -ne $legacyReceiver) {
        Write-Log "Legacy detailed webhook receiver '$legacyDetailedWebhookReceiverName' found - removing to avoid duplicates." "Yellow"
        az monitor action-group update -g $ResourceGroup -n $DetailedActionGroupName --subscription $subscriptionId --remove-action $legacyDetailedWebhookReceiverName 2>$null | Out-Null
      }
    }

    if ($null -eq $receiverWithUrl) {
      Write-Log "Ensuring receiver '$DetailedWebhookReceiverName' points to current callback URL..." "Cyan"
      az monitor action-group update -g $ResourceGroup -n $DetailedActionGroupName --subscription $subscriptionId --remove-action $DetailedWebhookReceiverName 2>$null | Out-Null
      $updateArgs = @(
        'monitor', 'action-group', 'update',
        '-g', $ResourceGroup, '-n', $DetailedActionGroupName,
        '--subscription', $subscriptionId,
        '--add-action', 'webhook', $DetailedWebhookReceiverName, ('"' + $callbackUrl + '"'),
        'usecommonalertschema'
      )
      $updateOutput = az @updateArgs 2>&1
      if ($LASTEXITCODE -ne 0) {
        throw "Failed to update detailed action group receiver: $updateOutput"
      }
      Write-Log "Detailed action group receiver ensured." "Green"
    } else {
      Write-Log "Detailed action group already has current callback URL receiver." "Gray"
    }
  }
} else {
  Write-Log "[WhatIf] Would ensure detailed action group '$DetailedActionGroupName' uses receiver '$DetailedWebhookReceiverName'." "Yellow"
}

if ($ConfigureAlertsAfterDeploy) {
  $missing = @()
  if (-not $AlertsEmailTo) { $missing += 'AlertsEmailTo' }
  if (-not $AlertsResourceGroup) { $missing += 'AlertsResourceGroup' }
  if (-not $AlertsLawName) { $missing += 'AlertsLawName' }
  if (-not $AlertsLocation) { $missing += 'AlertsLocation' }
  if ($missing.Count -gt 0) {
    throw "ConfigureAlertsAfterDeploy was set but missing required parameters: $($missing -join ', ')"
  }

  $alertsScriptPath = Join-Path $PSScriptRoot 'Azure-AVD-Alerts.ps1'
  if (-not (Test-Path $alertsScriptPath)) {
    throw "Alerts deployment script not found: $alertsScriptPath"
  }

  Write-Log "Invoking Azure-AVD-Alerts.ps1 with detailed webhook URL..." "Cyan"
  $alertsArgs = @{
    EmailTo = $AlertsEmailTo
    ResourceGroup = $AlertsResourceGroup
    LawName = $AlertsLawName
    Location = $AlertsLocation
    ActionGroupName = $AlertsActionGroupName
    DetailedActionGroupName = $DetailedActionGroupName
    DetailedWebhookReceiverName = $DetailedWebhookReceiverName
    Severity = $AlertsSeverity
    CreateOnly = $AlertsCreateOnly
    DetailedResultsWebhookUrl = $callbackUrl
  }
  if ($SubscriptionId) {
    $alertsArgs.SubscriptionId = $SubscriptionId
  }
  if ($PSBoundParameters.ContainsKey('WhatIf')) {
    $alertsArgs.WhatIf = $true
  }

  & $alertsScriptPath @alertsArgs
  if (-not $?) {
    throw "Azure-AVD-Alerts.ps1 execution failed."
  }
}

Write-Log "Companion Logic App deployment completed." "Green"
