# AVD Alerts Scripts Guide

This folder contains production-focused PowerShell scripts for deploying and extending Azure Virtual Desktop (AVD) alerting.

The **AVD Alerts Scripts Guide** is best used as a complementary tool alongside the built-in Azure Virtual Desktop Insights. The built-in **Azure Virtual Desktop Insights** gives administrators an end-to-end troubleshooting view of the environment, making it easier to follow issues across host pools, session hosts, user sessions, and diagnostic data in one place. Theese alert scripts add a **proactive layer** by querying AVD diagnostic logs in Log Analytics with KQL and generating alerts when known warning signs or failures appear. **This helps catch problems earlier, before they snowball into larger stability or user-impact issues**.

## What Each Script Does

1. `Azure-AVD-Alerts.ps1`
Creates and maintains the core `AVD-Category-*` scheduled query alerts, plus the primary email action group (`AVD-Alerts`).

2. `Deploy-AVD-AlertWebhook-LogicApp.ps1`
Deploys a detailed-notification Logic App (`la-avd-alerts-detailed`) and creates/updates the detailed webhook action group (`AVD-Alerts-Detailed`). Supports `Office365` (default) or `SendGrid` delivery. In `Office365` mode, the script now prints an explicit authorization reminder and checks connector status so you can confirm whether email delivery is ready.

3. `Deploy-AVD-Teams-Notifier.ps1`
Deploys a Teams notifier Logic App (`la-avd-alerts-teams`), creates/updates `AVD-Alerts-Teams`, and can attach Teams notifications to existing `AVD-Category-*` alerts.

4. `Send-AVD-Webhook-TestAlert.ps1`
Sends a synthetic Azure Monitor common alert payload to a Logic App webhook for end-to-end validation.

## Which Script Runs First

Run order depends on your rollout goal.

1. Always start with `Azure-AVD-Alerts.ps1`.
This establishes baseline monitoring and email alerting.

2. Then optionally run `Deploy-AVD-AlertWebhook-LogicApp.ps1`.
This upgrades notifications from basic alert emails to rich, detailed alert context emails.

3. Then optionally run `Deploy-AVD-Teams-Notifier.ps1`.
This adds Teams delivery in parallel with email.

4. Use `Send-AVD-Webhook-TestAlert.ps1` anytime after a Logic App is deployed.
This validates webhook processing without waiting for a real incident.

## Optional Scripts and Productivity Impact

- `Deploy-AVD-AlertWebhook-LogicApp.ps1` is optional.
Productivity gain: engineers get richer incident context in email (alert essentials and alert context payload), reducing time spent pivoting into Portal and Logs for first triage.

- `Deploy-AVD-Teams-Notifier.ps1` is optional.
Productivity gain: alerts appear in Teams channels/chats where ops collaboration already happens, reducing handoff friction and time-to-acknowledge.

- `Send-AVD-Webhook-TestAlert.ps1` is optional.
Productivity gain: enables repeatable smoke tests after deployment changes, reducing false confidence and avoiding live-incident validation risk.

## Dependency Diagram (Plain Text)

```text
Azure Monitor Scheduled Query Rules (AVD-Category-*)
		|
		|-- Action Group: AVD-Alerts (email receiver)
		|
		|-- Action Group: AVD-Alerts-Detailed (webhook) [optional]
		|       |
		|       +--> Logic App: la-avd-alerts-detailed
		|               |
		|               +--> Office365 connector or SendGrid API
		|
		|-- Action Group: AVD-Alerts-Teams (webhook) [optional]
						|
						+--> Logic App: la-avd-alerts-teams
										|
										+--> Microsoft Teams incoming webhook

Send-AVD-Webhook-TestAlert.ps1
		|
		+--> Posts sample payload to Logic App callback URL for validation
```

## Prerequisites

- Azure CLI installed and authenticated (`az login`)
-  set the subscription ('az account set --subscription "your-subscription-id" ')
- `scheduled-query` CLI extension available
- Monitoring permissions in target resource group
- A Log Analytics workspace receiving AVD diagnostics

