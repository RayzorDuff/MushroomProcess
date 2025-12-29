/**
 * Script: freezedry_package_actions.js
 * Version: 2025-12-28.2
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
 * Summary: Freeze Dry & Package – Actions
 * Notes: Succinct header; no diff blocks; try/catch + error surfacing.
 */
 
try {

  const { productId } = input.config();
  
  const productsTbl = base.getTable('products');
  const eventsTbl   = base.getTable('events');
  const itemsTbl = base.getTable('items');
  const locationsTbl = base.getTable('locations');
  const lotsTbl = base.getTable('lots');
  let strainsTbl = null;
  try { strainsTbl = base.getTable('strains'); } catch { /* optional */ }
    
  const src = await productsTbl.selectRecordAsync(productId);
  if (!src) throw new Error('Source product not found');

  const storageFieldName = (() => {
    try { productsTbl.getField('storage_location'); return 'storage_location'; } catch {}
    throw new Error('Could not find products.storage_location.');
  })();

  const traystateFieldName = (() => {
    try { productsTbl.getField('tray_state'); return 'tray_state'; } catch {}
    throw new Error('Could not find products.tray_state.');
  })();
    
  // Read inputs
  const packageItem        = src.getCellValue('package_item')?.[0] || null;
  const packageItemCategory= (src.getCellValueAsString('package_item_category') || '').toLowerCase(); // lookup from items.category
  const trayState          = (src.getCellValueAsString(traystateFieldName) || '').toLowerCase();
  const sizeG              = Number(src.getCellValue('package_size_g') ?? NaN);
  const count              = Number(src.getCellValue('package_count') ?? NaN);
  const useBy              = src.getCellValue('use_by');
  // storage_location is a link to locations (prefers single), so Airtable returns an array of linked records
  const loc                = (src.getCellValue(storageFieldName) || [])[0] || null;
  // Validate
  const errs = [];
  if (trayState !== 'freezer_tray') errs.push(`Packaging requires ${traystateFieldName} = freezer_tray.`);
  if (!packageItem) errs.push('Select package_item (retail SKU).');
  if (packageItemCategory !== 'freezedriedmushrooms') errs.push('package_item must have category "freezedriedmushrooms".');
  if (!Number.isFinite(sizeG) || sizeG <= 0) errs.push('Set package_size_g to a positive number.');
  if (!Number.isFinite(count) || count < 1) errs.push('Set package_count to 1 or more.');
  
  function hasField(tbl, name) { try { tbl.getField(name); return true; } catch { return false; } }

  async function buildStrainIdMap() {
    const map = new Map();
    if (!strainsTbl) return map;
    try {
      const q = await strainsTbl.selectRecordsAsync({ fields: ['strain_id'] });
      for (const r of q.records) {
        const sid = (r.getCellValueAsString('strain_id') || '').trim();
        if (sid) map.set(sid.toLowerCase(), r.id);
      }
    } catch {}
    return map;
  }

  function uniqLinks(links) {
    const out = [];
    const seen = new Set();
    for (const l of (links || [])) {
      const id = l?.id;
      if (id && !seen.has(id)) { seen.add(id); out.push({ id }); }
    }
    return out;
  }

  function resolveStrainLinksFromLot(lotRec, strainIdMap) {
    try {
      const v = lotRec.getCellValue('strain_id');
      if (Array.isArray(v) && v.length) {
        if (v[0] && typeof v[0] === 'object' && v[0].id) return uniqLinks(v);
        const mapped = v
          .map(x => (typeof x === 'string' ? x.trim() : (x?.name || '').trim()))
          .filter(Boolean)
          .map(s => strainIdMap.get(s.toLowerCase()))
          .filter(Boolean)
          .map(id => ({ id }));
        if (mapped.length) return uniqLinks(mapped);
      }
    } catch {}
    const s = (lotRec.getCellValueAsString('strain_id') || '').trim();
    if (s) {
      const id = strainIdMap.get(s.toLowerCase());
      if (id) return [{ id }];
    }
    return [];
  }

  async function resolveStrainLinksFromOriginLotIds(originLotIds, strainIdMap) {
    for (const lotId of (originLotIds || [])) {
      try {
        const lotRec = await lotsTbl.selectRecordAsync(lotId);
        if (!lotRec) continue;
        const links = resolveStrainLinksFromLot(lotRec, strainIdMap);
        if (links.length) return links;
      } catch {}
    }
    return [];
  }

  function coerceValueForField(table, fieldName, valueStr) {
    if (!valueStr) return null;
    const f = table.getField(fieldName);
    if (f.type === 'singleSelect') return { name: valueStr };
    return valueStr; // singleLineText, etc.
  }

  function getSingleSelectChoiceId(table, fieldName, choiceName) {
    const f = table.getField(fieldName);
    if (f.type !== 'singleSelect') {
      throw new Error(`${table.name}.${fieldName} is not a singleSelect field.`);
    }
    const choice = (f.options?.choices || []).find(c => c.name === choiceName);
    if (!choice) {
      throw new Error(`${table.name}.${fieldName} missing singleSelect choice "${choiceName}".`);
    }
    return choice.id;
  }

  // Look up locations by name (locations.primaryField is "name")
  const locationsQuery = await locationsTbl.selectRecordsAsync();
  const locationIdByName = new Map(
    locationsQuery.records.map(r => [
      (r.getCellValueAsString('name') || '').trim().toLowerCase(),
      r.id
    ])
  );
  function requireLocationIdByName(name) {
    const id = locationIdByName.get(String(name).trim().toLowerCase());
    if (!id) throw new Error(`locations record not found with name "${name}".`);
    return id;
  }
  const consumedLocationRecId = requireLocationIdByName('Consumed');
  const defaultProductsStorageRecId = requireLocationIdByName('Products Storage');
  
  // ----- NEW: multi-tray support via products.merge_tray_products -----
  const extraTrayRecords = [];
  let extraTrayLinks = [];
  
  if (hasField(productsTbl, 'merge_tray_products')) {
    extraTrayLinks = src.getCellValue('merge_tray_products') || [];
  }
  
  // Load each additional tray and validate its tray_state
  for (const ref of extraTrayLinks) {
    const rec = await productsTbl.selectRecordAsync(ref.id);
    if (!rec) {
      errs.push(`Additional tray ${ref.id} could not be loaded.`);
      continue;
    }
    extraTrayRecords.push(rec);
    const s = (rec.getCellValueAsString(traystateFieldName) || '').toLowerCase();
    if (s !== 'freezer_tray') {
      errs.push(`Additional tray ${rec.name || rec.id} must have ${traystateFieldName} = freezer_tray.`);
    }
  }
  
  if (errs.length) {
    await productsTbl.updateRecordAsync(src.id, {
      ui_error: errs.join(' '),
      ui_error_at: new Date().toISOString(),
      action: null
    });
    throw new Error('PackageFreezeDried validation failed.');
  }
  
  // Clear previous errors
  await productsTbl.updateRecordAsync(src.id, { ui_error: null, ui_error_at: null });
  
  // Compute use_by (2 years default)
  function addYearsDate(d, years) { const x = new Date(d); x.setFullYear(x.getFullYear() + years); return x; }
  const now = new Date();
  const nowIso = now.toISOString();
  // Airtable date fields accept Date objects; keep existing value if present
  const finalUseBy = useBy || addYearsDate(now, 2);
  
  // Gather origins from the primary tray plus any additional trays
  let origins = [];
  
  function addOriginsFromProduct(prod) {
    if (!prod) return;
  
    const links = prod.getCellValue('origin_lots') || [];
    if (links.length) {
      for (const o of links) {
        if (o && o.id && !origins.includes(o.id)) origins.push(o.id);
      }
    } else {
      try {
        const j = JSON.parse(prod.getCellValueAsString('origin_lot_ids_json') || '[]');
        if (Array.isArray(j)) {
          for (const id of j) {
            if (id && !origins.includes(id)) origins.push(id);
          }
        }
      } catch {}
    }
  }
  
  // Always include the current tray record
  addOriginsFromProduct(src);
  
  // Optionally merge in any additional trays linked via merge_tray_products
  for (const rec of extraTrayRecords) {
    addOriginsFromProduct(rec);
  }
  
  const itemRec = await itemsTbl.selectRecordAsync(packageItem.id);
  if (!itemRec) throw new Error(`package_item record not found: ${packageItem.id}`);

  // Strain: set products.strain_id directly during migration away from lookup
  const strainIdMap = hasField(productsTbl, 'strain_id') ? await buildStrainIdMap() : new Map();
  const strainLinksForPackage = hasField(productsTbl, 'strain_id') ? await resolveStrainLinksFromOriginLotIds(origins, strainIdMap) : [];
     
  // Create finished packaged products
  const batch = [];
  for (let i = 0; i < count; i++) {
    const f = {
      item_id: [{ id: packageItem.id }],
      origin_lot_ids_json: JSON.stringify(origins),
      origin_lots: origins.map(id => ({ id })),
      net_weight_g: sizeG,
      pack_date: nowIso,
      use_by: finalUseBy
    };
    if (hasField(productsTbl, 'strain_id') && strainLinksForPackage.length) f.strain_id = strainLinksForPackage;
    // storage_location is a linked record to locations. Default to "Products Storage" if not set on source tray.
    const packagedLocationId = (loc && loc.id) ? loc.id : defaultProductsStorageRecId;
    f[storageFieldName] = [{ id: packagedLocationId }];

  
    if (hasField(productsTbl, 'name_mat')) {
      const v = coerceValueForField(productsTbl, 'name_mat', itemRec.getCellValueAsString('name') || '');
      if (v != null) f.name_mat = v;
    }
    if (hasField(productsTbl, 'item_category_mat')) {
      const v = coerceValueForField(productsTbl, 'item_category_mat', itemRec.getCellValueAsString('category') || '');
      if (v != null) f.item_category_mat = v;
    }
  
    batch.push({ fields: f });
  }
  for (let i = 0; i < batch.length; i += 50) {
    await productsTbl.createRecordsAsync(batch.slice(i, i + 50));
  }
  
  // Log Package on origin lots (audit)
  const evtTypeField = eventsTbl.getField('type');
  const packageEvt = (evtTypeField.options?.choices || []).find(c => c.name === 'Package');
  if (packageEvt && origins.length) {
    const tsWritable = (() => { try { return eventsTbl.getField('timestamp').type === 'dateTime'; } catch { return false; }})();
    for (let i = 0; i < origins.length; i += 50) {
      const eBatch = origins.slice(i, i + 50).map(lotId => {
        const f = {
          lot_id: [{ id: lotId }],
          type: { id: packageEvt.id },
          station: 'Packaging Freeze-Dried',
          fields_json: JSON.stringify({
            from_product_id: src.id,
            package_item_id: packageItem.id,
            package_size_g: sizeG,
            package_count: count
          })
        };
        if (tsWritable) f.timestamp = nowIso;
        return { fields: f };
      });
      await eventsTbl.createRecordsAsync(eBatch);
    }
  }
  
  // ✅ Mark the tray product(s) as empty and set storage_location = "Consumed" (locations link)
  // tray_state IS a single select (choices include empty_tray)
  const trayStateField = productsTbl.getField(traystateFieldName);
  const emptyChoice = (trayStateField.options?.choices || []).find(c => c.name === 'empty_tray');
  if (!emptyChoice) throw new Error(`products.${traystateFieldName} missing singleSelect choice "empty_tray".`);
  
  const trayUpdates = [];
  
  // Primary tray
  trayUpdates.push({
    id: src.id,
    fields: {
      [traystateFieldName]: { id: emptyChoice.id },
      [storageFieldName]: [{ id: consumedLocationRecId }],
      action: null
    }
  });
  
  // Any additional trays used via merge_tray_products
  for (const rec of extraTrayRecords) {
    trayUpdates.push({
      id: rec.id,
      fields: {
        [traystateFieldName]: { id: emptyChoice.id },
        [storageFieldName]: [{ id: consumedLocationRecId }],
        action: null
      }
    });
  }
  
  // Batch update to respect Airtable’s 50-record limit
  for (let i = 0; i < trayUpdates.length; i += 50) {
    await productsTbl.updateRecordsAsync(trayUpdates.slice(i, i + 50));
  }

} catch (e) {
  if (typeof output !== 'undefined' && output && output.set) {
    output.set('error', (e && e.message) ? e.message : String(e));
  }
}
