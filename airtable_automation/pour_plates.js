/**
 * Script: pour_plates.js
 * Version: 2025-10-27.2
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

  const sourceLot = await lotsTbl.selectRecordAsync(sourceLotId);
  if (!sourceLot) throw new Error("Source lot not found");

  const errors = [];

  const action = sourceLot.getCellValueAsString('action');
  const plateCount = Number(sourceLot.getCellValue('plate_count'));
  const category = sourceLot.getCellValueAsString('item_category');
  const sourceRecipe = sourceLot.getCellValue('recipe_id')?.[0];

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

  // Clear errors and action
  await lotsTbl.updateRecordAsync(sourceLot.id, {
    ui_error: null,
    action: null
  });

  const plateGroupId = `PLATEGRP-${Date.now()}`;
  const platesToCreate = [];

  for (let i = 0; i < plateCount; i++) {
    platesToCreate.push({
      item_id: [{ id: plateItem.id }],
      recipe_id: [{ id: sourceRecipe.id }],
      parent_lot_id: [{ id: sourceLot.id }],
      plate_group_id: plateGroupId,
      qty: 1
    });
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
