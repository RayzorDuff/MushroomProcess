/**
 * Script: sterilizer_out_validate_create_lots.js
 * Version: 2026-06-23.3
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
 * Summary: Sterilizer OUT – Validate & Create Lots
 * Notes: Succinct header; no diff blocks; try/catch + error surfacing.
 */

const { runId } = input.config();

const runsTbl   = base.getTable('sterilization_runs');
const itemsTbl  = base.getTable('items');
const lotsTbl   = base.getTable('lots');
const eventsTbl = base.getTable('events');
let itemRecipeComponentsTbl = null;
let lotRecipeComponentsTbl = null;
try { itemRecipeComponentsTbl = base.getTable('item_recipe_components'); } catch (_) {}
try { lotRecipeComponentsTbl = base.getTable('lot_recipe_components'); } catch (_) {}

/* ---------- helpers ---------- */
function hasField(tbl, name){ try { tbl.getField(name); return true; } catch { return false; } }
function coerceValueForField(table, fieldName, valueStr) {
  if (!valueStr) return null;
  const f = table.getField(fieldName);
  if (f.type === 'singleSelect') return { name: valueStr };
  return valueStr; // singleLineText, etc.
}
function fieldType(tbl, name){ try { return tbl.getField(name).type; } catch { return null; } }
function isLinkField(tbl, name){ return fieldType(tbl, name) === 'multipleRecordLinks'; }
function num(v){ const n = Number(v); return Number.isFinite(n) ? n : null; }
function asStr(rec, f){ try { return rec.getCellValueAsString(f) || ''; } catch { return ''; } }
function normStr(v){ return String(v || '').trim(); }
function linkIds(rec, f){ try { return (rec.getCellValue(f) || []).map(x => x.id).filter(Boolean); } catch { return []; } }
function firstLinkId(rec, f){ return linkIds(rec, f)[0] || null; }
function checkboxTrue(rec, f){ try { const v = rec.getCellValue(f); return v === true || v === 1 || v === 'true'; } catch { return false; } }
function nearlyEqual(a, b){ return Math.abs(Number(a) - Number(b)) < 0.000001; }
async function createRecordsInBatches(tbl, records){
  if (!tbl || !records.length) return [];
  const ids = [];
  for (let i = 0; i < records.length; i += 50) {
    ids.push(...await tbl.createRecordsAsync(records.slice(i, i + 50)));
  }
  return ids;
}
function componentRoleForCategory(category){
  const c = String(category || '').toLowerCase();
  if (c === 'grain') return 'grain';
  if (c === 'substrate' || c === 'cordyceps_substrate' || c === 'all_in_one_bag') return 'substrate';
  if (c === 'agar_flask' || c === 'plate') return 'agar';
  if (c === 'lc_flask' || c === 'lc_syringe') return 'lc';
  if (c === 'casing') return 'casing';
  return 'primary';
}
/* Only return an {id} if option exists (no typecast in automations) */
function selectChoiceIdFor(table, fieldName, label) {
  if (!label) return null;
  const f = table.getField(fieldName);
  if (!f || f.type !== 'singleSelect') return null;
  const hit = (f.options?.choices || []).find(c => c.name === label);
  return hit ? { id: hit.id } : null;
}
async function safeUpdate(tbl, id, fields) {
  const out = {};
  for (const [k,v] of Object.entries(fields||{})) { if (v !== undefined && hasField(tbl,k)) out[k]=v; }
  if (Object.keys(out).length) await tbl.updateRecordAsync(id, out);
}
function notify(msg){
  try { if (typeof output?.set === 'function') output.set('result', msg); } catch(_){}
  try { console.log(msg); } catch(_){}
}

/* ---------- load run ---------- */
const run = await runsTbl.selectRecordAsync(runId);
if (!run) throw new Error('Sterilization run not found');

