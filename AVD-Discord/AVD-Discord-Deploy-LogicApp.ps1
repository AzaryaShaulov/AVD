<#
==============================================================================
SCRIPT VERSION: 1.0
LAST UPDATED: March 29, 2026
REPOSITORY: https://github.com/AzaryaShaulov/AVD
DISCLAIMER: This script is provided AS IS, without warranties or support guarantees.
==============================================================================
.SYNOPSIS
    Deploys the AVD Discord Alert Notifier Logic App and wires it to existing action groups.

.DESCRIPTION
    Creates or updates a Consumption Logic App that receives Azure Monitor
    Common Alert Schema payloads and posts formatted embeds to a Discord
    channel via an incoming webhook.

    The script:
    - Reads the Discord webhook URL from a local .env file (never logged).
    - Loads the Logic App workflow definition from workflow-definition.json.
    - Deploys a stateless Logic App (no managed identity, no API connections).
    - Retrieves the Logic App callback URL.
    - Adds a Discord webhook receiver to one or more existing action groups.
    - Does NOT create, modify, or delete alert rules or diagnostics.
    - Does NOT create action groups -- they must already exist.

.PARAMETER SubscriptionId
    Azure subscription ID to target. If omitted, uses the current Azure CLI context.

.PARAMETER ResourceGroupName
    Resource group where the Logic App will be deployed.

.PARAMETER LogicAppName
    Name of the Logic App resource.

.PARAMETER Location
    Azure region for deployment (for example: eastus2).

.PARAMETER ActionGroupNames
    One or more existing Azure Monitor action group names to wire with a
    Discord webhook receiver. Example: @("AVD-Alerts-Detailed","AVD-Insights-Detailed")

.PARAMETER ActionGroupResourceGroup
    Resource group containing the action groups. Defaults to ResourceGroupName.

.PARAMETER DiscordReceiverName
    Name for the webhook receiver added to each action group.

.PARAMETER DiscordUsername
    Display name shown as the Discord message author.

.PARAMETER DiscordAvatarUrl
    Optional avatar image URL for the Discord bot.

.PARAMETER EnvironmentName
    Environment label included in Discord embed footer (e.g., Production, Staging).

.PARAMETER EnvFilePath
    Path to the .env file containing DISCORD_WEBHOOK_URL.
    Defaults to .\.env in the script directory.

.PARAMETER Tags
    Optional resource tags to apply to the Logic App.

.PARAMETER UseHardCodedDefaults
    Uses values from the internal $HardCoded map when provided.

.PARAMETER PreviewOnly
    Show what the script would do without deploying anything.

.PARAMETER CsvPath
    Optional output path for the CSV deployment report.

.EXAMPLE
    .\AVD-Discord-Deploy-LogicApp.ps1 `
      -SubscriptionId "YOUR-SUBSCRIPTION-ID" `
      -ResourceGroupName "rg-avd-monitoring" `
      -LogicAppName "AVD-Discord-Notifier" `
      -Location "eastus2" `
      -ActionGroupNames @("AVD-Alerts-Detailed","AVD-Insights-Detailed")

.EXAMPLE
    .\AVD-Discord-Deploy-LogicApp.ps1 -UseHardCodedDefaults

.NOTES
    - Requires Azure CLI login with permissions to create Logic Apps and update action groups.
    - Discord webhook URL is read from .env file and stored as SecureString parameter in the Logic App.
    - No managed identity, RBAC assignment, or Office 365 API connection is needed.
    - Run AVD-Discord-Precheck.ps1 first to validate prerequisites.
#>

[CmdletBinding()]
param(
    [ValidateNotNullOrEmpty()]
    [string]$SubscriptionId,

    [ValidateNotNullOrEmpty()]
    [string]$ResourceGroupName,

    [ValidateNotNullOrEmpty()]
    [string]$LogicAppName,

    [ValidateNotNullOrEmpty()]
    [string]$Location,

    [string[]]$ActionGroupNames = @(),

    [string]$ActionGroupResourceGroup = "",

    [string]$DiscordReceiverName = "AVDDiscordWebhook",

    [string]$DiscordUsername = "Azure Monitor",

    [string]$DiscordAvatarUrl = "",

    [string]$EnvironmentName = "Production",

    [string]$EnvFilePath = "",

    [hashtable]$Tags = @{},

    [switch]$UseHardCodedDefaults,

    [switch]$PreviewOnly,

    [string]$CsvPath = ""
)

$ErrorActionPreference = "Stop"
$ScriptStartTime = Get-Date

# =========================
# OPTIONAL HARDCODED DEFAULTS
# Set these if you want to run with -UseHardCodedDefaults
# =========================
$HardCoded = @{
    SubscriptionId           = ""
    ResourceGroupName        = ""
    LogicAppName             = "AVD-Discord-Notifier"
    Location                 = ""
    ActionGroupNames         = @("AVD-Alerts-Detailed", "AVD-Insights-Detailed")
    ActionGroupResourceGroup = ""
    DiscordReceiverName      = "AVDDiscordWebhook"
    DiscordUsername           = "Azure Monitor"
    DiscordAvatarUrl         = ""
    EnvironmentName          = "Production"
    Tags                     = @{
        Solution    = "AVD"
        Component   = "Discord-Notifier"
        Environment = "Prod"
    }
}

# =========================
# Helper Functions
# =========================

function Write-Step {
    param([string]$Message)
    Write-Host "`n=== $Message ===" -ForegroundColor Cyan
}

