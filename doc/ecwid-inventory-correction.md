# Ecwid inventory correction — existing production, before Woo cutover

This is an independent MushroomProcess change based on main. Apply migration **058 only** to the existing `mushroomprocess_bridge` database after preflight. Its prerequisites are 026/027/051/052, which provide the three installed inventory functions and reservations. It does not require deploying 054–057, Woo hooks, ERP accounting, a new bench, a hostname change or Appsmith changes. Current main already preserves production's paid-Ecwid-event handling and internal n8n route; the inventory patch changes neither deployed fulfillment nor order webhook workflows. The production branch's two extra ancestry commits introduce no changes when merged into current main; no operational fix is replaced.

The urgent listing remains MP ecommerce **1**, Ecwid product **711334877**, SKU **E1SNHBC4QANF6**. Preserve all IDs. No product creation, rematching, enabled-state change, name/price change or UPC change is performed by the new publisher.

## Historical evidence, not opening quantities

The private November 21 exports were loaded into disposable PostgreSQL 16 and the actual old/new SQL functions were compared. Locations were reconstructed from export names because the location-active flags were not supplied. No current order/reservation export accompanied these files. These results are **gross review candidates**, not approval to publish these quantities:

| Listing | MP ID | Ecwid ID | Before gross | After gross | Additional candidates |
| --- | --- | --- | ---: | ---: | ---: |
| 5 lb pasteurized CVG / Coco Coir | 1 | 711334877 | 0 | 5 | 5 |
| 7.5 lb sterilized 75/25 hardwood substrate | 31 | 711335795 | 0 | 3 | 3 |
| 1 oz Chestnut | 29 | 829845573 | 9 | 12 | 3 |
| 1 oz Red Reishi | 35 | 711335798 | 0 | 13 | 13 |

The preserved legacy Chestnut packages record 28 g with their size-specific 1 oz Item. The rule accepts that legacy whole-gram rounding without broadening new generic 5 g packages into 1 oz stock. New generic 1 oz packages require matching ounce weight/package evidence. Wrong 2.5/5/7.5 lb sizes, 50/50 versus 75/25 recipes, grain versus substrate, strains, processing stages, expired/retired units and unknown/inactive/terminal locations remain separate or excluded. Unspecified generic listings and overlapping incompatible pools fail closed. Lots already converted into Products are not counted again.

The coordinated functions retain their return contracts. `mp_ecommerce_catalog_inventory()` reports gross units; `mp_commerce_inventory()` subtracts shared ledger and unshipped legacy Ecwid holds; `mp_ecommerce_ecwid_catalog_sync_candidates()` exposes net Ecwid stock. A single enabled listing owns publication for each pool. Suppressed aliases report zero availability. Outstanding reservations on a disabled alias still reduce its pool. A checked edit updates the installed 052/054 intake reservation predicate without replacing other installed intake behavior. Unknown function definitions stop the transaction. Do not reapply 058 over later function changes without review.

## Ongoing publication and fulfillment

Ecwid deducts stock when orders are placed. Writing a later absolute MP count can restore that stock before fulfillment. The new Commercial Inventory Sync route uses Ecwid's stock-delta endpoint and a durable MP receipt instead:

- Basis = current eligible MP units minus other-channel reservations plus eligible-definition Products physically marked Shipped and linked to active Ecwid orders.
- Ecwid's own pending order deductions are preserved. The later MP physical shipment is credited once in the basis, so it does not deduct the same sale again.
- Actual production, expiration, corrections and approved physical returns change the basis. Native cancellations restore unshipped stock; full refunds of physically shipped units receive a compensating deduction until physical stock actually returns. Partial refunds and generic-Ecwid-ledger coexistence stop for review.
- Each API delta gets one pending token before sending. A verified `updateCount=1` response acknowledges it. Timeout, warning, crash or unknown response leaves the token pending and blocks replay. Acknowledgments are idempotent; a resolved token cannot change outcome.
- Only initialized, reviewed existing Ecwid listings publish. Other listings remain in baseline review and are skipped. Initializing Coco alone does not approve the other candidate quantities.

Continue the existing MP fulfillment interface: package the actual selected whole Lot into one Product (the source Lot becomes Consumed), scan/assign the actual Product to its Ecwid order, and mark it Shipped through the existing workflow. The existing Product↔order link provides the stock-credit evidence. Partial fulfillment must retain the unshipped quantity. Do not manually move a sold Product to Shipped without linking its order, and do not mark an incompletely fulfilled order Shipped in Ecwid. Physical returns go to a review/quarantine location until accepted; refunding a payment does not itself make the goods available. No Woo fulfillment migration or UI replacement is required here.

