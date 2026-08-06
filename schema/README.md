# Schema and Migration Tools

_Airtable export → PostgreSQL, with retained Airtable and optional NocoDB tooling_


## Environment (.env)

All scripts in this directory load environment variables from `schema/.env` automatically (if present).

1. Copy `.env.example` → `.env`
2. Fill in values
3. Run the scripts normally (no need to set `$env:` variables).

> Variables set in your shell still take precedence; `.env` only fills in missing keys.

## Verified working versions

This repository state has been tested through a full schema import into:

- **NocoDB**: `0.265.1`
- **PostgreSQL**: `13`

This folder consolidates the complete database migration toolchain:

1. **Export** an Airtable base’s schema and data with `airtable-export`.
2. Recreate or update an **Airtable** base from the same export.
3. Generate the canonical **PostgreSQL** schema, views, functions, load files, and tests.
4. Retain the older **NocoDB** provisioning and schema-comparison utilities where they remain useful.

The goal is one canonical Airtable export that drives the final Airtable parity build and the PostgreSQL production migration.

---

## Contents

- `export/`
  - `_schema.json` — canonical Airtable schema export.
  - `_schema_nocodb.json` — retained NocoDB schema snapshot used by the comparison/provisioning tools.
  - `tables_dump.json`, `*.json`, `*.ndjson`, and `*.yml` — Airtable data exports and generated table artifacts.

- `pgsql/`
  - Ordered PostgreSQL schema, view, function, seed, load, and migration modules.
  - `csv/` — generated load data and link tables.
  - `tests/` — rollback-protected PostgreSQL regression tests.

- `compare_schemas.js`  
  Helper script to compare two `_schema.json` files (e.g., between versions) and show structural differences.

- `create_nocodb_schema_full.js`  
  Extended NocoDB provisioning script (tables + more advanced metadata).

- `airtable_export_to_postgres_sql.js`  
  **Primary “Airtable-export → Postgres” generator.** Reads `export/_schema.json` (and optionally `export/tables_dump.json` + per-table exports)
  and emits Postgres DDL + views + (optionally) CSV + a `\copy` loader script.

- `list_nocodb_bases.js`  
  Utility to list the **data sources** configured inside a NocoDB “base/project” (prints IDs, aliases, type).

- `patch_nocouuid_default.js`  
  One-off migration helper: patches every `nocouuid` column in a NocoDB base to default to `gen_random_uuid()` (Postgres),
  and enforces `NOT NULL` + `UNIQUE`.

- `generate_sql_from_schema.py`  
  Lightweight / experimental SQL emitter from `_schema.json` (multi-dialect). Useful for quick prototypes.

---

## Script details

### `airtable_export_to_postgres_sql.js` (recommended Postgres path)

This script turns an `airtable-export` bundle into **PostgreSQL artifacts** without using NocoDB’s meta APIs.

**When to use it**

- You want a **repeatable, deterministic** Postgres schema derived from Airtable’s `_schema.json`.
- You want **junction tables** for Airtable `multipleRecordLinks` and view-layer conveniences.
- You want to move away from “import into NocoDB then export SQL” workflows.

**Inputs**

Minimum:

- `export/_schema.json`

Recommended:

- `export/tables_dump.json`

Optional:

- `export/<table>.json` or `export/<table>.ndjson`

**Outputs**

- `001_tables.sql`
- `002_links.sql`
- `003_views.sql`
- `004_computed_views.sql`
- `100_load.sql` (optional)
- `csv/*.csv` (optional)

001–009   Airtable base schema (do not modify)
010–049   core system extensions
050–099   schema improvements / refactors
100–149   data loads / backfills
150–199   maintenance / repair / migrations

**Environment variables**

- `AIRTABLE_SCHEMA_PATH`
- `TABLES_DUMP_PATH`
- `POSTGRES_SCHEMA`
- `POSTGRES_OUT_DIR`
- `AIRTABLE_EXPORT_DIR`
- `CREATE_VIEWS`
- `BIGINT_PKS`

**Run**

```bash
node airtable_export_to_postgres_sql.js
```

When Airtable exports more than one linked record for a field marked
`prefersSingleRecordLink`, the generator now normalizes the relational load to
one deterministic target and writes the anomalies to:

```text
pgsql/csv/_prefers_single_link_conflicts.csv
```

Review that report before production cutover. The generated load remains
transactional and the scalar FK and derived junction row use the same target.

Run the offline generator contract smoke test after schema or formula changes:

```bash
node tests/airtable_export_to_postgres_sql_smoke.js
```

---

### `generate_sql_from_schema.py`

A smaller Python script that emits `CREATE TABLE` statements from `_schema.json` for multiple dialects.

**Run**

```bash
python generate_sql_from_schema.py --dialect postgres --output schema.sql
```

---

### `list_nocodb_bases.js`

Lists the **data sources** attached to a NocoDB base/project.

**Requires**

- `NOCODB_BASE_ID`

**Run**

```bash
node list_nocodb_bases.js
```

---

### `patch_nocouuid_default.js`

Patches every `nocouuid` column in a NocoDB base so that Postgres will auto-generate UUIDs.

**Prereqs**

```sql
CREATE EXTENSION IF NOT EXISTS pgcrypto;
```

**Run**

```bash
node patch_nocouuid_default.js
```

---

## 1. Exporting from Airtable with `airtable-export`

These steps assume you start from an Airtable base that already matches the MushroomProcess design.

1. **Install `airtable-export` from Git** (preferred over `pip`):


Install dependencies:

   ```bash
   # Clone the repository
   git clone https://github.com/simonw/airtable-export.git
   cd airtable-export

   # Ensure pip and pipx are installed and in your PATH
   python3 -m pip install --user pipx
   python3 -m pipx ensurepath

   # Important: Restart your terminal here if this is your first time installing pipx

   # Ensure the older PyPI package doesn't shadow your local clone
   python3 -m pip uninstall -y airtable-export
```
For Windows:

   ```bash
   pip install setuptools
   .\setup.py install
   ```

For Mac:

   ```bash
   # Install the local directory in 'editable' mode
   python3 -m pip install -e .
   ```

2. **Get your Python location (Windows example):**

   ```powershell
   py -c "import sys; print(sys.prefix)"
   # example: C:\Python313
   ```

3. **Run `airtable-export` against your base:**

   - Create an Airtable Personal Access Token with schema + data read permissions for the base.
   
   Windows:
   ```bash
   $env:AIRTABLE_KEY = "YOUR_API_KEY_HERE"
   $env:AIRTABLE_BASE = "YOUR_BASE_ID_HERE"
   ```

   Mac:
   ```bash
   export AIRTABLE_KEY=YOUR_API_KEY_HERE
   export AIRTABLE_BASE=YOUR_BASE_ID_HERE
   ```

   - Use `airtable-export` to dump:
     - `_schema.json` (schema only)
     - Per-table `*.json` or `*.ndjson` files (optional data).

   Point the output to this folder’s `export/` directory, or move the files there afterward.

   Windows:
   ```bash
   airtable-export --schema --ndjson --yaml --json export $Env:AIRTABLE_BASE strains recipes products lots items events locations sterilization_runs print_queue ecommerce ecommerce_orders item_recipe_components lot_recipe_components
   ```

   Mac:
   ```bash
   airtable-export --schema --ndjson --yaml --json --key $AIRTABLE_KEY  export $AIRTABLE_BASE strains recipes products lots items events locations sterilization_runs print_queue ecommerce ecommerce_orders item_recipe_components lot_recipe_components
   ```

   Also dump Airtable table metadata:

   ```bash
   curl.exe "https://api.airtable.com/v0/meta/bases/$Env:AIRTABLE_BASE/tables" -H "Authorization: Bearer $Env:AIRTABLE_KEY" --ssl-no-revoke  -o export/tables_dump.json
   ```

   or on Mac:
   ```bash
   curl "https://api.airtable.com/v0/meta/bases/${AIRTABLE_BASE}/tables" -H "Authorization: Bearer ${AIRTABLE_KEY}" --ssl-no-revoke  -o export/tables_dump.json
   ```

   Use the post-processor script to remove any "From field" style tables that were not removed from AirTable prior to export
   as well as to change the business-specific identifiers within the schema to generic entries.

   ```bash
   copy export/_schema.json export/_schema.json.orig
   copy export/tables_dump.json export/tables_dump.json.orig
   node airtable_export_postprocess.js export/_schema.json.orig export/_schema.json
   node airtable_export_postprocess.js export/tables_dump.json.orig export/tables_dump.json
   ```

   The post-processor supports two environment toggles (use `.env` or shell env vars):

   - `POSTPROCESS_REWRITE_COMPANY` (default `true`): rewrite company/branding formulas to generic placeholders.
   - `POSTPROCESS_REMOVE_EXTRA_FIELDS` (default `true`): remove Airtable-export helper fields like `From field: ...`.

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

