# AVD Diagnostics Configuration Tool

## Overview

Ideally, the Azure Virtual Desktop Configuration Workbook, a built-in tool in Azure Virtual Desktop, should be used to validate and configure the monitoring setup required for Azure Virtual Desktop Insights, including diagnostic settings, data collection rules, and Log Analytics integration.

Alternatively, the AVD Diagnostics Configuration script can be used to programmatically locate all host pools, application groups, and workspaces within a subscription and enable the required diagnostic settings to collect logs in a single operation.

The AVD Diagnostics Configuration script **enables diagnostic settings** for the following Azure Virtual Desktop resource types:

- Microsoft.DesktopVirtualization/hostPools
- Microsoft.DesktopVirtualization/applicationGroups
- Microsoft.DesktopVirtualization/workspaces

This ensures that telemetry and operational logs are sent to Log Analytics, allowing administrators to monitor Azure Virtual Desktop environment health, performance, and user experience.

This configuration script *does not enable* Azure Monitor Insights or deploy the AMA agent or a Data Collection Rule (DCR) required to capture *host-level performance metrics*.

## Purpose

Azure Virtual Desktop generates diagnostic logs that are **critical for monitoring, troubleshooting, and maintaining a healthy AVD environment**. However, diagnostic settings are **not enabled by default** on AVD resources. This script automates the configuration process across all your AVD resources (Host Pools, Application Groups, and Workspaces), ensuring consistent logging coverage.

**Key Goals:**
- **Automate** diagnostic settings configuration across all AVD resources
- **Standardize** logging configuration using best practices (allLogs category)
- **Eliminate** manual configuration overhead and human error
- **Ensure** comprehensive visibility into your AVD environment

## Prerequisites

- Azure CLI installed ([Install guide](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli))
- Azure account with **Monitoring Contributor** permissions
- PowerShell 5.1 or later
- Active Azure subscription with AVD resources

## Best Practice Checklist

Before running this script, ensure:

> <strong><span style="color:#b00020;">Attention:</span></strong> <span style="color:#2e7d32;font-weight:700;">Set the diagnostic settings to send data to the same Log Analytics workspace used by Nerdio, if one is deployed.</span>

- [ ] Log Analytics workspace exists and is properly sized
- [ ] You have Monitoring Contributor permissions on AVD resources
- [ ] Azure CLI is installed and you're logged in (`az login`)
- [ ] You've reviewed your workspace retention policy
- [ ] You've planned for log ingestion costs
- [ ] You have a strategy for log queries and alerting (see AVD-Alerts script)

## Why Enable Diagnostic Logs? (Best Practices)

Enabling diagnostic logs for Azure Virtual Desktop is considered a **critical best practice** for the following reasons:

| Best Practice | Benefits |
|---------------|----------|
| **Proactive Monitoring & Alerting** | • Detect issues before users report them<br>• Create alerts for failed connections, agent health problems, or resource errors<br>• Monitor session host registration failures in real-time<br>• Track authentication and authorization failures |
| **Troubleshooting & Root Cause Analysis** | • Investigate user connection failures with detailed error codes<br>• Trace the complete user journey from connection attempt to session establishment<br>• Correlate events across Host Pools, Application Groups, and Workspaces<br>• Analyze patterns in failures to identify systemic issues |
| **Security & Compliance** | • Audit administrative changes to AVD resources<br>• Track user access patterns for security analysis<br>• Meet compliance requirements for logging and retention (HIPAA, PCI-DSS, SOC 2)<br>• Detect anomalous connection patterns or potential security threats |
| **Performance Optimization** | • Identify resource bottlenecks and capacity issues<br>• Analyze connection latency and performance metrics<br>• Track session host utilization patterns<br>• Optimize scaling decisions based on historical data |
| **Capacity Planning** | • Understand usage trends over time<br>• Plan for growth based on connection patterns<br>• Right-size your AVD deployment<br>• Forecast infrastructure needs |
| **Cost Management** | • Track resource utilization to identify underutilized resources<br>• Correlate costs with usage patterns<br>• Optimize VM sizing and scaling policies |
| **Azure Monitor Integration** | • Build comprehensive dashboards with AVD metrics<br>• Integrate with Azure Monitor Workbooks for visualization<br>• Create automated remediation workflows<br>• Export data to SIEM systems for enterprise-wide monitoring |
| **Microsoft Support Requirements** | • Microsoft Support often requires diagnostic logs for troubleshooting<br>• Proactive logging accelerates support case resolution<br>• Historical data helps identify intermittent issues |

