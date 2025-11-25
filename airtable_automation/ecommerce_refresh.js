/**
 *  Script: ecommerce_refresh.js
 *  Version: 2025-11-22.1
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
 *
 * =============================================================================
 *  Purpose
 *  -------
 *  Refreshes link fields on the `ecommerce` table so that:
 *
 *    - `ecommerce.products` contains all matching products.
 *    - `ecommerce.lots`     contains all matching lots.
 *
 *  Matching rules (per ecommerce record):
 *
 *  Common:
 *    - products.item_id / lots.item_id == ecommerce.item_id
 *    - Strain handling:
 *        * If ecommerce.strain_id is set:
 *            product/lot.strain_id must match.
 *        * If ecommerce.strain_id is empty:
 *            product/lot.strain_id must also be empty.
 *
 *  Products:
 *    - products.use_by, if set, must be NOT expired (>= today).
 *    - products.storage_location != "Shipped".
 *
 *  Lots:
 *    - lots.use_by, if set, must be NOT expired (>= today).
 *    - lots.status is constrained by ecommerce.status:
 *        ecommerce.status = "Sterilized"     -> lots.status in ["Sterilized", "Sealed"]
 *        ecommerce.status = "Pasteurized"    -> lots.status in ["Pasteurized"]
 *        ecommerce.status = "FullyColonized" -> lots.status in ["FullyColonized", "Fridge", "ColdShock"]
 *        ecommerce.status = "Inoculated"     -> lots.status in ["Inoculated", "Colonizing"]
 *      If ecommerce.status is blank or not in the map, no lots are linked.
 *
 *  Execution pattern
 *  -----------------
 *  This script is designed to run as a standalone "refresh" job
 *  (e.g. via a scheduled Automation). It will:
 *
 *    1. Load all ecommerce records and index them by (item_id, strain_id-or-none).
 *    2. Load all products and lots.
 *    3. For each product / lot, find matching ecommerce records by that key and
 *       mark those ecommerce records as needing refresh.
 *    4. For each affected ecommerce record, recompute its `products` and `lots`
 *       links using the candidates that share the same (item, strain) key.
 *
 * =============================================================================
 */

function hasField(tbl, name){ try { tbl.getField(name); return true; } catch { return false; } }
function fieldType(tbl, name){ try { return tbl.getField(name).type; } catch { return null; } }
function isLinkField(tbl, name){ return fieldType(tbl, name) === 'multipleRecordLinks'; }
function num(v){ const n = Number(v); return Number.isFinite(n) ? n : null; }
function asStr(rec, f){ try { return rec.getCellValueAsString(f) || ''; } catch { return ''; } }
async function safeUpdate(tbl, id, fields) {
  const out = {};
  for (const [k,v] of Object.entries(fields||{})) {
    if (v !== undefined && hasField(tbl,k)) out[k]=v;
  }
  if (Object.keys(out).length) await tbl.updateRecordAsync(id, out);
}
function notify(msg){
  try { if (typeof output?.set === 'function') output.set('result', msg); } catch(_){}
  try { console.log(msg); } catch(_){}
}

/* ---------------------- Table handles & constants ---------------------- */

const ecommerceTbl = base.getTable('ecommerce');
const productsTbl  = base.getTable('products');
const lotsTbl      = base.getTable('lots');

// ecommerce fields
const ECOM_ITEM_FIELD     = 'item_id';     // link to items
const ECOM_STRAIN_FIELD   = 'strain_id';   // link to strains (optional)
const ECOM_STATUS_FIELD   = 'status';      // single select controlling lot status filter
const ECOM_PRODUCTS_FIELD = 'products';    // link to products
const ECOM_LOTS_FIELD     = 'lots';        // link to lots

// products fields
const PROD_ITEM_FIELD    = 'item_id';           // link to items
const PROD_STRAIN_FIELD  = 'strain_id';         // link to strains
const PROD_USE_BY_FIELD  = 'use_by';            // date
const PROD_STORAGE_FIELD = 'storage_location';  // single select, includes "Shipped"

