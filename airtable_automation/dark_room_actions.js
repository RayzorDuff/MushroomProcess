/**
 * Script: dark_room_actions.js
 * Version: 2025-10-16.1
 * Summary: Airtable automation script with resilience guards.
 * Notes: Succinct header; no diff blocks; try/catch + error surfacing.
 */
try {


const { lotId } = input.config();

const lotsTbl   = base.getTable('lots');
const locTbl    = base.getTable('locations');
const itemsTbl  = base.getTable('items');
const eventsTbl = base.getTable('events');

function hasField(tbl, name) {
  try { tbl.getField(name); return true; } catch { return false; }
}

const lot = await lotsTbl.selectRecordAsync(lotId);
if (!lot) throw new Error('Lot not found');

const action = lot.getCellValueAsString('action') || '';
if (!action) return;

const nowIso = new Date().toISOString();
const tsWritable = (() => { try { return eventsTbl.getField('timestamp').type === 'dateTime'; } catch { return false; }})();

/* -- helpers -- */
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
async function logEvent(lotId, typeName, station, payload={}) {
  const typeField = eventsTbl.getField('type');
  const typeChoice = (typeField.options?.choices || []).find(c => c.name === typeName);
  if (!typeChoice) return; // silently skip if missing
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
  if (hasField(lotsTbl, 'ui_error'))    update.ui_error = msg;
  if (hasField(lotsTbl, 'ui_error_at')) update.ui_error_at = new Date().toISOString();
  if (hasField(lotsTbl, 'action'))      update.action = null;
  if (Object.keys(update).length) await lotsTbl.updateRecordAsync(lot.id, update);
  throw new Error(msg);
}

/* -- read current status + item category of the target lot -- */
const statusName = lot.getCellValueAsString('status') || '';
let itemCategory = '';
try {
  const itemLink = lot.getCellValue('item_id')?.[0] || null;
  if (itemLink) {
    const item = await itemsTbl.selectRecordAsync(itemLink.id);
    itemCategory = (item?.getCellValueAsString('category') || '').toLowerCase();
  }
} catch {}

/* -- validation for MoveToFridge / ColdShock -- */
async function guardFullyColonizedForChillishActions() {
  const isVendorSyringe = (itemCategory === 'lc_syringe'); // exempt
  if (!isVendorSyringe && statusName !== 'FullyColonized') {
    await failWithUI('Only FullyColonized lots may be moved to Fridge or Cold Shock (vendor LC syringes excepted).');
  }
}

/* -- route by action -- */
if (action === 'MoveToFridge') {
  await guardFullyColonizedForChillishActions();
  await setStatus(lot.id, 'Fridge'); // ensure this status exists
  const fridgeLoc = await findLocationByName('Fridge');
  if (fridgeLoc && hasField(lotsTbl, 'location_id')) {
    await lotsTbl.updateRecordAsync(lot.id, { location_id: [{ id: fridgeLoc.id }] });
  }
  await logEvent(lot.id, 'MovedToFridge', 'Dark Room');
  await lotsTbl.updateRecordAsync(lot.id, { action: null, ui_error: null, ui_error_at: null });
  return;
}

if (action === 'ColdShock') {
  await guardFullyColonizedForChillishActions();
  await setStatus(lot.id, 'Fridge'); // same movement
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
  // New validation: target must be a fruiting block
  if (itemCategory !== 'fruiting_block') {
    await failWithUI('Apply Casing is only allowed on fruiting blocks (item.category = fruiting_block).');
  }

  // require a linked casing_lot_id on the block
  const casingLink = lot.getCellValue('casing_lot_id')?.[0] || null;
  if (!casingLink) {
    await failWithUI('Select a casing_lot_id before Apply Casing.');
  }

  const casingLot = await lotsTbl.selectRecordAsync(casingLink.id);
  if (!casingLot) {
    await failWithUI('Casing lot not found.');
  }

  // Verify the selected lot’s item.category = casing
  let casingCat = '';
  try {
    const casingItem = casingLot.getCellValue('item_id')?.[0]
      ? await itemsTbl.selectRecordAsync(casingLot.getCellValue('item_id')[0].id)
      : null;
    casingCat = (casingItem?.getCellValueAsString('category') || '').toLowerCase();
  } catch {}
  if (casingCat !== 'casing') {
    await failWithUI('Selected lot is not category "casing".');
  }

  // Log events
  await logEvent(lot.id, 'CasingApplied', 'Dark Room', {
    casing_lot_id: casingLot.id,
    casing_item_id: casingLot.getCellValue('item_id')?.[0]?.id || null
  });
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

  await lotsTbl.updateRecordAsync(lot.id, { action: null, ui_error: null, ui_error_at: null });
  return;
}

/* -- Unknown action -- */
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