const plannedItem    = run.getCellValue('planned_item')?.[0] || null;   // link → items
const plannedRecipe  = run.getCellValue('planned_recipe')?.[0] || null; // link → recipes (optional)
const unitSize       = num(run.getCellValue('planned_unit_size'));
const plannedCount   = num(run.getCellValue('planned_count'));
const goodCount      = num(run.getCellValue('good_count'));
const destroyedCount = num(run.getCellValue('destroyed_count'));

const operatorName   = asStr(run, 'operator');     // for Events (text)
const operatorSS     = selectChoiceIdFor(lotsTbl, 'operator', operatorName); // for Lots (single-select)

const runNo          = asStr(run, 'steri_run_id'); // display/reference
const plannedComponentSet = hasField(runsTbl, 'planned_component_set')
  ? normStr(asStr(run, 'planned_component_set'))
  : ''; // used for multi_recipe items such as AIO-BAG

/* --- normalize timestamps --- */
let startRaw = run.getCellValue('start_time');
if (startRaw && typeof startRaw === 'string') startRaw = new Date(startRaw);
if (startRaw && !(startRaw instanceof Date)) startRaw = null;

let overrideEnd = run.getCellValue('override_end_time');
if (overrideEnd && typeof overrideEnd === 'string') overrideEnd = new Date(overrideEnd);
if (overrideEnd && !(overrideEnd instanceof Date)) overrideEnd = null;

const nowDate = new Date();
const tsDate  = overrideEnd || nowDate;
const tsIso   = tsDate.toISOString();

/* ---------- validation ---------- */
const errs = [];
if (!plannedItem) errs.push('planned_item is required.');
if (!unitSize || unitSize <= 0) errs.push('planned_unit_size must be > 0.');
if (!Number.isFinite(plannedCount)) errs.push('planned_count must be set.');
if (!Number.isFinite(goodCount)) errs.push('good_count is required.');
if (!Number.isFinite(destroyedCount)) errs.push('destroyed_count is required.');
if ((goodCount + destroyedCount) !== plannedCount) errs.push('good_count + destroyed_count must equal planned_count.');
if (!startRaw) errs.push('start_time must be set on the run.');
else if (tsDate.getTime() < startRaw.getTime()) errs.push('Sterilized at time cannot be before start_time.');
if (tsDate.getTime() > nowDate.getTime()) errs.push('Sterilized at time cannot be in the future.');
if (errs.length) {
  await safeUpdate(runsTbl, run.id, {
    ui_error: errs.join(' '),
    ui_error_at: new Date().toISOString(),
    action: null
  });
  throw new Error('Sterilizer OUT validation failed.');
}

/* ---------- resolve process type (pasteurize vs sterilize) ---------- */
const itemRec = await itemsTbl.selectRecordAsync(plannedItem.id);
const itemCategory = (itemRec?.getCellValueAsString('category') || '').toLowerCase();
const itemComponentMode = normStr(itemRec?.getCellValueAsString('component_mode')).toLowerCase();
const processTypeRaw = asStr(run, 'process_type').toLowerCase();
const targetTempC    = num(run.getCellValue('target_temp_c'));
const pressureMode   = asStr(run, 'pressure_mode').toLowerCase();
function resolveProcess() {
  if (processTypeRaw === 'pasteurize' || processTypeRaw === 'sterilize') return processTypeRaw;
  if (Number.isFinite(targetTempC) && targetTempC <= 100) return 'pasteurize';
  if (pressureMode === 'open') return 'pasteurize';
  if (Number.isFinite(targetTempC) && targetTempC >= 110) return 'sterilize';
  if (itemCategory === 'casing') return 'pasteurize';
  return 'sterilize';
}
const proc = resolveProcess();

/* ---------- status & event choices ---------- */
const lotStatusField     = lotsTbl.getField('status');
const statusPasteurized  = (lotStatusField.options?.choices || []).find(c => c.name === 'Pasteurized');
const statusSterilized   = (lotStatusField.options?.choices || []).find(c => c.name === 'Sterilized');

