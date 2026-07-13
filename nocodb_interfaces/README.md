# NocoDB + Appsmith Interface Bundle

This folder contains:

- **NocoDB creator scripts (Node.js)** – create views that mirror the Airtable Interfaces.
- **Appsmith how-to text files** – instructions for building matching dashboards in Appsmith.

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
- etc.

Each document typically covers:

- Which NocoDB API endpoints to use.
- Suggested layout (tables, forms, buttons).
- How to bind actions (e.g., PATCH requests to update status, call automation webhooks).
- Where to surface error messages (analogous to Airtable’s `ui_error`).

Use these notes to rebuild the equivalent of the Airtable Interfaces in Appsmith, backed by the NocoDB schema.

### 3.1 Appsmith + Postgres workflow spec

#### Pattern
1. **UI** collects operator inputs (modal/page)
2. A **single SQL query** calls a **single Postgres function**
3. The Postgres function:
   - validates inputs
   - inserts/updates records
   - writes an event row (canonical `mp_events_insert*`)
   - writes print_queue rows (`mp_print_queue_enqueue`)
   - maintains links (M2M tables)

#### Pages

##### Products
- `tblProducts` lists products (latest 500)
- Freeze dried packaging modal (basic):
  - uses `mp_products_package_freeze_dried_basic`

##### Lab - Receive
- Receive purchased syringes:
  - creates `lc_syringe` lots
  - queues lot labels

##### Lab - Agar
- Lists `agar_flask` lots
- Pour plates:
  - creates `plate` lots
  - assigns `plate_group_id`

##### Spawn to Bulk
- Lists candidate spawn lots (grain/spawn categories)
- Spawn:
  - creates bulk lots
  - links source->target via `_m2m_lots_lots_target_lot_ids`
  - consumes sources

##### Lots – Draw Syringes
- Operates on selected lc_flask lot
- Creates syringe lots and decrements source `remaining_volume_ml`

##### Fulfillment Interface

The Fulfillment interface is responsible for assigning exact inventory products to ecommerce and market orders.

###### Features

- fulfillment-ready order listing
- market/web order filtering
- timezone-aware date filtering
- inventory product search
- exact product assignment
- linked-product visibility
- Clover reconciliation review
- manual reconciliation actions

###### Operational Flow

1. Load fulfillment-ready orders.
2. Select an order.
3. Review required products.
4. Search inventory.
5. Assign exact inventory products.
6. Assigned products automatically transition to `Shipped`.

Orders remain visible after all required products are linked so reconciliation and historical review can continue. Product-assignment controls are disabled for completed assignments, and reconciliation controls are disabled after reconciliation is complete.

The Order Date filter is blank by default. Selecting a date limits the order table to that calendar date; clearing the date restores the all-date view.

###### Market Order Handling

Market orders use Clover reconciliation state to determine readiness.

####### Ready Orders

```text
clover_reconciliation_status = reconciled
```

####### Reviewable Orders

```text
clover_reconciliation_status IN ('pending', 'needs_review')
```

Unassigned reviewable orders are visible when:
```text
Include Reconciliation Review = enabled
```

A fully assigned order that still needs reconciliation remains visible even when this option is disabled.

### Accounted Orders

Cash/manual transactions may be marked:

```text
clover_reconciliation_status = accounted
```

###### Linked Product Visibility

The fulfillment interface displays:

- ordered products
- linked internal inventory products
- reconciliation notes
- Clover reconciliation state

###### Inventory Filtering

Products are excluded if already located in:

- Shipped
- Consumed
- Compost
- Expired

## 4. Appsmith import file

The json file, MushroomProcess.json, may be imported directly into Appsmith.  Please recreate with:

```bash
node .\pretty-json.mjs --in .\MushroomProcess_exported --out .\MushroomProcess.json --sort-keys
```

---

### 4.1 Appsmith Page map 

#### Non-optional pages (core)
- Sterilizer – In / Out
- Lots
- Products
- Lab - Receive
- Lab - Agar
- Spawn to Bulk
- Reporting

#### Where specific workflows fit

##### Receive purchased syringes
**Lab - Receive**
- Creates `lc_syringe` lots with vendor + batch metadata
- Queues labels

##### Pour plates
**Lab - Agar**
- Source is `agar_flask` lot
- Output is `plate` lots (grouped by `plate_group_id`)

##### Draw syringes (from LC flask)
**Lots** (modal action)
- Source is a single `lc_flask` lot
- Output is `lc_syringe` lots

##### Spawn to Bulk
**Spawn to Bulk**
- Source: one or more spawn/grain lots
- Output: bulk/substrate/block lots
- Links + consumes sources

##### Package freeze dried
**Products**
- Source: freeze tray products
- Output: packaged products + print jobs

#### Optional / later pages
- Lab - Genetics (clone/spore workflows)
- Fruiting / Harvest station pages (flush management, harvest weights, tray state transitions)
- QA / Contam tracking pages


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
