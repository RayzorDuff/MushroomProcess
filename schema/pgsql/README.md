# MushroomProcess PostgreSQL installation and schema

## Fresh installation without operational data

Start the MushroomProcess PostgreSQL service and use an empty database. The
installation role must be able to create the `pgcrypto` extension. The commands
below use the database and role configured on the isolated RootedOps container.
They stream the SQL files into the container, so the database port can stay private.
Run from the MushroomProcess checkout on the RootedOps host.

```bash
deployment="$HOME/RootedOps/.test-deployment"
core=(sudo docker compose --env-file "$deployment/.env" -f "$deployment/core.yml")
(
  set -euo pipefail
  cd schema/pgsql
  tar -cf - -- 0*.sql 124_operator_identity_backfill_and_review_integration.sql
) | "${core[@]}" exec -T mushroomprocess-bridge-postgres bash -c '
  set -euo pipefail
  export LC_ALL=C
  dir=$(mktemp -d)
  trap "rm -rf -- \"$dir\"" EXIT
  tar -xf - -C "$dir"
  psql_cmd=(psql -X -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB")
  existing=$("${psql_cmd[@]}" -Atc "SELECT to_regclass(\$\$public.lots\$\$) IS NOT NULL")
  [[ "$existing" == f ]] || { echo "MushroomProcess is already initialized" >&2; exit 1; }
  for file in "$dir"/0*.sql; do
    [[ "$file" == */022_personnel_reviews_seeds.sql ]] && continue
    "${psql_cmd[@]}" -f "$file"
  done
  "${psql_cmd[@]}" -f "$dir/124_operator_identity_backfill_and_review_integration.sql"
'
```

For a standalone PostgreSQL installation, connect `psql` to the empty database
and run the same files with `-X -v ON_ERROR_STOP=1 -f`. Use `-f` so the `\ir` in
`051_extraction_batch_provenance.sql` resolves relative to that file. The `124_*`
patch installs the personnel review integration. If a file fails, inspect the
first error and use a new empty database to retry the sequence.

Create an initial operator for the actual Appsmith test account
and add synthetic inventory lookups as needed. The
[PostgreSQL CI workflow](../../.github/workflows/commerce-postgres.yml) shows
how to run synthetic smoke tests on a disposable `commerce_test` database.

### Inventory reconciliation (#78)

- `024_inventory_reconciliation.sql` provides transactional Product location reconciliation.
- `025_inventory_reconciliation_lots.sql` adds the equivalent Lot path using `mp_lot_set_location(...)`.
- The Appsmith Inventory - Reconcile page submits Product and Lot reconciliation calls in one PostgreSQL statement so a failure in either scope rolls back the complete physical-location reconciliation.

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

### PostgreSQL-native compatibility views (`035_native_postgres_views.sql`)

Migration `035_native_postgres_views.sql` establishes the `v_` / `vc_` interface
for tables created after the Airtable migration boundary: `ingredients`,
`recipe_ingredients`, `recipe_steps`, and `qr_scan_log`. It also extends the
existing `v_recipes` / `vc_recipes` contract with the `description` and
`batch_yield_text` fields added by migration 033.

These definitions intentionally live in a normal numbered migration rather than
being folded back into `003_views.sql` / `004_computed_views.sql`; those files are
retained historical output from the deprecated Airtable schema generator.
`vc_recipe_ingredients` and `vc_recipe_steps` add useful display identifiers for
administration/reporting. `vc_qr_scan_log` deliberately remains a passthrough so
historical scan-time snapshots are not replaced by current inventory state.

### Canonical lot lifecycle reporting (`036_reporting_lifecycle.sql`)

Issue #87 Phase 2 introduces `v_reporting_lot_lifecycle`, the read-only
one-row-per-lot reporting contract used by the rebuilt Reporting interface.
The view intentionally combines direct lifecycle columns with dated Events so
Airtable-migrated history and PostgreSQL-native records use the same interface.
Direct fields remain canonical when both sources exist; the view retains the
event timestamp, provenance source, mismatch flag, and source-quality flags
instead of silently replacing conflicting history.

The view also exposes Harvest-event flush/yield aggregates and exact grain /
substrate input relationship arrays. `mp_reporting_try_jsonb(text)` and
`mp_reporting_try_numeric(text)` are defensive read-only helpers used to avoid
legacy malformed/blank event metadata turning a Reporting query into a page
failure.

