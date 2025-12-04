# MushroomProcess  
_Airtable / NocoDB Inventory, Traceability & Labeling System_

This project implements a production-grade inventory, traceability, and label-printing system for a mushroom cultivation business.

It started on **Airtable** and is being migrated to **NocoDB**, while keeping the same core model:

- Items, recipes, strains
- Locations & stations (sterilizer, inoculation, dark room, fruiting, harvest, packaging)
- Sterilization runs and lots
- Events / audit log
- Ecommerce products and print queue for labels

The system ties together:

- A normalized **schema** (`airtable_schema/`)
- **Automations** to enforce workflows (`airtable_automation/`, `nocodb_automation/`)
- **Interfaces / Views** for station operators (`airtable_interfaces/`, `nocodb_interfaces/`)
- A **print daemon** that watches a queue and prints 4×2 thermal labels (`print-daemon/`)
- Optional **Ecwid integration** for ecommerce sync (`integrations/ecwid/`)

---

## Repository Layout

- `airtable_schema/`  
  Tools to export an Airtable base to `_schema.json` (via `airtable-export`), clean it up, and use that same JSON to:
  - Recreate a fresh **Airtable** base, and
  - Generate a **NocoDB** project (tables + relations + formulas) from the Airtable schema.  
  _See [`airtable_schema/README.md`](airtable_schema/README.md)._

- `airtable_automation/`  
  JavaScript **Airtable Automation** scripts that implement the production flows (sterilizer in/out, LC → grain, grain → substrate, spawn to bulk, harvest, packaging, etc.).  
  _See [`airtable_automation/README.md`](airtable_automation/README.md)._

- `airtable_interfaces/`  
  Documentation for the Airtable **Interfaces** (station UIs), plus a PDF (“Mushroom Process_Interfaces.pdf”) describing page-by-page setup.  
  _See [`airtable_interfaces/README.md`](airtable_interfaces/README.md)._

- `nocodb_automation/`  
  Node.js handlers that mirror Airtable automations using the NocoDB REST API.  
  _See `nocodb_automation/README_NocoDB_AUTOMATIONS.md`._

- `nocodb_interfaces/`  
  Node.js scripts to create NocoDB views that resemble the Airtable Interfaces, plus Retool how-to text files for each interface.  
  _See [`nocodb_interfaces/README.md`](nocodb_interfaces/README.md)._

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

- `screenshots/`  
  Reference screenshots of Airtable interfaces and flows.

---

## How the System Hangs Together

At a high level:

1. **Schema**  
   - Start from an Airtable base (the current production base or a template).
   - Export its schema using `airtable-export` into `_schema.json` and table data JSON.
   - Use `airtable_schema` tools to:
     - Recreate a clean Airtable base, or
     - Generate the full NocoDB schema from that same `_schema.json`.

2. **Automations**  
   - On Airtable: create one Automation per flow and paste the corresponding script from `airtable_automation/`.
   - On NocoDB: deploy the Node handlers in `nocodb_automation/` and call them from NocoDB button fields via webhooks.

3. **Interfaces / Views**  
   - Airtable Interfaces are defined by the PDF and text files in `airtable_interfaces/`.
   - NocoDB views and Retool apps are created using the scripts and notes in `nocodb_interfaces/`.

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
   - Optionally use `airtable_schema/` to reconstruct the schema from `_schema.json`.

2. **Install Airtable Automations**  
   - Follow [`airtable_automation/README.md`](airtable_automation/README.md) to:
     - Add one Automation per script, typically triggered from a button that passes the current record ID.
     - Paste each script into the Script action.
     - Adjust field names if your base differs.

3. **Create Interfaces**  
   - Follow [`airtable_interfaces/README.md`](airtable_interfaces/README.md) and the `Mushroom Process_Interfaces.pdf` to recreate station interfaces.
   - Ensure `ui_error` is visible in each interface so operators see validation failures.

4. **Set Up the Print Daemon**  
   - Follow [`print-daemon/README.md`](print-daemon/README.md) to configure `.env`, install Node dependencies, and run or service-wrap `print-daemon.js`.

5. **(Optional) Ecwid Integration**  
   - If you use Ecwid, configure `integrations/ecwid` to sync SKUs and orders.

---

## Quick Start – NocoDB Migration

Once you have an Airtable base and `_schema.json`:

1. **Install NocoDB (Windows quick test)**  
   - Download the Windows installer from the NocoDB GitHub releases page.
   - Install and then open: `http://localhost:8080/dashboard`.
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

3. **Use `airtable_schema` to create the NocoDB schema**  
   - See [`airtable_schema/README.md`](airtable_schema/README.md) for:
     - Directory layout (where `_schema.json` and data exports live).
     - Running `create_nocodb_from_schema.js` to create tables.
     - Running `create_nocodb_relations_and_rollups.js` to wire up relationships and formulas.

4. **Wire NocoDB Automations**  
   - Follow `nocodb_automation/README_NocoDB_AUTOMATIONS.md` to:
     - Add NocoDB Buttons per flow.
     - Configure webhooks to hit your Node services.
     - Ensure environment variables for NocoDB API access are set.

5. **Create NocoDB Views & Retool Apps**  
   - Follow [`nocodb_interfaces/README.md`](nocodb_interfaces/README.md) to:
     - Run the view-creator scripts.
     - Use the Retool “how-to” notes to recreate equivalent station dashboards.

6. **Point the Print Daemon at NocoDB**  
   - Update `.env` as described in `print-daemon/README.md` with NocoDB URL, token, and print_queue table ID.
   - Restart the daemon. It will now pull jobs from NocoDB instead of Airtable.

---

## Next Steps

- See `doc/CHANGELOG.md` and `doc/FIELD_MAP.md` for detailed field-level evolution.
- Iterate on automations and interfaces to match your exact cultivar mix, packaging formats, and QA steps.
