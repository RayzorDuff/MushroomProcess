/**
 *  Script: spawn_to_bulk_create_blocks.js
 *  Version: 2025-11-11
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
 *  Summary: Create Fruiting Block lots from grain + substrate inputs with
 *           correct unit size allocation and full lineage/events.
 *  Features:
 *  Invocation: Airtable Automation / Interface, with input.config():
 *    - recordId (string)          // the staging "Lots" record executing Spawn→Bulk
 *
 *  Behavior:
 *    - Validates the staging record has:
 *        • output_count >= 1
 *        • at least one grain input OR at least one substrate input
 *    - Computes per-output unit_size with this rule:
 *        • If outCount === substrate_inputs.length:
 *            unit_i = (SUM(grain.unit_size) / outCount) + substrate_i.unit_size
 *          (i.e., grain is evenly divided; each paired substrate contributes FULL size)
 *        • Else (mismatch): fallback to even average:
 *            unit_i = (SUM(grain.unit_size) + SUM(substrate.unit_size)) / outCount
 *    - Inherits strain from the first grain input (fallback: first substrate).
 *    - Picks output item_id by substrate recipe/item signature:
 *        FB-COCO-LG/SM for "CVG"
 *        FB-MM75-LG/SM for "MM75"
 *        FB-MM50-LG/SM for "MM50"
 *        Threshold: LARGE when per-output unit_size >= 5, else SMALL
 *        Fallback: FB-GENERIC if none match.
 *    - Creates outCount new Fruiting Block lots:
 *        status = Colonizing (fallback Spawned)
 *        spawned_at = override_spawn_time || now
 *        parents_json = JSON of parent lot IDs
 *        grain_inputs / substrate_inputs linked on the new blocks
 *    - Logs Events (SpawnedToBulk) on each new block with fields_json details
 *    - Optionally marks all input lots as Consumed
 *    - Writes user-friendly validation errors to lots.ui_error on the staging row
 *
 *  Side Effects:
 *    - Adds records to Lots + Events.
 *    - Updates inputs’ status if consumption is enabled.
 *    - Clears lots.ui_error on success.
 *
**/

///////////////////////////// CONFIG ///////////////////////////////////////////

const CONSUME_INPUTS = true; // set to false if you do NOT want to mark inputs Consumed
const OUTPUT_STATUS_PRIMARY = 'Colonizing';
const OUTPUT_STATUS_FALLBACK = 'Spawned';
const EVENT_TYPE_SPAWNED_TO_BULK = 'SpawnedToBulk';

// Item auto-pick rules for fruiting blocks
const FB_FALLBACK = 'FB-GENERIC';
const FB_RULES = [
  { tag: 'CVG',  small: 'FB-COCO-SM', large: 'FB-COCO-LG'  },
  { tag: 'MM75', small: 'FB-MM75-SM', large: 'FB-MM75-LG' },
  { tag: 'MM50', small: 'FB-MM50-SM', large: 'FB-MM50-LG' }
];
const LARGE_THRESHOLD_LB = 5; // >= 5 lb → “LG”, else “SM”

//////////////////////////// TABLE HANDLES /////////////////////////////////////

const lotsTbl    = base.getTable('lots');
const itemsTbl   = base.getTable('items');
const eventsTbl  = base.getTable('events');

//////////////////////////// UTILITIES /////////////////////////////////////////

function hasField(tbl, name) { try { tbl.getField(name); return true; } catch { return false; } }
function coerceValueForField(table, fieldName, valueStr) {
  if (!valueStr) return null;
  const f = table.getField(fieldName);
  if (f.type === 'singleSelect') return { name: valueStr };
  return valueStr; // singleLineText, etc.
}
function num(val) {
  if (val == null) return null;
  if (typeof val === 'number') return Number.isFinite(val) ? val : null;
  const n = Number(val);
  return Number.isFinite(n) ? n : null;
}
function getStr(rec, field) { try { return (rec.getCellValueAsString(field) || '').trim(); } catch { return ''; } }
function getLinkIds(rec, field) {
  try { return (rec.getCellValue(field) || []).map(x => x.id); } catch { return []; }
}
async function setUiError(lotId, msg) {
  if (!hasField(lotsTbl, 'ui_error')) return;
  try { await lotsTbl.updateRecordAsync(lotId, { ui_error: msg }); } catch {}
}
async function clearUiError(lotId) {
  if (!hasField(lotsTbl, 'ui_error')) return;
  try { await lotsTbl.updateRecordAsync(lotId, { ui_error: '' }); } catch {}
}

function pickFbItemId({ substrateSig, perOutputSizeLb }) {
  // Choose by signature tag in order of rules
  for (const rule of FB_RULES) {
    if (substrateSig.includes(rule.tag)) {
      return perOutputSizeLb >= LARGE_THRESHOLD_LB ? rule.large : rule.small;
    }
  }
  return FB_FALLBACK;
}

//////////////////////////// INPUTS ////////////////////////////////////////////

