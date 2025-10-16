/***** Print Queue Populator (sets lots.label_template too) *****/
const { productId } = input.config();

const itemsTbl      = base.getTable('items');
const productsTbl   = base.getTable('products');
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
async function findQueuedDuplicateByProduct(productId, labelTypeName) {
  const q = await printQueueTbl.selectRecordsAsync({
    fields: ['print_status','source_kind','product_id','label_type'],
//    fields: ['test_print_status','source_kind','product_id','label_type'],
    sorts: [{field: 'created_at', direction: 'desc'}]
  });
  for (const r of q.records) {
    const status = toName(r.getCellValue('print_status'));
//    const status = toName(r.getCellValue('test_print_status'));

    const src    = r.getCellValueAsString('source_kind') || '';
    const lt     = toName(r.getCellValue('label_type'));
    const link   = r.getCellValue('product_id')?.[0]?.id || null;
    if (status === 'Queued' && src === 'product' && link === productId && lt === labelTypeName) return r;
  }
  return null;
}

  console.log('product');
if (!productId) throw new Error('Missing input: productId');

const prod = await productsTbl.selectRecordAsync(productId);
if (!prod) throw new Error('Product not found');

const cat = (prod.getCellValueAsString('item_category') || '').toLowerCase();
console.log('Product category : ', cat);
//const isPack = (cat === 'freezedriedmushrooms' || cat === 'fresh_mushrooms');
//if (!isPack) {console.log('found no freezedried');return;}

const labelType = 'Product_Package';

const dup = await findQueuedDuplicateByProduct(prod.id, labelType);
if (dup) {console.log('found Duplicate');return;}

const choiceLabelType  = getSelectChoiceOrThrow(printQueueTbl, 'label_type',  labelType);
const choiceSourceKind = getSelectChoiceOrThrow(printQueueTbl, 'source_kind', 'product');
const choiceQueued     = getSelectChoiceOrThrow(printQueueTbl, 'print_status','Queued');
//const choiceQueued     = getSelectChoiceOrThrow(printQueueTbl, 'test_print_status','Queued');

await printQueueTbl.createRecordAsync({
  label_type:   { id: choiceLabelType.id },
  source_kind:  { id: choiceSourceKind.id },
  print_status: { id: choiceQueued.id },
  //test_print_status: { id: choiceQueued.id },

  product_id:   [{ id: prod.id }]
});

return;
