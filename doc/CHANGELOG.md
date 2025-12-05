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