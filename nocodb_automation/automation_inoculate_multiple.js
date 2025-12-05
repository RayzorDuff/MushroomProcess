// automation_inoculate_multiple.js
//
// Inoculate Multiple – source-first batch inoculation against NocoDB
// Mirrors Airtable automation_automation/inoculate_multiple.js semantics.
//
// Inputs (JSON body from NocoDB button/webhook):
//   { "source_lot_id": "<row id>", "operator": "<optional>" }
//
// Behaviour:
//   - Loads the SOURCE lot by id.
//   - Reads source.item_category, lc_volume_ml, remaining_volume_ml,
//     target_lot_ids (array of lot row ids), override_inoc_time,
//     strain_id, notes.
//   - Validates source + targets.
//   - For each target in target_lot_ids:
//       * status = "Colonizing"
//       * inoculated_at set
//       * total_volume_ml / remaining_volume_ml incremented for
//         tracked liquid sources only
//       * source_lot_id = source_lot_id
//       * strain_id = source.strain_id (if present)
//       * notes: for untracked_source, copied from source.notes
//       * ui_error cleared
//       * event created (type = "Inoculated") with fields_json payload
//   - For tracked liquid sources (lc_syringe / lc_flask), decrements
//     source.remaining_volume_ml by lc_volume_ml * target_count and
//     sets status = "Consumed" if <= 0.
//   - For untracked_source, requires source.notes to be non-empty,
//     copies notes to each target, and then clears notes on the source.
//   - Writes any validation failures to source.ui_error and returns 400.
//
// Category semantics:
//   - Liquid tracked sources: lc_syringe, lc_flask
//   - Solid tracked sources:  plate, grain
//   - Untracked source:       untracked_source
//

import { makeNC } from "./lib/noco.js";

const {
  NOCO_BASE_URL,
  NOCO_TOKEN,
  NOCO_PROJECT = "mushroom_inventory"
} = process.env;

const nc = makeNC({
  baseUrl: NOCO_BASE_URL,
  token: NOCO_TOKEN,
  projectSlug: NOCO_PROJECT
});

// Utility: write ui_error on source and throw
async function setErrorOnSource(source_lot_id, msg) {
  try {
    await nc.update("lots", source_lot_id, { ui_error: msg });
  } catch (_) {
    // ignore secondary errors
  }
  throw new Error(msg);
}