## Script Reference

| Script | Purpose | What It Does | Quick Start (copy & paste) |
| ------ | ------- | ------------ | -------------------------- |
| `AVD-Enable-Diagnostic-Logs.ps1` | Enable AVD diagnostic logs to Log Analytics | Discovers all host pools, application groups, and workspaces in a subscription. Configures `allLogs` diagnostic settings to route telemetry to a Log Analytics workspace. Verifies settings after applying and exports results to CSV. | `.\AVD-Enable-Diagnostic-Logs.ps1 -SubscriptionId "YOUR-SUB-ID" -WorkspaceName "YOUR-LAW" -WorkspaceResourceGroupName "YOUR-LAW-RG"` |

**Additional modes:**

| Mode | Command |
| ---- | ------- |
| Check only (read-only audit) | `.\AVD-Enable-Diagnostic-Logs.ps1 -SubscriptionId "YOUR-SUB-ID" -CheckOnly` |
| Custom workspace | `.\AVD-Enable-Diagnostic-Logs.ps1 -SubscriptionId "YOUR-SUB-ID" -WorkspaceName "MyLAW" -WorkspaceResourceGroupName "rg-law"` |
| Custom CSV export | `.\AVD-Enable-Diagnostic-Logs.ps1 -SubscriptionId "YOUR-SUB-ID" -CsvPath "C:\Reports\diag-status.csv"` |

## Features

- 🔍 **Auto-discovery** of AVD resources (Host Pools, Application Groups, Workspaces)
- 📊 **Enforces allLogs** category group for comprehensive diagnostic coverage
- ✅ **Verification** of settings after configuration
- 📋 **Check-only mode** to review current status without making changes
- 📄 **CSV export** of configuration results
- 🛡️ **Error handling** with detailed status reporting

## Quick Start

1. **Login to Azure:**
   ```powershell
   az login
   ```

2. **Run the script:**
   ```powershell
   .\AVD-Enable-Diagnostic-Logs.ps1 -SubscriptionId "YOUR-SUBSCRIPTION-ID"
   ```

## Parameters

| Parameter | Required | Type | Default | Description |
|-----------|----------|------|---------|-------------|
| `-SubscriptionId` | **Yes** | `string` | — | Azure subscription ID (GUID format) |
| `-WorkspaceName` | No | `string` | `AVD-LAW` | Log Analytics workspace name |
| `-WorkspaceResourceGroupName` | No | `string` | `rg-avd-monitoring` | Resource group containing the workspace. Alias: `-WorkspaceResourceGroup` |
| `-DiagnosticSettingName` | No | `string` | `AVD-Diagnostics` | Name for diagnostic settings created on each resource |
| `-CsvPath` | No | `string` | `avd-diagnostics-minimal.csv` (script directory) | Output path for CSV status report |
| `-CheckOnly` | No | `switch` | Off | Read-only mode — displays current diagnostic settings status without making any changes |

## Usage Examples

### Starter 1 — Custom Workspace + CSV Report
Target a specific Log Analytics workspace and write the report to a custom path:
```powershell
.\AVD-Enable-Diagnostic-Logs.ps1 `
    -SubscriptionId "YOUR-SUBSCRIPTION-ID" `
    -WorkspaceName "AVD-LogAnalytics" `
    -WorkspaceResourceGroupName "rg-az-west2-avd-nonprod" `
    -CsvPath "C:\Reports\avd-diagnostics-status.csv"
```

