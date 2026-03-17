<#
==============================================================================
SCRIPT VERSION: 1.2
LAST UPDATED: March 12, 2026
REPOSITORY: https://github.com/AzaryaShaulov/AVD
DISCLAIMER: This script is provided AS IS, without warranties or support guarantees.
==============================================================================
.SYNOPSIS
    Deploys and configures the AVD Logic App webhook notification pipeline.

.DESCRIPTION
    Creates or updates the Logic App workflow, ensures the detailed webhook action group,
    validates and authorizes required API connections, and configures alert routing so
    AVD category alerts send detailed notifications through the webhook path.

.PARAMETER SubscriptionId
    Azure subscription ID to target. If omitted, uses the current Azure CLI context.

.PARAMETER ResourceGroupName
    Resource group where Logic App and related alert resources are deployed.

.PARAMETER LogicAppName
    Name of the Logic App workflow used for detailed AVD alert notifications.

.PARAMETER Location
    Azure region for deployment (for example: eastus2).

.PARAMETER WorkspaceName
    Log Analytics workspace name used by the alert queries.

.PARAMETER WorkspaceResourceGroupName
    Resource group containing the Log Analytics workspace.

.PARAMETER SendToEmails
    One or more recipient email addresses for detailed notifications.

.PARAMETER SendToEmail
    Single recipient email address (legacy single-value option).

.PARAMETER SendFromEmail
    Sender mailbox address used by the Office 365 connection.

.PARAMETER Office365ConnectionName
    Existing API connection name for Office 365 (default: office365).

.PARAMETER DetailedActionGroupName
    Azure Monitor action group name for webhook-based detailed alerts.

.PARAMETER DetailedWebhookReceiverName
    Webhook receiver name created/updated inside the detailed action group.

.PARAMETER Tags
    Optional resource tags to apply to deployed resources.

.PARAMETER UseHardCodedDefaults
    Uses values from the internal $HardCoded map when provided.

.PARAMETER CsvPath
    Optional output path for post-run CSV summary report.
    If omitted, defaults to .\avd-webhook-deploy-report-<subscriptionPrefix>.csv.

.EXAMPLE
    .\AVD-Deploy-Alert-LogicApp.ps1 `
      -SubscriptionId "YOUR-SUBSCRIPTION-ID" `
      -ResourceGroupName "rg-avd-monitoring" `
      -LogicAppName "AVD-alert-details" `
      -Location "eastus2" `
      -WorkspaceName "law-avd-prod" `
      -WorkspaceResourceGroupName "rg-avd-monitoring" `
      -SendToEmail "alerts@contoso.com" `
      -SendFromEmail "alerts@contoso.com" `
      -Office365ConnectionName "avd-alerts-office365"

    Deploy webhook-based detailed notifications using a single recipient.

.EXAMPLE
    .\AVD-Deploy-Alert-LogicApp.ps1 `
      -SubscriptionId "YOUR-SUBSCRIPTION-ID" `
      -ResourceGroupName "rg-avd-monitoring" `
      -LogicAppName "AVD-alert-details" `
      -Location "eastus2" `
      -WorkspaceName "law-avd-prod" `
      -WorkspaceResourceGroupName "rg-avd-monitoring" `
      -SendToEmails "avdops@contoso.com","noc@contoso.com" `
      -SendFromEmail "alerts@contoso.com" `
      -Office365ConnectionName "avd-alerts-office365"

    Deploy with multiple recipients using -SendToEmails.

.NOTES
    Script function summary:
    - Deploys/updates Logic App workflow resources used for detailed alert notifications.
    - Ensures AVD detailed action group webhook receiver is present and points to callback URL.
    - Assigns Log Analytics Reader to the Logic App managed identity for query access.
    - Verifies required AVD-Category alerts exist and bootstraps them when missing.
    - Applies detailed-only routing for AVD category alerts after webhook deployment.

    Operational notes:
    - Requires Azure CLI login and permissions for Logic App, Monitor, and IAM changes.
    - Office365 connection may require manual authorization in Azure Portal before emails flow.
    - Supports either -SendToEmail (single) or -SendToEmails (multiple recipients).
#>

param(
    [ValidateNotNullOrEmpty()]
    [string]$SubscriptionId,

    [ValidateNotNullOrEmpty()]
    [string]$ResourceGroupName,

    [ValidateNotNullOrEmpty()]
    [string]$LogicAppName,

    [ValidateNotNullOrEmpty()]
    [string]$Location,

    [ValidateNotNullOrEmpty()]
    [string]$WorkspaceName,

    [ValidateNotNullOrEmpty()]
    [string]$WorkspaceResourceGroupName,

    [string[]]$SendToEmails = @(),
    [string]$SendToEmail = "",

    [ValidateNotNullOrEmpty()]
    [string]$SendFromEmail,

    [string]$Office365ConnectionName = "office365",
    [string]$DetailedActionGroupName = "AVD-Alerts-Detailed",
    [string]$DetailedWebhookReceiverName = "AVDAlertsDetailedWebhook",
    [string]$CsvPath = "",
    [hashtable]$Tags = @{},
    [switch]$UseHardCodedDefaults
)

$ErrorActionPreference = "Stop"
$ScriptStartTime = Get-Date

# =========================
# OPTIONAL HARDCODED DEFAULTS
# Set these if you want to run with -UseHardCodedDefaults
# =========================
$HardCoded = @{
    SubscriptionId              = ""
    ResourceGroupName           = ""
    LogicAppName                = ""
    Location                    = ""
    WorkspaceName               = ""
    WorkspaceResourceGroupName  = ""
    SendToEmails                = @()
    SendToEmail                 = ""
    SendFromEmail               = ""
    Office365ConnectionName     = "office365"
    DetailedActionGroupName     = "AVD-Alerts-Detailed"
    DetailedWebhookReceiverName = "AVDAlertsDetailedWebhook"
    Tags                        = @{
        Solution    = "AVD"
        Environment = "Prod"
    }
}

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

    if (-not [string]::IsNullOrWhiteSpace($Value)) {
        return $Value
    }

    if (-not [string]::IsNullOrWhiteSpace($DefaultValue)) {
        return $DefaultValue
    }

    throw "Missing required value for '$Name'. Provide it as a parameter or populate the hard-coded defaults and use -UseHardCodedDefaults."
}

function Get-AlertDefinitionMap {
    param(
        [Parameter(Mandatory = $true)]
        [array]$Definitions
    )

    $map = @{}
    foreach ($definition in $Definitions) {
        $map[$definition.Name] = @{
            Description = $definition.Description
            Kql         = $definition.Kql
        }
    }

    return $map
}

