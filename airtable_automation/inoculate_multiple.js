/**
 * Script: inoculate_multiple.js
 * Version: 2025-12-18.1
 * =============================================================================
 *  Batch inoculation starting from a SOURCE lot.
 *
 *  - Automation passes { lotRecordId } for the SOURCE lot.
 *  - SOURCE lot fields:
 *      - target_lot_ids : linked records to TARGET lots.
 *      - lc_volume_ml   : per-target LC volume in ml (for liquid sources).
 *      - override_inoc_time : optional explicit inoculated_at timestamp.
 *      - notes          : for untracked_source, description of the source.
 *  - TARGET lots will be updated to:
 *      - status = Colonizing
 *      - inoculated_at set
 *      - total_volume_ml / remaining_volume_ml updated
 *      - source_lot_id linked back to SOURCE lot
 *      - strain_id copied from SOURCE lot
 *      - vendor_name and vendor_batch copied from SOURCE lot if they are set
 *      - materialized fields set if they are not already
 *      - notes set from SOURCE notes when using untracked_source
 *
 *  Source remaining_volume_ml is decremented only when the source
 *  is a tracked liquid (lc_syringe, lc_flask). For untracked_source,
 *  no depletion is tracked; notes are required and then propagated to
 *  targets and cleared on the source after a successful run.
 * =============================================================================
 */