### Starter 2 — Check-Only Audit
Review current diagnostic settings status without making any changes:
```powershell
.\AVD-Enable-Diagnostic-Logs.ps1 `
    -SubscriptionId "YOUR-SUBSCRIPTION-ID" `
    -CheckOnly
```
Output shows per-resource status: `Enabled (allLogs)`, `Enabled (not allLogs)`, `Not Configured`, or `Disabled`.

## Output

| Output Type | Details |
|---|---|
| **Console Output** | Color-coded status per resource: 🟢 Success · 🟡 Skipped/Warning · 🔴 Error |
| **CSV Report** | Exported to `CsvPath`; includes resource name & type, configuration status, actions taken, errors |
| **Summary Statistics** | Totals for: resources found, successfully configured, skipped (already configured), failed |

## Troubleshooting

| Error / Issue | Resolution |
|---|---|
| `Failed to set subscription` | Run `az login` to authenticate before executing the script |
| `Log Analytics Workspace not found` | Verify `-WorkspaceName` and `-WorkspaceResourceGroupName` parameter values |
| `Conflict detected` | A duplicate diagnostic setting exists for the same workspace — remove it or use a different `-DiagnosticSettingName` |
| Permission errors | Ensure your account has **Monitoring Contributor** on the AVD resources and the Log Analytics workspace |

## Resource Types Supported

- `Microsoft.DesktopVirtualization/hostPools`
- `Microsoft.DesktopVirtualization/applicationGroups`
- `Microsoft.DesktopVirtualization/workspaces`

## Additional Resources

| Category | Resource | Description |
|---|---|---|
| Microsoft Docs | [AVD Diagnostics Overview](https://learn.microsoft.com/en-us/azure/virtual-desktop/diagnostics-log-analytics) | Official diagnostics & Log Analytics guide |
| Microsoft Docs | [Azure Monitor Diagnostic Settings](https://learn.microsoft.com/en-us/azure/azure-monitor/essentials/diagnostic-settings) | Diagnostic settings reference |
| Microsoft Docs | [AVD Required URLs](https://learn.microsoft.com/en-us/azure/virtual-desktop/safe-url-list) | Firewall & network requirements |
| This Repo | [AVD Alerts Script](../AVD-AzAlerts/) | Automated alerting for AVD error conditions |
| This Repo | [AVD Session Host Monitoring](../AVD-SessionHostMonitoring/) | DCR-based performance counter collection |
| Azure | [AVD Insights Workbook](https://learn.microsoft.com/en-us/azure/virtual-desktop/insights) | Built-in Azure Monitor workbook for AVD |
| Community | [AVD Tech Community](https://techcommunity.microsoft.com/t5/azure-virtual-desktop/bd-p/AzureVirtualDesktopForum) | Microsoft Tech Community forum |
| Community | [AVD GitHub Samples](https://github.com/Azure/RDS-Templates/tree/master/wvd-templates) | Official ARM/Bicep deployment templates |

## Version

**Version:** 1.2  
**Last Updated:** March 2026

## License

See [LICENSE](../LICENSE) file for details.

## Disclaimer

**THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED.**

This script is provided as-is under the MIT License. The authors and contributors:

- **Make no warranties or guarantees** about the functionality, reliability, or suitability of this script for any purpose
- **Accept no responsibility or liability** for any damages, data loss, service interruptions, or other issues arising from the use of this script
- **Provide no support or maintenance** obligations, though community contributions are welcome
- **Recommend thorough testing** in a non-production environment before deploying to production systems

### Important Notes:

- ⚠️ **Test First**: Always test in a development/staging environment before running in production
- ⚠️ **Backup**: Ensure you have appropriate backups and rollback procedures
- ⚠️ **Permissions**: Review required Azure RBAC permissions before execution
- ⚠️ **Costs**: Understand Azure Monitor and Log Analytics pricing before enabling diagnostics at scale
- ⚠️ **Compliance**: Verify this solution meets your organization's security and compliance requirements

**By using this script, you acknowledge and accept these terms and assume all risks associated with its use.**
