<#
==============================================================================
SCRIPT VERSION: 1.0
LAST UPDATED: March 29, 2026
REPOSITORY: https://github.com/AzaryaShaulov/AVD
DISCLAIMER: This script is provided AS IS, without warranties or support guarantees.
==============================================================================
.SYNOPSIS
    Sends a test Common Alert Schema payload to the AVD Discord Logic App.

.DESCRIPTION
    Posts a realistic Azure Monitor Common Alert Schema payload to the
    Logic App callback URL and reports the response. Use this to verify
    that the Logic App is deployed and the Discord webhook is working.

.PARAMETER CallbackUrl
    The Logic App HTTP trigger callback URL (contains SAS token).
    If omitted, the script retrieves it from the deployed Logic App.

.PARAMETER SubscriptionId
    Azure subscription ID (used to retrieve callback URL when not provided directly).

.PARAMETER ResourceGroupName
    Resource group containing the Logic App.

.PARAMETER LogicAppName
    Name of the deployed Logic App.

.PARAMETER PayloadPath
    Path to a JSON file to use as the test payload.
    Defaults to test-payload.json in the script directory.

.EXAMPLE
    .\AVD-Discord-TestAlert.ps1 -CallbackUrl "https://prod-xx.eastus2.logic.azure.com/..."

.EXAMPLE
    .\AVD-Discord-TestAlert.ps1 `
      -SubscriptionId "YOUR-SUB-ID" `
      -ResourceGroupName "rg-avd-monitoring" `
      -LogicAppName "AVD-Discord-Notifier"
#>

[CmdletBinding()]
param(
    [string]$CallbackUrl = "",

    [string]$SubscriptionId = "",

    [string]$ResourceGroupName = "",

    [string]$LogicAppName = "",

    [string]$PayloadPath = ""
)

$ErrorActionPreference = "Stop"

function Write-Step {
    param([string]$Message)
    Write-Host "`n=== $Message ===" -ForegroundColor Cyan
}

# =========================
# Resolve Callback URL
# =========================
if ([string]::IsNullOrWhiteSpace($CallbackUrl)) {
    Write-Step "Retrieving callback URL from deployed Logic App"

    if ([string]::IsNullOrWhiteSpace($SubscriptionId) -or
        [string]::IsNullOrWhiteSpace($ResourceGroupName) -or
        [string]::IsNullOrWhiteSpace($LogicAppName)) {
        throw "Provide either -CallbackUrl directly, or -SubscriptionId, -ResourceGroupName, and -LogicAppName to retrieve it."
    }

    & az account set --subscription $SubscriptionId 2>$null
    if ($LASTEXITCODE -ne 0) { throw "Failed to set subscription $SubscriptionId" }

    $workflowResourceId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Logic/workflows/$LogicAppName"
    $result = & az rest `
        --method post `
        --uri "$workflowResourceId/triggers/When_an_HTTP_request_is_received/listCallbackUrl?api-version=2019-05-01" `
        --body "{}" `
        --query "value" `
        -o tsv 2>&1

    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace(($result | Out-String).Trim())) {
        throw "Failed to retrieve callback URL from Logic App '$LogicAppName'.`n$result"
    }

    $CallbackUrl = ($result | Out-String).Trim()
    Write-Host "Callback URL retrieved." -ForegroundColor Gray
}

# =========================
# Load Test Payload
# =========================
Write-Step "Loading test payload"
if ([string]::IsNullOrWhiteSpace($PayloadPath)) {
    $PayloadPath = Join-Path $PSScriptRoot "test-payload.json"
}

if (-not (Test-Path -Path $PayloadPath)) {
    throw "Test payload file not found: $PayloadPath"
}

$payload = Get-Content -Raw -Path $PayloadPath

# Validate JSON
try {
    $null = $payload | ConvertFrom-Json
}
catch {
    throw "Test payload is not valid JSON: $($_.Exception.Message)"
}

Write-Host "Loaded: $PayloadPath" -ForegroundColor Gray

# =========================
# Send Test
# =========================
Write-Step "Sending test payload to Logic App"
try {
    $response = Invoke-RestMethod `
        -Uri $CallbackUrl `
        -Method POST `
        -ContentType "application/json" `
        -Body $payload `
        -ErrorAction Stop

    Write-Host "Response:" -ForegroundColor Green
    $response | ConvertTo-Json -Depth 5 | Write-Host
}
catch {
    $statusCode = $null
    $responseBody = $null
    if ($_.Exception.Response) {
        $statusCode = [int]$_.Exception.Response.StatusCode
        try {
            $reader = [System.IO.StreamReader]::new($_.Exception.Response.GetResponseStream())
            $responseBody = $reader.ReadToEnd()
            $reader.Close()
        }
        catch { }
    }

    if ($statusCode) {
        Write-Host "HTTP $statusCode" -ForegroundColor Red
        if ($responseBody) { Write-Host $responseBody -ForegroundColor Red }
    }
    else {
        Write-Host "Request failed: $($_.Exception.Message)" -ForegroundColor Red
    }
    throw
}

Write-Host "`nTest complete. Check your Discord channel for the message." -ForegroundColor Green
