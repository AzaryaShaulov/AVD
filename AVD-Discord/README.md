# AVD-Discord — Azure Monitor → Discord Alert Notifier

Azure Logic App (Consumption) that receives Azure Monitor alert notifications via the
**Common Alert Schema** and posts formatted embeds to a Discord channel using an
incoming webhook. Deployed via PowerShell using the same patterns as `AVD-AzAlerts`
and `AVD-SessionHost-Insights-Alerts`.

## Folder Structure

```
AVD-Discord/
├── AVD-Discord-Deploy-LogicApp.ps1   # Main deployment script
├── AVD-Discord-Precheck.ps1          # Pre-flight validation (read-only)
├── AVD-Discord-TestAlert.ps1         # Send test payload to Logic App
├── test-payload.json                 # Sample Common Alert Schema payload
├── .env                              # Discord webhook URL (gitignored)
└── README.md                         # This file
```

## Prerequisites

| Item | Details |
|---|---|
| Azure CLI | Logged in with permissions to create Logic Apps and update action groups |
| Resource group | Existing or the deploy script will create one |
| Action group(s) | Already exist (e.g., `AVD-Alerts-Detailed`, `AVD-Insights-Detailed`) |
| Discord webhook URL | Created in Discord channel settings → Integrations → Webhooks |
| `.env` file | In this directory, containing `DISCORD_WEBHOOK_URL=https://discord.com/api/webhooks/...` |

> **This project does NOT create alert rules, KQL queries, diagnostics, or action groups.**

## Setup

### 1. Create the `.env` file

```
# AVD-Discord/.env — gitignored, never commit
DISCORD_WEBHOOK_URL=https://discord.com/api/webhooks/<id>/<token>
```

### 2. Run the precheck

```powershell
.\AVD-Discord-Precheck.ps1 `
  -SubscriptionId "YOUR-SUBSCRIPTION-ID" `
  -ResourceGroupName "rg-avd-monitoring" `
  -ActionGroupNames @("AVD-Alerts-Detailed","AVD-Insights-Detailed")
```

This validates CLI login, subscription access, resource group, action groups, and Discord webhook reachability. No changes are made.

### 3. Deploy

```powershell
.\AVD-Discord-Deploy-LogicApp.ps1 `
  -SubscriptionId "YOUR-SUBSCRIPTION-ID" `
  -ResourceGroupName "rg-avd-monitoring" `
  -LogicAppName "AVD-Discord-Notifier" `
  -Location "eastus2" `
  -ActionGroupNames @("AVD-Alerts-Detailed","AVD-Insights-Detailed")
```

The script will:
1. Read the Discord webhook URL from `.env` (never logged).
2. Deploy the Logic App with the workflow definition.
3. Retrieve the callback URL.
4. Add a `AVDDiscordWebhook` receiver to each specified action group with `useCommonAlertSchema = true`.
5. Write a CSV deployment report.

#### Preview mode

```powershell
.\AVD-Discord-Deploy-LogicApp.ps1 `
  -SubscriptionId "YOUR-SUBSCRIPTION-ID" `
  -ResourceGroupName "rg-avd-monitoring" `
  -LogicAppName "AVD-Discord-Notifier" `
  -Location "eastus2" `
  -ActionGroupNames @("AVD-Alerts-Detailed") `
  -PreviewOnly
```

Shows what the script would do without deploying anything.

#### Using hardcoded defaults

Edit the `$HardCoded` hashtable at the top of the deploy script, then:

```powershell
.\AVD-Discord-Deploy-LogicApp.ps1 -UseHardCodedDefaults
```

### 4. Test

```powershell
# Option A: provide the callback URL directly
.\AVD-Discord-TestAlert.ps1 -CallbackUrl "https://prod-xx.eastus2.logic.azure.com/..."

# Option B: let the script retrieve it
.\AVD-Discord-TestAlert.ps1 `
  -SubscriptionId "YOUR-SUBSCRIPTION-ID" `
  -ResourceGroupName "rg-avd-monitoring" `
  -LogicAppName "AVD-Discord-Notifier"
