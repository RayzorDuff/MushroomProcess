/**
 *  Script: create_product_from_lot.js
 *  Version: 2025-12-28.1
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
 *  Summary: Create a Product from a single Lot with correct weights & lineage
 *  Features:
 *  Inputs (from Interface / Automation): { lotId }
 *
 *  Behavior:
 *    - Loads the selected Lot and its Item.
 *    - Validates required fields; writes any validation errors to lots.ui_error.
 *    - Derives product.use_by per business rules (freeze-dried = +2y; else +3mo
 *      from spawned_at, inoculated_at, or today as fallback).
 *    - Sets products.origin_lots (link) and origin_lot_ids_json (JSON array).
 *    - Computes products.net_weight_g and products.net_weight_oz from Lot size:
 *        Priority for unit source:
 *          A) lots.unit_size (assumed pounds unless a unit-specific default is available)
 *          B) items.default_unit_size_lb / _g / _oz (fallbacks)
 *        Conversion: pounds to grams (lb * 453.59237), ounces (lb * 16),
 *                   grams to ounces (g / 28.349523125), ounces ? grams (oz * 28.349523125)
 *    - (Optional) Marks the source Lot as Consumed (configurable toggle).
 *
 *  Side Effects:
 *    - Creates one record in products.
 *    - Updates lots.ui_error on validation failure (and clears on success).
 *    - Optionally updates lots.status = "Consumed".
 *
 *  Idempotency: Not idempotent (each run creates a new product).
 *
 *  Safety:
 *    - Exhaustive field existence checks (won’t crash if fields are missing).
 *    - Clear, actionable ui_error messages for operators.
 *
**/

const { lotId } = input.config();

/* ---------------------------- Table Handles ---------------------------- */
const lotsTbl   = base.getTable('lots');
const itemsTbl  = base.getTable('items');
const prodsTbl  = base.getTable('products');
let strainsTbl = null;
try { strainsTbl = base.getTable('strains'); } catch { /* optional */ }

/* ------------------------------ Config -------------------------------- */
const CONSUME_SOURCE_LOT = true; // set false if you do NOT want to auto-consume lots

/* ----------------------------- Utilities ------------------------------ */
function hasField(tbl, name) { try { tbl.getField(name); return true; } catch { return false; } }
function coerceValueForField(table, fieldName, valueStr) {
  if (!valueStr) return null;
  const f = table.getField(fieldName);
  if (f.type === 'singleSelect') return { name: valueStr };
  return valueStr; // singleLineText, etc.
}
function getStr(rec, field) {
  try { return (rec.getCellValueAsString(field) || '').trim(); } catch { return ''; }
}
function getLinkedFirst(rec, field) {
  try { return (rec.getCellValue(field) || [])[0] || null; } catch { return null; }
}
function getNum(rec, field) {
  try {
    const val = rec.getCellValue(field);
    if (val == null) return null;
    if (typeof val === 'number') return val;
    const parsed = Number(getStr(rec, field));
    return Number.isFinite(parsed) ? parsed : null;
  } catch { return null; }
}
function datePlus(dateLike, { days = 0, months = 0, years = 0 }) {
  const d = new Date(dateLike);
  if (Number.isNaN(d.getTime())) return null;
  d.setFullYear(d.getFullYear() + years);
  d.setMonth(d.getMonth() + months);
  d.setDate(d.getDate() + days);
  return d;
}
function isTruthy(v) { return !!(v || v === 0); }
function toJSON(value) { try { return JSON.stringify(value); } catch { return '[]'; } }

/* Strain helpers (supports migrating products.strain_id from lookup to link) */
async function buildStrainIdMap() {
  const map = new Map(); // key: normalized strain_id string -> strains record id
  if (!strainsTbl) return map;
  try {
    const q = await strainsTbl.selectRecordsAsync({ fields: ['strain_id'] });
    for (const r of q.records) {
      const sid = (r.getCellValueAsString('strain_id') || '').trim();
      if (sid) map.set(sid.toLowerCase(), r.id);
    }
  } catch {}
  return map;
}

