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
  -f nocodb_schema/pgsql/tests/000_run_component_smoke_tests.sql
```

### Run with the PostgreSQL Docker container

The runner uses `\ir`, so copy the test directory into the container and run it
with `-f`:

```bash
sudo docker exec mushroomprocess-bridge-postgres \
  rm -rf /tmp/mushroomprocess-pg-tests

sudo docker cp \
  nocodb_schema/pgsql/tests \
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
| #59 / #73 schema path | `008_inoculate_source_modes_smoke.sql` and `008_aio_lifecycle_smoke.sql`; UI enable/reset behavior remains Appsmith validation |
| #60 | `008_draw_syringe_labels_smoke.sql` |
| #61 / #63 | `008_freeze_dried_package_smoke.sql` |
| #65 / #70 schema paths | `008_product_tray_actions_smoke.sql` |
| #66 schema actions | `011_print_queue_actions_smoke.sql` |
| #68 | `007_sterilizer_component_mode_smoke.sql`, AIO tests, casing test, freeze-dried tests, harvest test, and Spawn to Bulk component tests |
| #69 | `008_package_multiple_lots_smoke.sql` |
| #75 | `010_spawn_to_bulk_components_smoke.sql` |

### Open issues not represented as PostgreSQL mutation tests

| Issue | Reason |
|---|---|
| #12 | QR destination routing is an Appsmith/public-link/ecommerce integration behavior, not a mutation function contract. |
| #13 | Image capture/upload storage has not been implemented in the PostgreSQL action layer. |
| #15 | Windows spooler success/failure is print-daemon behavior. `011_print_queue_actions_smoke.sql` covers database queue actions, but cannot simulate a spooler. |
| #56 | Default tray counts, stale widget state, and single-selection are Appsmith state behavior. Harvest database creation is covered by `009_harvest_mixed_outputs_smoke.sql`. |
| #57 | Deproductize/unpackage does not yet have a PostgreSQL function to execute. Add a transactional test with the implementation. |
| #67 | Fulfillment order visibility and stale selection are handled through the Appsmith/n8n API path rather than PostgreSQL mutation functions. |

The deferred generated-view correction for nonregulated Sample regulation
rollups under #68 should receive a computed-view test after the Airtable schema
is regenerated for v1.1.0; it is intentionally not encoded as a passing RC5
assertion against the current generated `004_computed_views.sql`.
