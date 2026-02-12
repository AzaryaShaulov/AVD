# Azure AVD Alerts Configuration Script

Automatically configure Azure Monitor scheduled query alerts for Azure Virtual Desktop (AVD) monitoring with email notifications.

## Overview

This PowerShell script creates 20 comprehensive alerts for Azure Virtual Desktop that monitor critical user connection and authentication issues. Alerts are triggered every 5 minutes and send email notifications through Azure Monitor Action Groups.

## Features

- 🔔 **20 Pre-configured Alerts** for common AVD issues
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

### 1. Get the Script

Clone or download from GitHub:
```powershell
git clone https://github.com/AzaryaShaulov/AVD.git
cd AVD/AVD-Alerts
```

Or download directly: [Azure-AVD-Alerts.ps1](https://github.com/AzaryaShaulov/AVD/blob/main/AVD-Alerts/Azure-AVD-Alerts.ps1)

### 2. Configure Parameters

Update the default values in the script (lines 50-65) or pass them as arguments:

```powershell
# Option 1: Edit script defaults (recommended for repeated use)
$EmailTo = "your-email@domain.com"
$ResourceGroup = "your-resource-group"
$LawName = "your-log-analytics-workspace"
$Location = "your-azure-region"

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
```

## Parameters

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `EmailTo` | No | `your-email@domain.com` | Email address for alert notifications |
| `ActionGroupName` | No | `AVD-Alerts` | Name of the Azure Monitor action group |
| `ResourceGroup` | No | `your-resource-group` | Resource group containing Log Analytics workspace |
| `LawName` | No | `your-log-analytics-workspace` | Log Analytics workspace name |
| `Location` | No | `your-azure-region` | Azure region for alert rules (e.g., eastus2) |
| `Severity` | No | `1` | Alert severity: 0=Critical, 1=Error, 2=Warning, 3=Info, 4=Verbose |
| `CsvPath` | No | `.\avd-alerts-report.csv` | Path for CSV export of results |
| `WhatIf` | No | (switch) | Preview changes without creating alerts |

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
.\Azure-AVD-Alerts.ps1 -Severity 0
```

### Preview Changes (WhatIf Mode)
```powershell
.\Azure-AVD-Alerts.ps1 -WhatIf
```

### Custom CSV Export Path
```powershell
.\Azure-AVD-Alerts.ps1 -CsvPath "C:\Reports\avd-alerts.csv"
```

## Alerts Reference

The script creates **20 comprehensive alerts** with the `AVD-` prefix. Each alert monitors specific AVD error conditions and sends email notifications when issues occur.

### Authentication & Credential Alerts

#### 1. AVD-PasswordMustChange
**Description:** Detects users who must change their password before logging into AVD. Triggers when a user's password policy requires a mandatory change.

**Used For:** 
- Identifying users with expired password policies requiring immediate password reset
- Proactive user support before repeated login failures
- Monitoring password policy compliance

**Microsoft Documentation:**
- [AVD Troubleshooting - User Connection](https://learn.microsoft.com/azure/virtual-desktop/troubleshoot-user-connection)
- [Password Policies in Azure AD](https://learn.microsoft.com/azure/active-directory/authentication/concept-password-policies)

---

#### 2. AVD-InvalidCredentials
**Description:** Detects login attempts with invalid credentials (wrong username or password). Indicates user credential issues or potential security concerns.

**Used For:**
- Identifying users entering incorrect passwords
- Detecting potential unauthorized access attempts
- Triggering user password reset processes

**Microsoft Documentation:**
- [AVD Troubleshooting - Authentication Issues](https://learn.microsoft.com/azure/virtual-desktop/troubleshoot-authentication)
- [Azure AD Sign-in Diagnostics](https://learn.microsoft.com/azure/active-directory/reports-monitoring/concept-sign-ins)

---

#### 3. AVD-PasswordExpired
**Description:** Detects users attempting to connect with expired passwords. Users must reset their password before accessing AVD.

**Used For:**
- Catching expired passwords at connection time
- Reducing helpdesk tickets for password-related issues
- Proactive user notification and support

**Microsoft Documentation:**
- [AVD Troubleshooting - User Connection](https://learn.microsoft.com/azure/virtual-desktop/troubleshoot-user-connection)
- [Password Expiration Policies](https://learn.microsoft.com/azure/active-directory/authentication/concept-password-policies)

---

#### 4. AVD-InvalidAuthToken
**Description:** Detects invalid or expired authentication tokens. Indicates authentication token validation failures or token expiration issues.

**Used For:**
- Monitoring authentication token lifecycle issues
- Detecting token validation failures
- Identifying sync issues between AVD and identity providers

**Microsoft Documentation:**
- [AVD Connection Architecture](https://learn.microsoft.com/azure/virtual-desktop/connection-architecture)
- [Azure AD Token Lifetime](https://learn.microsoft.com/azure/active-directory/develop/access-tokens)

---

### Account Management Alerts

#### 5. AVD-AccountLockedOut
**Description:** Detects user accounts that are locked out due to failed login attempts. Indicates potential security issues or users needing assistance.

**Used For:**
- Responding to account lockouts quickly
- Detecting brute force attack attempts
- Reducing user downtime from locked accounts

**Microsoft Documentation:**
- [AVD Troubleshooting - User Connection](https://learn.microsoft.com/azure/virtual-desktop/troubleshoot-user-connection)
- [Azure AD Account Lockout](https://learn.microsoft.com/azure/active-directory/authentication/howto-password-smart-lockout)

---

#### 6. AVD-AccountDisabled
**Description:** Detects connection attempts from disabled user accounts. Indicates terminated users trying to access AVD or account provisioning issues.

**Used For:**
- Security monitoring for disabled account access attempts
- Identifying account provisioning/de-provisioning issues
- Compliance and audit trail maintenance

**Microsoft Documentation:**
- [AVD Security Best Practices](https://learn.microsoft.com/azure/virtual-desktop/security-guide)
- [Azure AD User Account Management](https://learn.microsoft.com/azure/active-directory/fundamentals/add-users-azure-active-directory)

---

### Authorization & Permission Alerts

#### 7. AVD-ConnectionFailedUserNotAuthorized
**Description:** Detects unauthorized connection attempts to AVD. User lacks permissions on the application group or workspace.

**Used For:**
- Identifying missing RBAC role assignments
- Detecting permission configuration issues
- Monitoring unauthorized access attempts

**Microsoft Documentation:**
- [AVD Access Control](https://learn.microsoft.com/azure/virtual-desktop/rbac)
- [Assign User Access to Host Pools](https://learn.microsoft.com/azure/virtual-desktop/assign-access)

---

#### 8. AVD-LogonTypeNotGranted
**Description:** Detects when requested logon type is not granted by policy. User may lack required logon rights or policy restrictions are in place.

**Used For:**
- Identifying Group Policy restrictions affecting AVD access
- Monitoring logon rights configuration issues
- Troubleshooting Remote Desktop Services policies

**Microsoft Documentation:**
- [AVD Group Policy](https://learn.microsoft.com/azure/virtual-desktop/configure-group-policies)
- [User Rights Assignment](https://learn.microsoft.com/windows/security/threat-protection/security-policy-settings/user-rights-assignment)

---

#### 9. AVD-NotAuthorizedForLogon
**Description:** Detects users not authorized for logon. May indicate missing logon permissions or policy restrictions preventing access.

**Used For:**
- Troubleshooting Remote Desktop user group membership
- Identifying policy restrictions blocking user access
- Security compliance monitoring

**Microsoft Documentation:**
- [AVD Security Best Practices](https://learn.microsoft.com/azure/virtual-desktop/security-guide)
- [Configure RDP Properties](https://learn.microsoft.com/azure/virtual-desktop/customize-rdp-properties)

---

#### 10. AVD-LogonFailed
**Description:** Detects failed user logon attempts to AVD session hosts. May indicate authentication issues, incorrect credentials, or account problems.

**Used For:**
- General logon failure monitoring
- Identifying multi-factor authentication issues
- Detecting configuration problems affecting authentication

**Microsoft Documentation:**
- [AVD Troubleshooting - User Connection](https://learn.microsoft.com/azure/virtual-desktop/troubleshoot-user-connection)
- [Enable MFA for AVD](https://learn.microsoft.com/azure/virtual-desktop/set-up-mfa)

---

### Connection & Network Alerts

#### 11. AVD-ConnectionFailedClientConnectedTooLateReverseConnectionAlreadyClosed
**Description:** Detects when client connects too late and reverse connection is already closed. May indicate network latency or timeout issues.

**Used For:**
- Identifying network performance problems
- Detecting connection timeout issues
- Monitoring reverse connect transport reliability

**Microsoft Documentation:**
- [AVD Network Connectivity](https://learn.microsoft.com/azure/virtual-desktop/network-connectivity)
- [RDP Shortpath for Azure Virtual Desktop](https://learn.microsoft.com/azure/virtual-desktop/rdp-shortpath)

---

### Host Pool & Session Host Alerts

#### 12. AVD-ConnectionFailedNoHealthyRdshAvailable
**Description:** Detects when no healthy session hosts are available in a host pool. **CRITICAL** issue preventing all user connections - requires immediate attention.

**Used For:**
- **Critical alert** for complete service outage
- Monitoring session host health status
- Capacity planning and scaling decisions

**Microsoft Documentation:**
- [Monitor Azure Virtual Desktop](https://learn.microsoft.com/azure/virtual-desktop/monitor-azure-virtual-desktop)
- [Session Host Health Checks](https://learn.microsoft.com/azure/virtual-desktop/start-virtual-machine-connect)

---

#### 13. AVD-SessionHostResourceNotAvailable
**Description:** Detects when session host resources are unavailable. May indicate capacity issues, host health problems, or resource exhaustion.

**Used For:**
- Monitoring host pool capacity and utilization
- Detecting VM health issues
- Triggering scaling actions or capacity additions

**Microsoft Documentation:**
- [AVD Scaling Plans](https://learn.microsoft.com/azure/virtual-desktop/autoscale-scaling-plan)
- [Host Pool Load Balancing](https://learn.microsoft.com/azure/virtual-desktop/host-pool-load-balancing)

---

#### 14. AVD-OutOfMemory
**Description:** Detects session hosts running out of memory. **CRITICAL** issue requiring immediate attention - may cause session crashes or prevent new connections.

**Used For:**
- Identifying undersized VM SKUs
- Detecting memory leaks or runaway processes
- Capacity planning and VM sizing decisions

**Microsoft Documentation:**
- [AVD Virtual Machine Sizing](https://learn.microsoft.com/azure/virtual-desktop/virtual-machine-sizing-guidelines)
- [Performance Counters for AVD](https://learn.microsoft.com/azure/virtual-desktop/performance-counters)

---

### Personal Desktop Alerts

#### 15. AVD-ConnectionFailedPersonalDesktopFailedToBeStarted
**Description:** Detects when a personal desktop VM fails to start for a connection attempt. May indicate VM configuration issues or Azure capacity problems.

**Used For:**
- Monitoring personal host pool VM startup issues
- Detecting Azure capacity constraints
- Identifying VM configuration problems

**Microsoft Documentation:**
- [Start VM on Connect](https://learn.microsoft.com/azure/virtual-desktop/start-virtual-machine-connect)
- [Personal Desktop Assignment](https://learn.microsoft.com/azure/virtual-desktop/configure-host-pool-personal-desktop-assignment-type)

---

#### 16. AVD-ConnectionFailedNoPreAssignedPersonalDesktopForUser
**Description:** Detects connection attempts when user has no personal desktop assigned. Occurs in personal host pools without desktop assignment.

**Used For:**
- Identifying missing desktop assignments in personal pools
- Monitoring user provisioning processes
- Automated assignment troubleshooting

**Microsoft Documentation:**
- [Personal Desktop Assignment Types](https://learn.microsoft.com/azure/virtual-desktop/configure-host-pool-personal-desktop-assignment-type)
- [Assign Users to Personal Desktops](https://learn.microsoft.com/azure/virtual-desktop/configure-host-pool-personal-desktop-assignment-type)

---

### Profile & Storage Alerts

#### 17. AVD-ERROR_SHARING_VIOLATION
**Description:** Detects file sharing violations during user profile loading or application access. Often related to FSLogix profile conflicts or locked files.

**Used For:**
- Troubleshooting FSLogix profile container issues
- Detecting profile corruption or locking problems
- Monitoring storage connectivity issues

**Microsoft Documentation:**
- [FSLogix Profile Containers](https://learn.microsoft.com/fslogix/profile-container-configuration-reference)
- [Configure FSLogix for AVD](https://learn.microsoft.com/azure/virtual-desktop/create-profile-container-adds)

---

#### 18. AVD-UnloadWaitingForUserAction
**Description:** Detects when FSLogix profile unload is delayed waiting for user action. User may have unsaved work or active processes blocking logoff.

**Used For:**
- Identifying applications preventing clean logoff
- Detecting unsaved work blocking session termination
- Monitoring profile disconnect/logoff processes

**Microsoft Documentation:**
- [FSLogix Profile Container](https://learn.microsoft.com/fslogix/profile-container-configuration-reference)
- [Configure Profile Container Settings](https://learn.microsoft.com/fslogix/configure-profile-container-tutorial)

---

### Device & Graphics Alerts

#### 19. AVD-GetInputDeviceHandlesError
**Description:** Detects errors initializing input device handles. May indicate driver issues or peripheral compatibility problems.

**Used For:**
- Troubleshooting keyboard/mouse redirection issues
- Detecting device driver problems
- Monitoring peripheral compatibility

**Microsoft Documentation:**
- [Device Redirection](https://learn.microsoft.com/azure/virtual-desktop/configure-device-redirections)
- [Supported RDP Properties](https://learn.microsoft.com/azure/virtual-desktop/rdp-properties)

---

#### 20. AVD-GraphicsCapsNotReceived
**Description:** Detects when graphics capabilities are not received during session initialization. May indicate GPU or graphics driver issues.

**Used For:**
- Monitoring GPU acceleration problems
- Detecting graphics driver issues
- Troubleshooting multimedia redirection

**Microsoft Documentation:**
- [GPU Acceleration for AVD](https://learn.microsoft.com/azure/virtual-desktop/configure-vm-gpu)
- [Multimedia Redirection](https://learn.microsoft.com/azure/virtual-desktop/multimedia-redirection)

---

## Additional Resources

- [Azure Virtual Desktop Documentation](https://learn.microsoft.com/azure/virtual-desktop/)
- [AVD Troubleshooting Overview](https://learn.microsoft.com/azure/virtual-desktop/troubleshoot-overview)
- [Monitor AVD with Azure Monitor](https://learn.microsoft.com/azure/virtual-desktop/monitor-azure-virtual-desktop)
- [AVD Diagnostics with Log Analytics](https://learn.microsoft.com/azure/virtual-desktop/diagnostics-log-analytics)
- [AVD Error Code Reference](https://learn.microsoft.com/azure/virtual-desktop/troubleshoot-set-up-overview)

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

1. **Configure Defaults:** Update default parameter values (EmailTo, ResourceGroup, LawName, Location) in the script for easier repeated use
2. **Test First:** Use `-WhatIf` to preview changes before creating alerts
3. **Review Severity:** Adjust `-Severity` based on your incident response process
4. **Monitor Email:** Ensure the configured email address is monitored 24/7 for alert notifications
5. **Regular Updates:** Re-run the script to update alert configurations as needed
6. **Clean Up:** Delete old alerts without the `AVD-` prefix if you've upgraded from a previous version

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

- **v2.0** - Added 9 new alerts (total: 20)
  - ConnectionFailedClientConnectedTooLateReverseConnectionAlreadyClosed
  - GetInputDeviceHandlesError
  - GraphicsCapsNotReceived
  - InvalidAuthToken
  - InvalidCredentials
  - LogonTypeNotGranted
  - NotAuthorizedForLogon
  - OutOfMemory
  - SessionHostResourceNotAvailable
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
