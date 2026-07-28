# RC4 N8N Workflow Test Procedure

Repository: `MushroomProcess`  
Release target: `v1.1.0-RC4`  
Suggested test run ID: `RC4-N8N-20260630`

This procedure validates the N8N workflows that replace or support Airtable-era integrations during the Appsmith/Postgres migration.

The workflow tests are ordered from lowest risk to highest risk:

1. Read-only/list endpoints
2. Reversible product state changes
3. Appsmith/SignatureGate end-to-end calls
4. Fulfillment API mutation tests
5. External-side-effect workflows such as Clover reconciliation and report emails

Do not start with Clover live reconciliation or production report emails until the read-only and reversible product tests pass.

---

## 1. Common setup for all N8N workflow tests

For each workflow:

1. Open the imported PGSQL workflow in N8N.
2. Confirm all data nodes point to the intended target:
   - MushroomProcess workflows should point to the MushroomProcess Postgres/PGSQL target.
   - SignatureGate workflows should point to the SignatureGate Postgres target and, where applicable, the MushroomProcess Postgres inventory endpoint.
3. Confirm no Airtable credential/node is still active in the execution path.
4. Use the **Test URL** from the Webhook node first.
5. Run with the N8N execution view open.
6. After a successful test execution, activate the workflow and repeat once through the **Production URL**.
7. Record the following in the RC4 test matrix:
   - Workflow name
   - N8N execution ID
   - Request payload
   - Response body
   - Before/after SQL snapshots
   - Whether any Airtable node executed

Any test where an Airtable node executes should remain **failed** for RC4.

Use this test run identifier in payload notes and SQL snapshots:

```text
RC4-N8N-20260630
```

---

## 2. SignatureGate - PGSQL - List Available Sacrament Products

This validates the replacement for the Airtable-era workflow:

```text
SignatureGate - Airtable - List Available Sacrament Products
```

### 2.1 Direct N8N test

Open the N8N workflow:

```text
SignatureGate - PGSQL - List Available Sacrament Products
```

Click **Execute workflow**, then call the Webhook **Test URL**.

Use the actual Webhook path from the workflow. If the route retained the old path for Appsmith compatibility, it may resemble:

```text
/webhook-test/signaturegate/airtable/list_available_sacrament_products
```

If renamed for PGSQL, it may resemble:

```text
/webhook-test/signaturegate/pgsql/list_available_sacrament_products
```

Call the endpoint:

```bash
curl -sS "$N8N_TEST_URL" | jq .
```

### 2.2 Expected response

Pass if the response:

- Returns HTTP 200.
- Returns an array/list of available sacrament products.
- Uses MushroomProcess/Postgres product identifiers, preferably `product_id` values such as `PROD-...`.
- Does not expose Airtable record IDs as primary identifiers.
- Does not include shipped, consumed, retired, empty tray, or unavailable products.
- Includes enough display fields for the SignatureGate/Appsmith release issue UI:
  - `product_id`
  - item/name/title
  - package size or net weight
  - strain/species where applicable
  - storage/location/status

### 2.3 MushroomProcess database cross-check

Compare the response to `vc_products`.

```sql
select
  product_id,
  item_id,
  name,
  item_category_mat,
  net_weight_g,
  package_size_g,
  package_count,
  storage_location,
  tray_state,
  origin_strain_regulated,
  notes
from vc_products
where coalesce(storage_location, '') not in ('Shipped', 'Consumed', 'Retired', 'Compost', 'Spoiled')
  and coalesce(tray_state, '') not in ('empty_tray')
order by product_id desc
limit 50;
```

Pass only if the N8N response is explainable from the PGSQL result set.

### 2.4 SignatureGate Appsmith test

In **Rooted Psyche Membership Ops**, temporarily point the product inventory API call to this PGSQL workflow.

Open the Release/Issue workflow that lists available sacrament products.

Pass if:

- Product list loads.
- Same products appear as the direct N8N response.
- No Airtable endpoint is called.
- No browser/API error appears.

---

## 3. SignatureGate - PGSQL - Mark Product Shipped

