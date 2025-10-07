/**
 * Spawn → Bulk – Create Fruiting Blocks
 * Trigger: Interface button on a staging/output lot record → Run a script
 * Input: { lotRecordId }
 * Requires: grain_inputs (links), substrate_inputs (links), output_count (number), unit_size (number)
 * Sets item_id based on substrate item code + size (FB-COCO/MM variants), category=fruiting_block
 * Copies strain from grain, sets status=Colonizing, marks inputs Consumed, logs SpawnedToBulk
 */
const lotsTbl = base.getTable('lots');
const itemsTbl = base.getTable('items');
const eventsTbl = base.getTable('events');

const { lotRecordId } = input.config();
if (!lotRecordId) { throw new Error('Missing lotRecordId'); }
const out = await lotsTbl.selectRecordAsync(lotRecordId);
if (!out) { throw new Error('Output record not found'); }

async function setErr(msg){ await lotsTbl.updateRecordAsync(lotRecordId, { ui_error: msg ?? '' }); }
await setErr(''); // clear

const grainInputs = out.getCellValue('grain_inputs') ?? [];
const subInputs   = out.getCellValue('substrate_inputs') ?? [];
const count       = out.getCellValue('output_count');
const size        = out.getCellValue('unit_size');
const overrideRaw = out.getCellValue('override_spawn_time');
const spawnedAt   = overrideRaw ? new Date(overrideRaw) : new Date();

if (!grainInputs.length){ await setErr('Select at least one grain input.'); output.set('error', 'validation'); return; }
if (!subInputs.length){ await setErr('Select at least one substrate input.'); output.set('error', 'validation'); return; }
if (!(typeof count === 'number') || count < 1){ await setErr('output_count must be ≥ 1.'); output.set('error', 'validation'); return; }
if (!(typeof size === 'number') || size <= 0){ await setErr('unit_size must be a positive number.'); output.set('error', 'validation'); return; }

// Derive item_id by substrate item_id text & size threshold 5
function pickSku(subItemName, perBag){
  const name = (subItemName || '').toUpperCase();
  const lg = perBag >= 5;
  if (name.includes('CVG')) return lg ? 'FB-COCO-LG' : 'FB-COCO-SM';
  if (name.includes('MM75')) return lg ? 'FB-MM75-LG' : 'FB-MM75-SM';
  if (name.includes('MM50')) return lg ? 'FB-MM50-LG' : 'FB-MM50-SM';
  return 'FB-GENERIC';
}

// Load first substrate item name
let subItemName = '';
{
  const subLot = await lotsTbl.selectRecordAsync(subInputs[0].id);
  const li = subLot?.getCellValue('item_id')?.[0];
  if (li){
    const item = await itemsTbl.selectRecordAsync(li.id);
    subItemName = item?.name || item?.getCellValueAsString('name') || '';
  }
}

// Resolve SKU item record by item_id text
async function findItemByCode(code){
  const q = await itemsTbl.selectRecordsAsync({ fields: ['item_id','name','category'] });
  let match = null;
  for (let r of q.records){
    const codeVal = r.getCellValueAsString('item_id');
    if (codeVal && codeVal.toUpperCase() === code.toUpperCase()){ match = r; break; }
  }
  q.unloadData();
  return match;
}

const targetCode = pickSku(subItemName, size);
const targetItem = await findItemByCode(targetCode);

// Copy strain from first grain input
let sourceStrain = null;
{
  const gLot = await lotsTbl.selectRecordAsync(grainInputs[0].id);
  const s = gLot?.getCellValue('strain_id')?.[0];
  if (s) sourceStrain = s.id;
}

// Update output record as "the" new block
let updates = {
  status: { name: 'Colonizing' },
  spawned_at: spawnedAt,
  // ensure category is fruiting_block via the item selected:
};
if (targetItem){
  updates.item_id = [{ id: targetItem.id }];
}
if (sourceStrain){
  updates.strain_id = [{ id: sourceStrain }];
}
await lotsTbl.updateRecordAsync(lotRecordId, updates);

// Mark inputs consumed
for (const g of grainInputs){
  await lotsTbl.updateRecordAsync(g.id, { status: { name: 'Consumed' } });
}
for (const s of subInputs){
  await lotsTbl.updateRecordAsync(s.id, { status: { name: 'Consumed' } });
}

// Log event
await eventsTbl.createRecordAsync({
  lot_id: [{ id: lotRecordId }],
  type: { name: 'SpawnedToBulk' },
  timestamp: spawnedAt,
  station: 'Lab',
  fields_json: JSON.stringify({
    grain_inputs: grainInputs.map(x=>x.id),
    substrate_inputs: subInputs.map(x=>x.id),
    unit_size: size,
    output_count: count
  })
});

output.set('ok', true);