const { recordId } = input.config();
if (!recordId) throw new Error('recordId is required.');

const staging = await lotsTbl.selectRecordAsync(recordId);
if (!staging) throw new Error('Staging lot record not found.');

//////////////////////////// VALIDATION ////////////////////////////////////////

const errors = [];

const outCount = Math.max(1, num(staging.getCellValue('output_count')) || 0);

const grainIds = getLinkIds(staging, 'grain_inputs');
const subIds   = getLinkIds(staging, 'substrate_inputs');

if (outCount < 1) errors.push('output_count must be >= 1.');
if (grainIds.length === 0 && subIds.length === 0) {
  errors.push('At least one grain input or one substrate input is required.');
}

if (errors.length) {
  await setUiError(staging.id, errors.join(' '));
  throw new Error(`Validation failed: ${errors.join(' ')}`);
}

//////////////////// LOAD INPUT LOTS + FIELDS WE NEED //////////////////////////

const loadInputLots = async (ids) => {
  if (ids.length === 0) return [];
  // Batch select by IDs in chunks
  const out = [];
  for (let i = 0; i < ids.length; i += 50) {
    const slice = ids.slice(i, i + 50);
    const q = await lotsTbl.selectRecordsAsync({ fields: ['unit_size','item_id','strain_id','recipe_id','item_id','lot_id'] });
    // (Airtable scripting has no direct "select by list", so we just filter in-memory)
    for (const r of q.records) if (slice.includes(r.id)) out.push(r);
  }
  // Deduplicate if any overlap
  const seen = new Set(); const uniq = [];
  for (const r of out) { if (!seen.has(r.id)) { seen.add(r.id); uniq.push(r); } }
  return uniq;
};

const grainRecs = await loadInputLots(grainIds);
const subRecs   = await loadInputLots(subIds);

// Gather sizes (assume unit_size is in **pounds**, consistent with your base)
let grainUnitSum = 0;
for (const r of grainRecs) {
  const s = num(r.getCellValue('unit_size'));
  if (s) grainUnitSum += s;
}
let subUnitSum = 0;
for (const r of subRecs) {
  const s = num(r.getCellValue('unit_size'));
  if (s) subUnitSum += s;
}

// Resolve a substrate “signature” used to pick FB item ID (CVG / MM75 / MM50)
const substrateSignature = (() => {
  // prefer recipe_id then item_id text
  for (const r of subRecs) {
    const rid = r.getCellValue('recipe_id'); // linked
    if (rid && rid.length) {
      const txt = r.getCellValueAsString('recipe_id').toUpperCase();
      if (txt) return txt;
    }
    const iid = r.getCellValue('item_id');
    if (iid && iid.length) {
      const txt = r.getCellValueAsString('item_id').toUpperCase();
      if (txt) return txt;
    }
  }
  return '';
})();

// Resolve strain from first grain (fallback: first substrate)
const strainLink = (grainRecs[0]?.getCellValue('strain_id') || subRecs[0]?.getCellValue('strain_id') || [])[0] || null;
if (!strainLink) {
  // Not fatal: allow creation without strain, but log a warning
  // (We keep it non-blocking to avoid interrupting operations)
}

// Timestamp
const overrideTs = staging.getCellValue('override_spawn_time');
const tsDate = overrideTs ? new Date(overrideTs) : new Date();

// Determine output status choices
const statusField = lotsTbl.getField('status');
const statusChoices = statusField?.typeOptions?.choices || [];
const statusByName = Object.fromEntries(statusChoices.map(c => [c.name, c]));
const outputStatus = statusByName[OUTPUT_STATUS_PRIMARY] || statusByName[OUTPUT_STATUS_FALLBACK] || null;

// Event type choice
const evtTypeField = eventsTbl.getField('type');
const evtChoices   = evtTypeField?.typeOptions?.choices || [];
const evtByName    = Object.fromEntries(evtChoices.map(c => [c.name, c]));
const spawnedToBulkEvt = evtByName[EVENT_TYPE_SPAWNED_TO_BULK] || null;

//////////////// PER-OUTPUT UNIT SIZE (FIXED ALLOCATION LOGIC) /////////////////

/*
  Rule:
    If there is exactly one output per substrate input (outCount === subRecs.length):
      unit_i = (grainUnitSum / outCount) + unit_size(substrate_i)
    Else fallback to even average:
      unit_i = (grainUnitSum + subUnitSum) / outCount
*/
let perOutputUnits = [];
if (subRecs.length > 0 && outCount === subRecs.length) {
  const grainShare = grainUnitSum / outCount;
  for (let i = 0; i < outCount; i++) {
    const subSize = num(subRecs[i]?.getCellValue('unit_size')) || 0;
    perOutputUnits.push(grainShare + subSize);
  }
} else {
  const perBag = (grainUnitSum + subUnitSum) / outCount;
  for (let i = 0; i < outCount; i++) perOutputUnits.push(perBag);
}

