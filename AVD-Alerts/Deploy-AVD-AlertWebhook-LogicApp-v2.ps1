param(
    [string]$SubscriptionId = "",
    [string]$ResourceGroupName = "",
    [string]$LogicAppName = "",
    [string]$Location = "",
    [string]$WorkspaceName = "",
    [string]$WorkspaceResourceGroupName = "",
    [string]$SendToEmail = "",
    [string]$SendFromEmail = "",
    [string]$Office365ConnectionName = "office365",
    [string]$DetailedActionGroupName = "AVD-Alerts-Detailed",
    [string]$DetailedWebhookReceiverName = "AVDAlertsDetailedWebhook",
    [hashtable]$Tags = @{},
    [switch]$UseHardCodedDefaults
)

$ErrorActionPreference = "Stop"

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

function Ensure-DetailedActionGroupWebhook {
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
    $SendToEmail                = Resolve-Setting -Value $SendToEmail               -DefaultValue $HardCoded.SendToEmail                -Name "SendToEmail"
    $SendFromEmail              = Resolve-Setting -Value $SendFromEmail             -DefaultValue $HardCoded.SendFromEmail              -Name "SendFromEmail"

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
    $SendToEmail                = Resolve-Setting -Value $SendToEmail                -DefaultValue "" -Name "SendToEmail"
    $SendFromEmail              = Resolve-Setting -Value $SendFromEmail              -DefaultValue "" -Name "SendFromEmail"
}

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
$existingConnectionExitCode = 0
$probeOutFile = Join-Path -Path $env:TEMP -ChildPath ("o365-probe-out-{0}.txt" -f [guid]::NewGuid().ToString('N'))
$probeErrFile = Join-Path -Path $env:TEMP -ChildPath ("o365-probe-err-{0}.txt" -f [guid]::NewGuid().ToString('N'))
try {
    $probeProcess = Start-Process -FilePath "az" `
        -ArgumentList @("resource", "show", "--ids", $Office365ConnectionResourceId, "-o", "json") `
        -NoNewWindow -PassThru -Wait `
        -RedirectStandardOutput $probeOutFile `
        -RedirectStandardError $probeErrFile

    $existingConnectionExitCode = $probeProcess.ExitCode
    if (Test-Path $probeOutFile) {
        $existingConnectionJson = Get-Content -Path $probeOutFile -Raw
    }
}
finally {
    Remove-Item -Path $probeOutFile -ErrorAction SilentlyContinue
    Remove-Item -Path $probeErrFile -ErrorAction SilentlyContinue
}

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
}
else {
    Write-Host "Office 365 connection '$Office365ConnectionName' already exists."
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
            To         = $SendToEmail
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

        Initialize_KqlQueryText = @{
            type   = 'InitializeVariable'
            inputs = @{
                variables = @(
                    @{
                        name  = 'KqlQueryText'
                        type  = 'string'
                        value = ''
                    }
                )
            }
            runAfter = @{
                Initialize_AlertDefinitionMap = @('Succeeded')
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
                Initialize_KqlQueryText = @('Succeeded')
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

        Set_KqlQueryText = @{
            type   = 'SetVariable'
            inputs = @{
                name  = 'KqlQueryText'
                value = $kqlQueryExpr
            }
            runAfter = @{
                Set_AlertDescriptionText = @('Succeeded')
            }
        }

        Query_WVDErrors = @{
            type     = 'Http'
            runAfter = @{
                Set_KqlQueryText = @('Succeeded')
            }
            inputs   = @{
                method         = 'POST'
                uri            = "https://api.loganalytics.io/v1/workspaces/$WorkspaceId/query"
                headers        = @{
                    'Content-Type' = 'application/json'
                }
                body           = @{
                    query = "@{variables('KqlQueryText')}"
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
$roleAssignOutput = & az role assignment create `
    --assignee-object-id $principalId `
    --assignee-principal-type ServicePrincipal `
    --role "Log Analytics Reader" `
    --scope $WorkspaceResourceId 2>&1

if ($LASTEXITCODE -ne 0) {
    Write-Warning "Role assignment may already exist or could not be created automatically. Verify that the Logic App managed identity has 'Log Analytics Reader' on: $WorkspaceResourceId"
}
else {
    Write-Host "Role assignment created successfully."
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
Ensure-DetailedActionGroupWebhook `
    -SubscriptionId $SubscriptionId `
    -ResourceGroupName $ResourceGroupName `
    -ActionGroupName $DetailedActionGroupName `
    -ReceiverName $DetailedWebhookReceiverName `
    -ServiceUri $callbackValue
Write-Host "Detailed webhook action group '$DetailedActionGroupName' is configured."

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