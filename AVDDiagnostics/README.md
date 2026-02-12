# AVD Diagnostics Configuration Tool

A PowerShell script to automatically configure Azure Monitor diagnostic settings for Azure Virtual Desktop (AVD) resources.

## Overview

This tool discovers AVD resources in your Azure subscription and configures diagnostic settings to send logs and metrics to a Log Analytics workspace. It enforces the use of `allLogs` category group wherever supported for comprehensive logging.

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

**Host Pools:**
- `HostRegistration` - Session host registration events, health status changes
- `Connection` - User connection attempts, successes, and failures
- `Error` - Errors occurring at the host pool level
- `Checkpoint` - Lifecycle events and state transitions
- `Management` - Administrative operations and configuration changes
- `AgentHealthStatus` - AVD agent health monitoring

**Application Groups:**
- `Checkpoint` - Application group lifecycle events
- `Error` - Application-specific errors
- `Management` - Application group configuration changes

**Workspaces:**
- `Checkpoint` - Workspace lifecycle events
- `Error` - Workspace-level errors
- `Management` - Workspace configuration changes
- `Feed` - User feed subscription activities

### Real-World Use Cases

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

### 1. **Proactive Monitoring & Alerting**
- Detect issues before users report them
- Create alerts for failed connections, agent health problems, or resource errors
- Monitor session host registration failures in real-time
- Track authentication and authorization failures

### 2. **Troubleshooting & Root Cause Analysis**
- Investigate user connection failures with detailed error codes
- Trace the complete user journey from connection attempt to session establishment
- Correlate events across Host Pools, Application Groups, and Workspaces
- Analyze patterns in failures to identify systemic issues

### 3. **Security & Compliance**
- Audit administrative changes to AVD resources
- Track user access patterns for security analysis
- Meet compliance requirements for logging and retention (HIPAA, PCI-DSS, SOC 2)
- Detect anomalous connection patterns or potential security threats

### 4. **Performance Optimization**
- Identify resource bottlenecks and capacity issues
- Analyze connection latency and performance metrics
- Track session host utilization patterns
- Optimize scaling decisions based on historical data

### 5. **Capacity Planning**
- Understand usage trends over time
- Plan for growth based on connection patterns
- Right-size your AVD deployment
- Forecast infrastructure needs

### 6. **Cost Management**
- Track resource utilization to identify underutilized resources
- Correlate costs with usage patterns
- Optimize VM sizing and scaling policies

### 7. **Azure Monitor Integration**
- Build comprehensive dashboards with AVD metrics
- Integrate with Azure Monitor Workbooks for visualization
- Create automated remediation workflows
- Export data to SIEM systems for enterprise-wide monitoring

### 8. **Microsoft Support Requirements**
- Microsoft Support often requires diagnostic logs for troubleshooting
- Proactive logging accelerates support case resolution
- Historical data helps identify intermittent issues

## Features

- 🔍 **Auto-discovery** of AVD resources (Host Pools, Application Groups, Workspaces)
- 📊 **Enforces allLogs** category group for comprehensive diagnostic coverage
- ✅ **Verification** of settings after configuration
- 📋 **Check-only mode** to review current status without making changes
- 📄 **CSV export** of configuration results
- 🛡️ **Error handling** with detailed status reporting

## Prerequisites

