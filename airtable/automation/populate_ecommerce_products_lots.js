/**
 * Script: populate_ecommerce_products_lots.js
 * Version: 2025-12-28.1
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
 * Summary: Populate ecommerce.products and ecommerce.lots
 * Notes: 
 * For ecommerce.products:
 *  - products.item_id == ecommerce.item_id
 *  - AND if ecommerce.strain_id is set, products.strain_id == ecommerce.strain_id
 *  - AND products.use_by, if set, is NOT expired (use_by >= today)
 *  - AND products.storage_location NOT IN ("Shipped", "Expired", "Consumed").
 *
 * For ecommerce.lots:
 *  - lots.item_id == ecommerce.item_id
 *  - AND if ecommerce.strain_id is set, lots.strain_id == ecommerce.strain_id
 *  - AND lots.use_by, if set, is NOT expired (use_by >= today)
 *  - AND lots.status NOT IN ("Planned", "Consumed", "Retired")
 *
 * Trigger: When record created/updated in ecommerce
 * Input variable: recordId (from trigger)
 */

const { ecommerceRecordId } = input.config();

// =============================================================================
// Debug helpers + robust link/lookup parsing
// =============================================================================

const DEBUG = true; // set false to reduce output

function dbg(msg, obj) {
  if (!DEBUG) return;
  try {
    if (obj !== undefined) {
      console.log(`[populate_ecommerce_products_lots] ${msg}`, obj);
    } else {
      console.log(`[populate_ecommerce_products_lots] ${msg}`);
    }
  } catch (_) {}
}

/**
 * Extract linked record IDs from a field value that might be:
 *   - a normal linked-record field: [{id,name}, ...]
 *   - a lookup of a linked-record field: [[{id,name}, ...], ...]  (nested)
 *   - a lookup of text: ["XYZ", ...] (no IDs available)
 *
 * Returns: string[] of record IDs (may be empty)
 */
function extractLinkedIds(cellValue) {
  const out = [];
  const stack = Array.isArray(cellValue) ? [...cellValue] : (cellValue ? [cellValue] : []);

  while (stack.length) {
    const v = stack.shift();
    if (v == null) continue;
    if (Array.isArray(v)) {
      // lookup fields can return arrays-of-arrays
      for (const inner of v) stack.push(inner);
      continue;
    }
    if (typeof v === 'object') {
      if (typeof v.id === 'string') out.push(v.id);
      continue;
    }
    // primitives (string/number/boolean) are not record refs
  }
  return out;
}

function firstLinkedIdFromRecord(rec, fieldName) {
  try {
    const ids = extractLinkedIds(rec.getCellValue(fieldName));
    return ids.length ? ids[0] : null;
  } catch (_) {
    return null;
  }
}

function extractLookupStrings(cellValue) {
  const out = [];
  const stack = Array.isArray(cellValue) ? [...cellValue] : (cellValue ? [cellValue] : []);
  while (stack.length) {
    const v = stack.shift();
    if (v == null) continue;
    if (Array.isArray(v)) { for (const inner of v) stack.push(inner); continue; }
    if (typeof v === 'object') {
      if (typeof v.name === 'string' && v.name.trim()) out.push(v.name.trim());
      continue;
    }
    if (typeof v === 'string' && v.trim()) out.push(v.trim());
  }
  return out;
}

function fieldType(table, fieldName) {
  try { return table.getField(fieldName).type; } catch (_) { return null; }
}

dbg('Start', { ecommerceRecordId });

// ---------- Table & field names (change if needed) ----------

let ecommerceTable = base.getTable('ecommerce');
let productsTable = base.getTable('products');
let lotsTable = base.getTable('lots');

// ecommerce fields
let ECOM_ITEM_FIELD    = 'item_id';    // link to items
let ECOM_STRAIN_FIELD  = 'strain_id';  // link to strains (optional)
let ECOM_PRODUCTS_FIELD = 'products';  // link to products
let ECOM_LOTS_FIELD     = 'lots';      // link to lots
let ECOM_STATUS_FIELD     = 'status';      // link to lots