export default async function handler(req, res) {
  try {
    // -----------------------------
    // 1. Input validation
    // -----------------------------
    const { source_lot_id, operator: opFromBody } = req.body || {};

    if (!source_lot_id) {
      throw new Error("source_lot_id required");
    }

    const source = await nc.getById("lots", source_lot_id);
    if (!source) {
      throw new Error(`Source lot not found: ${source_lot_id}`);
    }

    const nowISO = new Date().toISOString();

    const {
      item_category,
      lc_volume_ml,
      remaining_volume_ml,
      target_lot_ids,
      override_inoc_time,
      notes,
      strain_id,
      operator: opFromSource
    } = source;

    const targets = Array.isArray(target_lot_ids) ? target_lot_ids : [];
    if (!targets.length) {
      return await setErrorOnSource(
        source_lot_id,
        "Must link at least one target lot in target_lot_ids."
      );
    }

    const sourceCategory = (item_category || "").toLowerCase();
    const allowedSources = [
      "lc_syringe",
      "lc_flask",
      "plate",
      "grain",
      "untracked_source"
    ];

    if (!allowedSources.includes(sourceCategory)) {
      return await setErrorOnSource(
        source_lot_id,
        `Source must be lc_syringe, lc_flask, plate, grain, or untracked_source (got "${sourceCategory || "none"}").`
      );
    }

    const isLiquidSource = ["lc_syringe", "lc_flask"].includes(sourceCategory);
    const isSolidSource = ["plate", "grain"].includes(sourceCategory);
    const isUntrackedSource = sourceCategory === "untracked_source";

    const volumePerLot = Number(lc_volume_ml || 0);
    const srcRemaining = remaining_volume_ml == null ? null : Number(remaining_volume_ml);
    const rawSourceNotes = notes || "";
    const effectiveOperator = opFromBody || opFromSource || "system";
    const inocTime = override_inoc_time
      ? new Date(override_inoc_time).toISOString()
      : nowISO;

    // -----------------------------
    // 2. Source category validation
    // -----------------------------
    if (isLiquidSource) {
      if (!(volumePerLot > 0)) {
        return await setErrorOnSource(
          source_lot_id,
          "Must enter a positive lc_volume_ml on the source lot."
        );
      }

      if (srcRemaining != null) {
        const totalNeeded = volumePerLot * targets.length;
        if (totalNeeded > srcRemaining) {
          return await setErrorOnSource(
            source_lot_id,
            `Source only has ${srcRemaining} ml remaining; needs ${totalNeeded} ml for ${targets.length} targets.`
          );
        }
      }
    } else if (isSolidSource && volumePerLot > 0) {
      return await setErrorOnSource(
        source_lot_id,
        "Do not enter lc_volume_ml for plate or grain as source."
      );
    } else if (isUntrackedSource) {
      if (!rawSourceNotes || rawSourceNotes.trim() === "") {
        return await setErrorOnSource(
          source_lot_id,
          'For untracked_source, you must enter a description in notes on the source lot.'
        );
      }
      // volumePerLot allowed but informational
    }

    // -----------------------------
    // 3. Clear previous source error
    // -----------------------------
    await nc.update("lots", source_lot_id, { ui_error: "" });

    let successfulTargets = 0;
    let totalVolumeUsed = 0;

    // -----------------------------
    // 4. Process each target
    // -----------------------------
    for (const targetId of targets) {
      if (!targetId) continue;

      const target = await nc.getById("lots", targetId);
      if (!target) continue;

      const targetCategory = (target.item_category || "").toLowerCase();
      if (!["grain", "lc_flask", "plate"].includes(targetCategory)) {
        await setErrorOnSource(
          source_lot_id,
          `Target lot ${target.lot_id || target.id} must be grain, lc_flask, or plate (got "${targetCategory}").`
        );
      }

      const unitSize = Number(target.unit_size || 0);
      const tTotalVol = Number(target.total_volume_ml || 0) || unitSize;
      const tRemaining = Number(target.remaining_volume_ml || 0) || unitSize;

      let newTotal = tTotalVol;
      let newRemaining = tRemaining;

      // tracked liquid source → adds volume to targets
      if (!isUntrackedSource && isLiquidSource && volumePerLot > 0) {
        newTotal += volumePerLot;
        newRemaining += volumePerLot;
      }

      const targetUpdate = {
        status: "Colonizing",
        action: null,
        inoculated_at: inocTime,
        total_volume_ml: newTotal,
        remaining_volume_ml: newRemaining,
        source_lot_id: source_lot_id,
        ui_error: ""
      };

      // propagate strain
      if (strain_id) {
        targetUpdate.strain_id = strain_id;
      }

      // for untracked sources: propagate source notes to target
      if (isUntrackedSource) {
        targetUpdate.notes = rawSourceNotes;
      }

      await nc.update("lots", targetId, targetUpdate);

      const eventPayload = {
        source_lot_id,
        source_category: sourceCategory,
        target_lot_id: target.lot_id || target.id,
        volume_ml:
          !isUntrackedSource && isLiquidSource && volumePerLot > 0
            ? volumePerLot
            : undefined,
        operator: effectiveOperator,
        notes: isUntrackedSource ? rawSourceNotes : undefined
      };

      await nc.create("events", {
        lot_id: targetId,
        type: "Inoculated",
        timestamp: inocTime,
        operator: effectiveOperator,
        station: "Inoculation",
        fields_json: JSON.stringify(eventPayload)
      });

      successfulTargets++;
      if (!isUntrackedSource && isLiquidSource && volumePerLot > 0) {
        totalVolumeUsed += volumePerLot;
      }
    }

    if (!successfulTargets) {
      return await setErrorOnSource(
        source_lot_id,
        "No target lots were successfully inoculated. Check configuration."
      );
    }

    // -----------------------------
    // 5. Update source lot
    // -----------------------------
    const sourceUpdate = {
      action: null,
      override_inoc_time: null
    };

    // tracked liquid → decrement remaining volume
    if (!isUntrackedSource && isLiquidSource && totalVolumeUsed > 0 && srcRemaining != null) {
      const newRemaining = srcRemaining - totalVolumeUsed;
      sourceUpdate.remaining_volume_ml = newRemaining;
      if (newRemaining <= 0) {
        sourceUpdate.status = "Consumed";
      }
    }

    // untracked sources → clear notes
    if (isUntrackedSource) {
      sourceUpdate.notes = null;
    }

    await nc.update("lots", source_lot_id, sourceUpdate);

    // -----------------------------
    // 6. Return success
    // -----------------------------
    res.status(200).json({
      ok: true,
      targetsUpdated: successfulTargets
    });

  } catch (e) {
    res.status(400).json({
      ok: false,
      error: String(e.message || e)
    });
  }
}
