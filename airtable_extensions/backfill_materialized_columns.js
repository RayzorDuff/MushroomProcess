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
  const srcFields = ['item_name', 'item_category', 'process_type (from steri_run_id)', 'vendor_name', 'strain_species_strain', 'source_lot_id'];
  const dstFields = ['item_name_mat', 'item_category_mat', 'process_type_mat', 'vendor_name_mat', 'strain_species_strain_mat'];

  const fields = [...srcFields, ...dstFields].filter(f => hasField(lotsTbl, f));
  let q = await lotsTbl.selectRecordsAsync({ fields });

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

    

    // vendor_name_mat:
    // - prefer lots.vendor_name (lookup from lc_lot_id) when present
    // - else inherit vendor_name_mat from source_lot_id (if present)
    if (hasField(lotsTbl, 'vendor_name_mat') && !asFirstText(r.getCellValue('vendor_name_mat'))) {
      const vLookup = hasField(lotsTbl, 'vendor_name') ? asFirstText(r.getCellValue('vendor_name')) : '';
      const coercedLookup = coerceForField(lotsTbl, 'vendor_name_mat', vLookup);
      if (coercedLookup != null) {
        patch['vendor_name_mat'] = coercedLookup;
      }
    }

    // strain_species_strain_mat:
    // - prefer lots.strain_species_strain (lookup via target_lot_ids/self-link) when present
    // - else inherit strain_species_strain_mat from source_lot_id (handled in a later pass)
    if (hasField(lotsTbl, 'strain_species_strain_mat') && !asFirstText(r.getCellValue('strain_species_strain_mat'))) {
      const vLookup = hasField(lotsTbl, 'strain_species_strain') ? asFirstText(r.getCellValue('strain_species_strain')) : '';
      const coercedLookup = coerceForField(lotsTbl, 'strain_species_strain_mat', vLookup);
      if (coercedLookup != null) {
        patch['strain_species_strain_mat'] = coercedLookup;
      }
    }

    if (Object.keys(patch).length) updates.push({ id: r.id, fields: patch });
  }

  for (let i = 0; i < updates.length; i += 50) {
    await lotsTbl.updateRecordsAsync(updates.slice(i, i + 50));
  }
  console.log(`Lots updated (direct mats + vendor lookup): ${updates.length}`);

  // Second pass: propagate vendor_name_mat via source_lot_id chains.
  // We do a few iterations so multi-hop chains can resolve (vendor lot -> LC -> grain -> block, etc).
  if (hasField(lotsTbl, 'vendor_name_mat') && hasField(lotsTbl, 'source_lot_id')) {
    const idToRecord = new Map(q.records.map(r => [r.id, r]));
    let totalInherited = 0;

    for (let pass = 0; pass < 6; pass++) {
      const inheritUpdates = [];
      for (const r of q.records) {
        const cur = asFirstText(r.getCellValue('vendor_name_mat'));
        if (cur) continue;

        const srcLink = r.getCellValue('source_lot_id');
        const srcId = Array.isArray(srcLink) && srcLink[0] ? srcLink[0].id : null;
        if (!srcId) continue;

        const srcRec = idToRecord.get(srcId);
        if (!srcRec) continue;

        const srcVal = asFirstText(srcRec.getCellValue('vendor_name_mat'));
        if (!srcVal) continue;

        const coerced = coerceForField(lotsTbl, 'vendor_name_mat', srcVal);
        if (coerced != null) {
          inheritUpdates.push({ id: r.id, fields: { vendor_name_mat: coerced } });
        }
      }

      if (!inheritUpdates.length) break;

      for (let i = 0; i < inheritUpdates.length; i += 50) {
        await lotsTbl.updateRecordsAsync(inheritUpdates.slice(i, i + 50));
      }

      totalInherited += inheritUpdates.length;

      // Refresh local records cache so multi-hop chains can resolve in subsequent passes.
      q = await lotsTbl.selectRecordsAsync({ fields });
      idToRecord.clear();
      for (const rr of q.records) idToRecord.set(rr.id, rr);
    }

    console.log(`Lots vendor_name_mat inherited via source_lot_id: ${totalInherited}`);
  }


  // Third pass: propagate strain_species_strain_mat via source_lot_id chains.
  // Multi-pass resolves long inoculation chains (vendor syringe -> LC -> grain -> block, etc).
  if (hasField(lotsTbl, 'strain_species_strain_mat') && hasField(lotsTbl, 'source_lot_id')) {
    const idToRecord = new Map(q.records.map(r => [r.id, r]));
    let totalInherited = 0;

    for (let pass = 0; pass < 6; pass++) {
      const inheritUpdates = [];
      for (const r of q.records) {
        const cur = asFirstText(r.getCellValue('strain_species_strain_mat'));
        if (cur) continue;

        const srcLink = r.getCellValue('source_lot_id');
        const srcId = Array.isArray(srcLink) && srcLink[0] ? srcLink[0].id : null;
        if (!srcId) continue;

        const srcRec = idToRecord.get(srcId);
        if (!srcRec) continue;

        const srcVal = asFirstText(srcRec.getCellValue('strain_species_strain_mat'));
        if (!srcVal) continue;

        const coerced = coerceForField(lotsTbl, 'strain_species_strain_mat', srcVal);
        if (coerced != null) {
          inheritUpdates.push({ id: r.id, fields: { strain_species_strain_mat: coerced } });
        }
      }

      if (!inheritUpdates.length) break;

      for (let i = 0; i < inheritUpdates.length; i += 50) {
        await lotsTbl.updateRecordsAsync(inheritUpdates.slice(i, i + 50));
      }

      totalInherited += inheritUpdates.length;

      // Refresh local records cache so multi-hop chains can resolve in subsequent passes.
      q = await lotsTbl.selectRecordsAsync({ fields });
      idToRecord.clear();
      for (const rr of q.records) idToRecord.set(rr.id, rr);
    }

    console.log(`Lots strain_species_strain_mat inherited via source_lot_id: ${totalInherited}`);
  }
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
