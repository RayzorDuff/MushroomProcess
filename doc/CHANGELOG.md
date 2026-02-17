## [v1.0.7-beta] - 2026-02-17

_This release advances the NocoDB/Postgres migration by introducing the first **Appsmith interface** operating against a **Postgres database** (exposed through NocoDB). It also tightens schema parity, adds helper SQL for core workflows, and improves lot lifecycle/event logging._

---

## Appsmith + Postgres (via NocoDB)

- **Initial Appsmith “Lot-centric UI” running against the imported Postgres database**, accessible through NocoDB.
  - Includes working Sterilizer interfaces (**Sterilizer – In**, **Sterilizer – Out**) and a **Lots** page for viewing/filtering by major identifiers.
  - Added Appsmith app export (`nocodb_interfaces/MushroomProcess.json`) plus formatting tooling (`pretty-json.mjs`).
- Documentation added/updated for the Appsmith approach and current coverage (`doc/Appsmith-Lot-Centric-UI.md`, `nocodb_interfaces/README.md`, and related interface notes).

---

## Postgres helper SQL for migrated workflows

- Added helper SQL modules/scripts to support the Postgres-backed workflow:
  - print queue helpers,
  - event insertion + linking helpers,
  - sterilizer helpers,
  - lot-action helpers (shake/retire).
- Updated Appsmith SQL queries to call the new Postgres functions for Sterilizer Out and lot filtering.

---

## Lot lifecycle: shake/retire event integrity

- Added/updated helper functions for lot lifecycle actions:
  - shake + retire now log events consistently,
  - retirement now sets/updates `retired_at`,
  - shake/retire functions return the number of lots affected (useful for UI feedback).
- Improved event creation so lot event links are created reliably by using a wrapper (`mp_events_insert_and_link_lot`) when inserting events.

---

## Schema updates & parity improvements

- Added `retired_at` timestamp to both Airtable and NocoDB schema exports.
- Added additional “prefers-single” FK columns for 1:1 links while **retaining `_m2m_` tables** for compatibility/auditing.
  - Added deterministic naming and deferred constraints/index creation to eliminate identifier truncation notices during import.
  - Added clear banner comments in `002_links.sql` indicating whether an `_m2m_` table is DERIVED (canonical FK exists) vs a true many-to-many.
- Removed redundant `lots.spawned_date`.
- Added `recipes.active` and updated interface queries to include only active recipes.

---

## Print queue correctness

- Ensured the `run_id` FK is populated correctly during print queue creation and aligned print-queue fields between Airtable and Postgres.

---

## Misc / Documentation

- Updated import documentation (`doc/Airtable-Postgres-NocoDB-Import.md`) and refreshed schema exports (`_schema.json`, `tables_dump.json`, recipes/locations exports).

## [v1.0.6-beta] - 2026-02-01

_This release includes production-branch updates since `v1.0.5-beta`. The focus is on making the NocoDB/Postgres migration path reliable (schema + data import), improving computed-field translation (lookups/rollups/formulas), and updating automations/interfaces to match the latest workflow expectations._

---

## NocoDB / Postgres migration (schema + data)

- Added a full **Airtable-export → Postgres SQL** pipeline, including a large new exporter (`airtable_export_to_postgres_sql.js`) and supporting tooling to generate/import SQL and CSV cleanly.
- Reorganized and expanded the NocoDB migration outputs into a dedicated `nocodb_schema/` structure (including `pgsql/` scripts, generated schema artifacts, and CSV exports).
- Added support for importing into **external DB sources in NocoDB** (source-scoped meta endpoints), improving compatibility with setups where NocoDB is attached to a Postgres database.
- Improved CSV load behavior:
  - fixed `psql \copy` filename handling (requires literal filename tokens),
  - removed incorrect path handling (load CSVs relative to CWD; removed basedir assumptions),
  - fixed link export so relational CSVs import correctly.

---

## Computed field translation: lookups, rollups, and formulas

A major set of fixes to ensure computed views import successfully and behave correctly in Postgres/NocoDB:

- Formalized the lookup/rollup compiler and prevented cycles:
  - removed lots→products lookups that created cycles; kept the direction products→lots.
- Fixed missing/invalid SQL generation cases:
  - fixed missing FROM-clause issues,
  - fixed runaway SQL generation paths,
  - ensured `OR()` / `AND()` compilation preserves operators correctly.
