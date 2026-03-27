<#
.SYNOPSIS
  Creates or updates an AVD session host Data Collection Rule (DCR) and optionally
  assigns built-in Azure Policy (with optional remediation) at selected host-pool
  resource-group scopes.

.DESCRIPTION
  This script validates Azure context, builds a DCR that streams performance counters
  to both InsightsMetrics and Perf tables, and then runs in one of three modes:

  - DcrOnly
  - DcrAndPolicy
  - DcrPolicyRemediation

  Interactive mode is the default. The script asks:
  - Which action mode to run
  - Whether to target all discovered host pool resource groups or specific host pools

  It then shows a confirmation summary, executes the selected actions idempotently,
  prints a run summary, and always writes a timestamped CSV report.

.PARAMETER SubscriptionId
  Azure subscription ID.

.PARAMETER LawRG
  Resource group containing the Log Analytics workspace.

.PARAMETER LawName
  Name of the Log Analytics workspace.

.PARAMETER DcrRG
  Resource group where the DCR is created or updated.

.PARAMETER DcrName
  Name of the DCR.

.PARAMETER Location
  Azure region for DCR and policy assignment managed identity.

.PARAMETER SamplingFrequencyInSeconds
  Perf counter collection frequency in seconds.

.PARAMETER CounterSpecifiers
  Perf counters to collect.

.PARAMETER TranscriptPath
  Optional transcript path.

.PARAMETER PolicyAssignmentName
  Policy assignment display name used per targeted RG.

.PARAMETER PolicyAssignmentResourceName
  Policy assignment resource name used in Azure Policy APIs (must be Azure-valid).

.PARAMETER PolicyAssignmentMode
  Policy assignment strategy:
  - SingleAssignment: one assignment at subscription scope, limited to selected RGs via notScopes.
  - PerResourceGroup: one assignment per selected RG.

.PARAMETER PolicyDefinitionId
  Policy definition id for AMA + DCR association.

.PARAMETER NonInteractive
  Skip prompts and use explicit parameter-driven behavior.

.PARAMETER ExecutionMode
  Non-interactive action mode: DcrOnly, DcrAndPolicy, DcrPolicyRemediation.

.PARAMETER ScopeSelection
  Non-interactive scope selection for policy mode: AllHostPoolResourceGroups or SpecificHostPools.

.PARAMETER HostPoolNames
  Host pool names used when ScopeSelection is SpecificHostPools.

.PARAMETER PolicyScopeResourceGroup
  Optional manual RG list for policy mode. If set, it takes precedence over host pool selection.

.PARAMETER SkipRemediationTask
  Backward-compatible switch. If used with DcrPolicyRemediation, mode is downgraded to DcrAndPolicy.

.PARAMETER ReportPath
  Optional report directory or file base path. Timestamp is always appended.

.PARAMETER WhatIf
  Preview changes without applying.

.NOTES
  Requires Azure CLI.
  Version: 2.3 (Performance-focused CLI round-trip reduction)
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
  [Parameter(Mandatory = $true)]
  [ValidateNotNullOrEmpty()]
  [ValidatePattern('^[0-9a-fA-F-]{36}$')]
  [string]$SubscriptionId,

  [Parameter(Mandatory = $false)]
  [ValidateNotNullOrEmpty()]
  [ValidatePattern('^[a-zA-Z0-9._()\-]{1,90}$')]
  [Alias('LawResourceGroup')]
  [string]$LawRG = 'rg-avd-monitoring',

  [Parameter(Mandatory = $false)]
  [ValidateNotNullOrEmpty()]
  [Alias('LawWorkspace')]
  [string]$LawName = 'law-avd-prod',

  [Parameter(Mandatory = $false)]
  [ValidateNotNullOrEmpty()]
  [ValidatePattern('^[a-zA-Z0-9._()\-]{1,90}$')]
  [string]$DcrRG = 'rg-avd-monitoring',

  [Parameter(Mandatory = $false)]
  [ValidateNotNullOrEmpty()]
  [string]$DcrName = 'AVD-SessionHost-DCR',

  [Parameter(Mandatory = $false)]
  [ValidateNotNullOrEmpty()]
  [string]$Location = 'EastUS2',

  [Parameter(Mandatory = $false)]
  [ValidateRange(10, 3600)]
  [int]$SamplingFrequencyInSeconds = 60,

  [Parameter(Mandatory = $false)]
  [string[]]$CounterSpecifiers = @(
    '\\Processor Information(_Total)\\% Processor Time',
    '\\Memory\\Available MBytes',
    '\\Memory\\% Committed Bytes In Use',
    '\\Memory\\Pages/sec',
    '\\Memory\\Page Faults/sec',
    '\\LogicalDisk(*)\\% Free Space',
    '\\LogicalDisk(*)\\Avg. Disk sec/Read',
    '\\LogicalDisk(*)\\Avg. Disk sec/Write',
    '\\LogicalDisk(*)\\Avg. Disk sec/Transfer',
    '\\PhysicalDisk(*)\\Avg. Disk sec/Read',
    '\\PhysicalDisk(*)\\Avg. Disk sec/Write',
    '\\PhysicalDisk(*)\\Avg. Disk sec/Transfer',
    '\\LogicalDisk(*)\\Current Disk Queue Length',
    '\\PhysicalDisk(*)\\Avg. Disk Queue Length',
    '\\User Input Delay per Process(*)\\Max Input Delay',
    '\\User Input Delay per Session(*)\\Max Input Delay',
    '\\RemoteFX Network(*)\\Current TCP RTT',
    '\\RemoteFX Network(*)\\Current UDP Bandwidth',
    '\\RemoteFX Graphics(*)\\Average Encoding Time',
    '\\Terminal Services\\Active Sessions',
    '\\Terminal Services\\Inactive Sessions',
    '\\Terminal Services\\Total Sessions',
    '\\Network Adapter(*)\\Bytes Total/sec',
    '\\Network Adapter(*)\\Bytes Received/sec',
    '\\Network Adapter(*)\\Bytes Sent/sec',
    '\\Network Adapter(*)\\Current Bandwidth',
    '\\Network Adapter(*)\\Output Queue Length'
  ),

  [Parameter(Mandatory = $false)]
  [string]$TranscriptPath,

  [Parameter(Mandatory = $false)]
  [ValidateNotNullOrEmpty()]
  [string]$PolicyAssignmentName = 'AVD-Sessionhost-Configure Windows Virtual Machines to be associated with a Data Collection Rule or a Data Collection Endpoint',

  [Parameter(Mandatory = $false)]
  [ValidateNotNullOrEmpty()]
  [ValidatePattern('^[a-zA-Z0-9._()\-]{1,128}$')]
  [string]$PolicyAssignmentResourceName = 'avd-sessionhost-ama-dcr',

  [Parameter(Mandatory = $false)]
  [ValidateSet('SingleAssignment', 'PerResourceGroup')]
  [string]$PolicyAssignmentMode = 'SingleAssignment',

  [Parameter(Mandatory = $false)]
  [ValidateNotNullOrEmpty()]
  [string]$PolicyDefinitionId = '/providers/Microsoft.Authorization/policyDefinitions/244efd75-0d92-453c-b9a3-7d73ca36ed52',

  [Parameter(Mandatory = $false)]
  [switch]$NonInteractive,

  [Parameter(Mandatory = $false)]
  [ValidateSet('DcrOnly', 'DcrAndPolicy', 'DcrPolicyRemediation')]
  [string]$ExecutionMode = 'DcrPolicyRemediation',

  [Parameter(Mandatory = $false)]
  [ValidateSet('AllHostPoolResourceGroups', 'SpecificHostPools')]
  [string]$ScopeSelection = 'AllHostPoolResourceGroups',

  [Parameter(Mandatory = $false)]
  [string[]]$HostPoolNames,

  [Parameter(Mandatory = $false)]
  [ValidatePattern('^[a-zA-Z0-9._()\-]{1,90}$')]
  [string[]]$PolicyScopeResourceGroup,

  [Parameter(Mandatory = $false)]
  [switch]$SkipRemediationTask,

  [Parameter(Mandatory = $false)]
  [string]$ReportPath
)