Official API behavior: [Ecwid stock adjustments](https://docs.ecwid.com/api-reference/rest-api/products/adjust-product-stock), [variation adjustments](https://docs.ecwid.com/api-reference/rest-api/products/product-variations/adjust-product-variation-stock), and [native checkout/cancellation deductions](https://support.ecwid.com/hc/en-us/articles/4402494390162-Intro-to-product-inventory). Do not enable automatic retries for a stock delta.

## Block 1 — read-only Ecwid verification, production Linode

Run this first. No Git update, migration, stock write, product disabling or workflow activation occurs.

```bash
(
  set -eu
  N8N_CONTAINER=$(sudo docker ps \
    --filter label=com.docker.compose.service=n8n --format '{{.ID}}')
  test "$(printf '%s\n' "$N8N_CONTAINER" | wc -l)" -eq 1
  test -n "$N8N_CONTAINER"
  sudo docker exec -i "$N8N_CONTAINER" node <<'JS'
(async () => {
  const store = process.env.ECWID_STORE_ID;
  const token = process.env.ECWID_SECRET_TOKEN;
  if (!/^[0-9]+$/.test(store || '') || !token) {
    throw new Error('Ecwid credentials unavailable inside this n8n container');
  }
  const response = await fetch(
    `https://app.ecwid.com/api/v3/${store}/products/711334877`, {
      headers: {Authorization: `Bearer ${token}`},
      redirect: 'error', signal: AbortSignal.timeout(15000)
    });
  if (!response.ok) throw new Error(`Ecwid HTTP ${response.status}`);
  const p = await response.json();
  console.log(JSON.stringify({id:p.id, sku:p.sku, enabled:p.enabled,
    quantity:p.quantity, unlimited:p.unlimited}));
})().catch(e => {console.error(e.message); process.exitCode = 1;});
JS
)
```

Expected ID `711334877` and SKU `E1SNHBC4QANF6`; record actual enabled/finite-stock/quantity values, without treating any quantity as the MP opening balance. STOP and return this output. A missing env setting means use the existing private Ecwid credential setup; do not paste keys. HTTP 401/403 requires the existing live token's catalog-read permission. Do not substitute a sandbox store, create a product or enable unlimited stock.

## Block 2 — reviewed Git source and backup, Linode

After the standalone inventory PR is reviewed and merged, promote its commits to production through the owner's normal Git procedure. This isolated checkout prevents replacing the live Appsmith export or unrelated workflows. Use the exact approved PR revision, inspect its SHA, and stop if it differs from the reviewed revision:

```bash
set -eu
mkdir -p "$HOME/commerce-migration"
git clone --no-checkout https://github.com/RayzorDuff/MushroomProcess.git \
  "$HOME/commerce-migration/mp-ecwid-inventory"
cd "$HOME/commerce-migration/mp-ecwid-inventory"
git fetch origin fix/ecwid-shared-inventory
git checkout --detach FETCH_HEAD
git log -1 --format='%H %s'
```

Success is the reviewed inventory PR head. STOP for a mismatch. If the isolated directory already exists, inspect its clean state and fetch there instead of deleting it. Keep this same shell/path for later blocks.

Leave **Commercial Inventory Sync paused**. Also pause any separate Ecwid Catalog Sync stock writer and finish/disable queued stock-writing executions. Leave native Ecwid order ingestion and the existing fulfillment workflow active. For the first publication window only, pause MP packing/assignment/corrections of this SKU and temporarily disable this **one product** in Ecwid admin. Do not pause the whole Ecwid store or change its domain. Later orders on other products can continue.

Back up the live database and privately download the paused Commercial workflow JSON from n8n before replacing it:

```bash
umask 077
INVENTORY_BACKUP="$HOME/commerce-migration/ecwid-stock-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -m 700 "$INVENTORY_BACKUP"
sudo docker exec mushroomprocess-bridge-postgres sh -ec \
  'exec pg_dump -Fc -U "$POSTGRES_USER" -d "$POSTGRES_DB"' \
  > "$INVENTORY_BACKUP/mushroomprocess.dump"
test -s "$INVENTORY_BACKUP/mushroomprocess.dump"
sudo docker exec -i mushroomprocess-bridge-postgres pg_restore --list \
  < "$INVENTORY_BACKUP/mushroomprocess.dump" >/dev/null
printf 'Verified private archive: %s\n' "$INVENTORY_BACKUP"
```

STOP on failure. Verify the archive through the existing off-host backup process. It contains private operational/customer data; do not attach it to an issue.

## Block 3 — installed prerequisite check, Linode (read-only)

```bash
sudo docker exec -i mushroomprocess-bridge-postgres sh -ec \
  'exec psql -X -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"' <<'SQL'
SELECT current_database(),current_user,
 to_regprocedure('public.mp_ecommerce_ecwid_catalog_sync_candidates()') AS ecwid,
 to_regprocedure('public.mp_ecommerce_catalog_inventory()') AS catalog,
 to_regprocedure('public.mp_commerce_inventory()') AS availability,
 to_regclass('public.mp_commerce_reservations') AS reservations;
