# MushroomProcess (Airtable + PostgreSQL + Appsmith + n8n)

This project implements a production-grade inventory, traceability, and label-printing system for a mushroom cultivation business.

This repository contains:
- **Schema exports, migration tools, and PostgreSQL modules** under `schema/`.
- **Appsmith UI** in `appsmith/MushroomProcess.json`.
- **External and asynchronous workflows** under `n8n/`.
- The final **Airtable parity/reference implementation** under `airtable/`.

The core database model is:

- Items, recipes, strains
- Locations & stations (sterilizer, inoculation, dark room, fruiting, harvest, packaging)
- Sterilization runs and lots
- Events / audit log
- Ecommerce products and print queue for labels

## Design principle

Appsmith is **lot-centric** (centered on `lots`) while Airtable was more **station-centric**. We keep station workflows by implementing each station as:
- A page (or modal) that gathers inputs
- A **single Postgres function** that performs the complete operation:
  - creates/updates lots/products
  - sets locations/status
  - inserts events
  - inserts print jobs
  - maintains lineage / M2M links

## Recently implemented / wired (2026-02-24)

### New Appsmith pages (stub UI now wired)
- **Products**
- Lab - Receive
- Lab - Agar
- **Fullfillment**
- **Spawn to Bulk**

Each page now has named widgets and working SQL/JS wiring:
- Data tables pull from Postgres (queries on-load)
- Action buttons call Postgres functions (below)

### Lots page
- Added **Draw Syringes** modal (Draw Syringes button):
  - Button is disabled unless **exactly one lot is selected** and it is **`item_category_mat = 'lc_flask'`**.

## Postgres functions added (see `008_lot_actions.sql`)
- `mp_lots_draw_syringes(...)`
- `mp_lots_receive_purchased_syringes(...)`
- `mp_lots_pour_plates(...)`
- `mp_lots_spawn_to_bulk(...)`
- `mp_products_package_freeze_dried_basic(...)` (basic implementation; may evolve)

## Next steps / trajectory
- Tighten each function to match Airtable behaviour exactly (weight/expiry calculations, edge-case validations, per-item recipes).
- Expand packaging:
  - Package Syringes
  - Package Freeze Dried (full merge-tray logic)
- Expand lab workflows:
  - Pour plates advanced: plate groups, incubation scheduling, contamination outcomes
- Add reporting parity with Airtable dashboards
- Ensure print-daemon functionality with Postgres
- Migrate ecwid integration to postgres/n8n
- Branch and begin retiring station-centric Airtable interface (described below) following testing of lot-centric appsmith approach

## Harvest Workflow (Postgres / Appsmith)

The Harvest workflow has been migrated from Airtable automation into the Postgres + Appsmith operational model.

### Harvest Flow

1. User selects a single `fruiting_block` lot in the Lots interface.
2. User opens the **Harvest** modal.
3. User selects a harvest output type:
   - `fresh_tray`
   - `freezer_tray`
4. User enters:
   - harvest weight (g)
   - tray count
5. Storage location is constrained automatically:
   - Fresh trays → Shipping/Fulfillment locations
   - Freezer trays → Freeze/Freeze Dryer locations
6. Product tray records are created in `products`.
7. Harvest lineage is linked back to the originating fruiting block lot.

### Harvest Metadata

The following fields are now populated during lifecycle transitions.

#### `lots`

- `beganfruiting_at`
- `firstharvested_at`
- `lastharvested_at`
- `flush_no`
- `fresh_tray_count`
- `frozen_tray_count`

#### `products`

- `harvest_flush_no`
- `harvest_weight_g`
- `harvested_at`

### Tray Products

Harvested trays are represented as `products`, not `lots`.

Supported tray product categories:

- `fresh_tray`
- `freezer_tray`

These tray products are intended for:

- fulfillment
- freeze drying
- downstream packaging operations

### SQL Functions

Implemented in:

- `009_harvest_actions.sql`

Primary function:

