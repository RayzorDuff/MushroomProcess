# MushroomProcess Postgres Rebuild / Reload

This directory contains the generated SQL used to rebuild the MushroomProcess bridge database, which runs inside the RootedOps Docker stack.

---

## Overview

This process is used after:

- Exporting Airtable
- Regenerating `schema/pgsql/*.sql`
- Needing to rebuild the Postgres schema from scratch

Workflow:

1. Backup current database
2. Drop and recreate database
3. Import pre-load schema/function SQL files through Docker
4. Import `100_load.sql` from the host with `psql`
5. Import post-load integration/backfill SQL through Docker

---

## Why `100_load.sql` Is Special

`100_load.sql` uses `\copy ... FROM csv/...`, for example:

```sql
\copy "strains"(...) FROM csv/strains.csv WITH (FORMAT csv, HEADER true);
```

`\copy` is a **psql client-side** command, not a server-side `COPY`.

That means the CSV files must be visible to the **machine running `psql`**, and the relative path `csv/...` is resolved from the current working directory of the `psql` client.

Because of that, `100_load.sql` should **not** be run with the same `docker exec ... psql < file.sql` pattern unless the `csv/` directory has first been copied into the container and the working directory is set correctly.

The simplest approach for this project is:

- run pre-load `0xx` SQL files through `docker exec`
- run `100_load.sql` locally from the host with `psql` against the mapped Postgres port
- run post-load integration/backfill SQL such as `124_*` through `docker exec` only after the data load commits

---

## Target Database

Container:

- `mushroomprocess-bridge-postgres`

Configuration source:

- `RootedOps/.env`

Variables:

- `MP_BRIDGE_DB_NAME`
- `MP_BRIDGE_DB_USER`
- `MP_BRIDGE_DB_PASSWORD`

Compose file:

- `RootedOps/docker/docker-compose.yml`

---

## SQL File Order

Import in lexical order:

```text
001_tables.sql
002_links.sql
003_views.sql
004_computed_views.sql
005_helpers.sql
006_triggers.sql
007_sterilizer.sql
008_lot_actions.sql
009_harvest_actions.sql
010_spawn_to_bulk.sql
011_print_queue_actions.sql
012_ecommerce_order_upsert.sql
021_personnel_reviews.sql
022_personnel_reviews_seeds.sql
023_operator_identity.sql
024_inventory_reconciliation.sql
025_inventory_reconciliation_lots.sql
100_load.sql
124_operator_identity_backfill_and_review_integration.sql
```

### Notes

- Tables → Views → Functions → Triggers → Data load
- `100_load.sql` = seed/reference data load from CSV files
- `124_*` = later patch file

Because `124_operator_identity_backfill_and_review_integration.sql` sorts after `100_load.sql`, it is still applied after the load step.

---


### Inventory reconciliation (#78)

- `024_inventory_reconciliation.sql` provides transactional Product location reconciliation.
- `025_inventory_reconciliation_lots.sql` adds the equivalent Lot path using `mp_lot_set_location(...)`.
- The Appsmith Inventory - Reconcile page submits Product and Lot reconciliation calls in one PostgreSQL statement so a failure in either scope rolls back the complete physical-location reconciliation.

## Full Rebuild Procedure

### 1. Change into RootedOps

```bash
cd /path/to/RootedOps
```

### 2. Load Environment Variables

```bash
set -a
source ./.env
set +a
```

### 3. Start Postgres Container

```bash
sudo docker compose --env-file .env -f docker/docker-compose.yml up -d mushroomprocess-bridge-postgres
```

### 4. Backup Existing Database

```bash
mkdir -p ./tmp

sudo docker exec \
  -e PGPASSWORD="$MP_BRIDGE_DB_PASSWORD" \
  mushroomprocess-bridge-postgres \
  pg_dump \
    -U "$MP_BRIDGE_DB_USER" \
    -d "$MP_BRIDGE_DB_NAME" \
    --clean --if-exists --no-owner --no-privileges \
  > "./tmp/mushroomprocess-bridge-pre-reimport-$(date +%Y%m%d-%H%M%S).sql"
```

Optional compressed version:

