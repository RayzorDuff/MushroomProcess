/**
 * Dark Room – Actions
 * Trigger: When {action} changes OR Interface button sets {action}, then Run a script
 * Enforces:
 * - Only FullyColonized items can MoveToFridge or ColdShock (LC vendor syringes excepted if needed)
 * - Only fruiting_block can ApplyCasing (requires casing_lot_id)
 * - Handles FullyColonized, Shake, MoveToFridge, ColdShock, StartFruiting, ApplyCasing
 * Writes errors to lots.ui_error
 */
const lotsTbl   = base.getTable('lots');
const itemsTbl  = base.getTable('items');
const eventsTbl = base.getTable('events');

const { lotRecordId } = input.config();

async function setErr(id, msg){ await lotsTbl.updateRecordAsync(id, { ui_error: msg ?? '' }); }
async function clearErr(id){ await lotsTbl.updateRecordAsync(id, { ui_error: '' }); }

if (!lotRecordId) { throw new Error('Missing lotRecordId'); }
const lot = await lotsTbl.selectRecordAsync(lotRecordId);
if (!lot) { throw new Error('Lot not found'); }

const action = lot.getCellValueAsString('action') || '';
const status = lot.getCellValueAsString('status') || '';

// Determine category
let category = '';
{
  const it = lot.getCellValue('item_id')?.[0];
  if (it){
    const item = await itemsTbl.selectRecordAsync(it.id);
    category = (item?.getCellValueAsString('category') || '').toLowerCase();
  }
}

// Gate: MoveToFridge / ColdShock require FullyColonized (except lc_syringe vendor lots)
if ((action === 'MoveToFridge' || action === 'ColdShock')){
  if (category !== 'lc_syringe' && status !== 'FullyColonized'){
    await setErr(lotRecordId, 'Only FullyColonized items can be moved to Fridge or Cold Shocked.');
    return;
  }
}

// Apply Casing only for fruiting_block
if (action === 'ApplyCasing'){
  if (category !== 'fruiting_block'){
    await setErr(lotRecordId, 'Apply Casing is only valid for fruiting blocks.');
    return;
  }
  const casing = lot.getCellValue('casing_lot_id');
  if (!casing?.length){
    await setErr(lotRecordId, 'Select a casing lot before applying casing.'); return;
  }
  await clearErr(lotRecordId);
  await eventsTbl.createRecordAsync({
    lot_id: [{ id: lotRecordId }],
    type: { name: 'CasingApplied' },
    timestamp: new Date(),
    station: 'DarkRoom',
    fields_json: JSON.stringify({ casing_lot_id: casing[0].id })
  });
  await lotsTbl.updateRecordAsync(lotRecordId, { action: '' });
  return;
}

// Other actions
switch(action){
  case 'FullyColonized':
    await clearErr(lotRecordId);
    await lotsTbl.updateRecordAsync(lotRecordId, { status: { name: 'FullyColonized' }, action: '' });
    await eventsTbl.createRecordAsync({ lot_id: [{ id: lotRecordId }], type: { name: 'FullyColonized' }, timestamp: new Date(), station: 'DarkRoom' });
    break;
  case 'Shake':
    await clearErr(lotRecordId);
    await eventsTbl.createRecordAsync({ lot_id: [{ id: lotRecordId }], type: { name: 'Shake' }, timestamp: new Date(), station: 'DarkRoom' });
    await lotsTbl.updateRecordAsync(lotRecordId, { action: '' });
    break;
  case 'MoveToFridge':
    await clearErr(lotRecordId);
    await lotsTbl.updateRecordAsync(lotRecordId, { status: { name: 'Fridge' }, action: '' });
    await eventsTbl.createRecordAsync({ lot_id: [{ id: lotRecordId }], type: { name: 'MoveToFridge' }, timestamp: new Date(), station: 'DarkRoom' });
    break;
  case 'ColdShock':
    await clearErr(lotRecordId);
    await lotsTbl.updateRecordAsync(lotRecordId, { status: { name: 'Fridge' }, action: '' });
    await eventsTbl.createRecordAsync({ lot_id: [{ id: lotRecordId }], type: { name: 'ColdShock' }, timestamp: new Date(), station: 'DarkRoom' });
    break;
  case 'StartFruiting':
    await clearErr(lotRecordId);
    await lotsTbl.updateRecordAsync(lotRecordId, { status: { name: 'Fruiting' }, action: '' });
    await eventsTbl.createRecordAsync({ lot_id: [{ id: lotRecordId }], type: { name: 'StartFruiting' }, timestamp: new Date(), station: 'DarkRoom' });
    break;
  default:
    // ignore
    break;
}

output.set('ok', true);
