# Azure Virtual Desktop — Diagnostics, Insights & Rich Email Alert Automation

**Last Updated:** March 2026

PowerShell automation for Azure Virtual Desktop that goes beyond standard Azure Monitor alert emails. These scripts deploy **rich, detailed email alerts** powered by Logic Apps that re-query Log Analytics at alert time — delivering operator-friendly HTML emails with affected host names, error codes, user names, and troubleshooting context that standard Azure Monitor notifications don't include.

**What it delivers:**

- **16 WVDErrors category alerts** — connection failures, authentication errors, session host health, FSLogix profile issues, network/gateway problems, bandwidth drops, round-trip latency, sign-in delays, and frame quality degradation
- **7 Insights performance alerts** — CPU saturation, memory pressure, disk latency/capacity, input delay, session quality (RTT, UDP), GPU encoding, session lifecycle, and FSLogix correlation
- **Diagnostic log enablement** — auto-discovers and configures all AVD resources in a subscription
- **Data Collection Rules** — 28 perf counters (CPU, memory, disk, network, GPU, AVD session quality) collected via Azure Monitor Agent

## Repository Structure

```text
AVD/
├── AVD-Diagnostics/           # Enable diagnostic logs on all AVD resources
├── AVD-AzAlerts/              # WVDErrors category alerts + Logic App email pipeline
├── AVD-SessionHostMonitoring/ # Perf counter DCR + interactive policy/remediation targeting
│   └── AVD-Insights-Enable-PerfMetrics-Monitoring.ps1
├── AVD-SessionHost-Insights-Alerts/ # 7 category alert rules + Logic App email pipeline
└── README.md
```

## AVD Projects at a Glance

| Project Folder | Purpose | What It Is Used For | How It Helps Customer AVD Deployments | Folder Link |
| -- | -- | -- | -- | -- |
| `AVD-Diagnostics` | Enable diagnostic settings across all AVD resources (host pools, app groups, workspaces). | Foundation step before alerting, troubleshooting, and audit workflows. | Ensures consistent telemetry coverage in Log Analytics so operations teams can detect, investigate, and prove service health without manual per-resource setup. | [AVD-Diagnostics](AVD-Diagnostics/) |
| `AVD-AzAlerts` | Deploy WVDErrors-based category alerts and a Logic App pipeline for detailed emails. | Monitoring connection failures, authentication/authorization issues, session host health, network/gateway problems, and FSLogix profile errors. | Delivers actionable alert emails with host names, error codes, and troubleshooting context, reducing time to triage and restore user access. | [AVD-AzAlerts](AVD-AzAlerts/) |
| `AVD-SessionHostMonitoring` | Create or update DCR-based performance collection and optional AMA or DCR policy association at scale. | Standing up Insights telemetry for CPU, memory, disk, network, GPU, and session quality counters across session hosts. | Standardizes data collection and policy rollout with safe re-runs, giving customers consistent performance baselines for capacity planning and proactive operations. | [AVD-SessionHostMonitoring](AVD-SessionHostMonitoring/) |
| `AVD-SessionHost-Insights-Alerts` | Deploy 7 consolidated session-host Insights alert categories and detailed email workflow. | Monitoring performance degradation, session lifecycle issues, disk pressure, correlated FSLogix signals, event logs, and GPU encoding behavior. | Provides context-rich performance alerts with specific breached counters and affected hosts so teams can act quickly before widespread end-user impact. | [AVD-SessionHost-Insights-Alerts](AVD-SessionHost-Insights-Alerts/) |

## Monitoring Decision Guide

Use this diagram to choose the correct AVD deployment path based on the monitoring outcome you need.

![AVD Monitoring Decision Guide](assets/avd-monitoring-decision-guide.svg)

Use the links in the Documentation section below for full deployment commands and runbooks.

## Important Notes

### <span style="color:#b00020;">WorkspaceName Guidance</span>

If there is already an existing AVD Log Analytics workspace (including Nerdio-managed environments), reuse it. Do not create a new workspace unless needed.

### <span style="color:#b00020;">Diagnostics Must Be Enabled First</span>

Run `AVD-Diagnostics/AVD-Enable-Diagnostic-Logs.ps1` before deploying alerts unless AVD diagnostics are already enabled. Without diagnostic logs in Log Analytics, AVD alert queries do not have data to evaluate.
Run `AVD-SessionHostMonitoring/AVD-Insights-Enable-PerfMetrics-Monitoring.ps1` to enable Insights telemetry for CPU, memory, disk, IOPS, network, GPU, and session quality counters across session hosts.

### <span style="color:#b00020;">Office 365 Connection Authorization</span>

Both Logic App scripts auto-create the Office 365 API connection, but it must be manually authorized in Azure Portal with valid mailbox credentials before emails will flow.

## Documentation

| Area | Link |
| ------ | ------ |
| AVD Diagnostics | [AVD-Diagnostics/README.md](AVD-Diagnostics/README.md) |
| WVDErrors Alerts | [AVD-AzAlerts/README.md](AVD-AzAlerts/README.md) |
| Alert Matrix (WVDErrors) | [AVD-AzAlerts/AVD-Alerts-Matrix.md](AVD-AzAlerts/AVD-Alerts-Matrix.md) |
| Runbook (WVDErrors) | [AVD-AzAlerts/AVD-Alerts-Runbook.md](AVD-AzAlerts/AVD-Alerts-Runbook.md) |
| DCR / AMA Setup | [AVD-SessionHostMonitoring/README.md](AVD-SessionHostMonitoring/README.md) |
| Insights Alerts | [AVD-SessionHost-Insights-Alerts/README.md](AVD-SessionHost-Insights-Alerts/README.md) |
| Alert Matrix (Insights) | [AVD-SessionHost-Insights-Alerts/Insights-Alert-Matrix.md](AVD-SessionHost-Insights-Alerts/Insights-Alert-Matrix.md) |
| Runbook (Insights) | [AVD-SessionHost-Insights-Alerts/Insights-Runbook.md](AVD-SessionHost-Insights-Alerts/Insights-Runbook.md) |

## Related Resources

- [Azure Virtual Desktop documentation](https://learn.microsoft.com/azure/virtual-desktop/)
- [Monitor AVD with Azure Monitor](https://learn.microsoft.com/azure/virtual-desktop/monitor-azure-virtual-desktop)
- [AVD Insights workbook](https://learn.microsoft.com/azure/virtual-desktop/insights)

## License

See `LICENSE` for details.

## Disclaimer

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED.

These scripts are provided as-is under the MIT License. Always validate in a non-production environment before production rollout.
