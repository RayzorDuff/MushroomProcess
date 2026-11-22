Warning: truncated output (original token count: 20398)
Total output lines: 1602

## v1.2.2 - 2026-11-21

- Reuse the shared physical inventory specification for Woo Product/Lot picking and shipment acknowledgments, including generic items sold through legacy listings.
- Add an explicit, reversible publication-owner handoff for the reviewed Woo cutover. Installing the migration does not activate or transfer inventory.
- Preserve the deployed Ecwid baseline, stock receipts and native fulfillment while the Woo stack remains in draft.

## v1.2.1 - 2026-11-21

- Correct Ecwid inventory through explicit legacy/canonical size and recipe specifications, shared reservations and a single publication owner per pool.
- Preserve ecommerce/external IDs and the existing Ecwid fulfillment interface. Coordinate all three inventory queries without requiring the Woo migrations.
- Add durable Ecwid stock-delta receipts, fresh order reconciliation and guarded first-publication tooling, a rollback-only preview, and scoped function rollback.
- Keep quantity changes subject to current hosted review. November 21 export counts are historical review candidates.

## v1.2.0 - 2026-08-13

_This coordinated release records the stable MushroomProcess baseline before the planned ERPNext-centered purchasing/inventory and provider-neutral commerce transition. It also marks the documented point at which the supported Appsmith/PostgreSQL application intentionally extends beyond the final Airtable reference._

### Added

- Categorized Appsmith navigation with a canonical navigation manifest and synchronization utility.
- Database-backed recipe management, ingredient/instruction editing, and printable recipe previews.
- Product and Lot inventory reconciliation by location, including QR-assisted entry.
- Stable Product and Lot QR URLs, resolver routing, regulated/internal destinations, deep linking, and scan analytics.
- Provider-neutral commerce metadata and PostgreSQL Ecwid catalog synchronization.
- Historical-data audit contracts, canonical lot lifecycle views, adjacent lineage, cohort analytics, and inventory snapshot reporting.
- Spawn to Bulk date override support.

### Changed

- Disabled the expanding native Appsmith navigation in favor of the categorized application navigation.
- Established Appsmith/PostgreSQL reporting as the maintained operational reporting surface.
- Retained Ecwid synchronization as a transition bridge; this release does not implement the planned ERPNext commerce authority or removal of Ecwid/Clover.

### Fixed

- Hardened Harvest regulation filters against initialization and refresh races.
- Hardened print-daemon queue hydration against NocoDB computed-view and record-link limitations.
- Repaired reporting chart shapes, lifecycle detail bindings, inventory-state validation, and reporting smoke-test performance.

### Coordinated baseline

- SignatureGate `v1.1.0`
- RootedOps `v1.1.0`
- BookWorks `bookworks-v3.3.0`

## v1.1.0 - 2026-08-05

_This is the first stable Appsmith/Postgres release of MushroomProcess. RC5 parity testing passed, establishing feature-complete row-by-row parity with the Airtable implementation for the tested production workflows. Changes after `V1.1.0-RC5` focus on final release stabilization, regression coverage, PostgreSQL integration completion, and repository organization._

---

## Stable Appsmith/Postgres release

- Promoted the RC5-tested Appsmith/Postgres implementation to stable `v1.1.0`.
- Completed the RC5 parity test matrix and recorded passing lifecycle, packaging, syringe, treatment, fulfillment, and print-queue coverage.
- Confirmed the Appsmith/Postgres implementation as the supported production path for the tested MushroomProcess workflows.
- Retained Airtable materials as migration/parity references while reorganizing the repository around the production Appsmith/Postgres architecture.

---

## Sterilizer stabilization

- Prevented duplicate Sterilizer IN run creation caused by repeated or concurrent Appsmith submissions.
- Restored the selected sterilizer recipe when returning to the Sterilizer IN page.
- Normalized sterilizer timestamps from Appsmith to UTC before PostgreSQL submission.
- Aligned generated lot shelf-life / use-by behavior with the Airtable implementation.
- Expanded sterilizer component and process-type regression tests.

---

## Packaging stabilization

