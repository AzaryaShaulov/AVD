# Azure Virtual Desktop (AVD) Management Scripts

**Last Updated:** March 2026

PowerShell automation tools for configuring diagnostics, monitoring, and alerting for Azure Virtual Desktop environments.

## What This Repository Covers

- Enable and standardize AVD diagnostic settings to Log Analytics
- Deploy consolidated AVD category alerts in Azure Monitor
- Optionally add detailed email notifications through a Logic App webhook

## Run Order (First, Second, Optional)

Run these in order for a full setup.

1. First: `AVD-Diagnostics/AVD-EnableDiagnosticLogs.ps1`
2. Second: `AVD-Alerts/Azure-AVD-Alerts.ps1`
3. Optional: `AVD-Alerts/Deploy-AVD-AlertWebhook-LogicApp-v2.ps1`
4. Optional validation: `AVD-Alerts/Send-AVD-Webhook-TestAlert.ps1`

## Script Flow Diagram

```mermaid
flowchart TD
    A[AVD-EnableDiagnosticLogs.ps1] --> B[Azure-AVD-Alerts.ps1]
    B --> C[Deploy-AVD-AlertWebhook-LogicApp-v2.ps1 optional]
    C --> D[Send-AVD-Webhook-TestAlert.ps1 optional]

    A1[Enable AVD diagnostics to Log Analytics] --- A
    B1[Create or update AVD-Category alerts and AVD-Alerts action group] --- B
    C1[Deploy AVD-alert-details Logic App and ensure AVD-Alerts-Detailed webhook action group] --- C
    C2[Ensure Office365 connection and assign Log Analytics Reader to Logic App MI] --- C
    D1[Post synthetic payload to callback URL for validation] --- D
```

## Execution Sequence

```mermaid
sequenceDiagram
  autonumber
  actor Eng as Engineer
  participant Diag as AVD-EnableDiagnosticLogs.ps1
  participant Alerts as Azure-AVD-Alerts.ps1
  participant Deploy as Deploy-AVD-AlertWebhook-LogicApp-v2.ps1
  participant Mon as Azure Monitor Scheduled Query Rules
  participant AG as AVD-Alerts-Detailed Action Group
  participant LA as Logic App AVD-alert-details
  participant LAW as Log Analytics Workspace
  participant O365 as Office365 Connector
  participant Test as Send-AVD-Webhook-TestAlert.ps1

  Eng->>Diag: Enable diagnostics on AVD resources
  Diag->>LAW: Route diagnostic logs to workspace

  Eng->>Alerts: Create or update AVD-Category alerts
  Alerts->>Mon: Configure scheduled query rules and action groups

  Eng->>Deploy: Optional detailed notifier deployment
  Deploy->>LA: Deploy or update workflow
  Deploy->>AG: Ensure webhook action group receiver
  Deploy->>LAW: Assign Log Analytics Reader to Logic App MI

  Mon->>AG: Fire webhook notification on alert match
  AG->>LA: Invoke callback URL with alert payload
  LA->>LAW: Query WVDErrors for alert window
  LAW-->>LA: Return results
  LA->>O365: Send detailed email

  Eng->>Test: Optional post-deploy validation
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

### 2) Deploy baseline AVD alerts

```powershell
cd ..\AVD-Alerts
pwsh -NoProfile -File .\Azure-AVD-Alerts.ps1 `
  -EmailTo "admin@contoso.com" `
  -ResourceGroup "YOUR-RG" `
  -LawName "YOUR-LAW-NAME" `
  -Location "eastus2"
```

### 3) Optional: Add detailed webhook email notifications

```powershell
pwsh -NoProfile -File .\Deploy-AVD-AlertWebhook-LogicApp-v2.ps1 `
  -SubscriptionId "YOUR-SUBSCRIPTION-ID" `
  -ResourceGroup "YOUR-RG" `
  -LogicAppName "AVD-alert-details" `
  -Location "eastus2" `
  -WorkspaceName "YOUR-LAW-NAME" `
  -WorkspaceResourceGroupName "YOUR-RG" `
  -SendFromEmail "alerts@contoso.com" `
  -SendToEmail "avd-oncall@contoso.com" `
  -Office365ConnectionName "avd-alerts-office365"
```

## Current Alert Model

The alerts script now deploys consolidated `AVD-Category-*` alerts with:

- Evaluation frequency: every 10 minutes
- Lookback window: 15 minutes
- Action groups: email baseline plus optional detailed webhook

See `AVD-Alerts/README.md` for full script details, RBAC, category breakdown, and examples.

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
