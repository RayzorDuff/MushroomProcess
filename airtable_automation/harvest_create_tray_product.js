/**
 * Script: harvest_create_tray_product.js
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
 * Summary: Harvest – Create Tray Product
 * Notes: Succinct header; no diff blocks; try/catch + error surfacing.
 */
try {


const { blockLotId } = input.config();

const lotsTbl     = base.getTable('lots');
const itemsTbl    = base.getTable('items');
const productsTbl = base.getTable('products');
const eventsTbl   = base.getTable('events');

//for (const f of productsTbl.fields) {
//  console.log('products', `${f.id} :: ${f.name} [${f.type}]`);
//}

//for (const e of eventsTbl.fields) {
//  console.log('events', `${e.id} :: ${e.name} [${e.type}]`);
//}

function hasField(tbl, name) { try { tbl.getField(name); return true; } catch { return false; } }

const block = await lotsTbl.selectRecordAsync(blockLotId);
if (!block) throw new Error('Fruiting block not found');

const weightG     = Number(block.getCellValue('harvest_weight_g') ?? NaN);
const flushNo     = Number(block.getCellValue('flush_no') ?? NaN);
const harvestItems = block.getCellValue('harvest_item') || [];
const freshTrayCount  = Math.floor(Number(block.getCellValue('fresh_tray_count') ?? 0));
const frozenTrayCount = Math.floor(Number(block.getCellValue('frozen_tray_count') ?? 0));

const errs = [];
if (!Number.isFinite(weightG) || weightG <= 0) errs.push('Enter harvest_weight_g (positive).');
if (!Number.isFinite(flushNo) || flushNo <= 0) errs.push('Enter flush_no (1,2,3…).');
if (!harvestItems.length) errs.push('Select harvest_item (one or more).');
if (errs.length) {
  const msg = errs.join(' ');
  await lotsTbl.updateRecordAsync(block.id, { ui_error: msg, ui_error_at: new Date().toISOString(), action: null });
  throw new Error(`Harvest validation failed: ${msg}`);
}

// Load all selected harvest items so we can allocate trays across them
const itemRecs = [];
for (const it of harvestItems) {
  const rec = await itemsTbl.selectRecordAsync(it.id);
  if (rec) itemRecs.push(rec);
}
if (!itemRecs.length) throw new Error('No harvest_item records could be loaded.');

if (hasField(productsTbl, 'name_mat')) productsTbl; // no-op; just confirms existence
function coerceValueForField(table, fieldName, valueStr) {
  if (!valueStr) return null;
  const f = table.getField(fieldName);
  if (f.type === 'singleSelect') return { name: valueStr };
  return valueStr; // singleLineText, etc.
}

// Look up the harvest item's category to seed tray_state
const itemCat = itemRec?.getCellValueAsString('category')?.toLowerCase() || '';
if (!['fresh_tray','freezer_tray'].includes(itemCat)) {
  // allow it but warn on the record; default to freezer_tray to keep the flow moving
  await lotsTbl.updateRecordAsync(block.id, { ui_error: `harvest_item.category "${itemCat}" not in {fresh_tray, freezer_tray}. Defaulting tray_state=freezer_tray.` });
}

// Partition selected items by category
const byCat = { fresh_tray: [], freezer_tray: [] };
for (const r of itemRecs) {
  const c = (r.getCellValueAsString('category') || '').toLowerCase();
  if (c === 'fresh_tray') byCat.fresh_tray.push(r);
  else if (c === 'freezer_tray') byCat.freezer_tray.push(r);
  else {
    await lotsTbl.updateRecordAsync(block.id, { ui_error: `harvest_item.category "${c}" not in {fresh_tray, freezer_tray}. Ignoring this item.` });
  }
}

// Determine total tray counts per category (only if category is selected)
const wantFresh  = byCat.fresh_tray.length > 0;
const wantFrozen = byCat.freezer_tray.length > 0;
if (wantFresh && freshTrayCount <= 0) errs.push('fresh_tray_count must be >= 1 when a fresh_tray harvest_item is selected.');
if (wantFrozen && frozenTrayCount <= 0) errs.push('frozen_tray_count must be >= 1 when a freezer_tray harvest_item is selected.');
if (errs.length) {
  const msg = errs.join(' ');
  await lotsTbl.updateRecordAsync(block.id, { ui_error: msg, ui_error_at: new Date().toISOString(), action: null });
  throw new Error(`Harvest validation failed: ${msg}`);
}

// Resolve tray_state choices
const productsTrayStateField = productsTbl.getField('tray_state');
const trayChoiceFresh  = (productsTrayStateField.options?.choices || []).find(c => c.name === 'fresh_tray')  || null;
const trayChoiceFrozen = (productsTrayStateField.options?.choices || []).find(c => c.name === 'freezer_tray') || null;
if (wantFresh && !trayChoiceFresh) throw new Error('products.tray_state missing "fresh_tray".');
if (wantFrozen && !trayChoiceFrozen) throw new Error('products.tray_state missing "freezer_tray".');
 
// Optional: copy strain from block (purely for display via lookups you already added)
const srcStrain = block.getCellValue('strain_id')?.[0] || null;

const nowIso = new Date().toISOString();
const originPayload = {
  origin_lot_ids_json: JSON.stringify([block.id]),
  origin_lots: [{ id: block.id }],
  pack_date: nowIso
};

// Allocate trays across items within a category (split evenly, remainder to first items)
function allocateCounts(total, recs) {
  if (!recs.length) return [];
  const base = Math.floor(total / recs.length);
  let rem = total % recs.length;
  return recs.map(r => ({ rec: r, n: base + (rem-- > 0 ? 1 : 0) }));
}

const allocations = [
  ...(wantFresh ? allocateCounts(freshTrayCount, byCat.fresh_tray).map(x => ({ ...x, trayChoice: trayChoiceFresh })) : []),
  ...(wantFrozen ? allocateCounts(frozenTrayCount, byCat.freezer_tray).map(x => ({ ...x, trayChoice: trayChoiceFrozen })) : []),
].filter(x => x.n > 0);

const totalTrays = allocations.reduce((s, a) => s + a.n, 0);
const perTrayWeightG = weightG / totalTrays;

const createBatch = [];
for (const a of allocations) {
  const itemNameRaw = a.rec.getCellValueAsString('name') || '';
  const itemCatRaw  = a.rec.getCellValueAsString('category') || '';
  for (let i = 0; i < a.n; i++) {
    const fields = {
      ...originPayload,
      item_id: [{ id: a.rec.id }],
      tray_state: { id: a.trayChoice.id },
      net_weight_g: perTrayWeightG
    };
    if (hasField(productsTbl, 'name_mat')) {
      const v = coerceValueForField(productsTbl, 'name_mat', itemNameRaw);
      if (v != null) fields.name_mat = v;
    }
    if (hasField(productsTbl, 'item_category_mat')) {
      const v = coerceValueForField(productsTbl, 'item_category_mat', itemCatRaw);
      if (v != null) fields.item_category_mat = v;
    }
    createBatch.push({ fields });
  }
}

// Create products in chunks (Airtable limit 50)
const productIds = [];
for (let i = 0; i < createBatch.length; i += 50) {
  const ids = await productsTbl.createRecordsAsync(createBatch.slice(i, i + 50));
  productIds.push(...ids);
}

// Log HARVEST on the source lot
const evtTypeField = eventsTbl.getField('type');
const harvestEvt = (evtTypeField.options?.choices || []).find(c => c.name === 'Harvest');
const tsWritable = (() => { try { return eventsTbl.getField('timestamp').type === 'dateTime'; } catch { return false; }})();
if (harvestEvt) {
  const e = {
    fields: {
      lot_id: [{ id: block.id }],
      type: { id: harvestEvt.id },
      station: 'Harvest',
      fields_json: JSON.stringify({
        created_product_ids: productIds,
        harvest_weight_g: weightG,
        flush_no: flushNo,
        fresh_tray_count: wantFresh ? freshTrayCount : 0,
        frozen_tray_count: wantFrozen ? frozenTrayCount : 0,
        total_trays: totalTrays,
        per_tray_weight_g: perTrayWeightG
      })
    }
  };
  if (tsWritable) e.fields.timestamp = nowIso;
  await eventsTbl.createRecordsAsync([e]);
}

// Clear trigger/error
await lotsTbl.updateRecordAsync(block.id, { action: null, ui_error: null, ui_error_at: null });

try { output.set('created_product_ids', productIds); } catch {}

} catch (e) {
  if (typeof output !== 'undefined' && output && output.set) {
    output.set('error', (e && e.message) ? e.message : String(e));
  }
}