// products fields
let PROD_ITEM_FIELD      = 'item_id';          // link to items
let PROD_STRAIN_FIELD    = 'strain_id';        // link to strains
let PROD_USE_BY_FIELD    = 'use_by';           // date
let PROD_STORAGE_FIELD   = 'storage_location'; // single select (includes "Shipped")

// Products in these storage locations are excluded (treated as unavailable)
const EXCLUDED_STORAGE_LOCATIONS = ['Shipped', 'Expired', 'Consumed'];

// lots fields
let LOT_ITEM_FIELD       = 'item_id';   // link to items
let LOT_STRAIN_FIELD     = 'strain_id'; // link to strains
let LOT_USE_BY_FIELD     = 'use_by';    // date (if you use a different name, change here)
let LOT_STATUS_FIELD     = 'status';    // single select with "Planned", "Consumed", "Retired"

// Map ecommerce.status -> allowed lots.status values
const LOT_STATUS_MAP = {
  Sterilized:     ['Sterilized', 'Sealed'],
  Pasteurized:    ['Pasteurized'],
  FullyColonized: ['FullyColonized', 'Fridge', 'ColdShock'],
  Inoculated:     ['Inoculated', 'Colonizing'],
};

// ---------- Load ecommerce record ----------

let ecommerceRecord = await ecommerceTable.selectRecordAsync(ecommerceRecordId);

dbg(`Trigger ecommerceRecordId=${ecommerceRecordId}`);
if (!ecommerceRecord) {
  output.set('error', `No ecommerce record found for ID ${ecommerceRecordId}`);
  return;
}

dbg('Field types', {
  ecommerce_item_id: fieldType(ecommerceTable, ECOM_ITEM_FIELD),
  ecommerce_strain_id: fieldType(ecommerceTable, ECOM_STRAIN_FIELD),
  ecommerce_status: fieldType(ecommerceTable, ECOM_STATUS_FIELD),
  products_item_id: fieldType(productsTable, PROD_ITEM_FIELD),
  products_strain_id: fieldType(productsTable, PROD_STRAIN_FIELD),
  lots_item_id: fieldType(lotsTable, LOT_ITEM_FIELD),
  lots_strain_id: fieldType(lotsTable, LOT_STRAIN_FIELD),
});

// Get ecommerce.status (required for including any lots)
let ecommerceStatusCell = ecommerceRecord.getCellValue(ECOM_STATUS_FIELD);
let ecommerceStatusName = ecommerceStatusCell && ecommerceStatusCell.name ? ecommerceStatusCell.name : null;

// Determine which lot statuses are allowed for this ecommerce status
let allowedLotStatuses = ecommerceStatusName
  ? LOT_STATUS_MAP[ecommerceStatusName] || []
  : [];

// If no ecommerce.status or unknown status, we won't include any lots

// Get linked item + strain from ecommerce
let ecommerceItemId = firstLinkedIdFromRecord(ecommerceRecord, ECOM_ITEM_FIELD);
let ecommerceStrainId = firstLinkedIdFromRecord(ecommerceRecord, ECOM_STRAIN_FIELD);

dbg('Ecommerce inputs', {
  ecommerceItemId,
  ecommerceStrainId,
  ecommerceStatusName,
  allowedLotStatuses,
});

if (!ecommerceItemId) {  // No item_id set; clear links and exit
  await ecommerceTable.updateRecordAsync(ecommerceRecordId, {
    [ECOM_PRODUCTS_FIELD]: [],
    [ECOM_LOTS_FIELD]: [],
  });
  output.set('error', 'No item_id on ecommerce record; cleared products & lots links.');
  return;
}

// Compute "today at midnight" for not-expired comparisons
let now = new Date();
let todayMidnight = new Date(now.getFullYear(), now.getMonth(), now.getDate());

// Helper: "not expired" => include if no date, OR use_by >= todayMidnight
function isNotExpired(useByValue) {
  if (!useByValue) {
    // No use_by set -> do NOT exclude
    return true;
  }
  let useByDate = new Date(useByValue);
  return useByDate >= todayMidnight;
}

// ---------- Fetch products ----------

let productsQuery = await productsTable.selectRecordsAsync({
  fields: [PROD_ITEM_FIELD, PROD_STRAIN_FIELD, PROD_USE_BY_FIELD, PROD_STORAGE_FIELD],
});