function Invoke-AzCliJson {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $result = & az @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI command failed: az $($Arguments -join ' ')`n$result"
    }

    if ([string]::IsNullOrWhiteSpace(($result | Out-String))) {
        return $null
    }

    return ($result | Out-String | ConvertFrom-Json)
}

function Invoke-AzCliText {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $result = & az @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI command failed: az $($Arguments -join ' ')`n$result"
    }

    return ($result | Out-String).Trim()
}

function Set-DetailedActionGroupWebhook {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SubscriptionId,
        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,
        [Parameter(Mandatory = $true)]
        [string]$ActionGroupName,
        [Parameter(Mandatory = $true)]
        [string]$ReceiverName,
        [Parameter(Mandatory = $true)]
        [string]$ServiceUri
    )

    $actionGroupId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/microsoft.insights/actionGroups/$ActionGroupName"
    $actionGroupUri = "${actionGroupId}?api-version=2023-01-01"
    $actionGroupBody = @{
        location = 'Global'
        properties = @{
            groupShortName = 'AVDDetl'
            enabled = $true
            webhookReceivers = @(
                @{
                    name = $ReceiverName
                    serviceUri = $ServiceUri
                    useCommonAlertSchema = $true
                }
            )
        }
    }

    $tmpFile = Join-Path -Path $env:TEMP -ChildPath ("action-group-{0}-{1}.json" -f $ActionGroupName, [guid]::NewGuid().ToString('N'))
    try {
        $actionGroupBody | ConvertTo-Json -Depth 20 | Set-Content -Path $tmpFile -Encoding utf8
        $result = & az rest --method put --uri $actionGroupUri --body "@$tmpFile" -o json 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to create/update action group '$ActionGroupName'`n$result"
        }
    }
    finally {
        Remove-Item -Path $tmpFile -ErrorAction SilentlyContinue
    }
}

function Set-AVDCategoryAlertsToDetailedOnly {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SubscriptionId,
        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,
        [Parameter(Mandatory = $true)]
        [string]$DetailedActionGroupName
    )

    $detailedActionGroupId = Invoke-AzCliText -Arguments @(
        "monitor", "action-group", "show",
        "--resource-group", $ResourceGroupName,
        "--name", $DetailedActionGroupName,
        "--subscription", $SubscriptionId,
        "--query", "id",
        "-o", "tsv"
    )

    if ([string]::IsNullOrWhiteSpace($detailedActionGroupId)) {
        throw "Failed to resolve action group ID for '$DetailedActionGroupName'."
    }

    $alertNameOutput = Invoke-AzCliText -Arguments @(
        "monitor", "scheduled-query", "list",
        "--resource-group", $ResourceGroupName,
        "--subscription", $SubscriptionId,
        "--query", "[?starts_with(name, 'AVD-Category-')].name",
        "-o", "tsv"
    )

    if ([string]::IsNullOrWhiteSpace($alertNameOutput)) {
        Write-Warning "No existing AVD-Category alert rules were found in resource group '$ResourceGroupName'."
        return
    }

    $alertNames = $alertNameOutput -split "[\r\n]+" |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { $_.Trim() }

    $updated = 0
    $failed = @()
    foreach ($alertName in $alertNames) {
        $updateOutput = & az monitor scheduled-query update `
            --resource-group $ResourceGroupName `
            --name $alertName `
            --subscription $SubscriptionId `
            --action-groups $detailedActionGroupId 2>&1

        if ($LASTEXITCODE -eq 0) {
            $updated++
            Write-Host "Updated '$alertName' to detailed-only action group." -ForegroundColor Gray
        }
        else {
            $failed += $alertName
            Write-Warning "Failed to update alert '$alertName' to detailed-only action group. $updateOutput"
        }
    }

    if ($failed.Count -gt 0) {
        throw "Updated $updated alert(s), but failed to update $($failed.Count): $($failed -join ', ')"
    }

    Write-Host "All $updated AVD-Category alert(s) now use detailed-only action group '$DetailedActionGroupName'." -ForegroundColor Green
}

function Ensure-AVDCategoryAlertsExist {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SubscriptionId,
        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,
        [Parameter(Mandatory = $true)]
        [string]$WorkspaceResourceGroupName,
        [Parameter(Mandatory = $true)]
        [string]$WorkspaceName,
        [Parameter(Mandatory = $true)]
        [string]$Location,
        [Parameter(Mandatory = $true)]
        [string]$DetailedActionGroupName,
        [Parameter(Mandatory = $true)]
        [string]$DetailedWebhookReceiverName,
        [Parameter(Mandatory = $true)]
        [string]$DetailedResultsWebhookUrl
    )

    # Guard: ensure scheduled-query extension is available before any az monitor scheduled-query calls
    & az extension show --name scheduled-query -o none 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Installing 'scheduled-query' extension for bootstrap..." -ForegroundColor Yellow
        & az extension add --name scheduled-query --yes -o none 2>$null
        if ($LASTEXITCODE -ne 0) {
            throw "Required Azure CLI extension 'scheduled-query' could not be installed."
        }
    }

    $existingAlertNamesOutput = Invoke-AzCliText -Arguments @(
        "monitor", "scheduled-query", "list",
        "--resource-group", $ResourceGroupName,
        "--subscription", $SubscriptionId,
        "--query", "[?starts_with(name, 'AVD-Category-')].name",
        "-o", "tsv"
    )

    $existingAlertNames = @()
    if (-not [string]::IsNullOrWhiteSpace($existingAlertNamesOutput)) {
        $existingAlertNames = $existingAlertNamesOutput -split "[\r\n]+" |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object { $_.Trim() }
    }

    $requiredAlertNames = @(
        'AVD-Category-AuthenticationIdentity',
        'AVD-Category-AuthorizationPolicy',
        'AVD-Category-ConnectionNetworkGateway',
        'AVD-Category-SessionHostHealthCapacity',
        'AVD-Category-PersonalDesktopAssignment',
        'AVD-Category-DeviceGraphicsInput',
        'AVD-Category-FSLogixProfileStorage',
        'AVD-Category-UnknownUnclassified'
    )

    $missingAlertNames = $requiredAlertNames | Where-Object { $existingAlertNames -notcontains $_ }
    if ($missingAlertNames.Count -eq 0) {
        Write-Host "All required AVD-Category alerts already exist; bootstrap creation is not required." -ForegroundColor Gray
        return
    }

    $coreAlertsScriptPath = Join-Path -Path $PSScriptRoot -ChildPath "AVD-Category-Alerts.ps1"
    if (-not (Test-Path -Path $coreAlertsScriptPath)) {
        throw "Could not find AVD-Category-Alerts.ps1 at '$coreAlertsScriptPath'."
    }

    Write-Host "Detected $($missingAlertNames.Count) missing AVD-Category alert(s). Bootstrapping core alerts via AVD-Category-Alerts.ps1..." -ForegroundColor Yellow

    & $coreAlertsScriptPath `
        -SubscriptionId $SubscriptionId `
        -ResourceGroup $ResourceGroupName `
        -WorkspaceResourceGroupName $WorkspaceResourceGroupName `
        -WorkspaceName $WorkspaceName `
        -Location $Location `
        -DetailedActionGroupName $DetailedActionGroupName `
        -DetailedWebhookReceiverName $DetailedWebhookReceiverName `
        -DetailedResultsWebhookUrl $DetailedResultsWebhookUrl `
        -CreateOnly $true

    if ($LASTEXITCODE -ne 0) {
        throw "Bootstrap alert creation via AVD-Category-Alerts.ps1 failed."
    }

    $postBootstrapOutput = Invoke-AzCliText -Arguments @(
        "monitor", "scheduled-query", "list",
        "--resource-group", $ResourceGroupName,
        "--subscription", $SubscriptionId,
        "--query", "[?starts_with(name, 'AVD-Category-')].name",
        "-o", "tsv"
    )

    $postBootstrapAlertNames = @()
    if (-not [string]::IsNullOrWhiteSpace($postBootstrapOutput)) {
        $postBootstrapAlertNames = $postBootstrapOutput -split "[\r\n]+" |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object { $_.Trim() }
    }

    $stillMissing = $requiredAlertNames | Where-Object { $postBootstrapAlertNames -notcontains $_ }
    if ($stillMissing.Count -gt 0) {
        throw "Bootstrap completed but required alerts are still missing: $($stillMissing -join ', ')"
    }

    Write-Host "Bootstrap complete: required AVD-Category alerts now exist." -ForegroundColor Green
}