- Improved type correctness and array/scalar behavior:
  - cast `array_agg(...)` expressions to concrete scalar types where needed,
  - fixed comparisons of arrays vs scalars,
  - detected mixed scalar/array results in `IF()` / `SWITCH()` and handled them safely,
  - only scalarize when the referenced column is known to be an array,
  - auto-coerce known lookup/rollup array refs when adjacent to `||`,
  - fixed scalar datetime functions emitted with incorrect raw casts.
- Fixed Postgres null-concat behavior that caused IDs to disappear:
  - addressed `||` + `NULL` ⇒ `NULL` situations (e.g., `lot_id` becoming null if `airtable_id` is null), which led to empty-looking fields in NocoDB.
- Added “two-pass” behavior by inlining dependent formulas:
  - when a formula references another formula field in the same table, the generator now inlines referenced SQL (or generates a two-pass select strategy).
- Improved self-link handling:
  - repaired links to the same table,
  - fixed same-table junction naming and alias uniqueness in generated views,
  - for self-link lookups targeting non-physical computed fields, the generator now emits safe empty arrays with TODO markers rather than invalid SQL.
- Added/adjusted schema to reduce reliance on self-link lookups:
  - introduced `vendor_name_mat` and `strain_species_strain_mat` to replace lookups against `lots.target_lot_ids` self-links and retire brittle lookup paths.

---

## Schema / import reliability fixes

- Updated schema to the latest production state and iterated on computed-view generation until **all `.sql` files import successfully**.
- Added and processed `tables_dump.json` from Airtable-export for richer import context; improved how the generator locates and uses it.
- Introduced import-time column ordering changes to match NocoDB expectations:
  - place migration-specific columns at the end,
  - ensure Airtable “primary” columns immediately follow `nocopk` so NocoDB chooses the intended display value.
- Fixed “regclass” import errors and addressed internal “leakage” issues discovered during Postgres import testing.

---

## Automations & workflow behavior

- Removed dependence on Airtable “views” for automation selection and added support for **multiple instances** (better suited to multi-site / multi-printer deployments).
- Updated multiple Airtable automations and interface specs to reflect current workflows (Dark Room, Fruit, Inoculate, Pour Plates, Spawn-to-Bulk, etc.).
- Dark Room workflow fix:
  - **Fixes #11**: allow transitions to `invalid` states in Dark Room when needed.

---

## Interfaces: Appsmith + Retool updates

- Added **Appsmith** interface definitions and updated NocoDB interface documentation/strategy (including an N8N automation strategy doc).
- Updated Airtable and NocoDB interface definitions and refreshed interface/automation screenshots to reflect current project state.

---

## Print daemon: multi-instance readiness

- Updated schema and related logic for an **instance-aware print daemon**, supporting multiple daemon instances/printers without relying on Airtable views.

---

## Ecwid integration quality-of-life

- Added a PowerShell sync loop to run periodic sync (e.g., every 15 minutes), and minor supporting documentation updates.

---

## [v1.0.5-beta]

_This release includes production-branch fixes and refinements since `v1.0.4-beta`, with a focus on stability, data integrity, and correctness across automations and inventory workflows. Issues #6, #7, and #8 are resolved in this release._

---

## Automation Correctness & Data Integrity

- **Issue #6 – Storage location consistency on tray emptying (resolved).**  
  When trays are emptied, automations now correctly update **both**:
  - `products.tray_state` → `empty_tray`
  - `products.storage_location` → `Consumed`  
  This ensures downstream inventory logic, reporting, and ecommerce sync accurately reflect consumed product state.

- **Issue #7 – Robust handling of linked fields during automation updates (resolved).**  
  Fixed cases where automations attempted to write single-select or scalar values into **linked-record fields**, resulting in Airtable API errors.  
  Link updates are now:
  - properly resolved to record IDs,
  - skipped or defaulted safely when targets are missing,
  - logged clearly when corrective action is required.

- **Issue #8 – Default storage location enforcement (resolved).**  
  Automations now guarantee that newly created or updated products always have a valid `storage_location`.  
  If unset or invalid, the location is automatically defaulted to **“Products Storage”**, preventing orphaned inventory records and downstream sync issues.

---

## Inventory & Workflow Improvements

