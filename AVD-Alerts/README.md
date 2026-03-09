# Azure AVD Alerts Configuration Script

Automatically configure Azure Monitor scheduled query alerts for Azure Virtual Desktop (AVD) monitoring with email notifications.

## Overview

This PowerShell script creates 8 consolidated category alerts for Azure Virtual Desktop that monitor critical user connection, authentication, host health, and FSLogix-related issues. Alerts are triggered every 10 minutes with a 15-minute lookback and send email notifications through Azure Monitor Action Groups.

## Features

- 🔔 **8 Consolidated Category Alerts** for common AVD issues
- 📧 **Email Notifications** via Azure Monitor Action Groups
- ⚡ **5-minute Evaluation** frequency for fast incident detection
- 🎯 **High Severity** alerts (configurable)
- 📊 **CSV Export** of alert configuration results
- 🧪 **WhatIf Mode** for fast preview (~5s) with proper Azure change prevention (fixed v2.1)
- 🔄 **Progress Indicator** showing real-time alert creation status
- 🎯 **Multi-Subscription Support** with explicit subscription targeting
- ✅ **Parameter Validation** for safe execution (including GUID validation)
- 📝 **Detailed Logging** with timestamps

## Prerequisites

- **Azure CLI** installed and configured ([Installation Guide](https://learn.microsoft.com/cli/azure/install-azure-cli))
- **PowerShell 5.1** or later
- **Azure Permissions:**
  - Monitoring Contributor role on the resource group
  - Read access to Log Analytics workspace
- **Existing Resources:**
  - Log Analytics workspace with AVD diagnostic logs enabled
  - Azure subscription with AVD resources

## Quick Start

### 1. Get the Script

Clone or download from GitHub:
```powershell
git clone https://github.com/AzaryaShaulov/AVD.git
cd AVD/AVD-Alerts
```

Or download directly: [Azure-AVD-Alerts.ps1](https://github.com/AzaryaShaulov/AVD/blob/main/AVD-Alerts/Azure-AVD-Alerts.ps1)

### 2. Configure Parameters

Update the default values in the script parameter section or pass them as arguments:

```powershell
# Option 1: Edit script defaults (recommended for repeated use)
# Update the parameter default values in the script:
$EmailTo = "your-email@domain.com"
$ResourceGroup = "your-resource-group"
$LawName = "your-log-analytics-workspace"
$Location = "your-azure-region"
$SubscriptionId = "" # Optional: specify target subscription

# Option 2: Pass as arguments (see usage examples below)
```

### 3. Login to Azure

```powershell
az login
```

### 4. Run the Script

```powershell
# After configuring default parameters in the script:
.\Azure-AVD-Alerts.ps1

# Or override parameters:
.\Azure-AVD-Alerts.ps1 -EmailTo "admin@yourdomain.com"

# Target specific subscription:
.\Azure-AVD-Alerts.ps1 -SubscriptionId "12345678-1234-1234-1234-123456789012" `
  -EmailTo "admin@yourdomain.com" `
  -ResourceGroup "rg-avd-prod" `
  -LawName "law-avd-prod" `
  -Location "eastus2"
```

## Parameters

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `EmailTo` | No | `your-email@domain.com` | Email address for alert notifications (validated) |
| `SubscriptionId` | No | (current context) | Azure subscription ID (GUID format, validated) |
| `ActionGroupName` | No | `AVD-Alerts` | Name of the Azure Monitor action group |
| `ResourceGroup` | No | `your-resource-group` | Resource group containing Log Analytics workspace |
| `LawName` | No | `your-log-analytics-workspace` | Log Analytics workspace name |
| `Location` | No | `your-azure-region` | Azure region for alert rules (e.g., eastus2) |
| `Severity` | No | `1` | Alert severity: 0=Critical, 1=Error, 2=Warning, 3=Info, 4=Verbose |
| `CreateOnly` | No | `true` | When `true`, existing alerts are skipped and left unchanged |
| `CsvPath` | No | `.\avd-alerts-report[-subId].csv` | Path for CSV export (auto-includes subscription ID when specified) |
| `WhatIf` | No | (switch) | Preview changes without making Azure modifications (~5s execution, fixed in v2.1) |

## Usage Examples

### Basic Usage (with defaults configured)
Run with default parameters after updating them in the script:
```powershell
.\Azure-AVD-Alerts.ps1
```

### Override Email Address
Create alerts with default settings but different email:
```powershell
.\Azure-AVD-Alerts.ps1 -EmailTo "admin@contoso.com"
```

### Target Specific Subscription
```powershell
.\Azure-AVD-Alerts.ps1 `
    -SubscriptionId "12345678-1234-1234-1234-123456789012" `
    -EmailTo "alerts@contoso.com" `
    -ResourceGroup "rg-avd-prod" `
    -LawName "law-avd-prod" `
    -Location "eastus2"
```

### Specify All Parameters
```powershell
.\Azure-AVD-Alerts.ps1 `
    -EmailTo "alerts@contoso.com" `
    -ResourceGroup "rg-avd-prod" `
    -LawName "law-avd-prod" `
  -Location "eastus2" `
  -CreateOnly:$true
```

### Change Alert Severity to Critical
```powershell
.\Azure-AVD-Alerts.ps1 -Severity 0
```

### Preview Changes (WhatIf Mode with Status Reporting)
```powershell
# Fast preview mode (~5 seconds) - no Azure CLI commands executed
# Properly skips all Azure changes (bug fixed in v2.1)
.\Azure-AVD-Alerts.ps1 -WhatIf
```

### Custom CSV Export Path
```powershell
.\Azure-AVD-Alerts.ps1 -CsvPath "C:\Reports\avd-alerts.csv"
```

## Best Practices

1. **Configure Defaults:** Update default parameter values (EmailTo, ResourceGroup, LawName, Location) in the script for easier repeated use
2. **Test First:** Use `-WhatIf` to preview changes before creating alerts (~5s fast preview, no Azure changes - fixed in v2.1)
3. **Subscription Context:** Use `-SubscriptionId` parameter for explicit subscription targeting in multi-subscription environments
4. **Review Severity:** Adjust `-Severity` based on your incident response process
5. **Monitor Email:** Ensure the configured email address is monitored 24/7 for alert notifications
6. **Create-Only Behavior:** Re-run the script safely; existing `AVD-` alerts are detected and skipped (no alert updates)
7. **Clean Up:** Delete old alerts without the `AVD-` prefix if you've upgraded from a previous version
8. **CSV Reports:** Review exported CSV files (auto-named by subscription) for audit trails

## Alerts Reference

The script creates **8 consolidated category alerts** with the `AVD-Category-` prefix. Each alert scans a related group of issues and fires one category-level notification to reduce alert noise.

| Category Alert | Covers |
|---|---|
| `AVD-Category-AuthenticationIdentity` | Password and credential failures, token/authentication issues, disabled/locked accounts, and related identity errors. |
| `AVD-Category-AuthorizationPolicy` | Authorization failures and logon rights/policy denials. |
| `AVD-Category-ConnectionNetworkGateway` | Client transport issues, DNS/gateway failures, and reverse-connect timing/connectivity problems. |
| `AVD-Category-SessionHostHealthCapacity` | No healthy host conditions, host resource exhaustion, and out-of-memory failures. |
| `AVD-Category-PersonalDesktopAssignment` | Personal desktop assignment/startup failures. |
| `AVD-Category-DeviceGraphicsInput` | Input-device initialization and graphics subsystem/capability failures. |
| `AVD-Category-FSLogixProfileStorage` | FSLogix profile/storage issues including sharing/lock/access/path/network/disk failures and FRX pattern matches. |
| `AVD-Category-UnknownUnclassified` | Unknown/unclassified error symbols for triage. |

### Important

If older per-error `AVD-` alerts already exist in Azure Monitor, delete them to avoid duplicate notifications and keep only the new category alerts.

## Alert Configuration

Each alert is configured with:
- **Evaluation Frequency:** Every 10 minutes
- **Query Time Window:** Last 15 minutes
- **Condition:** Query returns > 0 rows
- **Default Severity:** 1 (Error/High)
- **Action:** Email notification via action group

## Output

### Console Output
Color-coded status messages with real-time progress indicator:
- 🟢 **Green:** Successful operations
- 🟡 **Yellow:** Warnings, skipped items, and WhatIf preview messages
- 🔴 **Red:** Errors
- 🔵 **Cyan:** Section headers
- ⚪ **Gray:** Informational messages
- 📊 **Progress Bar:** Shows alert processing status (X of 8 alerts)

### WhatIf Status Reports
When using `-WhatIf` mode (fixed in v2.1):
- **Fast execution**: Completes in ~5 seconds (no Azure CLI commands executed)
- **Proper preview**: Shows create/skip preview messages for each alert
- **No Azure changes**: Verified to skip all Azure resource modifications
- **Summary report**: "WhatIf Mode: X alert(s) would be created; Y would be skipped (already exist)"

For sequential processing (PS 5.1), status reports appear every 30 seconds showing:
- Elapsed time
- Progress (alerts validated / total)
- Current alert being processed

### CSV Report
Exported to the path specified by `-CsvPath` (automatically includes subscription ID in filename when `-SubscriptionId` is provided):

**Columns:**
- `AlertName` - Name of the alert
- `Description` - What the alert detects
- `Severity` - Alert severity level
- `Action` - Operation performed (Created/Skipped/WouldCreate/WouldSkip/Failed)
- `Status` - Result (Success/Failed/WhatIf)

**Filename Examples:**
- Default: `avd-alerts-report.csv`
- With SubscriptionId: `avd-alerts-report-12345678.csv` (first 8 chars of subscription ID)

Example CSV content:
```csv
AlertName,Description,Severity,Action,Status
AVD-PasswordMustChange,"Detects users who must change their password...","1 (Error)",Created,Success
AVD-AccountLockedOut,"Detects user accounts that are locked out...","1 (Error)",Skipped,Success
```

## Troubleshooting

| Issue/Error | Solution |
|-------------|----------|
| **Could not resolve Log Analytics workspace** | Verify the workspace name and resource group are correct. Ensure you have read permissions. |
| **Failed to set subscription** | Run `az login` to authenticate. Verify the subscription ID format (must be a valid GUID: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx). Check you have access to the subscription with `az account list`. |
| **Invalid SubscriptionId format** | Ensure SubscriptionId follows GUID format: 8-4-4-4-12 hexadecimal characters (e.g., 12345678-1234-1234-1234-123456789012) |
| **Failed to create action group** | Ensure you have Monitoring Contributor permissions on the resource group. |
| **Failed to retrieve action group ID** | Check that the action group was created successfully. Try running with `-WhatIf` first. |
| **WhatIf creates alerts anyway** | Fixed in v2.1. Upgrade to latest version for proper WhatIf functionality. |
| **Alerts created but queries are incomplete** | This script properly handles multi-line KQL queries. If issues persist, check the Azure portal to verify query content. |
| **Script hangs during execution** | The script includes timeout handling and progress indicators. If hanging persists, check Azure CLI version (`az --version`) and update if needed. Use `-WhatIf` to validate without making changes. |

## Advanced Usage

### Existing Alerts Behavior
The script is intentionally create-only for scheduled query alerts. If an alert already exists, it is skipped and left unchanged. Re-running the script is safe and will only create missing alerts.

### Change Time Window
To modify the evaluation window, edit these variables in the script:
```powershell
$EvalFrequency = "PT10M"  # Evaluation frequency
$WindowSize    = "PT15M"  # Query time window
```

Supported formats: PT1M, PT5M, PT15M, PT30M, PT1H, etc.

### Add Custom Alerts
The script uses an array-driven approach for maintainability. Add new alerts to the `$alertDefinitions` array:

```powershell
# Add to the $alertDefinitions array:
$alertDefinitions = @(
  # ... existing alerts ...
  @{ 
    Name = "AVD-YourCustomAlert"
    Description = "Detects your custom condition..." 
    CodeSymbolic = "YourErrorCode" 
  }
)
```

Alternatively, call the function directly after the loop:
```powershell
New-OrUpdate-ScheduledQueryAlert -AlertName "AVD-YourAlert" -Description "Your description" -Kql @"
union isfuzzy=true WVDHostRegistration, WVDErrors
| where TimeGenerated > ago(5m)
| where CodeSymbolic == "YourErrorCode"
| project UserName, Source, CodeSymbolic, Message, Operation, _ResourceId
"@
```

## Requirements

- Azure CLI 2.50.0 or later
- PowerShell 5.1 or later
- AVD diagnostic logs configured to send to Log Analytics
- WVDHostRegistration and WVDErrors tables available in Log Analytics

## Version

**Version:** 2.1  
**Last Updated:** February 2026

### Version History

- **v2.1** (February 2026) - Critical bug fixes
  - **Bug Fixes:**
    - Fixed critical WhatIf functionality bug where alerts were being created in Azure even when using `-WhatIf` parameter
    - Changed WhatIf detection from `$WhatIf.IsPresent` to `$PSBoundParameters.ContainsKey('WhatIf')` for proper parameter detection in parallel processing
    - Fixed variable scope consistency for `$existingAlertNamesList` (now consistently uses `$script:` prefix)
    - WhatIf mode now properly skips Azure CLI execution and completes in ~5 seconds instead of ~30 seconds
  - **Testing Verified:**
    - WhatIf mode: Shows create/skip preview messages, no Azure changes
    - Normal mode: Creates/updates alerts successfully with proper status messages
    - Both parallel (PS7+) and sequential (PS5.1) modes working correctly
- **v2.0** (February 2026) - Major enhancements and 9 new alerts (total: 20)
  - **New Features:**
    - Added SubscriptionId parameter with GUID validation for multi-subscription environments
    - Subscription-aware CSV naming (includes subscription ID when specified)
    - Progress indicator showing real-time alert creation status
    - WhatIf status reporting every 30 seconds for long operations
    - Explicit subscription context for all Azure CLI commands
    - SHA256-based email receiver naming to prevent collisions
    - Performance optimization with cached alert list queries
    - Phase 1 & 2 performance optimizations: Smart action group checks, cached alert existence, --no-wait flag, parallel processing (77% speed improvement)
  - **New Alerts:**
    - ConnectionFailedClientConnectedTooLateReverseConnectionAlreadyClosed
    - GetInputDeviceHandlesError
    - GraphicsCapsNotReceived
    - InvalidAuthToken
    - InvalidCredentials
    - LogonTypeNotGranted
    - NotAuthorizedForLogon
    - OutOfMemory
    - SessionHostResourceNotAvailable
  - **Code Quality:**
    - Refactored to array-driven alert creation (reduced from ~690 to 563 lines)
    - Enhanced error handling and parameter validation
    - Improved logging with color-coded output
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

## Disclaimer

**THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED.**

This script is provided as-is under the MIT License. The authors and contributors:

- **Make no warranties or guarantees** about the functionality, reliability, or suitability of this script for any purpose
- **Accept no responsibility or liability** for any damages, data loss, service interruptions, or other issues arising from the use of this script
- **Provide no support or maintenance** obligations, though community contributions are welcome
- **Recommend thorough testing** in a non-production environment before deploying to production systems

### Important Notes:

- ⚠️ **Test First**: Always test in a development/staging environment before running in production
- ⚠️ **Email Configuration**: Verify alert email addresses are correct to avoid missing critical notifications
- ⚠️ **Permissions**: Review required Azure RBAC permissions before execution
- ⚠️ **Alert Fatigue**: Configure appropriate severity levels to prevent alert fatigue
- ⚠️ **Costs**: Understand Azure Monitor alert pricing before deploying at scale
- ⚠️ **Compliance**: Verify this solution meets your organization's security and compliance requirements

**By using this script, you acknowledge and accept these terms and assume all risks associated with its use.**

## Related Scripts

- [AVD Diagnostics Configuration](../AVDDiagnostics/README.md) - Configure diagnostic settings for AVD resources

## Support

For issues or questions:
1. Check the [Troubleshooting](#troubleshooting) section
2. Review Azure Monitor logs for detailed error messages
3. Verify Azure CLI is up to date: `az --version`

## Additional Resources

- [Azure Monitor Scheduled Query Alerts](https://learn.microsoft.com/azure/azure-monitor/alerts/alerts-unified-log)
- [Azure Virtual Desktop Diagnostics](https://learn.microsoft.com/azure/virtual-desktop/diagnostics-log-analytics)
- [Azure CLI Reference](https://learn.microsoft.com/cli/azure/monitor/scheduled-query)
- [Azure Virtual Desktop Documentation](https://learn.microsoft.com/azure/virtual-desktop/)
- [AVD Troubleshooting Overview](https://learn.microsoft.com/azure/virtual-desktop/troubleshoot-overview)
- [Monitor AVD with Azure Monitor](https://learn.microsoft.com/azure/virtual-desktop/monitor-azure-virtual-desktop)
- [AVD Diagnostics with Log Analytics](https://learn.microsoft.com/azure/virtual-desktop/diagnostics-log-analytics)
- [AVD Error Code Reference](https://learn.microsoft.com/azure/virtual-desktop/troubleshoot-set-up-overview)
