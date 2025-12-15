/**
 * Script: pour_plates.js
 * Version: 2025-10-31.1
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
 * Summary: Pour Plates – Create sterilized plates from an agar flask lot
 * Notes: Triggered from 'PourPlates' action in 'lots'. Requires:
 *        - lots.plate_count (must be > 0)
 *        - lots.item_category = "agar_flask"
 *        - lots.recipe_id and other references in source lot
 */

try {
  const { sourceLotId } = input.config();

  const lotsTbl = base.getTable('lots');
  const eventsTbl = base.getTable('events');
  const itemsTbl = base.getTable('items');
  
  //for (const f of lotsTbl.fields) {
  //  console.log('lots', `${f.id} :: ${f.name} [${f.type}]`);
  //}
  //for (const e of eventsTbl.fields) {
  //  console.log('events', `${e.id} :: ${e.name} [${e.type}]`);
  //}

  function hasField(tbl, name) { try { tbl.getField(name); return true; } catch { return false; } }
  function coerceValueForField(table, fieldName, valueStr) {
    if (!valueStr) return null;
    const f = table.getField(fieldName);
    if (f.type === 'singleSelect') return { name: valueStr };
    return valueStr; // singleLineText, etc.
  }
  const sourceLot = await lotsTbl.selectRecordAsync(sourceLotId);
  if (!sourceLot) throw new Error("Source lot not found");

  const errors = [];

  const action = sourceLot.getCellValueAsString('action');
  const plateCount = Number(sourceLot.getCellValue('plate_count'));
  const category = sourceLot.getCellValueAsString('item_category');
  const sourceRecipe = sourceLot.getCellValue('recipe_id')?.[0];
  const sourceStatus = sourceLot.getCellValueAsString('status') || "Sterilized";

  //if (action !== 'PourPlates') {
  //  await lotsTbl.updateRecordAsync(sourceLot.id, { action: null });
  //  return;
  //}

  if (!Number.isFinite(plateCount) || plateCount <= 0) {
    errors.push(`Plate count must be greater than 0 (got ${plateCount})`);
  }

  if (category !== 'agar_flask') {
    errors.push(`Expected item_category to be 'agar_flask', found '${category}'`);
  }

  if (!sourceRecipe) {
    errors.push(`Missing recipe_id on source lot`);
  }

  if (errors.length > 0) {
    await lotsTbl.updateRecordAsync(sourceLot.id, {
      ui_error: errors.join('; '),
      action: null
    });
    throw new Error("Validation failed");
  }

  // Look up the item_id for 'AGAR-PLATE'
  const itemsQuery = await itemsTbl.selectRecordsAsync();
  const plateItem = itemsQuery.records.find(rec =>
    rec.getCellValueAsString('item_id') === 'AGAR-PLATE'
  );

  if (!plateItem) {
    throw new Error("Item 'AGAR-PLATE' not found in items table.");
  }

  const plateGroupId = `PLATEGRP-${Date.now()}`;
  
  // Clear errors and action
  // ? Mark source agar flask as consumed
  await lotsTbl.updateRecordAsync(sourceLot.id, {
    ui_error: null,
    status: { name: 'Consumed' },
    plate_group_id: plateGroupId,
    action: null
  });
  
  const platesToCreate = [];

  for (let i = 0; i < plateCount; i++) {
    const rec = {
      item_id: [{ id: plateItem.id }],
      recipe_id: [{ id: sourceRecipe.id }],
      parent_lot_id: [{ id: sourceLot.id }],
      status: { name: sourceStatus },
      plate_group_id: plateGroupId,
    };
  
    const itemName = plateItem?.getCellValueAsString('name') || '';
    const itemCat  = plateItem?.getCellValueAsString('category') || '';
  
    if (hasField(lotsTbl, 'item_name_mat')) {
      const v = coerceValueForField(lotsTbl, 'item_name_mat', itemName);
      if (v != null) rec.item_name_mat = v;
    }
    if (hasField(lotsTbl, 'item_category_mat')) {
      const v = coerceValueForField(lotsTbl, 'item_category_mat', itemCat);
      if (v != null) rec.item_category_mat = v;
    }
  
    platesToCreate.push(rec);
  }
  
  const createdPlateIds = [];
  for (let i = 0; i < platesToCreate.length; i += 50) {
    const batch = await lotsTbl.createRecordsAsync(
      platesToCreate.slice(i, i + 50).map(fields => ({ fields }))
    );
    createdPlateIds.push(...batch.map(r => r.id));
  }

  const tsField = eventsTbl.getField('timestamp');
  const supportsTimestamp = tsField?.type === 'dateTime';
  const now = new Date();

  await eventsTbl.createRecordAsync({
    lot_id: [{ id: sourceLot.id }],
    type: { name: 'PlatesPoured' },
    station: 'Pour Plates',
    fields_json: JSON.stringify({
      plate_group_id: plateGroupId,
      plate_count: plateCount,
      recipe_id: sourceRecipe.name,
      created_plate_ids: createdPlateIds
    }),
    ...(supportsTimestamp && { timestamp: now })
  });

} catch (err) {
  if (typeof output !== 'undefined' && output?.set) {
    output.set('error', err.message || String(err));
  }
}
