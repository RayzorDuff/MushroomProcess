# Shared inventory: Woo fulfillment and cutover ownership

This draft follow-up closes the compatibility gap between merged Ecwid migration 058 and Woo fulfillment migrations 054–057. Count, reserve, pick and dispatch now use the same size/recipe/strain/lifecycle/location specification. A generic 5 lb CVG Lot or its packaged Product can fulfill the corresponding legacy Item listing; a 2.5 lb unit or wrong recipe cannot. Packing still leaves physical stock unchanged; dispatch moves it and creates the acknowledgment atomically. Replays retain the same movement and destination receipts.

## Preserve the working Ecwid deployment

The owner verified migration 058 COMMIT, first Coco delta +4, finite readback 4 and an applied receipt. Coco was re-enabled and the sale remained pending at handoff. The revised Commercial Inventory Sync manual run returned `unchanged` for ecommerce 1 with no errors; the other 23 listings required baseline review. These observations do not prove a new sale or fulfillment. Keep the deployed Ecwid workflow and source quantities unchanged during development. The owner enabled that revised schedule and archived the legacy Ecwid sync. Uninitialized listings remain excluded. Two of the sale’s lots were subsequently made into Products in MP; payment may be cash and remains unconfirmed. Packaging must replace its origin Lot in availability without releasing an outstanding order hold or recording dispatch. No live Ecwid receipt may be reset for Woo testing.

## Merge and test dependencies

Merge MP #115 → #116 → #117 → this follow-up, retaining merged main/#118 inventory work. Their source branches carry the current main inventory changes; those merges preserve the existing production Appsmith/Ecwid fixes. RootedOps's matching publisher follow-up follows #124. Keep Woo hooks, payment posting, stock publisher and this workflow disabled until their hosted preflight and approved-owner-order acceptance pass.

Fresh disposable rebuild: apply migrations in numeric order through 059. CI must test 058 standalone without 054–057, plus full Product/Lot fulfillment and shared-pool regression tests. Production already has 058; do not re-run all migrations or reapply 058 after replacing intake functions. After approved deployment/backups and schema preflight, apply the missing Woo prerequisites and 059 only. Confirm actual installed signatures before each step; stop if a prerequisite is partially installed or its definition differs from the reviewed source.

Run on the production Linode in the agreed MP deployment window, from the approved MushroomProcess checkout, after confirming 054–057 are absent and 058 is installed. This changes schema/functions, not existing stock quantities, domain routing or checkout flags:

```bash
(
  set -eu
  for migration in \
    054_commerce_operational_bridge.sql \
    055_commerce_atomic_shipment.sql \
    056_commerce_pack_dispatch.sql \
    057_commerce_lot_dispatch.sql \
    059_commerce_shared_pool_fulfillment.sql; do
    sudo docker exec -i mushroomprocess-bridge-postgres sh -ec \
      'exec psql -X -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"' \
      < "schema/pgsql/$migration"
  done
)
```

Success: each transaction commits. Stop on any error; do not blindly rerun non-idempotent 056/057. Record which migrations committed and inspect installed objects to resume. 058's independent Ecwid functions/baselines remain installed; 059 restores the shared reservation predicate in the newly deployed Woo intake without downgrading other intake behavior. Existing physical inventory, customer links, orders and receipts remain intact. No service restart is needed for SQL function replacement itself.

## Hosted rehearsal

Use fictitious/synthetic approved fixtures and the existing production ERP pairing, with public Woo checkout restricted. Prove a linked generic-item Product and a whole Lot are counted, reserved, picked and dispatched through the same pool. Prove wrong size/recipe refusal, partial shipment, replay and cancellation of unshipped holds. Label purchase must not dispatch products or move MP stock. Use the existing RootedOps runbook for ERP/Clover/label/service gates. Do not use today's pending Ecwid sale as a Woo fixture.

## Read-only publication-owner preview

The lowest-priority-number primary listing owns publication for a shared pool. Existing Ecwid rows usually retain ownership; sending Woo zero stock because it is a nonowner is not an acceptable launch procedure. RootedOps now refuses that publication instead. The preview below changes nothing:

