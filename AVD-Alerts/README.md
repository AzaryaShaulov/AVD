# AVD Alerts Scripts Guide

**Last Updated:** March 2026

This folder contains production-focused PowerShell scripts for deploying and maintaining Azure Virtual Desktop (AVD) alerting.

These scripts complement Azure Virtual Desktop Insights by adding proactive, category-based alerting from Log Analytics data.

## Scripts In Scope

1. `Azure-AVD-Alerts.ps1`
Creates and maintains core `AVD-Category-*` scheduled query alerts and the primary email action group (`AVD-Alerts`).

2. `Deploy-AVD-AlertWebhook-LogicApp-v2.ps1`
Deploys/updates the detailed email Logic App (`AVD-alert-details`), ensures Office365 API connection exists, assigns Log Analytics Reader to Logic App managed identity, and ensures detailed webhook action group (`AVD-Alerts-Detailed`).

3. `AzureRoles-precheck.ps1`
Validates required RBAC permissions for deploying and maintaining the alert stack.

4. `Send-AVD-Webhook-TestAlert.ps1`
Posts a synthetic Azure Monitor common alert payload to validate the detailed webhook flow end-to-end.

## Run Order

1. Start with `Azure-AVD-Alerts.ps1`.
2. Optionally run `Deploy-AVD-AlertWebhook-LogicApp-v2.ps1` for rich detailed emails.
3. Optionally run `Send-AVD-Webhook-TestAlert.ps1` to validate callback processing.
4. Use `AzureRoles-precheck.ps1` before deployment or role changes.

## Dependency Diagram

```mermaid
flowchart TD
    R[Azure-AVD-Alerts.ps1] --> SQ[Scheduled Query Rules AVD-Category-*]
    SQ --> AG1[Action Group AVD-Alerts]
    SQ --> AG2[Action Group AVD-Alerts-Detailed optional]

    AG2 --> LA[Logic App AVD-alert-details]
    LA --> LAW[Log Analytics Workspace]
    LA --> O365[Office365 API Connection]
    O365 --> M[Detailed Email Delivery]

    D[Deploy-AVD-AlertWebhook-LogicApp-v2.ps1] --> LA
    D --> AG2
    D --> O365

    T[Send-AVD-Webhook-TestAlert.ps1] --> LA
```

## Execution Sequence

```mermaid
sequenceDiagram
  autonumber
  actor Eng as Engineer
  participant Pre as AzureRoles-precheck.ps1
  participant Dep as Deploy-AVD-AlertWebhook-LogicApp-v2.ps1
  participant Core as Azure-AVD-Alerts.ps1
  participant Mon as Azure Monitor Scheduled Query Rules
  participant AGD as AVD-Alerts-Detailed Action Group
  participant LA as Logic App AVD-alert-details
  participant LAW as Log Analytics Workspace
  participant O365 as Office365 Connector
  participant Test as Send-AVD-Webhook-TestAlert.ps1

  Eng->>Pre: Validate required RBAC
  Pre-->>Eng: PASS or FAIL report

  Eng->>Dep: Deploy detailed notifier
  Dep->>LA: Deploy or update workflow
  Dep->>Dep: Ensure Office365 connection
  Dep->>LAW: Assign Log Analytics Reader to Logic App MI
  Dep->>AGD: Ensure webhook receiver points to callback URL
  Dep-->>Eng: Callback URL ready

  Eng->>Core: Create or update AVD-Category alerts
  Core->>Mon: Configure scheduled query rules
  Mon->>AGD: Fire webhook notification on match
  AGD->>LA: Invoke callback URL with alert payload
  LA->>LAW: Query WVDErrors for alert window
  LAW-->>LA: Return result rows
  LA->>O365: Send detailed email

  Eng->>Test: Optional synthetic payload test
  Test->>LA: Post test alert payload
```

## Prerequisites

- Azure CLI installed and authenticated (`az login`)
- Azure CLI `scheduled-query` extension available
- Target Log Analytics workspace receiving AVD diagnostics
- Required RBAC on target subscription/resource groups/workspace

## Minimum RBAC / Roles

