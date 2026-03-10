# Azure Virtual Desktop (AVD) Management Scripts

PowerShell automation tools for configuring diagnostics, monitoring, and alerting for Azure Virtual Desktop environments.

## What This Repository Covers

- Enable and standardize AVD diagnostic settings to Log Analytics
- Deploy consolidated AVD category alerts in Azure Monitor
- Optionally add detailed email notifications through a Logic App webhook
- Optionally add Teams notifications through a dedicated Teams notifier flow

## Run Order (First, Second, Optional)

Run these in order for a full setup.

1. First: `AVD-Diagnostics/AVD-EnableDiagnosticLogs.ps1`
2. Second: `AVD-Alerts/Azure-AVD-Alerts.ps1`
3. Optional: `AVD-Alerts/Deploy-AVD-AlertWebhook-LogicApp.ps1`
4. Optional: `AVD-Alerts/Deploy-AVD-Teams-Notifier.ps1`
5. Optional validation: `AVD-Alerts/Send-AVD-Webhook-TestAlert.ps1`

## Script Flow Diagram (Plain Text)

```text
[First] AVD-Diagnostics/AVD-EnableDiagnosticLogs.ps1
    |
    |  Enables diagnostic settings on AVD resources
    |  and sends logs to Log Analytics
    v
[Second] AVD-Alerts/Azure-AVD-Alerts.ps1
    |
    |  Creates/maintains AVD-Category-* alerts
    |  and primary email action group (AVD-Alerts)
    v
[Optional] Deploy-AVD-AlertWebhook-LogicApp.ps1
    |
    |-- Deploys la-avd-alerts-detailed
    |-- Ensures AVD-Alerts-Detailed webhook action group
    |-- Optional: auto-wires existing alerts
    v
[Optional] Deploy-AVD-Teams-Notifier.ps1
    |
    |-- Deploys la-avd-alerts-teams
    |-- Ensures AVD-Alerts-Teams action group
    |-- Optional: attaches Teams AG to existing alerts
    v
[Optional] Send-AVD-Webhook-TestAlert.ps1
       Sends synthetic test payload to validate webhook path
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
pwsh -NoProfile -File .\Deploy-AVD-AlertWebhook-LogicApp.ps1 `
  -ResourceGroup "YOUR-RG" `
  -Location "eastus2" `
  -SendFromEmail "alerts@contoso.com" `
  -SendToEmail "avd-oncall@contoso.com"
```

### 4) Optional: Add Teams notifications

```powershell
pwsh -NoProfile -File .\Deploy-AVD-Teams-Notifier.ps1 `
  -ResourceGroup "YOUR-RG" `
  -Location "eastus2" `
  -TeamsWebhookUrl "https://outlook.office.com/webhook/..."
```

## Current Alert Model

The alerts script now deploys consolidated `AVD-Category-*` alerts with:

- Evaluation frequency: every 10 minutes
- Lookback window: 15 minutes
- Action groups: email baseline plus optional detailed webhook and Teams

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