This validates the replacement for the Airtable-era workflow:

```text
SignatureGate - Airtable - Mark Product Shipped
```

Use a product returned by the previous list endpoint. Pick a disposable/test-safe product.

### 3.1 Before snapshot

```sql
select
  product_id,
  item_id,
  name,
  item_category_mat,
  storage_location,
  tray_state,
  ecommerce_orders,
  events,
  notes
from vc_products
where product_id = 'PROD-REPLACE-ME';
```

Check related events:

```sql
select
  event_id,
  product_id,
  type,
  timestamp,
  operator,
  station,
  fields_json
from vc_events
where product_id = 'PROD-REPLACE-ME'
order by timestamp desc nulls last, event_id desc;
```

### 3.2 Direct N8N test

Use the workflow Webhook Test URL and the same payload shape expected by the current SignatureGate Appsmith API call.

The payload should include at least the product identifier and test context. Use the exact field names expected by the workflow/Appsmith API body, but conceptually:

```json
{
  "product_id": "PROD-REPLACE-ME",
  "release_id": "RC4-N8N-20260630",
  "member_id": "RC4-N8N-TEST-MEMBER",
  "operator": "ray@edanks.com",
  "notes": "RC4-N8N-20260630 mark shipped test"
}
```

Pass if:

- HTTP 200 is returned.
- Response says one product was updated.
- Response includes `product_id`.
- Product is no longer returned by **List Available Sacrament Products**.
- Product storage/status now reflects `Shipped` or the equivalent shipped terminal state.
- No Airtable node executes.

### 3.3 After snapshot

```sql
select
  product_id,
  storage_location,
  tray_state,
  ecommerce_orders,
  events,
  notes
from vc_products
where product_id = 'PROD-REPLACE-ME';
```

Inspect events/audit:

```sql
select
  event_id,
  product_id,
  type,
  timestamp,
  operator,
  station,
  fields_json
from vc_events
where product_id = 'PROD-REPLACE-ME'
order by timestamp desc nulls last, event_id desc
limit 10;
```

If no product event is created, note that separately. This may overlap conceptually with product-state event logging work, but the RC4 issue should distinguish SignatureGate shipped/unshipped behavior from Products page tray terminal actions unless deliberately combined.

---

## 4. SignatureGate - PGSQL - Mark Product UnShipped

This is the reversal test for the same product used in the shipped test.

### 4.1 Direct N8N test

Use the Mark Product UnShipped workflow Test URL.

Payload conceptually:

```json
{
  "product_id": "PROD-REPLACE-ME",
  "release_id": "RC4-N8N-20260630",
  "member_id": "RC4-N8N-TEST-MEMBER",
  "operator": "ray@edanks.com",
  "notes": "RC4-N8N-20260630 mark unshipped test"
}
```

Pass if:

- HTTP 200 is returned.
- Response says one product was updated.
- Product returns to available storage/status.
- Product appears again in **List Available Sacrament Products**, if it is otherwise eligible.
- No duplicate product is created.
- No Airtable node executes.

### 4.2 After snapshot

```sql
select
  product_id,
  storage_location,
  tray_state,
  ecommerce_orders,
  events,
  notes
from vc_products
where product_id = 'PROD-REPLACE-ME';
```

Run the unship workflow **a second time** with the same payload.

Pass idempotency if the second run either:

- Returns a clean `already unshipped` / `no change` response.
- Returns success with zero rows changed.

Fail if it creates duplicate events, duplicate orders, or corrupts product state.

---

## 5. SignatureGate Appsmith end-to-end inventory API test

Run this only after the direct N8N SignatureGate tests pass.

### 5.1 Test path

1. In **Rooted Psyche Membership Ops**, point the product inventory APIs to the PGSQL N8N endpoints.
2. Open the Release Issue flow.
3. Select a test member/facilitator.
4. Load available sacrament products.
5. Select the same disposable product.
6. Run the issue/release path that marks the product shipped.
7. Run the void/cancel/unship path that marks it unshipped.

Pass if:

