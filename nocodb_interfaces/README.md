# NocoDB + Appsmith Interface Bundle

This folder contains:

- **NocoDB creator scripts (Node.js)** – create views that mirror the Airtable Interfaces.
- **Appsmith how-to text files** – instructions for building matching dashboards in Appsmith.
- **Retool how-to text files** – legacy instructions (kept for reference).

The goal is to approximate the Airtable operator experience (per station) using:

- NocoDB views and filters, plus
- Appsmith as the frontend
- n8n for automation workflows (replacing Airtable Scripting)

---

## 1. Environment

All NocoDB scripts here expect the following environment variables:

```bash
NOCO_BASE_URL=https://your-nocodb-instance.com
NOCO_PROJECT=mushroom_inventory
NOCO_TOKEN=YOUR_API_TOKEN
```

These must match your NocoDB deployment:

- `NOCO_BASE_URL` – Base URL, e.g. `http://localhost:8080` or your server’s HTTPS URL.
- `NOCO_PROJECT` – NocoDB project slug containing the MushroomProcess tables.
- `NOCO_TOKEN` – Personal access token with read/write rights to that project.

---

## 2. Running a View-Creator Script

Each `nocodb_create_*_view.js` script creates or updates a NocoDB view for a specific workflow.

Example:

```bash
node nocodb_create_spawn_to_bulk_view.js
```

Typical responsibilities:

- Create a view on the appropriate table (e.g., `lots`).
- Apply filters (e.g., only show lots at a particular stage).
- Define visible columns and default sort orders.

After running a script, check NocoDB’s UI to confirm the view appears as expected.

---

## 3. Appsmith How-To Files

For each interface, you’ll see corresponding Appsmith instructions such as:

- `Appsmith_Dark_Room.txt`
- `Retool_Fruiting.txt`
- `Retool_Spawn_to_Bulk.txt`
- etc.

Each document typically covers:

- Which NocoDB API endpoints to use.
- Suggested layout (tables, forms, buttons).
- How to bind actions (e.g., PATCH requests to update status, call automation webhooks).
- Where to surface error messages (analogous to Airtable’s `ui_error`).

Use these notes to rebuild the equivalent of the Airtable Interfaces in Appsmith, backed by the NocoDB schema.

## 4. Appsmith import file

The json file, MushroomProcess.json, may be imported directly into Appsmith.  Please recreate with:

```bash
node .\pretty-json.mjs --in .\MushroomProcess_exported --out .\MushroomProcess.json --sort-keys
```bash

### Legacy Retool specs
Retool specs are still present as `Retool_*.txt` for reference, but are not the recommended path if you’re using Appsmith + n8n.

---

## 5. Notes

- Scripts assume NocoDB v2/v3-style endpoints (e.g. `/api/v2` or `/api/v3`).
- Field names and filters mirror the Airtable schema as exported to `_schema.json`.
  - If your NocoDB schema diverges, you may need to tweak field/table names in the scripts.
- Keep your NocoDB environment variables in sync with the ones used in `nocodb_automation/` and the print daemon.

---

## 6. n8n Automation Strategy

Airtable’s scripts in `airtable_automation/` are the current “source of truth” for workflow logic.
When migrating, move this logic to **n8n** (webhooks or polling), and keep Appsmith focused on UI.

See: `Appsmith_N8N_Automation_Strategy.md`.