- Improved tray-lifecycle automation logic so product state transitions (filled → fruiting → harvested → empty) are handled deterministically and idempotently.
- Reduced edge cases where partial automation runs could leave products in ambiguous states.
- Improved guard-clauses and validation around automation inputs to avoid silent failures.

---

## Error Handling & Logging

- Added clearer error messages and logging paths when automations encounter:
  - missing linked records,
  - invalid field values,
  - unexpected schema mismatches.
- Improved resilience of long-running automations by ensuring recoverable failures do not halt batch execution.

---

## Schema & Documentation Alignment

- Minor documentation updates to reflect corrected automation behavior and resolved edge cases.
- Ensured automation assumptions remain aligned with the current Airtable schema (no reliance on deprecated fields).

---

## Summary

`v1.0.5-beta` is a **production-stability release** that:

- Resolves **Issues #6, #7, and #8**
- Fixes incorrect handling of linked-record fields
- Enforces consistent storage-location state
- Improves automation resilience and correctness
- Reduces the risk of inventory drift and API errors

This release is recommended for all production deployments prior to further feature expansion.

## [v1.0.4-beta]

_This release includes updates from both the `nocodb_migration` branch and recent fixes on the `production` branch. It continues the migration work toward full NocoDB compatibility while refining Airtable automations, Ecwid sync logic, and schema tooling._

---

## NocoDB Schema Migration & Postgres Compatibility

- Replaced the prior two-step NocoDB creation process with a **single unified migration script** (`create_nocodb_schema_full.js`) that:
  - creates all tables,
  - establishes relationships,
  - creates lookups, rollups, and formulas,
  - logs remaining manual steps.
- Updated Airtable-schema documentation to reflect the new **one-pass migration workflow** and added guidance for comparing Airtable `_schema.json` to the NocoDB-generated schema.
- Improved Postgres compatibility across migration scripts, resolving issues found during full-schema imports into a Postgres-backed NocoDB instance.
- Added support for NocoDB’s **v2 meta API** (alongside v3). Link-field creation can now route through v2 to avoid v3-related link bugs.
- Extended schema mapping rules:
  - standardized display fields and primary key selection,
  - enforced safe PK handling when formulas live in the primary key column,
  - improved inference of NocoDB `uidt` → SQL types.
- Added detection and safe fallback handling for NocoDB limitations:
  - rollups cannot aggregate other rollups/lookups,
  - lookups cannot target rollup fields across tables.

---

## Primary Keys, UUIDs, and System Timestamps

- Introduced consistent handling for **synthetic PKs and UUID columns** (`nocopk`, `nocouuid`) when Airtable tables lack suitable primary keys.
- Implemented correct Postgres defaults for UUIDs (`gen_random_uuid()`), plus a helper script to **repair columns** where the API failed to apply the default.
- Added explicit mapping of `CREATED_TIME()` formulas from Airtable to NocoDB’s **system-managed `CreatedAt`**, including translation of  
  `DATETIME_FORMAT(CREATED_TIME(), 'YYMMDD')`  
  into  
  `RIGHT(YEAR(NOW()),2) + MONTH(NOW()) + DAY(NOW())`.

---

## Relationship & Link Field Improvements

- Cleaned up and renamed NocoDB-generated inverse link fields to better match the Airtable schema, reducing drift.
- Improved formula cleanup when formulas appear in primary key columns, ensuring validity under NocoDB evaluation rules.
- Reintroduced the example `create_airtable_from_schema` helper script for round-tripping schema creation in Airtable.
- Removed deprecated fields such as `lots.create_lots` from schema exports and NocoDB builders.

---

## NocoDB Automations (Parity with Airtable)

- Expanded `nocodb_automation/README.md` with:
  - webhook configuration instructions,
  - API-version guidance,
  - detailed environment variable documentation,
  - stricter validation options and logging controls (`LOG_AUTOMATION`, `STRICT_VALIDATION`).
- Ensured support for all recent Airtable automation improvements:
  - untracked-source inoculation,
  - multi-target inoculation,
  - Fully-Colonized event consistency logic,
  - improved syringe labeling workflows.

---

## Interfaces & Retool (NocoDB Path)

- Updated `nocodb_interfaces` documentation with instructions for generating views that correspond to Airtable Interfaces.
- Added guidance for building equivalent Retool apps for:
  - inoculation,
  - sterilization runs,
  - spawn-to-bulk workflows,
  - harvesting and packaging,
  - dark room management.
