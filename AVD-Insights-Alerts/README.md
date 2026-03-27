# AVD Insights Alerts

**Rich performance and session lifecycle alerting** for Azure Virtual Desktop — delivering detailed, operator-friendly HTML emails that go beyond standard Azure Monitor notifications.

Standard Azure Monitor alert emails show only the alert name and a portal link. These alerts use a **Logic App webhook pipeline** that re-queries Log Analytics when an alert fires, producing emails with specific counter values, affected session host names, threshold breaches, and inline troubleshooting context — so operators can assess and act without opening the Azure Portal.

Driven by AVD Insights data: Perf counters (28 metrics via DCR), WVDCheckpoints, and WVDAgentHealthStatus.

## Overview

This solution **complements** the existing [AVD-AzAlerts](../../AVD-AzAlerts/) WVDErrors-category alerts by monitoring the session host **performance counters** and **session lifecycle signals** that AVD Insights collects via Azure Monitor Agent and Data Collection Rules.

### What It Monitors

| Category | Alert Rule | Signals | Data Source |
|----------|-----------|---------|-------------|
| Session Quality | AVD-Insights-Category-SessionQuality | InputDelay (Process/Session), RTT Latency, UDP Bandwidth | Perf (User Input Delay, RemoteFX Network) |
| Host Performance | AVD-Insights-Category-HostPerformance | CPU, Memory, Commit Ratio, Pages/sec, Page Faults, Disk Timing | Perf (Processor, Memory, LogicalDisk) |
| Disk Health | AVD-Insights-Category-DiskHealth | Queue Length, Free Space | Perf (PhysicalDisk, LogicalDisk) |
| Session Lifecycle | AVD-Insights-Category-SessionLifecycle | Sign-In Duration, Capacity Pressure, Session Imbalance | WVDCheckpoints, WVDAgentHealthStatus, Perf (Terminal Services) |
| Correlated Signals | AVD-Insights-Category-CorrelatedSignals | Multi-signal Hosts, FSLogix+Perf | Perf + WVDCheckpoints + Event |
| Event Log Alerts | AVD-Insights-Category-EventLogAlerts | FSLogix Profile Error | Event (FSLogix operational/admin logs) |
| GPU Performance | AVD-Insights-Category-GPUPerformance | GPU Encoding Time | Perf (RemoteFX Graphics) |

**7 category-consolidated alerts** (covering 19 sub-signals) across 7 categories. Each category alert unions all its sub-signals into a single scheduled-query rule — the alert fires when ANY signal in the category breaches its threshold. All thresholds are config-driven via `alerts-config.insights.json`.

## Script Reference

| # | Script | Purpose | What It Does | Quick Start (copy & paste) |
| -- | ------ | ------- | ------------ | -------------------------- |
| 1 | `AVD-Insights-Alerts-Precheck.ps1` | Validate prerequisites | Checks RBAC permissions, Azure CLI extensions, LAW connectivity, and verifies Perf counter data flow. Read-only — no changes made. | `.\AVD-Insights-Alerts-Precheck.ps1 -SubscriptionId "YOUR-SUB-ID" -ResourceGroupName "YOUR-RG" -WorkspaceName "YOUR-LAW"` |
| 2 | `AVD-Insights-Deploy-LogicApp.ps1` | **Primary: deploy alerts + email pipeline** | Creates/updates the Logic App, Office 365 API connection, webhook action group, assigns Log Analytics Reader to the Logic App managed identity, and bootstraps all 7 `AVD-Insights-Category-*` alerts. Single command does everything. | `.\AVD-Insights-Deploy-LogicApp.ps1 -SubscriptionId "YOUR-SUB-ID" -ResourceGroupName "YOUR-RG" -LogicAppName "AVD-Insights-Alert-Email" -Location "eastus2" -WorkspaceName "YOUR-LAW" -WorkspaceResourceGroupName "YOUR-LAW-RG" -SendFromEmail "alerts@contoso.com" -SendToEmail "team@contoso.com"` |
| 3 | `AVD-Insights-Category-Alerts.ps1` | Create alert rules only | Reads definitions from `alerts-config.insights.json`, loads KQL query files, and creates Azure Monitor scheduled query rules. Called automatically by script #2 — run directly only for standalone alert creation or re-deploy after threshold changes. | `.\AVD-Insights-Category-Alerts.ps1 -ResourceGroup "YOUR-RG" -WorkspaceName "YOUR-LAW" -Location "eastus2"` |