$ErrorActionPreference = 'Stop'
$scriptStart = Get-Date
$reportRows = New-Object System.Collections.Generic.List[object]
$resolvedMode = $ExecutionMode
$MaxSingleAssignmentNotScopesCount = 500
$MaxSingleAssignmentNotScopesArgLength = 7000

function Add-ReportRow {
  param(
    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $true)]
    [string]$ActionMode,

    [Parameter(Mandatory = $true)]
    [string]$DcrName,

    [Parameter(Mandatory = $false)]
    [string]$DcrId,

    [Parameter(Mandatory = $true)]
    [string]$LawRG,

    [Parameter(Mandatory = $true)]
    [string]$LawName,

    [Parameter(Mandatory = $false)]
    [string]$TargetHostPoolName,

    [Parameter(Mandatory = $false)]
    [string]$TargetResourceGroup,

    [Parameter(Mandatory = $true)]
    [string]$PolicyAssignmentName,

    [Parameter(Mandatory = $false)]
    [string]$PolicyAssignmentId,

    [Parameter(Mandatory = $false)]
    [string]$RemediationTaskName,

    [Parameter(Mandatory = $true)]
    [string]$Status,

    [Parameter(Mandatory = $false)]
    [string]$ErrorMessage,

    [Parameter(Mandatory = $true)]
    [double]$DurationSeconds
  )

  $script:reportRows.Add([PSCustomObject]@{
      TimestampUtc         = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
      SubscriptionId       = $SubscriptionId
      ActionMode           = $ActionMode
      DcrName              = $DcrName
      DcrId                = $DcrId
      LawRG                = $LawRG
      LawName              = $LawName
      TargetHostPoolName   = $TargetHostPoolName
      TargetResourceGroup  = $TargetResourceGroup
      PolicyAssignmentName = $PolicyAssignmentName
      PolicyAssignmentId   = $PolicyAssignmentId
      RemediationTaskName  = $RemediationTaskName
      Status               = $Status
      ErrorMessage         = $ErrorMessage
      DurationSeconds      = [Math]::Round($DurationSeconds, 2)
    })
}

function Test-AzNotFoundError {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ErrorText
  )

  return $ErrorText -match 'PolicyAssignmentNotFound|RemediationNotFound|ResourceNotFound|could not be found|not found'
}

function Test-AzAlreadyExistsError {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ErrorText
  )

  return $ErrorText -match 'already exists|already been created|Conflict'
}

function Get-PolicyAssignmentResourceId {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Scope,

    [Parameter(Mandatory = $true)]
    [string]$PolicyAssignmentResourceName
  )

  $trimmedScope = $Scope.TrimEnd('/')
  return "$trimmedScope/providers/Microsoft.Authorization/policyAssignments/$PolicyAssignmentResourceName"
}

function Resolve-ExecutionMode {
  param(
    [Parameter(Mandatory = $true)]
    [string]$InitialMode,

    [Parameter(Mandatory = $true)]
    [bool]$NonInteractive,

    [Parameter(Mandatory = $true)]
    [bool]$SkipRemediationTask
  )

  $mode = $InitialMode

  if (-not $NonInteractive) {
    Write-Host ''
    Write-Host 'Select execution mode:' -ForegroundColor Cyan
    Write-Host '  1) DCR only'
    Write-Host '  2) DCR + Policy assignment'
    Write-Host '  3) DCR + Policy + Remediation'

    do {
      $choice = (Read-Host 'Enter choice (1/2/3)').Trim()
    } while ($choice -notin @('1', '2', '3'))

    switch ($choice) {
      '1' { $mode = 'DcrOnly' }
      '2' { $mode = 'DcrAndPolicy' }
      '3' { $mode = 'DcrPolicyRemediation' }
    }
  }

  if ($SkipRemediationTask -and $mode -eq 'DcrPolicyRemediation') {
    Write-Warning 'SkipRemediationTask was set. Downgrading execution mode to DcrAndPolicy.'
    $mode = 'DcrAndPolicy'
  }

  return $mode
}

function Test-ResourceGroupExistsOrThrow {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName
  )

  $exists = az group exists --name $ResourceGroupName 2>$null
  if ($exists -ne 'true') {
    throw "Resource group '$ResourceGroupName' does not exist in subscription '$SubscriptionId'."
  }
}

function Get-HostPoolInventory {
  [OutputType([object[]])]
  param()

  $global:LASTEXITCODE = 0
  $json = az desktopvirtualization hostpool list --query '[].{name:name,resourceGroup:resourceGroup,id:id}' -o json --only-show-errors 2>$null
  if ($LASTEXITCODE -ne 0) {
    throw 'Failed to list AVD host pools. Ensure Microsoft.DesktopVirtualization resources are accessible.'
  }

  $items = @()
  if (-not [string]::IsNullOrWhiteSpace($json)) {
    $items = $json | ConvertFrom-Json
  }

  if (-not $items -or $items.Count -eq 0) {
    Write-Warning 'No AVD host pools found in this subscription.'
    return @()
  }

  return $items | Sort-Object resourceGroup, name
}

