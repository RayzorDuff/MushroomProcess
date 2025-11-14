# NocoDB Automation Kit

This folder contains Node handlers to mirror your Airtable automations using NocoDBâ€™s REST API.

## Environment
- `NOCO_BASE_URL` e.g. `https://nocodb.yourdomain.tld`
- `NOCO_PROJECT`  project slug (e.g., `mushroom_inventory`)
- `NOCO_TOKEN`    personal access token

## Wiring (NocoDB Button â†’ Webhook)
Create a Button field â†’ â€œRun Webhookâ€ (POST) â†’ your service endpoint. Example JSON bodies:

**Sterilizer OUT**
```json
{ "run_id": "{{row.id}}" }
**LC â†’ Grain**
```json
{
  "grain_lot_id": "{{row.id}}",
  "lc_lot_id": "{{row.lc_lot_id}}",
  "lc_volume_ml": "{{row.lc_volume_ml}}",
  "override_inoc_time": "{{row.override_inoc_time}}",
  "operator": "{{row.operator}}"
}
**Spawn to Bulk**
```json
{
  "row_id": "{{row.id}}",
  "grain_inputs": "{{row.grain_inputs}}",
  "substrate_inputs": "{{row.substrate_inputs}}",
  "output_count": "{{row.output_count}}",
  "operator": "{{row.operator}}"
}

Each script writes any validation messages to the relevant recordâ€™s ui_error.
Adjust table/field names if your NocoDB schema differs from Airtableâ€™s.