(async () => {
  try {
    const lotsTbl   = base.getTable('lots');
    const itemsTbl  = base.getTable('items');
    const eventsTbl = base.getTable('events');

/*
    // DEBUG: List all fields so we can map field IDs -> names/types
    for (const f of lotsTbl.fields) {
      console.log('lots', `${f.id} :: ${f.name} [${f.type}]`);
    }

    for (const i of itemsTbl.fields) {
      console.log('events', `${i.id} :: ${i.name} [${i.type}]`);
    }

    for (const e of eventsTbl.fields) {
      console.log('events', `${e.id} :: ${e.name} [${e.type}]`);
    }   
*/
    function hasField(tbl, name) {
      try { tbl.getField(name); return true; } catch { return false; }
    }

    function coerceValueForField(table, fieldName, valueStr) {
      if (!valueStr) return null;
      const f = table.getField(fieldName);
      if (f.type === 'singleSelect') return { name: valueStr };
      return valueStr; // singleLineText, etc.
    }    

    const { lotRecordId } = input.config();
    if (!lotRecordId) throw new Error('Missing lotRecordId');

    const sourceLot = await lotsTbl.selectRecordAsync(lotRecordId);
    if (!sourceLot) throw new Error('Source lot not found');

    const updateSourceError = async (msg) => {
      await lotsTbl.updateRecordAsync(lotRecordId, { ui_error: msg, action: null });
      output.set('error', msg);
    };

    const clearSourceError = async () => {
      await lotsTbl.updateRecordAsync(lotRecordId, { ui_error: '' });
    };

    // --- Extract key fields from source ------------------------------------
    const targetLinks  = sourceLot.getCellValue('target_lot_ids') ?? [];
    const volumePerLot = sourceLot.getCellValue('lc_volume_ml') ?? 0;
    const overrideTime = sourceLot.getCellValue('override_inoc_time');
    const inocTime     = overrideTime ? new Date(overrideTime) : new Date();

    // operator is optional; don't fail if field missing
    let operator = '';
    try {
      if (sourceLot.getCellValueAsString) {
        operator = sourceLot.getCellValueAsString('operator');
      } else {
        operator = sourceLot.getCellValue('operator') || '';
      }
    } catch (e) {
      operator = '';
    }

    if (!targetLinks.length) {
      return await updateSourceError('Must link at least one target lot in target_lot_ids.');
    }

    const sourceItemLink = sourceLot.getCellValue('item_id')?.[0];
    if (!sourceItemLink) {
      return await updateSourceError('Source lot must be linked to an item.');
    }

    const sourceItem = await itemsTbl.selectRecordAsync(sourceItemLink.id);
    const sourceCategory = (sourceItem?.getCellValueAsString('category') || '').toLowerCase();

    const allowedSources = ['lc_syringe', 'lc_flask', 'plate', 'grain', 'untracked_source'];
    if (!allowedSources.includes(sourceCategory)) {
      return await updateSourceError(
        `Source must be lc_syringe, lc_flask, plate, grain, or untracked_source (got "${sourceCategory || 'none'}").`
      );
    }

    const isLiquidSource    = ['lc_syringe', 'lc_flask'].includes(sourceCategory);
    const isSolidSource     = ['plate', 'grain'].includes(sourceCategory);
    const isUntrackedSource = sourceCategory === 'untracked_source';

    const rawSourceNotes = sourceLot.getCellValue('notes') || '';

    // Optional: vendor fields to propagate to targets (if present on source)
    const sourceVendorName  = hasField(lotsTbl, 'vendor_name')
      ? (sourceLot.getCellValueAsString?.('vendor_name') || sourceLot.getCellValue('vendor_name') || '')
      : '';
    const sourceVendorBatch = hasField(lotsTbl, 'vendor_batch')
      ? (sourceLot.getCellValueAsString?.('vendor_batch') || sourceLot.getCellValue('vendor_batch') || '')
      : '';    

    // --- Category-specific validation --------------------------------------
    if (isLiquidSource) {
      if (!volumePerLot || typeof volumePerLot !== 'number' || volumePerLot <= 0) {
        return await updateSourceError('Must enter a positive LC volume (ml) on the source lot.');
      }

      const srcRemainingRaw = sourceLot.getCellValue('remaining_volume_ml');
      const sourceRemaining = (srcRemainingRaw === null || srcRemainingRaw === undefined)
        ? null
        : Number(srcRemainingRaw);

      if (sourceRemaining !== null) {
        const totalNeeded = volumePerLot * targetLinks.length;
        if (totalNeeded > sourceRemaining) {
          return await updateSourceError(
            `Source only has ${sourceRemaining} ml remaining; needs ${totalNeeded} ml for ${targetLinks.length} targets.`
          );
        }
      }
    } else if (isSolidSource && volumePerLot && volumePerLot > 0) {
      return await updateSourceError('Do not enter LC volume for plate or grain as source.');
    } else if (isUntrackedSource) {
      // Require notes describing the mystery source
      if (!rawSourceNotes || rawSourceNotes.trim() === '') {
        return await updateSourceError(
          'For untracked_source, you must enter a description in notes on the source lot.'
        );
      }
      // volumePerLot is optional and informational only in this case
    }

    // Clear any previous error once validation has passed
    await clearSourceError();

    const sourceStrainLink = sourceLot.getCellValue('strain_id')?.[0] || null;
    const sourceNotesForTargets = isUntrackedSource ? rawSourceNotes : null;

    let successfulTargets = 0;
    let totalVolumeUsed   = 0;

    for (const link of targetLinks) {
      if (!link || !link.id) continue;

      const targetLot = await lotsTbl.selectRecordAsync(link.id);
      if (!targetLot) continue;

      const itemLink   = targetLot.getCellValue('item_id')?.[0];
      const recipeLink = targetLot.getCellValue('recipe_id')?.[0];
      const unitSize   = targetLot.getCellValue('unit_size') ?? 0;

      if (!itemLink) {
        await updateSourceError(
          `Target lot ${targetLot.getCellValueAsString ? targetLot.getCellValueAsString('lot_id') : targetLot.id} is missing item.`
        );
        continue;
      }
      if (!recipeLink) {
        await updateSourceError(
          `Target lot ${targetLot.getCellValueAsString ? targetLot.getCellValueAsString('lot_id') : targetLot.id} is missing recipe.`
        );
        continue;
      }

      const targetItem = await itemsTbl.selectRecordAsync(itemLink.id);
      const targetCategory = (targetItem?.getCellValueAsString('category') || '').toLowerCase();

      if (!['grain', 'lc_flask', 'plate'].includes(targetCategory)) {
        await updateSourceError(
          `Target lot ${targetLot.getCellValueAsString ? targetLot.getCellValueAsString('lot_id') : targetLot.id} must be ` +
          `grain, lc_flask, or plate (got "${targetCategory || 'none'}").`
        );
        continue;
      }

      // --- Calculate updated volumes for this target -----------------------
      const targetTotalVol  = targetLot.getCellValue('total_volume_ml') ?? 0;
      const targetRemaining = targetLot.getCellValue('remaining_volume_ml') ?? 0;
      let newTotal          = targetTotalVol || unitSize;
      let newRemaining      = targetRemaining || unitSize;

      // Only tracked liquids actually modify target volume and source depletion
      if (!isUntrackedSource && isLiquidSource && volumePerLot > 0) {
        newTotal     += volumePerLot;
        newRemaining += volumePerLot;
      }

      const lotUpdates = {
        status: { name: 'Colonizing' },
        action: null,
        inoculated_at: inocTime,
        total_volume_ml: newTotal,
        remaining_volume_ml: newRemaining,
        source_lot_id: [{ id: sourceLot.id }]
      };
      
      // --- Propagate vendor fields from source lot (if set on source) -----
      if (sourceVendorName && hasField(lotsTbl, 'vendor_name')) {
        const v = coerceValueForField(lotsTbl, 'vendor_name', sourceVendorName);
        if (v != null) lotUpdates.vendor_name = v;
      }
      if (sourceVendorBatch && hasField(lotsTbl, 'vendor_batch')) {
        const v = coerceValueForField(lotsTbl, 'vendor_batch', sourceVendorBatch);
        if (v != null) lotUpdates.vendor_batch = v;        
      }

      // --- Ensure _mat fields are populated on target lots ----------------
      // (Since we already loaded targetItem, this is cheap and prevents chains.)
      const targetItemName = targetItem?.getCellValueAsString('name') || '';
      const targetItemCat  = targetItem?.getCellValueAsString('category') || '';

      if (hasField(lotsTbl, 'item_name_mat')) {
        const v = coerceValueForField(lotsTbl, 'item_name_mat', targetItemName);
        if (v != null) lotUpdates.item_name_mat = v;
      }
      if (hasField(lotsTbl, 'item_category_mat')) {
        const v = coerceValueForField(lotsTbl, 'item_category_mat', targetItemCat);
        if (v != null) lotUpdates.item_category_mat = v;
      }

      // Compute lot.use_by based on target category and inoculation time
      let lotUseBy = null;
      if (targetCategory === 'lc_flask') {
        // Liquid culture flasks: 6 months from inoculation
        const d = new Date(inocTime);
        if (!Number.isNaN(d.getTime())) {
          d.setMonth(d.getMonth() + 6);
          lotUseBy = d;
        }
      } else if (targetCategory === 'grain') {
        // Grain spawn: 3 months from inoculation
        const d = new Date(inocTime);
        if (!Number.isNaN(d.getTime())) {
          d.setMonth(d.getMonth() + 3);
          lotUseBy = d;
        }
      }
      if (lotUseBy) {
        lotUpdates.use_by = lotUseBy;
      }

      // Strain: propagate from source if present
      if (sourceStrainLink) {
        lotUpdates.strain_id = [sourceStrainLink];
      }

      // For untracked_source, propagate notes from source to target
      if (isUntrackedSource && sourceNotesForTargets !== null) {
        lotUpdates.notes = sourceNotesForTargets;
      }

      await lotsTbl.updateRecordAsync(targetLot.id, lotUpdates);

      // --- Log event for this target --------------------------------------
      let lotIdLabel = '';
      try {
        lotIdLabel = targetLot.getCellValueAsString
          ? targetLot.getCellValueAsString('lot_id')
          : (targetLot.getCellValue('lot_id') || targetLot.id);
      } catch (e) {
        lotIdLabel = targetLot.id;
      }

      const eventPayload = {
        source_lot_id: sourceLot.id,
        source_category: sourceCategory,
        volume_ml: (!isUntrackedSource && isLiquidSource && volumePerLot > 0) ? volumePerLot : undefined,
        operator,
        target_lot_id: lotIdLabel,
        notes: isUntrackedSource ? sourceNotesForTargets : undefined
      };

      const eventFields = {
        lot_id: [{ id: targetLot.id }],
        type: { name: 'Inoculated' },
        timestamp: inocTime,
        station: 'Inoculation',
        fields_json: JSON.stringify(eventPayload)
      };

      await eventsTbl.createRecordAsync(eventFields);

      successfulTargets += 1;
      if (!isUntrackedSource && isLiquidSource && volumePerLot > 0) {
        totalVolumeUsed += volumePerLot;
      }
    }

    if (!successfulTargets) {
      return await updateSourceError(
        'No target lots were successfully inoculated. Check target configuration and try again.'
      );
    }

    // --- Update source lot (volumes, status, notes) ------------------------
    const sourceUpdates = {
      action: null,
      override_inoc_time: null,
      lc_volume_ml: null,
      target_lot_ids: null
    };

    if (!isUntrackedSource && isLiquidSource && totalVolumeUsed > 0) {
      const srcRemainingRaw = sourceLot.getCellValue('remaining_volume_ml');
      const sourceRemaining = (srcRemainingRaw === null || srcRemainingRaw === undefined)
        ? null
        : Number(srcRemainingRaw);

      if (sourceRemaining !== null) {
        const newSourceRemaining = sourceRemaining - totalVolumeUsed;
        sourceUpdates.remaining_volume_ml = newSourceRemaining;
        if (newSourceRemaining <= 0) {
          sourceUpdates.status = { name: 'Consumed' };
        }
      }
    }

    // For untracked_source, clear notes after propagation
    if (isUntrackedSource) {
      sourceUpdates.notes = null;
    }

    await lotsTbl.updateRecordAsync(sourceLot.id, sourceUpdates);

    output.set('ok', true);
    output.set('targetsUpdated', successfulTargets);

  } catch (err) {
    output.set('error', `Fatal error: ${err.message}`);
  }
})();