```bash
sudo docker exec -i mushroomprocess-bridge-postgres sh -ec \
  'exec psql -X -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"' <<'SQL'
SELECT e.nocopk AS mp_ecommerce_id,e.provider,e.site_key,e.external_product_id,
 e.external_variation_id,e.external_sku,s.pool_key,s.is_owner,
 n.available_quantity
FROM public.ecommerce e JOIN public.mp_inventory_specs() s ON s.ecommerce_id=e.nocopk
LEFT JOIN public.mp_commerce_inventory() n USING(ecommerce_id)
WHERE e.provider='woocommerce' ORDER BY e.nocopk;
SQL
```

Success: exact reviewed Woo site `danks.store` (logical identity), numeric Woo IDs/SKUs, distinct source pools and known current owner. The transport origin is the canonical `https://dankmushrooms.net`; retain existing customer route/store key `shop-test.danks.store`. The hostname change is the same installation, with no customer/order reimport. A missing or review-only specification is a stop point.

## Explicit ownership transfer — cutover only

Before this production write: pause Ecwid checkout and all competing stock writers for the pool, restrict public Woo checkout, reconcile accepted orders/holds, verify no pending Ecwid API receipt, and approve the exact MP Woo mapping in the private worker configuration. Preserve existing Ecwid/Woo product IDs. Do not transfer ownership while today's Ecwid checkout remains live.

Run one reviewed pool at a time. These prompts request MP ecommerce record IDs, not Woo product IDs:

```bash
read -r -p 'Reviewed MP Woo ecommerce ID: ' WOO_ECOMMERCE_ID
read -r -p 'Current owner MP ecommerce ID: ' CURRENT_OWNER_ID
[[ "$WOO_ECOMMERCE_ID" =~ ^[1-9][0-9]*$ ]]
[[ "$CURRENT_OWNER_ID" =~ ^[1-9][0-9]*$ ]]
sudo docker exec -i mushroomprocess-bridge-postgres sh -ec \
  'exec psql -X -v ON_ERROR_STOP=1 -v woo="$1" -v owner="$2" -U "$POSTGRES_USER" -d "$POSTGRES_DB"' \
  sh "$WOO_ECOMMERCE_ID" "$CURRENT_OWNER_ID" <<'SQL'
SELECT public.mp_commerce_select_woo_inventory_owner(:'woo'::bigint,:'owner'::bigint) AS owner_receipt;
SQL
```

Success: one durable UUID receipt, Woo becomes the sole owner, and original flags are saved. The function changes only the relevant primary-listing flags; it does not alter enable flags, physical stock, reservations, external IDs or accounting. Changed owner, pending API write, wrong provider/site or incomplete mapping aborts the transaction. Save the receipt privately for rollback.

Repeat the read-only preview, then run RootedOps's gated stock publisher and read back exact Woo product/variation quantities before opening public checkout. It uses the pool key for deduplication and accounts for Woo's own checkout deductions/MP holds. Complete the restricted owner purchase and full lifecycle acceptance before public activation. Ecwid stays available for rollback, with checkout paused.

## Rollback

Restrict Woo checkout, pause its publisher/intake/dispatch workers and reconcile accepted orders/payments/physical movements. Restore owner flags using the recorded receipt only after new writes are stopped:

```sql
SELECT public.mp_commerce_restore_inventory_owner('RECORDED_OWNER_RECEIPT'::uuid);
```

Success `restored`, repeated call `duplicate`. The function refuses changed pool membership/specifications/flags. It preserves Woo orders and stock receipts and restores only the saved primary flags. Recalculate current available stock and reconcile the Ecwid baseline/readback before reopening Ecwid checkout; never replay the old opening quantity or a resolved API delta.

If 059 itself must be reverted, restore its active owner handoffs first and keep Woo processing paused. Apply `schema/pgsql/rollback/059_commerce_shared_pool_fulfillment.sql` with the same Docker/psql command used above. It restores only tracked function definitions, refuses later changes and retains receipts/data. Ecwid migration 058 and its active baseline are not rolled back by this step.

Owner update: no Ecwid order exists for the two newly packaged Products; if paid cash, none is expected. Preserve the unrelated earlier hold. Native regression proves packaging alone is unchanged and an unlinked MP cash-sale dispatch publishes one negative delta, then unchanged on replay.
