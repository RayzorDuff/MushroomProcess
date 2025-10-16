/***** Fruiting: start, harvest, compost (status Retired, event Composted) *****/
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