In this `schema` folder:

```bash
npm install axios
```

Ensure this directory structure:

```text
schema/
  create_nocodb_schema_full.js
  export/
    _schema.json
    _schema_nocodb.json
    lots.json
    events.json
    ...
  pgsql/
    001_tables.sql
    ...
    tests/
```

### 3.2. Environment variables (PowerShell example)

If you use `.env`, you can skip the PowerShell `$env:` setup below.

PowerShell example (optional)

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

The NocoDB schema import script supports using different API versions for different feature sets:

- `NOCODB_API_VERSION` controls table + field metadata operations (commonly `v2`)
- `NOCODB_API_VERSION_LINKS` controls LTAR/link creation (commonly `v3`)

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

### 3.5. Import Airtable-export JSON table data into NocoDB

Once the schema has been created (section 3.3) and any required manual fixes are applied, you can import records from the airtable-export JSON files.

This repository includes a data importer:

- import_nocodb_data_from_airtable_export.js

It reads export/{table}.json (array-of-records JSON) and performs an idempotent upsert using airtable_id:

- Pass A: create/update non-link fields
- Pass B: update link (LTAR) fields after row IDs exist

#### Environment variables (PowerShell example)

Use the same NocoDB env vars as the schema script:

```powershell
$env:NOCODB_URL = "http://localhost:8080" +$env:NOCODB_BASE_ID = "p_your_base_id_here"
$env:NOCODB_API_TOKEN = "your_api_token_here" 

# Optional
$env:AIRTABLE_EXPORT_DIR = ".\\export" # default
$env:NOCODB_BATCH_SIZE = "100" # default 100
$env:NOCODB_DEBUG = "1" # verbose logging
$env:TABLES = "items,locations,ecommerce" # import subset (optional)
```

#### Run the import

```powershell
node .\\import_nocodb_data_from_airtable_export.js > data_import.log 2>&1
```

#### Notes / expectations

- The exporter in this repo writes link fields as arrays of Airtable record IDs (e.g. ["rec..."]). The importer translates those to arrays of NocoDB row IDs by looking up rows via airtable_id.
- If you import only a subset of tables, links to tables you did not import will resolve to empty arrays (because the target rows do not exist yet). Re-run the importer later after importing the missing tables.
- If you want a “clean re-import”, wipe the NocoDB table data first (either via UI or SQL), then rerun the importer.

---

## 4. Status & Limitations

From the current `create_nocodb_schema_full.js` specification:

1. **Some discrepancies between Airtable and NocoDB are unavoidables**

   - Primary keys are added to the schema and are different from Airtable defined keys as NocoDB does not allow LongText primary keys.
   - NocoDB creates inverse links that sometimes confuse Airtable's pre-created inverse links.
   - NocoDB has inherent limitations, such as having formulas add rollup counts or having DATESTR operate on a field that is not a date or datetime field.
     This script may fail fields in these cases and modifications to Airtable schema may be in order.
   - NocoDB creates inverse links automatically. The script renames these where possible to match Airtable naming, but extra LTAR columns may still appear.
   - NocoDB does not support rollups over lookup/rollup fields on another table; these should be redesigned in Airtable prior to export
      (e.g., roll up a primitive field or materialize the value).
   - Some formulas are intentionally not created when they rely on unsupported constructs; these must be adjusted in the Airtable schema or created manually.
   - NocoDB’s v3 LTAR metadata is still evolving; links creation via v3 may require stabilization steps and may be revisited as the API changes.

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
