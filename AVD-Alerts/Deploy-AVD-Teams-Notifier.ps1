#requires -Version 5.1
<#
==============================================================================
SCRIPT VERSION: 1.2
LAST UPDATED: March 2026
REPOSITORY: https://github.com/AzaryaShaulov/AVD
DISCLAIMER: This script is provided AS IS, without warranties or support guarantees.
==============================================================================
.SYNOPSIS
  Deploys a Teams notifier for AVD alerts and optionally attaches it to existing category alerts.

.DESCRIPTION
  Creates or updates a Logic App webhook endpoint that receives Azure Monitor common alert schema
  payloads and posts a formatted message to Microsoft Teams via an incoming webhook URL.

  This script is designed to be deployed later, after core AVD alerting is already in place.
  Optionally, it creates/updates a Teams action group and patches existing AVD-Category-* alerts
  to include that action group.

.PARAMETER ResourceGroup
  Azure resource group where Logic App and action group are managed.

.PARAMETER Location
  Azure region for Logic App deployment.

.PARAMETER LogicAppName
  Name of the Teams notifier Logic App workflow.

.PARAMETER TeamsWebhookUrl
  Teams incoming webhook URL (channel or workflow endpoint for a chat/person flow).

.PARAMETER SubscriptionId
  Optional Azure subscription ID.

.PARAMETER TeamsActionGroupName
  Name of Azure Monitor action group for the Teams notifier webhook.

.PARAMETER TeamsWebhookReceiverName
  Receiver name inside the action group.

.PARAMETER AttachToCategoryAlerts
  When true, patch existing AVD-Category-* scheduled-query alerts to include Teams action group.

.PARAMETER SkipTestInvoke
  Skip posting a sample payload to the Logic App callback URL.

.PARAMETER WhatIf
  Preview changes.

.EXAMPLE
  .\Deploy-AVD-Teams-Notifier.ps1 `
    -ResourceGroup "az-infra-eus2" `
    -Location "eastus2" `
    -LogicAppName "la-avd-alerts-teams" `
    -TeamsWebhookUrl "https://outlook.office.com/webhook/..."
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
  [string]$LogicAppName = "la-avd-alerts-teams",

  [Parameter(Mandatory = $true)]
  [ValidatePattern('^https?://.+')]
  [string]$TeamsWebhookUrl,

  [Parameter(Mandatory = $false)]
  [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
  [string]$SubscriptionId,

  [Parameter(Mandatory = $false)]
  [ValidateNotNullOrEmpty()]
  [string]$TeamsActionGroupName = "AVD-Alerts-Teams",

  [Parameter(Mandatory = $false)]
  [ValidateNotNullOrEmpty()]
  [string]$TeamsWebhookReceiverName = "AVDAlertsTeamsWebhook",

  [Parameter(Mandatory = $false)]
  [bool]$AttachToCategoryAlerts = $true,

  [Parameter(Mandatory = $false)]
  [switch]$SkipTestInvoke
)

$ErrorActionPreference = "Stop"

function Write-Log {
  param([string]$Message, [string]$Color = "White")
  $ts = Get-Date -Format "HH:mm:ss"
  Write-Host "[$ts] $Message" -ForegroundColor $Color
}

Write-Log "Starting Teams notifier deployment..." "Cyan"

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

$workflowDefinition = @{
  '$schema' = 'https://schema.management.azure.com/schemas/2016-06-01/Microsoft.Logic.json'
  contentVersion = '1.0.0.0'
  parameters = @{}
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
    Post_To_Teams = @{
      type = 'Http'
      inputs = @{
        method = 'POST'
        uri = $TeamsWebhookUrl
        headers = @{
          'Content-Type' = 'application/json'
        }
        body = @{
          '@type' = 'MessageCard'
          '@context' = 'http://schema.org/extensions'
          summary = "@{concat('AVD Alert - ', coalesce(triggerBody()?['data']?['essentials']?['alertRule'], 'Unknown Rule'))}"
          themeColor = '0078D7'
          title = "@{concat('[AVD Alert] ', coalesce(triggerBody()?['data']?['essentials']?['alertRule'], 'Unknown Rule'))}"
          text = "@{concat('<b>Severity:</b> ', string(triggerBody()?['data']?['essentials']?['severity']), '<br/><b>Condition:</b> ', coalesce(triggerBody()?['data']?['essentials']?['monitorCondition'], 'N/A'), '<br/><b>Fired:</b> ', coalesce(triggerBody()?['data']?['essentials']?['firedDateTime'], 'N/A'))}"
          sections = @(
            @{
              activityTitle = 'Alert Context'
              text = "@{string(triggerBody()?['data']?['alertContext'])}"
            }
          )
        }
      }
      runAfter = @{}
    }
    Response_Success = @{
      type = 'Response'
      runAfter = @{ Post_To_Teams = @('Succeeded') }
      inputs = @{ statusCode = 202; body = @{ status = 'accepted' } }
    }
    Response_Failure = @{
      type = 'Response'
      runAfter = @{ Post_To_Teams = @('Failed','TimedOut') }
      inputs = @{ statusCode = 500; body = @{ status = 'teams_post_failed' } }
    }
  }
  outputs = @{}
}

