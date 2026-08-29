# Issue #85 R0 — Fulfillment / Clover Legacy Baseline

## Purpose

R0 freezes the current fulfillment behavior before provider-neutral payment work begins.
It intentionally makes no production behavior change.

The objective is to make the Clover -> Moov migration incremental: each later round can
change schema, n8n, or Appsmith behavior while the pre-migration fulfillment contract is
explicitly regression-tested.

## Baseline architecture

At this baseline:

- Ecwid is the external order source for the existing fulfillment pipeline.
- `ecommerce_orders` already has provider-neutral order aliases (`provider`, `site_key`,
  `external_order_id`, `external_skus`) in addition to legacy `ecwid_*` fields.
- Fulfillment payment/reconciliation state is still Clover-specific.
- Market orders are identified operationally from `payment_method` values beginning with
  `Sell on the Go`.
- Website orders become fulfillment-ready when `payment_status = PAID`.
- Market/card orders become operationally resolved when
  `clover_reconciliation_status = reconciled`.
- Cash/manual market orders can become operationally resolved with
  `clover_reconciliation_status = accounted`.
- `pending` and `needs_review` market orders are review states, with unassigned review
  orders shown only when Include Review is enabled.
- A fully assigned market order that still needs reconciliation remains visible so the
  payment side can be completed without allowing more product assignment.
- Clover-specific manual reconciliation controls remain present in Appsmith.
- Clover reconciliation poller/report workflows remain the production compatibility path.

## Existing provider-neutral foundation

`schema/pgsql/026_ecommerce_provider_neutral.sql` already provides a useful migration
foundation for order-source identity:

```text
provider
site_key
external_order_id
external_skus
```

R1 and later should build on these identities rather than add a second competing order
source abstraction.

Payment identity is the missing abstraction. The target remains to separate:

```text
sales_channel
payment_processor
processor_payment_id
processor_payment_status
payment_reconciliation_status
```

while preserving the legacy Clover fields until migration and rollback validation are
complete.

## R0 regression contract

`n8n/tests/fulfillment_order_visibility_smoke.js` exercises both fulfillment workflow
variants:

- `MushroomProcess - Fulfillment API.json`
- `MushroomProcess - Fulfillment API - PGSQL.json`

The smoke fixture now explicitly verifies:

1. paid website orders are fulfillment-ready without requiring Clover reconciliation;
2. unpaid website orders are not fulfillment-ready;
3. reconciled market orders remain visible after product assignment when reconciliation
   state requires operational visibility;
4. pending market orders are hidden unless Include Review is enabled when they are not yet
   assigned;
5. `needs_review` orders follow the same review-only behavior;
6. `accounted` cash/manual market orders are fulfillment-ready;
7. completed historical orders remain available when no explicit date filter is supplied;
8. product-assignment and reconciliation-completion flags remain distinct;
9. explicit order-date filtering remains deterministic;
10. newest-first sorting remains intact.

## Deferred to R1+

R0 does not:

- add Moov credentials or call the Moov API;
- change PostgreSQL schema;
- rename Clover fields;
- change Appsmith labels or controls;
- change n8n fulfillment endpoints;
- change reconciliation matching;
- change Ecwid order ingestion;
- disable any Clover workflow.

Those changes should begin only after this baseline passes against the production branch.
