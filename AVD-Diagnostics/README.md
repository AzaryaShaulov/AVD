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

## What Are AVD Diagnostic Logs?

Azure Virtual Desktop diagnostic logs capture detailed telemetry about your AVD environment's operations, performance, and user activities. These logs are stored in Log Analytics workspaces where they can be queried, analyzed, and used for alerting.

### Critical Log Categories

| Resource Type | Log Category | Description |
|---|---|---|
| Host Pool | `HostRegistration` | Session host registration events and health status changes |
| Host Pool | `Connection` | User connection attempts, successes, and failures |
| Host Pool | `Error` | Errors occurring at the host pool level |
| Host Pool | `Checkpoint` | Lifecycle events and state transitions |
| Host Pool | `Management` | Administrative operations and configuration changes |
| Host Pool | `AgentHealthStatus` | AVD agent health monitoring |
| Application Group | `Checkpoint` | Application group lifecycle events |
| Application Group | `Error` | Application-specific errors |
| Application Group | `Management` | Application group configuration changes |
| Workspace | `Checkpoint` | Workspace lifecycle events |
| Workspace | `Error` | Workspace-level errors |
| Workspace | `Management` | Workspace configuration changes |
| Workspace | `Feed` | User feed subscription activities |

### Real-World Use Cases

| Scenario | Log Table | Purpose |
|---|---|---|
| Troubleshooting Connection Issues | `WVDConnections` | Identify failed user connections in the last 24 hours |
| Monitoring Agent Health | `WVDAgentHealthStatus` | Detect session hosts in a non-Available state |
| Tracking User Sessions | `WVDConnections` | Summarize active sessions per user over the last 7 days |

**Troubleshooting Connection Issues:**
```kusto
WVDConnections
| where TimeGenerated > ago(24h)
| where State == "Failed"
| project TimeGenerated, UserName, ClientOS, ClientType, CorrelationId, Message
```

**Monitoring Agent Health:**
```kusto
WVDAgentHealthStatus
| where TimeGenerated > ago(1h)
| where Status != "Available"
| summarize count() by SessionHostName, Status
```

**Tracking User Sessions:**
```kusto
WVDConnections
| where TimeGenerated > ago(7d)
| where State == "Connected"
| summarize Sessions = count() by UserName, ClientOS
| order by Sessions desc
```

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

## Features

- 🔍 **Auto-discovery** of AVD resources (Host Pools, Application Groups, Workspaces)
- 📊 **Enforces allLogs** category group for comprehensive diagnostic coverage
- ✅ **Verification** of settings after configuration
- 📋 **Check-only mode** to review current status without making changes
- 📄 **CSV export** of configuration results
- 🛡️ **Error handling** with detailed status reporting

## Prerequisites

- Azure CLI installed ([Install guide](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli))
- Azure account with **Monitoring Contributor** permissions
- PowerShell 5.1 or later
- Active Azure subscription with AVD resources

## Quick Start
## Best Practice Checklist

Before running this script, ensure:
- [ ] Log Analytics workspace exists and is properly sized
- [ ] You have Monitoring Contributor permissions on AVD resources
- [ ] Azure CLI is installed and you're logged in (`az login`)
- [ ] You've reviewed your workspace retention policy
- [ ] You've planned for log ingestion costs
- [ ] You have a strategy for log queries and alerting (see AVD-Alerts script)

1. **Login to Azure:**
   ```powershell
   az login
   ```

2. **Run the script:**
   ```powershell
   .\AVD-EnableDiagnosticLogs.ps1 -SubscriptionId "YOUR-SUBSCRIPTION-ID"
   ```

## Parameters

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `SubscriptionId` | **Yes** | — | Azure subscription ID |
| `WorkspaceName` | No | `AVD-LAW` | Log Analytics workspace name |
| `WorkspaceResourceGroup` | No | `az-infra-eus2` | Resource group containing the workspace |
| `DiagnosticSettingName` | No | `AVD-Diagnostics` | Name for diagnostic settings |
| `CsvPath` | No | `avd-diagnostics-minimal.csv` (script directory) | Path for CSV export |
| `CheckOnly` | No | (switch) | Check status without making changes |

## Usage Examples

### Check Current Status
Review diagnostic settings without making any changes:
```powershell
.\AVD-EnableDiagnosticLogs.ps1 -SubscriptionId "YOUR-SUBSCRIPTION-ID" -CheckOnly
```

### Configure with Custom Workspace
Apply diagnostic settings using a specific Log Analytics workspace:
```powershell
.\AVD-EnableDiagnosticLogs.ps1 `
    -SubscriptionId "YOUR-SUBSCRIPTION-ID" `
    -WorkspaceName "MyCustomLAW" `
    -WorkspaceResourceGroup "MyResourceGroup"
```

### Run with Default Settings
Use default workspace values:
```powershell
.\AVD-EnableDiagnosticLogs.ps1 -SubscriptionId "YOUR-SUBSCRIPTION-ID"
```

## Output

| Output Type | Details |
|---|---|
| **Console Output** | Color-coded status per resource: 🟢 Success · 🟡 Skipped/Warning · 🔴 Error |
| **CSV Report** | Exported to `CsvPath`; includes resource name & type, configuration status, actions taken, errors |
| **Summary Statistics** | Totals for: resources found, successfully configured, skipped (already configured), failed |

## Status Indicators

| Status | Meaning |
|--------|---------|
| `Enabled (allLogs)` | Configured with comprehensive logging |
| `Enabled (not allLogs)` | Configured but not using allLogs category |
| `Not Configured` | No diagnostic settings exist |
| `Disabled` | Diagnostic settings exist but are disabled |

## Troubleshooting

| Error / Issue | Resolution |
|---|---|
| `Failed to set subscription` | Run `az login` to authenticate before executing the script |
| `Log Analytics Workspace not found` | Verify `-WorkspaceName` and `-WorkspaceResourceGroup` parameter values |
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
| This Repo | [AVD Alerts Script](../AVD-Alerts/) | Automated alerting for AVD error conditions |
| This Repo | [AVD Session Host Monitoring](../AVD-SessionHostMonitoring/) | DCR-based performance counter collection |
| Azure | [AVD Insights Workbook](https://learn.microsoft.com/en-us/azure/virtual-desktop/insights) | Built-in Azure Monitor workbook for AVD |
| Community | [AVD Tech Community](https://techcommunity.microsoft.com/t5/azure-virtual-desktop/bd-p/AzureVirtualDesktopForum) | Microsoft Tech Community forum |
| Community | [AVD GitHub Samples](https://github.com/Azure/RDS-Templates/tree/master/wvd-templates) | Official ARM/Bicep deployment templates |

## Version

**Version:** 1.2  
**Last Updated:** February 2026

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