- `mp_lots_harvest_create_tray_products(...)`

---

## Spawn to Bulk Workflow (Postgres / Appsmith)

The Spawn-to-Bulk workflow has been migrated from Airtable automation into the Postgres + Appsmith operational model.

### Spawn to Bulk Flow

1. User selects one or more substrate lots from the Lots table.
2. User opens the **Spawn to Bulk** modal.
3. User selects one or more colonized grain source lots.
4. All selected grain lots must:
   - be category `grain`
   - share the same species/strain
5. User optionally specifies block sizing plans.
6. New `fruiting_block` lots are created.
7. Grain and substrate lineage are preserved.

### Output Planning

Supports variable block sizing.

Examples:

```text
5,5,2.5
```

or:

```text
FB-COCO-LG:5, FB-COCO-SM:2.5
```

### SQL Functions

Implemented in:

- `010_spawn_to_bulk.sql`

Primary function:

- `mp_lots_spawn_to_bulk(...)`

## Fulfillment + Reconciliation

MushroomProcess includes an operational fulfillment system built using:

- Appsmith (UI)
- n8n (API + orchestration)
- Airtable/Postgres inventory data

### Features

- exact-instance inventory assignment
- market + web order support
- Clover payment reconciliation
- manual reconciliation review
- inventory shipment state tracking

### Design Principles

- Ecwid is NOT the inventory authority.
- Clover is the payment authority for market card transactions.
- Inventory is tracked at exact product-instance level.
- Products are manually assigned to orders during fulfillment.

### Reconciliation States

| State | Meaning |
|---|---|
| reconciled | Clover payment matched |
| pending | Awaiting valid Clover match |
| needs_review | Ambiguous or unresolved match |
| accounted | Cash/manual transaction resolved operationally |

---

## 🧠 Fulfillment Flow

### Farmers Market
1. Order created via Sell on the Go (Awaiting Payment)
2. Payment processed via Clover
3. n8n reconciles payment
4. End-of-day:
   - Appsmith Fulfillment UI used
   - Products assigned to orders
   - Inventory marked as `Shipped`

---

### Website Orders
1. Order created + paid in Ecwid
2. Synced to Airtable
3. During packing:
   - Appsmith Fulfillment UI used
   - Products assigned
   - Inventory marked as `Shipped`

---

## ⚠️ Important Constraint

Exact-instance tracking requires:
- manual or scanned product assignment
- cannot rely on Ecwid SKU-level inventory

---

# MushroomProcess  

_Airtable / PostgreSQL / Appsmith / n8n Inventory, Traceability & Labeling System_

This project implements a production-grade inventory, traceability, and label-printing system for a mushroom cultivation business.

It started on **Airtable** and is being migrated to **Appsmith/PostgreSQL/n8n**, with NocoDB retained only where it remains useful for administrative data access, while keeping the same core model:

- Items, recipes, strains
- Locations & stations (sterilizer, inoculation, dark room, fruiting, harvest, packaging)
- Sterilization runs and lots
- Events / audit log
- Ecommerce products and print queue for labels

The system ties together:

- A shared Airtable export and migration toolchain (`schema/`)
- Airtable parity scripts and interface references (`airtable/`)
- PostgreSQL functions for internal operations and n8n workflows for external integrations (`schema/pgsql/`, `n8n/`)
- Appsmith operator interfaces (`appsmith/`)
- A **print daemon** that watches a queue and prints 4×2 thermal labels (`print-daemon/`)
- Optional **Ecwid integration** for ecommerce sync (`integrations/ecwid/`)

---

## Repository Layout

- `airtable/`
  Final Airtable parity/reference implementation retained through the v1.1.0 migration release:
  - `automation/` — Airtable Automation scripts and reference screenshots
  - `extensions/` — one-off administrative and backfill scripts
  - `interfaces/` — Airtable Interface specifications, exports, and reference screenshots
  _See [`airtable/README.md`](airtable/README.md)._

