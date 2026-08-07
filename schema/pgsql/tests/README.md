# PostgreSQL component smoke tests

These tests execute the same PostgreSQL functions called by Appsmith. They
insert rollback-only fixtures, execute the real mutation functions, assert the
resulting lots/products/events/links/print jobs, and then `ROLLBACK`.

## Explicit mutation opt-in

The aggregate runner requires an explicit psql variable:

```text
allow_schema_modification=true
```

Despite the historical variable name, the tests do not apply DDL or permanently
change the schema. The flag authorizes rollback-protected **database mutation**
so the real Appsmith function paths can be exercised. The runner exits with
status 3 when the flag is absent or false.

### Run from a host `psql` client

From the repository root:

```bash
PGPASSWORD="$MP_BRIDGE_DB_PASSWORD" \
psql \
  -h 127.0.0.1 \
  -p 5434 \
  -U "$MP_BRIDGE_DB_USER" \
  -d "$MP_BRIDGE_DB_NAME" \
  -v ON_ERROR_STOP=1 \
  -v allow_schema_modification=true \
  -f schema/pgsql/tests/000_run_component_smoke_tests.sql
```

### Run with the PostgreSQL Docker container

The runner uses `\ir`, so copy the test directory into the container and run it
with `-f`:

```bash
sudo docker exec mushroomprocess-bridge-postgres \
  rm -rf /tmp/mushroomprocess-pg-tests

sudo docker cp \
  schema/pgsql/tests \
  mushroomprocess-bridge-postgres:/tmp/mushroomprocess-pg-tests

sudo docker exec -i \
  -e PGPASSWORD="$MP_BRIDGE_DB_PASSWORD" \
  mushroomprocess-bridge-postgres \
  psql \
    -v ON_ERROR_STOP=1 \
    -v allow_schema_modification=true \
    -U "$MP_BRIDGE_DB_USER" \
    -d "$MP_BRIDGE_DB_NAME" \
    -f /tmp/mushroomprocess-pg-tests/000_run_component_smoke_tests.sql
```

Individual test files can still be run using the existing stdin pattern. They
all contain their own transaction and rollback.

## Open-issue coverage audit

The RC5 open issue list was reviewed against the current schema tests.

### Newly added behavioral coverage

| Issue | Test coverage |
|---|---|
| #1 | Unequal ratio allocation, different output item types, proportional actual components, and input consumption in `010_spawn_to_bulk_contract_smoke.sql` |
| #16 | Canonical `Sterilize`/`Pasteurize` storage, defaults, lot status, events, and sterilizer-sheet queueing in `007_sterilizer_process_type_smoke.sql` |
| #27 | Fruiting-block casing timestamp precision, note append, status/label preservation, event metadata/linkage, and no-print behavior in `008_apply_casing_parity_smoke.sql` |
| #52 | Direct override precedence across output timestamps, events, computed label fields, use-by, and print data, plus a no-override regression path in `010_spawn_to_bulk_contract_smoke.sql` |
| #54 | Persistence and event metadata for `top`, `side`, `shoebox`, and `monotub`, plus invalid-goal rejection. UI substrate filters remain an Appsmith test. |

### Existing PostgreSQL coverage retained by the runner

| Issue | Existing test |
|---|---|
| #59 / #73 schema path | `008_inoculate_source_modes_smoke.sql`, `008_inoculate_validation_atomicity_smoke.sql`, and `008_aio_lifecycle_smoke.sql`; covers source modes, rejected-request no-side-effects, insufficient-volume atomicity, multi-target counts, decrement, events, and labels. UI enable/reset behavior remains Appsmith validation. |
| #60 | `008_draw_syringe_labels_smoke.sql` |
| #61 / #63 | `008_freeze_dried_package_smoke.sql`; covers one operation event, source/created product links, origin-lot links exposed through `vc_products`, structured event fields, and package-label queueing. |
| #65 / #70 schema paths | `008_product_tray_actions_smoke.sql` |
| #66 schema actions/view | `011_print_queue_actions_smoke.sql` and `011_print_queue_view_contract_smoke.sql`; covers audited status changes plus the persisted fields, time predicates, and ZEBRA/TRAYS routing consumed by the Appsmith filters. |
| #68 | `004_product_regulation_rollup_smoke.sql` validates scalar regulation rollup and regulated/nonregulated Sample label branching. The sterilizer component-mode, AIO, casing, freeze-dried, harvest, and Spawn to Bulk tests cover the remaining implemented database paths. |
| #69 | `008_package_multiple_lots_smoke.sql` |
| #75 | `010_spawn_to_bulk_components_smoke.sql` |
| #78 | `024_inventory_reconciliation_smoke.sql` and `025_inventory_reconciliation_lots_smoke.sql`; cover Product and Lot found-item moves, Missing or Lost assignment, duplicate found IDs, post-snapshot concurrency protection, synchronized location links, audit events, Product Shipped correction, and terminal-state blocking. |


### Additional negative-path and view-contract coverage

| Issue | Test coverage |
|---|---|
| #59 / #73 | Liquid-source missing/insufficient volume rejection, solid-source volume rejection, no target/event/print side effects on rejected requests, actual multi-target return count, source decrement, target updates, event metadata, and one queued label per successful target in `008_inoculate_validation_atomicity_smoke.sql` |
| #66 | `vc_print_queue` exposure of status, printer target, daemon identity, source kind, label type, run/lot/product IDs, created/claimed/printed timestamps, errors, and ZEBRA/TRAYS routing in `011_print_queue_view_contract_smoke.sql` |

These tests validate the database contracts that support the open issues. They do
not close the remaining Appsmith-specific acceptance criteria, such as widget
visibility, stale selection clearing, button busy-state, table filtering UI, or
refresh behavior.

### Open issues not represented as PostgreSQL mutation tests

| Issue | Reason |
|---|---|
| #12 | `026_ecommerce_provider_neutral_smoke.sql` covers Ecwid-to-provider-neutral catalog/order aliases and protects non-Ecwid provider mappings. QR resolver/deep-link behavior remains an integration test. |
| #13 | Image capture/upload storage has not been implemented in the PostgreSQL action layer. |
| #15 | Windows spooler success/failure is print-daemon behavior. `011_print_queue_actions_smoke.sql` covers database queue actions, but cannot simulate a spooler. |
| #56 | Default tray counts, stale widget state, and single-selection are Appsmith state behavior. Harvest database creation is covered by `009_harvest_mixed_outputs_smoke.sql`. |
| #57 | Deproductize/unpackage does not yet have a PostgreSQL function to execute. Add a transactional test with the implementation. |
| #67 | Fulfillment order visibility and stale selection are handled through the Appsmith/n8n API path rather than PostgreSQL mutation functions. |

The generated-view correction for nonregulated Sample regulation rollups under
#68 is covered by `004_product_regulation_rollup_smoke.sql`. The test requires
`origin_strain_regulated` to be a scalar numeric SUM of linked checkboxes and
verifies the company, address, disclaimer, company-info, cottage, and public-link
branches for both regulated and unregulated Sample products.
