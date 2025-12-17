# Airtable Schema Tools  

_Airtable ↔ NocoDB from a shared `_schema.json`_

This folder holds everything needed to:

1. **Export** an Airtable base’s schema (and data) to `_schema.json` using `airtable-export`.
2. **Use that same `_schema.json`** to:
   - Recreate / update an **Airtable** base.
   - Create a **NocoDB** project with the same tables and relationships.

The goal is: **one canonical `_schema.json`** that can drive both Airtable and NocoDB.

---

## Contents

- `export/`
  - `_schema.json` – Airtable schema export (tables, fields, types, relationships, formulas, lookups, rollups).
  - `*.json` / `*.ndjson` – optional per-table data exports (lots, events, etc.).

- `compare_schemas.js`  
  Helper script to compare two `_schema.json` files (e.g., between versions) and show structural differences.

- `create_nocodb_from_schema.js`  
  Reads `_schema.json` and creates **basic tables and columns** in NocoDB (primitive field types).

- `create_nocodb_schema_full.js`  
  Extended NocoDB provisioning script (tables + more advanced metadata).

- `create_nocodb_relations_and_rollups.js`  
  Second-pass script that:
  - Reads linked-record metadata from `_schema.json`.
  - Creates relations and formula columns in NocoDB.
  - Prepares scaffolding for lookups and rollups.

- `generate_sql_from_schema.py`  
  Experimental script to emit SQL DDL from `_schema.json`.

---

## 1. Exporting from Airtable with `airtable-export`

These steps assume you start from an Airtable base that already matches the MushroomProcess design.

1. **Install `airtable-export` from Git** (preferred over `pip`):

+
+git clone https://github.com/simonw/airtable-export


   ```bash
   git clone https://github.com/simonw/airtable-export.git

   python -m pip install --user pipx
   python -m pipx ensurepath

   # ensure the older PyPI package doesn't shadow your local clone
   pip uninstall -y airtable-export
   pip install -e airtable-export

   cd .\airtable-export\
   pip install setuptools
   .\setup.py install
   ```

2. **Get your Python location (Windows example):**

   ```powershell
   py -c "import sys; print(sys.prefix)"
   # example: C:\Python313
   ```

3. **Run `airtable-export` against your base:**

   - Create an Airtable Personal Access Token with schema + data read permissions for the base.
   ```bash
   $env:AIRTABLE_KEY = "YOUR_API_KEY_HERE"
   $env:AIRTABLE_BASE = "YOUR_BASE_ID_HERE"
   ```
   - Use `airtable-export` to dump:
     - `_schema.json` (schema only)
     - Per-table `*.json` or `*.ndjson` files (optional data).

   Point the output to this folder’s `export/` directory, or move the files there afterward.

   ```bash
   airtable-export --schema --ndjson --yaml --json export $Env:AIRTABLE_BASE strains recipes products lots items events locations sterilization_runs print_queue ecommerce ecommerce_orders
   ```

4. **Template / redact `_schema.json` (optional)**

   Before distributing your schema, replace business-specific values with generic placeholders. For example, search and replace names and URLs like:

   - `"My Business"`
   - `"Regulated Business"`
   - `www.mybusiness.com`
   - `www.regulatedbusiness.com`
   - `RegulatedBusinessAddressAndContact`
   - `MyBuinessAddressAndContact`
   - `MyBusinessOffering`

   This keeps `_schema.json` reusable without leaking real-world identities.

---

## 2. Re-creating an Airtable Base from `_schema.json`

You can also go the other direction: use `_schema.json` to rebuild a fresh Airtable base.

1. **Create a new Airtable base**

   - Log in to Airtable.
   - Create a new base (e.g. “Mushroom Process”).
   - Record the **Base ID** (e.g. `appXXXXXXXXXXXXXX`).

2. **Set up Airtable API access**

   - Go to `https://airtable.com/account`.
   - Create a Personal Access Token with:
     - Schema read/write
     - Data read/write
   - Restrict it to your new base.
   - Save the token somewhere secure.

