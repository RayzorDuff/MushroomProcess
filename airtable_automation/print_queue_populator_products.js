/**
 * Script: print_queue_populator_products.js
 * Version: 2025-12-15.2
 * =============================================================================
 *  Copyright © 2025 Dank Mushrooms, LLC
 *  Licensed under the GNU General Public License v3 (GPL-3.0-only)
 *
 *  This program is free software: you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation, either version 3 of the License.
 *
 *  This program is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 *  GNU General Public License for more details.
 *
 *  You should have received a copy of the GNU General Public License
 *  along with this program. If not, see <https://www.gnu.org/licenses/>.
 * =============================================================================
 * Summary: Product label queueing – enqueue package labels per product, dedup by product + label type.
 * Notes: Succinct header; no diff blocks; try/catch + error surfacing.
 */
try {

  const { productId } = input.config();
  
  const itemsTbl      = base.getTable('items');
  const productsTbl   = base.getTable('products');
  const printQueueTbl = base.getTable('print_queue');
  
  function hasField(tbl, name) { try { tbl.getField(name); return true; } catch { return false; } }
  function coerceValueForField(table, fieldName, valueStr) {
    if (!valueStr) return null;
    const f = table.getField(fieldName);
    if (f.type === 'singleSelect') return { name: valueStr };
    return valueStr; // singleLineText, etc.
  }
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
  
  let itemCategory = '';
  try {
  
    // Prefer materialized category if present
    itemCategory = (prod?.getCellValueAsString('item_category_mat') || '').toLowerCase();
  
    if (!itemCategory) {
      // fallback to old behavior
      const prodItem = prod?.getCellValue('item_id')?.[0] || null;
      if (prodItem) {
        const itemRec = await itemsTbl.selectRecordAsync(prodItem.id);
        itemCategory = (itemRec?.getCellValueAsString('category') || '').toLowerCase();
      }
    }
  } catch {}
    
  console.log('Product item category : ', itemCategory);
  //const isPack = (itemCategory === 'freezedriedmushrooms' || itemCategory === 'fresh_mushrooms');
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

} catch (e) {
  if (typeof output !== 'undefined' && output && output.set) {
    output.set('error', (e && e.message) ? e.message : String(e));
  }
}