const evtTypeField       = eventsTbl.getField('type');
const evtPasteurized     = (evtTypeField.options?.choices || []).find(c => c.name === 'Pasteurized');
const evtSterilized      = (evtTypeField.options?.choices || []).find(c => c.name === 'Sterilized');
const evtDestroyed       = (evtTypeField.options?.choices || []).find(c => c.name === 'Destroyed');

const linkRunOnLot = isLinkField(lotsTbl, 'steri_run_id'); // link field in your schema

if (itemComponentMode === 'single_recipe' && !plannedRecipe) {
  await safeUpdate(runsTbl, run.id, {
    ui_error: 'planned_recipe is required for single_recipe items such as Spawn Bag, substrate bags, LC flasks, agar flasks, and plates.',
    ui_error_at: new Date().toISOString(),
    action: null
  });
  throw new Error('Sterilizer OUT validation failed. planned_recipe is required for single_recipe item.');
}

async function getPlannedItemComponents(options = {}) {
  const { applyComponentSet = false } = options;
  if (!itemRecipeComponentsTbl || !plannedItem) return [];
  const fields = ['active', 'item_id', 'recipe_id', 'component_role', 'component_set', 'unit_size_lb', 'default_weight_lb', 'default_percent', 'sort_order'];
  const availableFields = fields.filter(f => hasField(itemRecipeComponentsTbl, f));
  const q = await itemRecipeComponentsTbl.selectRecordsAsync({ fields: availableFields });
  return q.records
    .filter(r => !hasField(itemRecipeComponentsTbl, 'active') || checkboxTrue(r, 'active'))
    .filter(r => linkIds(r, 'item_id').includes(plannedItem.id))
    .filter(r => {
      const componentUnitSize = hasField(itemRecipeComponentsTbl, 'unit_size_lb') ? num(r.getCellValue('unit_size_lb')) : null;
      return !Number.isFinite(componentUnitSize) || nearlyEqual(componentUnitSize, unitSize);
    })
    .filter(r => {
      if (!applyComponentSet || !hasField(itemRecipeComponentsTbl, 'component_set')) return true;
      const rowSet = normStr(asStr(r, 'component_set'));
      return !rowSet || rowSet === plannedComponentSet;
    })
    .sort((a, b) => (num(a.getCellValue('sort_order')) || 0) - (num(b.getCellValue('sort_order')) || 0));
}

async function validateMultiRecipeComponentSet() {
  if (itemComponentMode !== 'multi_recipe' || !itemRecipeComponentsTbl || !plannedItem) return;

  const candidates = await getPlannedItemComponents({ applyComponentSet: false });
  const sets = [...new Set(candidates
    .map(r => hasField(itemRecipeComponentsTbl, 'component_set') ? normStr(asStr(r, 'component_set')) : '')
    .filter(Boolean))];

  if (sets.length > 1 && !plannedComponentSet) {
    await safeUpdate(runsTbl, run.id, {
      ui_error: 'planned_component_set is required for this multi_recipe item/size. Available component sets: ' + sets.join(', '),
      ui_error_at: new Date().toISOString(),
      action: null
    });
    throw new Error('Sterilizer OUT validation failed. planned_component_set is required for multi_recipe item.');
  }

  if (plannedComponentSet && sets.length && !sets.includes(plannedComponentSet)) {
    await safeUpdate(runsTbl, run.id, {
      ui_error: 'planned_component_set ' + plannedComponentSet + ' does not match active item_recipe_components for this item/size. Available component sets: ' + sets.join(', '),
      ui_error_at: new Date().toISOString(),
      action: null
    });
    throw new Error('Sterilizer OUT validation failed. planned_component_set does not match active item_recipe_components.');
  }
}


await validateMultiRecipeComponentSet();

