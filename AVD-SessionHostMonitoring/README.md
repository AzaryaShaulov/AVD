# AVD Session Host Insights Monitoring

This script automates Azure Virtual Desktop session host performance monitoring by creating a Data Collection Rule (DCR) that sends performance counters to a Log Analytics workspace in both the `InsightsMetrics` and `Perf` tables. It then automatically discovers all session hosts in a specified host pool and associates the DCR with each underlying VM, enabling AVD Insights and VM Insights dashboards with a single run.

## What It Does

- Creates or updates a DCR that collects performance counters into **two** tables:
  - `InsightsMetrics` — consumed by VM Insights dashboards and workbooks
  - `Perf` — consumed by Log Analytics queries and AVD Insights
- Validates the DCR was created by resolving its resource ID
- **Auto-associates** the DCR with all session host VMs in the specified host pool (when `-HostPoolName` / `-HostPoolRG` are provided)
  - Automatically installs the `desktopvirtualization` Azure CLI extension if not present
  - Reports per-VM success/fail counts
- Falls back to printing the manual association command when host pool parameters are omitted

## Parameters

| Parameter | Required | Default | Description |
|---|---|---|---|
| `SubscriptionId` | **Yes** | — | Azure subscription ID |
| `LawRG` | No | `AVD-rg` | Resource group of the Log Analytics workspace |
| `LawName` | No | `AVD-Law` | Log Analytics workspace name |
| `DcrRG` | No | `AVD-rg` | Resource group where the DCR is created |
| `DcrName` | No | `AVD-SessionHost-DCR` | Name of the Data Collection Rule |
| `Location` | No | `EastUS2` | Azure region for the DCR |
| `HostPoolName` | No | — | AVD host pool to auto-associate; enables session host enumeration |
| `HostPoolRG` | No | — | Resource group of the host pool (required with `HostPoolName`) |
| `SamplingFrequencyInSeconds` | No | `60` | Counter polling interval in seconds |
| `CounterSpecifiers` | No | 9 standard counters | Array of performance counter paths to collect |

## Counters Collected (Default)

| Counter | Description |
|---|---|
| `Processor(_Total)\% Processor Time` | CPU utilization |
| `Memory\Available MBytes` | Free memory |
| `Memory\% Committed Bytes In Use` | Memory pressure |
| `LogicalDisk(_Total)\% Free Space` | Disk free space |
| `LogicalDisk(_Total)\Avg. Disk sec/Read` | Disk read latency |
| `LogicalDisk(_Total)\Avg. Disk sec/Write` | Disk write latency |
| `LogicalDisk(_Total)\Current Disk Queue Length` | Disk queue depth |
| `Network Adapter(*)\Bytes Total/sec` | Network throughput |
| `Network Adapter(*)\Output Queue Length` | Network queue depth |

## Requirements

- Azure CLI installed and logged in (`az login`)
- **Monitoring Contributor** on the DCR resource group and Log Analytics workspace
- **Desktop Virtualization Reader** on the host pool resource group (required for auto-association)
- The `desktopvirtualization` Azure CLI extension — installed automatically by the script if missing

## Usage

### Create DCR and auto-associate with all session hosts

```powershell
.\AVD-Enable-SessionHost-Insights-Monitoring.ps1 `
  -SubscriptionId "YOUR-SUB-ID" `
  -LawRG "az-infra-eus2" `
  -LawName "AVD-LAW" `
  -DcrRG "az-infra-eus2" `
  -DcrName "AVD-SessionHost-DCR" `
  -Location "eastus2" `
  -HostPoolName "AVD-HostPool" `
  -HostPoolRG "az-avd-rg"
```

### Create DCR only (manual association)

```powershell
.\AVD-Enable-SessionHost-Insights-Monitoring.ps1 `
  -SubscriptionId "YOUR-SUB-ID" `
  -LawRG "az-infra-eus2" `
  -LawName "AVD-LAW" `
  -DcrRG "az-infra-eus2" `
  -DcrName "AVD-SessionHost-DCR" `
  -Location "eastus2"
```

Use `-WhatIf` with either invocation to preview all actions without making any changes.

## Post-Deployment

When `-HostPoolName` is provided, the script associates the DCR automatically and prints a success/fail summary.

When host pool parameters are omitted, the script prints the manual command to run per VM:

```powershell
az monitor data-collection rule association create `
  --name "assoc-AVD-SessionHost-DCR" `
  --resource "<VM-Resource-Id>" `
  --rule-id "<DCR-Id>"
```

Data appears in `InsightsMetrics` and `Perf` within 5–15 minutes.