```bash
sudo docker exec \
  -e PGPASSWORD="$MP_BRIDGE_DB_PASSWORD" \
  mushroomprocess-bridge-postgres \
  pg_dump \
    -U "$MP_BRIDGE_DB_USER" \
    -d "$MP_BRIDGE_DB_NAME" \
    --clean --if-exists --no-owner --no-privileges \
  | gzip -c \
  > "./tmp/mushroomprocess-bridge-pre-reimport-$(date +%Y%m%d-%H%M%S).sql.gz"
```

### 5. Drop and Recreate Database

```bash
sudo docker exec \
  -e PGPASSWORD="$MP_BRIDGE_DB_PASSWORD" \
  mushroomprocess-bridge-postgres \
  psql -U "$MP_BRIDGE_DB_USER" -d postgres \
  -c "DROP DATABASE IF EXISTS \"$MP_BRIDGE_DB_NAME\";"

sudo docker exec \
  -e PGPASSWORD="$MP_BRIDGE_DB_PASSWORD" \
  mushroomprocess-bridge-postgres \
  psql -U "$MP_BRIDGE_DB_USER" -d postgres \
  -c "CREATE DATABASE \"$MP_BRIDGE_DB_NAME\";"
```

### 6. Import Pre-Load SQL Files Through Docker

Run from the `MushroomProcess` repo root. Only import the `0xx` files at this stage; `100_load.sql` and post-load files such as `124_*` must run later in their documented order.

```bash
cd /path/to/MushroomProcess
set -e

for f in schema/pgsql/0*.sql; do
  echo "Importing $f"
  sudo docker exec -i \
    -e PGPASSWORD="$MP_BRIDGE_DB_PASSWORD" \
    mushroomprocess-bridge-postgres \
    psql -v ON_ERROR_STOP=1 \
      -U "$MP_BRIDGE_DB_USER" \
      -d "$MP_BRIDGE_DB_NAME" \
    < "$f"
done
```

The explicit equivalent is:

```bash
cd /path/to/MushroomProcess

for f in \
  schema/pgsql/001_tables.sql \
  schema/pgsql/002_links.sql \
  schema/pgsql/003_views.sql \
  schema/pgsql/004_computed_views.sql \
  schema/pgsql/005_helpers.sql \
  schema/pgsql/006_triggers.sql \
  schema/pgsql/007_sterilizer.sql \
  schema/pgsql/008_lot_actions.sql \
  schema/pgsql/009_harvest_actions.sql \
  schema/pgsql/010_spawn_to_bulk.sql \
  schema/pgsql/011_print_queue_actions.sql \
  schema/pgsql/012_ecommerce_order_upsert.sql \
  schema/pgsql/021_personnel_reviews.sql \
  schema/pgsql/022_personnel_reviews_seeds.sql \
  schema/pgsql/023_operator_identity.sql \
  schema/pgsql/024_inventory_reconciliation.sql \
  schema/pgsql/025_inventory_reconciliation_lots.sql
do
  echo "Importing $f"
  sudo docker exec -i \
    -e PGPASSWORD="$MP_BRIDGE_DB_PASSWORD" \
    mushroomprocess-bridge-postgres \
    psql -v ON_ERROR_STOP=1 \
      -U "$MP_BRIDGE_DB_USER" \
      -d "$MP_BRIDGE_DB_NAME" \
    < "$f"
done
```

### 7. Import `100_load.sql` From the Host Using `psql`

This step requires a local `psql` client installed on the host.

Change into the SQL directory first so the relative `csv/...` paths resolve correctly:

```bash
cd /path/to/MushroomProcess/schema/pgsql
```

Then run:

```bash
PGPASSWORD="$MP_BRIDGE_DB_PASSWORD" \
psql \
  -h 127.0.0.1 \
  -p 5434 \
  -U "$MP_BRIDGE_DB_USER" \
  -d "$MP_BRIDGE_DB_NAME" \
  -v ON_ERROR_STOP=1 \
  -f 100_load.sql
```

Why this works:

- `psql` runs on the host
- `100_load.sql` references `csv/...`
- those CSV files exist under this directory on the host
- Postgres is exposed by RootedOps on port `5434`

### 8. Import Post-Load Integration and Backfill SQL