function Resolve-TargetPolicyScopes {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Mode,

    [Parameter(Mandatory = $false)]
    [object[]]$HostPools,

    [Parameter(Mandatory = $true)]
    [bool]$NonInteractive,

    [Parameter(Mandatory = $false)]
    [string[]]$ManualPolicyScopes,

    [Parameter(Mandatory = $true)]
    [string]$ScopeSelection,

    [Parameter(Mandatory = $false)]
    [string[]]$HostPoolNames,

    [Parameter(Mandatory = $true)]
    [string]$DefaultDcrRG
  )

  if ($Mode -eq 'DcrOnly') {
    return [PSCustomObject]@{
      ResourceGroups = @()
      HostPoolMap    = @{}
    }
  }

  if ($ManualPolicyScopes -and $ManualPolicyScopes.Count -gt 0) {
    $map = @{}
    foreach ($rg in $ManualPolicyScopes) {
      $map[$rg] = 'ManualSelection'
    }

    return [PSCustomObject]@{
      ResourceGroups = ($ManualPolicyScopes | Sort-Object -Unique)
      HostPoolMap    = $map
    }
  }

  if (-not $HostPools -or $HostPools.Count -eq 0) {
    Write-Warning "Falling back to DcrRG '$DefaultDcrRG' because no host pools were discovered."
    return [PSCustomObject]@{
      ResourceGroups = @($DefaultDcrRG)
      HostPoolMap    = @{ $DefaultDcrRG = 'FallbackToDcrRG' }
    }
  }

  if ($NonInteractive) {
    if ($ScopeSelection -eq 'SpecificHostPools') {
      if (-not $HostPoolNames -or $HostPoolNames.Count -eq 0) {
        throw 'ScopeSelection SpecificHostPools requires HostPoolNames in NonInteractive mode.'
      }

      $selectedPools = $HostPools | Where-Object { $HostPoolNames -contains $_.name }
      if (-not $selectedPools -or $selectedPools.Count -eq 0) {
        throw 'No matching host pools found for HostPoolNames.'
      }

      $map = @{}
      foreach ($group in ($selectedPools | Group-Object resourceGroup)) {
        $map[$group.Name] = ($group.Group.name -join ';')
      }

      return [PSCustomObject]@{
        ResourceGroups = ($selectedPools.resourceGroup | Sort-Object -Unique)
        HostPoolMap    = $map
      }
    }

    $allMap = @{}
    foreach ($group in ($HostPools | Group-Object resourceGroup)) {
      $allMap[$group.Name] = ($group.Group.name -join ';')
    }

    return [PSCustomObject]@{
      ResourceGroups = ($HostPools.resourceGroup | Sort-Object -Unique)
      HostPoolMap    = $allMap
    }
  }

  Write-Host ''
  Write-Host 'Policy target scope selection:' -ForegroundColor Cyan
  Write-Host '  A) All discovered host pool resource groups'
  Write-Host '  S) Select specific host pools'

  do {
    $scopeChoice = (Read-Host 'Choose target scope (A/S)').Trim().ToUpperInvariant()
  } while ($scopeChoice -notin @('A', 'S'))

  if ($scopeChoice -eq 'A') {
    $allMap = @{}
    foreach ($group in ($HostPools | Group-Object resourceGroup)) {
      $allMap[$group.Name] = ($group.Group.name -join ';')
    }

    return [PSCustomObject]@{
      ResourceGroups = ($HostPools.resourceGroup | Sort-Object -Unique)
      HostPoolMap    = $allMap
    }
  }

  Write-Host ''
  Write-Host 'Available host pools:' -ForegroundColor Cyan
  for ($i = 0; $i -lt $HostPools.Count; $i++) {
    $displayIndex = $i + 1
    Write-Host ("  {0}) {1} (RG: {2})" -f $displayIndex, $HostPools[$i].name, $HostPools[$i].resourceGroup)
  }

  do {
    $raw = Read-Host 'Enter host pool numbers (comma-separated, e.g. 1,3)'
    $tokens = $raw -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }

    $indexes = @()
    $valid = $true
    foreach ($token in $tokens) {
      $num = 0
      if (-not [int]::TryParse($token, [ref]$num)) {
        $valid = $false
        break
      }
      if ($num -lt 1 -or $num -gt $HostPools.Count) {
        $valid = $false
        break
      }
      $indexes += ($num - 1)
    }

    $indexes = $indexes | Sort-Object -Unique
  } while (-not $valid -or $indexes.Count -eq 0)

  $selected = foreach ($idx in $indexes) { $HostPools[$idx] }
  $map = @{}
  foreach ($group in ($selected | Group-Object resourceGroup)) {
    $map[$group.Name] = ($group.Group.name -join ';')
  }

  return [PSCustomObject]@{
    ResourceGroups = ($selected.resourceGroup | Sort-Object -Unique)
    HostPoolMap    = $map
  }
}

