# Fulfillment allocation: owner walkthrough and deployment

This independently deployable fix follows installed Ecwid inventory 058. It does **not** require unfinished Woo migrations 054–059. The completed cash web order and already assigned/shipped Products are historical evidence, not fixtures: do not assign them again, move them back into stock or replay their opening stock delta. The owner confirms that sale completed. ERP cash posting is a separate follow-up; Assign and Dispatch cannot mark cash received.

## Behavior

Search Products accepts an empty string and returns a bounded, stable page of eligible Products matching the selected order's remaining specification pools. The table's server pagination sends page and page size; no aggregate-with-LIMIT query or all-pages download remains. Case, dates, valid location, package/strain/recipe and overlapping pools use installed 058 eligibility. Shipped/expired/ineligible Products, existing legacy assignments and installed Woo package picks are excluded. Assignment rechecks the same rule under the shared admission lock and a Product row lock. A stale scan or competing assignment fails without a second link or movement. Ambiguous/unmapped lines require review rather than a name match.

Assign allocates, creates the order link and returns current line progress in one database transaction. It does **not** move the Product. The selected order, Ordered Items and linked Products remain visible. Only product search/selection is reset. Required, assigned and remaining quantities refresh, including when a list filter removes the fully assigned order. Fully allocated shows a completion message and Confirm MP Dispatch; partial allocations stay available for more scans. Search responses from a previously selected order cannot overwrite the current selection.

Prepare labels separately. Dispatch is an explicit physical action (postal departure, pickup handover or completed local delivery) with its own stable movement reference and one transaction for location movement, events and dispatch receipt. Retry after an uncertain response with the retained reference; do not generate another. Partial dispatch leaves the remaining units open. Cancellation/refund releases only the new unshipped allocations; committed movements remain. Existing legacy Products, links and locations are not backfilled or changed. Ecwid native status changes remain the current owner/Ecwid process; this PR does not install a new Ecwid status writer. Woo uses its reviewed package/acknowledgment flow, not this legacy-order assignment API.

## A — read-only preflight (production Linode)

Run this alone. Keep Commercial Inventory Sync active and legacy Ecwid sync archived. Do not change checkout or the completed order.

```bash
(
  set -eu
  cd ~/mushroomprocess
  git log -1 --format='%h %s'
  git status --porcelain --untracked-files=no
  sudo docker exec -i mushroomprocess-bridge-postgres sh -ec \
    'exec psql -X -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"' <<'SQL'
BEGIN READ ONLY;
SELECT current_database(),current_user,
 to_regprocedure('public.mp_inventory_units()') AS inventory_058,
 to_regclass('public.mp_fulfillment_allocations') AS allocations_060,
 to_regprocedure('public.mp_product_set_storage_location(bigint,bigint)') AS movement;
SELECT count(*) AS active_shipped_locations FROM public.locations
 WHERE active AND regexp_replace(lower(name),'[^a-z0-9]','','g')='shipped';
COMMIT;
SQL
)
```

Success: clean tracked checkout; mushroomprocess_bridge; inventory and movement functions present; exactly one active Shipped location. 060 should be absent before first apply. **Stop** for a dirty checkout, missing 058, ambiguous Shipped location or partially installed 060. Verify the n8n PGSQL credential's database username privately before granting new object access. Do not paste credentials.

## B — backup (Linode, after reviewed merge/promotion)

Use the owner's normal main → production promotion, retaining deployed fixes. Fetch/fast-forward the approved deployment branch only; no branch-reset command is part of this procedure. Save the current Appsmith export and the active Fulfillment API PGSQL workflow privately before reimport. Pause only Fulfillment API operator writes while applying/importing. Inventory sync need not be paused.