- Corrected freeze-dried packaging so the selected package item and package class are honored by both Appsmith and PostgreSQL.
- Preserved the selected package storage location through modal state changes and submission.
- Removed the obsolete Fulfillment API dependency on `products.package_size_g`.
- Retained the RC5 behavior for:
  - independent packaging of selected lots,
  - source tray consumption,
  - use-by defaults,
  - strain and origin-lot lineage,
  - package event links,
  - regulated and non-regulated sample packages.

---

## Spawn to Bulk and recipe-component history

- Persisted output recipe-component history for lots created through Spawn to Bulk.
- Added regression coverage for:
  - component-set propagation,
  - Spawn to Bulk function contracts,
  - generated output-lot composition.
- Repaired the Spawn to Bulk substrate-lot query used by Appsmith.
- Preserved the RC5 all-in-one and recipe-component lifecycle behavior.

---

## Inoculation hardening

- Enabled valid Lab Inoculate submissions that were previously blocked by Appsmith state/validation behavior.
- Improved error reporting so the interface surfaces the specific inoculation failure returned by PostgreSQL.
- Hardened inoculation validation and atomicity:
  - validates eligible source modes and available source material,
  - prevents partial target updates when any target fails validation,
  - improves liquid and solid source-mode handling,
  - retains explicit validation errors for incompatible or unavailable sources.
- Initialized the Lots strain filter correctly.
- Added and expanded negative-path inoculation regression tests.

---

## Drawn-syringe label and vendor parity

- Preserved source vendor information on lots generated by Draw Syringes.
- Expanded drawn-syringe label regression testing.
- Accepted the product syringe `mL` capitalization used by the current product/schema conventions.
- Retained corrected title, subtitle, source-lot, strain, and selected-item label behavior from RC5.

---

## Harvest and Lab interface initialization

- Initialized the standalone Harvest workflow on page load.
- Refreshed Harvest data when the page opens.
- Reset Modify state and repaired Harvest controls after workflow completion or lot changes.
- Added and wired **Refresh Sources** and **Refresh Targets** controls on Lab and Harvest pages where source/target tables are present.
- Cleaned up refresh-button labels and page wiring.

---

## Product regulation and label formula parity

- Updated Airtable label formulas so `origin_strain_regulated` is evaluated as a numeric checkbox rollup using `SUM(values)`.
- Updated generated PostgreSQL formulas to compile checkbox rollups as numeric sums.
- Refreshed label-company, company-address, disclaimer, cottage, and company-information formula outputs.
- Added product-regulation rollup regression tests.
- Improved null-safe handling of imported lookup/rollup values used by generated labels.

---

## Import and generated-schema reliability

- Normalized Airtable lookup arrays and prefers-single-record links during PostgreSQL generation/import.
- Added generator documentation for lookup-array and single-link normalization.
- Expanded the schema-generator smoke test.
- Hardened regression coverage for:
  - imported identifiers,
  - computed views,
  - component relationships,
  - product regulation rollups,
  - print-queue view contracts.
- Refreshed generated SQL, CSV, schema, and test artifacts from the current Airtable export.

---

## PostgreSQL Ecwid order intake

- Ported the Ecwid order-updated intake workflow from Airtable to PostgreSQL.
- Added:
  - `012_ecommerce_order_upsert.sql`,
  - a PostgreSQL Ecwid order-upsert smoke test,
  - `MushroomProcess - Ecwid Order Updated - PGSQL.json`,
  - a JavaScript workflow smoke test.
- Updated PostgreSQL schema documentation for ecommerce order intake.
- Retained the PostgreSQL Fulfillment API while removing its obsolete package-size reference.
- This completes another major n8n dependency migration away from Airtable.

---

## Print daemon simplification

- Simplified print-daemon configuration and setup documentation.
- Hardened queue processing while retaining the RC5 audited Print Queue page and label-routing behavior.
- Updated `.env.example`, daemon documentation, and runtime behavior for a clearer production setup.
- Retained Mac/CUPS support, dry-run support, daemon targeting, tray routing, sample labels, and all-in-one labels.

---

## Regression and release-gate coverage