function Resolve-PolicyExecutionTargets {
  param(
    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $true)]
    [ValidateSet('SingleAssignment', 'PerResourceGroup')]
    [string]$PolicyAssignmentMode,

    [Parameter(Mandatory = $true)]
    [string[]]$TargetPolicyRgs,

    [Parameter(Mandatory = $true)]
    [hashtable]$HostPoolMapByRg,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 5000)]
    [int]$MaxNotScopesCount = 500,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1000, 50000)]
    [int]$MaxNotScopesArgLength = 7000
  )

  $buildPerResourceGroupTargets = {
    param(
      [string[]]$ResourceGroups,
      [hashtable]$HostPoolMap
    )

    $targets = @()
    foreach ($rg in ($ResourceGroups | Sort-Object -Unique)) {
      $targets += [PSCustomObject]@{
        Scope               = "/subscriptions/$SubscriptionId/resourceGroups/$rg"
        ScopeType           = 'ResourceGroup'
        ScopeLabel          = $rg
        ReportResourceGroup = $rg
        ReportHostPools     = if ($HostPoolMap.ContainsKey($rg)) { $HostPoolMap[$rg] } else { '' }
        NotScopes           = @()
      }
    }

    return $targets
  }

  if ($PolicyAssignmentMode -eq 'PerResourceGroup') {
    return [PSCustomObject]@{
      Targets           = (& $buildPerResourceGroupTargets -ResourceGroups $TargetPolicyRgs -HostPoolMap $HostPoolMapByRg)
      EffectiveMode     = 'PerResourceGroup'
      FallbackReason    = ''
      NotScopesCount    = 0
      NotScopesArgLength = 0
    }
  }

  $global:LASTEXITCODE = 0
  $allRgsRaw = az group list --query '[].name' -o tsv --only-show-errors 2>$null
  if ($LASTEXITCODE -ne 0) {
    throw 'Failed to list resource groups for consolidated policy assignment mode.'
  }

  $allRgs = @()
  if (-not [string]::IsNullOrWhiteSpace($allRgsRaw)) {
    $allRgs = $allRgsRaw -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
  }

  $selectedSet = @{}
  foreach ($rg in $TargetPolicyRgs) {
    $selectedSet[$rg] = $true
  }

  $notScopes = @()
  foreach ($rg in $allRgs) {
    if (-not $selectedSet.ContainsKey($rg)) {
      $notScopes += "/subscriptions/$SubscriptionId/resourceGroups/$rg"
    }
  }

  $notScopesArgLength = if ($notScopes.Count -gt 0) { ($notScopes -join ' ').Length } else { 0 }
  $fallbackReason = ''
  if ($notScopes.Count -gt $MaxNotScopesCount) {
    $fallbackReason = "notScopes count $($notScopes.Count) exceeds safe limit $MaxNotScopesCount"
  } elseif ($notScopesArgLength -gt $MaxNotScopesArgLength) {
    $fallbackReason = "notScopes argument length $notScopesArgLength exceeds safe limit $MaxNotScopesArgLength"
  }

  if (-not [string]::IsNullOrWhiteSpace($fallbackReason)) {
    return [PSCustomObject]@{
      Targets           = (& $buildPerResourceGroupTargets -ResourceGroups $TargetPolicyRgs -HostPoolMap $HostPoolMapByRg)
      EffectiveMode     = 'PerResourceGroup'
      FallbackReason    = $fallbackReason
      NotScopesCount    = $notScopes.Count
      NotScopesArgLength = $notScopesArgLength
    }
  }

  $hostPoolNames = @()
  foreach ($rg in $TargetPolicyRgs) {
    if ($HostPoolMapByRg.ContainsKey($rg)) {
      $hostPoolNames += $HostPoolMapByRg[$rg]
    }
  }

  $reportHostPools = (@($hostPoolNames | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique) -join ';')

  return [PSCustomObject]@{
    Targets = @(
      [PSCustomObject]@{
        Scope               = "/subscriptions/$SubscriptionId"
        ScopeType           = 'Subscription'
        ScopeLabel          = 'subscription'
        ReportResourceGroup = ($TargetPolicyRgs -join ';')
        ReportHostPools     = $reportHostPools
        NotScopes           = $notScopes
      }
    )
    EffectiveMode      = 'SingleAssignment'
    FallbackReason     = ''
    NotScopesCount     = $notScopes.Count
    NotScopesArgLength = $notScopesArgLength
  }
}

function Remove-PerResourceGroupPolicyAssignmentDuplicates {
  param(
    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $true)]
    [string[]]$TargetPolicyRgs,

    [Parameter(Mandatory = $true)]
    [string]$PolicyAssignmentResourceName
  )

  $removedCount = 0
  $skippedCount = 0

  foreach ($rg in $TargetPolicyRgs) {
    $scope = "/subscriptions/$SubscriptionId/resourceGroups/$rg"

    $global:LASTEXITCODE = 0
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $deleteOutput = az policy assignment delete --name $PolicyAssignmentResourceName --scope $scope --only-show-errors -o none 2>&1
    $deleteExitCode = $LASTEXITCODE
    $ErrorActionPreference = $prevEAP

    if ($deleteExitCode -ne 0) {
      $deleteErrText = ($deleteOutput | Out-String)
      if (Test-AzNotFoundError -ErrorText $deleteErrText) {
        $skippedCount++
        continue
      }
      throw "Failed to delete duplicate policy assignment '$PolicyAssignmentResourceName' in scope '$scope': $deleteErrText"
    }

    $removedCount++
  }

  return [PSCustomObject]@{
    RemovedCount = $removedCount
    SkippedCount = $skippedCount
  }
}

function Set-PolicyAssignmentState {
  param(
    [Parameter(Mandatory = $true)]
    [string]$PolicyScope,

    [Parameter(Mandatory = $true)]
    [string]$PolicyScopeLabel,

    [Parameter(Mandatory = $true)]
    [string]$PolicyAssignmentName,

    [Parameter(Mandatory = $true)]
    [string]$PolicyAssignmentResourceName,

    [Parameter(Mandatory = $true)]
    [string]$PolicyDefinitionId,

    [Parameter(Mandatory = $true)]
    [string]$Location,

    [Parameter(Mandatory = $true)]
    [string]$DcrId,

    [Parameter(Mandatory = $false)]
    [string[]]$NotScopes = @()
  )

  $scope = $PolicyScope
  $policyDefinitionRef = if ($PolicyDefinitionId -match '^/providers/Microsoft\.Authorization/policyDefinitions/(?<name>[^/]+)$') {
    $matches['name']
  } else {
    $PolicyDefinitionId
  }

  $policyParams = @{ dcrResourceId = @{ value = $DcrId } } | ConvertTo-Json -Depth 5 -Compress
  $scopeFileToken = if ([string]::IsNullOrWhiteSpace($PolicyScopeLabel)) { 'scope' } else { ($PolicyScopeLabel -replace '[^a-zA-Z0-9._()\-]', '_') }
  $policyParamsFile = Join-Path $env:TEMP ("policy-params-{0}-{1}.json" -f $PolicyAssignmentResourceName, $scopeFileToken)
  [System.IO.File]::WriteAllText($policyParamsFile, $policyParams, [System.Text.UTF8Encoding]::new($false))

  try {
    $global:LASTEXITCODE = 0
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $updateArgs = @(
      'policy', 'assignment', 'update',
      '--name', $PolicyAssignmentResourceName,
      '--scope', $scope,
      '--display-name', $PolicyAssignmentName,
      '--params', "@$policyParamsFile",
      '--only-show-errors', '-o', 'none'
    )
    if ($NotScopes -and $NotScopes.Count -gt 0) {
      $updateArgs += @('--not-scopes', ($NotScopes -join ' '))
    }

    $updateOutput = az @updateArgs 2>&1
    $updateExitCode = $LASTEXITCODE
    $ErrorActionPreference = $prevEAP

    if ($updateExitCode -eq 0) {
      $operation = 'Updated'
    } else {
      $updateErrText = ($updateOutput | Out-String)
      if (-not (Test-AzNotFoundError -ErrorText $updateErrText)) {
        throw "Failed to update policy assignment '$PolicyAssignmentResourceName' (display: '$PolicyAssignmentName') in scope '$PolicyScopeLabel': $updateErrText"
      }

      $global:LASTEXITCODE = 0
      $prevEAP = $ErrorActionPreference
      $ErrorActionPreference = 'Continue'
      $createArgs = @(
        'policy', 'assignment', 'create',
        '--name', $PolicyAssignmentResourceName,
        '--display-name', $PolicyAssignmentName,
        '--scope', $scope,
        '--policy', $policyDefinitionRef,
        '--params', "@$policyParamsFile",
        '--mi-system-assigned',
        '--identity-scope', $scope,
        '--role', 'Contributor',
        '--location', $Location,
        '--only-show-errors', '-o', 'none'
      )
      if ($NotScopes -and $NotScopes.Count -gt 0) {
        $createArgs += @('--not-scopes', ($NotScopes -join ' '))
      }

      $createOutput = az @createArgs 2>&1
      $createExitCode = $LASTEXITCODE
      $ErrorActionPreference = $prevEAP

      if ($createExitCode -ne 0) {
        $createErrText = ($createOutput | Out-String)
        if (Test-AzAlreadyExistsError -ErrorText $createErrText) {
          $operation = 'Updated'
        } else {
          throw "Failed to create policy assignment '$PolicyAssignmentResourceName' (display: '$PolicyAssignmentName') in scope '$PolicyScopeLabel': $createErrText"
        }
      } else {
        $operation = 'Created'
      }
    }
  } finally {
    Remove-Item -LiteralPath $policyParamsFile -ErrorAction SilentlyContinue
  }

  $assignmentId = Get-PolicyAssignmentResourceId -Scope $scope -PolicyAssignmentResourceName $PolicyAssignmentResourceName

  return [PSCustomObject]@{
    Scope        = $scope
    Name         = $PolicyAssignmentResourceName
    DisplayName  = $PolicyAssignmentName
    AssignmentId = $assignmentId
    Operation    = $operation
  }
}