# =========================
# Resolve runtime values
# =========================
if ($UseHardCodedDefaults) {
    $SubscriptionId             = Resolve-Setting -Value $SubscriptionId            -DefaultValue $HardCoded.SubscriptionId             -Name "SubscriptionId"
    $ResourceGroupName          = Resolve-Setting -Value $ResourceGroupName         -DefaultValue $HardCoded.ResourceGroupName          -Name "ResourceGroupName"
    $LogicAppName               = Resolve-Setting -Value $LogicAppName              -DefaultValue $HardCoded.LogicAppName               -Name "LogicAppName"
    $Location                   = Resolve-Setting -Value $Location                  -DefaultValue $HardCoded.Location                   -Name "Location"
    $WorkspaceName              = Resolve-Setting -Value $WorkspaceName             -DefaultValue $HardCoded.WorkspaceName              -Name "WorkspaceName"
    $WorkspaceResourceGroupName = Resolve-Setting -Value $WorkspaceResourceGroupName-DefaultValue $HardCoded.WorkspaceResourceGroupName -Name "WorkspaceResourceGroupName"
    $SendFromEmail              = Resolve-Setting -Value $SendFromEmail             -DefaultValue $HardCoded.SendFromEmail              -Name "SendFromEmail"

    if (($SendToEmails.Count -eq 0) -and [string]::IsNullOrWhiteSpace($SendToEmail)) {
        if ($HardCoded.SendToEmails -and $HardCoded.SendToEmails.Count -gt 0) {
            $SendToEmails = $HardCoded.SendToEmails
        }
        else {
            $SendToEmail = Resolve-Setting -Value $SendToEmail -DefaultValue $HardCoded.SendToEmail -Name "SendToEmail"
        }
    }

    if ([string]::IsNullOrWhiteSpace($Office365ConnectionName)) {
        $Office365ConnectionName = $HardCoded.Office365ConnectionName
    }

    if ([string]::IsNullOrWhiteSpace($DetailedActionGroupName)) {
        $DetailedActionGroupName = $HardCoded.DetailedActionGroupName
    }

    if ([string]::IsNullOrWhiteSpace($DetailedWebhookReceiverName)) {
        $DetailedWebhookReceiverName = $HardCoded.DetailedWebhookReceiverName
    }

    if (-not $Tags -or $Tags.Count -eq 0) {
        $Tags = $HardCoded.Tags
    }
}
else {
    $SubscriptionId             = Resolve-Setting -Value $SubscriptionId             -DefaultValue "" -Name "SubscriptionId"
    $ResourceGroupName          = Resolve-Setting -Value $ResourceGroupName          -DefaultValue "" -Name "ResourceGroupName"
    $LogicAppName               = Resolve-Setting -Value $LogicAppName               -DefaultValue "" -Name "LogicAppName"
    $Location                   = Resolve-Setting -Value $Location                   -DefaultValue "" -Name "Location"
    $WorkspaceName              = Resolve-Setting -Value $WorkspaceName              -DefaultValue "" -Name "WorkspaceName"
    $WorkspaceResourceGroupName = Resolve-Setting -Value $WorkspaceResourceGroupName -DefaultValue "" -Name "WorkspaceResourceGroupName"
    $SendFromEmail              = Resolve-Setting -Value $SendFromEmail              -DefaultValue "" -Name "SendFromEmail"

    if (($SendToEmails.Count -eq 0) -and [string]::IsNullOrWhiteSpace($SendToEmail)) {
        throw "Missing required value for 'SendToEmails' or 'SendToEmail'. Provide at least one recipient."
    }
}

# Normalize recipients from both parameters. Supports either array input or ';' / ',' delimited strings.
$ResolvedSendToEmails = @($SendToEmails)
if (-not [string]::IsNullOrWhiteSpace($SendToEmail)) {
    $ResolvedSendToEmails += $SendToEmail
}
$ResolvedSendToEmails = @(
    $ResolvedSendToEmails |
    ForEach-Object { $_ -split '[;,]' } |
    ForEach-Object { $_.Trim() } |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
    Select-Object -Unique
)
if ($ResolvedSendToEmails.Count -eq 0) {
    throw "No valid recipients were resolved from 'SendToEmails' or 'SendToEmail'."
}
# JSON-escape email values to prevent special characters from breaking workflow definition
$SendToEmailValue = (($ResolvedSendToEmails | ForEach-Object { $_ -replace '\\', '\\' -replace '"', '\"' }) -join ';')
$SendFromEmail = $SendFromEmail -replace '\\', '\\' -replace '"', '\"'

if ([string]::IsNullOrWhiteSpace($Office365ConnectionName)) {
    $Office365ConnectionName = "office365"
}
if ([string]::IsNullOrWhiteSpace($DetailedActionGroupName)) {
    $DetailedActionGroupName = "AVD-Alerts-Detailed"
}
if ([string]::IsNullOrWhiteSpace($DetailedWebhookReceiverName)) {
    $DetailedWebhookReceiverName = "AVDAlertsDetailedWebhook"
}
if (-not $Tags) {
    $Tags = @{}
}

if ([string]::IsNullOrWhiteSpace($CsvPath)) {
    $subPrefix = if ($SubscriptionId.Length -ge 8) { $SubscriptionId.Substring(0, 8) } else { $SubscriptionId }
    $CsvPath = ".\\avd-webhook-deploy-report-$subPrefix.csv"
}