- `schema/`
  Shared Airtable export, schema-management utilities, optional NocoDB schema snapshot, generated PostgreSQL modules, load CSVs, and regression tests.
  _See [`schema/README.md`](schema/README.md)._

- `appsmith/`
  Canonical Appsmith application export and retained page specifications.
  _See [`appsmith/README.md`](appsmith/README.md)._

- `scripts/`
  Repository-level maintenance utilities, including Appsmith JSON normalization and navigation synchronization tooling.
  _See [`scripts/README.md`](scripts/README.md)._

- `n8n/`
  External-system and asynchronous workflows, including ecommerce, fulfillment, reporting, and reconciliation integrations.

- `print-daemon/`  
  Node.js label **print daemon** plus PowerShell helpers to run it on Windows (including as a service via NSSM). Supports pulling jobs from Airtable (legacy) or NocoDB.  
  _See [`print-daemon/README.md`](print-daemon/README.md)._

- `integrations/ecwid/`  
  Ecwid ↔ Airtable sync utilities for products and orders.  
  _See `integrations/ecwid/README.md`._

- `doc/`  
  Supporting docs:
  - `CHANGELOG.md` – high-level changes
  - `FIELD_MAP.md` – mapping between conceptual fields and actual column names
  - `Lessons_Learned_and_Evolution_Report.pdf`
  - `NOTICE.md`

---

## How the System Hangs Together

At a high level:

1. **Schema**  
   - Start from an Airtable base (the current production base or a template).
   - Export its schema using `airtable-export` into `_schema.json` and table data JSON.
   - Use `schema` tools to:
     - Recreate a clean Airtable base, or
     - Generate the full NocoDB or Postgres schema from that same `_schema.json`.

2. **Automations**  
   - On Airtable: create one Automation per flow and paste the corresponding script from `airtable/automation/`.
   - On PostgreSQL: Internal workflow automation is implemented by functions and triggers imported from `schema/pgsql/`.
   - In n8n: External integrations and asynchronous workflows are imported from `n8n/workflows/`.

3. **Interfaces / Views**  
   - Airtable Interfaces are defined by the PDF and text files in `airtable/interfaces/`.
   - The Appsmith application is imported from `appsmith/MushroomProcess.json`.
   - Retained planning notes are stored under `appsmith/spec/`; the JSON export is the authoritative current implementation.

4. **Print Queue & Daemon**  
   - Workflows append rows to a `print_queue` table (in Airtable or NocoDB).
   - The Node print daemon in `print-daemon/` watches that table and sends 4×2 labels to a thermal printer (e.g., JADENS JD268BT-CA).

5. **Ecommerce Integration (optional)**  
   - `integrations/ecwid/` keeps Ecwid SKUs and orders synced with your internal inventory, so staff can fulfill orders from the same system.

---

## Prerequisites

- **General**
  - Node.js (LTS)
  - Git
  - A 4×2" compatible label printer (tested with JADENS JD268BT-CA)
  - Windows machine for the print daemon (scripts are Windows-centric)

- **Airtable path**
  - Airtable account
  - Personal Access Token with schema + data permissions

- **NocoDB path (optional)**
  - A running NocoDB instance (desktop, Docker, or server)
  - Project created for this base (e.g. `mushroom_inventory`)
  - NocoDB API token

---

## Quick Start – Airtable Only

If you only want Airtable (no NocoDB yet):

1. **Create an Airtable base**  
   - Create a new base for MushroomProcess.
   - Optionally use `schema/` to reconstruct the schema from `_schema.json`.

2. **Install Airtable Automations**  
   - Follow [`airtable/automation/README.md`](airtable/automation/README.md) to:
     - Add one Automation per script, typically triggered from a button that passes the current record ID.
     - Paste each script into the Script action.
     - Adjust field names if your base differs.

