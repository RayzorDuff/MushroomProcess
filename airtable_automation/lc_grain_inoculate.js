/**
 * LC → Grain Inoculation (with override_inoc_time → inoculated_at, status=Colonizing)
 * Trigger: Interface button on a grain lot → Run a script
 * Input variables: { lotRecordId }
 * Writes validation errors to lots.ui_error
 */
const lotsTbl   = base.getTable('lots');
const itemsTbl  = base.getTable('items');
const eventsTbl = base.getTable('events');

const { lotRecordId } = input.config();

async function setUiError(id, msg){ await lotsTbl.updateRecordAsync(id, { ui_error: msg ?? '' }); }
async function fail(msg){ await setUiError(lotRecordId, msg); output.set('error', msg); return; }

if (!lotRecordId){ await fail('Missing lotRecordId'); return; }
const lot = await lotsTbl.selectRecordAsync(lotRecordId);
if (!lot){ await fail('Lot not found.'); return; }

const grainItems    = lot.getCellValue('item_id') ?? [];
const grainRecipes  = lot.getCellValue('recipe_id') ?? [];
const unitSize      = lot.getCellValue('unit_size');
const lcLinks       = lot.getCellValue('lc_lot_id') ?? [];
const volMl         = lot.getCellValue('lc_volume_ml');
const overrideRaw   = lot.getCellValue('override_inoc_time');
const inocAt        = overrideRaw ? new Date(overrideRaw) : new Date();

if (grainItems.length !== 1){ await fail('Select exactly one grain item.'); return; }
if (grainRecipes.length !== 1){ await fail('Select exactly one recipe for the grain item.'); return; }
if (!(typeof unitSize === 'number') || unitSize <= 0){ await fail('Unit size must be a positive number.'); return; }
if (lcLinks.length !== 1){ await fail('Select exactly one LC lot to inoculate from.'); return; }
if (!(typeof volMl === 'number') || volMl <= 0){ await fail('LC volume (ml) must be a positive number.'); return; }

// Ensure target is category=grain
let itemCategory = '';
{
  const item = await itemsTbl.selectRecordAsync(grainItems[0].id);
  itemCategory = (item?.getCellValueAsString('category') || '').toLowerCase();
  if (itemCategory !== 'grain'){ await fail(`This action is only for grain lots (found "${itemCategory || 'unknown'}").`); return; }
}

// Load LC source
const lcLot = await lotsTbl.selectRecordAsync(lcLinks[0].id);
if (!lcLot){ await fail('Selected LC lot was not found.'); return; }

const lcRemaining = lcLot.getCellValue('remaining_volume_ml');
if (!(typeof lcRemaining === 'number') || lcRemaining < volMl){
  await fail(`LC source does not have enough volume. Needed ${volMl} ml, available ${lcRemaining ?? 0} ml.`); return;
}

// Source category must be lc_flask or lc_syringe
let lcItemCategory = '';
{
  const lcItemLink = lcLot.getCellValue('item_id')?.[0];
  if (lcItemLink){
    const lcItem = await itemsTbl.selectRecordAsync(lcItemLink.id);
    lcItemCategory = (lcItem?.getCellValueAsString('category') || '').toLowerCase();
  }
  if (lcItemCategory !== 'lc_flask' && lcItemCategory !== 'lc_syringe'){
    await fail(`LC source must be a flask or syringe (found "${lcItemCategory || 'unknown'}").`); return;
  }
}

// Apply updates
await setUiError(lotRecordId, '');
const lcStrain = lcLot.getCellValue('strain_id')?.[0];
let grainUpdates = {
  status: { name: 'Colonizing' },
  inoculated_at: inocAt,
};
if (lotsTbl.getFieldByNameIfExists?.('action')) grainUpdates.action = '';
if (lcStrain) grainUpdates.strain_id = [{ id: lcStrain.id }];

await lotsTbl.updateRecordAsync(lotRecordId, grainUpdates);

// Decrement LC remaining volume
const newRemaining = Math.max(0, (lcRemaining || 0) - volMl);
let lcUpdates = { remaining_volume_ml: newRemaining };
if (newRemaining <= 0) lcUpdates.status = { name: 'Consumed' };
await lotsTbl.updateRecordAsync(lcLot.id, lcUpdates);

// Log event
await eventsTbl.createRecordAsync({
  lot_id: [{ id: lotRecordId }],
  type: { name: 'Inoculated' },
  timestamp: inocAt,
  station: 'Inoculation',
  fields_json: JSON.stringify({ source_lc_lot_id: lcLot.id, volume_ml: volMl })
});

output.set('ok', true);
