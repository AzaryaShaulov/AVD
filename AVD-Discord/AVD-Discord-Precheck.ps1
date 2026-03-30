#requires -Version 5.1
<#
==============================================================================
SCRIPT VERSION: 1.0
LAST UPDATED: March 29, 2026
REPOSITORY: https://github.com/AzaryaShaulov/AVD
DISCLAIMER: This script is provided AS IS, without warranties or support guarantees.
==============================================================================
.SYNOPSIS
    Validates prerequisites for AVD Discord notifier deployment.

.DESCRIPTION
    Read-only precheck script. Validates:
    - Azure CLI login and subscription access
    - Resource group existence
    - Target action group(s) existence
    - Discord webhook URL format and reachability
    - .env file presence

    This script makes no changes to Azure resources.

.PARAMETER SubscriptionId
    Target Azure subscription ID.

.PARAMETER ResourceGroupName
    Resource group where the Logic App will be deployed.

.PARAMETER ActionGroupNames
    One or more existing action group names to validate.

.PARAMETER ActionGroupResourceGroup
    Resource group containing the action groups. Defaults to ResourceGroupName.

.PARAMETER EnvFilePath
    Path to the .env file containing DISCORD_WEBHOOK_URL.

.PARAMETER CsvPath
    Output path for the precheck report CSV.

.EXAMPLE
    .\AVD-Discord-Precheck.ps1 `
      -SubscriptionId "YOUR-SUB-ID" `
      -ResourceGroupName "rg-avd-monitoring" `
      -ActionGroupNames @("AVD-Alerts-Detailed","AVD-Insights-Detailed")
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ResourceGroupName,

    [string[]]$ActionGroupNames = @(),

    [string]$ActionGroupResourceGroup = "",

    [string]$EnvFilePath = "",

    [string]$CsvPath = ""
)

$ErrorActionPreference = "Stop"

function Write-Step {
    param([string]$Message)
    Write-Host "`n=== $Message ===" -ForegroundColor Cyan
}

function Write-CheckResult {
    param(
        [string]$Check,
        [bool]$Passed,
        [string]$Detail = ""
    )
    $icon = if ($Passed) { "[PASS]" } else { "[FAIL]" }
    $color = if ($Passed) { "Green" } else { "Red" }
    $msg = "$icon $Check"
    if ($Detail) { $msg += " - $Detail" }
    Write-Host $msg -ForegroundColor $color

    return [pscustomobject]@{
        Check  = $Check
        Passed = $Passed
        Detail = $Detail
    }
}

if ([string]::IsNullOrWhiteSpace($ActionGroupResourceGroup)) {
    $ActionGroupResourceGroup = $ResourceGroupName
}
if ([string]::IsNullOrWhiteSpace($EnvFilePath)) {
    $EnvFilePath = Join-Path $PSScriptRoot ".env"
}
if ([string]::IsNullOrWhiteSpace($CsvPath)) {
    $subPrefix = if ($SubscriptionId.Length -ge 8) { $SubscriptionId.Substring(0, 8) } else { $SubscriptionId }
    $CsvPath = Join-Path $PSScriptRoot "avd-discord-precheck-$subPrefix.csv"
}

$results = @()

# =========================
# Check 1: Azure CLI login
# =========================
Write-Step "Checking Azure CLI login"
$cliOk = $false
try {
    & az account show -o none 2>$null
    $cliOk = ($LASTEXITCODE -eq 0)
}
catch { }
$results += Write-CheckResult -Check "Azure CLI login" -Passed $cliOk -Detail $(if ($cliOk) { "Logged in" } else { "Run 'az login' first" })

if (-not $cliOk) {
    Write-Host "`nCannot proceed without Azure CLI login." -ForegroundColor Red
    $results | Export-Csv -Path $CsvPath -NoTypeInformation -Force
    return
}

# =========================
# Check 2: Subscription access
# =========================
Write-Step "Checking subscription access"
$subOk = $false
try {
    & az account set --subscription $SubscriptionId 2>$null
    $subOk = ($LASTEXITCODE -eq 0)
}
catch { }
$results += Write-CheckResult -Check "Subscription access" -Passed $subOk -Detail $(if ($subOk) { $SubscriptionId } else { "Cannot set subscription $SubscriptionId" })