function Resolve-Setting {
    param(
        [string]$Value,
        [string]$DefaultValue,
        [string]$Name
    )
    if (-not [string]::IsNullOrWhiteSpace($Value)) { return $Value }
    if (-not [string]::IsNullOrWhiteSpace($DefaultValue)) { return $DefaultValue }
    throw "Missing required value for '$Name'. Provide it as a parameter or populate the hard-coded defaults and use -UseHardCodedDefaults."
}

function Invoke-AzCliJson {
    param([Parameter(Mandatory)][string[]]$Arguments)
    if ($Arguments -notcontains '-o' -and $Arguments -notcontains '--output') {
        $Arguments += @('-o', 'json')
    }
    $result = & az @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Azure CLI command failed: az $($Arguments -join ' ')`n$result" }
    if ([string]::IsNullOrWhiteSpace(($result | Out-String))) { return $null }
    return ($result | Out-String | ConvertFrom-Json)
}

function Invoke-AzCliText {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $result = & az @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Azure CLI command failed: az $($Arguments -join ' ')`n$result" }
    return ($result | Out-String).Trim()
}

function Read-EnvFile {
    param([Parameter(Mandatory)][string]$Path)
    $vars = @{}
    if (-not (Test-Path -Path $Path)) {
        throw "Environment file not found: $Path"
    }
    Get-Content -Path $Path | ForEach-Object {
        $line = $_.Trim()
        if ($line -and -not $line.StartsWith('#')) {
            $eqIndex = $line.IndexOf('=')
            if ($eqIndex -gt 0) {
                $key = $line.Substring(0, $eqIndex).Trim()
                $val = $line.Substring($eqIndex + 1).Trim()
                $vars[$key] = $val
            }
        }
    }
    return $vars
}

function Add-DiscordReceiverToActionGroup {
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string]$ActionGroupName,
        [Parameter(Mandatory)][string]$ReceiverName,
        [Parameter(Mandatory)][string]$ServiceUri
    )

    # Read the existing action group to preserve all current receivers
    $actionGroupId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/microsoft.insights/actionGroups/$ActionGroupName"
    $actionGroupUri = "${actionGroupId}?api-version=2023-01-01"

    $existing = $null
    try {
        $existing = Invoke-AzCliJson -Arguments @("rest", "--method", "get", "--uri", $actionGroupUri)
    }
    catch {
        throw "Action group '$ActionGroupName' not found in resource group '$ResourceGroupName'. It must exist before wiring Discord."
    }

    # Preserve existing webhook receivers, replace or add the Discord one
    $webhookReceivers = @()
    if ($existing.properties.webhookReceivers) {
        foreach ($receiver in $existing.properties.webhookReceivers) {
            if ($receiver.name -ne $ReceiverName) {
                $webhookReceivers += $receiver
            }
        }
    }

    # Add the Discord receiver
    $webhookReceivers += @{
        name                 = $ReceiverName
        serviceUri           = $ServiceUri
        useCommonAlertSchema = $true
    }

    # Preserve all receiver types from the existing action group, passing through original objects
    $actionGroupBody = @{
        location   = 'Global'
        tags       = if ($existing.tags) { $existing.tags } else { @{} }
        properties = @{
            groupShortName               = $existing.properties.groupShortName
            enabled                      = $existing.properties.enabled
            emailReceivers               = @($existing.properties.emailReceivers)
            smsReceivers                 = @($existing.properties.smsReceivers)
            webhookReceivers             = $webhookReceivers
            armRoleReceivers             = @($existing.properties.armRoleReceivers)
            logicAppReceivers            = @($existing.properties.logicAppReceivers)
            automationRunbookReceivers   = @($existing.properties.automationRunbookReceivers)
            azureAppPushReceivers        = @($existing.properties.azureAppPushReceivers)
            azureFunctionReceivers       = @($existing.properties.azureFunctionReceivers)
            eventHubReceivers            = @($existing.properties.eventHubReceivers)
            itsmReceivers                = @($existing.properties.itsmReceivers)
            voiceReceivers               = @($existing.properties.voiceReceivers)
        }
    }

    $tmpFile = Join-Path $env:TEMP ("action-group-discord-{0}-{1}.json" -f $ActionGroupName, [guid]::NewGuid().ToString('N'))
    try {
        $jsonContent = $actionGroupBody | ConvertTo-Json -Depth 20
        [System.IO.File]::WriteAllText($tmpFile, $jsonContent, (New-Object System.Text.UTF8Encoding($false)))
        $priorEAP = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        $result = & az rest --method put --uri $actionGroupUri --body "@$tmpFile" -o json 2>&1
        $exitCode = $LASTEXITCODE
        $ErrorActionPreference = $priorEAP
        if ($exitCode -ne 0) {
            throw "Failed to update action group '$ActionGroupName' with Discord receiver.`n$result"
        }
    }
    finally {
        Remove-Item -Path $tmpFile -ErrorAction SilentlyContinue
    }
}