$Office365ConnectionStatus = "Unknown"
$RoleAssignmentStatus = "Unknown"

Write-Step "Checking Azure CLI login"
& az account show | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "Azure CLI is not logged in. Run 'az login' first."
}

Write-Step "Setting Azure subscription"
& az account set --subscription $SubscriptionId
if ($LASTEXITCODE -ne 0) {
    throw "Failed to set Azure subscription to $SubscriptionId"
}

Write-Step "Ensuring required CLI extension: scheduled-query"
& az extension show --name scheduled-query -o none 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "Installing 'scheduled-query' extension..." -ForegroundColor Yellow
    & az extension add --name scheduled-query --yes -o none 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw "Required Azure CLI extension 'scheduled-query' could not be installed."
    }
    Write-Host "'scheduled-query' extension installed." -ForegroundColor Green
} else {
    Write-Host "'scheduled-query' extension is available." -ForegroundColor Gray
}

Write-Step "Ensuring Logic App resource group exists"
$rgExists = Invoke-AzCliText -Arguments @("group","exists","--name",$ResourceGroupName)
if ($rgExists -eq "false") {
    $tagArgs = @()
    if ($Tags.Count -gt 0) {
        $flatTags = $Tags.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }
        $tagArgs = @("--tags") + $flatTags
    }

    & az group create --name $ResourceGroupName --location $Location @tagArgs | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to create resource group $ResourceGroupName"
    }
}

Write-Step "Resolving Log Analytics workspace by workspace name"
$workspace = Invoke-AzCliJson -Arguments @(
    "monitor","log-analytics","workspace","show",
    "--resource-group",$WorkspaceResourceGroupName,
    "--workspace-name",$WorkspaceName
)

if (-not $workspace) {
    throw "Workspace '$WorkspaceName' in resource group '$WorkspaceResourceGroupName' was not found."
}

$WorkspaceId = $workspace.customerId
$WorkspaceResourceId = $workspace.id

if ([string]::IsNullOrWhiteSpace($WorkspaceId) -or [string]::IsNullOrWhiteSpace($WorkspaceResourceId)) {
    throw "Could not resolve WorkspaceId or WorkspaceResourceId from workspace '$WorkspaceName'."
}

Write-Host "Workspace Name: $WorkspaceName"
Write-Host "Workspace GUID: $WorkspaceId"
Write-Host "Workspace Resource ID: $WorkspaceResourceId"

$Office365ConnectionResourceId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Web/connections/$Office365ConnectionName"
$Office365ManagedApiId = "/subscriptions/$SubscriptionId/providers/Microsoft.Web/locations/$Location/managedApis/office365"

Write-Step "Ensuring Office 365 API connection exists"
$existingConnectionJson = $null
$existingConnectionJson = & az resource show --ids $Office365ConnectionResourceId -o json 2>&1
$existingConnectionExitCode = $LASTEXITCODE

