# AVD Session Host Insights Monitoring

This script automates Azure Virtual Desktop session host performance monitoring by creating a Data Collection Rule (DCR) that sends performance counters to a Log Analytics workspace in both the `InsightsMetrics` and `Perf` tables. It automatically discovers **all AVD host pools** in the subscription and provides an interactive menu to associate the DCR with session hosts across selected host pools, enabling AVD Insights and VM Insights dashboards with a single run.

Once perf data is flowing, the companion [AVD-SessionHost-Insights-Alerts](../AVD-SessionHost-Insights-Alerts/) scripts deploy **7 category-consolidated performance alerts with rich email notifications** - HTML emails that include the specific counter values, affected host names, and threshold breaches, far more actionable than standard Azure Monitor "alert fired" notifications.

## What It Does

- Creates or updates a DCR that collects performance counters into **two** tables:
  - `InsightsMetrics` - consumed by VM Insights dashboards and workbooks
  - `Perf` - consumed by Log Analytics queries and AVD Insights
- Validates the DCR was created by resolving its resource ID
- **Auto-discovers** all AVD host pools in the subscription
- **Interactive association** with session hosts:
  - [A] Associate with all host pools
  - [S] Select specific host pools by number
  - [N] Skip association
- Automatically installs the `desktopvirtualization` Azure CLI extension if not present
- Shows real-time progress with association status per VM
- Reports per-pool and overall success/skip/fail counts
- Supports idempotency: skips already-associated VMs automatically

## Script Reference

| # | Script | Purpose | What It Does | Quick Start (copy & paste) |
| -- | ------ | ------- | ------------ | -------------------------- |
| 1 | `AVD-Insights-Enable-PerfMetricsDCRps1` | Deploy DCR for perf counters | Creates a Data Collection Rule collecting 28 perf counters into `InsightsMetrics` and `Perf` tables, auto-discovers all AVD host pools, and provides an interactive menu to associate the DCR with session hosts. Add `-InstallAma` to also install AMA on VMs where missing. | `.\AVD-Insights-Enable-PerfMetricsDCRps1 -SubscriptionId "YOUR-SUB-ID" -LawRG "YOUR-LAW-RG" -LawName "YOUR-LAW" -DcrRG "YOUR-DCR-RG" -DcrName "AVD-SessionHost-DCR" -Location "eastus2"` |
| 2 | `AVD-Insights-Alerts-Precheck.ps1` | Validate Insights prerequisites | Checks RBAC permissions, Azure CLI extensions, LAW connectivity, and verifies Perf counter data flow. Read-only - no changes made. | `..\AVD-SessionHost-Insights-Alerts\AVD-Insights-Alerts-Precheck.ps1 -SubscriptionId "YOUR-SUB-ID" -ResourceGroupName "YOUR-RG" -WorkspaceName "YOUR-LAW"` |
| 3 | `AVD-Insights-Alerts-Deploy-LogicApp.ps1` | **Primary: deploy Insights alerts + email pipeline** | Creates/updates the Logic App, Office 365 API connection, webhook action group, assigns Log Analytics Reader to the Logic App managed identity, and bootstraps all 7 `AVD-Insights-Category-*` alerts. Single command does everything. | `..\AVD-SessionHost-Insights-Alerts\AVD-Insights-Alerts-Deploy-LogicApp.ps1 -SubscriptionId "YOUR-SUB-ID" -ResourceGroupName "YOUR-RG" -LogicAppName "AVD-Insights-Alert-Email" -Location "eastus2" -WorkspaceName "YOUR-LAW" -WorkspaceResourceGroupName "YOUR-LAW-RG" -SendFromEmail "alerts@contoso.com" -SendToEmail "team@contoso.com"` |
| 4 | `AVD-Insights-Alerts-Category-Alerts.ps1` | Create Insights alert rules only | Reads alert definitions from `alerts-config.insights.json`, loads KQL query files, and creates scheduled query rules. Called automatically by script #3 - run directly only for standalone alert creation. | `..\AVD-SessionHost-Insights-Alerts\AVD-Insights-Alerts-Category-Alerts.ps1 -ResourceGroup "YOUR-RG" -WorkspaceName "YOUR-LAW" -Location "eastus2"` |

**Additional modes:**

