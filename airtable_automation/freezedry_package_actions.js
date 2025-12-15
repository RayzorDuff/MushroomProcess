/**
 * Script: freezedry_package_actions.js
 * Version: 2025-10-16.1
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
 * Summary: Freeze Dry & Package – Actions
 * Notes: Succinct header; no diff blocks; try/catch + error surfacing.
 */
try {


const { productId } = input.config();

const productsTbl = base.getTable('products');
const eventsTbl   = base.getTable('events');

const src = await productsTbl.selectRecordAsync(productId);
if (!src) throw new Error('Source product not found');

// Read inputs
const packageItem        = src.getCellValue('package_item')?.[0] || null;
const packageItemCategory= (src.getCellValueAsString('package_item_category') || '').toLowerCase(); // lookup from items.category
const trayState          = (src.getCellValueAsString('tray_state') || '').toLowerCase();
const sizeG              = Number(src.getCellValue('package_size_g') ?? NaN);
const count              = Number(src.getCellValue('package_count') ?? NaN);
const driedG             = Number(src.getCellValue('dried_weight_g') ?? NaN);
const useBy              = src.getCellValue('use_by');
const loc                = src.getCellValue('storage_location')?.[0] || null;

// Validate
const errs = [];
if (trayState !== 'freezer_tray') errs.push('Packaging requires tray_state = freezer_tray.');
if (!packageItem) errs.push('Select package_item (retail SKU).');
if (packageItemCategory !== 'freezedriedmushrooms') errs.push('package_item must have category "freezedriedmushrooms".');
if (!Number.isFinite(sizeG) || sizeG <= 0) errs.push('Set package_size_g to a positive number.');
if (!Number.isFinite(count) || count < 1) errs.push('Set package_count to 1 or more.');
if (!Number.isFinite(driedG) || driedG <= 0) errs.push('Enter dried_weight_g before packaging.');

function hasField(tbl, name) { try { tbl.getField(name); return true; } catch { return false; } }
function coerceValueForField(table, fieldName, valueStr) {
  if (!valueStr) return null;
  const f = table.getField(fieldName);
  if (f.type === 'singleSelect') return { name: valueStr };
  return valueStr; // singleLineText, etc.
}
if (errs.length) {
  await productsTbl.updateRecordAsync(src.id, {
    ui_error: errs.join(' '),
    ui_error_at: new Date().toISOString(),
    action: null
  });
  throw new Error('PackageFreezeDried validation failed.');
}

// Clear previous errors
await productsTbl.updateRecordAsync(src.id, { ui_error: null, ui_error_at: null });

// Compute use_by (2 years default)
function addYearsISO(iso, years) { const d = new Date(iso); d.setFullYear(d.getFullYear() + years); return d.toISOString(); }
const nowIso = new Date().toISOString();
const finalUseBy = useBy || addYearsISO(nowIso, 2);

// Gather origins
let origins = [];
const originLinks = src.getCellValue('origin_lots') || [];
if (originLinks.length) {
  origins = originLinks.map(o => o.id);
} else {
  try {
    const j = JSON.parse(src.getCellValueAsString('origin_lot_ids_json') || '[]');
    if (Array.isArray(j)) origins = j;
  } catch {}
}

// Create finished packaged products
const batch = [];
for (let i = 0; i < count; i++) {
  const f = {
    item_id: [{ id: packageItem.id }],
    origin_lot_ids_json: JSON.stringify(origins),
    origin_lots: origins.map(id => ({ id })),
    net_weight_g: sizeG,
    pack_date: nowIso,
    use_by: finalUseBy
  };
  if (loc) f.storage_location = [{ id: loc.id }];

  if (hasField(productsTbl, 'name_mat')) {
    const v = coerceValueForField(productsTbl, 'name_mat', packageItem.getCellValueAsString('name') || '');
    if (v != null) f.name_mat = v;
  }
  if (hasField(productsTbl, 'item_category_mat')) {
    const v = coerceValueForField(productsTbl, 'item_category_mat', packageItem.getCellValueAsString('category') || '');
    if (v != null) f.item_category_mat = v;
  }

  batch.push({ fields: f });
}
for (let i = 0; i < batch.length; i += 50) {
  await productsTbl.createRecordsAsync(batch.slice(i, i + 50));
}

// Log Package on origin lots (audit)
const evtTypeField = eventsTbl.getField('type');
const packageEvt = (evtTypeField.options?.choices || []).find(c => c.name === 'Package');
if (packageEvt && origins.length) {
  const tsWritable = (() => { try { return eventsTbl.getField('timestamp').type === 'dateTime'; } catch { return false; }})();
  const eBatch = origins.slice(0, 50).map(lotId => {
    const f = {
      lot_id: [{ id: lotId }],
      type: { id: packageEvt.id },
      station: 'Packaging Freeze-Dried',
      fields_json: JSON.stringify({
        from_product_id: src.id,
        package_item_id: packageItem.id,
        package_size_g: sizeG,
        package_count: count
      })
    };
    if (tsWritable) f.timestamp = nowIso;
    return { fields: f };
  });
  for (let i = 0; i < eBatch.length; i += 50) {
    await eventsTbl.createRecordsAsync(eBatch.slice(i, i + 50));
  }
}

// ✅ Mark the tray product as empty so it disappears from the filtered interface
const trayStateField = productsTbl.getField('tray_state');
const emptyChoice = (trayStateField.options?.choices || []).find(c => c.name === 'empty_tray');
if (!emptyChoice) throw new Error('products.tray_state missing "empty_tray".');
await productsTbl.updateRecordAsync(src.id, { tray_state: { id: emptyChoice.id }, action: null });

} catch (e) {
  if (typeof output !== 'undefined' && output && output.set) {
    output.set('error', (e && e.message) ? e.message : String(e));
  }
}
