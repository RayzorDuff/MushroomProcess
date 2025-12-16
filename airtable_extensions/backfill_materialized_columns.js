const lotsTbl = base.getTable('lots');
const prodsTbl = base.getTable('products');

function hasField(tbl, name) { try { tbl.getField(name); return true; } catch { return false; } }

function asFirstText(v) {
  if (v == null) return '';
  if (typeof v === 'string') return v;
  if (typeof v === 'number') return String(v);
  if (Array.isArray(v)) {
    const first = v[0];
    if (first == null) return '';
    if (typeof first === 'string') return first;
    if (typeof first === 'number') return String(first);
    if (typeof first === 'object' && first.name) return first.name;
    return String(first);
  }
  if (typeof v === 'object' && v.name) return v.name;
  return String(v);
}

// Write a value to a field, respecting destination type.
// - singleLineText -> string
// - singleSelect   -> {name: string}
// - anything else  -> string (safe default)
function coerceForField(tbl, fieldName, valueStr) {
  if (!valueStr) return null;
  const f = tbl.getField(fieldName);
  const t = f.type;

  if (t === 'singleSelect') return { name: valueStr };
  // singleLineText, multilineText, etc:
  return valueStr;
}

async function backfillLots() {
  const srcFields = ['item_name', 'item_category', 'process_type (from steri_run_id)'];
  const dstFields = ['item_name_mat', 'item_category_mat', 'process_type_mat'];

  const fields = [...srcFields, ...dstFields].filter(f => hasField(lotsTbl, f));
  const q = await lotsTbl.selectRecordsAsync({ fields });

  const updates = [];
  for (const r of q.records) {
    const patch = {};

    if (hasField(lotsTbl, 'item_name_mat') && !asFirstText(r.getCellValue('item_name_mat'))) {
      const v = asFirstText(r.getCellValue('item_name'));
      const coerced = coerceForField(lotsTbl, 'item_name_mat', v);
      if (coerced != null) patch['item_name_mat'] = coerced;
    }

    if (hasField(lotsTbl, 'item_category_mat') && !asFirstText(r.getCellValue('item_category_mat'))) {
      const v = asFirstText(r.getCellValue('item_category'));
      const coerced = coerceForField(lotsTbl, 'item_category_mat', v);
      if (coerced != null) patch['item_category_mat'] = coerced;
    }

    if (hasField(lotsTbl, 'process_type_mat') && !asFirstText(r.getCellValue('process_type_mat'))) {
      const v = asFirstText(r.getCellValue('process_type (from steri_run_id)'));
      const coerced = coerceForField(lotsTbl, 'process_type_mat', v);
      if (coerced != null) patch['process_type_mat'] = coerced;
    }

    if (Object.keys(patch).length) updates.push({ id: r.id, fields: patch });
  }

  for (let i = 0; i < updates.length; i += 50) {
    await lotsTbl.updateRecordsAsync(updates.slice(i, i + 50));
  }
  console.log(`Lots updated: ${updates.length}`);
}

async function backfillProducts() {
  const srcFields = ['name', 'item_category'];
  const dstFields = ['name_mat', 'item_category_mat'];

  const fields = [...srcFields, ...dstFields].filter(f => hasField(prodsTbl, f));
  const q = await prodsTbl.selectRecordsAsync({ fields });

  const updates = [];
  for (const r of q.records) {
    const patch = {};

    if (hasField(prodsTbl, 'name_mat') && !asFirstText(r.getCellValue('name_mat'))) {
      const v = asFirstText(r.getCellValue('name'));
      const coerced = coerceForField(prodsTbl, 'name_mat', v);
      if (coerced != null) patch['name_mat'] = coerced;
    }

    if (hasField(prodsTbl, 'item_category_mat') && !asFirstText(r.getCellValue('item_category_mat'))) {
      const v = asFirstText(r.getCellValue('item_category'));
      const coerced = coerceForField(prodsTbl, 'item_category_mat', v);
      if (coerced != null) patch['item_category_mat'] = coerced;
    }

    if (Object.keys(patch).length) updates.push({ id: r.id, fields: patch });
  }

  for (let i = 0; i < updates.length; i += 50) {
    await prodsTbl.updateRecordsAsync(updates.slice(i, i + 50));
  }
  console.log(`Products updated: ${updates.length}`);
}

await backfillLots();
await backfillProducts();
console.log('Done.');