| Mode | Command |
| ---- | ------- |
| With AMA install | `.\AVD-Insights-Enable-PerfMetricsDCRps1 -SubscriptionId "YOUR-SUB-ID" -LawRG "YOUR-LAW-RG" -LawName "YOUR-LAW" -DcrRG "YOUR-DCR-RG" -DcrName "AVD-SessionHost-DCR" -Location "eastus2" -InstallAma` |
| WhatIf (preview changes) | `.\AVD-Insights-Enable-PerfMetricsDCRps1 -SubscriptionId "YOUR-SUB-ID" -LawRG "YOUR-LAW-RG" -LawName "YOUR-LAW" -DcrRG "YOUR-DCR-RG" -DcrName "AVD-SessionHost-DCR" -Location "eastus2" -WhatIf` |
| Verbose + transcript | `.\AVD-Insights-Enable-PerfMetricsDCRps1 -SubscriptionId "YOUR-SUB-ID" -LawRG "YOUR-LAW-RG" -LawName "YOUR-LAW" -DcrRG "YOUR-DCR-RG" -DcrName "AVD-SessionHost-DCR" -Location "eastus2" -TranscriptPath "C:\Logs\dcr.log" -Verbose` |

## Features (v1.8)

- **Enhanced Monitoring**: 28 performance counters covering CPU, memory, disk (per-volume), AVD session quality (input delay, RTT, UDP, GPU), session lifecycle (Terminal Services), and network bandwidth
- **Progress Indicators**: Real-time progress bar with percentage complete
- **Idempotency Checks**: Automatically detects and skips existing associations
- **Transcript Support**: Optional logging of full script execution
- **WhatIf Mode**: Preview all changes without making any modifications
- **Verbose Logging**: Detailed diagnostic output with `-Verbose` flag
- **REST API Integration**: Uses Azure REST API for reliable session host enumeration

## Parameters

| Parameter | Required | Default | Description |
| --------- | -------- | ------- | ----------- |
| `SubscriptionId` | **Yes** | - | Azure subscription ID |
| `LawRG` | No | `rg-avd-monitoring` | Resource group of the Log Analytics workspace |
| `LawName` | No | `law-avd-prod` | Log Analytics workspace name |
| `DcrRG` | No | `rg-avd-monitoring` | Resource group where the DCR is created |
| `DcrName` | No | `AVD-SessionHost-DCR` | Name of the Data Collection Rule |
| `Location` | No | `EastUS2` | Azure region for the DCR |
| `SamplingFrequencyInSeconds` | No | `60` | Counter polling interval (10-3600 seconds) |
| `CounterSpecifiers` | No | 28 counters | Array of performance counter paths to collect |
| `TranscriptPath` | No | - | Optional path to save full script execution transcript |
| `InstallAma` | No | Off | Also check and install Azure Monitor Agent on session host VMs during DCR association |
| `AmaOnly` | No | Off | Run AMA validation/install workflow only (implies `-InstallAma`). Skips DCR create/update and associations |

## Counters Collected (Default - 28 Total)

### CPU (1)

| Counter | Description |
| ------- | ----------- |
| `Processor Information(_Total)\% Processor Time` | CPU utilization |

### Memory (4)

| Counter | Description |
| ------- | ----------- |
| `Memory\Available MBytes` | Free memory |
| `Memory\% Committed Bytes In Use` | Memory pressure |
| `Memory\Pages/sec` | Hard page faults requiring disk I/O |
| `Memory\Page Faults/sec` | Total page faults (soft + hard) |

### Disk Capacity (1)

| Counter | Description |
| ------- | ----------- |
| `LogicalDisk(*)\% Free Space` | Disk free space percentage (per volume) |

### Disk Latency (6)

| Counter | Description |
| ------- | ----------- |
| `LogicalDisk(*)\Avg. Disk sec/Read` | Logical disk read latency |
| `LogicalDisk(*)\Avg. Disk sec/Write` | Logical disk write latency |
| `LogicalDisk(*)\Avg. Disk sec/Transfer` | Logical disk overall latency |
| `PhysicalDisk(*)\Avg. Disk sec/Read` | Physical disk read latency |
| `PhysicalDisk(*)\Avg. Disk sec/Write` | Physical disk write latency |
| `PhysicalDisk(*)\Avg. Disk sec/Transfer` | Physical disk overall latency |

### Disk Queue (2)

