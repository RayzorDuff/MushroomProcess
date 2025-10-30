/**
 * Script: inoculate.js
 * Version: 2025-10-29.1
 * Summary: Inoculate grain or LC flasks from LC flask or syringe.
 * Requirements:
 * - lot must link to one LC lot
 * - LC lot must have sufficient remaining volume
 * - records `Inoculate` event
 * - marks lot Colonizing, updates volume, clears action
 */

try {
  const lotsTbl = base.getTable('lots');
  const itemsTbl = base.getTable('items');
  const eventsTbl = base.getTable('events');

  const { lotRecordId } = input.config();
  if (!lotRecordId) throw new Error('Missing lotRecordId');

  const targetLot = await lotsTbl.selectRecordAsync(lotRecordId);
  if (!targetLot) throw new Error('Lot not found');

  // Helpers
  const updateError = async (msg) => {
    await lotsTbl.updateRecordAsync(lotRecordId, { ui_error: msg });
    output.set('error', msg);
  };
  const clearError = async () => {
    await lotsTbl.updateRecordAsync(lotRecordId, { ui_error: '' });
  };

  // Get input fields from lot
  const lcLinks = targetLot.getCellValue('lc_lot_id') ?? [];
  const volumeMl = targetLot.getCellValue('lc_volume_ml');
  const overrideTime = targetLot.getCellValue('override_inoc_time');
  const inocTime = overrideTime ? new Date(overrideTime) : new Date();

  const itemLink = targetLot.getCellValue('item_id')?.[0];
  const recipeLink = targetLot.getCellValue('recipe_id')?.[0];

  if (!itemLink) return await updateError('Must link an item.');
  if (!recipeLink) return await updateError('Must link a recipe.');
  if (!volumeMl || typeof volumeMl !== 'number' || volumeMl <= 0) {
    return await updateError('Must enter a positive LC volume (ml).');
  }
  if (lcLinks.length !== 1) return await updateError('Must link exactly one LC lot.');

  const targetItem = await itemsTbl.selectRecordAsync(itemLink.id);
  const targetCategory = (targetItem?.getCellValueAsString('category') || '').toLowerCase();
  if (!['grain', 'lc_flask'].includes(targetCategory)) {
    return await updateError(`Target must be grain or lc_flask (got "${targetCategory || 'none'}").`);
  }

  // Fetch LC source lot
  const lcLot = await lotsTbl.selectRecordAsync(lcLinks[0].id);
  if (!lcLot) return await updateError('LC source lot not found.');

  const lcRemaining = lcLot.getCellValue('remaining_volume_ml') ?? 0;
  if (volumeMl > lcRemaining) {
    return await updateError(`LC source only has ${lcRemaining} ml remaining, need ${volumeMl}.`);
  }

  const lcItemLink = lcLot.getCellValue('item_id')?.[0];
  const lcItem = lcItemLink && await itemsTbl.selectRecordAsync(lcItemLink.id);
  const lcCategory = (lcItem?.getCellValueAsString('category') || '').toLowerCase();

  if (!['lc_syringe', 'lc_flask'].includes(lcCategory)) {
    return await updateError(`LC source must be syringe or flask (got "${lcCategory || 'none'}").`);
  }

  // Passed validation
  await clearError();

  // Transition lot to Colonizing, update strain and inoc time
  const updates = {
    status: { name: 'Colonizing' },
    action: '',
    inoculated_at: inocTime
  };

  const strain = lcLot.getCellValue('strain_id')?.[0];
  if (strain) updates.strain_id = [strain];

  await lotsTbl.updateRecordAsync(lotRecordId, updates);

  // Decrease remaining volume on LC source
  const remaining = lcRemaining - volumeMl;
  const lcUpdates = { remaining_volume_ml: remaining };
  if (remaining <= 0) lcUpdates.status = { name: 'Consumed' };
  await lotsTbl.updateRecordAsync(lcLot.id, lcUpdates);

  // Record inoculation event
  await eventsTbl.createRecordAsync({
    lot_id: [{ id: lotRecordId }],
    type: { name: 'Inoculate' },
    timestamp: inocTime,
    station: 'Inoculation',
    fields_json: JSON.stringify({
      source_lc_lot_id: lcLot.id,
      volume_ml: volumeMl
    })
  });

  output.set('ok', true);

} catch (err) {
  output.set('error', `Fatal error: ${err.message}`);
}