> ATTENTION
> If an existing AVD Log Analytics Workspace is already in place (including Nerdio-managed environments), reuse it instead of creating a new one.
>
> For `Azure-AVD-Alerts.ps1`, set:
> - `-ResourceGroup` to the resource group that contains the existing workspace
> - `-LawName` to the existing workspace name
>
> Before running, confirm the existing workspace is already receiving AVD diagnostic data and includes the required AVD error tables/events.

## Minimum RBAC and Change Impact by Script

Use the target resource group scope unless noted otherwise.

### Minimum RBAC / Roles

| Script | Minimum RBAC / Role | API Authorization Needed |
|---|---|---|
| `Azure-AVD-Alerts.ps1` | `Monitoring Contributor` on the target resource group, plus `Reader` access to the Log Analytics workspace resource. | Azure management APIs only (via `az` CLI). Requires authenticated Azure CLI session (`az login`) and token authorized for the target subscription/resource group. No extra third-party API key required. |
| `Deploy-AVD-AlertWebhook-LogicApp.ps1` | `Contributor` on the target resource group (minimum practical role because the script deploys Logic App resources, may create `Microsoft.Web/connections`, and manages action groups). | Azure management APIs (via `az rest`) require `az login` and ARM permissions. If `EmailProvider=SendGrid`, a valid `SendGridApiKey` with Mail Send permission is required. If `EmailProvider=Office365`, connector authorization/sign-in is required for the Office365 connection in addition to Azure RBAC. |
| `Deploy-AVD-Teams-Notifier.ps1` | `Contributor` on the target resource group (minimum practical role because the script deploys Logic App resources and creates/updates action groups and alert rules). | Azure management APIs require `az login` and ARM permissions. A valid Teams incoming webhook URL is required to post messages; possession of the webhook URL acts as authorization for Teams posting. |
| `Send-AVD-Webhook-TestAlert.ps1` | `Logic App Contributor` (or `Contributor`) on the target resource group to resolve callback URL and invoke test flow. | Azure management API call to retrieve callback URL requires `az login` and ARM permissions. The callback URL itself is an authorization secret for invoking the Logic App trigger. |

Notes:
- If `Deploy-AVD-AlertWebhook-LogicApp.ps1` is run with `-ConfigureAlertsAfterDeploy`, it also performs core alert deployment steps and therefore needs permissions required by `Azure-AVD-Alerts.ps1`.
- Office365 mode requires connector authorization in addition to Azure RBAC (the account authorizing the connection must be allowed to use that mailbox).
- The webhook deploy script now reports Office365 connection readiness after deployment and prints an action-required message when authorization is still needed.
- Treat all secret-bearing values as credentials: `SendGridApiKey`, Teams webhook URLs, and Logic App callback URLs.

### What Each Script Changes

| Script | Azure Services/Resources Changed | External API/Service Calls | Local Files Changed |
|---|---|---|---|
| `Azure-AVD-Alerts.ps1` | Creates/updates Azure Monitor action groups (`AVD-Alerts`, optional `AVD-Alerts-Detailed`), creates/updates `AVD-Category-*` scheduled query alert rules in `Microsoft.Insights/scheduledQueryRules`. | None beyond Azure control-plane APIs. | Writes CSV report (default `avd-alerts-report.csv` or subscription-suffixed variant). |
| `Deploy-AVD-AlertWebhook-LogicApp.ps1` | Creates/updates Logic App workflow `la-avd-alerts-detailed`, may create/update `Microsoft.Web/connections` (Office365), creates/updates detailed action group receiver, can optionally call core alert deployment to attach webhook action group. | Logic App runtime sends outbound email through SendGrid API or Office365 connector API, based on selected provider. | Creates temporary deployment JSON in the OS temp directory during execution (cross-platform temp path resolution; cleaned up by script). |
| `Deploy-AVD-Teams-Notifier.ps1` | Creates/updates Logic App workflow `la-avd-alerts-teams`, creates/updates `AVD-Alerts-Teams` action group, optionally patches existing `AVD-Category-*` alerts to add Teams action group. | Logic App runtime posts outbound messages to Teams incoming webhook endpoint. | Creates temporary deployment JSON in `%TEMP%` during execution (cleaned up by script). |
| `Send-AVD-Webhook-TestAlert.ps1` | No persistent Azure resource changes; resolves Logic App callback URL and posts a synthetic test payload to validate flow execution. | Sends HTTP POST to Logic App callback endpoint (authorized by callback URL secret). | No persistent local file changes. |

