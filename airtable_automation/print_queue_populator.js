/***** Print Queue Populator (sets lots.label_template too) *****/
const { eventId} = input.config();

const eventsTbl     = base.getTable('events');
const lotsTbl       = base.getTable('lots');
const itemsTbl      = base.getTable('items');
const printQueueTbl = base.getTable('print_queue');

function toName(val) {
  if (val == null) return '';
  if (typeof val === 'string') return val;
  try { return val.name ?? ''; } catch { return ''; }
}
function getSelectChoiceOrThrow(tbl, fieldName, choiceName) {
  const f = tbl.getField(fieldName);
  const c = (f.options?.choices || []).find(x => x.name === choiceName);
  if (!c) {
    const opts = (f.options?.choices || []).map(x => x.name).join(', ');
    throw new Error(`${tbl.name}.${fieldName} missing option "${choiceName}". Has: ${opts}`);
  }
  return c;
}
async function findQueuedDuplicateByLot(lotId, labelTypeName) {
  const q = await printQueueTbl.selectRecordsAsync({
    fields: ['print_status','source_kind','lot_id','label_type'],
    sorts: [{field: 'created_at', direction: 'desc'}]
  });
  for (const r of q.records) {
    const status = toName(r.getCellValue('print_status'));
    const src    = r.getCellValueAsString('source_kind') || '';
    const lt     = toName(r.getCellValue('label_type'));
    const link   = r.getCellValue('lot_id')?.[0]?.id || null;
    if (status === 'Queued' && src === 'lot' && link === lotId && lt === labelTypeName) return r;
  }
  return null;
}

if (!eventId) throw new Error('Missing input: eventId');

const ev = await eventsTbl.selectRecordAsync(eventId);
if (!ev) throw new Error('Event not found');

const eventType = toName(ev.getCellValue('type')); // "Inoculated", "LCInoculateFlask", "Spawned", "SpawnedToBulk"
const lotLink   = ev.getCellValue('lot_id')?.[0] || null;
if (!lotLink) return; // not tied to a lot
const lotId = lotLink.id;

// Determine item.category (to detect grain)
let itemCategory = '';
try {
  const lot = await lotsTbl.selectRecordAsync(lotId);
  const lotItem = lot?.getCellValue('item_id')?.[0] || null;
  if (lotItem) {
    const itemRec = await itemsTbl.selectRecordAsync(lotItem.id);
    itemCategory = (itemRec?.getCellValueAsString('category') || '').toLowerCase();
  }
} catch {}

// Map event ? label_type (and lot.label_template)
let labelType = null;
if (eventType === 'Inoculated' && itemCategory === 'grain') {
  labelType = 'Grain_Inoculated';
} else if (eventType === 'LCInoculate' || eventType === 'InoculateFlask') {
  labelType = 'LC_Flask_Inoculated';
} else if (eventType === 'Spawned' || eventType === 'SpawnedToBulk') {
  labelType = 'Bulk_Created';
}
if (!labelType) return;

// 1) Set lots.label_template to match
try {
  const labelField = lotsTbl.getField('label_template');
  const choice = (labelField.options?.choices || []).find(c => c.name === labelType);
  if (!choice) {
    const have = (labelField.options?.choices || []).map(c => c.name).join(', ');
    throw new Error(`lots.label_template missing option "${labelType}". Has: ${have}`);
  }
  await lotsTbl.updateRecordAsync(lotId, { label_template: { id: choice.id } });
} catch (e) {
  // Fail loudly so you notice misconfigured options
  throw e;
}

// 2) De-dupe queued print rows
const dup = await findQueuedDuplicateByLot(lotId, labelType);
if (dup) return;

// 3) Create print_queue row
const choiceLabelType  = getSelectChoiceOrThrow(printQueueTbl, 'label_type',  labelType);
const choiceSourceKind = getSelectChoiceOrThrow(printQueueTbl, 'source_kind', 'lot');
const choiceQueued     = getSelectChoiceOrThrow(printQueueTbl, 'print_status','Queued');

await printQueueTbl.createRecordAsync({
  label_type:   { id: choiceLabelType.id },
  source_kind:  { id: choiceSourceKind.id },
  print_status: { id: choiceQueued.id },
  lot_id:       [{ id: lotId }]
});

return;