Run post-load files only after `100_load.sql` commits successfully. These scripts depend on imported rows and may silently update zero rows if run too early.

```bash
cd /path/to/MushroomProcess

sudo docker exec -i \
  -e PGPASSWORD="$MP_BRIDGE_DB_PASSWORD" \
  mushroomprocess-bridge-postgres \
  psql -v ON_ERROR_STOP=1 \
    -U "$MP_BRIDGE_DB_USER" \
    -d "$MP_BRIDGE_DB_NAME" \
  < schema/pgsql/124_operator_identity_backfill_and_review_integration.sql
```

### 9. Verify Import

```bash
sudo docker exec \
  -e PGPASSWORD="$MP_BRIDGE_DB_PASSWORD" \
  mushroomprocess-bridge-postgres \
  psql -U "$MP_BRIDGE_DB_USER" -d "$MP_BRIDGE_DB_NAME" \
  -c "\dt"

sudo docker exec \
  -e PGPASSWORD="$MP_BRIDGE_DB_PASSWORD" \
  mushroomprocess-bridge-postgres \
  psql -U "$MP_BRIDGE_DB_USER" -d "$MP_BRIDGE_DB_NAME" \
  -c "\dv"
```

---

## Alternative: Copy CSV Files Into the Container

If you prefer to keep everything inside Docker, you can copy the `csv/` directory into the container and run `100_load.sql` there.

Example:

```bash
cd /path/to/MushroomProcess/schema/pgsql

sudo docker exec mushroomprocess-bridge-postgres mkdir -p /tmp/mp-pgload
sudo docker cp ./csv mushroomprocess-bridge-postgres:/tmp/mp-pgload/csv
sudo docker cp ./100_load.sql mushroomprocess-bridge-postgres:/tmp/mp-pgload/100_load.sql

sudo docker exec \
  -i \
  -w /tmp/mp-pgload \
  -e PGPASSWORD="$MP_BRIDGE_DB_PASSWORD" \
  mushroomprocess-bridge-postgres \
  psql -v ON_ERROR_STOP=1 \
    -U "$MP_BRIDGE_DB_USER" \
    -d "$MP_BRIDGE_DB_NAME" \
    -f /tmp/mp-pgload/100_load.sql
```

This works because the `psql` client is then running inside the container with `/tmp/mp-pgload` as its working directory, so `csv/...` resolves to `/tmp/mp-pgload/csv/...`.

For this project, the host-side `psql` method is usually simpler.

---

## Important Notes

- This rebuild targets the **bridge Postgres DB**, not the NocoDB metadata DB
- The Postgres service is exposed on host port `5434`
- All non-load SQL files can be imported with `docker exec`
- `100_load.sql` must be run where the `csv/` directory is visible to the `psql` client
- Always back up before rebuilding
- All commands use `ON_ERROR_STOP=1` so the process stops on the first SQL error

---

## Known Limitation

This process restores whatever tables and records are present in the generated SQL and CSV export.

If a table, view dependency, attachment mapping, computed value, or external integration state is not represented in the export/generator output, it will not be recreated by this process.

---

## Typical Use Case

After regenerating schema from Airtable export:

1. Regenerate `schema/pgsql/*.sql`
2. Start RootedOps Postgres
3. Back up current bridge DB
4. Drop/recreate bridge DB
5. Import pre-load `0xx` SQL through Docker
6. Import `100_load.sql` from the host with `psql`
7. Import post-load `124_*` integration/backfill SQL
8. Verify schema and seed data loaded correctly


## Notes on action helpers

- `mp_lot_set_location_by_name(...)` updates the scalar `lots.location_id` and now also refreshes the Airtable-style location link tables for lots.
- `mp_product_set_storage_location_by_name(...)` updates the scalar `products.storage_location_id` and now also refreshes the Airtable-style location link tables for products.
- `mp_lots_package_basic(...)` now checks whether `lots.process_type_mat` or+  `lots.process_type` actually exists before referencing either column.



## Issue #12 Phase 1: provider-neutral ecommerce metadata