$workflowBody = @{
  location = $Location
  properties = @{
    state = 'Enabled'
    definition = $workflowDefinition
    parameters = @{}
  }
}

$tmpFile = Join-Path $env:TEMP ("logicapp-teams-{0}.json" -f [guid]::NewGuid().ToString('N'))
$workflowBody | ConvertTo-Json -Depth 30 | Set-Content -Path $tmpFile -Encoding utf8

$workflowResourceId = "/subscriptions/$subscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Logic/workflows/$LogicAppName"
$workflowUri = "${workflowResourceId}?api-version=2019-05-01"

try {
  if ($PSCmdlet.ShouldProcess($LogicAppName, "Deploy/update Teams notifier Logic App")) {
    Write-Log "Deploying Logic App workflow '$LogicAppName'..." "Cyan"
    $putOutput = az rest --method put --uri $workflowUri --body "@$tmpFile" -o json 2>&1
    if ($LASTEXITCODE -ne 0) {
      throw "Failed to deploy Teams Logic App: $putOutput"
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
  $callbackUrl = "https://example.logic.azure.com/workflows/$LogicAppName/triggers/manual/paths/invoke?api-version=2019-05-01"
  Write-Log "[WhatIf] Callback URL (simulated): $callbackUrl" "Yellow"
} else {
  $callbackEndpoint = "${workflowResourceId}/triggers/manual/listCallbackUrl?api-version=2019-05-01"
  $callbackUrl = az rest --method post --uri $callbackEndpoint --query value -o tsv 2>$null
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($callbackUrl)) {
    throw "Failed to retrieve Logic App callback URL."
  }
  Write-Log "Callback URL resolved." "Green"
}

if (-not $SkipTestInvoke -and -not $PSBoundParameters.ContainsKey('WhatIf')) {
  Write-Log "Sending sample test payload to Teams notifier..." "Cyan"
  $testPayload = @{
    schemaId = 'azureMonitorCommonAlertSchema'
    data = @{
      essentials = @{
        alertRule = 'AVD-Teams-TestAlert'
        severity = 'Sev3'
        monitorCondition = 'Fired'
        firedDateTime = (Get-Date).ToString('o')
      }
      alertContext = @{
        Source = 'Deploy-AVD-Teams-Notifier.ps1'
        SearchResults = @{ tables = @(@{ name = 'PrimaryResult'; rows = @(@('SampleRow')) }) }
      }
    }
  } | ConvertTo-Json -Depth 10

  try {
    $resp = Invoke-WebRequest -Method Post -Uri $callbackUrl -ContentType 'application/json' -Body $testPayload -UseBasicParsing
    Write-Log "Sample payload accepted by Teams notifier. HTTP status: $($resp.StatusCode)" "Green"
  } catch {
    Write-Log "Warning: Test invoke failed: $($_.Exception.Message)" "Yellow"
  }
}

$teamsAgId = "/subscriptions/$subscriptionId/resourceGroups/$ResourceGroup/providers/microsoft.insights/actionGroups/$TeamsActionGroupName"
if ($PSCmdlet.ShouldProcess($TeamsActionGroupName, "Create/update Teams action group")) {
  $agJson = az monitor action-group show -g $ResourceGroup -n $TeamsActionGroupName --subscription $subscriptionId -o json 2>$null
  $agExists = ($LASTEXITCODE -eq 0)

  if (-not $agExists) {
    Write-Log "Creating Teams action group '$TeamsActionGroupName'..." "Yellow"
    $createArgs = @(
      'monitor', 'action-group', 'create',
      '-g', $ResourceGroup, '-n', $TeamsActionGroupName,
      '--subscription', $subscriptionId,
      '--short-name', 'AVDTeams',
      '--action', 'webhook', $TeamsWebhookReceiverName, ('"' + $callbackUrl + '"'),
      'usecommonalertschema'
    )
    $agCreateOutput = az @createArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
      throw "Failed creating Teams action group: $agCreateOutput"
    }
    Write-Log "Teams action group created." "Green"
  } else {
    Write-Log "Teams action group exists; ensuring webhook receiver..." "Gray"
    $ag = $agJson | ConvertFrom-Json
    $webhookReceivers = @($ag.webhookReceivers)
    $existingReceiver = $webhookReceivers | Where-Object { $_.name -eq $TeamsWebhookReceiverName -and $_.serviceUri -eq $callbackUrl } | Select-Object -First 1
    if ($null -eq $existingReceiver) {
      az monitor action-group update -g $ResourceGroup -n $TeamsActionGroupName --subscription $subscriptionId --remove-action $TeamsWebhookReceiverName 2>$null | Out-Null
      $updateArgs = @(
        'monitor', 'action-group', 'update',
        '-g', $ResourceGroup, '-n', $TeamsActionGroupName,
        '--subscription', $subscriptionId,
        '--add-action', 'webhook', $TeamsWebhookReceiverName, ('"' + $callbackUrl + '"'),
        'usecommonalertschema'
      )
      $agUpdateOutput = az @updateArgs 2>&1
      if ($LASTEXITCODE -ne 0) {
        throw "Failed updating Teams action group receiver: $agUpdateOutput"
      }
      Write-Log "Teams action group webhook receiver updated." "Green"
    }
  }
} else {
  Write-Log "[WhatIf] Would create/update Teams action group '$TeamsActionGroupName'." "Yellow"
}

