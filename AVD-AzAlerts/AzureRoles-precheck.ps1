param(
    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [string]$WorkspaceName,

    [Parameter(Mandatory = $true)]
    [string]$WorkspaceResourceGroupName,

    [string]$Assignee,
    [string]$AssigneeObjectId,

    [switch]$RequireResourceGroupCreate,
    [switch]$RequireRoleAssignmentWrite
)

$ErrorActionPreference = 'Stop'

function Write-Section {
    param([string]$Message)
    Write-Host "`n=== $Message ===" -ForegroundColor Cyan
}

function Invoke-AzCliJson {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)
    $result = & az @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI command failed: az $($Arguments -join ' ')`n$result"
    }
    $text = ($result | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }
    return ($text | ConvertFrom-Json)
}

function Invoke-AzCliText {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)
    $result = & az @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI command failed: az $($Arguments -join ' ')`n$result"
    }
    return ($result | Out-String).Trim()
}

function Convert-WildcardToRegex {
    param([string]$Pattern)
    if ([string]::IsNullOrWhiteSpace($Pattern)) {
        return '^$'
    }
    return '^' + [Regex]::Escape($Pattern).Replace('\*', '.*') + '$'
}

function Test-PatternMatch {
    param(
        [Parameter(Mandatory = $true)][string]$Pattern,
        [Parameter(Mandatory = $true)][string]$Value
    )
    $regex = Convert-WildcardToRegex -Pattern $Pattern
    return ($Value -match $regex)
}

function Resolve-Principal {
    param(
        [Parameter(Mandatory = $true)][psobject]$AccountInfo,
        [string]$Assignee,
        [string]$AssigneeObjectId
    )

    if (-not [string]::IsNullOrWhiteSpace($Assignee) -or -not [string]::IsNullOrWhiteSpace($AssigneeObjectId)) {
        $principalName = $Assignee
        $principalType = 'unknown'
        $principalObjectId = $AssigneeObjectId

        if ([string]::IsNullOrWhiteSpace($principalObjectId) -and -not [string]::IsNullOrWhiteSpace($Assignee)) {
            try {
                $principalObjectId = Invoke-AzCliText -Arguments @('ad', 'user', 'show', '--id', $Assignee, '--query', 'id', '-o', 'tsv')
                if (-not [string]::IsNullOrWhiteSpace($principalObjectId)) {
                    $principalType = 'user'
                }
            }
            catch {
                # Try service principal resolution next.
            }

            if ([string]::IsNullOrWhiteSpace($principalObjectId)) {
                try {
                    $principalObjectId = Invoke-AzCliText -Arguments @('ad', 'sp', 'show', '--id', $Assignee, '--query', 'id', '-o', 'tsv')
                    if (-not [string]::IsNullOrWhiteSpace($principalObjectId)) {
                        $principalType = 'servicePrincipal'
                    }
                }
                catch {
                    # Fallback to assignee string if object lookup is unavailable.
                }
            }
        }

        if ([string]::IsNullOrWhiteSpace($principalName) -and -not [string]::IsNullOrWhiteSpace($principalObjectId)) {
            $principalName = $principalObjectId
        }

        return [pscustomobject]@{
            PrincipalType = $principalType
            PrincipalName = $principalName
            PrincipalObjectId = $principalObjectId
        }
    }

    $principalType = $AccountInfo.user.type
    $principalName = $AccountInfo.user.name
    $principalObjectId = $null

    if ($principalType -eq 'user') {
        try {
            $principalObjectId = Invoke-AzCliText -Arguments @('ad', 'signed-in-user', 'show', '--query', 'id', '-o', 'tsv')
        }
        catch {
            # Fallback to assignee by UPN if Graph lookup fails.
        }
    }
    elseif ($principalType -eq 'servicePrincipal') {
        try {
            $principalObjectId = Invoke-AzCliText -Arguments @('ad', 'sp', 'show', '--id', $principalName, '--query', 'id', '-o', 'tsv')
        }
        catch {
            # Fallback to assignee by appId/name if Graph lookup fails.
        }
    }

    return [pscustomobject]@{
        PrincipalType = $principalType
        PrincipalName = $principalName
        PrincipalObjectId = $principalObjectId
    }
}

