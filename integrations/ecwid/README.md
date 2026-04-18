# Ecwid ? Airtable Sync Utilities

This repository includes two complementary Node.js scripts for synchronizing data between **Airtable** (your operational inventory database) and **Ecwid** (your ecommerce storefront).

The goals are:

- Maintain accurate real-time **product availability** on Ecwid based on Airtable inventory.
- Maintain a local Airtable mirror of **Ecwid orders** for fulfillment workflows.
- Enable staff to move internal products to `"Shipped"` and correctly associate them with incoming Ecwid orders.

This document explains how each sync script works, how to install and configure the system, and the recommended workflow for your team.

---

# Overview

This system is built around **two data flows**:

### 1. Airtable ? Ecwid  
**sync_ecommerce_to_ecwid.js**  
Updates product availability on Ecwid based on Airtable's computed inventory.

### 2. Ecwid ? Airtable  
**sync_ecwid_to_ecommerce_orders.js**  
Imports and updates Ecwid orders into an Airtable table (`ecommerce_orders`), enabling fulfillment tracking and linking shipped products to specific customer orders.

A shared library, **lib/ecwid_airtable.js**, handles common API interactions for both scripts.

---

### `sync_ecommerce_to_ecwid.js`
This script reads the Airtable `ecommerce` table and synchronizes each mapped SKU with Ecwid.

It now performs two related jobs for each ecommerce row:

1. **Push inventory quantities to Ecwid**
   - Reads the two quantity component fields from Airtable.
   - Sums them to determine the desired Ecwid stock quantity.
   - Updates the matching Ecwid base product or variation by SKU.

2. **Pull Ecwid product metadata back into Airtable**
   - Ecwid is treated as the source of truth for:
     - `ecwid_category`
     - `ecwid_price`
     - `ecwid_stock`
     - `ecwid_url`
     - `ecwid_upc`
   - After resolving the SKU in Ecwid, the script updates those fields in Airtable.
   - If the Ecwid product / variation does not yet have a UPC, the script allocates the next available code from the configured UPC pool and writes it back to both Ecwid and Airtable.

Recommended Airtable fields on `ecommerce`:
- `ecwid_sku`
- `available_from_products`
- `available_from_lots`
- `sync_to_ecwid`
- `ecwid_category`
- `ecwid_price`
- `ecwid_stock`
- `ecwid_url`
- `ecwid_upc`

This script **pushes inventory quantities from Airtable to Ecwid**.

It reads records from your Airtable **ecommerce** table:

- `ecwid_sku` identifies the Ecwid product or variation.
- Two numeric fields (configured via environment variables, typically
  `available_from_products` and `available_from_lots`) provide the internal availability components. Their sum is treated as the *precomputed internal
  availability* that is pushed to Ecwid.

For each SKU:

1. Looks up the corresponding Ecwid product or variation.
2. Updates its available quantity to match Airtable.
3. Ensures Ecwid always accurately reflects internal stock.

This prevents overselling and keeps your storefront listings constantly in sync.

---

### `sync_ecwid_to_ecommerce_orders.js`
This script fetches recent Ecwid orders and upserts them into the Airtable `ecommerce_orders` table using `ecwid_order_id` as the external key.


Orders are upserted into a dedicated Airtable table named **`ecommerce_orders`** using `ecwid_order_id` as the external key.

It also:
- extracts SKUs from `items_json`
- stores them in `ecwid_skus`
- links `ecommerce_orders.ecommerce` to matching rows in the `ecommerce` table by `ecwid_sku`

Ecwid is treated as the source of truth for these order-facing fields:


- `name`
- `ecwid_order_id`
- `order_number`
- `status`
- `order_date`
- `customer_name`
- `customer_email`
- `items_json` (raw items)
- `ecwid_skus`
- `payment_status`
- `payment_method`
- `subtotal`
- `tax_total`
- `order_total`
- `currency`

These Airtable-managed fields are intentionally not overwritten by the polling sync:
- `products`
- `clover_reconciliation_status`
- `clover_payment_id`
- `clover_payment_time`
- `clover_match_confidence`
- `reconciled_at`
- `reconciliation_notes`
- webhook metadata fields such as `ecwid_event_type`, `ecwid_event_id`, `last_webhook_at`
- A link field (`products`) which staff can use to attach internal product records that were shipped in this order.

This enables:

- Audit trails
- Shipment reconciliation
- Inventory verification
- Smooth fulfillment workflows

When a user marks a product’s `storage_location` as `"Shipped"` in an Interface, they can link the product to the correct Ecwid order through the auto-created reverse link field (`products.ecommerce_orders`).

---

## Shared library

### `lib/ecwid_airtable.js`
Shared helpers for:
- Airtable API requests
- Ecwid API requests
- SKU lookups
- product / variation updates
- UPC normalization and allocation helpers

This design:
- Centralizes API logic
- Keeps scripts clean
- Ensures consistent behavior across both sync processes

---

# Airtable Schema Requirements

## Table: `ecommerce`
Represents website-facing SKUs.

Important fields:
- `ecwid_sku`
- `available_quantity` (formula, rollup, or automation-computed)
- `products` (link to internal products)

Additional fields like `strain_id`, `item_id`, etc., tie to your inventory system.

---

## Table: `ecommerce_orders`
Mirrors orders imported from Ecwid.

Field | Type | Description
------|------|------------
`name` | Single line text | Generated: `#orderNumber — customerName`
`ecwid_order_id` | Text | External key from Ecwid
`order_number` | Number | Human-readable
`status` | Single select or text | Order status from Ecwid
`order_date` | Date | Ecwid order date
`customer_name` | Text | Billing/shipping name
`customer_email` | Text | Email from order
`items_json` | Long text | Raw JSON of order line items
`products` | Link to `products` | Products assigned to this order

### Auto-created field:
When `ecommerce_orders.products` was created, Airtable created:

- `products.ecommerce_orders` (reverse link)

This serves as your **“product ? Ecwid order”** field.  
No separate field is required.

## UPC pool storage

The simplest and recommended design is to keep the UPC pool in flat files in the repository or integration directory:

- `eancodes.txt` â†’ allocatable UPC / EAN pool
- `codes.txt` â†’ optional reserved / legacy codes reference

The sync script loads those files on each run. Airtable then becomes the durable assignment record through `ecommerce.ecwid_upc`.


---

# Environment Variables

See .env.example and rename to .env

## Installation

```bash
npm install node-fetch@2 dotenv
```

## Usage

```bash
node sync_ecommerce_to_ecwid.js
node sync_ecwid_to_ecommerce_orders.js
```

## Suggested run cadence

- `sync_ecommerce_to_ecwid.js`:
  - every 10â€“15 minutes
  - or immediately after major inventory-affecting workflows

- `sync_ecwid_to_ecommerce_orders.js`:
  - every 5â€“15 minutes
  - or more frequently if staff needs orders available quickly in Airtable

## ¿¿ Interaction with n8n Reconciliation

- This integration syncs ALL orders (paid + awaiting_payment)
- n8n workflows:
  - process farmers market orders (awaiting_payment)
  - process Clover reconciliation separately

---

## ¿ Future Integration Point

n8n will eventually replace this sync with:
- webhook-driven ingestion
- PostgreSQL persistence

---

## ¿ Key Field: `items_json`

- Contains ordered product data
- Used for:
  - reporting
  - fulfillment guidance
  - product tally generation

---