if ($existingConnectionExitCode -ne 0 -or [string]::IsNullOrWhiteSpace(($existingConnectionJson | Out-String))) {
    Write-Host "Office 365 connection '$Office365ConnectionName' not found - creating..."
    $connBody = @{
        location = $Location
        properties = @{
            displayName = $Office365ConnectionName
            api = @{ id = $Office365ManagedApiId }
        }
    }

    $connTmpFile = Join-Path -Path $env:TEMP -ChildPath ("office365-connection-{0}.json" -f [guid]::NewGuid().ToString('N'))
    try {
        $connBody | ConvertTo-Json -Depth 20 | Set-Content -Path $connTmpFile -Encoding utf8
        $connUri = "${Office365ConnectionResourceId}?api-version=2016-06-01"
        $connCreateOutput = & az rest --method put --uri $connUri --body "@$connTmpFile" -o json 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to create Office 365 connection '$Office365ConnectionName'`n$connCreateOutput"
        }
    }
    finally {
        Remove-Item -Path $connTmpFile -ErrorAction SilentlyContinue
    }

    Write-Host "Office 365 connection '$Office365ConnectionName' created. Authorize it in Azure Portal if prompted."
    $Office365ConnectionStatus = "Created"
}
else {
    Write-Host "Office 365 connection '$Office365ConnectionName' already exists."
    $Office365ConnectionStatus = "Existing"
}

$defaultAlertDefinitionName = "AVD-Category-DefaultFallback"

$commonProjection = @"
| project
    TimeGenerated = column_ifexists('TimeGenerated', datetime(null)),
    UserName = column_ifexists('UserName', ''),
    Source = column_ifexists('Source', ''),
    Code = column_ifexists('Code', ''),
    CodeSymbolic = column_ifexists('CodeSymbolic', ''),
    Message = column_ifexists('Message', ''),
    Operation = column_ifexists('Operation', ''),
    _ResourceId = column_ifexists('_ResourceId', '')
"@

$alertDefinitions = @(
    @{
        Name        = "AVD-Category-AuthenticationIdentity"
        Description = "Consolidated authentication and identity failures in AVD."
        Kql         = @"
WVDErrors
| where TimeGenerated between (datetime({0}) .. datetime({1}))
| where CodeSymbolic in (
    'PasswordMustChange',
    'PasswordExpired',
    'InvalidAuthToken',
    'InvalidCredentials',
    'AccountLockedOut',
    'AccountDisabled',
    'LogonFailed',
    'AuthenticationLogonFailed',
    'NoAuthenticatingAuthority',
    'LocalSecurityAuthorityError'
)
$commonProjection
| order by TimeGenerated desc
| limit 100
"@
    }

    @{
        Name        = "AVD-Category-AuthorizationPolicy"
        Description = "Consolidated authorization and logon rights failures in AVD."
        Kql         = @"
WVDErrors
| where TimeGenerated between (datetime({0}) .. datetime({1}))
| where CodeSymbolic in (
    'ConnectionFailedUserNotAuthorized',
    'LogonTypeNotGranted',
    'NotAuthorizedForLogon'
)
$commonProjection
| order by TimeGenerated desc
| limit 100
"@
    }

    @{
        Name        = "AVD-Category-ConnectionNetworkGateway"
        Description = "Consolidated AVD client, DNS, reverse connect, and gateway transport failures."
        Kql         = @"
WVDErrors
| where TimeGenerated between (datetime({0}) .. datetime({1}))
| where CodeSymbolic in (
    'Client',
    'DnsLookupFailed',
    'GatewayServerNotFound',
    'ReverseConnectDnsLookupFailed',
    'ConnectionFailedClientConnectedTooLateReverseConnectionAlreadyClosed',
    'ConnectionFailedServerDisconnect',
    'ConnectionFailedClientDisconnect',
    'ReverseConnectSChannelFailure'
)
$commonProjection
| order by TimeGenerated desc
| limit 100
"@
    }

    @{
        Name        = "AVD-Category-SessionHostHealthCapacity"
        Description = "Consolidated session host availability and capacity issues."
        Kql         = @"
WVDErrors
| where TimeGenerated between (datetime({0}) .. datetime({1}))
| where CodeSymbolic in (
    'ConnectionFailedNoHealthyRdshAvailable',
    'SessionHostResourceNotAvailable',
    'OutOfMemory'
)
$commonProjection
| order by TimeGenerated desc
| limit 100
"@
    }

    @{
        Name        = "AVD-Category-PersonalDesktopAssignment"
        Description = "Consolidated personal desktop assignment and startup failures."
        Kql         = @"
WVDErrors
| where TimeGenerated between (datetime({0}) .. datetime({1}))
| where CodeSymbolic in (
    'ConnectionFailedPersonalDesktopFailedToBeStarted',
    'ConnectionFailedNoPreAssignedPersonalDesktopForUser'
)
$commonProjection
| order by TimeGenerated desc
| limit 100
"@
    }

    @{
        Name        = "AVD-Category-DeviceGraphicsInput"
        Description = "Consolidated input and graphics subsystem failures."
        Kql         = @"
WVDErrors
| where TimeGenerated between (datetime({0}) .. datetime({1}))
| where CodeSymbolic in (
    'GetInputDeviceHandlesError',
    'GraphicsCapsNotReceived',
    'GraphicsSubsystemFailed',
    'DWMProcessAccessFailure'
)
$commonProjection
| order by TimeGenerated desc
| limit 100
"@
    }

    @{
        Name        = "AVD-Category-FSLogixProfileStorage"
        Description = "Consolidated FSLogix profile and storage attach/detach/access issues."
        Kql         = @"
WVDErrors
| where TimeGenerated between (datetime({0}) .. datetime({1}))
| where
    CodeSymbolic in (
        'ERROR_SHARING_VIOLATION',
        'UnloadWaitingForUserAction',
        'ERROR_ACCESS_DENIED',
        'ERROR_PATH_NOT_FOUND',
        'ERROR_FILE_NOT_FOUND',
        'ERROR_BAD_NETPATH',
        'ERROR_BAD_NET_NAME',
        'ERROR_NETNAME_DELETED',
        'ERROR_DISK_FULL',
        'ERROR_LOCK_VIOLATION'
    )
    or Source contains 'fslogix'
    or Message has_any (
        'frxsvc',
        'frxshell',
        'temporary profile',
        'default profile',
        'profile failed',
        'vhd attach',
        'vhdx attach',
        'container attach',
        'container detach',
        'odfc'
    )
$commonProjection
| order by TimeGenerated desc
| limit 100
"@
    }

    @{
        Name        = "AVD-Category-UnknownUnclassified"
        Description = "Consolidated unknown or unclassified AVD error symbols for triage."
        Kql         = @"
WVDErrors
| where TimeGenerated between (datetime({0}) .. datetime({1}))
| where CodeSymbolic == 'Unknown CodeSymbolic - review Message for details.'
$commonProjection
| order by TimeGenerated desc
| limit 100
"@
    }

    # --- WVD Diagnostic Log alerts (non-WVDErrors tables) ---

    @{
        Name        = "AVD-Category-ConnectionFailureRate"
        Description = "Spike in failed connections per host pool from WVDConnections."
        Kql         = @"
WVDConnections
| where TimeGenerated between (datetime({0}) .. datetime({1}))
| where State == 'Failed'
| extend HostPool = tostring(split(_ResourceId, '/')[-1])
| summarize FailedCount = count() by HostPool, UserName
| where FailedCount > 5
| project HostPool, UserName, FailedCount
| order by FailedCount desc
| limit 100
"@
    }

    @{
        Name        = "AVD-Category-DisconnectionSpike"
        Description = "Abnormal disconnection rate across session hosts indicating infrastructure or network instability."
        Kql         = @"
WVDConnections
| where TimeGenerated between (datetime({0}) .. datetime({1}))
| where State == 'Completed'
| where ConnectionType == 'Disconnected'
| extend HostPool = tostring(split(_ResourceId, '/')[-1])
| summarize DisconnectCount = count() by HostPool, SessionHostName
| where DisconnectCount > 10
| project HostPool, SessionHostName, DisconnectCount
| order by DisconnectCount desc
| limit 100
"@
    }

    @{
        Name        = "AVD-Category-UnhealthyHosts"
        Description = "Session hosts reporting non-Available status from WVDAgentHealthStatus."
        Kql         = @"
WVDAgentHealthStatus
| where TimeGenerated between (datetime({0}) .. datetime({1}))
| summarize arg_max(TimeGenerated, *) by SessionHostName
| where Status != 'Available'
| extend HostPool = tostring(split(_ResourceId, '/')[-1])
| project HostPool, SessionHostName, Status, LastHeartBeat = TimeGenerated
| order by LastHeartBeat asc
| limit 100
"@
    }

    @{
        Name        = "AVD-Category-StaleHeartbeat"
        Description = "Session hosts with stale agent heartbeat indicating communication failure or zombie hosts."
        Kql         = @"
WVDAgentHealthStatus
| where TimeGenerated between (datetime({0}) .. datetime({1}))
| summarize arg_max(TimeGenerated, *) by SessionHostName
| where TimeGenerated < ago(5m)
| extend HostPool = tostring(split(_ResourceId, '/')[-1])
| extend StaleSinceMin = datetime_diff('minute', now(), TimeGenerated)
| project HostPool, SessionHostName, Status, StaleSinceMin
| order by StaleSinceMin desc
| limit 100
"@
    }

    @{
        Name        = "AVD-Category-BandwidthDrop"
        Description = "Per-connection estimated bandwidth drops below threshold from WVDConnectionNetworkData."
        Kql         = @"
WVDConnectionNetworkData
| where TimeGenerated between (datetime({0}) .. datetime({1}))
| summarize P10BW = percentile(EstAvailableBandwidthKBps, 10) by CorrelationId
| where P10BW < 500
| join kind=inner (
    WVDConnections
    | where TimeGenerated between (datetime({0}) .. datetime({1}))
    | project CorrelationId, UserName, SessionHostName, _ResourceId
) on CorrelationId
| extend HostPool = tostring(split(_ResourceId, '/')[-1])
| project HostPool, UserName, SessionHostName, P10BW_KBps = round(P10BW, 0)
| order by P10BW_KBps asc
| limit 100
"@
    }

    @{
        Name        = "AVD-Category-RTTPerUser"
        Description = "Per-user P95 round-trip time exceeds threshold from WVDConnectionNetworkData."
        Kql         = @"
WVDConnectionNetworkData
| where TimeGenerated between (datetime({0}) .. datetime({1}))
| summarize P95RTT = percentile(EstRoundTripTimeInMs, 95) by CorrelationId
| where P95RTT > 200
| join kind=inner (
    WVDConnections
    | where TimeGenerated between (datetime({0}) .. datetime({1}))
    | project CorrelationId, UserName, SessionHostName, _ResourceId
) on CorrelationId
| extend HostPool = tostring(split(_ResourceId, '/')[-1])
| project HostPool, UserName, SessionHostName, P95RTT_ms = round(P95RTT, 0)
| order by P95RTT_ms desc
| limit 100
"@
    }

    @{
        Name        = "AVD-Category-SignInPhaseDelay"
        Description = "Prolonged sign-in phases detected from WVDCheckpoints (profile load, GPO, shell start)."
        Kql         = @"
WVDCheckpoints
| where TimeGenerated between (datetime({0}) .. datetime({1}))
| where Source == 'WVDConnections'
| where Name in ('OnConnected', 'ShellReady', 'LoadProfile', 'ApplyGroupPolicy')
| extend HostPool = tostring(split(_ResourceId, '/')[-1])
| extend DurationSec = datetime_diff('second', TimeGenerated, todatetime(tostring(Parameters.StartTime)))
| where DurationSec > 15
| project HostPool, UserName, Name, DurationSec, SessionHostName = tostring(Parameters.SessionHostName)
| order by DurationSec desc
| limit 100
"@
    }

    @{
        Name        = "AVD-Category-FrameQualityDegradation"
        Description = "[Preview] End-to-end frame delay or dropped frames exceeding threshold from ConnectionGraphicsData."
        Kql         = @"
ConnectionGraphicsData
| where TimeGenerated between (datetime({0}) .. datetime({1}))
| summarize AvgFrameDelay = avg(EstEndToEndDelayInMs), DropPct = avg(FramesSkippedPercentage) by CorrelationId
| where AvgFrameDelay > 300 or DropPct > 15
| join kind=inner (
    WVDConnections
    | where TimeGenerated between (datetime({0}) .. datetime({1}))
    | project CorrelationId, UserName, SessionHostName, _ResourceId
) on CorrelationId
| extend HostPool = tostring(split(_ResourceId, '/')[-1])
| project HostPool, UserName, SessionHostName, AvgFrameDelay_ms = round(AvgFrameDelay, 0), DroppedFramesPct = round(DropPct, 1)
| order by AvgFrameDelay_ms desc
| limit 100
"@
    }

    # --- Fallback ---

    @{
        Name        = "AVD-Category-DefaultFallback"
        Description = "Fallback WVDErrors query when alert rule name is not mapped."
        Kql         = @"
WVDErrors
| where TimeGenerated between (datetime({0}) .. datetime({1}))
$commonProjection
| order by TimeGenerated desc
| limit 100
"@
    }
)

$alertDefinitionMap = Get-AlertDefinitionMap -Definitions $alertDefinitions
$alertDefinitionMapJson = $alertDefinitionMap | ConvertTo-Json -Depth 20 -Compress

$kqlQueryExpr = @"
@{replace(
    replace(
        coalesce(
            variables('AlertDefinitionMap')?[coalesce(triggerBody()?['data']?['essentials']?['alertRule'], '$defaultAlertDefinitionName')]?['Kql'],
            variables('AlertDefinitionMap')?['$defaultAlertDefinitionName']?['Kql']
        ),
        '{0}',
        coalesce(
            triggerBody()?['data']?['alertContext']?['condition']?['windowStartTime'],
            triggerBody()?['data']?['alertContext']?['windowStartTime'],
            triggerBody()?['data']?['essentials']?['firedDateTime'],
            addMinutes(utcNow(), -15)
        )
    ),
    '{1}',
    coalesce(
        triggerBody()?['data']?['alertContext']?['condition']?['windowEndTime'],
        triggerBody()?['data']?['alertContext']?['windowEndTime'],
        triggerBody()?['data']?['essentials']?['firedDateTime'],
        utcNow()
    )
)}
"@

$alertEmailHtmlExpr = @'
@{concat(
  '<html><body style="font-family:Segoe UI,Arial,sans-serif;font-size:13px;color:#242424;">',
  '<h2 style="margin-bottom:8px;">Azure Virtual Desktop Alert</h2>',

  '<table border="0" cellpadding="6" cellspacing="0" style="border-collapse:collapse;">',
    '<tr><td><b>Rule</b></td><td>', coalesce(triggerBody()?['data']?['essentials']?['alertRule'], 'N/A'), '</td></tr>',
    '<tr><td><b>Description</b></td><td>', coalesce(variables('AlertDescriptionText'), 'N/A'), '</td></tr>',
    '<tr><td><b>Severity</b></td><td>', string(coalesce(triggerBody()?['data']?['essentials']?['severity'], 'N/A')), '</td></tr>',
    '<tr><td><b>Condition</b></td><td>', coalesce(triggerBody()?['data']?['essentials']?['monitorCondition'], 'N/A'), '</td></tr>',
    '<tr><td><b>Fired At</b></td><td>', coalesce(triggerBody()?['data']?['essentials']?['firedDateTime'], 'N/A'), '</td></tr>',
    '<tr><td><b>Window Start</b></td><td>', coalesce(triggerBody()?['data']?['alertContext']?['condition']?['windowStartTime'], triggerBody()?['data']?['alertContext']?['windowStartTime'], 'N/A'), '</td></tr>',
    '<tr><td><b>Window End</b></td><td>', coalesce(triggerBody()?['data']?['alertContext']?['condition']?['windowEndTime'], triggerBody()?['data']?['alertContext']?['windowEndTime'], 'N/A'), '</td></tr>',
  '</table>',

  '<h3 style="margin:14px 0 6px 0;">Log Analytics Workspace</h3>',
  '<table border="0" cellpadding="6" cellspacing="0" style="border-collapse:collapse;">',
    '<tr><td><b>Name</b></td><td>$WorkspaceName</td></tr>',
    '<tr><td><b>Workspace GUID</b></td><td>$WorkspaceId</td></tr>',
  '</table>',

  '<h3 style="margin:14px 0 6px 0;">WVDErrors Results</h3>',
  variables('ResultsTableHtml'),

  '</body></html>'
)}
'@

$alertEmailHtmlExpr = $alertEmailHtmlExpr.Replace('$WorkspaceName', $WorkspaceName)
$alertEmailHtmlExpr = $alertEmailHtmlExpr.Replace('$WorkspaceId', $WorkspaceId)

$sendEmailAction = @{
    type = "ApiConnection"
    runAfter = @{
        Append_Table_End = @("Succeeded")
    }
    inputs = @{
        method = "post"
        path   = "/v2/Mail"
        host   = @{
            connection = @{
                name = "@parameters('`$connections')['office365']['connectionId']"
            }
        }
        body   = @{
            To         = $SendToEmailValue
            Subject    = "@{concat('AVD Alert - ', coalesce(triggerBody()?['data']?['essentials']?['alertRule'], 'WVDErrors'))}"
            Body       = $alertEmailHtmlExpr
            From       = $SendFromEmail
            Importance = "High"
        }
    }
}