SELECT e.nocopk,e.external_product_id,e.external_sku,i.item_id,
 i.replaced_by_item_id,e.sync_enabled,e.sync_to_ecwid
FROM public.ecommerce e JOIN public.items i ON i.nocopk=e.item_id
WHERE e.nocopk IN (1,29,31,35) ORDER BY e.nocopk;
SELECT item_id,nocopk FROM public.items
WHERE item_id IN ('SUB-CVG-5','SUB-CVG-BAG','SUB-MM75-7_5','SUB-HW-BAG','MUSH-DRIED-1OZ','MUSH-DRIED');
SELECT recipe_id FROM public.recipes WHERE recipe_id IN ('REC-SUB-CVG-V3','REC-SUB-MM75');
SQL
```

Expected database `mushroomprocess_bridge`, all three signatures and reservations present, original product IDs unchanged, required source/legacy Item and recipe codes present. Absence of 054/055 is acceptable. STOP if any required object/code or ID differs; do not run all migrations to fix this preflight.

## Block 4 — rollback-only before/after preview, then application

Preview makes temporary transactional schema/function changes and rolls them back. It performs no Ecwid/API write:

```bash
python3 scripts/ecwid_inventory_preview.py \
  | sudo docker exec -i mushroomprocess-bridge-postgres sh -ec \
    'exec psql -X -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"'
```

Expected a before/after table followed by `ROLLBACK`. Review all differences, especially the four candidate listings. Counts can differ from November 21 because of sales, shipments, dates, corrections and holds. STOP for incompatible pools, unexpected losses, unmapped stock, invalid order data or an unrecognized intake definition. No quantity is approved merely by this preview.

Apply only after the preview and backup are accepted:

```bash
sudo docker exec -i mushroomprocess-bridge-postgres sh -ec \
  'exec psql -X -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"' \
  < schema/pgsql/058_ecwid_shared_inventory.sql
```

Expected the same reviewed shape, current recalculated counts and `COMMIT`. One transaction replaces all three functions and the checked reservation predicate. It does not rewrite ecommerce IDs, external IDs, physical stock, orders, reservations or customer data. STOP on any error; the transaction rolls back.

## Block 5 — current orders and first Coco publication

Keep this product disabled, competing stock writers paused and MP work on this SKU paused. The helper reads current Ecwid orders through existing n8n credentials, filters to this SKU, and refreshes only stock-related fields of existing MP orders. It preserves customer/financial fields and merges existing line metadata. It stops for a new/current order absent in MP instead of creating an incomplete order. Let the existing native Ecwid ingestion catch up; if needed, replay that order through the existing reviewed ingestion procedure, then repeat the read/reconciliation. Do not proceed with a missing order.

```bash
python3 scripts/ecwid_inventory_publish.py inspect --ecommerce-id 1
python3 scripts/ecwid_inventory_publish.py sync-orders --ecommerce-id 1 --confirm-paused
sudo docker exec -i mushroomprocess-bridge-postgres sh -ec \
  'exec psql -X -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"' \
  < schema/pgsql/operations/ecwid-inventory-review.sql
```

Success: original ID/SKU, current order checks completed, current reviewed net quantity, owner mapping and no pending API receipt. Inspect the five historical lot candidates against current physical QR/location/status/use-by records. Any already-sold or fulfilled bag must be accounted for. The fresh net can be five, four, fewer or zero. STOP if the count or current order/fulfillment state is unexplained.

The following command **writes live Ecwid stock**, using a durable delta derived from the current MP net and fresh Ecwid readback. No hardcoded opening quantity is passed:

```bash
python3 scripts/ecwid_inventory_publish.py initialize --ecommerce-id 1 --confirm-paused
```

Expected: original mapped ID/SKU; reconciled order count; current net; a durable receipt if a delta is needed; finite-stock readback equal to the reviewed net; product still disabled; `Verified first publication`. STOP on any failure. Do not rerun initialization blindly after a timeout: its pending receipt prevents duplicate stock adjustment. A baseline that already exists requires receipt inspection, not reset.

**Urgent sale before the scheduler is ready:** after this block's live readback and owner review pass, you may re-enable the same finite-stock Coco product with both stock writers still paused. Ecwid's native counter handles the sale, and the existing MP fulfillment flow continues. Do not run the old absolute publisher. Complete block 6 before resuming automatic stock publication or relying on automatic replenishment.

## Block 6 — reimport and resume Commercial Inventory Sync

Reimport **MushroomProcess - Commercial Inventory Sync - PGSQL.json** from this approved Git revision into the existing paused workflow using n8n's import-from-file workflow editor. Replace that workflow rather than creating a second scheduled writer. Preserve its existing project and `Postgres account 2` credential binding. Keep it inactive while checking. No n8n service restart, Appsmith import, Ecwid order-webhook import or Woo deployment is required.

Confirm Manual Trigger and Hourly Schedule both flow through provider preflight; the Ecwid-enabled branch now reaches **Plan Safe Ecwid Inventory → Ready Changes → Apply Inventory Delta → Verify Receipt → Acknowledge**. The old absolute-quantity/UPC nodes remain as unconnected reference nodes and must not be executed manually. Keep the separate legacy Ecwid Catalog Sync inactive. Keep ERP/Woo provider flags disabled. The Ecwid path does not require the generic snapshot flag.

If the existing PostgreSQL credential is not the schema owner, grant only the new publisher permissions as owner. Read the username from that credential privately; do not confuse the credential label with a PostgreSQL role:

```bash
read -r -p 'PostgreSQL username used by Postgres account 2: ' N8N_DB_ROLE
sudo docker exec -i mushroomprocess-bridge-postgres sh -ec \
  'exec psql -X -v ON_ERROR_STOP=1 -v publisher_role="$1" -U "$POSTGRES_USER" -d "$POSTGRES_DB"' \
  sh "$N8N_DB_ROLE" < schema/pgsql/operations/058_ecwid_publisher_grants.sql
