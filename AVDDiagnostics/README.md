# AVD Diagnostics Configuration Tool

A PowerShell script to automatically configure Azure Monitor diagnostic settings for Azure Virtual Desktop (AVD) resources.

## Overview

This tool discovers AVD resources in your Azure subscription and configures diagnostic settings to send logs and metrics to a Log Analytics workspace. It enforces the use of `allLogs` category group wherever supported for comprehensive logging.

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

## Version

**Version:** 1.1  
**Last Updated:** February 2026

## License

See [LICENSE](../LICENSE) file for details.
