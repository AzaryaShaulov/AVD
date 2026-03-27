# AVD Session Host Insights Monitoring

Script: `AVD-Insights-Enable-PerfMetrics-Monitoring.ps1`

## Purpose

This script gives operators a repeatable way to enable and standardize Azure Virtual Desktop (AVD) session host performance monitoring.

It handles two connected tasks in one run:

1. Create or update a Data Collection Rule (DCR) that sends host performance counters to Log Analytics.
2. Optionally assign and remediate the built-in AMA + DCR association policy so hosts are linked to the DCR at scale.

## What The Script Does

- Validates Azure CLI sign-in, subscription context, and required resource groups.
- Creates or updates one DCR that writes counters to both `InsightsMetrics` and `Perf`.
- Supports three execution modes:
  - `DcrOnly`
  - `DcrAndPolicy`
  - `DcrPolicyRemediation`
- Discovers host pools and resolves policy scope from:
  - all discovered host pool resource groups,
  - specific host pools, or
  - manual RG override list.
- Supports two policy assignment strategies:
  - `SingleAssignment` (default): one subscription-scope assignment limited by `notScopes`.
  - `PerResourceGroup`: one assignment per selected RG.
- Automatically falls back from `SingleAssignment` to `PerResourceGroup` if safe `notScopes` limits are exceeded.
- In `DcrOnly`, prints and records guidance that policy association is still required manually.
- Always writes a timestamped CSV report for audit and operations handoff.

## Why Use It (Advantages)

- Faster deployment: DCR and policy wiring are done in one workflow.
- Safer re-runs: operations are idempotent and designed for repeated execution.
- Flexible scope targeting: interactive and non-interactive options for broad or narrow rollouts.
- Better reliability at scale: assignment-mode fallback avoids oversized `notScopes` operations.
- Clear operator outcomes: console summary plus CSV status per scope.
- Automation-friendly: supports `-NonInteractive` and `-WhatIf` for pipeline and dry-run usage.

## Minimum Permissions By Execution Mode

Notes:

- Scope matters: for `SingleAssignment`, policy permissions are needed at subscription scope. For `PerResourceGroup`, they are needed on each targeted resource group.
- If `PolicyScopeResourceGroup` is provided, host-pool discovery permission is not required.

| Mode | Minimum Azure actions required | Practical minimum role guidance |
| --- | --- | --- |
| `DcrOnly` | `Microsoft.Resources/subscriptions/resourceGroups/read`, `Microsoft.OperationalInsights/workspaces/read`, `Microsoft.Insights/dataCollectionRules/read`, `Microsoft.Insights/dataCollectionRules/write` | Monitoring Contributor on DCR RG + Log Analytics Reader (or Reader) on LAW scope |
| `DcrAndPolicy` | All `DcrOnly` actions, plus `Microsoft.Authorization/policyAssignments/read`, `Microsoft.Authorization/policyAssignments/write`, `Microsoft.Authorization/policyAssignments/delete` (cleanup path), `Microsoft.Authorization/roleAssignments/write` (for assignment create with managed identity), and optionally `Microsoft.DesktopVirtualization/hostPools/read` (if discovery is used) | DCR permissions above + Policy Contributor at target scope + ability to create role assignments (for create path) |
| `DcrPolicyRemediation` | All `DcrAndPolicy` actions, plus `Microsoft.PolicyInsights/remediations/read`, `Microsoft.PolicyInsights/remediations/write` | `DcrAndPolicy` permissions + permission to create remediation tasks at target scope |

## 3 Simple Starter Examples

### 1) Interactive guided run (best first run)

```powershell
.\AVD-Insights-Enable-PerfMetrics-Monitoring.ps1 `
  -SubscriptionId "YOUR-SUBSCRIPTION-ID" `
  -LawRG "YOUR-LAW-RG" `
  -LawName "YOUR-LAW-NAME" `
  -DcrRG "YOUR-DCR-RG" `
  -DcrName "AVD-SessionHost-DCR" `
  -Location "eastus2"
```

Explanation: The script prompts for mode, scope, and confirmation. Use this when validating behavior in a new environment.

### 2) DCR-only dry run (safe preview)

```powershell
.\AVD-Insights-Enable-PerfMetrics-Monitoring.ps1 `
  -SubscriptionId "YOUR-SUBSCRIPTION-ID" `
  -LawRG "YOUR-LAW-RG" `
  -LawName "YOUR-LAW-NAME" `
  -DcrRG "YOUR-DCR-RG" `
  -NonInteractive `
  -ExecutionMode DcrOnly `
  -WhatIf