- Expanded the PostgreSQL component test runner and test documentation.
- Added or extended coverage for:
  - sterilizer process type and component mode,
  - Apply Casing parity,
  - Spawn to Bulk contracts and component propagation,
  - inoculation validation atomicity,
  - freeze-dried package negative paths,
  - drawn-syringe labels,
  - print-queue view contracts,
  - ecommerce order upsert,
  - product regulation rollups.
- Bounded the print-queue view smoke workload for predictable execution.
- Added a schema-generator smoke test to the reorganized repository.
- Updated the RC5 test matrix through final pass/cleanup and carried the validated matrix into the stable release.

---

## Repository organization

- Reorganized the repository to reflect the stable architecture:
  - moved the Appsmith export and specifications into `appsmith/`,
  - consolidated Airtable automations, interfaces, extensions, and screenshots under `airtable/`,
  - renamed `nocodb_schema/` to `schema/`,
  - moved generated PostgreSQL SQL, CSV, and tests under `schema/pgsql/`,
  - removed obsolete NocoDB automation/interface prototypes.
- Updated root and subsystem README files for the new directory structure.
- Relocated Airtable screenshots into their related automation/interface directories.
- Updated contributor and import documentation for the stable repository layout.

---

## Summary

`v1.1.0` is the stable release of the feature-complete Appsmith/Postgres implementation validated through the RC5 parity test cycle. The final delta from RC5 closes release-blocking edge cases, strengthens regression coverage, completes PostgreSQL Ecwid order intake, improves import and formula reliability, simplifies print-daemon deployment, and reorganizes the repository around the supported Appsmith/Postgres production architecture.


## [v1.1.0-RC5] - 2026-07-13

_This release is the feature-completion candidate for the Appsmith/Postgres implementation. It builds on the RC4 parity pass by adding recipe-component tracking, complete all-in-one lifecycle support, freeze-dried sample packaging and labeling, audited print-queue management, and another round of fixes across Products, Harvest, Inoculate, Fulfillment, packaging, and label generation._

---

## Release-candidate scope and validation

- Completed and halted the RC4 test matrix after identifying the remaining feature-completion work targeted by RC5.
- Refreshed the Airtable schema, generated Postgres SQL, computed views, load files, and Appsmith export for the RC5 test candidate.
- Added an RC5 release gate to the packaging smoke-test suite.
- Expanded repeatable validation coverage for:
  - sterilizer recipe-component creation,
  - all-in-one lifecycle and packaging,
  - liquid and solid inoculation source modes,
  - multi-lot packaging,
  - freeze-dried packaging,
  - drawn-syringe labels,
  - mixed harvest outputs,
  - product tray lifecycle actions,
  - print-queue actions,
  - fulfillment order visibility.
- Added a documented test procedure for validating the n8n workflows used by the Appsmith/Postgres implementation.
- Simplified the repository hierarchy for the supported UI and migration architecture:
  - moved the canonical Appsmith export and formatter to `appsmith/`,
  - retained migration-era page notes under `appsmith/spec/`,
  - removed the abandoned NocoDB REST-automation and view-generation prototypes,
  - consolidated Airtable scripts and interface references under `airtable/automation`, `airtable/extensions`, and `airtable/interfaces`,
  - consolidated the Airtable export, optional NocoDB schema snapshot, migration tools, generated PostgreSQL modules, CSVs, and tests under `schema/`.

---

## Recipe-component migration and lot composition

- Added `item_recipe_components` and `lot_recipe_components` to the Airtable schema and generated Postgres model.
- Added Airtable automation support for creating lot recipe-component rows.
- Added Sterilizer OUT component-set matching so the correct component set is selected from the planned item, recipe, process type, and unit size.
- Updated Postgres Sterilizer OUT logic to create recipe-component rows for generated lots.
- Added component-mode smoke testing for generated sterilizer lots.
- Corrected generated relationship and migration artifacts for recipe components.
- Removed invalid exported `lot_recipe_components` rows that did not reference a lot.
- Removed a duplicate `CASING_PEAT` item from the source schema and regenerated the migration artifacts.
- Hardened generated imports with stricter ID validation, text-formula compilation fixes, relationship cleanup, and safer load behavior.