**Additional modes:**

| Mode | Command |
| ---- | ------- |
| WhatIf (dry run) | `.\AVD-Insights-Category-Alerts.ps1 -ResourceGroup "YOUR-RG" -WorkspaceName "YOUR-LAW" -Location "eastus2" -WhatIf` |
| Single category | `.\AVD-Insights-Category-Alerts.ps1 -ResourceGroup "YOUR-RG" -WorkspaceName "YOUR-LAW" -Location "eastus2" -CategoryFilter "HostPerformance"` |
| Override severity | `.\AVD-Insights-Category-Alerts.ps1 -ResourceGroup "YOUR-RG" -WorkspaceName "YOUR-LAW" -Location "eastus2" -Severity 1` |

## Prerequisites

1. **Azure Monitor Agent (AMA)** deployed on session hosts
2. **Data Collection Rule** sending Perf counters to your Log Analytics workspace  
   (See [AVD-Insights-Enable-PerfMetrics-Monitoring.ps1](../AVD-Insights-Enable-PerfMetrics-Monitoring.ps1))
3. **AVD Diagnostics** enabled (WVDCheckpoints, WVDAgentHealthStatus tables)
4. **Azure CLI** with `scheduled-query` extension
5. RBAC: **Monitoring Contributor** + **Log Analytics Reader** (or Owner/Contributor)

## File Structure

```
AVD-Insights-Alerts/
├── alerts-config.insights.json          # Alert definitions and thresholds (7 categories)
├── queries/                             # KQL query files
│   ├── category-session-quality.kql     # Consolidated: InputDelay + RTT + UDP
│   ├── category-host-performance.kql    # Consolidated: CPU + Memory + Disk Timing
│   ├── category-disk-health.kql         # Consolidated: Queue Length + Free Space
│   ├── category-session-lifecycle.kql   # Consolidated: SignIn + Capacity + Imbalance
│   ├── category-correlated-signals.kql  # Consolidated: Multi-signal + FSLogix
│   ├── category-event-log-alerts.kql    # FSLogix profile errors
│   ├── category-gpu-performance.kql     # GPU encoding time
│   ├── input-delay.kql                  # Individual signal (used by LogicApp re-queries)
│   ├── round-trip-latency.kql
│   ├── input-delay-session.kql
│   ├── udp-bandwidth.kql
│   ├── cpu-saturation.kql
│   ├── memory-pressure.kql
│   ├── memory-commit-ratio.kql
│   ├── memory-pages-per-sec.kql
│   ├── page-faults.kql
│   ├── disk-timing.kql
│   ├── disk-queue-length.kql
│   ├── disk-free-space.kql
│   ├── signin-degradation.kql
│   ├── capacity-pressure.kql
│   ├── session-imbalance.kql
│   ├── correlated-hosts.kql
│   ├── fslogix-correlation.kql
│   ├── fslogix-profile-error.kql
│   └── gpu-encoding-time.kql
├── AVD-Insights-Deploy-LogicApp.ps1     # **Primary**: deploys Logic App + bootstraps alerts
├── AVD-Insights-Category-Alerts.ps1       # Advanced: deploy/update alerts only
├── AVD-Insights-Alerts-Precheck.ps1     # RBAC & data flow validation
├── README.md                            # This file
├── Insights-Alert-Matrix.md             # Alert reference matrix
└── Insights-Runbook.md                  # Operational runbook
```

## Deployment

### Recommended: Single-Command Deploy (Logic App + Alerts)

The **primary entry point** is `AVD-Insights-Deploy-LogicApp.ps1`. It deploys the Logic App email pipeline and automatically **bootstraps any missing AVD-Insights alerts** via `AVD-Insights-Category-Alerts.ps1`. If all 7 category alerts already exist, the bootstrap step is skipped.

#### Step 1 (Optional): Run Pre-Checks

```powershell
.\AVD-Insights-Alerts-Precheck.ps1 `
  -SubscriptionId "YOUR-SUBSCRIPTION-ID" `
  -ResourceGroupName "rg-avd-prod" `
  -WorkspaceName "law-avd-prod"
