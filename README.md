# MushroomProcess (PostgreSQL + Appsmith + n8n)

Current version: **1.2.0**.

See [`doc/RELEASE_PROCESS.md`](doc/RELEASE_PROCESS.md) for the repeatable release workflow.

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

The application runs on **PostgreSQL, Appsmith and n8n**, with optional NocoDB access for administration. The core model includes:

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
  Repository-level maintenance utilities, including Appsmith JSON normalization, navigation synchronization, and reporting-data audit tooling.
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
  - `Reporting-Data-Contract.md` – historical/current lifecycle, cohort, lineage, and inventory reporting source contract
  - `Lessons_Learned_and_Evolution_Report.pdf`
  - `NOTICE.md`

---

## Fresh installation

1. Start PostgreSQL 16, Appsmith and n8n. The [RootedOps fresh-host guide](https://github.com/RayzorDuff/RootedOps/blob/main/doc/fresh-host-recovery.md) describes an isolated test deployment of these services.
2. Clone this repository and follow the [PostgreSQL installation](schema/pgsql/README.md#fresh-installation-without-operational-data) to initialize an empty MushroomProcess database.
3. In Appsmith, follow the [application guide](appsmith/README.md) to import `appsmith/MushroomProcess.json`. Bind the PostgreSQL datasource to the database from step 2 and test the connection. Set up the initial operator using the email of the actual Appsmith login.
4. Import the PostgreSQL workflows you need from `n8n/workflows/`. Create credentials for this installation and update the imported credential bindings and endpoint URLs. Keep workflows inactive until their credentials, destinations and triggers have been reviewed.
5. If you use label printing, configure the optional [print daemon](print-daemon/README.md) for your queue and printer.

## Next Steps

- See `doc/CHANGELOG.md`, `doc/FIELD_MAP.md`, and `doc/Reporting-Data-Contract.md` for field-level evolution and reporting source semantics.
- Iterate on automations and interfaces to match your exact cultivar mix, packaging formats, and QA steps.
