/**
 * LC Draw Syringes (from flask) – validates and creates syringe lots, decrements flask volume
 * Trigger: Interface button on a flask lot → Run a script
 * Input: { lotRecordId }
 * Requires fields: syringe_item_id (link to items, category=lc_syringe), syringe_count (number ≥1)
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

// Validate category = lc_flask
let flaskCat = '';
{
  const it = flask.getCellValue('item_id')?.[0];
  if (!it){ await fail('Flask item_id is required.'); return; }
  const item = await itemsTbl.selectRecordAsync(it.id);
  flaskCat = (item?.getCellValueAsString('category') || '').toLowerCase();
  if (flaskCat !== 'lc_flask'){ await fail(`Target must be lc_flask (found "${flaskCat || 'unknown'}").`); return; }
}

const syringeItemLink = flask.getCellValue('syringe_item_id')?.[0];
const syringeCount = flask.getCellValue('syringe_count');
if (!syringeItemLink){ await fail('Choose syringe_item_id (an item with category=lc_syringe).'); return; }
if (!(typeof syringeCount === 'number') || syringeCount < 1){ await fail('syringe_count must be ≥ 1.'); return; }

// Ensure syringe item category
{
  const sitem = await itemsTbl.selectRecordAsync(syringeItemLink.id);
  const cat = (sitem?.getCellValueAsString('category') || '').toLowerCase();
  if (cat !== 'lc_syringe'){ await fail('syringe_item_id must be category lc_syringe.'); return; }
}

const remaining = flask.getCellValue('remaining_volume_ml') || 0;
const needed = 10 * syringeCount;
if (remaining < needed){ await fail(`Not enough LC in flask. Needed ${needed} ml, has ${remaining} ml.`); return; }

await setErr(lotRecordId, '');

// Create syringe lots
let made = 0;
for (let i=0;i<syringeCount;i++){
  await lotsTbl.createRecordAsync({
    item_id: [{ id: syringeItemLink.id }],
    strain_id: flask.getCellValue('strain_id') || [],
    status: { name: 'Fridge' },
    remaining_volume_ml: 10
  });
  made++;
}

// Decrement flask
await lotsTbl.updateRecordAsync(lotRecordId, { remaining_volume_ml: remaining - needed });

// Log event
await eventsTbl.createRecordAsync({
  lot_id: [{ id: lotRecordId }],
  type: { name: 'SyringesDrawn' },
  timestamp: new Date(),
  station: 'Lab',
  fields_json: JSON.stringify({ count: syringeCount, per_syringe_ml: 10 })
});

output.set('created_syringes', made);
