## v1.0.4-beta

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