// Choose the output Item (per-output based on size)
const fbItemIdByOutput = perOutputUnits.map(sz => pickFbItemId({
  substrateSig: substrateSignature,
  perOutputSizeLb: sz
}));

// Map item_id codes to actual Items
const itemIdToRecordId = async (codes) => {
  const uniq = Array.from(new Set(codes));
  const foundMap = new Map();
  // Fetch items table (single pass) and index by item_id text
  const all = await itemsTbl.selectRecordsAsync({ fields: ['item_id','name','category'] });

  const index = new Map();
  const codeToId = new Map();
  const idToMeta = new Map();
  
  for (const it of all.records) {
    const code = getStr(it, 'item_id');
    if (code) codeToId.set(code, it.id);
    idToMeta.set(it.id, {
      name: it.getCellValueAsString('name') || '',
      category: it.getCellValueAsString('category') || ''
    });
  }
  for (const code of uniq) {
    foundMap.set(code, index.get(code) || null);
  }
  return codes.map(c => foundMap.get(c) || null);
};
const fbItemRecordIds = await itemIdToRecordId(fbItemIdByOutput);

//////////////////// CREATE OUTPUT FRUITING BLOCK LOTS /////////////////////////

const parentsIds = [...grainIds, ...subIds];
const createdIds = [];

const statusPayload = outputStatus ? { status: { id: outputStatus.id } } : {};
const strainPayload = strainLink ? { strain_id: [{ id: strainLink.id }] } : {};

const makeFields = (i) => {
  const itemRecId = fbItemRecordIds[i];
  const fields = {
    ...statusPayload,
    unit_size: perOutputUnits[i],
    qty: 1,
    parents_json: JSON.stringify(parentsIds),
    spawned_at: tsDate,
    ...strainPayload
  };
  // item_id
  if (itemRecId) fields.item_id = [{ id: itemRecId }];
  // inherit output recipe if staging has one
  const outRecLink = staging.getCellValue('recipe_id');
  if (outRecLink && outRecLink.length) fields.recipe_id = [{ id: outRecLink[0].id }];

  const meta = (itemRecId && idToMeta.get(itemRecId)) || { name:'', category:'' };
  const itemName = meta.name;
  const itemCat  = meta.category;
  
  if (hasField(lotsTbl, 'item_name_mat')) {
    const v = coerceValueForField(lotsTbl, 'item_name_mat', itemName);
    if (v != null) fields.item_name_mat = v;
  }
  if (hasField(lotsTbl, 'item_category_mat')) {
    const v = coerceValueForField(lotsTbl, 'item_category_mat', itemCat);
    if (v != null) fields.item_category_mat = v;
  }

  // Link inputs on the NEW block (not on parents)
  try { lotsTbl.getField('grain_inputs');     fields.grain_inputs     = grainIds.map(id => ({ id })); } catch {}
  try { lotsTbl.getField('substrate_inputs'); fields.substrate_inputs = subIds.map(id => ({ id })); } catch {}

  return fields;
};

// Create in batches
const createBatch = [];
for (let i = 0; i < outCount; i++) {
  createBatch.push({ fields: makeFields(i) });
}
for (let i = 0; i < createBatch.length; i += 50) {
  const ids = await lotsTbl.createRecordsAsync(createBatch.slice(i, i + 50));
  createdIds.push(...ids);
}

////////////////////////// LOG EVENTS ON NEW LOTS /////////////////////////////

if (spawnedToBulkEvt) {
  const evtBatch = createdIds.map((id, idx) => {
    const f = {
      lot_id: [{ id }],
      type: { id: spawnedToBulkEvt.id },
      station: 'Spawn to Bulk',
      fields_json: JSON.stringify({
        grain_input_ids: grainIds,
        substrate_input_ids: subIds,
        per_output_unit_size_lb: perOutputUnits[idx],
        output_item_code: fbItemIdByOutput[idx],
        output_index: idx,
        output_count: outCount
      })
    };
    if (hasField(eventsTbl, 'timestamp')) f.timestamp = tsDate;
    return { fields: f };
  });
  for (let i = 0; i < evtBatch.length; i += 50) {
    await eventsTbl.createRecordsAsync(evtBatch.slice(i, i + 50));
  }
}

//////////////////// OPTIONAL: CONSUME INPUT LOTS /////////////////////////////

if (CONSUME_INPUTS && hasField(lotsTbl, 'status')) {
  const status = statusByName['Consumed'];
  if (status) {
    const updates = [...grainIds, ...subIds].map(id => ({ id, fields: { status: { id: status.id } } }));
    for (let i = 0; i < updates.length; i += 50) {
      await lotsTbl.updateRecordsAsync(updates.slice(i, i + 50));
    }
  }
}

//////////////////////////// CLEANUP & OUTPUT /////////////////////////////////

await clearUiError(staging.id);

try {
  output.set('result', `✅ Created ${createdIds.length} fruiting block(s). Per-bag sizes (lb): ${perOutputUnits.map(x => Number(x.toFixed(2))).join(', ')}`);
} catch {}