$workflowDefinition = @{
    '$schema'      = 'https://schema.management.azure.com/schemas/2016-06-01/Microsoft.Logic.json'
    contentVersion = '1.0.0.0'
    parameters     = @{
        '$connections' = @{
            type         = 'Object'
            defaultValue = @{}
        }
    }

    triggers = @{
        manual = @{
            type   = 'Request'
            kind   = 'Http'
            inputs = @{
                method = 'POST'
            }
        }
    }

    actions = @{
        Initialize_ResultsTableHtml = @{
            type   = 'InitializeVariable'
            inputs = @{
                variables = @(
                    @{
                        name  = 'ResultsTableHtml'
                        type  = 'string'
                        value = '<p>No WVDErrors rows were returned for this alert window.</p>'
                    }
                )
            }
            runAfter = @{}
        }

        Initialize_AlertDefinitionMap = @{
            type   = 'InitializeVariable'
            inputs = @{
                variables = @(
                    @{
                        name  = 'AlertDefinitionMap'
                        type  = 'object'
                        value = ($alertDefinitionMapJson | ConvertFrom-Json)
                    }
                )
            }
            runAfter = @{
                Initialize_ResultsTableHtml = @('Succeeded')
            }
        }

        Initialize_AlertDescription = @{
            type   = 'InitializeVariable'
            inputs = @{
                variables = @(
                    @{
                        name  = 'AlertDescriptionText'
                        type  = 'string'
                        value = ''
                    }
                )
            }
            runAfter = @{
                Initialize_AlertDefinitionMap = @('Succeeded')
            }
        }

        Set_AlertDescriptionText = @{
            type   = 'SetVariable'
            inputs = @{
                name  = 'AlertDescriptionText'
                value = "@{coalesce(
                    variables('AlertDefinitionMap')?[coalesce(triggerBody()?['data']?['essentials']?['alertRule'], '$defaultAlertDefinitionName')]?['Description'],
                    variables('AlertDefinitionMap')?['$defaultAlertDefinitionName']?['Description']
                )}"
            }
            runAfter = @{
                Initialize_AlertDescription = @('Succeeded')
            }
        }

        Query_WVDErrors = @{
            type     = 'Http'
            runAfter = @{
                Set_AlertDescriptionText = @('Succeeded')
            }
            inputs   = @{
                method         = 'POST'
                uri            = "https://api.loganalytics.io/v1/workspaces/$WorkspaceId/query"
                headers        = @{
                    'Content-Type' = 'application/json'
                }
                body           = @{
                    query = $kqlQueryExpr
                }
                authentication = @{
                    type     = 'ManagedServiceIdentity'
                    audience = 'https://api.loganalytics.io/'
                }
            }
        }

        Start_Table = @{
            type     = 'SetVariable'
            runAfter = @{
                Query_WVDErrors = @('Succeeded')
            }
            inputs   = @{
                name  = 'ResultsTableHtml'
                value = "<table border='1' cellpadding='6' cellspacing='0' style='border-collapse:collapse;font-size:12px;'><thead><tr style='background:#f3f2f1;'>"
            }
        }

        For_Each_Column = @{
            type     = 'Foreach'
            foreach  = "@body('Query_WVDErrors')?['tables']?[0]?['columns']"
            operationOptions = 'Sequential'
            runAfter = @{
                Start_Table = @('Succeeded')
            }
            actions  = @{
                Append_Column_Header = @{
                    type   = 'AppendToStringVariable'
                    inputs = @{
                        name  = 'ResultsTableHtml'
                        value = "@{concat('<th>', item()?['name'], '</th>')}"
                    }
                    runAfter = @{}
                }
            }
        }

        Append_Header_Close = @{
            type     = 'AppendToStringVariable'
            runAfter = @{
                For_Each_Column = @('Succeeded')
            }
            inputs   = @{
                name  = 'ResultsTableHtml'
                value = "</tr></thead><tbody>"
            }
        }

        For_Each_Row = @{
            type     = 'Foreach'
            foreach  = "@body('Query_WVDErrors')?['tables']?[0]?['rows']"
            operationOptions = 'Sequential'
            runAfter = @{
                Append_Header_Close = @('Succeeded')
            }
            actions  = @{
                Start_Row = @{
                    type   = 'AppendToStringVariable'
                    inputs = @{
                        name  = 'ResultsTableHtml'
                        value = "<tr>"
                    }
                    runAfter = @{}
                }

                For_Each_Cell = @{
                    type     = 'Foreach'
                    foreach  = "@item()"
                    operationOptions = 'Sequential'
                    runAfter = @{
                        Start_Row = @('Succeeded')
                    }
                    actions  = @{
                        Append_Cell = @{
                            type   = 'AppendToStringVariable'
                            inputs = @{
                                name  = 'ResultsTableHtml'
                                value = "@{concat('<td>', if(equals(item(), null), '', string(item())), '</td>')}"
                            }
                            runAfter = @{}
                        }
                    }
                }

                End_Row = @{
                    type     = 'AppendToStringVariable'
                    runAfter = @{
                        For_Each_Cell = @('Succeeded')
                    }
                    inputs   = @{
                        name  = 'ResultsTableHtml'
                        value = "</tr>"
                    }
                }
            }
        }

        Append_Table_End = @{
            type     = 'AppendToStringVariable'
            runAfter = @{
                For_Each_Row = @('Succeeded')
            }
            inputs   = @{
                name  = 'ResultsTableHtml'
                value = "</tbody></table>"
            }
        }

        Send_Detailed_Email = $sendEmailAction

        Response_Success = @{
            type     = 'Response'
            runAfter = @{
                Send_Detailed_Email = @('Succeeded')
            }
            inputs   = @{
                statusCode = 202
                body       = @{
                    status = 'accepted'
                }
            }
        }

        Response_Failure = @{
            type     = 'Response'
            runAfter = @{
                Send_Detailed_Email = @('Failed', 'TimedOut')
            }
            inputs   = @{
                statusCode = 500
                body       = @{
                    status = 'email_send_failed'
                }
            }
        }
    }

    outputs = @{}
}

