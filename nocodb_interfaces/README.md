# NocoDB & Retool Interface Bundle

This folder contains:

- **NocoDB creator scripts (Node.js)** – create views that mirror the Airtable Interfaces.
- **Retool how-to text files** – instructions for building matching dashboards in Retool.

The goal is to approximate the Airtable operator experience (per station) using:

- NocoDB views and filters, plus
- Retool as a richer frontend when needed.

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

## 3. Retool How-To Files

For each interface, you’ll see corresponding Retool instructions such as:

- `Retool_Dark_Room.txt`
- `Retool_Fruiting.txt`
- `Retool_Spawn_to_Bulk.txt`
- etc.

Each document typically covers:

- Which NocoDB API endpoints to use.
- Suggested layout (tables, forms, buttons).
- How to bind actions (e.g., PATCH requests to update status, call automation webhooks).
- Where to surface error messages (analogous to Airtable’s `ui_error`).

Use these notes to rebuild the equivalent of the Airtable Interfaces in Retool, backed by the NocoDB schema.

---

## 4. Notes

- Scripts assume NocoDB v2/v3-style endpoints (e.g. `/api/v2` or `/api/v3`).
- Field names and filters mirror the Airtable schema as exported to `_schema.json`.
  - If your NocoDB schema diverges, you may need to tweak field/table names in the scripts.
- Keep your NocoDB environment variables in sync with the ones used in `nocodb_automation/` and the print daemon.