// lots fields
const LOT_ITEM_FIELD    = 'item_id';    // link to items
const LOT_STRAIN_FIELD  = 'strain_id';  // link to strains
const LOT_USE_BY_FIELD  = 'use_by';     // date (adjust if your lots use different name)
const LOT_STATUS_FIELD  = 'status';     // single select

// Map ecommerce.status -> allowed lots.status values
const LOT_STATUS_MAP = {
  Sterilized:     ['Sterilized', 'Sealed'],
  Pasteurized:    ['Pasteurized'],
  FullyColonized: ['FullyColonized', 'Fridge', 'ColdShock'],
  Inoculated:     ['Inoculated', 'Colonizing'],
};

/* --------------------------- Date helper --------------------------- */

const now = new Date();
const todayMidnight = new Date(now.getFullYear(), now.getMonth(), now.getDate());

function isNotExpired(useByValue) {
  if (!useByValue) return true; // no use_by -> allowed
  const d = new Date(useByValue);
  if (Number.isNaN(d.getTime())) return true; // malformed date, be lenient
  return d >= todayMidnight;
}

/* -------------------- Key helpers (item + strain) ------------------- */

function keyFor(itemId, strainId) {
  if (!itemId) return null;
  return `${itemId}::${strainId || 'NONE'}`;
}

function firstLinkedId(rec, fieldName) {
  try {
    const arr = rec.getCellValue(fieldName) || [];
    return arr.length ? arr[0].id : null;
  } catch {
    return null;
  }
}

/* --------------------------- Main logic ----------------------------- */