3. **Configure your environment**

   Depending on the script you use (Python or Node), set environment variables (example):

   ```bash
   export AIRTABLE_BASE_ID="appXXXXXXXXXXXXXX"
   export AIRTABLE_TOKEN="patXXXXXXXXXXXXXX"
   ```

4. **Run your Airtable schema script**

   - Use your script of choice (use create_airtable_from_schema.js as a base for developing your own) to:
     - Iterate `_schema.json`
     - Create tables
     - Create fields with correct types, options, and relationships

   Notes:

   - You can rerun the script to create **missing** tables/fields without deleting existing data.
   - It will not automatically delete or rename tables; handle destructive changes manually.

5. **(Optional) Import data**

   - Use `airtable-export` or a small script to POST table records from the exported `*.json` files.
   - The schema tools here focus on **structure**; record import is a separate step.

---

## 3. Creating a NocoDB Project from `_schema.json`

This path uses Node.js and the NocoDB REST API, in two passes.

### 3.1. Prerequisites

In this `airtable_schema` folder:

```bash
npm install axios
```

Ensure this directory structure:

```text
airtable_schema/
  create_nocodb_schema_full.js
  export/
    _schema.json
    lots.json
    events.json
    ...
```

### 3.2. Environment variables (PowerShell example)

```powershell
$env:NOCODB_URL       = "http://localhost:8080"   # or your cloud URL
$env:NOCODB_BASE_ID   = "p_your_base_id_here"     # from NocoDB UI
$env:NOCODB_API_TOKEN = "your_api_token_here"     # personal access token

# Optional: help scripts know which metadata to recreate
$env:NOCODB_API_VERSION      = "v2"
$env:NOCODB_API_VERSION_LINKS= "v3"
$env:NOCODB_RECREATE_LINKS   = "true"
$env:NOCODB_RECREATE_ROLLUPS = "true"
$env:NOCODB_RECREATE_LOOKUPS = "true"
```

### 3.3. All passes – Create base tables & primitive columns as well as relationships & formulas 

```powershell
node .\create_nocodb_schema_full.js > full_import.log 2>&1
```

This script:

- Parses link-to-record fields from `_schema.json`.
- Creates relations between tables in NocoDB.
- Creates appropriate formula, rollups, and lookup columns where possible (e.g., simple computed fields).

### 3.4. Compare the AirTable _schema.json with the NocoDB _schema_nocodb.json to identify discrepancies

```powershell
node .\compare_schemas.js > schema_comparison.log 2>&1
```

Review the output from compare_schemas.js as well as the direction from the output of create_nocodb_schema_full.js to determine manual modifications necessary.

---

## 4. Status & Limitations

From the current `create_nocodb_schema_full.js` specification:

1. **Some discrepancies between link columns and created formulas**

   - Primary keys are added to the schema and are different from Airtable defined keys as NocoDB does not allow LongText primary keys.
   - NocoDB creates inverse links that sometimes confuse Airtable's pre-created inverse links.
   - Some functions referencing rollup or lookup fields are not created and must be created manually following the migration.
   - NocoDB’s v3 LTAR (Linked Table And Rollup) metadata is still evolving; scripts expect to be revisited once the API stabilizes.

3. **Data import to NocoDB**

   - The sample TODO is to:
     - Map Airtable functions → NocoDB expressions (e.g., rollups → `SUM`, `COUNT`, `MIN`, `MAX`, etc.).
     - Add a script to import records from the per-table JSON/NDJSON into NocoDB via `/api/v2/tables/:tableId/records`.

---

## 5. Comparing Schema Versions

Use `compare_schemas.js` to:

- Diff two `_schema.json` files (old vs new).
- Identify added/removed tables, fields, and type changes.
- Review the impact before re-running your provisioning scripts.

---

With these tools, you can:

- Start with an Airtable base,
- Export its schema into `_schema.json`,
- Use that same file to **rebuild Airtable** or to **stand up NocoDB**, and
- Keep both in sync as you evolve the MushroomProcess data model.
