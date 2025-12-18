# Ecwid ? Airtable Sync Utilities

This repository includes two complementary Node.js scripts for synchronizing data between **Airtable** (your operational inventory database) and **Ecwid** (your ecommerce storefront).

The goals are:

- Maintain accurate real-time **product availability** on Ecwid based on Airtable inventory.
- Maintain a local Airtable mirror of **Ecwid orders** for fulfillment workflows.
- Enable staff to move internal products to `"Shipped"` and correctly associate them with incoming Ecwid orders.

This document explains how each sync script works, how to install and configure the system, and the recommended workflow for your team.

---

# Table of Contents

1. [Overview](#overview)
2. [Script 1: sync_ecommerce_to_ecwid.js](#script-1-sync_ecommerce_to_ecwidjs)
3. [Script 2: sync_ecwid_to_ecommerce_orders.js](#script-2-sync_ecwid_to_ecommerce_ordersjs)
4. [Shared Library: lib/ecwid_airtable.js](#shared-library-libecwid_airtablejs)
5. [Airtable Schema Requirements](#airtable-schema-requirements)
6. [Environment Variables](#environment-variables)
7. [Installation](#installation)
8. [Usage](#usage)
9. [Recommended Fulfillment Workflow](#recommended-fulfillment-workflow)
10. [Future Enhancements](#future-enhancements)

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

# Script 1: `sync_ecommerce_to_ecwid.js`

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

# Script 2: `sync_ecwid_to_ecommerce_orders.js`

This script **pulls orders from Ecwid into Airtable** on a schedule.

Orders are upserted into a dedicated Airtable table named **`ecommerce_orders`** using `ecwid_order_id` as the external key.

For each Ecwid order, Airtable receives:

- `name`
- `ecwid_order_id`
- `order_number`
- `status`
- `order_date`
- `customer_name`
- `customer_email`
- `items_json` (raw items)
- A link field (`products`) which staff can use to attach internal product records that were shipped in this order.

This enables:

- Audit trails
- Shipment reconciliation
- Inventory verification
- Smooth fulfillment workflows

When a user marks a product’s `storage_location` as `"Shipped"` in an Interface, they can link the product to the correct Ecwid order through the auto-created reverse link field (`products.ecommerce_orders`).

---

# Shared Library: `lib/ecwid_airtable.js`

A single shared module used by both scripts.

It provides:

### Airtable Helpers
- `airtableFetchAllRecords`
- `airtableCreateRecord`
- `airtableUpdateRecord`

### Ecwid Helpers
- `ecwidRequest`
- `findEcwidProductBySku`
- `updateEcwidBaseProductQuantity`
- `updateEcwidVariationQuantity`

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

---

# Environment Variables

See .env.example and rename to .env