3. **Create Interfaces**  
   - Follow [`airtable/interfaces/README.md`](airtable/interfaces/README.md) and the `Mushroom Process_Interfaces.pdf` to recreate station interfaces.
   - Ensure `ui_error` is visible in each interface so operators see validation failures.

4. **Set Up the Print Daemon**  
   - Follow [`print-daemon/README.md`](print-daemon/README.md) to configure `.env`, install Node dependencies, and run or service-wrap `print-daemon.js`.

5. **(Optional) Ecwid Integration**  
   - If you use Ecwid, configure `integrations/ecwid` to sync SKUs and orders.

---

## Quick Start – NocoDB Migration

Once you have an Airtable base and `_schema.json`:

1. **Install NocoDB (Windows)**  
   - Install Docker Desktop for Windows. 
   - Open PowerShell or Command Prompt and navigate to your desired project directory.
     Create a docker-compose.yml file.: 
   ```bash
    version: '3.8'

    services:
      nocodb:
        image: nocodb/nocodb:latest
        container_name: nocodb
        ports:
          - "8080:8080"
        volumes:
          - ./nocodb_data:/usr/app/data
        environment:
          NC_DB: "pg://postgres:5432?u=nocodb_user&p=nocodb_password&d=nocodb_db" # Connection string for PostgreSQL
          NC_AUTH_JWT_SECRET: "your_strong_jwt_secret" # Replace with a strong secret
        depends_on:
          - postgres
        restart: unless-stopped

      postgres:
        image: postgres:13
        container_name: postgres_db
        environment:
          POSTGRES_DB: nocodb_db
          POSTGRES_USER: nocodb_user
          POSTGRES_PASSWORD: nocodb_password
        volumes:
          - ./postgres_data:/var/lib/postgresql/data
        restart: unless-stopped
   ```
   - Launch docker
   ```powershell
      docker-compose up -d
   ```
   - Navigate to http://localhost:8080/
   - Create a new project (e.g. `MushroomProcess`).
   - Create an API token from your profile.

2. **Set environment variables** (PowerShell example):

   ```powershell
   $env:NOCODB_URL          = "http://localhost:8080"
   $env:NOCODB_BASE_ID      = "p_your_base_id_here"
   $env:NOCODB_API_TOKEN    = "your_api_token_here"
   $env:NOCODB_API_VERSION  = "v3"    # for current v2/v3 endpoints

   # Optional helpers for relation scripts
   $env:NOCODB_RECREATE_LINKS   = "true"
   $env:NOCODB_RECREATE_ROLLUPS = "true"
   $env:NOCODB_RECREATE_LOOKUPS = "true"
   ```

3. **Use `schema` to create the NocoDB schema**
   - See [`schema/README.md`](schema/README.md) for:
     - Directory layout (where `_schema.json` and data exports live).
     - Running `create_nocodb_schema_full.js` for the retained NocoDB provisioning path.
     - Running `compare_schemas.js` against `export/_schema.json` and `export/_schema_nocodb.json`.

4. **Install PostgreSQL workflow functions**
   - Import the ordered SQL modules under `schema/pgsql/`.
   - Internal multi-row workflow behavior is implemented transactionally in PostgreSQL rather than in a separate NocoDB automation service.

5. **Import the Appsmith application**
   - Follow [`appsmith/README.md`](appsmith/README.md).
   - Import `appsmith/MushroomProcess.json`.
   - Use `scripts/pretty-json.mjs` when normalizing a newly exported Appsmith project.
   - Treat `appsmith/spec/` as retained planning/reference material, not as the authoritative runtime definition.

6. **Point the Print Daemon at NocoDB**  
   - Update `.env` as described in `print-daemon/README.md` with NocoDB URL, token, and print_queue table ID.
   - Restart the daemon. It will now pull jobs from NocoDB instead of Airtable.

---

## Next Steps

- See `doc/CHANGELOG.md` and `doc/FIELD_MAP.md` for detailed field-level evolution.
- Iterate on automations and interfaces to match your exact cultivar mix, packaging formats, and QA steps.
