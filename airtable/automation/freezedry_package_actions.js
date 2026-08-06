/**
 * Script: freezedry_package_actions.js
 * Version: 2026-06-29.1
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
  const packageSizeChoice  = hasField(productsTbl, 'package_size') ? (src.getCellValueAsString('package_size') || '').trim() : '';
  const count              = Number(src.getCellValue('package_count') ?? NaN);
  const useBy              = src.getCellValue('use_by');

  // Optional sample/package classification fields.  Airtable may use either a
  // single select products.package_class = Retail/Sample or a checkbox
  // products.is_sample.  Support both so the automation remains compatible
  // during schema migration.
  const packageClass = hasField(productsTbl, 'package_class')
    ? (src.getCellValueAsString('package_class') || 'Retail').trim()
    : (hasField(productsTbl, 'is_sample') && src.getCellValue('is_sample') ? 'Sample' : 'Retail');
  const isSample = packageClass.toLowerCase() === 'sample'
    || (hasField(productsTbl, 'is_sample') && !!src.getCellValue('is_sample'));

  // storage_location is a link to locations (prefers single), so Airtable returns an array of linked records
  const loc                = (src.getCellValue(storageFieldName) || [])[0] || null;
  // Validate
  const errs = [];
  if (trayState !== 'freezer_tray') errs.push(`Packaging requires ${traystateFieldName} = freezer_tray.`);
  if (!packageItem) errs.push('Select package_item (retail SKU).');
  const freezeDriedCategories = new Set(['freezedriedmushrooms', 'freeze_dried_mushrooms', 'freeze_dried_capsules']);
  if (!freezeDriedCategories.has(packageItemCategory)) {
    errs.push('package_item must be a freeze-dried retail item.');
  }
  if (!Number.isFinite(sizeG) || sizeG <= 0) errs.push('Select a package size.');
  if (!Number.isFinite(count) || count < 1) errs.push('Set package_count to 1 or more.');
  
  function hasField(tbl, name) { try { tbl.getField(name); return true; } catch { return false; } }
  function isWritableField(tbl, name) {
    try {
      const t = tbl.getField(name).type;
      return !['formula', 'rollup', 'multipleLookupValues', 'createdTime', 'lastModifiedTime', 'autoNumber', 'button', 'count'].includes(t);
    } catch {
      return false;
    }
  }

  function uniqIds(values) {
    const out = [];
    const seen = new Set();
    for (const v of (values || [])) {
      const id = String(v || '').trim();
      if (id && !seen.has(id)) {
        seen.add(id);
        out.push(id);
      }
    }
    return out;
  }

  async function buildLotIdResolver() {
    const validRecordIds = new Set();
    const recordIdByDisplayLotId = new Map();
    const displayLotIdByRecordId = new Map();

    const q = hasField(lotsTbl, 'lot_id')
      ? await lotsTbl.selectRecordsAsync({ fields: ['lot_id'] })
      : await lotsTbl.selectRecordsAsync();

    for (const r of q.records) {
      validRecordIds.add(r.id);
      const displayLotId = hasField(lotsTbl, 'lot_id')
        ? (r.getCellValueAsString('lot_id') || '').trim()
        : '';
      if (displayLotId) {
        recordIdByDisplayLotId.set(displayLotId, r.id);
        displayLotIdByRecordId.set(r.id, displayLotId);
      } else {
        displayLotIdByRecordId.set(r.id, r.id);
      }
    }

    return {
      resolve(rawValue) {
        const raw = String(rawValue || '').trim();
        if (!raw) return null;
        if (validRecordIds.has(raw)) return raw;
        return recordIdByDisplayLotId.get(raw) || null;
      },
      displayFor(recordId) {
        return displayLotIdByRecordId.get(recordId) || recordId;
      }
    };
  }

  function productLabel(prod) {
    if (!prod) return '(unknown product)';
    return prod.name || prod.id;
  }

  function parseJsonArrayCell(record, fieldName) {
    try {
      const raw = record.getCellValueAsString(fieldName) || '';
      if (!raw) return [];
      const parsed = JSON.parse(raw);
      return Array.isArray(parsed) ? parsed : [];
    } catch {
      return [];
    }
  }

  function getNetWeightG(prod) {
    const n = Number(prod?.getCellValue('net_weight_g') ?? NaN);
    return Number.isFinite(n) ? n : 0;
  }

  function formatG(n) {
    return Math.round(Number(n) * 100) / 100;
  }

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
  
  // Preflight weight so Airtable does not partially package more grams than the selected tray(s) contain.
  const sourceWeightG = [src, ...extraTrayRecords].reduce((sum, prod) => sum + getNetWeightG(prod), 0);
  const requiredWeightG = sizeG * count;
  if (
    Number.isFinite(requiredWeightG) &&
    requiredWeightG > 0 &&
    sourceWeightG > 0 &&
    requiredWeightG - sourceWeightG > 0.01
  ) {
    errs.push(`Package count/size requires ${formatG(requiredWeightG)} g but selected source tray weight is ${formatG(sourceWeightG)} g.`);
  }

  if (errs.length) {
    await productsTbl.updateRecordAsync(src.id, {
      ui_error: errs.join(' '),
      ui_error_at: new Date().toISOString(),
      action: null
    });
    throw new Error('PackageFreezeDried validation failed.');
  }
  
  // Do not clear errors or mutate the source tray until all preflight validation passes.
  
  // Compute use_by (2 years default)
  function addYearsDate(d, years) { const x = new Date(d); x.setFullYear(x.getFullYear() + years); return x; }
  const now = new Date();
  const nowIso = now.toISOString();
  // Airtable date fields accept Date objects; keep existing value if present
  const finalUseBy = useBy || addYearsDate(now, 2);
  
  // Gather origin lot Airtable record IDs from the primary tray plus any additional trays.
  // origin_lot_ids_json may contain display IDs such as LOT-260..., so resolve those
  // to actual Airtable lots record IDs before writing the products.origin_lots link field.
  const lotIdResolver = await buildLotIdResolver();
  let origins = [];
  let originLotIdsForJson = [];

  function addOriginRecordId(rawValue, context) {
    const raw = String(rawValue || '').trim();
    if (!raw) return;
    const resolved = lotIdResolver.resolve(raw);
    if (!resolved) {
      errs.push(`Could not resolve origin lot "${raw}" from ${context}.`);
      return;
    }
    if (!origins.includes(resolved)) {
      origins.push(resolved);
      originLotIdsForJson.push(lotIdResolver.displayFor(resolved));
    }
  }

  function addOriginsFromProduct(prod) {
    if (!prod) return;

    const context = productLabel(prod);
    const links = prod.getCellValue('origin_lots') || [];
    if (links.length) {
      for (const o of links) addOriginRecordId(o?.id, `origin_lots on ${context}`);
      return;
    }

    for (const id of parseJsonArrayCell(prod, 'origin_lot_ids_json')) {
      addOriginRecordId(id, `origin_lot_ids_json on ${context}`);
    }
  }

  // Always include the current tray record
  addOriginsFromProduct(src);

  // Optionally merge in any additional trays linked via merge_tray_products
  for (const rec of extraTrayRecords) {
    addOriginsFromProduct(rec);
  }

  origins = uniqIds(origins);
  originLotIdsForJson = uniqIds(originLotIdsForJson);
  if (!origins.length) {
    errs.push('No valid origin lots found on selected freezer tray product(s).');
  }

  const itemRec = await itemsTbl.selectRecordAsync(packageItem.id);
  if (!itemRec) throw new Error(`package_item record not found: ${packageItem.id}`);

  const packageItemCode = (itemRec.getCellValueAsString('item_id') || '').trim().toUpperCase();
  const packageItemName = (itemRec.getCellValueAsString('name') || '').trim().toLowerCase();
  const isCapsuleItem = packageItemCode.includes('CAPSULE') || packageItemName.includes('capsule');
  const isDriedMushroomItem = packageItemCode.includes('DRIED') || packageItemName.includes('mushroom');
  function approxEq(a, b) { return Math.abs(Number(a) - Number(b)) < 0.01; }
  if (isCapsuleItem && ![1, 5, 10].some(v => approxEq(sizeG, v))) {
    errs.push('Freeze-dried capsules must use package size 1 g, 5 g, or 10 g.');
  }
  if (!isCapsuleItem && isDriedMushroomItem && ![1, 5, 28.349523125].some(v => approxEq(sizeG, v))) {
    errs.push('Freeze-dried mushrooms must use package size 1 g, 5 g, or 1 oz.');
  }
  if (errs.length) {
    await productsTbl.updateRecordAsync(src.id, {
      ui_error: errs.join(' '),
      ui_error_at: new Date().toISOString(),
      action: null
    });
    throw new Error('PackageFreezeDried validation failed.');
  }

  // Clear previous errors only after all preflight validation passes.
  await productsTbl.updateRecordAsync(src.id, { ui_error: null, ui_error_at: null });

  // Strain: set products.strain_id directly during migration away from lookup
  const strainIdMap = hasField(productsTbl, 'strain_id') ? await buildStrainIdMap() : new Map();
  const strainLinksForPackage = hasField(productsTbl, 'strain_id') ? await resolveStrainLinksFromOriginLotIds(origins, strainIdMap) : [];
     
  // Create finished packaged products
  const batch = [];
  for (let i = 0; i < count; i++) {
    const f = {
      item_id: [{ id: packageItem.id }],
      origin_lot_ids_json: JSON.stringify(originLotIdsForJson),
      origin_lots: origins.map(id => ({ id })),
      net_weight_g: sizeG,
      pack_date: nowIso,
      use_by: finalUseBy
    };
    if (hasField(productsTbl, 'strain_id') && strainLinksForPackage.length) f.strain_id = strainLinksForPackage;
    // storage_location is a linked record to locations. Default to "Products Storage" if not set on source tray.
    const packagedLocationId = (loc && loc.id) ? loc.id : defaultProductsStorageRecId;
    f[storageFieldName] = [{ id: packagedLocationId }];

    if (packageSizeChoice && isWritableField(productsTbl, 'package_size')) f.package_size = coerceValueForField(productsTbl, 'package_size', packageSizeChoice);
    if (isWritableField(productsTbl, 'package_size_g')) f.package_size_g = sizeG;
    if (isWritableField(productsTbl, 'package_class')) f.package_class = coerceValueForField(productsTbl, 'package_class', isSample ? 'Sample' : 'Retail');
    if (isWritableField(productsTbl, 'is_sample')) f.is_sample = isSample;

  
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
            package_count: count,
            package_class: isSample ? 'Sample' : 'Retail',
            is_sample: isSample
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
