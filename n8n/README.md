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
- Polls Clover payments
- Matches to Ecwid orders by:
  - amount
  - timestamp window
- Updates Airtable:
  - `clover_reconciliation_status`
  - `clover_payment_id`
  - `clover_payment_time`
- DOES NOT update Ecwid payment status (to avoid duplicate Clover entries)

---

### 3. Daily Reconciliation Report
- Generates:
  - plain text report
  - PDF attachment
- Includes:
  - reconciled orders
  - unreconciled orders
  - unmatched Clover payments
  - **Ecwid product tally (NEW)**
- Sends via email

---

### 4. Fulfillment API (NEW)
Endpoints for Appsmith:

#### `/fulfillment/orders/list`
Returns:
- orders needing product assignment
- supports:
  - farmers market (reconciled)
  - website orders (paid)

#### `/fulfillment/order/detail`
Returns:
- full order detail
- parsed `items_json`

#### `/fulfillment/products/search`
Search available products by:
- `product_id`
- filters out shipped inventory

#### `/fulfillment/assign-product`
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

## 🔄 Future Migration

Replace Airtable nodes with:
- PostgreSQL
- or NocoDB

NO changes required in:
- Appsmith UI
- n8n endpoints

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