For incremental production deployment, import `036_reporting_lifecycle.sql`
after the existing schema/function migrations, then run
`tests/036_reporting_lifecycle_smoke.sql`. Phase 2 does not change the Appsmith
Reporting page; Phase 3 will switch the Lifecycle Trace UI only after the view
is validated against the live database.

### Reporting lineage (`037_reporting_lineage.sql`)

Issue #87 Phase 4 adds `v_reporting_lot_lineage`, a read-only adjacent-lineage view rooted at each lot. It exposes explicit upstream/downstream grain, substrate, source/parent lot relationships and resulting products. It does not infer lineage from matching item/strain/date values.


### Canonical cohort reporting (`038_reporting_cohort.sql`)

Issue #87 Phase 5 adds `v_reporting_cohort_lifecycle`,
`v_reporting_cohort_dimension_options`, `mp_reporting_cohort_basis_at(...)`, and
`mp_reporting_cohort(...)`.  The cohort fact view reuses the Phase 2 lifecycle
contract and adds exact grain/substrate relationship dimensions, input-age-at-
spawn measures, outcome flags, and cohort quality flags.

`mp_reporting_cohort(...)` is the required population boundary for later Cohort
Analytics queries.  It applies one shared optional date-basis/range, category,
item, strain, grain, substrate, recipe, regulation, and data-origin contract.
Grain/substrate filtering uses exact individual relationship values rather than
scalar matching against PostgreSQL array renderings.

For incremental production deployment, import `038_reporting_cohort.sql` after
`036_reporting_lifecycle.sql` (and normally after `037_reporting_lineage.sql` in
repository order), then run `tests/038_reporting_cohort_smoke.sql`.  Phase 5 does
not change the Appsmith Cohort Analytics widgets; Phase 6 will rebind them to the
canonical cohort function.

### Reporting inventory layer (Issue #87 Phase 7)

`039_reporting_inventory.sql` adds the canonical read-only inventory reporting objects:

- `v_reporting_product_inventory` — one row per Product with the Products-page active/terminal rule centralized, resolved item/strain/location dimensions, and quality flags;
- `mp_reporting_inventory_expiration_status(...)` — deterministic expired/expiring/current/unknown classification for an explicit as-of date and horizon;
- `mp_reporting_product_inventory(...)` — exact current/as-of Product inventory filtering including Active/Terminal/All scope and the explicit Unknown-location bucket;
- `v_reporting_lot_inventory` — current in-process lot inventory derived from the canonical lifecycle view and grouped into operational stages.

The Phase 7 Reporting UI uses these objects instead of duplicating terminal-state/location logic in Appsmith.

### Provider-neutral payment identity (`041_payment_provider_neutral.sql`)

Issue #85 R1 adds the additive payment/reconciliation aliases used to migrate
Fulfillment away from Clover-specific storage without changing current Clover
behavior. `payment_processor`, `processor_payment_id`,
`processor_payment_status`, `processor_payment_amount`,
`processor_payment_time`, `processor_match_confidence`, and
`payment_reconciliation_status` coexist with the legacy `clover_*` columns.

A compatibility trigger infers `payment_processor = 'clover'` only when actual
Clover reconciliation evidence exists and mirrors Clover legacy writes to the
generic aliases. Generic writes for a row explicitly identified as Clover are
also mirrored back to the legacy fields so current workflows/readers remain
usable during the migration. A row explicitly identified as another processor,
such as `moov`, is never projected into the Clover columns.

For incremental production deployment, import
`041_payment_provider_neutral.sql` after the currently deployed numbered
migrations, then run `tests/041_payment_provider_neutral_smoke.sql`. R1 changes
only the database compatibility contract; Appsmith and n8n continue using the
existing Clover fields until a later #85 round moves those reads/writes to the
provider-neutral aliases.

### `042_product_return_to_lot.sql` / `043_product_return_lineage.sql` — Product return foundation (#57)

Issue #57 is implemented in two application phases.  The first database phase adds the audit-safe transition used by the later Appsmith workflows:

