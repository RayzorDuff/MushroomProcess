/**
 * Script: fruiting_actions.js
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
 * Summary: Fruiting – Actions
 * Notes: Succinct header; no diff blocks; try/catch + error surfacing.
 */
try {


const { lotRecordId } = input.config();
const lotsTbl   = base.getTable('lots');
const eventsTbl = base.getTable('events');

const lot = await lotsTbl.selectRecordAsync(lotRecordId);
if (!lot) throw new Error('Lot not found');

const action = (lot.getCellValueAsString('action') || '').toLowerCase();
if (!action) return;

// Helpers
const choiceByName = (table, fieldName, name) => {
  const f = table.getField(fieldName);
  const choices = f.options?.choices || [];
  return choices.find(c => c.name === name) || null;
};
const evtFieldType = (n) => { try { return eventsTbl.getField(n).type; } catch { return null; } };

const nowIso = new Date().toISOString();
const eventTimestampWritable = evtFieldType('timestamp') === 'dateTime';

// Resolve status choices
const fruitingStatus = choiceByName(lotsTbl, 'status', 'Fruiting');
const retiredStatus  = choiceByName(lotsTbl, 'status', 'Retired');
if (!fruitingStatus || !retiredStatus) {
  const opts = (lotsTbl.getField('status').options?.choices || []).map(c => c.name).join(', ');
  throw new Error(`Lots.status missing "Fruiting" or "Retired". Has: ${opts}`);
}

// Resolve event choices
const fruitingStartEvt = choiceByName(eventsTbl, 'type', 'FruitingStart');
const harvestEvt       = choiceByName(eventsTbl, 'type', 'Harvest');
const compostedEvt     = choiceByName(eventsTbl, 'type', 'Composted');  // new event type
if (!fruitingStartEvt || !harvestEvt || !compostedEvt) {
  const opts = (eventsTbl.getField('type').options?.choices || []).map(c => c.name).join(', ');
  throw new Error(`Events.type missing "FruitingStart", "Harvest", or "Composted". Has: ${opts}`);
}

if (action === 'startfruiting') {
  const e = { lot_id: [{ id: lot.id }], type: { id: fruitingStartEvt.id }, station: 'Fruiting' };
  if (eventTimestampWritable) e.timestamp = nowIso;
  await eventsTbl.createRecordAsync(e);
  await lotsTbl.updateRecordAsync(lot.id, { status: { id: fruitingStatus.id }, action: null });
  return;
}



if (action === 'composted') {
  // Set lot status to Retired and clear action
  await lotsTbl.updateRecordAsync(lot.id, { status: { id: retiredStatus.id }, action: null });

  // Log Composted event
  const e = { lot_id: [{ id: lot.id }], type: { id: compostedEvt.id }, station: 'Fruiting' };
  if (eventTimestampWritable) e.timestamp = nowIso;
  await eventsTbl.createRecordAsync(e);
  return;
}

// Fallback: clear stray action
await lotsTbl.updateRecordAsync(lot.id, { action: null });

} catch (e) {
  if (typeof output !== 'undefined' && output && output.set) {
    output.set('error', (e && e.message) ? e.message : String(e));
  }
}