dbg('Loaded products', { count: productsQuery.records.length });

// Check if a products record matches ecommerce conditions
function productMatchResult(record) {
  // Return { ok: boolean, reason: string }
  // 1) item_id must match
  let prodItemIds = extractLinkedIds(record.getCellValue(PROD_ITEM_FIELD));
  let matchesItem = prodItemIds.includes(ecommerceItemId);
  if (!matchesItem) return { ok: false, reason: 'item_mismatch' };

  // 2) strain logic:
  //    - if ecommerce.strain_id is set: product.strain_id must match
  //    - if ecommerce.strain_id is EMPTY: product.strain_id must also be EMPTY
  // products.strain_id is often a LOOKUP into origin lots.strain_id.
  // That means it may contain names (strings) instead of linked-record IDs.
  const prodStrainRaw = record.getCellValue(PROD_STRAIN_FIELD);
  if (ecommerceStrainId) {
    // require at least one matching strain link
    const prodStrainIds = extractLinkedIds(prodStrainRaw);
    if (prodStrainIds.length > 0) {
      if (!prodStrainIds.includes(ecommerceStrainId)) return { ok: false, reason: 'strain_mismatch' };
    } else {
      const prodStrainNames = extractLookupStrings(prodStrainRaw);
      if (!ecommerceStrainName) return false;
      const target = ecommerceStrainName.trim().toLowerCase();
      const matchesName = prodStrainNames.some(n => n.toLowerCase() === target);
      if (!matchesName) return { ok: false, reason: 'strain_mismatch' };
    }
  } else {
    // ecommerce has no strain; only match products with NO strain
    // ecommerce has no strain; only match products with NO strain
    const prodStrainIds = extractLinkedIds(prodStrainRaw);
    const prodStrainNames = extractLookupStrings(prodStrainRaw);
    if (prodStrainIds.length > 0 || prodStrainNames.length > 0) return { ok: false, reason: 'strain_should_be_empty' };
  }

  // 3) use_by not expired (or empty)
  let useBy = record.getCellValue(PROD_USE_BY_FIELD);
  if (!isNotExpired(useBy)) return { ok: false, reason: 'expired_use_by' };

  // 4) storage_location NOT IN ("Shipped", "Expired", "Consumed")
  // storage_location is a link to locations (single link)
  // e.g. [{ id: 'rec...', name: 'Shipped' }]
  let storageLinks = record.getCellValue(PROD_STORAGE_FIELD) || [];
  let isExcludedLocation = storageLinks.some((link) => {
    const name = (link.name || '').trim();
    return EXCLUDED_STORAGE_LOCATIONS.includes(name);
  });
  if (isExcludedLocation) return { ok: false, reason: 'excluded_storage_location' };

  return { ok: true, reason: 'ok' };
}

// ---------- Fetch lots ----------

let lotsQuery = await lotsTable.selectRecordsAsync({
  fields: [LOT_ITEM_FIELD, LOT_STRAIN_FIELD, LOT_USE_BY_FIELD, LOT_STATUS_FIELD],
});

dbg('Loaded lots', { count: lotsQuery.records.length });

// Check if a lots record matches ecommerce conditions
function lotMatchResult(record) {
  // Return { ok: boolean, reason: string }
  // 1) item_id must match
  let lotItemIds = extractLinkedIds(record.getCellValue(LOT_ITEM_FIELD));
  let matchesItem = lotItemIds.includes(ecommerceItemId);
  if (!matchesItem) return { ok: false, reason: 'item_mismatch' };

  // 2) strain logic:
  //    - if ecommerce.strain_id is set: lot.strain_id must match
  //    - if ecommerce.strain_id is EMPTY: lot.strain_id must also be EMPTY
  let lotStrainIds = extractLinkedIds(record.getCellValue(LOT_STRAIN_FIELD));
  if (ecommerceStrainId) {
    let matchesStrain = lotStrainIds.includes(ecommerceStrainId);
    if (!matchesStrain) return { ok: false, reason: 'strain_mismatch' };
  } else {
    if (lotStrainIds.length > 0) return { ok: false, reason: 'strain_should_be_empty' };
  }

  // 3) use_by not expired (or empty)
  let useBy = record.getCellValue(LOT_USE_BY_FIELD);
  if (!isNotExpired(useBy)) return { ok: false, reason: 'expired_use_by' };

  // 4) status must match the allowed set for ecommerce.status
  //    If ecommerce.status is not set or not mapped, allowedLotStatuses = []
  let status = record.getCellValue(LOT_STATUS_FIELD);
  let statusName = status && status.name ? status.name : null;

  if (!statusName) return { ok: false, reason: 'missing_status' };
  if (!allowedLotStatuses.includes(statusName)) {
    return { ok: false, reason: `status_not_allowed:${statusName}` };
  }

  return { ok: true, reason: 'ok' };
}

