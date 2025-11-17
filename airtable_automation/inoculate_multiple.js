/**
 * Script: inoculate_multiple.js
 * Version: 2025-11-17.1
 * =============================================================================
 *  Batch inoculation starting from a SOURCE lot.
 *
 *  - The automation passes { lotRecordId } for the SOURCE lot.
 *  - SOURCE lot fields:
 *      - target_lot_ids : link to one or more TARGET lots (was lc_lot_id).
 *      - lc_volume_ml   : volume (ml) to use PER TARGET when source is liquid.
 *      - override_inoc_time : optional explicit inoculation timestamp.
 *  - TARGET lots will be updated to:
 *      - status = Colonizing
 *      - inoculated_at set
 *      - total_volume_ml / remaining_volume_ml updated
 *      - source_lot_id linked to the SOURCE lot
 *      - strain_id copied from the SOURCE lot
 *      - Inoculated event logged in events table
 *
 *  Source remaining_volume_ml is decremented by
 *  lc_volume_ml * number_of_targets for liquid sources; if <= 0, status is
 *  set to Consumed.
 *
 *  This script assumes the automation trigger still keys off action = "Inoculate"
 *  on the SOURCE lot; the script itself only clears action and ui_error.
 * =============================================================================
 */

(async () => {
  try {
    // --- Tables --------------------------------------------------------------
    const lotsTbl   = base.getTable('lots');
    const itemsTbl  = base.getTable('items');
    const eventsTbl = base.getTable('events');

    // --- Input config -------------------------------------------------------
    const { lotRecordId } = input.config();
    if (!lotRecordId) throw new Error('Missing lotRecordId');

    const sourceLot = await lotsTbl.selectRecordAsync(lotRecordId);
    if (!sourceLot) throw new Error('Source lot not found');

    // --- Helper functions ---------------------------------------------------
    const updateSourceError = async (msg) => {
      await lotsTbl.updateRecordAsync(lotRecordId, { ui_error: msg, action: null });
      output.set('error', msg);
    };

    const clearSourceError = async () => {
      await lotsTbl.updateRecordAsync(lotRecordId, { ui_error: '' });
    };

    // --- Extract key source fields -----------------------------------------
    // target_lot_ids: new multi-link field on SOURCE pointing to TARGET lots.
    const targetLinks   = sourceLot.getCellValue('target_lot_ids') ?? [];
    // lc_volume_ml: volume in ml PER TARGET (only used for liquid sources).
    const volumePerLot  = sourceLot.getCellValue('lc_volume_ml') ?? 0;
    const overrideTime  = sourceLot.getCellValue('override_inoc_time');
    const inocTime      = overrideTime ? new Date(overrideTime) : new Date();

    const operator = sourceLot.getCellValueAsString
      ? sourceLot.getCellValueAsString('operator')
      : (sourceLot.getCellValue('operator') || '');

    if (!targetLinks.length) {
      return await updateSourceError('Must link at least one target lot.');
    }

    // Source must be a valid inoculation source
    const sourceItemLink = sourceLot.getCellValue('item_id')?.[0];
    if (!sourceItemLink) {
      return await updateSourceError('Source lot must be linked to an item.');
    }

    const sourceItem = await itemsTbl.selectRecordAsync(sourceItemLink.id);
    const sourceCategory = (sourceItem?.getCellValueAsString('category') || '').toLowerCase();

    const allowedSources = ['lc_syringe', 'lc_flask', 'plate', 'grain'];
    if (!allowedSources.includes(sourceCategory)) {
      return await updateSourceError(
        `Source must be lc_syringe, lc_flask, plate, or grain (got "${sourceCategory || 'none'}").`
      );
    }

    const isLiquidSource = ['lc_syringe', 'lc_flask'].includes(sourceCategory);
    const isSolidSource  = ['plate', 'grain'].includes(sourceCategory);

    if (isLiquidSource) {
      if (!volumePerLot || typeof volumePerLot !== 'number' || volumePerLot <= 0) {
        return await updateSourceError('Must enter a positive LC volume (ml) on the source lot.');
      }
    } else if (isSolidSource && volumePerLot && volumePerLot > 0) {
      return await updateSourceError('Do not enter LC volume when using plate or grain as source.');
    }

    // --- Validate source volume vs required volume --------------------------
    let totalVolumeNeeded = 0;
    if (isLiquidSource) {
      totalVolumeNeeded = volumePerLot * targetLinks.length;

      const srcRemainingRaw = sourceLot.getCellValue('remaining_volume_ml');
      const sourceRemaining = (srcRemainingRaw === null || srcRemainingRaw === undefined)
        ? null
        : Number(srcRemainingRaw);

      if (sourceRemaining !== null && totalVolumeNeeded > sourceRemaining) {
        return await updateSourceError(
          `Source only has ${sourceRemaining} ml remaining; ` +
          `needs ${totalVolumeNeeded} ml for ${targetLinks.length} targets.`
        );
      }
    }

    // --- Clear any previous error ------------------------------------------
    await clearSourceError();

    // Cache source strain for propagation to all targets
    const sourceStrainLink = sourceLot.getCellValue('strain_id')?.[0] || null;

    // --- Process each target lot -------------------------------------------
    let successfulTargets = 0;
    let totalVolumeUsed   = 0;

    for (const link of targetLinks) {
      if (!link || !link.id) continue;

      const targetLot = await lotsTbl.selectRecordAsync(link.id);
      if (!targetLot) {
        // Soft-fail: skip missing target but keep going.
        continue;
      }

      const itemLink   = targetLot.getCellValue('item_id')?.[0];
      const recipeLink = targetLot.getCellValue('recipe_id')?.[0];
      const unitSize   = targetLot.getCellValue('unit_size') ?? 0;

      if (!itemLink) {
        await updateSourceError(
          `Target lot ${targetLot.getCellValueAsString('lot_id') || targetLot.id} is missing item.`
        );
        continue;
      }
      if (!recipeLink) {
        await updateSourceError(
          `Target lot ${targetLot.getCellValueAsString('lot_id') || targetLot.id} is missing recipe.`
        );
        continue;
      }

      const targetItem = await itemsTbl.selectRecordAsync(itemLink.id);
      const targetCategory = (targetItem?.getCellValueAsString('category') || '').toLowerCase();

      if (!['grain', 'lc_flask', 'plate'].includes(targetCategory)) {
        await updateSourceError(
          `Target lot ${targetLot.getCellValueAsString('lot_id') || targetLot.id} must be ` +
          `grain, lc_flask, or plate (got "${targetCategory || 'none'}").`
        );
        continue;
      }

      // --- Calculate updated volumes for this target -----------------------
      const targetTotalVol  = targetLot.getCellValue('total_volume_ml') ?? 0;
      const targetRemaining = targetLot.getCellValue('remaining_volume_ml') ?? 0;
      let newTotal          = targetTotalVol || unitSize;
      let newRemaining      = targetRemaining || unitSize;

      if (isLiquidSource && volumePerLot > 0) {
        newTotal     += volumePerLot;
        newRemaining += volumePerLot;
      }

      const lotUpdates = {
        status: { name: 'Colonizing' },
        action: null,
        inoculated_at: inocTime,
        total_volume_ml: newTotal,
        remaining_volume_ml: newRemaining,
      };

      // Link back to the common source lot
      lotUpdates.source_lot_id = [{ id: sourceLot.id }];

      // Propagate strain from source to target (your new requirement)
      if (sourceStrainLink) {
        lotUpdates.strain_id = [sourceStrainLink];
      }

      await lotsTbl.updateRecordAsync(targetLot.id, lotUpdates);

      // --- Log event for this target lot -----------------------------------
      const eventFields = {
        lot_id: [{ id: targetLot.id }],
        type: { name: 'Inoculated' },
        timestamp: inocTime,
        station: 'Inoculation',
        fields_json: JSON.stringify({
          source_lot_id: sourceLot.id,
          volume_ml: isLiquidSource ? volumePerLot : undefined,
          operator,
          notes: targetLot.getCellValue('notes') || undefined
        })
      };

      await eventsTbl.createRecordAsync(eventFields);

      successfulTargets += 1;
      if (isLiquidSource && volumePerLot > 0) {
        totalVolumeUsed += volumePerLot;
      }
    }

    if (!successfulTargets) {
      return await updateSourceError(
        'No target lots were successfully inoculated. See errors for details.'
      );
    }

    // --- Update source lot remaining volume / status -----------------------
    const sourceUpdates = {
      action: null,
      override_inoc_time: null,
    };

    if (isLiquidSource && totalVolumeUsed > 0) {
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

    await lotsTbl.updateRecordAsync(sourceLot.id, sourceUpdates);

    output.set('ok', true);
    output.set('targetsUpdated', successfulTargets);

  } catch (err) {
    output.set('error', `Fatal error: ${err.message}`);
  }
})();
