# MushroomProcess – n8n Workflows

This directory contains all n8n workflows used to orchestrate integrations between:

- Ecwid (order source)
- Clover (payment processor)
- Airtable (temporary operational datastore)
- Future: PostgreSQL / NocoDB (primary datastore)
- Appsmith (UI layer via API endpoints)

---

## 🧠 Architecture Overview

Appsmith → n8n → Airtable (current)  
Appsmith → n8n → PostgreSQL (future)

n8n acts as:
- API layer for Appsmith
- Integration layer for Ecwid + Clover
- Reconciliation engine
- Reporting engine

---

## 📊 Current Workflows

### 1. Ecwid → Airtable Sync (existing)
**Source:** `integrations/ecwid`
- Syncs orders, products, customers into Airtable
- Populates:
  - `ecommerce_orders`
  - `items_json`
  - `payment_status`
  - `products` (initially empty)

---

### 2. Clover Reconciliation Poller

The Clover reconciliation workflow:

1. Retrieves pending market orders from Airtable.
2. Retrieves Clover payments within a configurable time window.
3. Attempts automatic reconciliation using:
   - payment amount
   - timestamp proximity
   - tender type
4. Prevents reuse of Clover payment IDs already reconciled.
5. Flags unresolved orders for review.

#### Reconciliation States

| State | Meaning |
|---|---|
| reconciled | Clover payment matched automatically or manually |
| pending | No valid Clover payment found |
| needs_review | Multiple or ambiguous candidate payments |
| accounted | Manually resolved without Clover reconciliation |

#### Manual Reconciliation Actions

The Fulfillment interface supports:

##### Mark Cash / Accounted

Used for:
- cash market sales
- offline/manual transactions
- administrative overrides

##### Manual Match Clover Payment

Used when:
- duplicate payment amounts exist
- multiple Clover candidates exist
- operator confirmation is required

---

### 3. Daily Reconciliation Report
- Generates:
  - plain text report
  - PDF attachment
- Includes:
  - reconciled orders
  - unreconciled orders
  - unmatched Clover payments
  - Ecwid product tally
- Sends via email

---

### 4. Fulfillment API

The `MushroomProcess - Fulfillment API` workflow provides operational fulfillment services to the Appsmith interface.

#### Responsibilities

The workflow handles:

- fulfillment-ready order listing
- order detail retrieval
- inventory product search
- product assignment
- Clover reconciliation review
- manual reconciliation actions
- inventory state transitions

#### Fulfillment Order States

##### Website Orders

Website orders become fulfillment-ready when:

```text
payment_status = PAID
```

##### Market Orders

Market (`Sell on the Go`) orders become fulfillment-ready when:

```text
clover_reconciliation_status = reconciled
```

##### Reviewable Orders

Orders may remain visible in review mode when:

```text
clover_reconciliation_status IN ('pending', 'needs_review')
```

##### Accounted Orders

Cash/manual market orders may be resolved using:

```text
clover_reconciliation_status = accounted
```

This state indicates:
- payment handled manually
- no Clover card reconciliation required
- operationally resolved

#### Fulfillment Product Search

The fulfillment workflow excludes products located in:

- Shipped
- Consumed
- Compost
- Expired

This prevents reassignment of inventory already completed or discarded.

#### Fulfillment Assignment

When a product is assigned:

1. Product is linked to the ecommerce order.
2. Product storage location is updated to `Shipped`.
3. Duplicate assignment is prevented.

#### Endpoints for Appsmith:

##### `/fulfillment/orders/list`
Returns:
- fulfillment-ready orders needing product assignment
- fully assigned market orders that still need reconciliation
- completed orders for audit/history when no order-date filter is supplied
- supports:
  - farmers market orders
  - website orders (paid)
  - optional review inclusion for unassigned pending/needs-review market orders

##### `/fulfillment/order/detail`
Returns:
- full order detail
- parsed `items_json`

##### `/fulfillment/products/search`
Search available products by:
- `product_id`
- filters out shipped inventory

##### `/fulfillment/assign-product`
- links product → order
- moves product → `Shipped` location

---

## ⚠️ Key Rules

### ❌ DO NOT set Ecwid orders to PAID via API
- Causes duplicate Clover "External Payment"
- Clover is the source of truth for payments

### ✅ Payment Truth Model
- Clover = payment system of record
- Ecwid = order capture
- Airtable = reconciliation + fulfillment (temporary)

---

## 🔄 PostgreSQL replacements for Airtable nodes

These workflows duplicate the Airtable-backed workflows listed in MushroomProcess issue #37 and replace Airtable HTTP API nodes with n8n PostgreSQL nodes.

Generated workflows:

- `MushroomProcess - Clover Payment Reconciliation Poller - PGSQL.json`
- `MushroomProcess - Fulfillment API - PGSQL.json`
- `MushroomProcess - Daily Reconciliation Report Email + PDF - PGSQL.json`

The inactive `MushroomProcess - Clover Payment Reconciliation Webhook` was not duplicated because issue #37 explicitly marks it as `No Implementation - Not Used`.

## Import notes

1. Import the JSON files into n8n.
2. Assign your PostgreSQL credential to each `PGSQL - ...` node.
3. Keep the original Airtable workflows inactive during validation, or use distinct webhook paths before switching Appsmith/webhook callers.
4. Validate with non-production data first.

## Compatibility notes

The PGSQL nodes intentionally return Airtable-shaped JSON where downstream code expects Airtable responses, for example:

- list queries return `{ records: [{ id, fields }] }`
- detail/update queries return `{ id, fields }`

This minimizes workflow churn while removing Airtable API dependencies.


---

## 🧪 Environment Variables

```bash
AIRTABLE_BASE_ID=
AIRTABLE_API_TOKEN=
AIRTABLE_ECOMMERCE_ORDERS_TABLE_ID=
AIRTABLE_PRODUCTS_TABLE_ID=
AIRTABLE_LOCATIONS_TABLE_ID=

ECWID_STORE_ID=
ECWID_SECRET_TOKEN=

CLOVER_MERCHANT_ID=
CLOVER_API_TOKEN=

REPORT_FROM_EMAIL=
REPORT_TO_EMAIL=
REPORT_TIMEZONE=America/Denver
```


## Issue #12 provider-neutral commerce transition

The PostgreSQL Ecwid order webhook now emits both the legacy `ecwid_*` order identifiers and provider-neutral aliases (`provider`, `site_key`, `external_order_id`, `external_skus`). The PostgreSQL upsert persists both sets during the Ecwid transition.

The Airtable compatibility workflow remains legacy-safe by default. It only emits the provider-neutral alias fields when `AIRTABLE_PROVIDER_NEUTRAL_ECOMMERCE_FIELDS=true`; do not enable that flag unless matching Airtable fields have been created. PostgreSQL is the production path for this phase.