# =========================
# Resolve runtime values
# =========================
if ($UseHardCodedDefaults) {
    $SubscriptionId           = Resolve-Setting -Value $SubscriptionId          -DefaultValue $HardCoded.SubscriptionId           -Name "SubscriptionId"
    $ResourceGroupName        = Resolve-Setting -Value $ResourceGroupName       -DefaultValue $HardCoded.ResourceGroupName        -Name "ResourceGroupName"
    $LogicAppName             = Resolve-Setting -Value $LogicAppName            -DefaultValue $HardCoded.LogicAppName             -Name "LogicAppName"
    $Location                 = Resolve-Setting -Value $Location                -DefaultValue $HardCoded.Location                 -Name "Location"
    $DiscordReceiverName      = if ([string]::IsNullOrWhiteSpace($DiscordReceiverName)) { $HardCoded.DiscordReceiverName } else { $DiscordReceiverName }
    $DiscordUsername          = if ([string]::IsNullOrWhiteSpace($DiscordUsername)) { $HardCoded.DiscordUsername } else { $DiscordUsername }
    $DiscordAvatarUrl         = if ([string]::IsNullOrWhiteSpace($DiscordAvatarUrl)) { $HardCoded.DiscordAvatarUrl } else { $DiscordAvatarUrl }
    $EnvironmentName          = if ([string]::IsNullOrWhiteSpace($EnvironmentName)) { $HardCoded.EnvironmentName } else { $EnvironmentName }

    if ($ActionGroupNames.Count -eq 0 -and $HardCoded.ActionGroupNames.Count -gt 0) {
        $ActionGroupNames = $HardCoded.ActionGroupNames
    }
    if ([string]::IsNullOrWhiteSpace($ActionGroupResourceGroup)) {
        $ActionGroupResourceGroup = if (-not [string]::IsNullOrWhiteSpace($HardCoded.ActionGroupResourceGroup)) { $HardCoded.ActionGroupResourceGroup } else { $ResourceGroupName }
    }
    if (-not $Tags -or $Tags.Count -eq 0) {
        $Tags = $HardCoded.Tags
    }
}
else {
    $SubscriptionId    = Resolve-Setting -Value $SubscriptionId    -DefaultValue "" -Name "SubscriptionId"
    $ResourceGroupName = Resolve-Setting -Value $ResourceGroupName -DefaultValue "" -Name "ResourceGroupName"
    $LogicAppName      = Resolve-Setting -Value $LogicAppName      -DefaultValue "" -Name "LogicAppName"
    $Location          = Resolve-Setting -Value $Location          -DefaultValue "" -Name "Location"

    if ([string]::IsNullOrWhiteSpace($ActionGroupResourceGroup)) {
        $ActionGroupResourceGroup = $ResourceGroupName
    }
}

if (-not $Tags) { $Tags = @{} }

if ([string]::IsNullOrWhiteSpace($CsvPath)) {
    $subPrefix = if ($SubscriptionId.Length -ge 8) { $SubscriptionId.Substring(0, 8) } else { $SubscriptionId }
    $CsvPath = Join-Path $PSScriptRoot "avd-discord-deploy-report-$subPrefix.csv"
}

# =========================
# Read Discord Webhook URL from .env
# =========================
Write-Step "Reading Discord webhook URL from .env"
if ([string]::IsNullOrWhiteSpace($EnvFilePath)) {
    $EnvFilePath = Join-Path $PSScriptRoot ".env"
}