`026_ecommerce_provider_neutral.sql` adds provider-neutral catalog fields while retaining the legacy `ecwid_*` columns. Existing Ecwid rows are backfilled with `provider = 'ecwid'`, `site_key = 'dank_mushrooms'`, generic SKU/price/stock/public URL/UPC aliases, and a primary-listing flag. Triggers keep the generic aliases current when existing Ecwid integrations continue to update the legacy columns. Once a row is moved to another provider such as `woocommerce`, later Ecwid legacy updates no longer overwrite the generic provider mapping.

For an incremental production deployment, import `026_ecommerce_provider_neutral.sql` after the existing schema files. It is idempotent and may be re-run. On a rebuild, `001_tables.sql` contains the new columns and `026` installs/backfills the compatibility triggers before/after data load as applicable.

## Issue #12 Phase 1B: PostgreSQL-native Ecwid catalog sync

`027_ecommerce_ecwid_catalog_sync.sql` provides the database contract used by `MushroomProcess - Ecwid Catalog Sync - PGSQL`.

It adds:

- `ecommerce_upc_pool`, seeded from the existing repository UPC pool;
- `mp_normalize_gtin_text(...)`, including repair of scientific-notation UPC strings inherited from Airtable exports;
- `mp_ecommerce_reserve_upc(...)` for serialized/idempotent UPC allocation;
- `mp_ecommerce_ecwid_catalog_sync_candidates()` for provider-neutral Ecwid sync candidates and sellable inventory counts;
- `mp_ecommerce_ecwid_catalog_sync_writeback(...)` for guarded legacy + provider-neutral metadata persistence after a successful Ecwid API update.

The candidate function deliberately derives availability from current PostgreSQL state instead of relying on Airtable-era ecommerce junction rollups. Product availability excludes expired records and terminal/exception storage locations (Shipped, Expired, Consumed, Compost/Composted, Retired, Missing/Missing or Lost). Lot availability follows the former Airtable `ecommerce_refresh.js` status map and excludes expired Lots.

For an incremental production deployment, import `027_ecommerce_ecwid_catalog_sync.sql` after `026_ecommerce_provider_neutral.sql`, run `027_ecommerce_ecwid_catalog_sync_smoke.sql`, and only then import/activate the n8n catalog workflow.

## Issue #12 Phase 2: stable QR resolver contract

`028_qr_resolver.sql` adds `mp_qr_resolve_inventory(text)`, the provider-neutral database contract behind `https://qr.danks.store/r?i=...`. Product identifiers resolve through the Product item/strain mapping to exactly one enabled ecommerce row with a public URL. A single `is_primary_public_listing = true` row wins when more than one active provider mapping exists; multiple primary mappings (or multiple active mappings without a primary) are rejected as ambiguous rather than routed arbitrarily. Lot identifiers are validated and returned for the HTTP layer to deep-link into Appsmith.

For an incremental production deployment, import `028_qr_resolver.sql` after `027_ecommerce_ecwid_catalog_sync.sql`, run `028_qr_resolver_smoke.sql`, then import and publish `MushroomProcess - QR Resolver - PGSQL`. RootedOps exposes the workflow through `qr.danks.store`; the n8n container must receive `MP_APP_LOTS_URL` containing the published Appsmith Lots page URL.

### QR Product routing classes (Issue #12)

After `028_qr_resolver.sql`, apply `029_qr_product_routing.sql`. It keeps the stable QR identifier contract but classifies fresh/freezer trays for the internal Products interface and regulated freeze-dried/capsule Products for the regulated business base website.

### `030_qr_scan_log.sql` — QR scan analytics foundation

Creates `qr_scan_log` and `mp_qr_log_scan(jsonb)`. The public QR resolver uses this to persist one request record per scan, including the resolved inventory ID, routing outcome, company/item/strain/location snapshots, client/browser/device metadata, and Cloudflare visitor-location headers when available. The denormalized inventory fields intentionally preserve scan-time context for later reporting.

### Legacy Airtable/public-link cleanup (#12 Phase 6)

Stable QR routing now owns Product/Lot navigation. The export generator suppresses
Airtable/formula `public_link*` fields when producing `vc_lots`, `vc_products`,
and `vc_print_queue`, and Appsmith/print-daemon runtime consumers have been
removed.