$workflowProperties = @{
    definition = $workflowDefinition
    parameters = @{
        '$connections' = @{
            value = @{
                office365 = @{
                    connectionId   = $Office365ConnectionResourceId
                    connectionName = $Office365ConnectionName
                    id             = $Office365ManagedApiId
                }
            }
        }
    }
}

$body = @{
    identity   = @{
        type = 'SystemAssigned'
    }
    location   = $Location
    tags       = $Tags
    properties = $workflowProperties
}

Write-Step "Deploying Logic App"
$workflowResourceId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Logic/workflows/$LogicAppName"
$workflowTempFile = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("logicapp-{0}-{1}.json" -f $LogicAppName, [guid]::NewGuid().ToString('N'))
try {
    $body | ConvertTo-Json -Depth 100 | Set-Content -Path $workflowTempFile -Encoding utf8

    $deployResult = & az resource create `
        --id $workflowResourceId `
        --api-version 2019-05-01 `
        --is-full-object `
        --properties "@$workflowTempFile" `
        -o json 2>&1

    if ($LASTEXITCODE -ne 0) {
        throw "Failed to deploy Logic App $LogicAppName`n$deployResult"
    }
}
finally {
    Remove-Item -Path $workflowTempFile -ErrorAction SilentlyContinue
}

Write-Step "Retrieving Logic App managed identity"
$logicApp = Invoke-AzCliJson -Arguments @(
    "resource","show",
    "--resource-group",$ResourceGroupName,
    "--name",$LogicAppName,
    "--resource-type","Microsoft.Logic/workflows"
)