```

Run the workflow manually once while inactive. For initialized Coco with no intervening physical change, expect `unchanged`, no HTTP delta, no error and no pending token. Other uninitialized listings show `review_baseline_required` and remain unchanged in Ecwid; they need their own current review/readback before automatic publication. Do not initialize all rows from the historical export quantities.

**Resume the paused Commercial Inventory Sync only when:** the approved 058 migration committed; the Coco baseline and live finite-stock readback passed; the revised workflow was imported into the existing workflow; competing absolute-stock writers are inactive; the manual run passed; required grants work; and the review query has no pending/unknown receipt. Then activate this one schedule, re-enable the **same Ecwid product** in Ecwid admin and release the SKU's MP fulfillment pause. Verify the public Coco listing is purchasable with the reviewed finite stock. Neither WordPress hostname work nor unfinished Woo order PRs gate this step.

For the first actual sale: record only the order ID, verify Ecwid decrements, native Ecwid ingestion reaches the existing MP order, and the MP unshipped hold appears. Package/scan/assign the actual unit through the existing fulfillment interface. Verify current MP net and Ecwid quantity afterward; the next publisher pass must not deduct the same sale twice or restore it. An intentional replenishment/correction should generate exactly one delta and one resolved receipt. No test purchase or charge is executed by these scripts.

## Exceptions, resume and rollback

Use the read-only review SQL after publication and whenever a workflow errors. Keep credentials and private order bodies out of issues. Pending tokens identify unknown outcomes; do not use n8n's retry-from-HTTP action or clear the baseline. Inspect the private n8n execution and Ecwid stock/order history. Only after establishing whether the exact delta applied, resolve its token as owner:

```sql
SELECT public.mp_ecwid_inventory_resolve('THE_RECORDED_TOKEN'::uuid,'applied');
-- OR 'not_applied', only with evidence the API write never happened.
```

`applied` advances the saved basis once; `not_applied` permits a new token for the outstanding change. Repeating the same outcome returns `duplicate`; attempting to change a resolved outcome fails. Re-read current orders/stock before resuming. Partial refunds, ambiguous mappings, unknown locations, unexplained negative stock and unsupported variation-pause evidence remain review cases.

For a SQL regression, pause Commercial Sync and all competing stock writers first. Keep Ecwid's finite-stock native checkout handling and already-accepted orders intact. Resolve pending API outcomes, then restore only the saved functions:

```bash
sudo docker exec -i mushroomprocess-bridge-postgres sh -ec \
  'exec psql -X -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"' \
  < schema/pgsql/rollback/058_ecwid_shared_inventory.sql
```

Expected `COMMIT`; it refuses changed later function definitions and unresolved receipts. Additive specifications, receipts and backups remain for audit; no physical/order data is reverted. Do not restore the whole database over later sales or replay old stock quantities. Keep the old absolute publisher paused after rollback; use reviewed manual finite-stock corrections until the defect is fixed. Reimport the privately backed-up workflow only while paused. A full database restore is a separate recovery decision, not this rollback procedure.

## Verification record

Local native PostgreSQL 16 verified installation without 054–057, shared reservation/disabled-alias behavior, SKU/size/recipe/strain/location/date exclusions, native sale and MP shipment accounting, replenishment/refund deltas, unknown-outcome refusal and scoped rollback. Additional checks run against the installed 054 intake in a disposable database. November 21 export preview results above are reproducible historical evidence; hosted quantities and API publication remain owner checks. CI results and the exact reviewed commit are linked from the standalone inventory PR.