function Set-PolicyRemediationState {
  param(
    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $true)]
    [ValidateSet('ResourceGroup', 'Subscription')]
    [string]$PolicyScopeType,

    [Parameter(Mandatory = $false)]
    [string]$PolicyScopeResourceGroup = '',

    [Parameter(Mandatory = $true)]
    [string]$PolicyAssignmentResourceName,

    [Parameter(Mandatory = $true)]
    [string]$PolicyAssignmentReference,

    [Parameter(Mandatory = $false)]
    [string]$PolicyAssignmentDisplayName = '',

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 10)]
    [int]$MaxRetryAttempts = 4,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 60)]
    [int]$RetryDelaySeconds = 8
  )

  $remediationName = "$PolicyAssignmentResourceName-remediate"
  $scopeLabel = if ($PolicyScopeType -eq 'ResourceGroup') { $PolicyScopeResourceGroup } else { 'subscription' }

  $createArgs = @(
    'policy', 'remediation', 'create',
    '--name', $remediationName,
    '--policy-assignment', $PolicyAssignmentReference,
    '--subscription', $SubscriptionId,
    '--resource-discovery-mode', 'ReEvaluateCompliance',
    '--only-show-errors', '-o', 'none'
  )
  if ($PolicyScopeType -eq 'ResourceGroup') {
    $createArgs += @('--resource-group', $PolicyScopeResourceGroup)
  }

  $lastCreateErrText = ''
  for ($attempt = 1; $attempt -le $MaxRetryAttempts; $attempt++) {
    $global:LASTEXITCODE = 0
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $createOutput = az @createArgs 2>&1
    $createExitCode = $LASTEXITCODE
    $ErrorActionPreference = $prevEAP

    if ($createExitCode -eq 0) {
      return [PSCustomObject]@{
        Name      = $remediationName
        Operation = 'Created'
      }
    }

    $createErrText = ($createOutput | Out-String)
    $lastCreateErrText = $createErrText

    if (Test-AzAlreadyExistsError -ErrorText $createErrText) {
      return [PSCustomObject]@{
        Name      = $remediationName
        Operation = 'Unchanged'
      }
    }

    # Azure Policy assignment propagation can be eventual; retry not-found style errors briefly.
    if ((Test-AzNotFoundError -ErrorText $createErrText) -and $attempt -lt $MaxRetryAttempts) {
      Write-Warning ("Remediation create attempt {0}/{1} failed in scope '{2}' due to policy-assignment propagation. Retrying in {3}s..." -f $attempt, $MaxRetryAttempts, $scopeLabel, $RetryDelaySeconds)
      Start-Sleep -Seconds $RetryDelaySeconds
      continue
    }

    break
  }

  if ([string]::IsNullOrWhiteSpace($PolicyAssignmentDisplayName)) {
    throw "Failed to create remediation task '$remediationName' in scope '$scopeLabel' after $MaxRetryAttempts attempt(s). Error: $lastCreateErrText"
  }
  throw "Failed to create remediation task '$remediationName' for policy '$PolicyAssignmentResourceName' (display: '$PolicyAssignmentDisplayName') in scope '$scopeLabel' after $MaxRetryAttempts attempt(s). Error: $lastCreateErrText"
}

