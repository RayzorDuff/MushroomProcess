/**
 * Script: lc_flask_inoculate.js
 * Version: 2025-10-16.1
 * Summary: Airtable automation script with resilience guards.
 * Notes: Succinct header; no diff blocks; try/catch + error surfacing.
 */
try {


const lotsTbl   = base.getTable('lots');
const itemsTbl  = base.getTable('items');
const eventsTbl = base.getTable('events');

const { lotRecordId } = input.config(); // target flask lot (record id)

//for (const e of lotsTbl.fields) {
//  console.log('lots', `${e.id} :: ${e.name} [${e.type}]`);
//}
function nowIso() { return new Date().toISOString(); }
function toName(v){ try { return v?.name ?? ''; } catch { return ''; } }

async function setError(lotId, msg){
  await lotsTbl.updateRecordAsync(lotId, { ui_error: msg ?? '' });
}
async function fail(msg){
  if (lotRecordId) await setError(lotRecordId, msg);
  output.set('error', msg);
  return;
}

if (!lotRecordId) { await fail('Missing lotRecordId.'); return; }

const flask = await lotsTbl.selectRecordAsync(lotRecordId);
if (!flask) { await fail('Flask lot not found.'); return; }

// -------- Inputs on the flask record
const flaskLotID   = flask.getCellValue('lot_id') ?? [];
const itemLinks   = flask.getCellValue('item_id') ?? [];
const recipeLinks = flask.getCellValue('recipe_id') ?? [];
const unitSize    = flask.getCellValue('unit_size'); // optional, if you use it for LC
const lcLinks     = flask.getCellValue('lc_lot_id') ?? []; // LC syringe source
const volMl       = flask.getCellValue('lc_volume_ml');    // volume injected into flask
const fv          = flask.getCellValue('total_volume_ml') || flask.getCellValue('unit_size');
const curRem      = flask.getCellValue('remaining_volume_ml');


// -------- Validate cardinality & numbers
if (itemLinks.length !== 1)   { await fail('Select exactly one flask item.'); return; }
if (recipeLinks.length !== 1) { await fail('Select exactly one recipe for the flask.'); return; }
if (!(typeof volMl === 'number') || volMl <= 0) { await fail('LC volume (ml) must be a positive number.'); return; }
if (lcLinks.length !== 1)     { await fail('Select exactly one LC syringe (source).'); return; }

const srcLink = lcLinks[0];

// -------- Ensure target item.category = lc_flask
let flaskItemCategory = '';
{
  const item = await itemsTbl.selectRecordAsync(itemLinks[0].id);
  flaskItemCategory = (item?.getCellValueAsString('category') || '').toLowerCase();
  if (flaskItemCategory !== 'lc_flask') {
    await fail(`This action is only for LC flasks (found category "${flaskItemCategory || 'unknown'}").`);
    return;
  }
}

// -------- Load LC syringe source, validate remaining volume
const srcLot = await lotsTbl.selectRecordAsync(srcLink.id);
if (!srcLot) { await fail('Selected LC syringe lot was not found.'); return; }

const srcRemaining = srcLot.getCellValue('remaining_volume_ml');
if (!(typeof srcRemaining === 'number') || srcRemaining < volMl) {
  await fail(`Syringe does not have enough volume. Needed ${volMl} ml, has ${srcRemaining ?? 0} ml.`);
  return;
}

// Optional: ensure source item.category=lc_syringe
let srcItemCategory = '';
{
  const srcItemLink = srcLot.getCellValue('item_id')?.[0];
  if (srcItemLink) {
    const it = await itemsTbl.selectRecordAsync(srcItemLink.id);
    srcItemCategory = (it?.getCellValueAsString('category') || '').toLowerCase();
  }
  if (srcItemCategory !== 'lc_syringe') {
    await fail(`Source must be an LC syringe (found "${srcItemCategory || 'unknown'}").`);
    return;
  }
}

// -------- Apply updates to the flask: set strain from source; status Colonizing
const srcStrain = srcLot.getCellValue('strain_id')?.[0];
let flaskUpdate = {
  status: { name: 'Colonizing' },
  action: null // clear action if present
};
if (srcStrain) flaskUpdate.strain_id = [{ id: srcStrain.id }];


console.log('Flask ', flaskLotID, ' ', ' total_volume_ml: ', fv);

if (typeof fv === 'number' && fv > 0) {
  // Initialize remaining to the full flask volume if not already set
  console.log('Flask total_volume_ml: ', fv, ' Flask current remaining_volume_ml: ', curRem);
  if (!(typeof curRem === 'number') || curRem <= 0) {

    flaskUpdate.remaining_volume_ml = fv + volMl;
  } else {flaskUpdate.remaining_volume_ml = curRem + volMl; }
}


console.log('Source remaining_volume_ml: ', srcRemaining, " Flask remaining_volume_ml: ", flaskUpdate.remaining_volume_ml);

await setError(lotRecordId, '');
await lotsTbl.updateRecordAsync(lotRecordId, flaskUpdate);

// -------- Decrement syringe remaining volume, mark consumed if empty
const newRemaining = Math.max(0, (srcRemaining || 0) - volMl);
let srcUpdate = { remaining_volume_ml: newRemaining };
if (newRemaining <= 0) {
  srcUpdate.status = { name: 'Consumed' };
}
await lotsTbl.updateRecordAsync(srcLot.id, srcUpdate);

// -------- Log event
await eventsTbl.createRecordAsync({
  lot_id: [{ id: lotRecordId }],
  type: { name: 'LCInoculate' }, // use your exact event type name
  timestamp: new Date(),
  station: 'Inoculation',
  operator: '',
  fields_json: JSON.stringify({
    source_syringe_lot_id: srcLot.id,
    volume_ml: volMl
  })
});

output.set('ok', true);

} catch (e) {
  if (typeof output !== 'undefined' && output && output.set) {
    output.set('error', (e && e.message) ? e.message : String(e));
  }
}