if (-not $logicApp.identity -or -not $logicApp.identity.principalId) {
    throw "Managed identity was not found on Logic App $LogicAppName"
}

$principalId = $logicApp.identity.principalId
Write-Host "Logic App Managed Identity PrincipalId: $principalId"

Write-Step "Assigning Log Analytics Reader to Logic App managed identity"
& az role assignment create `
    --assignee-object-id $principalId `
    --assignee-principal-type ServicePrincipal `
    --role "Log Analytics Reader" `
    --scope $WorkspaceResourceId 2>&1

if ($LASTEXITCODE -ne 0) {
    Write-Warning "Role assignment may already exist or could not be created automatically. Verify that the Logic App managed identity has 'Log Analytics Reader' on: $WorkspaceResourceId"
    $RoleAssignmentStatus = "NeedsVerification"
}
else {
    Write-Host "Role assignment created successfully."
    $RoleAssignmentStatus = "CreatedOrExists"
}

# Verify role assignment was actually applied
$verifyRoleJson = & az role assignment list `
    --assignee-object-id $principalId `
    --scope $WorkspaceResourceId `
    --role "Log Analytics Reader" `
    --query "[0].id" -o tsv 2>&1
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($verifyRoleJson)) {
    throw "Role assignment verification failed. The Logic App managed identity does not have 'Log Analytics Reader' on: $WorkspaceResourceId. Assign this role manually before the Logic App can query Log Analytics."
}
if ($RoleAssignmentStatus -eq "NeedsVerification") {
    Write-Host "Role assignment verified (already existed)."
    $RoleAssignmentStatus = "AlreadyExists"
}

Write-Step "Retrieving webhook URL"
$callbackValue = Invoke-AzCliText -Arguments @(
    "rest",
    "--method", "post",
    "--uri", "$workflowResourceId/triggers/manual/listCallbackUrl?api-version=2019-05-01",
    "--body", "{}",
    "--query", "value",
    "-o", "tsv"
)

if ([string]::IsNullOrWhiteSpace($callbackValue)) {
    throw "Failed to retrieve Logic App callback URL."
}

Write-Step "Ensuring detailed webhook action group"
Set-DetailedActionGroupWebhook `
    -SubscriptionId $SubscriptionId `
    -ResourceGroupName $ResourceGroupName `
    -ActionGroupName $DetailedActionGroupName `
    -ReceiverName $DetailedWebhookReceiverName `
    -ServiceUri $callbackValue
Write-Host "Detailed webhook action group '$DetailedActionGroupName' is configured."

Write-Step "Ensuring AVD-Category alerts exist (bootstrap if needed)"
Ensure-AVDCategoryAlertsExist `
    -SubscriptionId $SubscriptionId `
    -ResourceGroupName $ResourceGroupName `
    -WorkspaceResourceGroupName $WorkspaceResourceGroupName `
    -WorkspaceName $WorkspaceName `
    -Location $Location `
    -DetailedActionGroupName $DetailedActionGroupName `
    -DetailedWebhookReceiverName $DetailedWebhookReceiverName `
    -DetailedResultsWebhookUrl $callbackValue

Write-Step "Switching AVD-Category alerts to detailed-only action group"
Set-AVDCategoryAlertsToDetailedOnly `
    -SubscriptionId $SubscriptionId `
    -ResourceGroupName $ResourceGroupName `
    -DetailedActionGroupName $DetailedActionGroupName

Write-Host ""
Write-Host "Deployment complete." -ForegroundColor Green
Write-Host ""
Write-Host "Webhook URL:"
Write-Host $callbackValue
Write-Host ""
Write-Host "Notes:"
Write-Host "1. The Office 365 API connection '$Office365ConnectionName' is auto-created if missing, but it must be authenticated in Azure Portal."
Write-Host "2. The Log Analytics workspace was resolved by name: $WorkspaceName"
Write-Host "3. Your Azure Monitor alert rule names should match one of the following definitions to use category-specific KQL:"
$alertDefinitions | ForEach-Object { Write-Host "   - $($_.Name)" }
Write-Host "4. If no rule name matches, the script uses the fallback WVDErrors query."
Write-Host "5. Detailed webhook action group: $DetailedActionGroupName ($DetailedWebhookReceiverName)"
Write-Host "6. If AVD-Category alerts were missing, they were auto-created via AVD-Category-Alerts.ps1."
Write-Host "7. Existing AVD-Category alerts were switched to detailed-only action group routing."

$ScriptEndTime = Get-Date
$ExecutionSeconds = [Math]::Round(($ScriptEndTime - $ScriptStartTime).TotalSeconds, 1)
$IdentityChange = if ([string]::IsNullOrWhiteSpace($principalId)) {
    "Unknown"
}
else {
    "LogicAppSystemAssignedManagedIdentity"
}

$reportRows = @(
    [pscustomobject]@{
        TimestampUtc = (Get-Date).ToUniversalTime().ToString("o")
        SubscriptionId = $SubscriptionId
        ResourceGroupName = $ResourceGroupName
        LogicAppName = $LogicAppName
        Location = $Location
        WorkspaceName = $WorkspaceName
        WorkspaceResourceGroupName = $WorkspaceResourceGroupName
        DetailedActionGroupName = $DetailedActionGroupName
        DetailedWebhookReceiverName = $DetailedWebhookReceiverName
        SendFromEmail = $SendFromEmail
        SendToRecipients = $SendToEmailValue
        WebhookUrl = $callbackValue
        LogicAppPrincipalId = $principalId
        IdentityChange = $IdentityChange
        Office365ConnectionStatus = $Office365ConnectionStatus
        RoleAssignmentStatus = $RoleAssignmentStatus
        ExecutionSeconds = $ExecutionSeconds
        Result = "Success"
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