function Set-DcrState {
  [CmdletBinding(SupportsShouldProcess = $true)]
  param(
    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $true)]
    [string]$DcrRG,

    [Parameter(Mandatory = $true)]
    [string]$DcrName,

    [Parameter(Mandatory = $true)]
    [string]$Location,

    [Parameter(Mandatory = $true)]
    [int]$SamplingFrequencyInSeconds,

    [Parameter(Mandatory = $true)]
    [string[]]$CounterSpecifiers,

    [Parameter(Mandatory = $true)]
    [string]$LawId
  )

  $exists = $true
  $global:LASTEXITCODE = 0
  $prevEAP = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  $dcrCheckErr = az monitor data-collection rule show -g $DcrRG -n $DcrName -o none --only-show-errors 2>&1
  $dcrCheckExitCode = $LASTEXITCODE
  $ErrorActionPreference = $prevEAP

  if ($dcrCheckExitCode -ne 0) {
    $errText = ($dcrCheckErr | Out-String)
    if ($errText -match 'ResourceNotFound|could not be found|not found') {
      $exists = $false
    } else {
      throw "Failed to check DCR existence for '$DcrName': $errText"
    }
  }

  $laName = 'destination-LAW'
  $perfInsightsName = 'datasource-InsightsMetrics'
  $perfTableName = 'datasource-Perf'

  $dcrObj = [ordered]@{
    location   = $Location
    properties = [ordered]@{
      dataSources = [ordered]@{
        performanceCounters = @(
          [ordered]@{
            name                       = $perfInsightsName
            streams                    = @('Microsoft-InsightsMetrics')
            samplingFrequencyInSeconds = $SamplingFrequencyInSeconds
            counterSpecifiers          = @($CounterSpecifiers)
          },
          [ordered]@{
            name                       = $perfTableName
            streams                    = @('Microsoft-Perf')
            samplingFrequencyInSeconds = $SamplingFrequencyInSeconds
            counterSpecifiers          = @($CounterSpecifiers)
          }
        )
      }
      destinations = [ordered]@{
        logAnalytics = @(
          [ordered]@{
            name                = $laName
            workspaceResourceId = $LawId
          }
        )
      }
      dataFlows = @(
        [ordered]@{
          streams      = @('Microsoft-InsightsMetrics')
          destinations = @($laName)
        },
        [ordered]@{
          streams      = @('Microsoft-Perf')
          destinations = @($laName)
        }
      )
    }
  }

  $tmp = Join-Path $env:TEMP ("dcr-{0}.json" -f $DcrName)
  [System.IO.File]::WriteAllText($tmp, ($dcrObj | ConvertTo-Json -Depth 10), [System.Text.UTF8Encoding]::new($false))

  try {
    if (-not (Test-Path $tmp) -or ((Get-Item $tmp).Length -eq 0)) {
      throw "DCR JSON temp file missing or empty: $tmp"
    }

    $action = if ($exists) { 'Updating' } else { 'Creating' }
    if ($PSCmdlet.ShouldProcess("$DcrName in RG $DcrRG", "$action DCR")) {
      az monitor data-collection rule create --name $DcrName --resource-group $DcrRG --rule-file $tmp --only-show-errors -o none
      if ($LASTEXITCODE -ne 0) {
        throw "Failed to create/update DCR '$DcrName'."
      }

      $dcrId = "/subscriptions/$SubscriptionId/resourceGroups/$DcrRG/providers/Microsoft.Insights/dataCollectionRules/$DcrName"

      return [PSCustomObject]@{
        DcrId      = $dcrId
        Operation  = $action
        WasWhatIf  = $false
      }
    }

    return [PSCustomObject]@{
      DcrId      = '<WhatIf-DcrId>'
      Operation  = '[WhatIf]'
      WasWhatIf  = $true
    }
  } finally {
    Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
  }
}

function Export-ExecutionReport {
  param(
    [Parameter(Mandatory = $true)]
    [object[]]$Rows,

    [Parameter(Mandatory = $false)]
    [string]$ReportPath,

    [Parameter(Mandatory = $true)]
    [string]$DefaultDirectory
  )

  $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $baseDirectory = $DefaultDirectory
  $baseName = 'avd-dcr-policy-report'

  if (-not [string]::IsNullOrWhiteSpace($ReportPath)) {
    if (Test-Path -LiteralPath $ReportPath -PathType Container) {
      $baseDirectory = $ReportPath
    } else {
      $parent = Split-Path -Parent $ReportPath
      if (-not [string]::IsNullOrWhiteSpace($parent)) {
        $baseDirectory = $parent
      }

      $leaf = Split-Path -Leaf $ReportPath
      $candidateName = [System.IO.Path]::GetFileNameWithoutExtension($leaf)
      if (-not [string]::IsNullOrWhiteSpace($candidateName)) {
        $baseName = $candidateName
      }
    }
  }

  if (-not (Test-Path -LiteralPath $baseDirectory)) {
    New-Item -ItemType Directory -Path $baseDirectory -Force -WhatIf:$false | Out-Null
  }

  $filePath = Join-Path $baseDirectory ("{0}-{1}.csv" -f $baseName, $timestamp)
  $Rows | Export-Csv -Path $filePath -NoTypeInformation -Encoding UTF8 -WhatIf:$false
  return $filePath
}

if ($TranscriptPath) {
  try {
    Start-Transcript -Path $TranscriptPath -Append -ErrorAction Stop
    Write-Verbose "Transcript started: $TranscriptPath"
  } catch {
    Write-Warning "Failed to start transcript: $_"
  }
}

$reportFilePath = $null