function uniqLinks(links) {
  const out = [];
  const seen = new Set();
  for (const l of (links || [])) {
    const id = l?.id;
    if (id && !seen.has(id)) { seen.add(id); out.push({ id }); }
  }
  return out;
}
function resolveStrainLinksFromLot(lotRec, strainIdMap) {
  // Prefer direct link field on lots.strain_id
  try {
    const v = lotRec.getCellValue('strain_id');
    if (Array.isArray(v) && v.length) {
      // If v is already an array of linked record objects, use their ids
      if (v[0] && typeof v[0] === 'object' && v[0].id) return uniqLinks(v);
      // If v is an array of strings (lookup), map by strains.strain_id
      const mapped = v
        .map(x => (typeof x === 'string' ? x.trim() : (x?.name || '').trim()))
        .filter(Boolean)
        .map(s => strainIdMap.get(s.toLowerCase()))
        .filter(Boolean)
        .map(id => ({ id }));
      if (mapped.length) return uniqLinks(mapped);
    }
  } catch {}

  // Fall back to cell string (covers singleLineText / formula / other)
  const s = (getStr(lotRec, 'strain_id') || '').trim();
  if (s) {
    const id = strainIdMap.get(s.toLowerCase());
    if (id) return [{ id }];
  }
  return [];
}

/* Unit conversions */
const LB_TO_G  = 453.59237;
const OZ_TO_G  = 28.349523125;
const G_TO_OZ  = (g) => g / OZ_TO_G;

/* “best effort” weight resolver from lot + item defaults
   Returns { grams, ounces } or null if cannot determine.
*/
function resolveWeights({ lot, lotUnitSize, item }) {
  // Prefer explicit lot.unit_size as pounds when present.
  if (isTruthy(lotUnitSize)) {
    const lb = Number(lotUnitSize);
    if (Number.isFinite(lb) && lb > 0) {
      const grams = lb * LB_TO_G;
      const ounces = lb * 16;
      return { grams, ounces };
    }
  }

  // Fall back to item defaults if present (exact unit priority: grams, ounces, pounds)
  const itemG  = getNum(item, 'default_unit_size_g');
  if (Number.isFinite(itemG) && itemG > 0) {
    return { grams: itemG, ounces: G_TO_OZ(itemG) };
  }
  const itemOz = getNum(item, 'default_unit_size_oz');
  if (Number.isFinite(itemOz) && itemOz > 0) {
    const grams = itemOz * OZ_TO_G;
    return { grams, ounces: itemOz };
  }
  const itemLb = getNum(item, 'default_unit_size_lb');
  if (Number.isFinite(itemLb) && itemLb > 0) {
    const grams = itemLb * LB_TO_G;
    return { grams, ounces: itemLb * 16 };
  }

  // Last resort: if item.default_unit_size exists as a number, assume POUNDS
  const itemGeneric = getNum(item, 'default_unit_size');
  if (Number.isFinite(itemGeneric) && itemGeneric > 0) {
    const grams = itemGeneric * LB_TO_G;
    return { grams, ounces: itemGeneric * 16 };
  }

  // Could not determine
  return null;
}

/* Helper: write ui_error to lots (non-throwing) */
async function setLotError(lotRec, message) {
  if (!hasField(lotsTbl, 'ui_error')) return;
  try { await lotsTbl.updateRecordAsync(lotRec.id, { ui_error: message }); } catch {}
}
/* Helper: clear ui_error on success */
async function clearLotError(lotRec) {
  if (!hasField(lotsTbl, 'ui_error')) return;
  try { await lotsTbl.updateRecordAsync(lotRec.id, { ui_error: '' }); } catch {}
}

/* ------------------------------ Validate ------------------------------ */
if (!lotId) throw new Error('lotId was not provided by the interface.');

const lot = await lotsTbl.selectRecordAsync(lotId);
if (!lot) throw new Error('Lot not found.');

const lotIdText = getStr(lot, 'lot_id') || lot.id;
const lotItemLink = getLinkedFirst(lot, 'item_id');
if (!lotItemLink) {
  await setLotError(lot, 'Validation: item_id is required on lot before productizing.');
  throw new Error('Validation failed: lot.item_id missing.');
}