- `lots.source_product_id` is the canonical Product -> returned-Lot edge, with a retained derived single-record junction for NocoDB compatibility;
- `mp_product_cultivation_eligibility(...)` limits returnable inventory to structurally eligible grain, substrate, and LC-syringe Products and rejects ordered, terminal/unavailable, ambiguous-lineage, or already-returned Products; expiration visibility is handled separately by the contextual UI;
- `mp_product_return_to_lot(...)` creates a new Lot rather than reopening an old consumed Lot, preserves the earliest Product/origin expiration, volume/weight, strain/vendor metadata, sterilization/recipe-component provenance, moves the Product to `Consumed`, and records a linked audit event;
- label creation is explicit and defaults to none so contextual operations can avoid unnecessary intermediate labels; and
- `043_product_return_lineage.sql` extends `v_reporting_lot_lineage` so reporting can traverse the explicit `Lot -> Product -> returned Lot` chain in both directions.

For an incremental production deployment, import `042_product_return_to_lot.sql` and then `043_product_return_lineage.sql`; run `tests/042_product_return_to_lot_smoke.sql` before the Phase 2 Appsmith workflow is enabled.

### `044_product_cultivation_context.sql` — contextual Product cultivation (#57 Phase 2)

`044_product_cultivation_context.sql` exposes eligible packaged cultivation inventory through
`v_product_cultivation_candidates` and adds atomic wrappers for the user-facing Inoculate and
Spawn-to-Bulk workflows. The wrappers convert an eligible Product back to a new Lot and perform
the cultivation operation in the same database call, so a downstream validation failure cannot
leave a Product deproductized by itself.

The Appsmith **Show Eligible Products** option is available on Lots, Lab - Inoculate, and Lab -
Spawn to Bulk. Packaged grain may be an inoculation target, LC syringes may be inoculation sources,
and packaged substrate may be a Spawn-to-Bulk substrate. Other Product categories remain hidden.

Label behavior is contextual: grain receives the normal inoculated-grain label; substrate receives
no intermediate return label because the Spawn-to-Bulk output gets the normal `Bulk_Created` label;
a fully depleted LC syringe gets no replacement label; and a partially used LC syringe gets one
replacement LC Lot label for its remaining volume. Product/origin expiration is preserved and may
only shorten, never extend, the downstream lifecycle date.

For an incremental production deployment, import `044_product_cultivation_context.sql`, run
`tests/044_product_cultivation_context_smoke.sql`, and run
`node appsmith/product_cultivation_return_smoke.js` before importing the updated Appsmith export.

### `045_product_cultivation_phase2_corrections.sql` — Product cultivation corrections (#57)

This follow-up corrects three findings from the initial Phase 2 deployment:

- cultivation Product expiration uses the Colorado operating calendar date instead of the PostgreSQL host's UTC `CURRENT_DATE`, preventing a Product from disappearing several hours early at UTC midnight;
- `v_product_cultivation_candidates.lot_id` now exposes the Product's existing `PROD-*` identifier directly, without an extra `PRODUCT · ` prefix; and
- Product-return/Inoculate/Spawn-to-Bulk wrappers derive `now()` in the same operating timezone used by candidate visibility.

The timezone rule is centralized in `mp_cultivation_operating_date()` so it can later be sourced from the planned Settings table without changing every cultivation query.

For incremental production deployment, import `045_product_cultivation_phase2_corrections.sql`, run `tests/045_product_cultivation_phase2_corrections_smoke.sql`, and then import the paired Appsmith correction. `qSpawnToBulkLocations` is already an automatic/on-load query; the Appsmith correction removes manual `.run()` calls from `LotsSpawnToBulk` to avoid mixing trigger and data dependencies on the same query.


### `046_expired_product_cultivation_opt_in.sql` — expired Product cultivation opt-in (#57)

Issue #57 now distinguishes expiration from structural unavailability. A Product whose use-by date
has passed can still be returned to cultivation when the operator explicitly enables **Show Expired
Products**. The default remains conservative: **Show Eligible Products** excludes expired rows until
the second checkbox is enabled.

`v_product_cultivation_candidates` now includes structurally eligible current and expired Products
and exposes `is_expired`. The eligibility contract no longer treats the use-by date, or an `Expired`
storage/lifecycle marker by itself, as terminal. Order-linked, shipped, consumed, retired, composted,
missing, already-returned, inoculated grain/substrate, and other invalid Products remain excluded.

For incremental deployment, import `046_expired_product_cultivation_opt_in.sql`, run
`tests/046_expired_product_cultivation_opt_in_smoke.sql`, and then import the paired Appsmith export.