- Added notes on regenerating interfaces directly from a fresh Airtable schema export or reconstructing them entirely in NocoDB/Retool.

---

# Production Branch Fixes Included in This Release

These changes were made on `production` after `v1.0.3-beta` and are incorporated into `v1.0.4-beta`.

## Airtable Automations — LC Syringes & Labeling

- **Single-syringe receiving flow:**  
  `lc_receive_syringe` now processes *exactly one* syringe per run using a staging lot, removing the older `receive_count` logic entirely.
- Added **automatic label printing** for received syringes by populating `print_queue`.
- Updated related automations (`print_queue_populator.js`, `dark_room_actions.js`) to support labeling and simplify Fully-Colonized event patterns.

---

## Ecwid Sync Refinements

- Inventory sync now excludes items in the following locations:
  - **Shipped**
  - **Expired**
  - **Consumed**
- Prevents outdated or unavailable inventory from being listed in Ecwid.
- Updated logic in both `ecommerce_refresh.js` and `populate_ecommerce_products_lots.js`.

---

## Sterilizer Automation Cleanup

- Removed references to the deprecated `create_lots` flag in  
  `sterilizer_out_validate_create_lots.js` to match the updated schema.

---

## Documentation & Developer Experience

- Reintroduced and expanded tooling for rebuilding Airtable from schema JSON.
- Updated top-level README and Airtable schema README with clearer installation and usage notes (including Windows-specific steps).
- General cleanup and consistency fixes applied across schema tools and automations.

---

## Summary

`v1.0.4-beta` is a major step forward in the NocoDB migration effort, delivering:

- A unified NocoDB schema generation workflow  
- Improved Postgres support  
- Better PK/UUID handling  
- More robust timestamp and formula translation  
- Updated automations and labeling workflows  
- Safer Ecwid sync behavior  
- Cleaner schema and documentation  

This release strengthens cross-backend support while keeping Airtable fully functional.


## [v1.0.3-beta] – 2025-12-04 (nocodb_migration)

> This release is cut from the `nocodb_migration` branch and adds an experimental **NocoDB path** alongside the existing Airtable flows. Airtable behavior remains effectively the same as v1.0.2-beta; the new work is focused on schema migration, NocoDB automations, and interface generation.

### NocoDB schema & migration tooling

- **Generalized schema JSON** so a single exported `_schema.json` from `airtable-export` can be used to recreate **either**:
  - a clean Airtable base, or  
  - a NocoDB project with matching tables and fields.
- Added an **initial script to create a NocoDB project from an Airtable `_schema.json` export**, wiring up tables and columns based on Airtable metadata. 
- Introduced a **two-pass column creation flow** for NocoDB:
  - first pass creates “simple” columns;  
  - second pass adds relationships and more complex fields;  
  - with **fallback link-column creation** when metadata is incomplete.
- Implemented **automatic relationship table creation** that respects Airtable’s **many-to-many, one-to-many, and one-to-one** link patterns during NocoDB link creation.
- Added a script to **generate SQL DDL from `_schema.json`** plus documentation for how to apply the generated SQL in a NocoDB-backed database. 
- Tightened mapping to NocoDB’s internal types:
  - use **valid NocoDB `uidt` values**;  
  - allow NocoDB to infer `dt` / `dtx` from `uidt` instead of forcing them;  
  - skip `LinkToAnotherRecord` fields in the basic mapper where appropriate.
- Fixed an **“undefined dt”** error path by requiring primary keys on tables before certain migration steps run.

### NocoDB meta-API support & robustness

- Added support for **both NocoDB v2 and v3 meta APIs**, selectable via an **environment variable**, so you can switch between API versions while working around v3 issues.
- Iterated on the v3 field-creation flow to track and work around an internal NocoDB bug (“Cannot read …” when creating certain `LinkToAnotherRecord` fields). 
- Added **retry logic for formula creation**:
  - formulas are applied *after* links and lookups have been created;  
  - failed formulas are retried, then surfaced in a manual-steps report.
- Improved handling of **Airtable-style inverse link fields** that already contain data, avoiding destructive updates while creating NocoDB relationships. 
- New tooling to **dump a NocoDB schema to JSON** and **compare it to the Airtable `_schema.json`**, making it easier to verify that migration output matches the source base. 

### NocoDB automations

