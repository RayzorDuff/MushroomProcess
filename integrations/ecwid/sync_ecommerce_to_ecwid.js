/**
 * Script: sync_ecommerce_to_ecwid.js
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
 * Purpose: Read ecommerce mapping table in Airtable and push inventory
 *          quantities to Ecwid (store 95802503) by SKU.
 *
 * Usage:
 *   npm install node-fetch@2 dotenv
 *   node sync_ecommerce_to_ecwid.js
 */

const {
  assertCommonEnv,
  airtableFetchAllRecords,
  airtableUpdateRecord,
  findEcwidProductBySku,
  updateEcwidBaseProductQuantity,
  updateEcwidVariationQuantity,
  updateEcwidProduct,
  updateEcwidVariation,
} = require('./lib/ecwid_airtable');

const {
  AIRTABLE_ECOMMERCE_TABLE,
  AIRTABLE_ECOMMERCE_SKU_FIELD,
  AIRTABLE_ECOMMERCE_QTY_FROM_PRODUCTS_FIELD,
  AIRTABLE_ECOMMERCE_QTY_FROM_LOTS_FIELD,
  AIRTABLE_ECOMMERCE_ACTIVE_FIELD,
} = process.env;

const fs = require('fs');
const path = require('path');

const UPC_POOL_FILE = path.join(__dirname, '../upc/eancodes.txt');

function assertEnv() {
  const required = [
    'AIRTABLE_ECOMMERCE_TABLE',
    'AIRTABLE_ECOMMERCE_SKU_FIELD',
    'AIRTABLE_ECOMMERCE_QTY_FROM_PRODUCTS_FIELD',
    'AIRTABLE_ECOMMERCE_QTY_FROM_LOTS_FIELD',

  ];

  const missing = required.filter((k) => !process.env[k]);
  if (missing.length) {
    console.error('Missing required env vars:', missing.join(', '));
    process.exit(1);
  }
}

assertCommonEnv();
assertEnv();



// ---------- Sync logic ----------

function shouldSkipRecord(record) {
  const fields = record.fields || {};

  const sku = fields[AIRTABLE_ECOMMERCE_SKU_FIELD];
  const qtyFromProductsRaw = fields[AIRTABLE_ECOMMERCE_QTY_FROM_PRODUCTS_FIELD];
  const qtyFromLotsRaw = fields[AIRTABLE_ECOMMERCE_QTY_FROM_LOTS_FIELD];

  if (!sku || String(sku).trim() === '') return true;

  const qtyFromProducts = Number(qtyFromProductsRaw);
  const qtyFromLots = Number(qtyFromLotsRaw);

  const hasProductsQty = Number.isFinite(qtyFromProducts);
  const hasLotsQty = Number.isFinite(qtyFromLots);

  // Preserve previous behavior: if we don't have any numeric quantity at all, skip.
  if (!hasProductsQty && !hasLotsQty) return true;

  const quantity =
    (hasProductsQty ? qtyFromProducts : 0) +
    (hasLotsQty ? qtyFromLots : 0);

  if (!Number.isFinite(quantity) || quantity < 0) return true;

  return false;
}

function getNextUPC(usedSet) {
  const lines = fs.readFileSync(UPC_POOL_FILE, 'utf-8').split('\n');

  for (const line of lines) {
    const code = line.trim();
    if (!code) continue;
    if (!usedSet.has(code)) return code;
  }

  throw new Error('No UPC codes left in pool');
}

async function syncRecord(record, usedUpcs) {
  const fields = record.fields || {};
  const sku = String(fields[AIRTABLE_ECOMMERCE_SKU_FIELD]).trim();

  const qtyFromProducts = Number(fields[AIRTABLE_ECOMMERCE_QTY_FROM_PRODUCTS_FIELD]);
  const qtyFromLots = Number(fields[AIRTABLE_ECOMMERCE_QTY_FROM_LOTS_FIELD]);

  const quantity =
    (Number.isFinite(qtyFromProducts) ? qtyFromProducts : 0) +
    (Number.isFinite(qtyFromLots) ? qtyFromLots : 0);

  const { product, variation } = await findEcwidProductBySku(sku);

  if (!product) {
    console.warn(`No Ecwid product found for SKU ${sku}`);
    return;
  }

  const target = variation || product;

  // --- Pull Ecwid values ---
  const ecwidPrice = target.price;
  const ecwidStock = target.quantity;
  const ecwidUrl = product.url || null;
  const ecwidCategory =
  Array.isArray(product.categoryIds) && product.categoryIds.length
    ? String(product.categoryIds[0])
    : null;
  const ecwidUpc = target.attributes?.find(a => a.name === 'UPC')?.value || null;

  let upcToUse = fields.ecwid_upc || ecwidUpc;

  if (!upcToUse) {
    upcToUse = getNextUPC(usedUpcs);
    usedUpcs.add(upcToUse);

    console.log(`Assigned UPC ${upcToUse} to SKU ${sku}`);

    const attr = [{ name: 'UPC', value: upcToUse }];

    if (variation) {
      await updateEcwidVariation(product.id, variation.id, { attributes: attr });
    } else {
      await updateEcwidProduct(product.id, { attributes: attr });
    }
  }

  // --- Push quantity ---
  if (variation) {
    await updateEcwidVariationQuantity(product.id, variation.id, quantity);
  } else {
    await updateEcwidBaseProductQuantity(product.id, quantity);
  }

  // --- Write back to Airtable ---
  const updateFields = {
    ecwid_price: Number.isFinite(Number(ecwidPrice)) ? Number(ecwidPrice) : null,
    ecwid_stock: Number.isFinite(Number(ecwidStock)) ? Number(ecwidStock) : null,
    ecwid_url: ecwidUrl ? String(ecwidUrl) : null,
    ecwid_upc: upcToUse ? String(upcToUse) : null,
  };

  if (
    Array.isArray(product.categoryIds) &&
    product.categoryIds.length > 0 &&
    product.categoryIds[0] != null
  ) {
    updateFields.ecwid_category = String(product.categoryIds[0]);
  } else {
    updateFields.ecwid_category = null;
  }

  await airtableUpdateRecord(AIRTABLE_ECOMMERCE_TABLE, record.id, updateFields);

  console.log(`Synced SKU ${sku}`);
}

async function main() {
  try {
    console.log(
      `Fetching ecommerce records from table "${AIRTABLE_ECOMMERCE_TABLE}"`
    );
    const records = await airtableFetchAllRecords(AIRTABLE_ECOMMERCE_TABLE);
    console.log(`Fetched ${records.length} raw records.`);

    const usable = records.filter((r) => !shouldSkipRecord(r));
    console.log(`Found ${usable.length} record(s) to sync.`);

    const usedUpcs = new Set(
      records.map(r => r.fields?.ecwid_upc).filter(Boolean)
    );

    for (const record of usable) {
      try {
        await syncRecord(record, usedUpcs);
      } catch (err) {
        console.error(
          `Error syncing record ${record.id} (SKU=${record.fields?.[AIRTABLE_ECOMMERCE_SKU_FIELD]}):`,
          err.message
        );
      }
    }

    console.log('\nDone.');
  } catch (err) {
    console.error('Fatal error:', err.message);
    process.exit(1);
  }
}

main();