## Sample Usage for Each Script

### 1) Core Alerts (Run First)

```powershell
.\Azure-AVD-Alerts.ps1 `
	-EmailTo "alerts@contoso.com" `
	-ResourceGroup "rg-avd-prod" `
	-LawName "law-avd-prod" `
	-Location "eastus2"
```

Preview only:

```powershell
.\Azure-AVD-Alerts.ps1 `
	-EmailTo "alerts@contoso.com" `
	-ResourceGroup "rg-avd-prod" `
	-LawName "law-avd-prod" `
	-Location "eastus2" `
	-WhatIf
```

### 2) Detailed Email Notifier (Optional)

Office365 mode (default provider):

```powershell
pwsh -NoProfile -File .\Deploy-AVD-AlertWebhook-LogicApp.ps1 `
	-ResourceGroup "rg-avd-prod" `
	-Location "eastus2" `
	-SendFromEmail "alerts@contoso.com" `
	-SendToEmail "avd-oncall@contoso.com"
```

Office365 note:

- After deployment, the script prints the Office365 connector status.
- If connector authorization is missing, it prints an action-required message instructing you to authorize the Office365 connection in Azure Portal before emails can be delivered.

SendGrid mode:

```powershell
pwsh -NoProfile -File .\Deploy-AVD-AlertWebhook-LogicApp.ps1 `
	-ResourceGroup "rg-avd-prod" `
	-Location "eastus2" `
	-EmailProvider "SendGrid" `
	-SendGridApiKey "<sendgrid-key>" `
	-SendFromEmail "alerts@contoso.com" `
	-SendToEmail "avd-oncall@contoso.com"
```

Single-command behavior *AVD-Alerts* + *Deploy-AVD-AlertWebook-LogicApp*:

- You do not need to run a separate Office365 deploy command and a separate core-alerts command.
- `Office365` is the default provider in `Deploy-AVD-AlertWebhook-LogicApp.ps1`.
- If you include `-ConfigureAlertsAfterDeploy`, the same command **deploys/updates the Logic App and then invokes `Azure-AVD-Alerts.ps1`** automatically with the generated webhook URL.

One command: deploy detailed notifier + auto-configure core alerts:

```powershell
pwsh -NoProfile -File .\Deploy-AVD-AlertWebhook-LogicApp.ps1 `
	-ResourceGroup "rg-avd-prod" `
	-Location "eastus2" `
	-SendFromEmail "alerts@contoso.com" `
	-SendToEmail "avd-oncall@contoso.com" `
	-ConfigureAlertsAfterDeploy `
	-AlertsEmailTo "alerts@contoso.com" `
	-AlertsResourceGroup "rg-avd-prod" `
	-AlertsLawName "law-avd-prod" `
	-AlertsLocation "eastus2"
```

### 3) Teams Notifier (Optional)

Get the `-TeamsWebhookUrl` first, then run the script.

Option A: Channel webhook URL (Incoming Webhook connector)

1. In Microsoft Teams, open the target team channel.
2. Open channel settings/options and locate `Connectors` (or channel app integrations).
3. Add/configure `Incoming Webhook`.
4. Create the webhook and copy the generated URL.
5. Use that URL as `-TeamsWebhookUrl`.

Option B: User or chat delivery URL (Teams Workflows / Power Automate)

1. In Microsoft Teams, open `Apps` -> `Workflows`.
2. Create a workflow with trigger `When a Teams webhook request is received`.
3. Add an action to post to a user/chat (for example, post as Flow bot to a user, or post in a chat).
4. Save the workflow and copy the trigger HTTP URL.
5. Use that workflow URL as `-TeamsWebhookUrl`.

Notes:

- Classic Incoming Webhook is channel-oriented.
- User-targeted posting is typically done through a Teams Workflow webhook trigger.
- Treat all webhook URLs as secrets.

