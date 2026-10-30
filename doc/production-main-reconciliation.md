# Production → main reconciliation, 2026-10-30

`production` is the authoritative current operational codebase. This merge brings
its history into `main`, retaining the commerce work already reviewed through
PRs #105 and #106. It does not deploy or apply migrations to a live system.

Reconciled parents:

- main: `0ccfde5` (merged commerce PR #106)
- production: `c6f2724` (current production policy documentation)

Production's complete Appsmith JSON is preserved byte for byte, including the
Lots workflow consolidation (#102), extraction UI, cultivation and harvest fixes.
Production payment aliases/reporting, sterilizer cancellation, Product-return
migrations 041–048, extraction provenance/labels and their tests remain present.
Commerce migration 051, order/reservation ledger 052, manual inactive catalog
snapshot and regression/concurrency CI from main remain present too.

Two extraction add/add conflicts were resolved using production's 050 function
and smoke test: these retain canonical/materialized strain and vendor provenance
rather than reverting to the older main implementation. The smoke test now creates
rollback-only synthetic locations, freezer-tray Item and Strain when a clean CI
database lacks them, so extraction behavior is exercised rather than skipped.

The production computed-view baseline had a duplicated/dangling
`source_product_business_id` expression. The valid main version is retained,
keeping the same field once and producing valid SQL. Migration 031's exact-view
fingerprint guards remain in force; no catch-all bypass is added.

Combined native tests also exposed that production migration 047 replaced the
Spawn-to-Bulk wrapper without retaining the America/Denver timezone pinned by
045. Keep that function configuration in 047 for fresh installs and provide
additive migration 053 to restore it on an already migrated database. The existing
045 regression asserts the contract. No live migration is run by this merge.

Appsmith tests formerly requiring deleted Lots-page workflow queries now assert
the canonical dedicated station pages and absence of the removed duplicates.
The NocoDB label-alias test now expects the existing stable QR resolver, rather
than obsolete direct links. No runtime Appsmith or printer behavior is changed
by those assertion repairs.

The existing navigation check reports drift for the published/unpublished Products
navigation widget compared with the manifest. This also occurs on the unchanged
production Appsmith export and is not silently fixed by regenerating that export.
Navigation/UI reconciliation remains separate; no claim is made that this check
passes. The 16 Appsmith/workflow/label smoke scripts are independent of that check.

Both `051_erp_commerce_catalog.sql` and
`051_extraction_batch_provenance.sql` are retained by full filename; do not renumber
an already applied migration based only on its numeric prefix. The clean-room CI
runner processes exact filenames lexicographically. Cultivation tests use guarded
synthetic lookup definitions in an empty commerce_test database instead of
requiring imported production Items/Recipes/Strains. No production CSVs, credentials
or runtime state are required for its synthetic tests.

Review the complete merge diff before approval. There are no whole-file deletions;
the large Appsmith diff is adoption of the production export, not a replacement
with a reconstructed export. After owner merge, main will contain both histories.
Promotion or database deployment remains a separate explicit operation. Never run
the complete baseline/rebuild sequence against an existing production database.