- Azure CLI installed ([Install guide](https://docs.microsoft.com/cli/azure/install-azure-cli))
- Azure account with **Monitoring Contributor** permissions
- PowerShell 5.1 or later
- Active Azure subscription with AVD resources

## Quick Start

1. **Login to Azure:**
   ```powershell
   az login
   ```

2. **Run the script:**
   ```powershell
   .\AvdDiag-minimal.ps1 -SubscriptionId "YOUR-SUBSCRIPTION-ID"
   ```

## Parameters

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `SubscriptionId` | No | `00000000-0000-0000-0000-000000000000` | Azure subscription ID |
| `WorkspaceName` | No | `AVD-LAW` | Log Analytics workspace name |
| `WorkspaceResourceGroup` | No | `az-infra-eus2` | Resource group containing the workspace |
| `DiagnosticSettingName` | No | `AVD-Diagnostics` | Name for diagnostic settings |
| `CsvPath` | No | `.\avd-diagnostics-minimal.csv` | Path for CSV export |
| `CheckOnly` | No | (switch) | Check status without making changes |

## Usage Examples

### Check Current Status
Review diagnostic settings without making any changes:
```powershell
.\AvdDiag-minimal.ps1 -SubscriptionId "YOUR-SUBSCRIPTION-ID" -CheckOnly
```

### Configure with Custom Workspace
Apply diagnostic settings using a specific Log Analytics workspace:
```powershell
.\AvdDiag-minimal.ps1 `
    -SubscriptionId "YOUR-SUBSCRIPTION-ID" `
    -WorkspaceName "MyCustomLAW" `
    -WorkspaceResourceGroup "MyResourceGroup"
```

### Run with Default Settings
Use default workspace values:
```powershell
.\AvdDiag-minimal.ps1 -SubscriptionId "YOUR-SUBSCRIPTION-ID"
```

## Output

The script provides:

1. **Console Output:** Color-coded status messages for each resource
   - 🟢 Green: Success
   - 🟡 Yellow: Skipped or warnings
   - 🔴 Red: Errors

2. **CSV Report:** Detailed results exported to the specified CSV path
   - Resource name and type
   - Configuration status
   - Actions taken
   - Any errors encountered

3. **Summary Statistics:**
   - Total resources found
   - Successfully configured
   - Skipped (already configured)
   - Failed

## Status Indicators

| Status | Meaning |
|--------|---------|
| `Enabled (allLogs)` | Configured with comprehensive logging |
| `Enabled (not allLogs)` | Configured but not using allLogs category |
| `Not Configured` | No diagnostic settings exist |
| `Disabled` | Diagnostic settings exist but are disabled |

## Troubleshooting

### "Failed to set subscription"
Ensure you're logged in: `az login`

### "Log Analytics Workspace not found"
Verify the workspace name and resource group are correct.

### "Conflict detected"
Another diagnostic setting is already sending logs to the same workspace. Remove duplicate settings or use a different diagnostic setting name.

### Permission Errors
Ensure your account has **Monitoring Contributor** role on the resources.

## Resource Types Supported

- `Microsoft.DesktopVirtualization/hostPools`
- `Microsoft.DesktopVirtualization/applicationGroups`
- `Microsoft.DesktopVirtualization/workspaces`

## Data Retention & Cost Considerations

### Log Analytics Retention
- **Default retention:** 30 days (free)
- **Extended retention:** Up to 730 days (additional cost applies)
- Configure retention in Log Analytics workspace settings
- Consider archive policies for long-term compliance needs

### Cost Optimization Tips
1. **Use allLogs category** - Simplifies configuration without missing critical data
2. **Set appropriate retention** - Balance compliance needs with storage costs
3. **Query efficiently** - Use time ranges and filters to minimize data processing
4. **Archive old data** - Move aged logs to cheaper storage tiers
5. **Monitor ingestion rates** - Track daily log volume in Log Analytics workspace

### Estimated Costs
Diagnostic logs for AVD typically generate:
- **Small environment** (< 50 users): ~1-2 GB/month
- **Medium environment** (50-200 users): ~5-10 GB/month
- **Large environment** (> 200 users): ~20+ GB/month

*Actual costs depend on user activity, connection frequency, and error rates.*

## Additional Resources

### Microsoft Documentation
- [Azure Virtual Desktop Diagnostics Overview](https://learn.microsoft.com/en-us/azure/virtual-desktop/diagnostics-log-analytics)
- [Use Log Analytics for Diagnostics](https://learn.microsoft.com/en-us/azure/virtual-desktop/diagnostics-log-analytics)
- [Azure Monitor Diagnostic Settings](https://learn.microsoft.com/en-us/azure/azure-monitor/essentials/diagnostic-settings)
- [AVD Required URLs](https://learn.microsoft.com/en-us/azure/virtual-desktop/safe-url-list)

### Related Tools in This Repository
- **[AVD Alerts Script](../AVD-Alerts/)** - Automated alerting for AVD error conditions
- **[AVD Monitoring Workbook](https://learn.microsoft.com/en-us/azure/virtual-desktop/insights)** - Built-in Azure Monitor insights

### Community Resources
- [AVD Tech Community](https://techcommunity.microsoft.com/t5/azure-virtual-desktop/bd-p/AzureVirtualDesktopForum)
- [AVD GitHub Samples](https://github.com/Azure/RDS-Templates/tree/master/wvd-templates)

## Best Practice Checklist

Before running this script, ensure:
- [ ] Log Analytics workspace exists and is properly sized
- [ ] You have Monitoring Contributor permissions on AVD resources
- [ ] Azure CLI is installed and you're logged in (`az login`)
- [ ] You've reviewed your workspace retention policy
- [ ] You've planned for log ingestion costs
- [ ] You have a strategy for log queries and alerting (see AVD-Alerts script)

## Version

**Version:** 1.1  
**Last Updated:** February 2026

## License

See [LICENSE](../LICENSE) file for details.
