/***** LC → Grain Inoculation (updated)
 * - Validates inputs and writes user-visible messages to lots.ui_error
 * - Sets grain lot strain to match LC lot strain
 * - Uses override_inoc_time (if set) else current time; writes to inoculated_at
 * - Updates grain lot status to Colonizing
 * - Decrements LC source remaining_volume_ml; marks Consumed if empty
 * - Logs an Inoculated event with the same timestamp
 *****/

const lotsTbl   = base.getTable('lots');
const itemsTbl  = base.getTable('items');
const eventsTbl = base.getTable('events');

const { lotRecordId } = input.config(); // Record ID of the target grain lot

/* ------------ helpers ------------- */
function toName(v){ try { return v?.name ?? ''; } catch { return ''; } }
async function setUiError(lotId, msg){ await lotsTbl.updateRecordAsync(lotId, { ui_error: msg ?? '' }); }
async function fail(msg){
  if (lotRecordId) await setUiError(lotRecordId, msg);
  output.set('error', msg);
  return; // graceful stop so the interface stays open and shows ui_error
}

/* ------------ basic load ------------- */
if (!lotRecordId) { await fail('Missing lotRecordId.'); return; }

const lot = await lotsTbl.selectRecordAsync(lotRecordId);
if (!lot) { await fail('Lot not found.'); return; }

/* ------------ read inputs from lot record ------------- */
// These field names assume your LC→Grain page writes here:
const grainItems    = lot.getCellValue('item_id') ?? [];      // link → items (target grain item)
const grainRecipes  = lot.getCellValue('recipe_id') ?? [];    // link → recipes (for the grain)
const unitSize      = lot.getCellValue('unit_size');          // number > 0
const lcLinks       = lot.getCellValue('lc_lot_id') ?? [];    // link → lots (LC source: syringe or flask)
const volMl         = lot.getCellValue('lc_volume_ml');       // number > 0

// Inoculation time override (Date field on the lot)
const overrideRaw   = lot.getCellValue('override_inoc_time'); // ISO string or null
const inocAt        = overrideRaw ? new Date(overrideRaw) : new Date();

/* ------------ validations ------------- */
if (grainItems.length !== 1)   { await fail('Select exactly one grain item.'); return; }
if (grainRecipes.length !== 1) { await fail('Select exactly one recipe for the grain item.'); return; }

if (!(typeof unitSize === 'number') || unitSize <= 0) {
  await fail('Unit size must be a positive number.'); return;
}
if (lcLinks.length !== 1) {
  await fail('Select exactly one LC lot to inoculate from.'); return;
}
if (!(typeof volMl === 'number') || volMl <= 0) {
  await fail('LC volume (ml) must be a positive number.'); return;
}

/* enforce target item.category = "grain" */
const grainItemLink = grainItems[0];
let grainCategory = '';
{
  const item = await itemsTbl.selectRecordAsync(grainItemLink.id);
  grainCategory = (item?.getCellValueAsString('category') || '').toLowerCase();
  if (grainCategory !== 'grain') {
    await fail(`This action is only for grain lots (found category "${grainCategory || 'unknown'}").`);
    return;
  }
}

/* load LC source lot and check volume & category */
const lcLink = lcLinks[0];
const lcLot = await lotsTbl.selectRecordAsync(lcLink.id);
if (!lcLot) { await fail('Selected LC lot was not found.'); return; }

const lcRemaining = lcLot.getCellValue('remaining_volume_ml');
if (!(typeof lcRemaining === 'number') || lcRemaining < volMl) {
  await fail(`LC source does not have enough volume. Needed ${volMl} ml, available ${lcRemaining ?? 0} ml.`);
  return;
}

/* optional: ensure LC source category is lc_flask or lc_syringe */
let lcItemCategory = '';
{
  const lcItemLink = lcLot.getCellValue('item_id')?.[0];
  if (lcItemLink) {
    const lcItem = await itemsTbl.selectRecordAsync(lcItemLink.id);
    lcItemCategory = (lcItem?.getCellValueAsString('category') || '').toLowerCase();
  }
  if (lcItemCategory !== 'lc_flask' && lcItemCategory !== 'lc_syringe') {
    await fail(`LC source must be a flask or syringe (found "${lcItemCategory || 'unknown'}").`);
    return;
  }
}

/* ------------ clear prior ui_error before updates ------------- */
await setUiError(lotRecordId, '');

/* ------------ apply updates to the grain lot ------------- */
// set grain lot strain to LC strain if present
const lcStrain = lcLot.getCellValue('strain_id')?.[0];
const grainUpdates = {
  status: { name: 'Colonizing' },          // changed from Inoculated → Colonizing
  inoculated_at: inocAt,                   // write override or now
  // clear action if you use an action field
  ...(lotsTbl.getFieldByNameIfExists?.('action') ? { action: '' } : {})
};
if (lcStrain) { grainUpdates.strain_id = [{ id: lcStrain.id }]; }

await lotsTbl.updateRecordAsync(lotRecordId, grainUpdates);

/* ------------ decrement LC source remaining volume ------------- */
const newRemaining = Math.max(0, (lcRemaining || 0) - volMl);
const lcUpdates = { remaining_volume_ml: newRemaining };

// if drained to zero, mark Consumed; otherwise leave status as-is
if (newRemaining <= 0) {
  lcUpdates.status = { name: 'Consumed' };
}
await lotsTbl.updateRecordAsync(lcLot.id, lcUpdates);

/* ------------ log event for traceability ------------- */
await eventsTbl.createRecordAsync({
  lot_id: [{ id: lotRecordId }],
  type: { name: 'Inoculated' },   // keep event type as Inoculated for history
  timestamp: inocAt,              // use the same effective timestamp
  station: 'Inoculation',
  operator: '',                   // fill if you capture operator identity
  fields_json: JSON.stringify({
    source_lc_lot_id: lcLot.id,
    volume_ml: volMl
  })
});

/* ------------ done ------------- */
output.set('ok', true);
