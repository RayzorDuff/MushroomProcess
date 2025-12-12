/**
 * Script: dark_room_actions.js
 * Version: 2025-12-12.1
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
 * Summary: Dark Room – Handles dark room lot actions, including status transitions and event logging.
 * Notes:
 * - Added: ApplyBeneficialTrichoderma, ApplyNematodes, ApplyDiatomaceousEarth (log-only actions).
 * - Changed: ApplyCasing no longer requires a casing lot.
 * - 2025-10-19.3:
 *   - For MoveToFridge, ColdShock, and StartFruiting:
 *     - Ensure a FullyColonized event exists for the lot.
 *     - If missing, set status to FullyColonized
 *       and log a FullyColonized event before transitioning.
 */
try {
  const { lotId } = input.config();

  const lotsTbl = base.getTable('lots');
  const locTbl = base.getTable('locations');
  const itemsTbl = base.getTable('items');
  const eventsTbl = base.getTable('events');

  function hasField(tbl, name) {
    try { tbl.getField(name); return true; } catch { return false; }
  }

  const lot = await lotsTbl.selectRecordAsync(lotId);
  if (!lot) throw new Error('Lot not found');

  const action = lot.getCellValueAsString('action') || '';
  if (!action) return;

  const nowIso = new Date().toISOString();
  const tsWritable = (() => {
    try { return eventsTbl.getField('timestamp').type === 'dateTime'; } catch { return false; }
  })();

  function choiceByName(field, name) {
    return (field.options?.choices || []).find(c => c.name === name) || null;
  }

  async function findLocationByName(name) {
    try {
      const q = await locTbl.selectRecordsAsync({ fields: ['name'] });
      for (const r of q.records) {
        if ((r.getCellValueAsString('name') || '').toLowerCase() === name.toLowerCase()) return r;
      }
    } catch {}
    return null;
  }

  async function logEvent(lotId, typeName, station, payload = {}) {
    const typeField = eventsTbl.getField('type');
    const typeChoice = (typeField.options?.choices || []).find(c => c.name === typeName);
    if (!typeChoice) return;
    const rec = {
      fields: {
        lot_id: [{ id: lotId }],
        type: { id: typeChoice.id },
        station,
        fields_json: JSON.stringify(payload)
      }
    };
    if (tsWritable) rec.fields.timestamp = nowIso;
    await eventsTbl.createRecordsAsync([rec]);
  }

  async function setStatus(lotId, statusName) {
    const sf = lotsTbl.getField('status');
    const ch = choiceByName(sf, statusName);
    if (!ch) {
      const names = (sf.options?.choices || []).map(c => c.name).join(', ');
      throw new Error(`lots.status missing "${statusName}". Has: ${names}`);
    }
    await lotsTbl.updateRecordAsync(lotId, { status: { id: ch.id } });
  }

  async function failWithUI(msg) {
    const update = {};
    if (hasField(lotsTbl, 'ui_error')) update.ui_error = msg;
    if (hasField(lotsTbl, 'ui_error_at')) update.ui_error_at = new Date().toISOString();
    if (hasField(lotsTbl, 'action')) update.action = null;
    if (Object.keys(update).length) await lotsTbl.updateRecordAsync(lot.id, update);
    throw new Error(msg);
  }

  const statusName = lot.getCellValueAsString('status') || '';
  let itemCategory = '';
  try {
    const itemLink = lot.getCellValue('item_id')?.[0];
    if (itemLink) {
      const item = await itemsTbl.selectRecordAsync(itemLink.id);
      itemCategory = (item?.getCellValueAsString('category') || '').toLowerCase();
    }
  } catch {}

  /**
   * Ensure that a FullyColonized event exists for this lot.
   * If not present, we:
   *   - set the lot status to FullyColonized (if not already),
   *   - and log a FullyColonized event.
   *
   * This allows the UI / history to always show that anything
   * moved to Fridge / Fruiting / ColdShock was considered fully colonized.
   */
  async function ensureFullyColonizedHistoryForTransition() {
    const typeField = eventsTbl.getField('type');
    const fullyChoice = (typeField.options?.choices || []).find(c => c.name === 'FullyColonized');
    if (!fullyChoice) {
      // If events.type doesn't have FullyColonized, we can't log it; just return.
      return;
    }

    // Scan events for this lot / type = FullyColonized
    const q = await eventsTbl.selectRecordsAsync({ fields: ['lot_id', 'type'] });
    let hasFully = false;
    for (const r of q.records) {
      const typeVal = r.getCellValue('type'); // single select: {id, name}
      if (!typeVal || typeVal.id !== fullyChoice.id) continue;

      const lotLinks = r.getCellValue('lot_id') || [];
      if (lotLinks.some(l => l.id === lot.id)) {
        hasFully = true;
        break;
      }
    }

    if (!hasFully) {
      // No need to set status as it will be reset to the correct final status next
      // then log the FullyColonized event.
      //if (statusName !== 'FullyColonized') {
      //  await setStatus(lot.id, 'FullyColonized');
      //}
      await logEvent(lot.id, 'FullyColonized', 'Dark Room');
    }
  }

  // ---------------------------------------------------------------------------
  // Standard status transitions
  // ---------------------------------------------------------------------------

  if (action === 'MoveToFridge') {
    // New behavior: assume lot is fully colonized if we're moving it,
    // and make sure history reflects that.
    await ensureFullyColonizedHistoryForTransition();

    await setStatus(lot.id, 'Fridge');
    const fridgeLoc = await findLocationByName('Fridge');
    if (fridgeLoc && hasField(lotsTbl, 'location_id')) {
      await lotsTbl.updateRecordAsync(lot.id, { location_id: [{ id: fridgeLoc.id }] });
    }
    await logEvent(lot.id, 'MovedToFridge', 'Dark Room');
    await lotsTbl.updateRecordAsync(lot.id, { action: null, ui_error: null, ui_error_at: null });
    return;
  }

  if (action === 'ColdShock') {
    // Same colonization assumption/handling for ColdShock.
    await ensureFullyColonizedHistoryForTransition();

    await setStatus(lot.id, 'Fridge');
    const fridgeLoc = await findLocationByName('Fridge');
    if (fridgeLoc && hasField(lotsTbl, 'location_id')) {
      await lotsTbl.updateRecordAsync(lot.id, { location_id: [{ id: fridgeLoc.id }] });
    }
    await logEvent(lot.id, 'ColdShock', 'Dark Room');
    await lotsTbl.updateRecordAsync(lot.id, { action: null, ui_error: null, ui_error_at: null });
    return;
  }

  if (action === 'FullyColonized') {
    await setStatus(lot.id, 'FullyColonized');
    await logEvent(lot.id, 'FullyColonized', 'Dark Room');
    await lotsTbl.updateRecordAsync(lot.id, { action: null, ui_error: null, ui_error_at: null });
    return;
  }

  if (action === 'Contaminated') {
    const sf = lotsTbl.getField('status');
    const retired = choiceByName(sf, 'Retired') || choiceByName(sf, 'Consumed');
    if (!retired) {
      const names = (sf.options?.choices || []).map(c => c.name).join(', ');
      throw new Error(`lots.status missing "Retired" (or Consumed). Has: ${names}`);
    }
    await lotsTbl.updateRecordAsync(lot.id, { status: { id: retired.id } });
    await logEvent(lot.id, 'Contaminated', 'Dark Room');
    await lotsTbl.updateRecordAsync(lot.id, { action: null, ui_error: null, ui_error_at: null });
    return;
  }

  if (action === 'Shake') {
    await logEvent(lot.id, 'Shake', 'Dark Room');
    await lotsTbl.updateRecordAsync(lot.id, { action: null, ui_error: null, ui_error_at: null });
    return;
  }

  if (action === 'StartFruiting') {
    // Also ensure a FullyColonized event before starting fruiting.
    await ensureFullyColonizedHistoryForTransition();

    await setStatus(lot.id, 'Fruiting');
    const fruitLoc = await findLocationByName('Fruiting Chamber');
    if (fruitLoc && hasField(lotsTbl, 'location_id')) {
      await lotsTbl.updateRecordAsync(lot.id, { location_id: [{ id: fruitLoc.id }] });
    }
    await logEvent(lot.id, 'StartFruiting', 'Dark Room');
    await lotsTbl.updateRecordAsync(lot.id, { action: null, ui_error: null, ui_error_at: null });
    return;
  }

  if (action === 'ApplyCasing') {
    if (itemCategory !== 'fruiting_block') {
      await failWithUI('Apply Casing is only allowed on fruiting blocks (item.category = fruiting_block).');
    }

    const casingLink = lot.getCellValue('casing_lot_id')?.[0] || null;
    let casingLot = null, casingItemId = null;

    if (casingLink) {
      casingLot = await lotsTbl.selectRecordAsync(casingLink.id);
      if (casingLot) {
        const casingItem = casingLot.getCellValue('item_id')?.[0]
          ? await itemsTbl.selectRecordAsync(casingLot.getCellValue('item_id')[0].id)
          : null;
        const casingCat = (casingItem?.getCellValueAsString('category') || '').toLowerCase();
        if (casingCat !== 'casing') {
          await failWithUI('Selected lot is not category "casing".');
        }
        casingItemId = casingLot.getCellValue('item_id')?.[0]?.id || null;
      }
    }

    await logEvent(lot.id, 'CasingApplied', 'Dark Room', {
      casing_lot_id: casingLot?.id || null,
      casing_item_id: casingItemId
    });

    if (casingLot) {
      const usedEvtChoice = (eventsTbl.getField('type').options?.choices || []).find(c => c.name === 'UsedForCasing');
      if (usedEvtChoice) {
        const rec = {
          fields: {
            lot_id: [{ id: casingLot.id }],
            type: { id: usedEvtChoice.id },
            station: 'Dark Room',
            fields_json: JSON.stringify({ applied_to_block_id: lot.id })
          }
        };
        if (tsWritable) rec.fields.timestamp = nowIso;
        await eventsTbl.createRecordsAsync([rec]);
      }
    }

    await lotsTbl.updateRecordAsync(lot.id, { action: null, ui_error: null, ui_error_at: null, casing_applied_at: nowIso});
    return;
  }

  const simpleActions = {
    'ApplyBeneficialTrichoderma': 'BeneficialTrichodermaApplied',
    'ApplyNematodes': 'NematodesApplied',
    'ApplyDiatomaceousEarth': 'DiatomaceousEarthApplied'
  };

  if (Object.keys(simpleActions).includes(action)) {
    await logEvent(lot.id, simpleActions[action], 'Dark Room');
    await lotsTbl.updateRecordAsync(lot.id, { action: null, ui_error: null, ui_error_at: null });
    return;
  }

  await lotsTbl.updateRecordAsync(lot.id, {
    ui_error: `Unknown action "${action}".`,
    ui_error_at: new Date().toISOString(),
    action: null
  });
  throw new Error(`Unhandled action: ${action}`);

} catch (e) {
  if (typeof output !== 'undefined' && output && output.set) {
    output.set('error', (e && e.message) ? e.message : String(e));
  }
}