```bash
(
  set -eu
  cd ~/mushroomprocess
  umask 077
  BACKUP_DIR="$HOME/commerce-migration/fulfillment-$(date -u +%Y%m%dT%H%M%SZ)"
  mkdir -p "$BACKUP_DIR"
  sudo docker exec mushroomprocess-bridge-postgres sh -ec \
    'exec pg_dump -Fc -U "$POSTGRES_USER" -d "$POSTGRES_DB"' > "$BACKUP_DIR/mp.dump"
  test -s "$BACKUP_DIR/mp.dump"
  sudo docker exec -i mushroomprocess-bridge-postgres pg_restore --list < "$BACKUP_DIR/mp.dump" > "$BACKUP_DIR/restore-list.txt"
  git rev-parse HEAD > "$BACKUP_DIR/source-commit.txt"
  printf 'Backup: %s\n' "$BACKUP_DIR"
)
```

Success: nonempty archive and restore list. **Stop** if backup verification fails; retain an off-host copy through the existing backup process before migration.

## C — apply (Linode, approved checkout)

```bash
cd ~/mushroomprocess
sudo docker exec -i mushroomprocess-bridge-postgres sh -ec \
  'exec psql -X -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"' \
  < schema/pgsql/060_fulfillment_allocation.sql
```

Success: COMMIT. **Stop** on any error. This does not change existing orders/stock/baselines. If the n8n credential is not the database owner, apply `schema/pgsql/operations/060_fulfillment_api_grants.sql` with psql `-v api_role=REVIEWED_N8N_DATABASE_ROLE`; inspect the exact credential username locally first. Existing base-table access remains required. Do not grant these actions to PUBLIC.

## D — import and publish (n8n/Appsmith owner UI)

Import the Git version of `n8n/workflows/MushroomProcess - Fulfillment API - PGSQL.json` **over the existing PGSQL Fulfillment API**, retaining its private PostgreSQL credential and existing webhook paths. Leave the Airtable reference workflow inactive. Confirm no second active workflow owns these routes. The revised workflow routes search, assign and dispatch only through 060 functions; the old two-write auto-ship path is removed. No import/change to Commercial Inventory Sync is required.

Render a separate Appsmith import file from Git, using the existing private export as `--source` if it includes reviewed local changes:

```bash
cd ~/mushroomprocess
umask 077
mkdir -p "$HOME/commerce-migration/fulfillment-ui"
python3 scripts/render_fulfillment_ui.py \
  --output "$HOME/commerce-migration/fulfillment-ui/MushroomProcess.json"
```

Import that rendered file into the existing application, retain its private datasource and publish. Both published/unpublished Fulfillment definitions and compiled actions are generated together from `appsmith/fulfillment_ui.js` and the scoped allocation overlay. No unrelated page or navigation change is intended. When later merging the Woo overlay, retain these changes in the base export and preserve the separate Woo section.

Success: empty Search returns a paginated list; assigning one synthetic test Product keeps order/detail and does not move its location. **Stop** before real dispatch if assignment still marks Shipped, the selected order disappears, the database returns permission errors or an old workflow still handles the route.

## E — hosted operator acceptance

Use a new synthetic/disposable order and test Products, not today's completed sale. Empty search → next page → search by exact code. Confirm an already-shipped Product and one assigned to another order are absent; submit an old/stale product ID and confirm refusal. Assign one of two required units: order and Ordered Items remain, Assigned=1, Remaining=1, physical location unchanged. Assign the second: Remaining=0 and dispatch action appears. Prepare the label without moving stock. Confirm dispatch only when intentionally moving the test units; retry the same reference and verify one event per Product and one receipt. Verify current Ecwid availability through the existing inspect/review query, never a hardcoded quantity. Cash receipt/accounting is a separate action and must not be inferred from allocation/dispatch.

## Rollback

Restrict Fulfillment writes. Resolve any **new** unshipped 060 allocations through dispatch or an actual reviewed order cancellation; do not falsify cancellation to free completed-sale stock. Restore the backed-up workflow/Appsmith together and apply `schema/pgsql/rollback/060_fulfillment_allocation.sql` only after reviewing its guard. It refuses outstanding allocations and keeps dispatch/financial history. Existing sales, Products, IDs, receipts and inventory 058 remain intact. Never restore a pre-sale database as routine rollback. The previous interface auto-ships on Assign, so only reopen it after operators are explicitly informed of that behavior.