# =========================
# Check 3: Resource group
# =========================
Write-Step "Checking resource group"
$rgOk = $false
try {
    $rgExists = (& az group exists --name $ResourceGroupName 2>$null).Trim()
    $rgOk = ($rgExists -eq "true")
}
catch { }
$results += Write-CheckResult -Check "Resource group exists" -Passed $rgOk -Detail $(if ($rgOk) { $ResourceGroupName } else { "'$ResourceGroupName' not found - will be created by deploy script" })

# =========================
# Check 4: Action groups
# =========================
if ($ActionGroupNames.Count -gt 0) {
    Write-Step "Checking action group(s)"
    foreach ($agName in $ActionGroupNames) {
        $agOk = $false
        try {
            $agResult = & az monitor action-group show `
                --resource-group $ActionGroupResourceGroup `
                --name $agName `
                --subscription $SubscriptionId `
                -o tsv --query "name" 2>$null
            $agOk = ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($agResult))
        }
        catch { }
        $results += Write-CheckResult -Check "Action group '$agName'" -Passed $agOk -Detail $(if ($agOk) { "Found in $ActionGroupResourceGroup" } else { "Not found - create it or check the resource group" })
    }
}

# =========================
# Check 5: .env file
# =========================
Write-Step "Checking .env file"
$envExists = Test-Path -Path $EnvFilePath
$results += Write-CheckResult -Check ".env file exists" -Passed $envExists -Detail $(if ($envExists) { $EnvFilePath } else { "Create .env with DISCORD_WEBHOOK_URL=https://discord.com/api/webhooks/..." })

# =========================
# Check 6: Discord webhook URL format and reachability
# =========================
$webhookUrl = ""
$urlFormatOk = $false
$webhookReachable = $false

if ($envExists) {
    Write-Step "Checking Discord webhook URL"
    try {
        $lines = Get-Content -Path $EnvFilePath
        foreach ($line in $lines) {
            $trimmed = $line.Trim()
            if ($trimmed -match '^DISCORD_WEBHOOK_URL=(.+)$') {
                $webhookUrl = $Matches[1].Trim()
                break
            }
        }
    }
    catch { }

    if ([string]::IsNullOrWhiteSpace($webhookUrl)) {
        $results += Write-CheckResult -Check "DISCORD_WEBHOOK_URL in .env" -Passed $false -Detail "Key not found in .env file"
    }
    else {
        $urlFormatOk = ($webhookUrl -match '^https://discord(app)?\.com/api/webhooks/\d+/.+$')
        $results += Write-CheckResult -Check "Webhook URL format" -Passed $urlFormatOk -Detail $(if ($urlFormatOk) { "Valid Discord webhook URL" } else { "Expected https://discord.com/api/webhooks/<id>/<token>" })

        if ($urlFormatOk) {
            try {
                $response = Invoke-WebRequest -Uri $webhookUrl -Method Get -UseBasicParsing -ErrorAction Stop
                $webhookReachable = ($response.StatusCode -in @(200, 405))
            }
            catch {
                $statusCode = $null
                if ($_.Exception.Response) {
                    $statusCode = [int]$_.Exception.Response.StatusCode
                }
                # Discord returns 405 for GET on a valid webhook, which is expected
                if ($statusCode -eq 405) {
                    $webhookReachable = $true
                }
            }
            $results += Write-CheckResult -Check "Webhook reachability" -Passed $webhookReachable -Detail $(if ($webhookReachable) { "Discord endpoint responded" } else { "Could not reach webhook - check URL or network" })
        }
    }
}

# =========================
# Summary
# =========================
Write-Host ""
Write-Host "=== Precheck Summary ===" -ForegroundColor Cyan
$passCount = ($results | Where-Object { $_.Passed }).Count
$failCount = ($results | Where-Object { -not $_.Passed }).Count
Write-Host "Passed: $passCount  Failed: $failCount" -ForegroundColor $(if ($failCount -eq 0) { "Green" } else { "Yellow" })

if ($failCount -gt 0) {
    Write-Host "`nFix the failed checks before running AVD-Discord-Deploy-LogicApp.ps1." -ForegroundColor Yellow
}
else {
    Write-Host "`nAll checks passed. Ready to deploy." -ForegroundColor Green
}

try {
    $results | Export-Csv -Path $CsvPath -NoTypeInformation -Force
    Write-Host "Precheck report: $CsvPath" -ForegroundColor Gray
}
catch {
    Write-Warning "Failed to write precheck report: $($_.Exception.Message)"
}