- Product list loads from PGSQL.
- Issue/release marks the selected product shipped.
- Product disappears from the available list.
- Void/cancel marks the selected product unshipped.
- Product becomes available again.
- SignatureGate audit/release records remain coherent.
- MushroomProcess product state matches the UI.

Fail if Appsmith still calls an Airtable URL, if the list is stale, or if shipped/unshipped changes are not reversible.

---

## 5A. MushroomProcess - Ecwid Order Updated - PGSQL

This workflow replaces the Airtable-backed Ecwid order intake workflow while retaining the existing webhook route:

```text
mushroomprocess/ecwid/order_updated
```

Before testing, import:

```text
n8n/workflows/MushroomProcess - Ecwid Order Updated - PGSQL.json
```

Confirm:

- The workflow imports **inactive**.
- `PGSQL - Upsert Ecwid Order` uses the MushroomProcess PostgreSQL credential.
- No Airtable node, Airtable credential, or Airtable environment variable exists in the workflow.
- The Airtable-backed workflow is inactive before the PGSQL workflow is activated because both workflows use the same webhook path.
- `ECWID_STORE_ID` and `ECWID_SECRET_TOKEN` are available to n8n.

### 5A.1 Install and smoke-test the PostgreSQL function

```bash
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 \
  -f nocodb_schema/pgsql/012_ecommerce_order_upsert.sql

psql "$DATABASE_URL" -v ON_ERROR_STOP=1 \
  -f nocodb_schema/pgsql/tests/012_ecommerce_order_upsert_smoke.sql
```

Expected:

```text
NOTICE:  Ecwid PostgreSQL create/update, retry idempotency, reconciliation reset, and duplicate-data guard smoke tests passed.
```

Run the workflow structure test:

```bash
node n8n/tests/ecwid_order_updated_pgsql_smoke.js
```

Expected:

```text
Ecwid Order Updated PGSQL workflow structure, filtering, mapping, and payload smoke tests passed.
```

### 5A.2 Before snapshot

Choose an actual Ecwid order whose current payment status is `AWAITING_PAYMENT`. Record its numeric Ecwid API order ID and human-facing order code.

```sql
select
  nocopk,
  ecwid_order_id,
  order_code,
  name,
  status,
  payment_status,
  order_total,
  currency,
  ecwid_event_type,
  ecwid_event_id,
  last_webhook_at,
  clover_reconciliation_status,
  clover_payment_id,
  reconciled_at
from public.ecommerce_orders
where ecwid_order_id = 'REPLACE-WITH-ECWID-ENTITY-ID';
```

### 5A.3 Processed webhook test

Use the workflow Test URL and substitute the actual Ecwid values. `eventCreated` is a Unix timestamp in seconds.

```bash
curl -sS -X POST "$N8N_TEST_URL" \
  -H 'Content-Type: application/json' \
  -d '{
    "eventId": "RC5-N8N-ECWID-001",
    "eventCreated": 1785175200,
    "storeId": REPLACE_WITH_STORE_ID,
    "eventType": "order.updated",
    "entityId": REPLACE_WITH_NUMERIC_ECWID_ORDER_ID,
    "data": {
      "orderId": "REPLACE_WITH_ORDER_CODE",
      "oldPaymentStatus": "PAID",
      "newPaymentStatus": "AWAITING_PAYMENT"
    }
  }' | jq .
```

Pass if:

- HTTP 200 is returned.
- `processed` is `true`.
- `action` is `created` or `updated`.
- `ecwid_order_id` matches the numeric Ecwid API order ID.
- `postgres_record_id` is returned.
- Exactly one `ecommerce_orders` row exists for that `ecwid_order_id`.
- Order/customer/item/totals fields match the Ecwid API response.
- `clover_reconciliation_status` is `pending` and prior reconciliation fields are cleared, matching the Airtable workflow behavior for a newly awaiting-payment order.
- No Airtable node executes.

### 5A.4 Retry/idempotency test

Send the exact same webhook payload again.

Pass if:

- The response is successful.
- `action` is `updated`.
- The same `postgres_record_id` is returned.
- The database still contains exactly one row for the Ecwid order.
- No duplicate order or product links are created.