```

Expected response:

```json
{
  "status": "ok",
  "alertRule": "AVD-HostPool-NoAvailableSessionHosts",
  "discordStatus": 204
}
```

## How Action Group Wiring Works

The deploy script **adds a webhook receiver** to your existing action group(s). It:
- Reads the existing action group (preserving all current receivers).
- Adds or updates only the Discord webhook receiver.
- Sets `useCommonAlertSchema = true` on the Discord receiver.
- Does NOT modify alert rules, diagnostics, or other receivers.

This means the same alert fires to both your existing email Logic App **and** Discord.

### Manual wiring (if needed)

If you skip `-ActionGroupNames`, you can wire manually in the Azure Portal:

1. Navigate to **Monitor → Alerts → Action groups**.
2. Open the target Action Group.
3. Under **Actions**, add a new **Webhook** action.
4. Paste the Logic App callback URL.
5. Enable **Common Alert Schema**.
6. Save.

## Workflow Details

### Trigger

HTTP POST trigger accepting the Azure Monitor Common Alert Schema JSON body.

### Discord Message Format

One embed per alert:

| Section | Content |
|---|---|
| **Title** | Status emoji + alert rule name + Fired/Resolved |
| **Description** | Severity and monitoring service — plus description if present |
| **Fields** | Severity, Condition, Signal Type, Monitoring Service, Fired Time, Environment, Target Resources |
| **Color** | Red (Sev0), Orange (Sev1), Yellow (Sev2), Blue (Sev3), Grey (other) |
| **Footer** | Environment name |
| **Timestamp** | Fired date/time |

If `alertContext` contains `SearchResults`, `IncludedSearchResults`, or `condition.allOf` data, a compact summary is appended as an additional field.

Target resources are truncated to the first 3 entries with a "... and N more" note.

### Error Handling

| Scenario | Behavior |
|---|---|
| Missing optional fields | `coalesce()` provides safe defaults; workflow continues |
| Discord API transient failure | Exponential retry: 3 attempts, 5s–30s backoff |
| Discord API permanent failure | Scoped failure path returns HTTP 502 with error details |
| Oversize strings | `take()` truncates title to 200 chars, description to 2048 chars |

### Security

- Discord webhook URL is read from `.env` and stored as `SecureString` in the Logic App — never logged.
- The Logic App callback URL contains a SAS signature — treat as secret.
- No managed identity, API connections, or RBAC assignments needed.

## Parameters Reference

| Parameter | Required | Default | Description |
|---|---|---|---|
| `SubscriptionId` | Yes | — | Azure subscription ID |
| `ResourceGroupName` | Yes | — | Target resource group |
| `LogicAppName` | Yes | — | Logic App resource name |
| `Location` | Yes | — | Azure region |
| `ActionGroupNames` | No | `@()` | Action groups to wire |
| `ActionGroupResourceGroup` | No | Same as RG | Resource group of action groups |
| `DiscordReceiverName` | No | `AVDDiscordWebhook` | Webhook receiver name |
| `DiscordUsername` | No | `Azure Monitor` | Bot display name in Discord |
| `DiscordAvatarUrl` | No | _(empty)_ | Avatar image URL |
| `EnvironmentName` | No | `Production` | Label in embed footer |
| `EnvFilePath` | No | `.\.env` | Path to .env file |
| `Tags` | No | `@{}` | Resource tags |
| `PreviewOnly` | No | `$false` | Dry-run mode |

## Troubleshooting

| Symptom | Fix |
|---|---|
| **Logic App never fires** | Verify the action group has the Discord webhook receiver with Common Alert Schema enabled. |
| **Discord returns 401/403** | Webhook URL invalid or deleted. Regenerate in Discord channel settings. |
| **Discord returns 400** | Payload exceeds Discord limits (6000 chars, 25 fields). Check Run History in the portal. |
| **Discord returns 429** | Rate-limited. Retry policy handles transient 429s. Reduce alert frequency if persistent. |
| **Fields show "Unknown"** | Alert payload missing fields. Confirm Common Alert Schema is enabled on the action group. |
| **502 from Logic App** | Discord POST failed after retries. Check Logic App Run History → `Scope_PostToDiscord` → `Post_To_Discord`. |
| **Precheck fails on webhook** | Run `AVD-Discord-Precheck.ps1` — it tests URL format and reachability. |
| **.env not found** | Create `.env` in the AVD-Discord folder with `DISCORD_WEBHOOK_URL=https://discord.com/api/webhooks/...` |

## What This Project Does NOT Do

- Create or modify Azure Monitor alert rules
- Create KQL queries
- Create or delete action groups
- Create a Discord bot (uses incoming webhook only)
- Manage Discord server/channel permissions
- Modify existing AVD-AzAlerts or AVD-Insights code
