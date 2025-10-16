/**
 * Fruiting – Actions
 * Trigger: When {action} changes or Interface button sets it; Run a script
 * Supports: StartFruiting, Composted
 */
const lotsTbl = base.getTable('lots');
const eventsTbl = base.getTable('events');

const { lotRecordId } = input.config();
if (!lotRecordId) { throw new Error('Missing lotRecordId'); }

const lot = await lotsTbl.selectRecordAsync(lotRecordId);
if (!lot) { throw new Error('Lot not found'); }

const action = lot.getCellValueAsString('action') || '';

switch(action){
  case 'StartFruiting':
    await lotsTbl.updateRecordAsync(lotRecordId, { status: { name: 'Fruiting' }, action: '' });
    await eventsTbl.createRecordAsync({ lot_id: [{ id: lotRecordId }], type: { name: 'StartFruiting' }, timestamp: new Date(), station: 'Fruiting' });
    break;
  case 'Composted':
    await lotsTbl.updateRecordAsync(lotRecordId, { status: { name: 'Retired' }, action: '' });
    await eventsTbl.createRecordAsync({ lot_id: [{ id: lotRecordId }], type: { name: 'Composted' }, timestamp: new Date(), station: 'Fruiting' });
    break;
  default:
    break;
}

output.set('ok', true);
