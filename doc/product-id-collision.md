# Product business-ID collision correction

The MP #115 failure was a real short-suffix collision: inventory fixture 058 inserted several same-day Products without explicit IDs, and two generated `PROD-YYMMDD-xxxx` values matched. A passing rerun did not disprove it. The focused #115 test correction uses transaction-local fixture IDs so inventory behavior is deterministic. This independent migration fixes allocation for actual future Products too.

062 replaces only `set_autogen_ids_products()`. Existing nonempty Product IDs and UUIDs are preserved. A new missing ID keeps the established preferred short format when free. On collision it adds the new numeric Product identity, with a bounded further suffix if a manually allocated identifier already occupies that form. It does not regenerate lineage UUIDs, rename existing records, change external ecommerce IDs or reprint QR labels. The existing unique constraint remains authoritative for explicit duplicate IDs. A dedicated namespace lock serializes generated allocations across concurrent sessions without taking the commerce-stock lock. Bulk inserts see their earlier generated IDs. Lot generator behavior is unchanged.

Native tests force the same UUID tail rather than hoping randomness hits it; they cover bulk allocation, old-ID/UUID preservation, explicit duplicate rejection and concurrent sessions. Inventory fixture determinism is separate from generator correctness.

## Linode — preflight and backup (read-only)

From the approved checkout after owner merge/promotion, keep ordinary inventory sync unchanged. No n8n/Appsmith import is required for this correction.

```bash
(
  set -eu
  cd ~/mushroomprocess
  umask 077
  ID_BACKUP="$HOME/commerce-migration/product-id-$(date -u +%Y%m%dT%H%M%SZ).sql"
  mkdir -p "$(dirname "$ID_BACKUP")"
  sudo docker exec -i mushroomprocess-bridge-postgres sh -ec \
    'exec psql -XAt -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"' \
    > "$ID_BACKUP" <<'SQL'
SELECT pg_get_functiondef('public.set_autogen_ids_products()'::regprocedure);
SQL
  test -s "$ID_BACKUP"
  printf 'Saved current function: %s\n' "$ID_BACKUP"
)
```

Success: nonempty private function backup. Stop if the installed function is absent or has an unreviewed different implementation. No Product is created by this block.

## Apply (production function change)

```bash
cd ~/mushroomprocess
sudo docker exec -i mushroomprocess-bridge-postgres sh -ec \
  'exec psql -X -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"' \
  < schema/pgsql/062_product_id_collision.sql
```

Success COMMIT; stop on error. Existing IDs/data do not change. Future inserts use the corrected function immediately; no container restart or workflow reimport. Coordinate against concurrent packaging operations; the short lock timeout stops rather than waiting indefinitely on deployment locks. Do not run synthetic fixture tests against production.

Rollback: pause Product creation, apply `schema/pgsql/rollback/062_product_id_collision.sql` with the same Docker/psql command. The guard refuses later function changes and restores the saved function only. Existing new longer collision-fallback IDs are retained and remain valid `PROD-*` identifiers; never rename or relabel them. The old generator can collide again, so rollback is an exception requiring review.