```sql
select ecwid_order_id, count(*)
from public.ecommerce_orders
where ecwid_order_id = 'REPLACE-WITH-ECWID-ENTITY-ID'
group by ecwid_order_id;
```

### 5A.5 Ignored webhook test

Send an update that does not newly enter `AWAITING_PAYMENT`:

```json
{
  "eventId": "RC5-N8N-ECWID-IGNORED",
  "eventCreated": 1785175200,
  "storeId": 123,
  "eventType": "order.updated",
  "entityId": 900001,
  "data": {
    "orderId": "ABCD1",
    "oldPaymentStatus": "PAID",
    "newPaymentStatus": "PAID"
  }
}
```

Pass if:

- HTTP 200 is returned.
- `processed` is `false`.
- The Ecwid order lookup and PostgreSQL upsert nodes do not execute.
- No database row changes.

## 6. MushroomProcess - Fulfillment API - PGSQL

This validates the N8N backend for the MushroomProcess Fulfillment page / Move-Ship Products row.

### 6.1 Direct N8N list/read test

Open the workflow:

```text
MushroomProcess - Fulfillment API - PGSQL
```

Run the Webhook Test URL.

First perform a read/list action. Use the workflow expected query/body.

Example GET-style request:

```bash
curl -sS "$N8N_TEST_URL?action=list_ready" | jq .
```

Example POST-style body:

```json
{
  "action": "list_ready",
  "testRunId": "RC4-N8N-20260630"
}
```

Pass if:

- HTTP 200 is returned.
- Response contains product/order rows expected by Fulfillment.
- Product identifiers match PGSQL `product_id` values.
- No Airtable node executes.

### 6.2 Cross-check query

```sql
select
  product_id,
  item_id,
  name,
  item_category_mat,
  storage_location,
  tray_state,
  ecommerce_orders,
  notes
from vc_products
where storage_location in ('Fulfillment', 'Products Storage')
order by product_id desc
limit 50;
```

### 6.3 Mutation test

Only after list/read passes, run a reversible or low-risk mutation such as mark fulfilled, ship, or unship depending on the workflow design.

Pass if:

- Exactly one selected product/order changes.
- Response includes affected count.
- Rerunning the same request is idempotent.
- Appsmith Fulfillment page reflects the change after refresh.
- No Airtable node executes.

This test likely touches the Fulfillment visibility/state issue if the Fulfillment page does not reflect PGSQL state. It does not touch the Print Queue page unless print queue UI behavior is involved.

---

## 7. MushroomProcess - Clover Payment Reconciliation Poller - PGSQL

Treat this as higher risk because it may touch payment/order reconciliation state.

### 7.1 Test A — dry-run empty window

Set the workflow to PGSQL target and dry-run/test mode if the workflow supports it.

Use a date window where no Clover payments are expected.

Example conceptual input:

```json
{
  "mode": "dry_run",
  "from": "2026-06-30T00:00:00-06:00",
  "to": "2026-06-30T00:05:00-06:00",
  "testRunId": "RC4-N8N-20260630"
}
```

Pass if:

- Workflow completes.
- Response/report says zero payments or zero reconciliations.
- No database mutation occurs.
- No Airtable node executes.

### 7.2 Test B — dry-run known payment window

Use a narrow known payment/reconciliation date range.

Pass if:

- Workflow finds the expected payment/order candidates.
- Totals match Clover/workflow output.
- Dry run does not mutate PGSQL.
- No Airtable node executes.

### 7.3 Test C — live idempotency test

Only after Test A and Test B pass, run live mode for one known payment/order.

Then run the exact same live window again.

Pass if:

- First live run updates exactly the expected reconciliation row/order/payment state.
- Second live run does not duplicate records.
- Second live run reports zero new changes or a clean already-reconciled state.
- No Airtable node executes.

Fail if duplicate reconciliation rows, duplicate order links, or inconsistent paid/shipped state appear.

---

## 8. MushroomProcess - Daily Reconciliation Report Email + PDF - PGSQL