try {
  if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI (az) not found. Please install and try again.'
  }

  $global:LASTEXITCODE = 0
  az account show -o none 2>$null
  if ($LASTEXITCODE -ne 0) {
    throw "Azure CLI is not logged in. Run 'az login' and try again."
  }

  az account set --subscription $SubscriptionId --only-show-errors 2>$null
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to set subscription '$SubscriptionId'."
  }

  Test-ResourceGroupExistsOrThrow -ResourceGroupName $LawRG
  Test-ResourceGroupExistsOrThrow -ResourceGroupName $DcrRG

  $LawId = az monitor log-analytics workspace show -g $LawRG -n $LawName --query id -o tsv --only-show-errors 2>$null
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($LawId)) {
    throw "Could not resolve Log Analytics workspace '$LawName' in '$LawRG'."
  }
  $LawId = $LawId.Trim()

  $resolvedMode = Resolve-ExecutionMode -InitialMode $ExecutionMode -NonInteractive:$NonInteractive -SkipRemediationTask:$SkipRemediationTask
  $requiresPolicy = $resolvedMode -ne 'DcrOnly'
  $defaultAmaDcrPolicyName = 'Configure Windows machines to run Azure Monitor Agent and associate them to a Data Collection Rule'
  $resolvedPolicyName = if ($PolicyDefinitionId -eq '/providers/Microsoft.Authorization/policyDefinitions/244efd75-0d92-453c-b9a3-7d73ca36ed52') {
    $defaultAmaDcrPolicyName
  } else {
    'Selected policy definition'
  }
  $dcrOnlyPolicyGuidance = "DCR-only mode selected. You must manually associate session hosts to this DCR using Azure Policy. Policy name: '$resolvedPolicyName'. Policy definition id: '$PolicyDefinitionId'."

  $hostPools = @()
  if ($requiresPolicy -and (-not $PolicyScopeResourceGroup -or $PolicyScopeResourceGroup.Count -eq 0)) {
    $hostPools = Get-HostPoolInventory
  }

  $scopeResult = Resolve-TargetPolicyScopes `
    -Mode $resolvedMode `
    -HostPools $hostPools `
    -NonInteractive:$NonInteractive `
    -ManualPolicyScopes $PolicyScopeResourceGroup `
    -ScopeSelection $ScopeSelection `
    -HostPoolNames $HostPoolNames `
    -DefaultDcrRG $DcrRG

  $targetPolicyRgs = $scopeResult.ResourceGroups
  $hostPoolMapByRg = $scopeResult.HostPoolMap

  foreach ($rg in $targetPolicyRgs) {
    Test-ResourceGroupExistsOrThrow -ResourceGroupName $rg
  }

  $policyExecutionTargets = @()
  $effectivePolicyAssignmentMode = $PolicyAssignmentMode
  $policyModeFallbackReason = ''
  if ($requiresPolicy) {
    $policyPlan = Resolve-PolicyExecutionTargets `
      -SubscriptionId $SubscriptionId `
      -PolicyAssignmentMode $PolicyAssignmentMode `
      -TargetPolicyRgs $targetPolicyRgs `
      -HostPoolMapByRg $hostPoolMapByRg `
      -MaxNotScopesCount $MaxSingleAssignmentNotScopesCount `
      -MaxNotScopesArgLength $MaxSingleAssignmentNotScopesArgLength

    $policyExecutionTargets = $policyPlan.Targets
    $effectivePolicyAssignmentMode = $policyPlan.EffectiveMode
    $policyModeFallbackReason = $policyPlan.FallbackReason
  }

  Write-Host ''
  Write-Host 'Execution summary:' -ForegroundColor Cyan
  Write-Host ("  Mode: {0}" -f $resolvedMode)
  Write-Host ("  DCR to create/update: {0}" -f $DcrName)
  Write-Host ("  Policy assignment display name: {0}" -f $PolicyAssignmentName)
  Write-Host ("  Policy assignment resource name: {0}" -f $PolicyAssignmentResourceName)
  if ($requiresPolicy) {
    Write-Host ("  Policy assignment mode: {0}" -f $effectivePolicyAssignmentMode)
    if (-not [string]::IsNullOrWhiteSpace($policyModeFallbackReason)) {
      Write-Warning ("Policy assignment mode fallback applied: requested '{0}' but using '{1}' because {2}." -f $PolicyAssignmentMode, $effectivePolicyAssignmentMode, $policyModeFallbackReason)
    }
    Write-Host ("  Target policy RG count: {0}" -f $targetPolicyRgs.Count)
    Write-Host ("  Target policy RGs: {0}" -f ($targetPolicyRgs -join ', '))
    if ($effectivePolicyAssignmentMode -eq 'SingleAssignment' -and $policyExecutionTargets.Count -gt 0) {
      Write-Host ("  Single assignment scope: {0}" -f $policyExecutionTargets[0].Scope)
      Write-Host ("  Excluded RG scope count (notScopes): {0}" -f $policyExecutionTargets[0].NotScopes.Count)
    }
    if ($resolvedMode -eq 'DcrPolicyRemediation') {
      Write-Host ("  Remediation task name pattern: {0}-remediate" -f $PolicyAssignmentResourceName)
    }
  }

  if (-not $NonInteractive) {
    $confirm = (Read-Host 'Proceed? (Y/N)').Trim().ToUpperInvariant()
    if ($confirm -ne 'Y') {
      throw 'Operation canceled by user.'
    }
  }

  Write-Host ''
  Write-Host 'Creating/updating DCR...' -ForegroundColor Cyan
  $dcrStart = Get-Date
  $dcrResult = Set-DcrState -SubscriptionId $SubscriptionId -DcrRG $DcrRG -DcrName $DcrName -Location $Location -SamplingFrequencyInSeconds $SamplingFrequencyInSeconds -CounterSpecifiers $CounterSpecifiers -LawId $LawId
  $dcrDuration = ((Get-Date) - $dcrStart).TotalSeconds

  Write-Host ("DCR result: {0}" -f $dcrResult.Operation) -ForegroundColor Green
  Write-Host ("DCR Id: {0}" -f $dcrResult.DcrId)

  if ($requiresPolicy -and $effectivePolicyAssignmentMode -eq 'SingleAssignment') {
    if ($PSCmdlet.ShouldProcess(($targetPolicyRgs -join ', '), "Remove duplicate per-resource-group policy assignments named '$PolicyAssignmentResourceName'")) {
      $cleanupResult = Remove-PerResourceGroupPolicyAssignmentDuplicates -SubscriptionId $SubscriptionId -TargetPolicyRgs $targetPolicyRgs -PolicyAssignmentResourceName $PolicyAssignmentResourceName
      if (($cleanupResult.RemovedCount + $cleanupResult.SkippedCount) -gt 0) {
        Write-Host ("Duplicate per-RG assignment cleanup: removed {0}, already absent {1}" -f $cleanupResult.RemovedCount, $cleanupResult.SkippedCount) -ForegroundColor DarkYellow
      }
    } else {
      Write-Host ("[WhatIf] Would remove duplicate per-RG policy assignments named '{0}' from selected RG scopes." -f $PolicyAssignmentResourceName) -ForegroundColor DarkYellow
    }
  }

  if ($resolvedMode -eq 'DcrOnly') {
    Write-Warning $dcrOnlyPolicyGuidance
    $dcrOnlyStatus = if ($dcrResult.WasWhatIf) { 'DcrWhatIf' } else { 'DcrSuccess' }
    Add-ReportRow -SubscriptionId $SubscriptionId -ActionMode $resolvedMode -DcrName $DcrName -DcrId $dcrResult.DcrId -LawRG $LawRG -LawName $LawName -TargetHostPoolName '' -TargetResourceGroup $DcrRG -PolicyAssignmentName $PolicyAssignmentName -PolicyAssignmentId '' -RemediationTaskName '' -Status $dcrOnlyStatus -ErrorMessage $dcrOnlyPolicyGuidance -DurationSeconds $dcrDuration
  } elseif ($dcrResult.WasWhatIf) {
    foreach ($target in $policyExecutionTargets) {
      Add-ReportRow -SubscriptionId $SubscriptionId -ActionMode $resolvedMode -DcrName $DcrName -DcrId $dcrResult.DcrId -LawRG $LawRG -LawName $LawName -TargetHostPoolName $target.ReportHostPools -TargetResourceGroup $target.ReportResourceGroup -PolicyAssignmentName $PolicyAssignmentName -PolicyAssignmentId '' -RemediationTaskName '' -Status 'WhatIf' -ErrorMessage '' -DurationSeconds 0
      Write-Host ("[WhatIf] Would assign policy in scope '{0}'" -f $target.ScopeLabel) -ForegroundColor DarkYellow
      if ($resolvedMode -eq 'DcrPolicyRemediation') {
        Write-Host ("[WhatIf] Would create remediation in scope '{0}'" -f $target.ScopeLabel) -ForegroundColor DarkYellow
      }
    }
  } else {
    foreach ($target in $policyExecutionTargets) {
      $scopeStart = Get-Date
      try {
        Write-Host ''
        Write-Host ("Processing policy scope: {0}" -f $target.ScopeLabel) -ForegroundColor Cyan

        $assignmentId = ''
        $remediationName = ''
        $status = 'PolicySuccess'

        if ($PSCmdlet.ShouldProcess("$PolicyAssignmentResourceName in scope $($target.ScopeLabel)", 'Assign/Update AMA+DCR policy')) {
          $assignment = Set-PolicyAssignmentState -PolicyScope $target.Scope -PolicyScopeLabel $target.ScopeLabel -PolicyAssignmentName $PolicyAssignmentName -PolicyAssignmentResourceName $PolicyAssignmentResourceName -PolicyDefinitionId $PolicyDefinitionId -Location $Location -DcrId $dcrResult.DcrId -NotScopes $target.NotScopes
          $assignmentId = $assignment.AssignmentId
          Write-Host ("Policy assignment {0} in '{1}' (resource: {2}, display: {3})" -f $assignment.Operation, $target.ScopeLabel, $assignment.Name, $assignment.DisplayName) -ForegroundColor Green

          if ($resolvedMode -eq 'DcrPolicyRemediation') {
            if ($PSCmdlet.ShouldProcess($target.ScopeLabel, "Create remediation task for policy '$PolicyAssignmentResourceName'")) {
              $remediation = Set-PolicyRemediationState -SubscriptionId $SubscriptionId -PolicyScopeType $target.ScopeType -PolicyScopeResourceGroup $target.ScopeLabel -PolicyAssignmentResourceName $PolicyAssignmentResourceName -PolicyAssignmentReference $assignmentId -PolicyAssignmentDisplayName $PolicyAssignmentName
              $remediationName = $remediation.Name
              Write-Host ("Remediation {0}: {1}" -f $remediation.Operation, $remediationName) -ForegroundColor Green
              $status = 'PolicyRemediationSuccess'
            } else {
              $status = 'PolicyWhatIf'
            }
          }
        } else {
          $status = 'PolicyWhatIf'
        }

        $scopeDuration = ((Get-Date) - $scopeStart).TotalSeconds
        Add-ReportRow -SubscriptionId $SubscriptionId -ActionMode $resolvedMode -DcrName $DcrName -DcrId $dcrResult.DcrId -LawRG $LawRG -LawName $LawName -TargetHostPoolName $target.ReportHostPools -TargetResourceGroup $target.ReportResourceGroup -PolicyAssignmentName $PolicyAssignmentName -PolicyAssignmentId $assignmentId -RemediationTaskName $remediationName -Status $status -ErrorMessage '' -DurationSeconds $scopeDuration
      } catch {
        $scopeDuration = ((Get-Date) - $scopeStart).TotalSeconds
        Write-Warning ("Failed processing scope '{0}': {1}" -f $target.ScopeLabel, $_.Exception.Message)
        Add-ReportRow -SubscriptionId $SubscriptionId -ActionMode $resolvedMode -DcrName $DcrName -DcrId $dcrResult.DcrId -LawRG $LawRG -LawName $LawName -TargetHostPoolName $target.ReportHostPools -TargetResourceGroup $target.ReportResourceGroup -PolicyAssignmentName $PolicyAssignmentName -PolicyAssignmentId '' -RemediationTaskName '' -Status 'Failed' -ErrorMessage $_.Exception.Message -DurationSeconds $scopeDuration
      }
    }
  }

  $duration = (Get-Date) - $scriptStart
  $successCount = @($reportRows | Where-Object { $_.Status -match 'Success|WhatIf|DcrSuccess|DcrWhatIf' }).Count
  $failedCount = @($reportRows | Where-Object { $_.Status -eq 'Failed' }).Count

  Write-Host ''
  Write-Host '=== Run Summary ===' -ForegroundColor Cyan
  Write-Host ("Rows captured: {0}" -f $reportRows.Count)
  Write-Host ("Successful/WhatIf rows: {0}" -f $successCount)
  Write-Host ("Failed rows: {0}" -f $failedCount)
  $durationText = if ($duration.TotalHours -ge 1) {
    "{0:00}:{1:00}:{2:00}" -f [int]$duration.TotalHours, $duration.Minutes, $duration.Seconds
  } else {
    $duration.ToString('mm\:ss')
  }
  Write-Host ("Total duration: {0}" -f $durationText)

  if ($reportRows.Count -gt 0) {
    Write-Host ''
    $reportRows |
      Select-Object TimestampUtc, ActionMode, TargetResourceGroup, Status, PolicyAssignmentId, RemediationTaskName |
      Format-Table -AutoSize | Out-String | Write-Host
  }
} catch {
  $fatalDuration = ((Get-Date) - $scriptStart).TotalSeconds
  Write-Error $_

  if ($reportRows.Count -eq 0) {
    Add-ReportRow -SubscriptionId $SubscriptionId -ActionMode $resolvedMode -DcrName $DcrName -DcrId '' -LawRG $LawRG -LawName $LawName -TargetHostPoolName '' -TargetResourceGroup '' -PolicyAssignmentName $PolicyAssignmentName -PolicyAssignmentId '' -RemediationTaskName '' -Status 'FatalError' -ErrorMessage $_.Exception.Message -DurationSeconds $fatalDuration
  }

  throw
} finally {
  try {
    if ($reportRows.Count -gt 0) {
      $reportFilePath = Export-ExecutionReport -Rows $reportRows -ReportPath $ReportPath -DefaultDirectory $PSScriptRoot
      Write-Host ''
      Write-Host ("Report saved: {0}" -f $reportFilePath) -ForegroundColor Green
    }
  } catch {
    Write-Warning ("Failed to write CSV report: {0}" -f $_.Exception.Message)
  }

  if ($TranscriptPath) {
    try {
      Stop-Transcript -ErrorAction SilentlyContinue | Out-Null
      Write-Verbose 'Transcript stopped.'
    } catch {
    }
  }
}