```

This validates RBAC, Azure CLI extensions, LAW connectivity, and verifies Perf counter data flow.

#### Step 2: Deploy Everything

```powershell
.\AVD-Insights-Deploy-LogicApp.ps1 `
  -SubscriptionId "YOUR-SUBSCRIPTION-ID" `
  -ResourceGroupName "rg-avd-prod" `
  -LogicAppName "AVD-Insights-Alert-Email" `
  -Location "eastus2" `
  -WorkspaceName "law-avd-prod" `
  -WorkspaceResourceGroupName "rg-avd-prod" `
  -SendToEmail "avdops@contoso.com" `
  -SendFromEmail "alerts@contoso.com"
```

This single command will:
1. Create/update the Office 365 API connection
2. Resolve the Log Analytics workspace
3. Deploy the Logic App with system-assigned managed identity
4. Assign **Log Analytics Reader** RBAC to the Logic App identity
5. Create the **AVD-Insights-Detailed** webhook action group pointing to the Logic App callback URL
6. **Bootstrap** any missing AVD-Insights category alerts (calls `AVD-Insights-Category-Alerts.ps1` internally)
7. Switch all AVD-Insights alerts to the detailed-only action group

> **Note:** The Office 365 API connection may require manual authorization in Azure Portal before emails flow.

### Advanced: Deploy Alerts Only

Use `AVD-Insights-Category-Alerts.ps1` directly when you need to:
- Deploy alerts **without** the Logic App email pipeline
- Re-deploy or update specific alerts (e.g., after editing KQL thresholds)
- Use a different action group or webhook target

```powershell
.\AVD-Insights-Category-Alerts.ps1 `
  -ResourceGroup "rg-avd-prod" `
  -WorkspaceName "law-avd-prod" `
  -Location "eastus2" `
  -WebhookUrl "https://your-webhook-url"
```

## Common Operations

### Preview Changes (Dry Run)

```powershell
.\AVD-Insights-Category-Alerts.ps1 -ResourceGroup "rg-avd" -WorkspaceName "law-avd" -Location "eastus2" -WhatIf
```

### Deploy a Single Category

```powershell
.\AVD-Insights-Category-Alerts.ps1 ... -CategoryFilter "HostPerformance"
```

### Deploy a Single Alert

```powershell
.\AVD-Insights-Category-Alerts.ps1 ... -AlertFilter "AVD-Insights-Category-HostPerformance"
```

### Override Severity

```powershell
.\AVD-Insights-Category-Alerts.ps1 ... -Severity 1   # Error
```

### Tune Thresholds

Thresholds are defined as `let` variables at the top of each `queries/category-*.kql` file. Edit the KQL files directly to change thresholds, then re-deploy with `-CreateOnly $false`. The `alerts-config.insights.json` file documents the threshold values for reference but is not injected into the KQL at deploy time.

## Dependency Diagram

```mermaid
flowchart TD
    subgraph Prerequisites
        AMA["Azure Monitor Agent<br>on Session Hosts"]
        DCR["Data Collection Rule<br>(Perf + InsightsMetrics)"]
        DIAG["AVD Diagnostics<br>(WVDCheckpoints, AgentHealth)"]
    end

    subgraph "Primary Deployment (recommended)"
        PRE["AVD-Insights-Alerts-Precheck.ps1<br>RBAC + data flow check"]
        LA["AVD-Insights-Deploy-LogicApp.ps1<br>Logic App + bootstrap alerts"]
    end

    subgraph "Bootstrapped Automatically"
        CFG["alerts-config.insights.json<br>thresholds & metadata"]
        KQL["queries/category-*.kql<br>7 consolidated KQL files"]
        DEPLOY["AVD-Insights-Category-Alerts.ps1<br>creates scheduled query rules"]
    end

    AMA --> DCR
    DCR --> |Perf data| LA
    DIAG --> |WVD tables| LA
    PRE --> |validates| LA
    LA --> |bootstraps missing alerts| DEPLOY
    CFG --> |thresholds| DEPLOY
    KQL --> |queries| DEPLOY
```

## Related

- [AVD-AzAlerts](../../AVD-AzAlerts/) - WVDErrors category alerts (connection failures, auth errors)
- [AVD-Insights-Enable-PerfMetrics-Monitoring.ps1](../AVD-Insights-Enable-PerfMetrics-Monitoring.ps1) - DCR and AMA setup
- [Insights-Alert-Matrix.md](Insights-Alert-Matrix.md) - Full alert reference
- [Insights-Runbook.md](Insights-Runbook.md) - Operational procedures
