# Azure Virtual Desktop (AVD) Management Scripts

**Last Updated:** March 2026

PowerShell automation tools for configuring diagnostics, monitoring, and alerting for Azure Virtual Desktop environments.

## What This Repository Covers

- Enable and standardize AVD diagnostic settings to Log Analytics
- Deploy consolidated AVD category alerts in Azure Monitor
- Deploy rich webhook-based detailed notifications through a Logic App

## Run Order

1. First: `AVD-Diagnostics/AVD-EnableDiagnosticLogs.ps1`
2. Preferred deployment path (Option 1): `AVD-Alerts/Deploy-AVD-AlertWebhook-LogicApp-v2.ps1`
3. Alternative deployment path (Option 2): `AVD-Alerts/Azure-AVD-Alerts.ps1`, then `AVD-Alerts/Deploy-AVD-AlertWebhook-LogicApp-v2.ps1`
4. Optional validation: `AVD-Alerts/Send-AVD-Webhook-TestAlert.ps1`

## Script Flow Diagram

```mermaid
flowchart TD
  A[AVD-EnableDiagnosticLogs.ps1] --> O1[Option 1: Deploy-AVD-AlertWebhook-LogicApp-v2.ps1]
  A --> O2A[Option 2 Step 1: Azure-AVD-Alerts.ps1]
  O2A --> O2B[Option 2 Step 2: Deploy-AVD-AlertWebhook-LogicApp-v2.ps1]

  O1 --> D[Send-AVD-Webhook-TestAlert.ps1 optional]
  O2B --> D

  A1[Enable AVD diagnostics to Log Analytics] --- A
  O1A[Deploy Logic App + detailed action group, bootstrap missing alerts, enforce detailed-only routing] --- O1
  O2A1[Create native AVD-Category alerts] --- O2A
  O2B1[Add webhook-based rich alerts and cutover to detailed-only routing] --- O2B
  D1[Post synthetic payload to callback URL for validation] --- D
```

## Execution Sequence

```mermaid
sequenceDiagram
  autonumber
  actor Eng as Engineer
  participant Diag as AVD-EnableDiagnosticLogs
  participant Deploy as Deploy-Webhook
  participant Alerts as Azure-AVD-Alerts
  participant Mon as Scheduled Query Alerts
  participant AG as Detailed Action Group
  participant LA as Logic App
  participant LAW as Log Analytics
  participant O365 as O365 Connector
  participant Test as Webhook Test Script

  Eng->>Diag: Enable AVD diagnostics
  Diag->>LAW: Route diagnostic logs to workspace

  rect rgb(236, 248, 255)
  Note over Eng,Deploy: Option 1 (recommended): webhook-first
  Eng->>Deploy: Run webhook deployment
  Deploy->>LA: Deploy or update workflow
  Deploy->>AG: Ensure webhook receiver
  Deploy->>LAW: Grant LA Reader to Logic App MI
  Deploy->>Mon: Check AVD-Category alerts
  alt Missing category alerts
    Deploy->>Alerts: Bootstrap missing alerts
    Alerts->>Mon: Create missing AVD-Category rules
  end
  Deploy->>Mon: Route to Detailed action group only
  end

  rect rgb(245, 255, 245)
  Note over Eng,Deploy: Option 2: native first, then cutover
  Eng->>Alerts: Create native AVD-Category alerts
  Alerts->>Mon: Configure native alert rules
  Eng->>Deploy: Later run webhook cutover
  Deploy->>Mon: Switch to Detailed action group only
  end

  Mon->>AG: Fire webhook on alert match
  AG->>LA: Invoke callback URL with alert payload
  LA->>LAW: Query WVDErrors for alert period
  LAW-->>LA: Return results
  LA->>O365: Send detailed email

  Eng->>Test: Optional validation
  Test->>LA: Post synthetic payload to callback URL
```

## Critical Prerequisites

- Azure CLI installed and authenticated (`az login`)
- Required Azure RBAC on target resource groups
- PowerShell 7 (`pwsh`) recommended for best compatibility and parallel processing

### Important: Diagnostics Must Be Enabled First

Run `AVD-Diagnostics/AVD-EnableDiagnosticLogs.ps1` before deploying alerts unless diagnostics are already enabled on AVD resources.

