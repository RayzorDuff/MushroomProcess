/**
 * Script: lc_draw_syringes.js
 * Version: 2025-12-15.2
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
 * Summary: LC Draw Syringes (from flask) – validates and creates syringe lots, decrements flask volume
 * Notes: Succinct header; no diff blocks; try/catch + error surfacing.
 */
try {


const { flaskLotId } = input.config();

const lotsTbl     = base.getTable('lots');
const itemsTbl    = base.getTable('items');
const productsTbl = base.getTable('products');
const eventsTbl   = base.getTable('events');

function hasField(tbl, name) {
  try { tbl.getField(name); return true; } catch { return false; }
}

function coerceValueForField(table, fieldName, valueStr) {
  if (!valueStr) return null;
  const f = table.getField(fieldName);
  if (f.type === 'singleSelect') return { name: valueStr };
  return valueStr; // singleLineText, etc.
}

function datePlus(date, {days=0, months=0, years=0}) {
  const d = new Date(date);
  d.setDate(d.getDate() + days);
  d.setMonth(d.getMonth() + months);
  d.setFullYear(d.getFullYear() + years);
  return d;
}

// ---- Load the flask row
const flask = await lotsTbl.selectRecordAsync(flaskLotId);
if (!flask) throw new Error('Flask lot not found');

const rawAction = (flask.getCellValueAsString('action') || '').trim();
if (rawAction !== 'MakeSyringes') {
  // Not our action; clear and exit quietly
  if (hasField(lotsTbl, 'action')) await lotsTbl.updateRecordAsync(flask.id, { action: null });
  return;
}

// ---- Read inputs
const syringeItem = flask.getCellValue('syringe_item')?.[0] || null;
const syringeCount = Number(flask.getCellValue('syringe_count') ?? NaN);
const currentVol = Number(flask.getCellValue('remaining_volume_ml') ?? NaN);

// Optional fields (only used if present)
const storageLocFieldExists = hasField(productsTbl, 'storage_location');
const originLotsFieldExists = hasField(productsTbl, 'origin_lots'); // link to lots on products
const netVolFieldExists     = hasField(productsTbl, 'net_volume_ml'); // if you track 10ml explicitly

// ---- Validate
const errs = [];
if (!syringeItem) errs.push('Select a syringe_item (the 10ml syringe SKU).');
if (!Number.isFinite(syringeCount) || syringeCount < 1) errs.push('syringe_count must be ≥ 1.');
if (!Number.isFinite(currentVol) || currentVol < 0) errs.push('remaining_volume_ml on the flask must be set (≥ 0).');

const usedVolume = Number.isFinite(syringeCount) ? syringeCount * 10 : NaN; // 10 ml per syringe
if (Number.isFinite(currentVol) && Number.isFinite(usedVolume) && currentVol < usedVolume) {
  errs.push(`Not enough LC volume. Need ${usedVolume} ml, have ${currentVol} ml.`);
}

if (errs.length) {
  const toUpdate = { };
  if (hasField(lotsTbl, 'ui_error'))    toUpdate.ui_error = errs.join(' ');
  if (hasField(lotsTbl, 'ui_error_at')) toUpdate.ui_error_at = new Date().toISOString();
  if (hasField(lotsTbl, 'action'))      toUpdate.action = null;
  if (Object.keys(toUpdate).length) await lotsTbl.updateRecordAsync(flask.id, toUpdate);
  throw new Error('LC – Make Syringes validation failed.');
}

// ---- Load syringe item record (for materialized product fields)
const syringeItemRec = syringeItem ? await itemsTbl.selectRecordAsync(syringeItem.id) : null;
const syringeItemName = syringeItemRec?.getCellValueAsString('name') || '';
const syringeItemCat  = syringeItemRec?.getCellValueAsString('category') || '';

// ---- Create syringe products
const nowIso = new Date().toISOString();
const prodBatch = [];
for (let i = 0; i < syringeCount; i++) {
  const f = {
    item_id: [{ id: syringeItem.id }],
    origin_lot_ids_json: JSON.stringify([flask.id]),
    pack_date: nowIso,
    use_by : datePlus(nowIso, { months: 3 }),
  };
  if (originLotsFieldExists) f.origin_lots = [{ id: flask.id }]; // if you keep a direct link
  if (netVolFieldExists)     f.net_volume_ml = 10;               // optional, if you track per-product volume
  // If you store products' location, copy from flask.location_id (optional)
  const flaskLoc = flask.getCellValue('location_id')?.[0] || null;
  if (storageLocFieldExists && flaskLoc) f.storage_location = [{ id: flaskLoc.id }];

  // Materialize product fields (type-safe)
  if (hasField(productsTbl, 'name_mat')) {
    const v = coerceValueForField(productsTbl, 'name_mat', syringeItemName);
    if (v != null) f.name_mat = v;
  }
  if (hasField(productsTbl, 'item_category_mat')) {
    const v = coerceValueForField(productsTbl, 'item_category_mat', syringeItemCat);
    if (v != null) f.item_category_mat = v;
  }

  prodBatch.push({ fields: f });
}

// Create in chunks to be safe
for (let i = 0; i < prodBatch.length; i += 50) {
  await productsTbl.createRecordsAsync(prodBatch.slice(i, i + 50));
}

// ---- Decrement flask volume
const remaining = Math.max(currentVol - usedVolume, 0);
await lotsTbl.updateRecordAsync(flask.id, { remaining_volume_ml: remaining });

// ---- Log event: SyringesDrawn
const evtTypeField = eventsTbl.getField('type');
const evt = (evtTypeField.options?.choices || []).find(c => c.name === 'SyringesDrawn');
if (evt) {
  const tsWritable = (() => { try { return eventsTbl.getField('timestamp').type === 'dateTime'; } catch { return false; }})();
  const rec = {
    fields: {
      lot_id: [{ id: flask.id }],
      type: { id: evt.id },
      station: 'LC – Make Syringes',
      fields_json: JSON.stringify({
        syringe_item_id: syringeItem.id,
        syringe_count: syringeCount,
        used_volume_ml: usedVolume,
        remaining_volume_ml: remaining
      })
    }
  };
  if (tsWritable) rec.fields.timestamp = nowIso;
  await eventsTbl.createRecordsAsync([rec]);
}

// ---- Clear action & any prior error
const clearFields = {};
if (hasField(lotsTbl, 'action'))      clearFields.action = null;
if (hasField(lotsTbl, 'ui_error'))    clearFields.ui_error = null;
if (hasField(lotsTbl, 'ui_error_at')) clearFields.ui_error_at = null;
if (Object.keys(clearFields).length) await lotsTbl.updateRecordAsync(flask.id, clearFields);

} catch (e) {
  if (typeof output !== 'undefined' && output && output.set) {
    output.set('error', (e && e.message) ? e.message : String(e));
  }
}