---

## All-in-one lifecycle support

- Added full all-in-one bag lifecycle support across Airtable, Postgres, Appsmith, labels, and tests.
- All-in-one bags can now:
  - be created from matched recipe-component sets during Sterilizer OUT,
  - be inoculated directly,
  - receive casing,
  - move through the applicable lot lifecycle,
  - be packaged/productized through the Appsmith interface.
- Added all-in-one label handling to the print queue and print daemon.
- Added Appsmith workflow support for all-in-one lifecycle operations.
- Fixed Appsmith component selection so complete component sets are selected rather than partial matches.
- Added all-in-one package/productize support and aligned created products with the current Products schema.
- Added all-in-one lifecycle and package smoke tests, including support for formatted pound values in generated labels.

---

## Freeze-dried packaging redesign

- Redesigned the freeze-dried packaging workflow in Appsmith and Postgres.
- Reworked the modal state so package item, package size, package class, source trays, quantity, and summary remain synchronized.
- Added a package-size selector backed by supported package sizes rather than free-form entry.
- Wired the package-size selector into the Postgres packaging action.
- Source freezer trays are consumed after successful packaging.
- Products refresh after package completion.
- Default package use-by dates are applied when no override is provided.
- Origin-lot resolution failures now produce explicit validation errors rather than failing silently.
- Package actions retain source lineage, package class, strain context, and package event links.
- Multi-lot packaging now packages each selected lot independently instead of treating all selected lots as one combined source.
- Added smoke testing for multiple-lot packaging and freeze-dried package behavior.

---

## Sample packaging and labels

- Added schema, automation, Appsmith, and print-daemon support for freeze-dried **Sample** packages.
- Sample packaging supports the configured package sizes, including 1 g, 5 g, and 1 oz where defined by item/package configuration.
- `package_class = Sample` is carried into created products.
- Sample packaging is not restricted only to regulated strains.
- Added sample-specific label fields and materialized schema output.
- Updated company-address handling to use the product label company-address base field.
- Improved sample label readability:
  - enlarged disclaimer text,
  - moved sample font-size controls into `.env.example`,
  - resized lower-label content for better readability.
- Added regulated and non-regulated sample-label handling in the print daemon.
- Kept label configuration externally adjustable through print-daemon environment settings.

---

## Draw Syringes label parity

- Populated generated syringe lot label fields during Draw Syringes.
- Corrected title/subtitle content for drawn LC syringe labels.
- Added a dedicated drawn-syringe label smoke test.
- Preserved the selected syringe item and source-lot context in generated lots and print jobs.

---

## Products and tray lifecycle parity

- Finished tray lifecycle event auditing for:
  - move to freeze dryer,
  - retire,
  - spoil,
  - compost.
- Tray actions now require the expected lifecycle audit events.
- Updated Products-page UI behavior around tray actions and refreshed state.
- Added repeatable product tray-action smoke tests.
- Continued alignment of tray locations, terminal states, event links, and UI result handling.

---

## Harvest and Inoculate hardening

- Fixed standalone Harvest state so state resets by selected lot.
- Preserved the selected Harvest lot during table row events and refreshes.
- Added mixed fresh/freezer harvest-output smoke testing.
- Cleared stale Inoculate source and target state when the source mode or selection changes.
- Added smoke coverage for both liquid and solid inoculation source modes.
- Continued enforcing the different volume/eligibility rules for LC and solid sources.

---

## Fulfillment reconciliation visibility

- Kept completed fulfillment orders visible when they still require reconciliation or review.
- Added smoke testing for fulfillment order visibility.
- Updated the PGSQL and Airtable Fulfillment API workflows consistently.

---

## Audited print-queue management

- Added a new Appsmith **Print Queue** page.
- Added Postgres helper functions in `011_print_queue_actions.sql`.
- The page provides audited queue-management actions for operators, including controlled retry/cancel/reset-style queue operations supported by the backend.
- Organized the print-queue widgets and page JavaScript into maintainable sections.
- Added print-queue action smoke tests.
- Updated the print daemon and documentation for the expanded queue data and label behavior.

---

## Appsmith improvements

