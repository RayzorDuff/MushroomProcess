# NocoDB Automations

This folder contains the Node-based handlers that replace Airtable Automations when running MushroomProcess on NocoDB instead of Airtable.

These handlers perform actions equivalent to the Airtable scripts found in `airtable_automation/`, including:
- Status transitions of substrate/lots
- Creation of event records
- Triggering print queue inserts
- Updating linked records
- Performing validations and writing error messages

They are invoked from NocoDB using **webhook Buttons** or from Retool via REST calls.

---

## How This Works

### 1. Configure Button Fields in NocoDB
For each workflow action (e.g. Sterilizer OUT, Spawn to Bulk, Harvest Packaging), you attach a Button column in NocoDB that triggers a webhook.

Example configuration:
- Type: `Button`
- Mode: `Webhook remotely`
- Method: `POST`
- URL: The endpoint of your automation handler (e.g.: `/automation/spawnToBulk`)

When a user clicks a button in the row interface, the automation handler receives the record ID and performs the operation.

---

## 2. Environment Variables

Automation handlers expect these env variables:

```bash
NOCODB_URL=http://localhost:8080
NOCODB_TOKEN=your_api_token_here
NOCODB_API_VERSION=v3
```

Optional helpers:

```bash
LOG_AUTOMATION=true
STRICT_VALIDATION=true
```

---

## 3. Workflow Example

### Spawn-to-Bulk Action

When the Spawn-To-Bulk button triggers:

**Payload example**
```json
{
  "recordId": "recXXXXXXXXXXXX",
  "table": "lots"
}
```

The handler will:
1. Validate state
2. Create new `events` rows
3. Update status/action fields
4. Push a print job to `print_queue`

This is equal to `spawn_to_bulk/actions.js` in Airtable.

---

## 4. File Structure

```text
nocodb_automation/
  spawn_to_bulk.js
  sterilizer_in.js
  sterilizer_out.js
  harvest.js
  util/
    noco_client.js
    logger.js
    field_map.js
```

### Key roles
- `noco_client.js` → wraps calls into NocoDB REST API
- `field_map.js` → maps canonical names → actual DB names
- `*_actions.js` → each workflow

---

## 5. Running Locally

```bash
npm install
node spawn_to_bulk.js
```

You should test with a sandbox base before using production.

---

## 6. Deployment Options

Recommended:
- pm2
- docker container
- systemd unit
- NSSM windows service

Example for pm2:

```bash
pm2 start sterilizer_out.js --name steri-out
pm2 start spawn_to_bulk.js --name spawn-bulk
pm2 save
```

---

## 7. Comparison with Airtable Automations

| Capability               | Airtable Automations | NocoDB Automations  |
|-------------------------|----------------------|---------------------|
| Runs inside UI          | Yes                  | No                  |
| Trigger sources         | UI buttons/scripts   | Webhook button      |
| Logs                    | Inline UI logs       | Console/Files        |
| External API access     | Limited              | Full Node access    |
| Scheduling              | Limited              | cron/pm2/systemd    |

---

## 8. Notes

- Ensure button fields always send the correct row ID.
- Use logging during deployment to validate state updates.
- Keep `print_queue` IDs consistent when switching backends.