Without diagnostic logs in Log Analytics, alert queries do not have data to evaluate.

### Important: `LawName` (Log Analytics Workspace) Guidance

For `AVD-Alerts/Azure-AVD-Alerts.ps1`, `-LawName` is the Log Analytics workspace name used by alert queries.

If there is already an existing AVD Log Analytics workspace (including Nerdio-managed environments), reuse it.

- Set `-ResourceGroup` to the workspace resource group
- Set `-LawName` to that existing workspace name

Do not create a new workspace unless needed.

## Quick Start

### 1) Enable AVD diagnostics first

```powershell
cd AVD-Diagnostics
pwsh -NoProfile -File .\AVD-EnableDiagnosticLogs.ps1 `
  -SubscriptionId "YOUR-SUBSCRIPTION-ID" `
  -WorkspaceName "YOUR-LAW-NAME"
```

### 2) Alerts and Webhook Deployment Options

#### Option 1 (Recommended): Rich Alerts via Webhook + Logic App (Single Script)

This option deploys webhook infrastructure, bootstraps missing `AVD-Category-*` alerts if needed, and applies detailed-only routing.

```powershell
cd ..\AVD-Alerts
pwsh -NoProfile -File .\Deploy-AVD-AlertWebhook-LogicApp-v2.ps1 `
  -SubscriptionId "YOUR-SUBSCRIPTION-ID" `
  -ResourceGroupName "YOUR-ALERTS-RG" `
  -LogicAppName "AVD-alert-details" `
  -Location "eastus2" `
  -WorkspaceName "YOUR-LAW-NAME" `
  -WorkspaceResourceGroupName "YOUR-LAW-RG" `
  -SendFromEmail "alerts@contoso.com" `
  -SendToEmails @("avd-oncall@contoso.com", "avd-manager@contoso.com") `
  -Office365ConnectionName "avd-alerts-office365"
```

ATTENTION: Authorize `avd-alerts-office365` (or your chosen `-Office365ConnectionName`) in Azure Portal with valid mailbox credentials before expecting detailed emails.

#### Option 2: Native Alerts First, Then Add Webhook-Based Rich Alerts

Step 1: Deploy native alerts.

```powershell
pwsh -NoProfile -File .\Azure-AVD-Alerts.ps1 `
  -EmailTo "admin@contoso.com" `
  -ResourceGroup "YOUR-ALERTS-RG" `
  -LawName "YOUR-LAW-NAME" `
  -Location "eastus2"
```

Step 2: Add webhook-based rich alerts and cutover.

```powershell
pwsh -NoProfile -File .\Deploy-AVD-AlertWebhook-LogicApp-v2.ps1 `
  -SubscriptionId "YOUR-SUBSCRIPTION-ID" `
  -ResourceGroupName "YOUR-ALERTS-RG" `
  -LogicAppName "AVD-alert-details" `
  -Location "eastus2" `
  -WorkspaceName "YOUR-LAW-NAME" `
  -WorkspaceResourceGroupName "YOUR-LAW-RG" `
  -SendFromEmail "alerts@contoso.com" `
  -SendToEmails @("avd-oncall@contoso.com", "avd-manager@contoso.com") `
  -Office365ConnectionName "avd-alerts-office365"
```

## Current Alert Model

The current model supports two deployment paths:

- Option 1 (recommended): webhook-first single script with bootstrap + detailed-only routing
- Option 2: native alerts first, then webhook-based rich alerts

See `AVD-Alerts/README.md` for full script details, RBAC, category breakdown, and end-to-end examples.

## Documentation

- `AVD-Diagnostics/README.md`
- `AVD-Alerts/README.md`

## Related Resources

- Azure Virtual Desktop documentation: https://learn.microsoft.com/azure/virtual-desktop/
- Monitor AVD with Azure Monitor: https://learn.microsoft.com/azure/virtual-desktop/monitor-azure-virtual-desktop
- AVD Insights workbook: https://learn.microsoft.com/azure/virtual-desktop/insights

## License

See `LICENSE` for details.

## Disclaimer

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED.

These scripts are provided as-is under the MIT License. Always validate in a non-production environment before production rollout.