// ---------- Build link arrays ----------

let matchingProducts = [];
let productRejects = { item: 0, strain: 0, expired: 0, excluded_location: 0 };

for (let productRecord of productsQuery.records) {
  // For debug, re-run criteria with counters to see where failures occur.
  const prodItemIds = extractLinkedIds(productRecord.getCellValue(PROD_ITEM_FIELD));
  if (!prodItemIds.includes(ecommerceItemId)) { productRejects.item++; continue; }

  const prodStrainIds = extractLinkedIds(productRecord.getCellValue(PROD_STRAIN_FIELD));
  if (ecommerceStrainId) {
    if (!prodStrainIds.includes(ecommerceStrainId)) { productRejects.strain++; continue; }
  } else {
    if (prodStrainIds.length > 0) { productRejects.strain++; continue; }
  }

  const useBy = productRecord.getCellValue(PROD_USE_BY_FIELD);
  if (!isNotExpired(useBy)) { productRejects.expired++; continue; }

  const storageLinks = productRecord.getCellValue(PROD_STORAGE_FIELD) || [];
  const isExcludedLocation = storageLinks.some((link) => {
    const name = (link.name || '').trim();
    return EXCLUDED_STORAGE_LOCATIONS.includes(name);
  });
  if (isExcludedLocation) { productRejects.excluded_location++; continue; }

  matchingProducts.push(productRecord);
}

let matchingLots = [];
let lotRejects = { item: 0, strain: 0, expired: 0, no_status: 0, status_not_allowed: 0 };

for (let lotRecord of lotsQuery.records) {
  const lotItemIds = extractLinkedIds(lotRecord.getCellValue(LOT_ITEM_FIELD));
  if (!lotItemIds.includes(ecommerceItemId)) { lotRejects.item++; continue; }

  const lotStrainIds = extractLinkedIds(lotRecord.getCellValue(LOT_STRAIN_FIELD));
  if (ecommerceStrainId) {
    if (!lotStrainIds.includes(ecommerceStrainId)) { lotRejects.strain++; continue; }
  } else {
    if (lotStrainIds.length > 0) { lotRejects.strain++; continue; }
  }

  const useBy = lotRecord.getCellValue(LOT_USE_BY_FIELD);
  if (!isNotExpired(useBy)) { lotRejects.expired++; continue; }

  const status = lotRecord.getCellValue(LOT_STATUS_FIELD);
  const statusName = status && status.name ? status.name : null;
  if (!statusName) { lotRejects.no_status++; continue; }
  if (!allowedLotStatuses.includes(statusName)) { lotRejects.status_not_allowed++; continue; }

  matchingLots.push(lotRecord);
}

let productLinks = matchingProducts.map(rec => ({ id: rec.id }));
let lotLinks     = matchingLots.map(rec => ({ id: rec.id }));

dbg('Match summary', {
  matchingProducts: matchingProducts.length,
  matchingLots: matchingLots.length,
  productRejects,
  lotRejects,
});

// ---------- Update ecommerce record ----------

await ecommerceTable.updateRecordAsync(ecommerceRecordId, {
  [ECOM_PRODUCTS_FIELD]: productLinks,
  [ECOM_LOTS_FIELD]: lotLinks,
});

output.set('result',
  `Linked ${matchingProducts.length} product(s) and ${matchingLots.length} lot(s) to ecommerce record ${ecommerceRecordId}.`
);