Airtable is now deprecated as a production source rather than a database that is
expected to be migrated again. `031_remove_legacy_public_links.sql` therefore
removes the obsolete fields from the **live** PostgreSQL computed views:

- ten `public_link*` columns from `vc_lots`;
- `public_link` from `vc_products`;
- `public_link_from_lot_id` and `public_link_from_product_id` from
  `vc_print_queue`.

Migration 031 was built from the live production view definitions captured during
the Phase 6 preflight. It verifies whitespace-normalized signatures for all three
target views before changing anything, captures downstream view definitions and
metadata from PostgreSQL, drops/recreates them in dependency order without
`CASCADE`, and aborts if a downstream view still explicitly consumes a legacy
`public_link*` field.

For an incremental production deployment, import
`031_remove_legacy_public_links.sql` after the preceding schema migrations and
then run `031_remove_legacy_public_links_smoke.sql`. Do **not** re-import
`004_computed_views.sql` for this cleanup; that file remains historical/generator
output derived from the former Airtable migration path.

Retained Airtable exports, `airtable_id`, and migration tooling remain available
for historical provenance and schema archaeology, but PostgreSQL/Appsmith is the
authoritative production implementation and no future Airtable migration is
assumed.


### `032_recipe_management.sql` — Recipe and ingredient administration (#79)

PostgreSQL/Appsmith is now the authoritative recipe-management implementation.
Migration `032_recipe_management.sql` adds:

- `ingredients` — a stable ingredient master with category, default unit,
  preferred vendor/source, active state, and notes;
- `recipe_ingredients` — structured Recipe composition rows with Ingredient,
  amount, unit, optional per-Recipe vendor/source, sort order, active state, and
  notes;
- `mp_recipe_admin_save(...)` — create/update Recipe metadata while leaving the
  imported `recipes.ingredients` text untouched as legacy reference;
- `mp_ingredient_admin_save(...)` — create/update the Ingredient master;
- `mp_recipe_ingredient_admin_save(...)` — create/update structured Recipe
  Ingredient rows;
- `mp_item_recipe_component_admin_save(...)` — maintain existing
  `item_recipe_components` with the single-recipe versus multi-recipe rules
  established under #68.

`item_recipe_components` remains the allowed/default Item component-plan source.
`lot_recipe_components` remains actual production history and is exposed
read-only by the Recipes - Manage page; it is not modified by Recipe
administration.

For incremental production deployment, import `032_recipe_management.sql` after
`031_remove_legacy_public_links.sql`, then run
`tests/032_recipe_management_smoke.sql` before importing the updated Appsmith
application.

### Recipe document model (`033_recipe_document_model.sql`)

Issue #79 extends the PostgreSQL-first recipe definition so complete human-readable production instructions can eventually be rendered from database content rather than maintained only in an external document.

The model adds `recipes.description` and `recipes.batch_yield_text`, extends `recipe_ingredients` with quantity ranges/display text, alternative groups, optional/nested composition support, and adds ordered `recipe_steps` grouped by section. These are recipe-definition fields only; actual production history remains in `lot_recipe_components`.

### Recipe administration document-field wiring (`034_recipe_admin_document_wiring.sql`)

Issue #79 migration `034_recipe_admin_document_wiring.sql` completes the canonical write path for the document-oriented structured Recipe Ingredient fields introduced by migration 033. `mp_recipe_ingredient_document_admin_save(...)` writes numeric/ranged quantities, display quantity text, vendor/source, alternative groups, nested parent ingredients, optional state, ordering, active state, and notes while enforcing same-Recipe parent relationships.

The Recipes - Manage Appsmith page uses migration 033's `mp_recipe_document_metadata_save(...)` and `mp_recipe_step_admin_save(...)` functions for Recipe description/batch-yield metadata and ordered Recipe instruction steps. Parameter-dependent Appsmith reads are manual-only and use prepared-statement-safe nullable numeric bindings so an unselected Recipe or Item does not send the literal string `NULL` to a PostgreSQL `bigint` parameter.

For incremental production deployment, import `034_recipe_admin_document_wiring.sql` after migrations 032 and 033, then run `tests/034_recipe_admin_document_wiring_smoke.sql` before importing the corresponding Appsmith JSON.
