# AVD Session Host Insights Monitoring

Configures an Azure Monitor **Data Collection Rule (DCR)** that captures performance counters from Azure Virtual Desktop session hosts into a Log Analytics workspace.

## What It Does

- Creates or updates a DCR that collects the same set of performance counters into **two** tables:
  - `InsightsMetrics` — consumed by VM Insights dashboards and workbooks
  - `Perf` — consumed by Log Analytics queries and AVD Insights
- Writes DCR JSON to a temp file and deploys it via Azure CLI (`az monitor data-collection rule create`)
- Validates the DCR was created by resolving its resource ID
- Outputs the ready-to-run `az` command to associate the DCR with your session host VMs

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
- Caller identity needs **Monitoring Contributor** on the DCR resource group and the Log Analytics workspace

## Usage

```powershell
.\AVD-Enable-SessionHost-Insights-Monitoring.ps1 `
  -SubscriptionId "YOUR-SUB-ID" `
  -LawRG "az-infra-eus2" `
  -LawName "AVD-LAW" `
  -DcrRG "az-infra-eus2" `
  -DcrName "AVD-SessionHost-DCR" `
  -Location "eastus2"
```

Use `-WhatIf` to preview without making any changes.

## Post-Deployment

The script outputs the association command once the DCR is ready. Run it for each session host VM:

```powershell
az monitor data-collection rule association create `
  --name "assoc-AVD-SessionHost-DCR" `
  --resource "<VM-Resource-Id>" `
  --rule-id "<DCR-Id>"
```

Data appears in `InsightsMetrics` and `Perf` within 5–15 minutes.