function Get-RoleAssignmentsForScope {
    param(
        [Parameter(Mandatory = $true)][string]$Scope,
        [Parameter(Mandatory = $true)][psobject]$Principal
    )

    $args = @('role', 'assignment', 'list', '--scope', $Scope, '--include-inherited', '-o', 'json')
    if (-not [string]::IsNullOrWhiteSpace($Principal.PrincipalObjectId)) {
        $args += @('--assignee-object-id', $Principal.PrincipalObjectId)
    }
    else {
        $args += @('--assignee', $Principal.PrincipalName)
    }

    $result = & az @args 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Could not list role assignments at scope '$Scope'. Ensure you can read RBAC assignments on this scope.`n$result"
    }

    $text = ($result | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) {
        return @()
    }

    $parsed = $text | ConvertFrom-Json
    if ($null -eq $parsed) {
        return @()
    }

    return @($parsed)
}

function Get-RolePermissionSets {
    param(
        [Parameter(Mandatory = $true)][array]$RoleAssignments,
        [Parameter(Mandatory = $true)][hashtable]$RoleDefinitionCache
    )

    $permissionSets = @()

    foreach ($assignment in $RoleAssignments) {
        $roleName = $assignment.roleDefinitionName
        if ([string]::IsNullOrWhiteSpace($roleName)) {
            continue
        }

        if (-not $RoleDefinitionCache.ContainsKey($roleName)) {
            $def = Invoke-AzCliJson -Arguments @('role', 'definition', 'list', '--name', $roleName)
            if ($def -and @($def).Count -gt 0) {
                $RoleDefinitionCache[$roleName] = $def[0]
            }
            else {
                $RoleDefinitionCache[$roleName] = $null
            }
        }

        $roleDef = $RoleDefinitionCache[$roleName]
        if ($null -eq $roleDef -or $null -eq $roleDef.permissions) {
            continue
        }

        foreach ($perm in $roleDef.permissions) {
            $permissionSets += [pscustomobject]@{
                RoleName = $roleName
                Actions = @($perm.actions)
                NotActions = @($perm.notActions)
            }
        }
    }

    return $permissionSets
}

function Test-ActionGranted {
    param(
        [Parameter(Mandatory = $true)][string]$Action,
        [Parameter(Mandatory = $true)][array]$PermissionSets
    )

    foreach ($permSet in $PermissionSets) {
        $isAllowed = $false
        foreach ($allow in $permSet.Actions) {
            if (Test-PatternMatch -Pattern $allow -Value $Action) {
                $isAllowed = $true
                break
            }
        }

        if (-not $isAllowed) {
            continue
        }

        $isDenied = $false
        foreach ($deny in $permSet.NotActions) {
            if (Test-PatternMatch -Pattern $deny -Value $Action) {
                $isDenied = $true
                break
            }
        }

        if (-not $isDenied) {
            return $true
        }
    }

    return $false
}

Write-Section 'Pre-flight'
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw "Azure CLI not found. Install from https://learn.microsoft.com/cli/azure/install-azure-cli"
}

$accountInfo = Invoke-AzCliJson -Arguments @('account', 'show')
if ($null -eq $accountInfo) {
    throw "Not logged in. Run 'az login' first."
}

Invoke-AzCliText -Arguments @('account', 'set', '--subscription', $SubscriptionId, '-o', 'none') | Out-Null
$accountInfo = Invoke-AzCliJson -Arguments @('account', 'show')

$principal = Resolve-Principal -AccountInfo $accountInfo -Assignee $Assignee -AssigneeObjectId $AssigneeObjectId
Write-Host "Subscription: $($accountInfo.name) ($($accountInfo.id))"
Write-Host "Principal: $($principal.PrincipalName) [$($principal.PrincipalType)]"

Write-Section 'Resolve Scopes'
$rgScope = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName"
$workspace = Invoke-AzCliJson -Arguments @(
    'monitor', 'log-analytics', 'workspace', 'show',
    '--resource-group', $WorkspaceResourceGroupName,
    '--workspace-name', $WorkspaceName
)
$workspaceScope = $workspace.id

Write-Host "Resource Group scope: $rgScope"
Write-Host "Workspace scope: $workspaceScope"

Write-Section 'Collect Role Assignments'
$roleDefinitionCache = @{}
$rgAssignments = Get-RoleAssignmentsForScope -Scope $rgScope -Principal $principal
$workspaceAssignments = Get-RoleAssignmentsForScope -Scope $workspaceScope -Principal $principal
$subscriptionScope = "/subscriptions/$SubscriptionId"
$subscriptionAssignments = Get-RoleAssignmentsForScope -Scope $subscriptionScope -Principal $principal

$rgPermSets = Get-RolePermissionSets -RoleAssignments $rgAssignments -RoleDefinitionCache $roleDefinitionCache
$workspacePermSets = Get-RolePermissionSets -RoleAssignments $workspaceAssignments -RoleDefinitionCache $roleDefinitionCache
$subscriptionPermSets = Get-RolePermissionSets -RoleAssignments $subscriptionAssignments -RoleDefinitionCache $roleDefinitionCache

Write-Host "RG assignments found: $(@($rgAssignments).Count)"
Write-Host "Workspace assignments found: $(@($workspaceAssignments).Count)"
Write-Host "Subscription assignments found: $(@($subscriptionAssignments).Count)"

Write-Section 'Permission Checks'
$checks = @(
    [pscustomobject]@{ ScopeName = 'ResourceGroup'; Scope = $rgScope; Action = 'Microsoft.Insights/actionGroups/read'; Why = 'Read action groups' },
    [pscustomobject]@{ ScopeName = 'ResourceGroup'; Scope = $rgScope; Action = 'Microsoft.Insights/actionGroups/write'; Why = 'Create/update action groups' },
    [pscustomobject]@{ ScopeName = 'ResourceGroup'; Scope = $rgScope; Action = 'Microsoft.Insights/scheduledQueryRules/read'; Why = 'Read scheduled query alerts' },
    [pscustomobject]@{ ScopeName = 'ResourceGroup'; Scope = $rgScope; Action = 'Microsoft.Insights/scheduledQueryRules/write'; Why = 'Create/update scheduled query alerts' },
    [pscustomobject]@{ ScopeName = 'ResourceGroup'; Scope = $rgScope; Action = 'Microsoft.Logic/workflows/read'; Why = 'Read Logic App workflow' },
    [pscustomobject]@{ ScopeName = 'ResourceGroup'; Scope = $rgScope; Action = 'Microsoft.Logic/workflows/write'; Why = 'Deploy/update Logic App workflow' },
    [pscustomobject]@{ ScopeName = 'ResourceGroup'; Scope = $rgScope; Action = 'Microsoft.Web/connections/read'; Why = 'Read API connections' },
    [pscustomobject]@{ ScopeName = 'ResourceGroup'; Scope = $rgScope; Action = 'Microsoft.Web/connections/write'; Why = 'Create/update Office 365 connection' },
    [pscustomobject]@{ ScopeName = 'Workspace'; Scope = $workspaceScope; Action = 'Microsoft.OperationalInsights/workspaces/read'; Why = 'Resolve workspace details' }
)

if ($RequireResourceGroupCreate) {
    $checks += [pscustomobject]@{ ScopeName = 'Subscription'; Scope = $subscriptionScope; Action = 'Microsoft.Resources/subscriptions/resourceGroups/write'; Why = 'Create resource group if missing' }
}

if ($RequireRoleAssignmentWrite) {
    $checks += [pscustomobject]@{ ScopeName = 'Workspace'; Scope = $workspaceScope; Action = 'Microsoft.Authorization/roleAssignments/write'; Why = 'Assign Log Analytics Reader to Logic App MI' }
}

$results = @()
foreach ($check in $checks) {
    $permSets = switch ($check.ScopeName) {
        'ResourceGroup' { $rgPermSets }
        'Workspace' { $workspacePermSets + $rgPermSets + $subscriptionPermSets }
        'Subscription' { $subscriptionPermSets }
        default { @() }
    }

    $granted = Test-ActionGranted -Action $check.Action -PermissionSets $permSets
    $results += [pscustomobject]@{
        Scope = $check.ScopeName
        Action = $check.Action
        Purpose = $check.Why
        Granted = $granted
    }
}

$results | Format-Table -AutoSize

$missing = @($results | Where-Object { -not $_.Granted })
Write-Host ""
if ($missing.Count -eq 0) {
    Write-Host "PASS: principal appears to have all required permissions for AVD deployment scripts." -ForegroundColor Green
    exit 0
}

Write-Host "FAIL: missing required permissions:" -ForegroundColor Red
$missing | ForEach-Object {
    Write-Host "- [$($_.Scope)] $($_.Action) ($($_.Purpose))" -ForegroundColor Red
}

Write-Host ""
Write-Host "Suggested minimum built-in roles (common baseline):" -ForegroundColor Yellow
Write-Host "- Resource Group '$ResourceGroupName': Monitoring Contributor" -ForegroundColor Yellow
Write-Host "- Workspace '$WorkspaceName': Log Analytics Reader" -ForegroundColor Yellow
if ($RequireRoleAssignmentWrite) {
    Write-Host "- Workspace scope: User Access Administrator (or Owner) for roleAssignments/write" -ForegroundColor Yellow
}
if ($RequireResourceGroupCreate) {
    Write-Host "- Subscription scope: Contributor (or Owner) for resourceGroups/write" -ForegroundColor Yellow
}

exit 2