- Refreshed the Appsmith project after RC4 testing.
- Added or completed Appsmith UI support for:
  - all-in-one lifecycle actions,
  - all-in-one packaging/productization,
  - redesigned freeze-dried packaging,
  - package-size selection,
  - audited print-queue management.
- Corrected Sterilizer IN success reporting so the created sterilizer-run identifier is displayed.
- Continued tightening page refresh behavior, modal state, selection handling, and workflow summaries.

---

## Schema, formulas, and generated import fixes

- Updated the Airtable schema with:
  - recipe-component tables,
  - sample-label fields,
  - package-related fields,
  - all-in-one support fields.
- Improved the Airtable-to-Postgres generator:
  - validates imported IDs,
  - compiles Airtable text formulas more safely,
  - generates updated link and computed-view definitions,
  - handles recipe-component relationships,
  - produces hardened SQL imports and load files.
- Refreshed the field map and generated exports for the RC5 schema.

---

## Issues addressed or materially advanced

This release includes work associated with the following RC5 parity and feature-completion issues:

- `#36` Harvest tray creation / tray behavior.
- `#37` Fulfillment and reconciliation parity.
- `#56` Harvest defaults, stale state, and single-lot behavior.
- `#59` Inoculation source-mode and stale-state handling.
- `#60` Drawn LC syringe label title/subtitle behavior.
- `#61`–`#65` freeze-dried package lineage, events, use-by behavior, tray consumption, and product lifecycle events.
- `#66` all-in-one workflow support.
- `#67` completed fulfillment order visibility.
- `#68` freeze-dried sample packaging and labeling.
- `#69` package summary and independent multi-lot packaging behavior.
- `#70` Products tray-action auditing, refresh, and operator feedback.
- Recipe-component and all-in-one changes also advance the remaining parity work related to Spawn to Bulk, treatments, and generated-lot composition.

---

## Summary

`v1.1.0-RC5` is the feature-completion release candidate for the Appsmith/Postgres migration. It adds recipe-component tracking, complete all-in-one workflows, sample packaging and labels, a redesigned freeze-dried packaging flow, independent multi-lot packaging, audited print-queue management, and expanded smoke-test coverage. It also resolves another set of RC4 findings across Products, Harvest, Inoculate, Fulfillment, labeling, imports, and generated Postgres schema behavior.

## [v1.1.0-RC4] - 2026-06-18

_This release is the next release candidate for validating the Appsmith/Postgres implementation against the Airtable production baseline. It focuses on RC3 test findings and parity tickets: import/sanitization fixes, Appsmith deployment/runtime fixes, fulfillment reconciliation behavior, lab/sterilizer/harvest/spawn validation, product lifecycle events, freeze-dried package lineage, and print-routing correctness._

---

## Release-candidate focus

- Continued the row-by-row parity test cycle after `v1.1.0-RC3`.
- Incorporated RC3 test results and updated the test matrix for the RC4 candidate.
- Refreshed Airtable schema/export artifacts for RC4 testing.
- Added and corrected Appsmith/Postgres behavior for the next round of parity validation.

---

## Import, schema, and sanitization fixes

- Updated Airtable schema/export artifacts in preparation for RC4 testing.
- Repaired email obfuscation / postprocess behavior:
  - normalized only operator import columns that should become operator identities (`lots.operator`, `products.operator`, `sterilization_runs.operator`),
  - converted `User Name <email@domain>`-style values to email values during import,
  - supported legacy first-name operator values where the updated schema choices contain full `Name <email>` choices,
  - recursively obfuscated emails and lingering organization/domain strings without hardcoded operator definitions,
  - fixed the placeholder typo `MyBuinessAddressAndContact` → `MyBusinessAddressAndContact`.
- Added / updated NocoDB API v3 support.
- Fixed `005_helpers.sql` import syntax so PL/pgSQL exception handling uses a single `EXCEPTION` block with multiple `WHEN` cases.

---

## Appsmith deployment/runtime hardening

- Fixed deployed Appsmith modal-submit issues caused by unusual `fullyQualifiedName` values on Products-page queries:
  - `qPackageFreezeDried`
  - `qRetireTrayProducts`
  - `qMoveProductsToFreezeDryer`
