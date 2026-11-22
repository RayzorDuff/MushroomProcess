# Cash web orders: separate receipt and accounting

Cash is a tender, not a Clover capture or a shipment. The owner reports the current Ecwid web order completed with Products assigned. Preserve that order, Products, Ecwid status and inventory receipts. Do not reassign, redispatch, create a second sale, reset the stock baseline or create a Woo copy of this historical order. Recording its actual cash receipt retrospectively is allowed after checking for existing ERP documents. A new customer needs a reviewed existing/new ERP Customer and, when appropriate, the normal Woo account-link flow; no broad Ecwid reimport.

## Independent deployment

This follows MP #120 / 060. Apply 061 to the existing mushroomprocess_bridge database after the same read-only preflight and verified backup in [the Fulfillment walkthrough](fulfillment-allocation-launch.md). It works with the existing Ecwid ledger without deploying unfinished Woo migrations. No worker, posting, stock owner or production gateway is enabled by installing it.

Linode, approved Git checkout, with new cash entry temporarily unavailable:

```bash
cd ~/mushroomprocess
sudo docker exec -i mushroomprocess-bridge-postgres sh -ec \
  'exec psql -X -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"' \
  < schema/pgsql/061_commerce_cash_receipts.sql
```

Success COMMIT; stop on an error or an unreviewed migration footprint. Preserve existing cash/dispatch receipts. Invoker functions require the reviewed n8n role to have base-table access; use `schema/pgsql/operations/061_cash_api_grants.sql` with explicit `api_role` and `worker_role` psql variables. The API role records receipt; only the trusted accounting worker may acknowledge ERP references. Never give the webhook receiver a processor verifier or cash-posting credential.

## Owner connections (n8n/Appsmith)

Create an n8n **Header Auth** credential named MP Cash Operator with header `X-MP-Cash-Token` and a private random token (at least 32 bytes). Import the inactive Git `MushroomProcess - Cash Receipts - PGSQL.json`, selecting that credential and the existing MP PostgreSQL credential. Do not activate it without authentication. No token belongs in Git, browser JS or Appsmith store.

Reimport the revised Git **Fulfillment API - PGSQL** over its existing workflow; it reads receipt state and retires the unsafe legacy Mark Accounted path. Keep the Airtable/reference API inactive. Do not change the active Commercial Inventory Sync or archived legacy stock writer.

Render the scoped Appsmith export using `python3 scripts/render_fulfillment_ui.py --output PRIVATE_PATH`. It adds the private datasource `mushroomprocess-cash-n8n` at the existing internal n8n URL. In Appsmith's server-side datasource editor, set the matching `X-MP-Cash-Token` header. Retain it privately on later imports; rendering a source export containing this datasource preserves its connection. Publish after a synthetic receipt test. A blank credential must fail closed; stop if the endpoint accepts an unauthenticated request.

## Operator flow

1. Select the cash web order. It can be packed while cash is still due. Empty product search and scanning use 060's eligibility and allocation validation; assignment does not mark paid or move stock.
2. Prepare any label separately. Pickup/local delivery require no postal label.
3. **Only when cash actually arrives**, enter the exact full amount, check Cash has actually been received and choose Record Cash Received. Currency comes from the stored order. The protected endpoint records source identity, amount, currency, timestamp, named operator and immutable commercial snapshot. A repeated click returns the same UUID. Partial/split tender, wrong amount, missing currency, cancelled/refunded orders or commercial drift require review.
4. The receipt initially says ERP pending. It does not say accounted merely because Products are linked. The separately enabled RootedOps cash worker validates reviewed item/customer/tax/account mapping and creates/reuses one ERP sale, invoice and Payment Entry. MP records those references only after ERP commits. A timeout retries the same receipt; it must not create new cash or processor evidence.
5. Confirm MP dispatch at physical departure/handover, using the same reference on a retry. Do not repeat this for the already completed order. Existing Ecwid fulfillment/status operation stays in place; after the Woo cutover, the reviewed Woo package flow delivers committed acknowledgments to ERP and Woo.

Cash in ERP is a reviewed cash-on-hand/undeposited-funds account. A later bank deposit is a separate transfer/reconciliation, not another sale or payment from the customer. No physical drawer is required. Clover clearing, fees and settlements remain separate.

## Woo extension — only after 054–059 are installed and tested

The existing Woo interface originally lists only confirmed paid reservations. The Git renderer below adds pending cash orders to that view, preserves selected Woo order identity on refresh, shifts the Woo section below the legacy cash controls, and adds the protected cash receipt action. It changes no route credentials or identity keys. Inspect source JSON before import; unknown list-query/layout changes fail closed.

Linode, approved merged source and private output directory:

```bash
cd ~/mushroomprocess
umask 077
python3 scripts/prepare_cash_woo.py \
  --woo-workflow 'n8n/workflows/MushroomProcess - Woo Pack and Dispatch - PGSQL.json' \
  --woo-overlay appsmith/commerce_fulfillment_overlay.json \
  --output-dir "$HOME/commerce-migration/cash-woo"
```

Then, **only after installed signatures confirm 059**, allow unpaid cash packing (not dispatch):

```bash
sudo docker exec -i mushroomprocess-bridge-postgres sh -ec \
  'exec psql -X -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"' <<'SQL'
SELECT public.mp_commerce_prepare_cash_packing();
SQL
```

Success: checked replacement of Product and Lot packing admission, originals saved for rollback. Stop on unknown definitions or missing prerequisites. Use the rendered inactive Woo workflow to update its existing instance; import the rendered Appsmith bundle once, retaining both private datasources. No manual editing of workflow JS/SQL is required.

RootedOps must explicitly enable reviewed `cod` cash intake, cash accounting and `ROOTEDOPS_MP_CASH_ENABLED`. Cash proof never calls Clover. After ERP posting, its worker projects the same receipt to Woo and sets processing (not completed), letting native Woo emit its signed update. MP confirmation waits for that active snapshot and durable ERP references. Packing before payment moves nothing; dispatch before receipt/accounting is refused. A paid-snapshot delay is visible and retried, with no repeated invoice/payment or Woo notification. Partial dispatch keeps Woo open; only full MP dispatch completes it.

## Tests, acceptance and rollback

Disposable SQL proves exact full receipt, post-delivery cash recording, duplicate UUID, no implicit payment, drift/refund refusal, ERP reference recovery, unpaid Woo packing, dispatch refusal before accounting, native paid-snapshot ordering, partial/repeated dispatch and cancellation release. Scoped UI tests prove separate confirmation and retained order. Native ERP/WordPress posting evidence belongs to the paired RootedOps PR; CI is not production deployment.

Hosted acceptance needs one synthetic cash order before enabling real cash posting. No real receipt is required for testing. Verify missing Header Auth fails; Pack does not create a receipt; explicit synthetic receipt stays ERP pending until approved; replay yields the same UUID and references. Confirm account/company/currency and native tax configuration privately. Keep the completed real sale untouched until existing ERP documents and actual cash receipt are reviewed.

Rollback: disable new cash entry and its worker/gateway flags, preserve receipts, stop if any real receipt is unacknowledged. `schema/pgsql/rollback/061_commerce_cash_receipts.sql` restores only checked saved Woo packing definitions, drops entry/ack helpers and retains cash/ERP history. Restore workflow/Appsmith together. It refuses later function changes or pending cash; do not delete a real receipt to bypass it. A payment refund and physical return require separately reviewed reversals; neither is automatic.
