/**
 * LC → Flask Inoculation (source = LC syringe)
 * Trigger: Interface button on a flask lot → Run a script
 * Input: { lotRecordId }
 * Validates LC syringe volume, sets flask strain/status, decrements syringe remaining_volume_ml
 * Writes errors to lots.ui_error
 */
const lotsTbl   = base.getTable('lots');
const itemsTbl  = base.getTable('items');
const eventsTbl = base.getTable('events');

const { lotRecordId } = input.config();

async function setErr(id, msg){ await lotsTbl.updateRecordAsync(id, { ui_error: msg ?? '' }); }
async function fail(msg){ await setErr(lotRecordId, msg); output.set('error', msg); return; }

if (!lotRecordId){ await fail('Missing lotRecordId'); return; }
const flask = await lotsTbl.selectRecordAsync(lotRecordId);
if (!flask){ await fail('Flask lot not found.'); return; }

// category check
let flaskCat = '';
{
  const it = flask.getCellValue('item_id')?.[0];
  if (!it){ await fail('Flask item_id is required.'); return; }
  const item = await itemsTbl.selectRecordAsync(it.id);
  flaskCat = (item?.getCellValueAsString('category') || '').toLowerCase();
  if (flaskCat !== 'lc_flask'){ await fail(`Target must be lc_flask (found "${flaskCat || 'unknown'}").`); return; }
}

const lcLinks = flask.getCellValue('lc_lot_id') ?? [];
const volMl   = flask.getCellValue('lc_volume_ml');
const overrideRaw = flask.getCellValue('override_inoc_time');
const inocAt = overrideRaw ? new Date(overrideRaw) : new Date();

if (lcLinks.length !== 1){ await fail('Select exactly one LC syringe (source).'); return; }
if (!(typeof volMl === 'number') || volMl <= 0){ await fail('LC volume (ml) must be positive.'); return; }

const syringe = await lotsTbl.selectRecordAsync(lcLinks[0].id);
if (!syringe){ await fail('LC syringe not found.'); return; }

// source category
let srcCat = '';
{
  const it = syringe.getCellValue('item_id')?.[0];
  if (it){
    const item = await itemsTbl.selectRecordAsync(it.id);
    srcCat = (item?.getCellValueAsString('category') || '').toLowerCase();
  }
  if (srcCat !== 'lc_syringe'){ await fail(`Source must be lc_syringe (found "${srcCat || 'unknown'}").`); return; }
}

const rem = syringe.getCellValue('remaining_volume_ml') || 0;
if (rem < volMl){ await fail(`Syringe volume insufficient. Needed ${volMl} ml, has ${rem} ml.`); return; }

await setErr(lotRecordId, '');

// Apply updates to flask
const srcStrain = syringe.getCellValue('strain_id')?.[0];
let up = { status: { name: 'Colonizing' } };
if (srcStrain) up.strain_id = [{ id: srcStrain.id }];
await lotsTbl.updateRecordAsync(lotRecordId, up);

// Decrement syringe
const newRem = Math.max(0, rem - volMl);
let sup = { remaining_volume_ml: newRem };
if (newRem <= 0) sup.status = { name: 'Consumed' };
await lotsTbl.updateRecordAsync(syringe.id, sup);

// Event
await eventsTbl.createRecordAsync({
  lot_id: [{ id: lotRecordId }],
  type: { name: 'LCInoculateFlask' },
  timestamp: inocAt,
  station: 'Inoculation',
  fields_json: JSON.stringify({ source_syringe_lot_id: syringe.id, volume_ml: volMl })
});

output.set('ok', true);