- Fixed Lab - Spawn to Bulk refresh behavior after submit:
  - `LotsSpawnToBulk.spawnSelected()` no longer calls the broad `LotsSpawnToBulk.refresh()`,
  - refresh is limited to the table/source/species queries required after submit,
  - avoids mixing `qSpawnToBulkLocations.run()` and `qSpawnToBulkLocations.data` in the same reactive dependency path.
- Improved Appsmith display of backend validation errors for inoculation workflows.
- Added LC remaining volume to the Inoculate source table so operators can see available LC before submitting.

---

## Sterilizer parity

- Added Sterilizer IN notes support:
  - `sterilization_runs.notes` is imported / stored,
  - optional notes are saved when creating a sterilizer run,
  - notes are included in the `SterilizerRunCreated` event payload when present,
  - Appsmith Sterilizer IN includes a Notes input and submit wiring.
- Required a valid Sterilizer OUT storage location before completion.
- Defaulted the Sterilizer OUT Appsmith storage-location selector to **New Lots** by `nocopk`.
- Prevented zero-valued location IDs from reaching lot creation.
- Added destroyed-unit context to Sterilizer OUT events:
  - run number,
  - process type,
  - planned item,
  - planned recipe,
  - planned unit context,
  - destroyed count / sequence.
- Preserved the sterilizer `process_type` display value in event metadata so Sterilize/Pasteurize values remain aligned with `sterilization_runs` and lots.

---

## Inoculation and lab workflow parity

- Validated inoculation override dates against source material availability:
  - source availability is computed from created, sterilized, and received dates,
  - inoculation overrides before the source exists / is available are rejected,
  - validation errors are surfaced through the source lot `ui_error`.
- Fixed agar plate source handling:
  - colonized agar plates are allowed as non-liquid inoculation sources,
  - agar flasks remain excluded from the generic inoculation workflow,
  - LC volume is required only for LC flask / LC syringe sources,
  - stale LC volume state is cleared when the source context changes.
- Added Airtable-parity fields to `Inoculated` event payloads:
  - operator,
  - target lot ID,
  - source display / Airtable identifiers,
  - native `nocopk` identifiers.
- Validated pour dates against the source agar flask:
  - source availability is computed from created, sterilized, and received dates,
  - pour timestamps before source material exists / is sterilized are rejected.
- Fixed null-safe Airtable formula concatenation so blank `vendor_batch` no longer blanks received syringe label subtitles.

---

## Spawn to Bulk parity

- Fixed Spawn to Bulk override-date behavior by passing the Appsmith override spawn date into `mp_lots_spawn_to_bulk`.
- Populated created bulk lots with source species, strain, and vendor metadata so `Bulk_Created` labels have meaningful subtitle content.
- Added optional `fruiting_goal` support:
  - persisted on spawned fruiting block lots,
  - included in `SpawnedToBulk` event metadata,
  - added to the Lab Spawn to Bulk Appsmith selection flow,
  - preserves existing Lots-modal behavior when no goal is selected.

---

## Harvest parity

- Fixed Harvest Appsmith form state behavior:
  - prevents duplicate harvest submits while `qHarvestLot` is running,
  - resets harvest submit state when opening the Harvest action,
  - aligns required fields with harvest SQL validation,
  - defaults fresh harvest tray count to one.
- Fixed Harvest event linkage:
  - Harvest event arguments are mapped by name,
  - Harvest events link to each created tray product,
  - Harvest events still link to the source fruiting lot.

---

## Transition / fully-colonized parity

- Required a destination location for Fully Colonized transitions.
- Defaulted Fully Colonized transitions to **Dark Room** in Appsmith.
- Updated SQL transition behavior to set lot location during Fully Colonized.
- Added destination location fields to the `FullyColonized` event payload.

---

## Products, trays, and package-freeze-dried parity

- Added product-linked lifecycle events for tray actions:
  - Move to Freeze Dryer,
  - Spoil Tray,
  - Compost Tray,
  - Retire Tray.
