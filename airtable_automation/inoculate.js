/**
 * Script: inoculate.js
 * Version: 2025-10-30.1
 * Summary: Inoculate grain, LC flasks, or agar plates from LC syringes, LC flasks, or other agar plates.
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

  const updateError = async (msg) => {
    await lotsTbl.updateRecordAsync(lotRecordId, { ui_error: msg });
    output.set('error', msg);
  };
  const clearError = async () => {
    await lotsTbl.updateRecordAsync(lotRecordId, { ui_error: '' });
  };

  const lcLinks = targetLot.getCellValue('lc_lot_id') ?? [];
  const volumeMl = targetLot.getCellValue('lc_volume_ml') ?? 0;
  const overrideTime = targetLot.getCellValue('override_inoc_time');
  const inocTime = overrideTime ? new Date(overrideTime) : new Date();

  const itemLink = targetLot.getCellValue('item_id')?.[0];
  const recipeLink = targetLot.getCellValue('recipe_id')?.[0];

  if (!itemLink) return await updateError('Must link an item.');
  if (!recipeLink) return await updateError('Must link a recipe.');
  if (lcLinks.length !== 1) return await updateError('Must link exactly one source lot.');

  const targetItem = await itemsTbl.selectRecordAsync(itemLink.id);
  const targetCategory = (targetItem?.getCellValueAsString('category') || '').toLowerCase();

  if (!['grain', 'lc_flask', 'plate'].includes(targetCategory)) {
    return await updateError(`Target must be grain, lc_flask, or plate (got "${targetCategory || 'none'}").`);
  }

  const sourceLot = await lotsTbl.selectRecordAsync(lcLinks[0].id);
  if (!sourceLot) return await updateError('Source lot not found.');

  const sourceItemLink = sourceLot.getCellValue('item_id')?.[0];
  const sourceItem = sourceItemLink && await itemsTbl.selectRecordAsync(sourceItemLink.id);
  const sourceCategory = (sourceItem?.getCellValueAsString('category') || '').toLowerCase();

  if (!['lc_syringe', 'lc_flask', 'plate'].includes(sourceCategory)) {
    return await updateError(`Source must be lc_syringe, lc_flask, or plate (got "${sourceCategory || 'none'}").`);
  }

  // Validate volume for LC-based sources
  const isLiquidSource = ['lc_syringe', 'lc_flask'].includes(sourceCategory);
  const isPlateSource = sourceCategory === 'plate';

  if (isLiquidSource && (!volumeMl || typeof volumeMl !== 'number' || volumeMl <= 0)) {
    return await updateError('Must enter a positive LC volume (ml).');
  }

  if (isPlateSource && volumeMl && volumeMl > 0) {
    return await updateError('Do not enter LC volume for plate-to-plate inoculation.');
  }

  const sourceRemaining = sourceLot.getCellValue('remaining_volume_ml') ?? null;
  if (isLiquidSource && sourceRemaining !== null && volumeMl > sourceRemaining) {
    return await updateError(`Source only has ${sourceRemaining} ml remaining.`);
  }

  // All validations passed
  await clearError();

  // Transition target lot to Colonizing
  const updates = {
    status: { name: 'Colonizing' },
    action: '',
    inoculated_at: inocTime
  };

  const strain = sourceLot.getCellValue('strain_id')?.[0];
  if (strain) updates.strain_id = [strain];

  await lotsTbl.updateRecordAsync(lotRecordId, updates);

  // Decrease LC volume and mark source consumed if empty
  if (isLiquidSource && sourceRemaining !== null) {
    const remaining = sourceRemaining - volumeMl;
    const sourceUpdates = {
      remaining_volume_ml: remaining
    };
    if (remaining <= 0) sourceUpdates.status = { name: 'Consumed' };
    await lotsTbl.updateRecordAsync(sourceLot.id, sourceUpdates);
  }
  
  

  // Log event
  await eventsTbl.createRecordAsync({
    lot_id: [{ id: lotRecordId }],
    type: { name: 'Inoculate' },
    timestamp: inocTime,
    station: 'Inoculation',
    fields_json: JSON.stringify({
      source_lot_id: sourceLot.id,
      total_volume_ml: isLiquidSource ? volumeMl : undefined
    })
  });

  output.set('ok', true);

} catch (err) {
  output.set('error', `Fatal error: ${err.message}`);
}
