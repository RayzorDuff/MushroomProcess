# Commercial catalog interface

ERPNext owns commercial Item/Item Price/content. MushroomProcess owns operational
quantity, packages and lineage. Apply `schema/pgsql/051_erp_commerce_catalog.sql`
after 027. The new function reuses 027 availability semantics but removes the
Ecwid-only filter. Existing Ecwid function/workflows are unchanged.

`erp_item_code` is nullable until a human-reviewed SKU/variant mapping exists.
Do not infer an ERP Item from MushroomProcess Item alone: strain/packaging can
change the sellable SKU. Use a parameterized update for reviewed links. Do not
copy storefront stock into Products or Lots. Snapshot validation fails closed
for missing ERP links/invalid quantities. `compose_projection` in RootedOps
checks both ERP Item and ecommerce mapping identities before joining content and
stock. No ERP or storefront inventory writes are enabled by this release.

Import `MushroomProcess - Commercial Catalog Snapshot - PGSQL.json` into a new
staging n8n instance, select only the staging Postgres credential, leave inactive
and run manually. It exposes mappings requiring review and operational quantity.
The Appsmith export was inspected for its existing datasource/workflow conventions;
this release does not rewrite the production app or its datasource IDs. A mapping
administration page remains #80 work, with ERP content edited in native Frappe forms.

Run rollback-protected `schema/pgsql/tests/051_erp_commerce_catalog.sql` to compare
Ecwid quantities against the unchanged existing workflow. Test at least one
synthetic product, lot, expired product and non-Ecwid mapping before enabling sync.
Related RootedOps #20/#2 and MushroomProcess #80/#86; orders/refunds remain #85.
