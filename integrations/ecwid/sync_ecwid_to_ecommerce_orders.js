/**
 * Script: sync_ecwid_to_ecommerce_orders.js
 * Version: 2025-12-02.2
 * =============================================================================
 *  Copyright © 2025 Dank Mushrooms, LLC
 *  Licensed under the GNU General Public License v3 (GPL-3.0-only)
 *
 *  This program is free software: you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation, either version 3 of the License.
 *
 *  This program is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 *  GNU General Public License for more details.
 *
 *  You should have received a copy of the GNU General Public License
 *  along with this program. If not, see <https://www.gnu.org/licenses/>.
 * ============================================================================= 
 * Purpose:
 *   - Fetch recent orders from Ecwid (storeId from env)
 *   - Upsert them into the Airtable table ecommerce_orders
 *     using ecwid_order_id as the external key.
 *
 * Usage:
 *   AIRTABLE_ECOMMERCE_ORDERS_TABLE=ecommerce_orders
 *   npm install node-fetch@2 dotenv
 *   node sync_ecwid_to_ecommerce_orders.js
 */

const {
  assertCommonEnv,
  airtableFetchAllRecords,
  airtableCreateRecord,
  airtableUpdateRecord,
  ecwidRequest,
} = require('./lib/ecwid_airtable');

require('dotenv').config();

const {
  AIRTABLE_ECOMMERCE_ORDERS_TABLE,
  ECWID_ORDERS_LIMIT,
} = process.env;

function assertEnv() {
  assertCommonEnv();
  const required = ['AIRTABLE_ECOMMERCE_ORDERS_TABLE'];
  const missing = required.filter((k) => !process.env[k]);
  if (missing.length) {
    console.error('Missing required env vars:', missing.join(', '));
    process.exit(1);
  }
}

assertEnv();

const ORDERS_LIMIT = Number(ECWID_ORDERS_LIMIT) || 100;

/**
 * Fetch recent Ecwid orders.
 *
 * NOTE:
 *   You can refine the query with date filters or statuses.
 *   For now, we fetch the last N orders sorted by createdTime.
 */
async function fetchRecentEcwidOrders() {
  const params = new URLSearchParams({
    offset: '0',
    limit: String(ORDERS_LIMIT),
    sortBy: 'createdTime',
    sortOrder: 'DESC',
  });

  const data = await ecwidRequest(`/orders?${params.toString()}`);
  const items = data.items || data.orders || data || [];
  if (!Array.isArray(items)) {
    console.warn('Unexpected orders payload shape; adjust parsing if needed.');
    return [];
  }

  return items;
}

/**
 * Build a map ecwid_order_id -> Airtable recordId from ecommerce_orders.
 */
async function buildExistingOrdersMap() {
  const records = await airtableFetchAllRecords(AIRTABLE_ECOMMERCE_ORDERS_TABLE);
  const map = new Map();

  for (const rec of records) {
    const fields = rec.fields || {};
    const extId = fields.ecwid_order_id;
    if (!extId) continue;
    map.set(String(extId), rec.id);
  }

  return map;
}

/**
 * Map an Ecwid order object to Airtable fields for ecommerce_orders.
 */
function mapEcwidOrderToFields(order) {
  // Ecwid structures can vary by version; adjust as needed.
  const rawId = order.id || order.orderId || order.number;
  const orderNumber = order.orderNumber || rawId || null;

  const billing = order.billingPerson || {};
  const shipping = order.shippingPerson || {};
  const customerName =
    billing.name ||
    shipping.name ||
    `${billing.firstName || ''} ${billing.lastName || ''}`.trim() ||
    `${shipping.firstName || ''} ${shipping.lastName || ''}`.trim() ||
    null;

  const customerEmail =
    billing.email ||
    shipping.email ||
    null;

  const status =
    order.fulfillmentStatus ||
    order.paymentStatus ||
    order.financialStatus ||
    null;

  const createdRaw = order.createDate || order.created || order.dateCreated || null;

  let orderDate = null;
  if (createdRaw) {
    const d = new Date(createdRaw);
    if (!Number.isNaN(d.getTime())) {
      // Airtable date fields accept ISO strings
      orderDate = d.toISOString();
    }
  }

  const items = order.items || order.orderItems || [];

  const name =
    (orderNumber != null ? `#${orderNumber}` : '') +
    (customerName ? ` – ${customerName}` : '');

  const itemsJson = JSON.stringify(items, null, 2);

  return {
    name: name || null,
    ecwid_order_id: rawId != null ? String(rawId) : null,
    order_number: orderNumber != null ? Number(orderNumber) : null,
    status,
    order_date: orderDate,
    customer_name: customerName,
    customer_email: customerEmail,
    items_json: itemsJson,
    // products: left for user to link manually in Airtable UI
    // ecommerce: optional, can be filled later based on SKUs
  };
}

async function upsertOrders() {
  try {
    console.log('Fetching recent Ecwid orders...');
    const orders = await fetchRecentEcwidOrders();
    console.log(`Fetched ${orders.length} Ecwid order(s).`);

    console.log('Building existing ecommerce_orders map...');
    const existingMap = await buildExistingOrdersMap();
    console.log(`Found ${existingMap.size} existing ecommerce_orders row(s).`);

    let createdCount = 0;
    let updatedCount = 0;

    for (const order of orders) {
      const fields = mapEcwidOrderToFields(order);
      const extId = fields.ecwid_order_id;

      if (!extId) {
        console.warn('Order skipped because no ecwid_order_id could be derived:', order);
        continue;
      }

      const existingRecordId = existingMap.get(String(extId));

      try {
        if (existingRecordId) {
          // Update
          await airtableUpdateRecord(
            AIRTABLE_ECOMMERCE_ORDERS_TABLE,
            existingRecordId,
            fields
          );
          updatedCount++;
        } else {
          // Create
          await airtableCreateRecord(AIRTABLE_ECOMMERCE_ORDERS_TABLE, fields);
          createdCount++;
        }
      } catch (err) {
        console.error(
          `Error upserting Ecwid order ${extId}:`,
          err.message
        );
      }
    }

    console.log(
      `Done. Created ${createdCount} and updated ${updatedCount} ecommerce_orders record(s).`
    );
  } catch (err) {
    console.error('Fatal error in upsertOrders:', err.message);
    process.exit(1);
  }
}

upsertOrders();