| Script | Minimum RBAC / Role | Notes |
|---|---|---|
| `Azure-AVD-Alerts.ps1` | `Monitoring Contributor` on target resource group + workspace read access | Creates/updates scheduled query alerts and action groups. |
| `Deploy-AVD-AlertWebhook-LogicApp-v2.ps1` | `Contributor` on target resource group; ability to assign role at LAW scope when needed | Deploys Logic App, manages Office365 connection/action group, assigns `Log Analytics Reader` to Logic App MI. |
| `AzureRoles-precheck.ps1` | Read access to role assignments/role definitions in relevant scopes | Evaluates required Azure actions across scopes. |
| `Send-AVD-Webhook-TestAlert.ps1` | `Logic App Contributor` (or `Contributor`) on target resource group | Resolves callback URL and invokes test payload. |

## What Each Script Changes

| Script | Azure Resources Changed | External Calls | Local Files |
|---|---|---|---|
| `Azure-AVD-Alerts.ps1` | Creates/updates `AVD-Category-*` scheduled query rules, ensures `AVD-Alerts`, optionally ensures `AVD-Alerts-Detailed` on existing alerts | Azure control plane via `az` | Writes CSV report (`avd-alerts-report*.csv`) |
| `Deploy-AVD-AlertWebhook-LogicApp-v2.ps1` | Creates/updates Logic App `AVD-alert-details`, ensures `Microsoft.Web/connections` (Office365), ensures `AVD-Alerts-Detailed` receiver, role assignment to LAW | Azure control plane; Logic App runtime calls Log Analytics and Office365 connector | Temporary deployment JSON in OS temp path (cleaned up) |
| `AzureRoles-precheck.ps1` | No persistent resource changes | Azure control plane reads role assignments/definitions | No local output by default |
| `Send-AVD-Webhook-TestAlert.ps1` | No persistent resource changes | Posts sample payload to Logic App callback URL | No persistent local output |

## Sample Usage

### 1) Core Alerts (Run First)

```powershell
pwsh -NoProfile -File .\Azure-AVD-Alerts.ps1 `
  -EmailTo "alerts@contoso.com" `
  -ResourceGroup "rg-avd-prod" `
  -LawName "law-avd-prod" `
  -Location "eastus2"
```

### 2) Detailed Email Notifier (Optional)

```powershell
pwsh -NoProfile -File .\Deploy-AVD-AlertWebhook-LogicApp-v2.ps1 `
  -SubscriptionId "YOUR-SUBSCRIPTION-ID" `
  -ResourceGroupName "rg-avd-prod" `
  -LogicAppName "AVD-alert-details" `
  -Location "eastus2" `
  -WorkspaceName "law-avd-prod" `
  -WorkspaceResourceGroupName "rg-avd-prod" `
  -SendFromEmail "alerts@contoso.com" `
  -SendToEmail "avd-oncall@contoso.com" `
  -Office365ConnectionName "avd-alerts-office365"
```

### 3) RBAC Precheck (Recommended)

```powershell
pwsh -NoProfile -File .\AzureRoles-precheck.ps1 `
  -SubscriptionId "YOUR-SUBSCRIPTION-ID" `
  -ResourceGroupName "rg-avd-prod" `
  -WorkspaceName "law-avd-prod" `
  -WorkspaceResourceGroupName "rg-avd-prod" `
  -RequireRoleAssignmentWrite
```

### 4) Test Payload Sender (Optional)

```powershell
pwsh -NoProfile -File .\Send-AVD-Webhook-TestAlert.ps1 `
  -ResourceGroup "rg-avd-prod" `
  -LogicAppName "AVD-alert-details"
```

## Recommended Rollout Paths

1. Baseline only: run `Azure-AVD-Alerts.ps1`.
2. Baseline + rich email: run `Deploy-AVD-AlertWebhook-LogicApp-v2.ps1`, then run `Azure-AVD-Alerts.ps1` with detailed webhook attached (or re-run to ensure action groups are attached).
3. Post-change validation: run `Send-AVD-Webhook-TestAlert.ps1` after webhook deployment/update.

## AVD Alert Categories

The core script deploys 8 consolidated `AVD-Category-*` alerts.

- Evaluation frequency: every `10 minutes`
- Scan/lookback window: last `15 minutes`
- Trigger behavior: alert fires when matching events are found in the window

Categories:

- `AVD-Category-AuthenticationIdentity`
- `AVD-Category-AuthorizationPolicy`
- `AVD-Category-ConnectionNetworkGateway`
- `AVD-Category-SessionHostHealthCapacity`
- `AVD-Category-PersonalDesktopAssignment`
- `AVD-Category-DeviceGraphicsInput`
- `AVD-Category-FSLogixProfileStorage`
- `AVD-Category-UnknownUnclassified`
