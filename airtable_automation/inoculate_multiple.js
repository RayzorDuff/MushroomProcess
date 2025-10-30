/**
 * Script: inoculate.js
 * Version: 2025-10-30.5
 * Summary: Inoculate grain, LC flasks, or agar plates from LC syringes, LC flasks, other plates, or grain.
 * Features:
 * Consolidated inoculation automation for Airtable.
 * Supports inoculation of:
 *   - Liquid Culture Flask
 *   - Grain Spawn
 *   - Agar Plate
 * 
 * Source may be:
 *   - Another tracked lot (LC flask, LC syringe, grain, or agar plate)
 *   - Untracked source (clone, gifted plate, old plate, etc.)
 * 
 * Validations:
 *   - Target must exist.
 *   - Source_lot_id OR notes must be provided.
 *   - lc_volume_ml (if provided) must be positive.
 * 
 * Updates:
 *   - Sets strain_id, source_lot_id, total_volume_ml, remaining_volume_ml.
 *   - Increments volumes when source is liquid.
 *   - Updates status to Colonizing.
 *   - Logs event of type "Inoculate".
 *   - If untracked source, appends note and proceeds without error.
 */

try {
  const lotsTbl = base.getTable('lots');
  const itemsTbl = base.getTable('items');
  const eventsTbl = base.getTable('events');

  //for (const f of lotsTbl.fields) {
  //  console.log('lots', `${f.id} :: ${f.name} [${f.type}]`);
  //}
  
  //for (const e of eventsTbl.fields) {
  //  console.log('events', `${e.id} :: ${e.name} [${e.type}]`);
  //}

  const { lotRecordId } = input.config();
  if (!lotRecordId) throw new Error('Missing lotRecordId');

  const targetLot = await lotsTbl.selectRecordAsync(lotRecordId);
  if (!targetLot) throw new Error('Lot not found');

  // --- Helper functions ---
  const updateError = async (msg) => {
    await lotsTbl.updateRecordAsync(lotRecordId, { ui_error: msg });
    output.set('error', msg);
  };
  const clearError = async () => {
    await lotsTbl.updateRecordAsync(lotRecordId, { ui_error: '' });
  };

  // --- Extract key fields ---
  const lcLinks = targetLot.getCellValue('lc_lot_id') ?? [];
  const volumeMl = targetLot.getCellValue('lc_volume_ml') ?? 0;
  const overrideTime = targetLot.getCellValue('override_inoc_time');
  const inocTime = overrideTime ? new Date(overrideTime) : new Date();

  const itemLink = targetLot.getCellValue('item_id')?.[0];
  const recipeLink = targetLot.getCellValue('recipe_id')?.[0];
  const unitSize = targetLot.getCellValue('unit_size') ?? 0;

  if (!itemLink) return await updateError('Must link an item.');
  if (!recipeLink) return await updateError('Must link a recipe.');

  const targetItem = await itemsTbl.selectRecordAsync(itemLink.id);
  const targetCategory = (targetItem?.getCellValueAsString('category') || '').toLowerCase();

  if (!['grain', 'lc_flask', 'plate'].includes(targetCategory)) {
    return await updateError(`Target must be grain, lc_flask, or plate (got "${targetCategory || 'none'}").`);
  }

    // --- If source is provided, validate and apply ---
  let isUntracked = lcLinks.length === 0;
  let sourceLot = null;
  let sourceCategory = '';
  let isLiquidSource = false;
  let isSolidSource = false;

  if (!isUntracked) {
    if (lcLinks.length !== 1) return await updateError('Must link exactly one source lot.');

    sourceLot = await lotsTbl.selectRecordAsync(lcLinks[0].id);
    if (!sourceLot) return await updateError('Source lot not found.');

    const sourceItemLink = sourceLot.getCellValue('item_id')?.[0];
    const sourceItem = sourceItemLink && await itemsTbl.selectRecordAsync(sourceItemLink.id);
    sourceCategory = (sourceItem?.getCellValueAsString('category') || '').toLowerCase();

    const allowedSources = ['lc_syringe', 'lc_flask', 'plate', 'grain'];
    if (!allowedSources.includes(sourceCategory)) {
      return await updateError(`Source must be lc_syringe, lc_flask, plate, or grain (got "${sourceCategory || 'none'}").`);
    }

    isLiquidSource = ['lc_syringe', 'lc_flask'].includes(sourceCategory);
    isSolidSource = ['plate', 'grain'].includes(sourceCategory);

    if (isLiquidSource && (!volumeMl || typeof volumeMl !== 'number' || volumeMl <= 0)) {
      return await updateError('Must enter a positive LC volume (ml).');
    }
    if (isSolidSource && volumeMl && volumeMl > 0) {
      return await updateError('Do not enter LC volume for plate or grain as source.');
    }

    const sourceRemaining = sourceLot.getCellValue('remaining_volume_ml') ?? null;
    if (isLiquidSource && sourceRemaining !== null && volumeMl > sourceRemaining) {
      return await updateError(`Source only has ${sourceRemaining} ml remaining.`);
    }
  } else {
    // --- Validate untracked case ---
    const notes = targetLot.getCellValue('notes');
    if (!notes || notes.trim() === '') {
      return await updateError('Must provide source lot or enter details in notes when using untracked source.');
    }
  }
  
  await clearError();

  // --- Calculate updated volumes ---
  const targetTotalVol = targetLot.getCellValue('total_volume_ml') ?? 0;
  const targetRemaining = targetLot.getCellValue('remaining_volume_ml') ?? 0;
  let newTotal = targetTotalVol || unitSize;
  let newRemaining = targetRemaining || unitSize;

  if (!isUntracked && isLiquidSource && volumeMl > 0) {
    newTotal += volumeMl;
    newRemaining += volumeMl;
  }

  const lotUpdates = {
    status: { name: 'Colonizing' },
    action: null,
    inoculated_at: inocTime,
    total_volume_ml: newTotal,
    remaining_volume_ml: newRemaining,
  };

  if (!isUntracked) {
    lotUpdates.source_lot_id = [{ id: sourceLot.id }];
    const strain = sourceLot.getCellValue('strain_id')?.[0];
    if (strain) lotUpdates.strain_id = [strain];
  }

  await lotsTbl.updateRecordAsync(lotRecordId, lotUpdates);

  if (!isUntracked && isLiquidSource) {
    const sourceRemaining = sourceLot.getCellValue('remaining_volume_ml') ?? null;
    if (sourceRemaining !== null) {
      const newSourceRemaining = sourceRemaining - volumeMl;
      const sourceUpdates = {
        remaining_volume_ml: newSourceRemaining
      };
      if (newSourceRemaining <= 0) {
        sourceUpdates.status = { name: 'Consumed' };
      }
      await lotsTbl.updateRecordAsync(sourceLot.id, sourceUpdates);
    }
  }

  // --- Log inoculation event ---
  const eventFields = {
    lot_id: [{ id: lotRecordId }],
    type: { name: 'Inoculated' },
    timestamp: inocTime,
    station: 'Inoculation',
    fields_json: JSON.stringify({
      source_lot_id: !isUntracked ? sourceLot.id : undefined,
      volume_ml: !isUntracked && isLiquidSource ? volumeMl : undefined,
      notes: isUntracked ? targetLot.getCellValue('notes') : undefined
    })
  };

  await eventsTbl.createRecordAsync(eventFields);

  output.set('ok', true);

} catch (err) {
  output.set('error', `Fatal error: ${err.message}`);
}