```powershell
pwsh -NoProfile -File .\Deploy-AVD-Teams-Notifier.ps1 `
	-ResourceGroup "rg-avd-prod" `
	-Location "eastus2" `
	-TeamsWebhookUrl "https://outlook.office.com/webhook/..."
```

Keep Logic App deploy but skip attaching to existing category alerts:

```powershell
pwsh -NoProfile -File .\Deploy-AVD-Teams-Notifier.ps1 `
	-ResourceGroup "rg-avd-prod" `
	-Location "eastus2" `
	-TeamsWebhookUrl "https://outlook.office.com/webhook/..." `
	-AttachToCategoryAlerts:$false
```

### 4) Test Payload Sender (Optional)

Test detailed notifier:

```powershell
pwsh -NoProfile -File .\Send-AVD-Webhook-TestAlert.ps1 `
	-ResourceGroup "rg-avd-prod" `
	-LogicAppName "la-avd-alerts-detailed"
```

Test Teams notifier:

```powershell
pwsh -NoProfile -File .\Send-AVD-Webhook-TestAlert.ps1 `
	-ResourceGroup "rg-avd-prod" `
	-LogicAppName "la-avd-alerts-teams"
```

## Recommended Rollout Paths

1. Baseline only: run `Azure-AVD-Alerts.ps1`.
2. Baseline + rich email: run `Azure-AVD-Alerts.ps1`, then `Deploy-AVD-AlertWebhook-LogicApp.ps1`.
3. Full workflow (email + Teams): run `Azure-AVD-Alerts.ps1`, then both optional deploy scripts.
4. Post-change verification: run `Send-AVD-Webhook-TestAlert.ps1` after each notifier deployment/update.

## AVD Alert Categories (No Raw Queries)

The core script creates 8 consolidated `AVD-Category-*` alerts. Each one groups related failures so engineers receive fewer, higher-signal notifications.

### Alert Cadence and Scan Window

- Evaluation frequency: every `10 minutes`
- Scan/lookback window: last `15 minutes`
- Trigger behavior: alert fires when matching error events are found in the window
- Purpose of this cadence: balances fast detection with reduced alert noise from transient events

### Category Breakdown

| Category | Purpose | Looks For |
|---|---|---|
| `AVD-Category-AuthenticationIdentity` | Identify account and authentication failures early. | Password expiry/change-required issues, invalid credentials/tokens, locked or disabled accounts, and authority/security authentication failures. |
| `AVD-Category-AuthorizationPolicy` | Detect access-policy and logon-rights problems. | User not authorized to connect/log on and policy-based denial scenarios. |
| `AVD-Category-ConnectionNetworkGateway` | Surface client-to-service transport and name-resolution issues. | Client connection failures, DNS lookup errors, gateway endpoint discovery failures, and reverse-connect timing/closure conditions. |
| `AVD-Category-SessionHostHealthCapacity` | Detect host pool health or capacity exhaustion. | No healthy session host availability, host resource-not-available events, and memory pressure/out-of-memory failures. |
| `AVD-Category-PersonalDesktopAssignment` | Monitor personal desktop assignment and launch reliability. | Failures where a personal desktop cannot be started or no pre-assigned personal desktop exists for the user. |
| `AVD-Category-DeviceGraphicsInput` | Catch endpoint graphics/input subsystem issues that block user sessions. | Input device handle failures, graphics capability negotiation issues, graphics subsystem errors, and related desktop window manager access failures. |
| `AVD-Category-FSLogixProfileStorage` | Detect profile container and storage path failures that break sign-in/session profile load. | Sharing/lock/access/path/network/disk-full conditions and FSLogix-specific profile mount/attach indicators in diagnostic events. |
| `AVD-Category-UnknownUnclassified` | Flag uncategorized error signals for triage and rule tuning. | Unknown/unclassified symbolic error patterns so engineering can investigate and classify new failure modes. |

### Why This Category Model Helps

- Reduces alert sprawl by consolidating many low-level errors into a manageable category signal.
- Improves triage speed by routing incidents by failure domain (identity, network, host capacity, profile, etc.).
- Supports iterative tuning: unknown/unclassified category highlights where future refinements are needed.