$envVars = Read-EnvFile -Path $EnvFilePath
$DiscordWebhookUrl = $envVars['DISCORD_WEBHOOK_URL']
if ([string]::IsNullOrWhiteSpace($DiscordWebhookUrl)) {
    throw "DISCORD_WEBHOOK_URL not found in '$EnvFilePath'. Add it as: DISCORD_WEBHOOK_URL=https://discord.com/api/webhooks/..."
}

if ($DiscordWebhookUrl -notmatch '^https://discord(app)?\.com/api/webhooks/\d+/.+$') {
    throw "DISCORD_WEBHOOK_URL does not match expected Discord webhook URL format."
}

Write-Host "Discord webhook URL loaded from .env (value not displayed)." -ForegroundColor Gray

# =========================
# Preview mode
# =========================
if ($PreviewOnly) {
    Write-Step "PREVIEW MODE -- no changes will be made"
    Write-Host "Subscription:        $SubscriptionId"
    Write-Host "Resource Group:      $ResourceGroupName"
    Write-Host "Logic App:           $LogicAppName"
    Write-Host "Location:            $Location"
    Write-Host "Discord Username:    $DiscordUsername"
    Write-Host "Environment:         $EnvironmentName"
    Write-Host "Action Groups:       $($ActionGroupNames -join ', ')"
    Write-Host "AG Resource Group:   $ActionGroupResourceGroup"
    Write-Host "Discord Receiver:    $DiscordReceiverName"
    Write-Host "Webhook URL:         (loaded from .env, hidden)"
    Write-Host ""
    Write-Host "Preview complete. Remove -PreviewOnly to deploy." -ForegroundColor Yellow
    return
}

# =========================
# Pre-flight Checks
# =========================
Write-Step "Checking Azure CLI login"
& az account show -o none 2>$null
if ($LASTEXITCODE -ne 0) { throw "Azure CLI is not logged in. Run 'az login' first." }

Write-Step "Setting Azure subscription"
& az account set --subscription $SubscriptionId
if ($LASTEXITCODE -ne 0) { throw "Failed to set Azure subscription to $SubscriptionId" }

Write-Step "Ensuring resource group exists"
$rgExists = Invoke-AzCliText -Arguments @("group", "exists", "--name", $ResourceGroupName)
if ($rgExists -eq "false") {
    $tagArgs = @()
    if ($Tags.Count -gt 0) {
        $flatTags = $Tags.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }
        $tagArgs = @("--tags") + $flatTags
    }
    & az group create --name $ResourceGroupName --location $Location @tagArgs | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Failed to create resource group $ResourceGroupName" }
    Write-Host "Resource group '$ResourceGroupName' created." -ForegroundColor Green
}
else {
    Write-Host "Resource group '$ResourceGroupName' exists." -ForegroundColor Gray
}

# =========================
# Load Workflow Definition from JSON
# =========================
Write-Step "Loading workflow definition from workflow-definition.json"
$workflowJsonPath = Join-Path $PSScriptRoot "workflow-definition.json"
if (-not (Test-Path -Path $workflowJsonPath)) {
    throw "workflow-definition.json not found at '$workflowJsonPath'. It must be in the same directory as this script."
}

$workflowDefinitionRaw = Get-Content -Raw -Path $workflowJsonPath
$workflowDefinition = $workflowDefinitionRaw | ConvertFrom-Json

Write-Host "Workflow definition loaded." -ForegroundColor Gray

# =========================
# Build and Deploy Logic App
# =========================
Write-Step "Deploying Logic App '$LogicAppName'"

$body = @{
    location   = $Location
    tags       = $Tags
    properties = @{
        state      = 'Enabled'
        definition = $workflowDefinition
        parameters = @{
            discordWebhookUrl = @{ value = $DiscordWebhookUrl }
            discordUsername    = @{ value = $DiscordUsername }
            discordAvatarUrl  = @{ value = $DiscordAvatarUrl }
            environmentName   = @{ value = $EnvironmentName }
        }
    }
}