- Added an initial **`nocodb_automation/`** package with Node.js handlers that mirror the core Airtable automations (sterilizer, inoculation, spawn to bulk, harvest, packaging, etc.) but talk to NocoDB via its REST API. 
- Brought over the **multi-target inoculation** workflow so you can inoculate multiple targets from a single source in the NocoDB path, matching the behavior already available on Airtable. 
- Ensured that automations remain compatible with existing changes such as:
  - inoculation from untracked sources;  
  - `lc_volume_ml` / `target_lot_ids` reset on the source lot;  
  - Fully-Colonized event history for items moved to Fridge, ColdShock, and Fruiting. 

### NocoDB interfaces & Retool

- Introduced **`nocodb_interfaces/`** containing:
  - scripts to create NocoDB views that approximate the Airtable Interfaces, and  
  - **Retool how-to documentation** for each interface. 
- Added detailed **interface descriptions** focused on NocoDB/Retool, with enough information to:
  - recreate Interfaces on a fresh Airtable base, or  
  - drive equivalent NocoDB views / Retool apps. 
- Updated the **top-level README** to clearly describe the dual path:
  - Airtable schema + automations + interfaces, and  
  - NocoDB schema generation, automations, and interfaces / Retool guidance. 
- Added a dedicated **README for `nocodb_interfaces/`** describing the new scripts and their usage (creation of views, Retool glue, and assumptions about the schema).

### Print daemon: NocoDB support

- Extended the **print daemon** so it can **poll NocoDB** in addition to Airtable, still targeting 4×2 thermal labels (e.g., JADENS JD268BT-CA). 
- Kept existing behavior for Airtable intact while wiring in NocoDB connection details via environment variables.

### Documentation & housekeeping

- **Top-level README** rewritten for **combined Airtable/NocoDB support**, including updated repository layout and “how the system hangs together” with both backends. 
- Added / updated READMEs for the new `nocodb_automation` and `nocodb_interfaces` directories with setup and usage notes. 
- Cleaned up INSTALL / README duplication in the root and subdirectories, ensuring Airtable-specific instructions live with the Airtable tooling and NocoDB setup is described alongside the migration scripts. 
- Added extra logging (including timestamps) in migration / casing scripts to make troubleshooting NocoDB migrations easier. 

## [v1.0.2-beta]

* Inoculation workflow:
  * Replace `inoculate.js` with `inoculate_multiple.js` and update the inoculation interface to support inoculating multiple target lots from a single source lot.
  * Add support for inoculation from untracked sources, including better notes/metadata on the source lot.
  * After a batch run, automatically clear `lc_volume_ml` and `target_lot_ids` on the source lot so the interface starts clean for the next inoculation.

* Dark room & event history:
  * Ensure a `FullyColonized` event exists for any lot moved to **Fridge**, **ColdShock**, or **StartFruiting`** via `dark_room_actions.js`, improving downstream event history integrity.

* Ecwid ? Airtable ecommerce integration:
  * Add initial Ecwid integration scripts to keep Ecwid product counts aligned with Airtable inventory.
  * Introduce a shared `lib/ecwid_airtable.js` module for common Ecwid/Airtable API helpers.
  * Implement sync flows to:
    * Populate `ecommerce.products` and `ecommerce.lots` link fields from `products` / `lots`.
    * Maintain an `ecommerce_orders` table mirrored from Ecwid orders.
    * Link `ecommerce_orders` records back to `ecommerce` rows using Ecwid SKUs and related fields.
  * Expand `integrations/ecwid/README.md` and `.env.example` with full configuration, schema requirements, and workflow documentation.
  * Rename sample environment files to `.env.example` in both the Ecwid integration and the print daemon.

* Schema & documentation:
  * Refresh Airtable schema exports to include `ecommerce` and `ecommerce_orders` tables and updated field definitions.
  * Update `FIELD_MAP.md` to reflect the latest schema, including ecommerce-specific fields.

## [v1.0.1-beta]

* Applied GPL licensing
* Updates to logic for bulk sizes in spawn_to_bulk
* Add product creation script
* Add more detailed interface documentation including beginnings of NocoDB and Retool migration information.

## [v1.0.0-beta]

* Database schema running on a production server.
* Untested method for importing schema to a new server.
* Tested automation scripts.
* Example interface screenshots.
* Install documentation.

## [v0.0.1-alpha]

* Initial Release