try {
  const startIso = new Date().toISOString();
  notify(`ecommerce_refresh.js start @ ${startIso}`);

  // ---------- 1) Load all ecommerce rows and index by key ----------
  const ecommerceQuery = await ecommerceTbl.selectRecordsAsync({
    fields: [ECOM_ITEM_FIELD, ECOM_STRAIN_FIELD, ECOM_STATUS_FIELD]
  });

  /** key -> array of ecommerce record objects */
  const ecommerceByKey = new Map();
  /** ecommerce.id -> { rec, itemId, strainId, statusName } */
  const ecommerceMeta = new Map();

  for (const rec of ecommerceQuery.records) {
    const itemId   = firstLinkedId(rec, ECOM_ITEM_FIELD);
    const strainId = firstLinkedId(rec, ECOM_STRAIN_FIELD);

    if (!itemId) continue; // ecommerce rows must have an item to participate

    const statusCell = rec.getCellValue(ECOM_STATUS_FIELD);
    const statusName = statusCell && statusCell.name ? statusCell.name : null;

    const key = keyFor(itemId, strainId);
    if (!key) continue;

    if (!ecommerceByKey.has(key)) ecommerceByKey.set(key, []);
    ecommerceByKey.get(key).push(rec);

    ecommerceMeta.set(rec.id, { rec, itemId, strainId, statusName });
  }

  if (!ecommerceByKey.size) {
    notify('No ecommerce rows with item_id set. Nothing to refresh.');
    return;
  }

  // ---------- 2) Load all products and lots; build maps by key ------
  const productsQuery = await productsTbl.selectRecordsAsync({
    fields: [PROD_ITEM_FIELD, PROD_STRAIN_FIELD, PROD_USE_BY_FIELD, PROD_STORAGE_FIELD],
  });

  const lotsQuery = await lotsTbl.selectRecordsAsync({
    fields: [LOT_ITEM_FIELD, LOT_STRAIN_FIELD, LOT_USE_BY_FIELD, LOT_STATUS_FIELD],
  });

  /** key -> array of product records */
  const productsByKey = new Map();
  /** key -> array of lot records */
  const lotsByKey = new Map();

  /** set of ecommerce IDs we will recompute */
  const ecommerceIdsToRefresh = new Set();

  // --- Scan products ---
  for (const prod of productsQuery.records) {
    const itemId   = firstLinkedId(prod, PROD_ITEM_FIELD);
    const strainId = firstLinkedId(prod, PROD_STRAIN_FIELD);
    const key = keyFor(itemId, strainId);
    if (!key) continue;

    // Only care about keys that exist in ecommerce
    if (!ecommerceByKey.has(key)) continue;

    if (!productsByKey.has(key)) productsByKey.set(key, []);
    productsByKey.get(key).push(prod);

    // Mark all ecommerce rows on this key as needing refresh
    for (const ecomRec of ecommerceByKey.get(key)) {
      ecommerceIdsToRefresh.add(ecomRec.id);
    }
  }

  // --- Scan lots ---
  for (const lot of lotsQuery.records) {
    const itemId   = firstLinkedId(lot, LOT_ITEM_FIELD);
    const strainId = firstLinkedId(lot, LOT_STRAIN_FIELD);
    const key = keyFor(itemId, strainId);
    if (!key) continue;

    if (!ecommerceByKey.has(key)) continue;

    if (!lotsByKey.has(key)) lotsByKey.set(key, []);
    lotsByKey.get(key).push(lot);

    for (const ecomRec of ecommerceByKey.get(key)) {
      ecommerceIdsToRefresh.add(ecomRec.id);
    }
  }

  if (!ecommerceIdsToRefresh.size) {
    notify('No ecommerce rows matched by any products or lots. Nothing to update.');
    return;
  }

  // ---------- 3) Recompute links for affected ecommerce rows --------

  async function recomputeForEcommerce(rec) {
    const meta = ecommerceMeta.get(rec.id);
    if (!meta) return;

    const { itemId, strainId, statusName } = meta;
    const key = keyFor(itemId, strainId);
    if (!key) return;

    const candidateProducts = productsByKey.get(key) || [];
    const candidateLots     = lotsByKey.get(key) || [];

    // Determine allowed lot statuses for this ecommerce.status
    const allowedLotStatuses = statusName && LOT_STATUS_MAP[statusName]
      ? LOT_STATUS_MAP[statusName]
      : [];

    // --- Filter candidates for products ---
    const productLinks = [];
    for (const prod of candidateProducts) {
      // Strain compatibility is already baked into the key:
      // - ecommerce.strain set  => key has that strain; only products with same strain contribute.
      // - ecommerce.strain null => key uses "NONE"; only strainless products are in this bucket.
      // So we only need to check use_by + storage_location here.

      const useBy = prod.getCellValue(PROD_USE_BY_FIELD);
      if (!isNotExpired(useBy)) continue;

      const storage = prod.getCellValue(PROD_STORAGE_FIELD);
      const storageName = storage && storage.name ? storage.name : null;
      if (storageName === 'Shipped') continue;

      productLinks.push({ id: prod.id });
    }

    // --- Filter candidates for lots ---
    const lotLinks = [];
    for (const lot of candidateLots) {
      const useBy = lot.getCellValue(LOT_USE_BY_FIELD);
      if (!isNotExpired(useBy)) continue;

      const status = lot.getCellValue(LOT_STATUS_FIELD);
      const statusNameLot = status && status.name ? status.name : null;

      if (!statusNameLot) continue;
      if (!allowedLotStatuses.includes(statusNameLot)) continue;

      lotLinks.push({ id: lot.id });
    }

    await safeUpdate(ecommerceTbl, rec.id, {
      [ECOM_PRODUCTS_FIELD]: productLinks,
      [ECOM_LOTS_FIELD]: lotLinks,
    });
  }

  // Throttle updates slightly to avoid hitting Airtable rate limits
  let refreshedCount = 0;
  for (const rec of ecommerceQuery.records) {
    if (!ecommerceIdsToRefresh.has(rec.id)) continue;
    await recomputeForEcommerce(rec);
    refreshedCount++;
  }

  const endIso = new Date().toISOString();
  notify(`ecommerce_refresh.js completed. Refreshed ${refreshedCount} ecommerce row(s). End @ ${endIso}`);

} catch (err) {
  notify(`ecommerce_refresh.js ERROR: ${err.message}`);
}