| Counter | Description |
| ------- | ----------- |
| `LogicalDisk(*)\Current Disk Queue Length` | Logical disk queue depth |
| `PhysicalDisk(*)\Avg. Disk Queue Length` | Physical disk average queue depth |

### AVD Session Quality (5)

| Counter | Description |
| ------- | ----------- |
| `User Input Delay per Process(*)\Max Input Delay` | Per-process input delay |
| `User Input Delay per Session(*)\Max Input Delay` | Per-session input delay |
| `RemoteFX Network(*)\Current TCP RTT` | TCP round-trip latency |
| `RemoteFX Network(*)\Current UDP Bandwidth` | UDP bandwidth (RDP Shortpath) |
| `RemoteFX Graphics(*)\Average Encoding Time` | GPU encoding time (GPU hosts) |

### AVD Session Lifecycle (3)

| Counter | Description |
| ------- | ----------- |
| `Terminal Services\Active Sessions` | Active session count per host |
| `Terminal Services\Inactive Sessions` | Disconnected/idle session count |
| `Terminal Services\Total Sessions` | Total session count per host |

### Network Bandwidth (4)

| Counter | Description |
| ------- | ----------- |
| `Network Adapter(*)\Bytes Total/sec` | Total network throughput |
| `Network Adapter(*)\Bytes Received/sec` | Inbound network bandwidth |
| `Network Adapter(*)\Bytes Sent/sec` | Outbound network bandwidth |
| `Network Adapter(*)\Current Bandwidth` | Network adapter link speed |

### Network Queue (1)

| Counter | Description |
| ------- | ----------- |
| `Network Adapter(*)\Output Queue Length` | Network output queue depth |

## Requirements

- Azure CLI installed and logged in (`az login`)
- **Monitoring Contributor** on the DCR resource group and Log Analytics workspace
- **Desktop Virtualization Reader** on the subscription (for host pool discovery)
- The `desktopvirtualization` Azure CLI extension - installed automatically by the script if missing

## Usage

### Default mode: Create DCR + associate session hosts

```powershell
.\AVD-Insights-Enable-PerfMetricsDCRps1 `
  -SubscriptionId "YOUR-SUBSCRIPTION-ID" `
  -LawRG "rg-avd-monitoring" `
  -LawName "law-avd-prod" `
  -DcrRG "rg-avd-monitoring" `
  -DcrName "AVD-SessionHost-DCR" `
  -Location "eastus2"
```

The script will:

1. Create/update the DCR
2. Discover all host pools in the subscription
3. Display an interactive menu:

  ```text
   Discovered 5 host pool(s):
     [1] AVD-Pooled  (RG: rg-avd-pooled)
     [2] Contoso-AppSharePool  (RG: rg-avd-monitoring)
     [3] Contoso-EntraID-HostPool  (RG: rg-avd-entra)
     [4] Personal-Pool  (RG: rg-avd-monitoring)
     [5] SharedDesktops-Pool  (RG: rg-avd-shared)
   
   Associate DCR 'AVD-SessionHost-DCR' with session hosts in:
     [A] All host pools
     [S] Select specific host pools
     [N] Skip
   
   Choice:
   ```

### WhatIf mode: Preview changes without applying

```powershell
.\AVD-Insights-Enable-PerfMetricsDCRps1 `
  -SubscriptionId "YOUR-SUBSCRIPTION-ID" `
  -LawRG "rg-avd-monitoring" `
  -LawName "law-avd-prod" `
  -DcrRG "rg-avd-monitoring" `
  -DcrName "AVD-SessionHost-DCR" `
  -Location "eastus2" `
  -WhatIf
```

### With transcript logging and verbose output

```powershell
.\AVD-Insights-Enable-PerfMetricsDCRps1 `
  -SubscriptionId "YOUR-SUBSCRIPTION-ID" `
  -LawRG "rg-avd-monitoring" `
  -LawName "law-avd-prod" `
  -DcrRG "rg-avd-monitoring" `
  -DcrName "AVD-SessionHost-DCR" `
  -Location "eastus2" `
  -TranscriptPath "C:\Logs\DCR-Setup.log" `
  -Verbose