async function createLotRecipeComponentsForSterilizedLots(lotIds) {
  if (!lotRecipeComponentsTbl || !lotIds.length) return;

  const creates = [];

  if (itemComponentMode === 'multi_recipe') {
    const components = await getPlannedItemComponents({ applyComponentSet: true });
    for (const lotId of lotIds) {
      for (const c of components) {
        const recipeId = firstLinkId(c, 'recipe_id');
        if (!recipeId) continue;
        const defaultWeight = hasField(itemRecipeComponentsTbl, 'default_weight_lb') ? num(c.getCellValue('default_weight_lb')) : null;
        const fields = {
          lot_id: [{ id: lotId }],
          item_id: [{ id: plannedItem.id }],
          recipe_id: [{ id: recipeId }],
          source_item_recipe_component: [{ id: c.id }],
          component_role: { name: normStr(asStr(c, 'component_role')) || componentRoleForCategory(itemCategory) },
          sort_order: num(c.getCellValue('sort_order')) || undefined,
          notes: 'Created from multi_recipe item component plan on sterilization run ' + (runNo || run.id)
        };
        if (Number.isFinite(defaultWeight)) fields.component_weight_lb = defaultWeight;
        const percent = hasField(itemRecipeComponentsTbl, 'default_percent') ? num(c.getCellValue('default_percent')) : null;
        if (Number.isFinite(percent)) fields.component_percent = percent;
        creates.push({ fields });
      }
    }
  } else if (plannedRecipe) {
    let matchingComponentId = null;
    if (itemRecipeComponentsTbl) {
      const components = await getPlannedItemComponents();
      const match = components.find(c => firstLinkId(c, 'recipe_id') === plannedRecipe.id);
      if (match) matchingComponentId = match.id;
    }
    for (const lotId of lotIds) {
      const fields = {
        lot_id: [{ id: lotId }],
        item_id: [{ id: plannedItem.id }],
        recipe_id: [{ id: plannedRecipe.id }],
        component_role: { name: componentRoleForCategory(itemCategory) },
        component_weight_lb: unitSize,
        sort_order: 1,
        notes: 'Created from sterilization run planned_recipe'
      };
      if (matchingComponentId) fields.source_item_recipe_component = [{ id: matchingComponentId }];
      creates.push({ fields });
    }
  }

  await createRecordsInBatches(lotRecipeComponentsTbl, creates);
}

/* ---------- create lots ---------- */
const creates = [];
for (let i = 0; i < goodCount; i++) {
  const fields = {
    item_id: [{ id: plannedItem.id }],
    unit_size: unitSize,
    qty: 1,
    sterilized_at: tsDate,
    ...(operatorSS ? { operator: operatorSS } : {}),
    ...(plannedRecipe ? { recipe_id: [{ id: plannedRecipe.id }] } : {}),
    ...(linkRunOnLot ? { steri_run_id: [{ id: run.id }] } : {})
  };
  if (proc === 'pasteurize' && statusPasteurized) fields.status = { id: statusPasteurized.id };
  else if (statusSterilized) fields.status = { id: statusSterilized.id };

  // Set lot.use_by for un-inoculated grain/substrate/casing lots: 3 months from sterilization
  if (['grain', 'substrate', 'casing', 'cordyceps_substrate'].includes(itemCategory)) {
    try {
      const d = new Date(tsDate);
      if (!Number.isNaN(d.getTime())) {
        d.setMonth(d.getMonth() + 3);
        fields.use_by = d;
      }
    } catch (e) {
      // If date math fails, leave use_by unset.
    }
  }
  
  const procName = proc === 'pasteurize' ? 'Pasteurize' : 'Sterilize';
  const itemName = itemRec?.getCellValueAsString('name') || '';

  if (hasField(lotsTbl, 'item_name_mat')) {
    const v = coerceValueForField(lotsTbl, 'item_name_mat', itemName);
    if (v != null) fields.item_name_mat = v;
  }
  if (hasField(lotsTbl, 'item_category_mat')) {
    const v = coerceValueForField(lotsTbl, 'item_category_mat', itemCategory);
    if (v != null) fields.item_category_mat = v;
  }
  if (hasField(lotsTbl, 'process_type_mat')) {
    const v = coerceValueForField(lotsTbl, 'process_type_mat', procName);
    if (v != null) fields.process_type_mat = v;
  }
  
  creates.push({ fields });
}
const createdLotIds = [];
for (let i = 0; i < creates.length; i += 50) {
  const ids = await lotsTbl.createRecordsAsync(creates.slice(i, i + 50));
  createdLotIds.push(...ids);
}

