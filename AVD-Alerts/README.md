# Azure AVD Alerts Configuration Script

Automatically configure Azure Monitor scheduled query alerts for Azure Virtual Desktop (AVD) monitoring with email notifications.

## Overview

This PowerShell script creates 11 comprehensive alerts for Azure Virtual Desktop that monitor critical user connection and authentication issues. Alerts are triggered every 5 minutes and send email notifications through Azure Monitor Action Groups.

## Features

- 🔔 **11 Pre-configured Alerts** for common AVD issues
- 📧 **Email Notifications** via Azure Monitor Action Groups
- ⚡ **5-minute Evaluation** frequency for fast incident detection
- 🎯 **High Severity** alerts (configurable)
- 📊 **CSV Export** of alert configuration results
- 🧪 **WhatIf Mode** to preview changes without applying
- ✅ **Parameter Validation** for safe execution
- 📝 **Detailed Logging** with timestamps

## Prerequisites

- **Azure CLI** installed and configured ([Installation Guide](https://docs.microsoft.com/cli/azure/install-azure-cli))
- **PowerShell 5.1** or later
- **Azure Permissions:**
  - Monitoring Contributor role on the resource group
  - Read access to Log Analytics workspace
- **Existing Resources:**
  - Log Analytics workspace with AVD diagnostic logs enabled
  - Azure subscription with AVD resources

## Quick Start

### 1. Configure Parameters

Update the default values in the script (lines 50-60) or pass them as arguments:

```powershell
# Option 1: Edit script defaults
$ResourceGroup = "your-resource-group"
$LawName = "your-log-analytics-workspace"
$Location = "your-azure-region"

# Option 2: Pass as arguments (see usage examples below)
```

### 2. Login to Azure

```powershell
az login
```

### 3. Run the Script

```powershell
.\Azure-AVD-Alerts.ps1 -EmailTo "admin@yourdomain.com"
```

## Parameters

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `EmailTo` | **Yes** | - | Email address for alert notifications |
| `ActionGroupName` | No | `AVD-Alerts` | Name of the Azure Monitor action group |
| `ResourceGroup` | No | `your-resource-group` | Resource group containing Log Analytics workspace |
| `LawName` | No | `your-log-analytics-workspace` | Log Analytics workspace name |
| `Location` | No | `your-azure-region` | Azure region for alert rules (e.g., eastus2) |
| `Severity` | No | `1` | Alert severity: 0=Critical, 1=Error, 2=Warning, 3=Info, 4=Verbose |
| `CsvPath` | No | `.\avd-alerts-report.csv` | Path for CSV export of results |
| `WhatIf` | No | (switch) | Preview changes without creating alerts |

## Usage Examples

### Basic Usage
Create alerts with default settings:
```powershell
.\Azure-AVD-Alerts.ps1 -EmailTo "admin@contoso.com"
```

### Specify All Parameters
```powershell
.\Azure-AVD-Alerts.ps1 `
    -EmailTo "alerts@contoso.com" `
    -ResourceGroup "rg-avd-prod" `
    -LawName "law-avd-prod" `
    -Location "eastus2"
```

### Change Alert Severity to Critical
```powershell
.\Azure-AVD-Alerts.ps1 `
    -EmailTo "admin@contoso.com" `
    -Severity 0
```

### Preview Changes (WhatIf Mode)
```powershell
.\Azure-AVD-Alerts.ps1 `
    -EmailTo "admin@contoso.com" `
    -WhatIf
```

### Custom CSV Export Path
```powershell
.\Azure-AVD-Alerts.ps1 `
    -EmailTo "admin@contoso.com" `
    -CsvPath "C:\Reports\avd-alerts.csv"
```

## Alerts Created

The script creates the following 11 alerts with the `AVD-` prefix:

| Alert Name | Description | Impact |
|------------|-------------|---------|
| **AVD-PasswordMustChange** | User password must be changed before login | User cannot access AVD until password changed |
| **AVD-AccountLockedOut** | Account locked due to failed login attempts | User blocked from accessing AVD |
| **AVD-ConnectionFailedPersonalDesktopFailedToBeStarted** | Personal desktop VM failed to start | User cannot connect to assigned desktop |
| **AVD-PasswordExpired** | User password has expired | User must reset password to access AVD |
| **AVD-AccountDisabled** | Disabled account attempting connection | Indicates terminated user or provisioning issue |
| **AVD-ConnectionFailedNoHealthyRdshAvailable** | No healthy session hosts available | **CRITICAL** - All users unable to connect |
| **AVD-ERROR_SHARING_VIOLATION** | File sharing violation during profile load | FSLogix profile conflicts or locked files |
| **AVD-LogonFailed** | User logon failed | Authentication or credential issues |
| **AVD-UnloadWaitingForUserAction** | Profile unload delayed | User has unsaved work blocking logoff |
| **AVD-ConnectionFailedUserNotAuthorized** | Unauthorized connection attempt | Missing permissions on app group/workspace |
| **AVD-ConnectionFailedNoPreAssignedPersonalDesktopForUser** | No personal desktop assigned | Missing desktop assignment in personal pool |

## Alert Configuration

Each alert is configured with:
- **Evaluation Frequency:** Every 5 minutes
- **Query Time Window:** Last 5 minutes
- **Condition:** Query returns > 0 rows
- **Default Severity:** 1 (Error/High)
- **Action:** Email notification via action group

## Output

### Console Output
Color-coded status messages:
- 🟢 **Green:** Successful operations
- 🟡 **Yellow:** Warnings or skipped items
- 🔴 **Red:** Errors
- ⚪ **Gray:** Informational messages

### CSV Report
Exported to the path specified by `-CsvPath` with columns:
- `AlertName` - Name of the alert
- `Description` - What the alert detects
- `Severity` - Alert severity level
- `Status` - Result (Success/Failed/WhatIf)

Example:
```csv
AlertName,Description,Severity,Status
AVD-PasswordMustChange,"Detects users who must change their password...",1 (Error),Success
AVD-AccountLockedOut,"Detects user accounts that are locked out...",1 (Error),Success
```

## Troubleshooting

### Error: "Could not resolve Log Analytics workspace"
**Solution:** Verify the workspace name and resource group are correct. Ensure you have read permissions.

### Error: "Failed to set subscription"
**Solution:** Run `az login` to authenticate, then try again.

### Error: "Failed to create action group"
**Solution:** Ensure you have Monitoring Contributor permissions on the resource group.

### Error: "Failed to retrieve action group ID"
**Solution:** Check that the action group was created successfully. Try running with `-WhatIf` first.

### Alerts created but queries are incomplete
**Solution:** This script properly handles multi-line KQL queries. If issues persist, check the Azure portal to verify query content.

### Script hangs during execution
**Solution:** The script now includes proper error handling. If hanging persists, check Azure CLI version (`az --version`) and update if needed.

## Best Practices

1. **Test First:** Use `-WhatIf` to preview changes before creating alerts
2. **Review Severity:** Adjust `-Severity` based on your incident response process
3. **Monitor Email:** Ensure the specified email address is monitored 24/7
4. **Regular Updates:** Re-run the script to update alert configurations as needed
5. **Clean Up:** Delete old alerts without the `AVD-` prefix if you've upgraded from a previous version

## Advanced Usage

### Update Existing Alerts
Simply re-run the script with the same parameters. Azure CLI will update existing alerts.

### Change Time Window
To modify the evaluation window, edit these variables in the script:
```powershell
$EvalFrequency = "PT5M"   # Evaluation frequency
$WindowSize    = "PT5M"   # Query time window
```

Supported formats: PT1M, PT5M, PT15M, PT30M, PT1H, etc.

### Add Custom Alerts
Follow the pattern in the script:
```powershell
New-OrUpdate-ScheduledQueryAlert -AlertName "AVD-YourAlert" -Description "Your description" -Kql @"
union isfuzzy=true WVDHostRegistration, WVDErrors
| where TimeGenerated > ago(5m)
| where CodeSymbolic == "YourErrorCode"
"@
```

## Requirements

- Azure CLI 2.50.0 or later
- PowerShell 5.1 or later
- AVD diagnostic logs configured to send to Log Analytics
- WVDHostRegistration and WVDErrors tables available in Log Analytics

## Version History

- **v1.0** - Initial release with 11 pre-configured alerts
- Added parameter validation and WhatIf support
- Fixed multi-line KQL query handling
- Added AVD- prefix to alert names
- Improved error handling and logging

## Contributing

Contributions are welcome! Please ensure:
- Parameter validation is maintained
- Error handling is comprehensive
- Documentation is updated
- Testing with `-WhatIf` before committing changes

## License

See [LICENSE](../LICENSE) file for details.

## Related Scripts

- [AVD Diagnostics Configuration](../AVDDiagnostics/README.md) - Configure diagnostic settings for AVD resources

## Support

For issues or questions:
1. Check the [Troubleshooting](#troubleshooting) section
2. Review Azure Monitor logs for detailed error messages
3. Verify Azure CLI is up to date: `az --version`

## Additional Resources

- [Azure Monitor Scheduled Query Alerts](https://docs.microsoft.com/azure/azure-monitor/alerts/alerts-unified-log)
- [Azure Virtual Desktop Diagnostics](https://docs.microsoft.com/azure/virtual-desktop/diagnostics-log-analytics)
- [Azure CLI Reference](https://docs.microsoft.com/cli/azure/monitor/scheduled-query)