Test this after the poller read/dry-run succeeds.

### 8.1 Configure test recipient

Before running, change the email recipient to yourself only and add a subject prefix:

```text
[RC4 N8N TEST] Daily Reconciliation Report
```

Use a narrow fixed date range.

Conceptual input:

```json
{
  "mode": "test",
  "from": "2026-06-30T00:00:00-06:00",
  "to": "2026-06-30T23:59:59-06:00",
  "recipient": "ray@edanks.com",
  "subjectPrefix": "[RC4 N8N TEST]",
  "testRunId": "RC4-N8N-20260630"
}
```

Pass if:

- Workflow completes.
- Email is received by the test recipient only.
- PDF is attached.
- Report totals match PGSQL query/report output.
- No Airtable node executes.
- No production recipients receive the test.

Run a second empty-window report.

Pass if it still sends or cleanly reports zero rows without error, depending on intended behavior.

---

## 9. MushroomProcess - Clover Payment Reconciliation Webhook (Inactive)

Do not test the inactive Clover webhook as a functional workflow.

Validation should be limited to:

- Workflow remains inactive.
- No Appsmith/N8N production route depends on it.
- No RC4 live-pilot path requires it.

Do not mark this as failed if it is intentionally unused. Mark it as:

```text
N/A / inactive / not in RC4 pilot scope
```

---

## 10. Matrix pass/fail rules

| Matrix row | Pass condition |
|---|---|
| SignatureGate - PGSQL - List Available Sacrament Products | Direct N8N response matches PGSQL products and SignatureGate Appsmith product list loads from PGSQL. |
| SignatureGate - PGSQL - Mark Product Shipped | Direct N8N and SignatureGate UI both mark one product shipped, remove it from available list, and avoid Airtable. |
| SignatureGate - PGSQL - Mark Product UnShipped | Direct N8N and SignatureGate UI both restore product availability, are idempotent, and avoid Airtable. |
| MushroomProcess - Ecwid Order Updated - PGSQL | Newly awaiting-payment Ecwid orders are created or updated in PostgreSQL, retries remain single-row, ignored events do not mutate data, and no Airtable node executes. |
| MushroomProcess - Fulfillment API - PGSQL | Fulfillment list/read works from PGSQL and any tested mutation updates exactly the intended product/order. |
| Clover Payment Reconciliation Poller - PGSQL | Dry-run empty and known windows pass; live run is idempotent if tested. |
| Daily Reconciliation Report Email + PDF - PGSQL | Test email/PDF goes only to test recipient, totals match PGSQL, and no Airtable executes. |
| Clover Payment Reconciliation Webhook inactive | N/A if intentionally inactive and unused. |

---

## 11. Issues to update based on results

Update related issues only when a workflow test directly touches the issue scope.

- Update the Fulfillment visibility/state issue if the Fulfillment page visibility or product availability is wrong after the PGSQL Fulfillment API test.
- Update product-state event logging issues only if shipped/unshipped or Fulfillment mutations are expected to create product events and do not.
- Update freeze-dried package size/class issues only if SignatureGate product listing exposes package-size/package-class problems from freeze-dried products.
- Create a new issue if any imported PGSQL N8N workflow still executes Airtable nodes or requires Airtable IDs.

---

## 12. Optional risk-accepted RC4 matrix language

Use this language if the N8N workflows are not directly tested before switchover.

```text
Ready for Live pilot: Conditional / Monitored pilot only.

Expected Deviations: PGSQL N8N workflows are imported but not directly execution-tested in RC4. Underlying Postgres views/functions used by Appsmith have been broadly tested, but webhook payload shape, production URL routing, N8N credentials, idempotency, and external side effects remain unverified.

Issues Logged/Updated/Closed: No new issue solely for skipped N8N validation unless a workflow fails at switchover. Keep related fulfillment/product-state issues open as applicable.

Notes: Risk accepted for RC4 switchover. Monitor first live executions closely. Prefer manual verification of affected Product/Event rows after first SignatureGate ship/unship and first Fulfillment/Clover/report execution.
```