```

Explanation: Previews DCR changes only and outputs a reminder that policy association must be done manually in this mode.

### 3) Full non-interactive rollout for discovered host-pool RGs

```powershell
.\AVD-Insights-Enable-PerfMetrics-Monitoring.ps1 `
  -SubscriptionId "YOUR-SUBSCRIPTION-ID" `
  -LawRG "YOUR-LAW-RG" `
  -LawName "YOUR-LAW-NAME" `
  -DcrRG "YOUR-DCR-RG" `
  -NonInteractive `
  -ExecutionMode DcrPolicyRemediation `
  -ScopeSelection AllHostPoolResourceGroups
```

Explanation: Creates/updates DCR, assigns policy, and starts remediation across all discovered host-pool RGs.

## Key Parameters And Switches

| Parameter | Required | Default | Description |
| --- | --- | --- | --- |
| `SubscriptionId` | Yes | - | Azure subscription ID |
| `LawRG` | No | `rg-avd-monitoring` | Log Analytics workspace resource group |
| `LawName` | No | `law-avd-prod` | Log Analytics workspace name |
| `DcrRG` | No | `rg-avd-monitoring` | Resource group where DCR is created/updated |
| `DcrName` | No | `AVD-SessionHost-DCR` | DCR name |
| `Location` | No | `EastUS2` | Region for DCR and policy assignment identity |
| `SamplingFrequencyInSeconds` | No | `60` | Counter polling interval |
| `CounterSpecifiers` | No | Built-in list | Performance counters to collect |
| `PolicyAssignmentName` | No | Predefined display name | Policy assignment display name |
| `PolicyAssignmentResourceName` | No | `avd-sessionhost-ama-dcr` | Policy assignment resource name |
| `PolicyAssignmentMode` | No | `SingleAssignment` | `SingleAssignment` or `PerResourceGroup` |
| `PolicyDefinitionId` | No | `244efd75-...` | Policy definition id for AMA + DCR association |
| `ExecutionMode` | No | `DcrPolicyRemediation` | `DcrOnly`, `DcrAndPolicy`, `DcrPolicyRemediation` |
| `ScopeSelection` | No | `AllHostPoolResourceGroups` | Scope strategy in non-interactive mode |
| `HostPoolNames` | No | - | Host pools used when `ScopeSelection` is `SpecificHostPools` |
| `PolicyScopeResourceGroup` | No | - | Manual policy scope RG list override |
| `ReportPath` | No | Script folder | CSV output directory or base filename |
| `TranscriptPath` | No | - | Optional transcript output file |
| `NonInteractive` | Switch | Off | Skip prompts |
| `SkipRemediationTask` | Switch | Off | Downgrades remediation mode to policy-only |
| `WhatIf` | Switch | Off | Preview changes without applying |

## CSV Report Output

Output file pattern:

`avd-dcr-policy-report-yyyyMMdd-HHmmss.csv`

The report includes:

- subscription and action mode
- DCR name and DCR id
- host pool name(s) and target RG
- policy assignment id
- remediation task name
- status, error message, and duration

Common status values include:

- `DcrSuccess`, `DcrWhatIf`
- `PolicySuccess`, `PolicyWhatIf`
- `PolicyRemediationSuccess`
- `Failed`, `FatalError`

## Quick Verification Commands

Check DCR:

```powershell
az monitor data-collection rule show `
  -g "YOUR-DCR-RG" `
  -n "AVD-SessionHost-DCR" `
  -o table
```

Check subscription-scope assignment (default consolidated mode):

```powershell
az policy assignment show `
  --scope "/subscriptions/<sub-id>" `
  --name "avd-sessionhost-ama-dcr" `
  -o table
```

Check remediation task:

```powershell
az policy remediation show `
  -n "avd-sessionhost-ama-dcr-remediate" `
  -o table
```

## Troubleshooting

- If host pool discovery fails, verify permission for `Microsoft.DesktopVirtualization/hostPools/read`.
- If policy assignment fails, verify `Microsoft.Authorization/policyAssignments/write` at scope.
- If remediation fails, verify the assignment exists and rerun remediation mode.
- If metrics are delayed, allow 5-15 minutes for first ingestion into `InsightsMetrics` and `Perf`.

## Version History

- v2.3 (2026-03-26): Performance-focused CLI round-trip reduction, assignment guardrails/fallback, duplicate cleanup, and DCR-only guidance in console + CSV
- v2.1 (2026-03-26): Interactive execution/scope workflow, per-RG policy processing, mandatory timestamped CSV reporting
- v2.0 (2026-03-26): Policy-first AMA + DCR association model