```

### With AMA install: Also install Azure Monitor Agent on VMs

```powershell
.\AVD-Insights-Enable-PerfMetricsDCRps1 `
  -SubscriptionId "YOUR-SUBSCRIPTION-ID" `
  -LawRG "rg-avd-monitoring" `
  -LawName "law-avd-prod" `
  -DcrRG "rg-avd-monitoring" `
  -DcrName "AVD-SessionHost-DCR" `
  -Location "eastus2" `
  -InstallAma
```

Same as default, but also checks each session host VM for the Azure Monitor Agent extension and installs it where missing.

### Skip confirmation prompts (unsafe - for automation)

```powershell
.\AVD-Insights-Enable-PerfMetricsDCRps1 `
  -SubscriptionId "YOUR-SUBSCRIPTION-ID" `
  -LawRG "rg-avd-monitoring" `
  -LawName "law-avd-prod" `
  -DcrRG "rg-avd-monitoring" `
  -DcrName "AVD-SessionHost-DCR" `
  -Location "eastus2" `
  -Confirm:$false
```

## Post-Deployment

After running with interactive association, the script prints a detailed summary:

```text
=== Association Summary ===
Total Pools Processed: 5
Successful: 14
Skipped (already associated): 0
Failed: 0
Duration: 01:55
```

Data appears in `InsightsMetrics` and `Perf` within 5-15 minutes.

## Verification

### Check DCR exists

```powershell
az monitor data-collection rule show `
  -g "rg-avd-monitoring" `
  -n "AVD-SessionHost-DCR" `
  -o table
```

### Verify association for a specific VM

```powershell
az monitor data-collection rule association list `
  --resource "/subscriptions/{sub-id}/resourceGroups/{rg}/providers/Microsoft.Compute/virtualMachines/{vm-name}" `
  --query "[?contains(dataCollectionRuleId, 'AVD-SessionHost-DCR')].{Name:name, DCR:dataCollectionRuleId}" `
  -o table
```

### Query data in Log Analytics

```kql
// Check InsightsMetrics table
InsightsMetrics
| where TimeGenerated > ago(1h)
| where Namespace == "Processor" or Namespace == "Memory" or Namespace == "LogicalDisk" or Namespace == "Network"
| summarize count() by Name, Namespace, bin(TimeGenerated, 5m)

// Check Perf table
Perf
| where TimeGenerated > ago(1h)
| where ObjectName in ("Processor", "Memory", "LogicalDisk", "PhysicalDisk", "Network Adapter")
| summarize count() by ObjectName, CounterName, bin(TimeGenerated, 5m)
```

## Troubleshooting

### Extension installation fails

If the `desktopvirtualization` extension fails to install automatically, install it manually:

```powershell
az extension add --name desktopvirtualization
```

### DCR creation fails with "InvalidPayload"

Common causes:

- **Datasource name too long** (max 32 chars) - Fixed in v1.6+
- **Invalid counter path** - Verify counter names match Windows Performance Monitor syntax

### Session host enumeration fails

The script uses Azure REST API to enumerate session hosts. If this fails:

1. Verify you have **Desktop Virtualization Reader** role on the subscription
2. Check the host pool exists: `az desktopvirtualization hostpool list -o table`
3. Run with `-Verbose` flag to see detailed error messages

### No data appearing in Log Analytics

Wait 5-15 minutes after association, then:

1. Verify the DCR association exists (see Verification section above)
2. Check the Azure Monitor Agent is installed on the VMs
3. Verify the VM has network connectivity to Azure Monitor endpoints

## Version History

- **v1.8** (2026-03-16): Added 11 AVD-specific counters (input delay, RTT, UDP, GPU, Terminal Services, memory pages, disk queue); changed disk instances from (_Total) to (*) for per-volume alerting (28 total counters)
- **v1.7** (2026-02-18): Enhanced disk latency and network bandwidth counters (17 counters)
- **v1.6** (2026-02-18): Fixed DCR datasource names, REST API for session hosts, division by zero guard
- **v1.5**: Enhanced with progress indicators, idempotency checks, transcript support
- **v1.0**: Initial release with basic DCR creation and manual association

## Related Links

- [Azure Virtual Desktop Insights](https://learn.microsoft.com/en-us/azure/virtual-desktop/insights)
- [Data Collection Rules](https://learn.microsoft.com/en-us/azure/azure-monitor/essentials/data-collection-rule-overview)
- [Azure Monitor Agent](https://learn.microsoft.com/en-us/azure/azure-monitor/agents/azure-monitor-agent-overview)