$workflowResourceId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Logic/workflows/$LogicAppName"
$workflowTempFile = Join-Path $env:TEMP ("logicapp-discord-{0}-{1}.json" -f $LogicAppName, [guid]::NewGuid().ToString('N'))
try {
    $jsonContent = $body | ConvertTo-Json -Depth 100
    [System.IO.File]::WriteAllText($workflowTempFile, $jsonContent, (New-Object System.Text.UTF8Encoding($false)))

    $priorEAP = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $deployResult = & az resource create `
        --id $workflowResourceId `
        --api-version 2019-05-01 `
        --is-full-object `
        --properties "@$workflowTempFile" `
        -o json 2>&1
    $deployExitCode = $LASTEXITCODE
    $ErrorActionPreference = $priorEAP

    if ($deployExitCode -ne 0) {
        throw "Failed to deploy Logic App '$LogicAppName'`n$deployResult"
    }

    Write-Host "Logic App '$LogicAppName' deployed successfully." -ForegroundColor Green
}
finally {
    Remove-Item -Path $workflowTempFile -ErrorAction SilentlyContinue
}

# =========================
# Retrieve Callback URL
# =========================
Write-Step "Retrieving Logic App callback URL"
$callbackValue = Invoke-AzCliText -Arguments @(
    "rest",
    "--method", "post",
    "--uri", "$workflowResourceId/triggers/When_an_HTTP_request_is_received/listCallbackUrl?api-version=2019-05-01",
    "--body", "{}",
    "--query", "value",
    "-o", "tsv"
)

if ([string]::IsNullOrWhiteSpace($callbackValue)) {
    throw "Failed to retrieve Logic App callback URL."
}

Write-Host "Callback URL retrieved (contains SAS token - treat as secret)." -ForegroundColor Gray

# =========================
# Wire Action Groups
# =========================
$wiredActionGroups = @()
if ($ActionGroupNames.Count -gt 0) {
    Write-Step "Wiring Discord receiver to action group(s)"
    foreach ($agName in $ActionGroupNames) {
        Write-Host "  Adding '$DiscordReceiverName' to '$agName'..." -ForegroundColor Gray
        try {
            Add-DiscordReceiverToActionGroup `
                -SubscriptionId $SubscriptionId `
                -ResourceGroupName $ActionGroupResourceGroup `
                -ActionGroupName $agName `
                -ReceiverName $DiscordReceiverName `
                -ServiceUri $callbackValue
            Write-Host "  '$agName' - Discord receiver wired." -ForegroundColor Green
            $wiredActionGroups += $agName
        }
        catch {
            Write-Warning "  Failed to wire '$agName': $($_.Exception.Message)"
        }
    }

    if ($wiredActionGroups.Count -eq 0) {
        Write-Warning "No action groups were wired. You can wire them manually using the callback URL."
    }
}
else {
    Write-Host "No action group names provided. Wire manually using the callback URL." -ForegroundColor Yellow
}

# =========================
# Summary and CSV Report
# =========================
Write-Host ""
Write-Host "Deployment complete." -ForegroundColor Green
Write-Host ""
Write-Host "Logic App:           $LogicAppName"
Write-Host "Resource Group:      $ResourceGroupName"
Write-Host "Subscription:        $SubscriptionId"
Write-Host "Environment:         $EnvironmentName"
Write-Host "Discord Username:    $DiscordUsername"
Write-Host "Wired Action Groups: $($wiredActionGroups -join ', ')"
Write-Host ""
Write-Host "Next steps:"
Write-Host "1. Run AVD-Discord-TestAlert.ps1 to send a test payload."
Write-Host "2. Verify the message appears in your Discord channel."
Write-Host "3. If action groups were not wired automatically, add a webhook receiver manually."

$ScriptEndTime = Get-Date
$ExecutionSeconds = [Math]::Round(($ScriptEndTime - $ScriptStartTime).TotalSeconds, 1)

$reportRows = @(
    [pscustomobject]@{
        TimestampUtc         = (Get-Date).ToUniversalTime().ToString("o")
        SubscriptionId       = $SubscriptionId
        ResourceGroupName    = $ResourceGroupName
        LogicAppName         = $LogicAppName
        Location             = $Location
        EnvironmentName      = $EnvironmentName
        DiscordUsername       = $DiscordUsername
        DiscordReceiverName  = $DiscordReceiverName
        WiredActionGroups    = ($wiredActionGroups -join ';')
        ExecutionSeconds     = $ExecutionSeconds
        Result               = "Success"
    }
)

try {
    $csvDirectory = Split-Path -Path $CsvPath -Parent
    if (-not [string]::IsNullOrWhiteSpace($csvDirectory) -and -not (Test-Path -Path $csvDirectory)) {
        New-Item -Path $csvDirectory -ItemType Directory -Force | Out-Null
    }
    $reportRows | Export-Csv -Path $CsvPath -NoTypeInformation -Force
    Write-Host "CSV report written: $CsvPath" -ForegroundColor Green
}
catch {
    Write-Warning "Failed to write CSV report to '$CsvPath': $($_.Exception.Message)"
}