- Product lifecycle events now capture previous and new tray state/location in `fields_json`.
- Fixed freeze-dried product lineage and package events:
  - strain and origin-lot lineage are populated when creating freeze-dried packaged products from freezer trays,
  - package runs reject mixed-strain source trays,
  - default use-by dates are applied,
  - package events link to created products, source trays, and origin lots.
- Added product event linking helper support.
- Fixed tray print-target formula generation so `fresh_tray` and `freezer_tray` print-queue rows route to the **TRAYS** daemon instead of the standard product daemon.

---

## Fulfillment and reconciliation parity

- Updated Fulfillment PGSQL product search terminal filters:
  - excludes `Consumed`, `Compost`, and `Expired` product locations from available-inventory search.
- Kept completed fulfillment orders visible for reconciliation / review.
- Added completion flags from the n8n list API.
- Disa…6398 tokens truncated… Fulfillment API.json` and supporting documentation in `n8n/README.md`.
- Fulfillment logic now supports the intended reconciliation flow for:
  - **website orders** paid in Ecwid, and
  - **farmers market / Clover** orders reconciled against Ecwid-created orders.
- Improved product search behavior in the Fulfillment page so operators can find assignable products more reliably.
- Stabilized the Fulfillment page by moving widget JS into a single shared object and tightening the search / assignment flow.

---

## Clover / Ecwid reconciliation

- Added initial and follow-on n8n workflows for the Clover / Ecwid reconciliation process:
  - Clover reconciliation poller / webhook workflows
  - Ecwid order update workflow
  - Daily reconciliation report email + PDF workflow
- Updated ecommerce schema / fields to support **Ecwid ↔ Clover reconciliation**.
- Adjusted reconciliation handling so orders processed through this path are not incorrectly marked as paid-due in ways that can create duplicate Clover payment behavior.
- Added support for expanding order synchronization capacity and updating missing UPC values on Ecwid orders.

---

## Personnel reviews / operator identity

- Added a new personnel review subsystem in Postgres:
  - `021_personnel_reviews.sql`
  - `022_personnel_reviews_seeds.sql`
- Added `023_operator_identity.sql` and `124_operator_identity_backfill_and_review_integration.sql` to better map Appsmith-authenticated operators into the database and tie review entries to known people.
- Added documentation for the new manager-log / review process in `doc/Personnel-Reviews-and-10-Minute-Manager-Log.md`.
- Added logic to normalize and de-duplicate review subjects / operators, including current-operator helpers used across Appsmith pages.

---

## Postgres / imported-data development workflow

- Refreshed the production schema and export artifacts to a **larger Airtable data set** for Postgres development and interface testing.
- Added / updated load and import documentation for rebuilding the Postgres bridge database from the generated SQL + CSV artifacts.
- Reworked handling of `100_load.sql` so it is run in the right context for host-side CSV access.
- Removed older manual / obsolete migration paths and replaced them with the current documented import flow.

---

## Lot actions, validation, and interface-backed testing

- Expanded `schema/pgsql/008_lot_actions.sql` with more complete helper functions for lot-centric operations exposed through Appsmith.
- Added validation for lot actions such as **Shake** and **Move**, and allowed multiple modifier actions where needed.
- Added / refined SQL wiring for:
  - Move Lots
  - Modify Lots
  - Package Lots
  - Inoculate Lots
  - Draw Syringes
  - Receive Purchased Syringes
  - Pour Plates
  - Spawn to Bulk
- Basic testing has now begun against the imported larger data set through **Lots manipulation** and related Appsmith workflows.

---

## Schema / workflow parity fixes

- Added active flags for `items`, `locations`, and `strains`.
- Added `recipes.active` and updated interface queries to use active recipes only where appropriate.
- Ensured new lots created in **Sterilizer Out** receive `item_id` and `recipe_id` foreign keys and a default location.
- Updated events schema and sterilization-related helper SQL to better match the Airtable production workflow.
- Materialized additional fields used by the Postgres/Appsmith path, including `products.process_type_mat`.
- Updated packaging-related computed fields such as `products.net_weight_g` and `products.net_weight_oz` to better mirror Airtable behavior.
- Updated handling of lot volume and related materialized fields for liquid lots vs grain / agar lots.
- Updated labeling behavior so `label_type` and `source_kind` match Airtable conventions more closely.
- Improved print queue creation and syringe-receive labeling behavior.

---

## Documentation and migration direction

- Updated the top-level README to make clear that **Retool is no longer a target** and Appsmith is the supported interface direction going forward.
- Removed legacy `Retool_*.txt` files from the interface-planning area.
- Expanded README content across:
  - root README
  - `appsmith/README.md`
  - `n8n/README.md`
  - `schema/pgsql/README.md`
  - `integrations/ecwid/README.md`
- Added / retained supporting legacy UPC barcode tooling and code pools used for ecommerce workflows.

---

## Hardening and cleanup

- Applied general hardening to reduce console warnings and tighten interface behavior.
- Improved SQL import robustness and repaired additional syntax / schema mismatches encountered during development.
- Cleaned up print-daemon behavior and README notes to align with the newer Postgres/Appsmith workflow.

## [v1.0.7-beta] - 2026-02-17

_This release advances the NocoDB/Postgres migration by introducing the first **Appsmith interface** operating against a **Postgres database** (exposed through NocoDB). It also tightens schema parity, adds helper SQL for core workflows, and improves lot lifecycle/event logging._

---

## Appsmith + Postgres (via NocoDB)

- **Initial Appsmith “Lot-centric UI” running against the imported Postgres database**, accessible through NocoDB.
  - Includes working Sterilizer interfaces (**Sterilizer – In**, **Sterilizer – Out**) and a **Lots** page for viewing/filtering by major identifiers.
  - Added Appsmith app export (`appsmith/MushroomProcess.json`) plus formatting tooling (`pretty-json.mjs`).
- Documentation added/updated for the Appsmith approach and current coverage (`doc/Appsmith-Lot-Centric-UI.md`, `appsmith/README.md`, and related interface notes).

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
- Reorganized and expanded the NocoDB migration outputs into a dedicated `schema/` structure (including `pgsql/` scripts, generated schema artifacts, and CSV exports).
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

## Experimental NocoDB REST automation prototype

- Expanded the prototype documentation with:
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

## Experimental NocoDB interface and Retool path

- Updated the experimental interface documentation with instructions for generating views that correspond to Airtable Interfaces.
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

- Added an initial experimental Node.js package that mirrored the core Airtable automations through the NocoDB REST API. This prototype was later removed when operational automation moved into PostgreSQL.

- Brought over the **multi-target inoculation** workflow so you can inoculate multiple targets from a single source in the NocoDB path, matching the behavior already available on Airtable. 
- Ensured that automations remain compatible with existing changes such as:
  - inoculation from untracked sources;  
  - `lc_volume_ml` / `target_lot_ids` reset on the source lot;  
  - Fully-Colonized event history for items moved to Fridge, ColdShock, and Fruiting. 

### NocoDB interfaces & Retool

- Introduced an experimental interface-migration package containing:
  - scripts to create NocoDB views that approximate the Airtable Interfaces, and  
  - **Retool how-to documentation** for each interface. 
- Added detailed **interface descriptions** focused on NocoDB/Retool, with enough information to:
  - recreate Interfaces on a fresh Airtable base, or  
  - drive equivalent NocoDB views / Retool apps. 
- Updated the **top-level README** to clearly describe the dual path:
  - Airtable schema + automations + interfaces, and  
  - NocoDB schema generation, automations, and interfaces / Retool guidance. 
- Added dedicated documentation for the experimental view-generation scripts, Retool glue, and schema assumptions.

### Print daemon: NocoDB support

- Extended the **print daemon** so it can **poll NocoDB** in addition to Airtable, still targeting 4×2 thermal labels (e.g., JADENS JD268BT-CA). 
- Kept existing behavior for Airtable intact while wiring in NocoDB connection details via environment variables.

### Documentation & housekeeping

- **Top-level README** rewritten for **combined Airtable/NocoDB support**, including updated repository layout and “how the system hangs together” with both backends. 
- Added setup and usage documentation for the experimental NocoDB REST-automation and interface-generation prototypes.

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
