# Azure Virtual Desktop (AVD) Management Scripts

PowerShell automation tools for configuring comprehensive monitoring, diagnostics, and alerting for Azure Virtual Desktop environments.

## Scripts Overview

### 📊 [AVDDiagnostics](./AVDDiagnostics/)
Automatically discovers and configures diagnostic settings for all AVD resources (Host Pools, Application Groups, Workspaces) to send logs and metrics to a Log Analytics workspace. Enables all available log categories individually for comprehensive logging coverage across your entire AVD environment.

### 🔔 [AVD-Alerts](./AVD-Alerts/)
Creates 20 pre-configured Azure Monitor scheduled query alerts that monitor critical AVD connection, authentication, and resource issues with 5-minute evaluation frequency. Features parallel processing (PowerShell 7+) for fast execution, proper WhatIf support for safe testing, and multi-subscription targeting. Sends email notifications through Azure Monitor Action Groups when problems are detected, enabling rapid incident response.

**Version 2.1** - Critical bug fixes for WhatIf functionality and improved performance with 77% speed improvement through parallel processing.

## Why Enable Diagnostics and Alerts?

**Diagnostic settings are not enabled by default** on AVD resources, leaving critical operational data uncollected. Enabling diagnostics captures essential telemetry about user connections, authentication failures, session host health, and performance metrics—data that's **required for effective troubleshooting and proactive monitoring**. Without diagnostic logs, identifying the root cause of user connection failures, performance degradation, or resource availability issues becomes extremely difficult or impossible.

**Azure Monitor alerts provide real-time notifications** when critical issues occur, such as failed authentications, no healthy session hosts available, or out-of-memory conditions. Early detection enables IT teams to resolve problems before they impact a large number of users, reducing downtime and maintaining service quality. Combined with diagnostic logs, alerts transform AVD from a reactive "fix-it-when-it-breaks" model to a proactive monitoring and incident response system.

These scripts **support and enable the Azure Virtual Desktop | Insights workbook**, Microsoft's official monitoring solution for AVD. The Insights workbook requires diagnostic settings to be configured on all AVD resources to populate its dashboards with connection diagnostics, performance data, user session analytics, and capacity planning metrics.

## Prerequisites

- **Azure CLI** 2.50.0 or later ([Installation Guide](https://learn.microsoft.com/cli/azure/install-azure-cli))
- **PowerShell** 5.1 or later
- **Azure Permissions:**
  - Monitoring Contributor role (for diagnostics and alerts)
  - Reader role on AVD resources
- **Log Analytics Workspace** (existing or create new)

## Quick Start

### 1. Enable Diagnostic Settings
```powershell
cd AVDDiagnostics
.\AVD-EnableDiagnosticLogs.ps1 -SubscriptionId "YOUR-SUBSCRIPTION-ID" -WorkspaceName "YOUR-LAW-NAME"
```

### 2. Create AVD Alerts
```powershell
cd AVD-Alerts
.\Azure-AVD-Alerts.ps1 -EmailTo "admin@contoso.com" -ResourceGroup "YOUR-RG" -LawName "YOUR-LAW-NAME" -Location "eastus2"
```

## Documentation

Each script includes comprehensive documentation:
- [AVDDiagnostics README](./AVDDiagnostics/README.md) - Diagnostic settings configuration details
- [AVD-Alerts README](./AVD-Alerts/README.md) - Alert configuration and complete alert reference (v2.1)

## Related Resources

- [Azure Virtual Desktop Documentation](https://learn.microsoft.com/azure/virtual-desktop/)
- [Monitor AVD with Azure Monitor](https://learn.microsoft.com/azure/virtual-desktop/monitor-azure-virtual-desktop)
- [AVD Insights Workbook](https://learn.microsoft.com/azure/virtual-desktop/insights)
- [AVD Diagnostics with Log Analytics](https://learn.microsoft.com/azure/virtual-desktop/diagnostics-log-analytics)

## License

See [LICENSE](./LICENSE) file for details.

## Disclaimer

**THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED.**

This collection of scripts is provided as-is under the MIT License. The authors and contributors make no warranties or guarantees about functionality, reliability, or suitability. Always test in non-production environments before deploying to production systems. See individual script READMEs for detailed disclaimers and warnings.

## Contributing

Contributions are welcome! Please feel free to submit issues or pull requests.