const lotItem = await itemsTbl.selectRecordAsync(lotItemLink.id);
if (!lotItem) {
  await setLotError(lot, 'Validation: linked Item not found.');
  throw new Error('Validation failed: linked Item not found.');
}

/* Weight resolution */
const lotUnitSize = getNum(lot, 'unit_size'); // generally in pounds for your packaged inputs
const resolved = resolveWeights({ lot, lotUnitSize, item: lotItem });
if (!resolved) {
  await setLotError(lot,
    'Validation: Unable to determine net weight. ' +
    'Provide lots.unit_size (lbs) or item default size (lb/g/oz).'
  );
  throw new Error('Validation failed: net weight could not be derived.');
}
const netG  = Number(resolved.grams.toFixed(2));
const netOz = Number(resolved.ounces.toFixed(2));

/* -------------------------- Pack & Use-by Rules ----------------------- */
const now = new Date();
const inocAt  = lot.getCellValue('inoculated_at') || null;
const spawnAt = lot.getCellValue('spawned_at') || null;

const itemNameRaw = getStr(lotItem, 'name');
const itemCatRaw  = getStr(lotItem, 'category');

const itemName = itemNameRaw.toLowerCase();
const itemCat  = itemCatRaw.toLowerCase();

const isFreezeDried =
  itemCat === 'freezedriedmushrooms' || itemName.includes('freeze dried');

const packDate = now;
const useBy = isFreezeDried
  ? datePlus(packDate, { years: 2 })
  : (spawnAt ? datePlus(spawnAt, { months: 3 })
    : (inocAt ? datePlus(inocAt, { months: 3 })
      : datePlus(packDate, { months: 3 })));

if (!useBy) {
  await setLotError(lot, 'Validation: Could not compute use_by date.');
  throw new Error('Validation failed: use_by date computation failed.');
}

/* -------------------------- Create the Product ------------------------ */
const wantsOriginLotIdsJson = hasField(prodsTbl, 'origin_lot_ids_json');
const wantsNetG = hasField(prodsTbl, 'net_weight_g');
const wantsNetOz = hasField(prodsTbl, 'net_weight_oz');

const createPayload = {
  // lineage
  origin_lots: [{ id: lot.id }],
  // item
  item_id: [{ id: lotItem.id }],
  // dates
  pack_date: packDate,
  use_by: useBy
};
if (wantsOriginLotIdsJson) createPayload.origin_lot_ids_json = toJSON([lotIdText]);
if (wantsNetG)  createPayload.net_weight_g  = netG;
if (wantsNetOz) createPayload.net_weight_oz = netOz;

// Strain: set products.strain_id as a direct link (if the field exists)
if (hasField(prodsTbl, 'strain_id')) {
  const strainIdMap = await buildStrainIdMap();
  const strainLinks = resolveStrainLinksFromLot(lot, strainIdMap);
  if (strainLinks.length) createPayload.strain_id = strainLinks;
}

if (hasField(prodsTbl, 'name_mat')) {
  const v = coerceValueForField(prodsTbl, 'name_mat', itemNameRaw);
  if (v != null) createPayload.name_mat = v;
}
if (hasField(prodsTbl, 'item_category_mat')) {
  const v = coerceValueForField(prodsTbl, 'item_category_mat', itemCatRaw);
  if (v != null) createPayload.item_category_mat = v;
}

let prodId = null;
try {
  prodId = await prodsTbl.createRecordAsync(createPayload);
} catch (e) {
  await setLotError(lot, `Error while creating product: ${e.message || e}`);
  throw e;
}

/* ----------------------- Post-Create Updates -------------------------- */
// Clear any prior errors on success
await clearLotError(lot);

// Optionally mark the source lot as Consumed
if (CONSUME_SOURCE_LOT && hasField(lotsTbl, 'status')) {
  try {
    await lotsTbl.updateRecordAsync(lot.id, { status: { name: 'Consumed' } });
  } catch (e) {
    // Non-fatal: status option might not exist in this base
  }
}

/* ---------------------------- Output Result --------------------------- */
try {
  output.set('result', `Product ${prodId} created from lot ${lotIdText} (net: ${netG} g / ${netOz} oz)`);
} catch {}