await createLotRecipeComponentsForSterilizedLots(createdLotIds);

/* ---------- events for new lots ---------- */
if (createdLotIds.length) {
  const evts = createdLotIds.map(lotId => ({
    fields: {
      lot_id: [{ id: lotId }],
      station: 'Sterilizer OUT',
      operator: operatorName || 'system', // Events.operator is text
      type: (proc === 'pasteurize' && evtPasteurized) ? { id: evtPasteurized.id }
           : (evtSterilized ? { id: evtSterilized.id } : undefined),
      timestamp: tsDate,
      fields_json: JSON.stringify({
        run_id: run.id,
        run_no: runNo || null,
        process_type: proc,
        unit_size: unitSize,
        component_set: plannedComponentSet || null
      })
    }
  }));
  for (let i = 0; i < evts.length; i += 50) {
    await eventsTbl.createRecordsAsync(evts.slice(i, i + 50));
  }
}

/* ---------- destroyed events (optional) ---------- */
if (destroyedCount > 0 && evtDestroyed) {
  const de = [];
  for (let i = 0; i < destroyedCount; i++) {
    de.push({
      fields: {
        type: { id: evtDestroyed.id },
        station: 'Sterilizer OUT',
        operator: operatorName || 'system',
        timestamp: tsDate,
        fields_json: JSON.stringify({ run_id: run.id, run_no: runNo || null, process_type: proc, component_set: plannedComponentSet || null })
      }
    });
  }
  for (let i = 0; i < de.length; i += 50) {
    await eventsTbl.createRecordsAsync(de.slice(i, i + 50));
  }
}

/* ---------- stamp end_time & clear flags ---------- */
await safeUpdate(runsTbl, run.id, {
  end_time: tsDate,
  ui_error: null,
  ui_error_at: null,
  action: null
});

// Add a single consolidated sheet job for this run
let pqTbl = null;
try { pqTbl = base.getTable('print_queue'); } catch(_){}
if (pqTbl) {
  const SourceKindField = pqTbl.getField('source_kind');
  const SteriSheetKind = (SourceKindField.options?.choices || []).find(c => c.name === 'steri_sheet');
  const PrintStatusField = pqTbl.getField('print_status');
  const StatusQueued = (PrintStatusField.options?.choices || []).find(c => c.name === 'Queued');

  let SteriSheetLabel = null;
  if (hasField(pqTbl, 'label_type')) {
    const LabelTypeField = pqTbl.getField('label_type');
    SteriSheetLabel = (LabelTypeField.options?.choices || []).find(c => c.name === 'Sterilizer_Sheet') || null;
  }

  const pqFields = {
    source_kind: SteriSheetKind,
    run_id: [{ id: run.id }],
    print_status: StatusQueued,
    // Optional: set a specific printer per job here:
    // target_printer: 'HP_Office_Letter'
  };

  // Set the explicit sterilizer sheet label type when the schema includes it.
  // Older bases without this select choice can still route by source_kind = steri_sheet.
  if (SteriSheetLabel) pqFields.label_type = SteriSheetLabel;

  await pqTbl.createRecordAsync(pqFields);
}

notify(`Created ${createdLotIds.length} ${proc} lot(s). End time = ${tsIso}`);