if ($AttachToCategoryAlerts) {
  Write-Log "Ensuring Teams action group is attached to existing AVD-Category-* alerts..." "Cyan"
  $alertNamesOutput = az monitor scheduled-query list -g $ResourceGroup --subscription $subscriptionId --query "[?starts_with(name, 'AVD-Category-')].name" -o tsv 2>$null
  $alertNames = @()
  if (-not [string]::IsNullOrWhiteSpace($alertNamesOutput)) {
    $alertNames = $alertNamesOutput -split "[\r\n]+" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
  }

  foreach ($alertName in $alertNames) {
    if (-not $PSCmdlet.ShouldProcess($alertName, "Attach Teams action group")) {
      Write-Log "[WhatIf] Would attach Teams action group to '$alertName'" "Yellow"
      continue
    }

    $currentAgOutput = az monitor scheduled-query show -g $ResourceGroup -n $alertName --subscription $subscriptionId --query "actions.actionGroups" -o json 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($currentAgOutput)) {
      Write-Log "Warning: Could not read action groups for '$alertName'." "Yellow"
      continue
    }

    $currentAgIds = @($currentAgOutput | ConvertFrom-Json)
    $currentAgNormalized = $currentAgIds | ForEach-Object { $_.ToLowerInvariant() }
    if ($currentAgNormalized -contains $teamsAgId.ToLowerInvariant()) {
      Write-Log "Teams action group already attached: $alertName" "Gray"
      continue
    }

    $newAgIds = @($currentAgIds + $teamsAgId)
    $updateArgs = @('monitor', 'scheduled-query', 'update', '-g', $ResourceGroup, '-n', $alertName, '--subscription', $subscriptionId, '--action-groups')
    $updateArgs += $newAgIds
    $updateOutput = az @updateArgs 2>&1
    if ($LASTEXITCODE -eq 0) {
      Write-Log "Attached Teams action group: $alertName" "Green"
    } else {
      Write-Log "Warning: Failed attaching Teams action group on '$alertName': $updateOutput" "Yellow"
    }
  }
}

Write-Log "" 
Write-Log "=== Teams Notifier Deployment Summary ===" "Cyan"
Write-Log "Logic App: $LogicAppName" "White"
Write-Log "Callback URL: $callbackUrl" "Green"
Write-Log "Teams Action Group: $TeamsActionGroupName" "White"
Write-Log "AttachToCategoryAlerts: $AttachToCategoryAlerts" "White"
Write-Log "Done." "Green"
