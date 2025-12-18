/**
 * Script: spawn_to_bulk_create_blocks.js
 * Version: 2025-12-18.1
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
 * Summary: Spawn → Bulk – Create Fruiting Blocks
 * - Accepts input.config().recordId OR input.config().stagingLotId
 * - (Optional) respects lots.action == 'SpawnToBulk' (if field exists); clears action on exit
 * - Defaults grain_inputs to the staging lot when empty (legacy behavior)
 * - Validations write to lots.ui_error (+ ui_error_at if present)
 * - Computes output unit_size:
 *     * If substrate_inputs count == output_count, uses per-substrate bag sizes + evenly-shared grain size
 *     * Else, uses (total grain + total substrate)/output_count
 * - Picks output item_id from substrate signature (CVG/MM75/MM50) + size threshold (>=5 lb => LG)
 * - Creates lots in batches; links grain_inputs/substrate_inputs on each new lot
 * - Creates SpawnedToBulk events per output lot (if events.type supports it)
 * - Optionally marks all input lots Consumed + logs Consumed events
 * - Stamps spawned_at from lots.override_spawn_time or NOW()
 */

const CONSUME_INPUTS = true; // set false if you do NOT want to mark inputs Consumed
const OUTPUT_STATUS_PRIMARY = 'Colonizing';
const OUTPUT_STATUS_FALLBACK = 'Spawned';
const EVENT_TYPE_SPAWNED_TO_BULK = 'SpawnedToBulk';
const EVENT_TYPE_CONSUMED = 'Consumed';

// Item auto-pick rules for fruiting blocks
const FB_FALLBACK = 'FB-GENERIC';
const FB_RULES = [
  { tag: 'CVG',  small: 'FB-COCO-SM', large: 'FB-COCO-LG'  },
  { tag: 'MM75', small: 'FB-MM75-SM', large: 'FB-MM75-LG' },
  { tag: 'MM50', small: 'FB-MM50-SM', large: 'FB-MM50-LG' }
];
const LARGE_THRESHOLD_LB = 5; // >= 5 lb → “LG”, else “SM”

const lotsTbl   = base.getTable('lots');
const itemsTbl  = base.getTable('items');
const eventsTbl = base.getTable('events');

function hasField(tbl, name) { try { tbl.getField(name); return true; } catch { return false; } }
function num(val) {
  if (val == null) return null;
  if (typeof val === 'number') return Number.isFinite(val) ? val : null;
  const n = Number(val);
  return Number.isFinite(n) ? n : null;
}
function getStr(rec, field) { try { return (rec.getCellValueAsString(field) || '').trim(); } catch { return ''; } }
function getLinkIds(rec, field) { try { return (rec.getCellValue(field) || []).map(x => x.id); } catch { return []; } }

// For singleSelect fields, Airtable accepts {name:"Option"}; for text fields, must be string.
function coerceValueForField(table, fieldName, valueStr) {
  if (valueStr == null) return null;
  const s = String(valueStr);
  if (!s) return null;
  const f = table.getField(fieldName);
  if (f.type === 'singleSelect') return { name: s };
  return s;
}

async function setUiError(lotId, msg) {
  if (!hasField(lotsTbl, 'ui_error')) return;
  const fields = { ui_error: msg || '' };
  if (hasField(lotsTbl, 'ui_error_at')) fields.ui_error_at = new Date().toISOString();
  // Clear action (legacy)
  if (hasField(lotsTbl, 'action')) fields.action = null;
  try { await lotsTbl.updateRecordAsync(lotId, fields); } catch {}
}
async function clearUiError(lotId) {
  if (!hasField(lotsTbl, 'ui_error')) return;
  const fields = { ui_error: '' };
  if (hasField(lotsTbl, 'ui_error_at')) fields.ui_error_at = null;
  if (hasField(lotsTbl, 'action')) fields.action = null;
  try { await lotsTbl.updateRecordAsync(lotId, fields); } catch {}
}

function pickFbItemCode({ substrateSig, perOutputSizeLb }) {
  for (const rule of FB_RULES) {
    if (substrateSig.includes(rule.tag)) {
      return perOutputSizeLb >= LARGE_THRESHOLD_LB ? rule.large : rule.small;
    }
  }
  return FB_FALLBACK;
}

function detectSubstrateSignature(subLots) {
  // Look for substrings in the item code/name text
  const tags = new Set();
  for (const r of subLots) {
    const txt = (getStr(r, 'item_id') + ' ' + getStr(r, 'name')).toUpperCase();
    if (txt.includes('CVG'))  tags.add('CVG');
    if (txt.includes('MM75') || (txt.includes('MASTER') && txt.includes('75'))) tags.add('MM75');
    if (txt.includes('MM50') || (txt.includes('MASTER') && txt.includes('50'))) tags.add('MM50');
  }
  // If multiple tags, treat as mixed (no match => fallback)
  if (tags.size !== 1) return '';
  return [...tags][0];
}

async function loadLotsByIds(ids) {
  if (!ids.length) return [];
  const wanted = new Set(ids);
  // Pull once (fast enough for typical automation sizes)
  const q = await lotsTbl.selectRecordsAsync({
    fields: ['unit_size','item_id','strain_id','recipe_id','lot_id','status']
  });
  return q.records.filter(r => wanted.has(r.id));
}

async function buildItemLookups() {
  const q = await itemsTbl.selectRecordsAsync({ fields: ['item_id','name','category'] });
  const codeToId = new Map();
  const idToMeta = new Map(); // itemRecId -> { name, category }

  for (const it of q.records) {
    const recId = it.id;
    const code = getStr(it, 'item_id').toUpperCase();
    const name = getStr(it, 'name');
    const cat  = getStr(it, 'category');

    if (code) codeToId.set(code, recId);
    // Optional convenience: allow matching by name string too (as your prior code did)
    if (name) {
      const key = name.toUpperCase();
      if (!codeToId.has(key)) codeToId.set(key, recId);
    }

    idToMeta.set(recId, { name, category: cat });
  }

  return { codeToId, idToMeta };
}

async function getSingleSelectOptionIdByName(table, fieldName, desiredName) {
  try {
    const f = table.getField(fieldName);
    if (f.type !== 'singleSelect') return null;
    const opt = (f.options?.choices || []).find(c => (c.name || '').toLowerCase() === String(desiredName).toLowerCase());
    return opt ? opt.id : null;
  } catch {
    return null;
  }
}

async function main() {
  const cfg = input.config() || {};
  const stagingId = cfg.recordId || cfg.stagingLotId || cfg.stagingLotID || cfg.lotId;
  if (!stagingId) throw new Error('Missing input config id. Provide recordId or stagingLotId.');

  const staging = await lotsTbl.selectRecordAsync(stagingId);
  if (!staging) throw new Error('Staging lot not found.');

  // Optional action gate (legacy): only run if action == SpawnToBulk
  if (hasField(lotsTbl, 'action')) {
    const act = getStr(staging, 'action');
    if (act && act !== 'SpawnToBulk') {
      // Clear it and exit
      try { await lotsTbl.updateRecordAsync(staging.id, { action: null }); } catch {}
      return;
    }
  }

  // Inputs
  let grainIds = getLinkIds(staging, 'grain_inputs');
  const subIds  = getLinkIds(staging, 'substrate_inputs');
  const outCount = num(staging.getCellValue('output_count'));

  // Legacy fallback: if grain_inputs empty, default to staging lot
  if (grainIds.length === 0) {
    grainIds = [staging.id];
    if (hasField(lotsTbl, 'grain_inputs')) {
      try { await lotsTbl.updateRecordAsync(staging.id, { grain_inputs: [{ id: staging.id }] }); } catch {}
    }
  }

  const errs = [];
  if (grainIds.length < 1) errs.push('Select at least one grain lot in grain_inputs.');
  if (subIds.length   < 1) errs.push('Select at least one substrate lot in substrate_inputs.');
  if (!Number.isFinite(outCount) || outCount < 1) errs.push('Set output_count to 1 or more.');
  if (errs.length) { await setUiError(staging.id, errs.join(' ')); return; }

  const grainRecs = await loadLotsByIds(grainIds);
  const subRecs   = await loadLotsByIds(subIds);

  // Validate strain: must be exactly 1
  const strainIds = new Set();
  let grainSizeSum = 0;
  for (const r of grainRecs) {
    const sid = (r.getCellValue('strain_id') || [])[0]?.id;
    if (sid) strainIds.add(sid);
    const s = num(r.getCellValue('unit_size'));
    if (!Number.isFinite(s) || s <= 0) errs.push(`Grain lot ${r.lot_id || r.id} missing/invalid unit_size.`);
    else grainSizeSum += s;
  }
  let subSizeSum = 0;
  for (const r of subRecs) {
    const s = num(r.getCellValue('unit_size'));
    if (!Number.isFinite(s) || s <= 0) errs.push(`Substrate lot ${r.lot_id || r.id} missing/invalid unit_size.`);
    else subSizeSum += s;
  }
  if (strainIds.size === 0) errs.push('Grain inputs are missing strain_id.');
  if (strainIds.size > 1)  errs.push('Grain inputs have mixed strains; use a single strain.');
  const totalSize = grainSizeSum + subSizeSum;
  if (!(totalSize > 0)) errs.push('Total input unit_size must be > 0.');
  if (errs.length) { await setUiError(staging.id, errs.join(' ')); return; }
  const [strainId] = [...strainIds];

  // Timestamp
  const overrideSpawn = hasField(lotsTbl, 'override_spawn_time') ? staging.getCellValue('override_spawn_time') : null;
  const tsDate = overrideSpawn || new Date();

  // Per-output unit sizes:
  // If substrate count == outCount, attribute each substrate bag to one output, and share grain evenly.
  const grainShare = grainSizeSum / outCount;
  const perOutputUnits = [];
  if (subRecs.length === outCount) {
    for (const r of subRecs) {
      const subSize = num(r.getCellValue('unit_size')) || 0;
      perOutputUnits.push(grainShare + subSize);
    }
  } else {
    const per = totalSize / outCount;
    for (let i = 0; i < outCount; i++) perOutputUnits.push(per);
  }

  // Substrate signature (single tag only)
  const substrateTag = detectSubstrateSignature(subRecs);
  const { codeToId: itemCodeToId, idToMeta } = await buildItemLookups();

  // Resolve output status option id if singleSelect, else write name (string)
  let statusFieldPayload = null;
  if (hasField(lotsTbl, 'status')) {
    const idPrimary = await getSingleSelectOptionIdByName(lotsTbl, 'status', OUTPUT_STATUS_PRIMARY);
    const idFallback = await getSingleSelectOptionIdByName(lotsTbl, 'status', OUTPUT_STATUS_FALLBACK);
    if (idPrimary) statusFieldPayload = { id: idPrimary };
    else if (idFallback) statusFieldPayload = { id: idFallback };
    else statusFieldPayload = coerceValueForField(lotsTbl, 'status', OUTPUT_STATUS_PRIMARY) || coerceValueForField(lotsTbl, 'status', OUTPUT_STATUS_FALLBACK);
  }

  // Resolve event type option ids (if applicable)
  let spawnedToBulkEvtId = null;
  let consumedEvtId = null;
  if (hasField(eventsTbl, 'type')) {
    spawnedToBulkEvtId = await getSingleSelectOptionIdByName(eventsTbl, 'type', EVENT_TYPE_SPAWNED_TO_BULK);
    consumedEvtId      = await getSingleSelectOptionIdByName(eventsTbl, 'type', EVENT_TYPE_CONSUMED);
  }

  // Build lots create payload
  const parentIds = [...grainIds, ...subIds];
  const createBatch = [];
  const chosenItemCodes = [];
  for (let i = 0; i < outCount; i++) {
    const itemCode = pickFbItemCode({ substrateSig: substrateTag, perOutputSizeLb: perOutputUnits[i] });
    chosenItemCodes.push(itemCode);
    const itemRecId = itemCodeToId.get(itemCode.toUpperCase()) || itemCodeToId.get(FB_FALLBACK) || null;
    if (!itemRecId) {
      await setUiError(staging.id, `Could not resolve items.item_id "${itemCode}" (or fallback "${FB_FALLBACK}").`);
      return;
    }

    const fields = {};
    if (statusFieldPayload) fields.status = statusFieldPayload;
    if (hasField(lotsTbl, 'item_id')) fields.item_id = [{ id: itemRecId }];
    if (hasField(lotsTbl, 'unit_size')) fields.unit_size = perOutputUnits[i];
    if (hasField(lotsTbl, 'qty')) fields.qty = 1;
    if (hasField(lotsTbl, 'parents_json')) fields.parents_json = JSON.stringify(parentIds);
    if (hasField(lotsTbl, 'strain_id')) fields.strain_id = [{ id: strainId }];
    if (hasField(lotsTbl, 'spawned_at')) fields.spawned_at = tsDate;

    // Set lot.use_by for fruiting blocks: 3 months from spawn
    try {
      const d = new Date(tsDate);
      if (!Number.isNaN(d.getTime())) {
        d.setMonth(d.getMonth() + 3);
        fields.use_by = d;
      }
    } catch (e) {
      // If date math fails, leave use_by unset.
    }

    // Optional: inherit recipe_id from staging (if present)
    const outRecipe = (staging.getCellValue('recipe_id') || [])[0]?.id;
    if (outRecipe && hasField(lotsTbl, 'recipe_id')) fields.recipe_id = [{ id: outRecipe }];

    // Materialized text mirrors, if present (type-safe)
    const meta = idToMeta.get(itemRecId) || { name: '', category: '' };
    if (hasField(lotsTbl, 'item_name_mat')) {
      const v = coerceValueForField(lotsTbl, 'item_name_mat', meta.name);
      if (v != null) fields.item_name_mat = v;
    }
    if (hasField(lotsTbl, 'item_category_mat')) {
      const v = coerceValueForField(lotsTbl, 'item_category_mat', meta.category);
      if (v != null) fields.item_category_mat = v;
    }

    // Link inputs on new lots
    if (hasField(lotsTbl, 'grain_inputs')) fields.grain_inputs = grainIds.map(id => ({ id }));
    if (hasField(lotsTbl, 'substrate_inputs')) fields.substrate_inputs = subIds.map(id => ({ id }));

    createBatch.push({ fields });
  }

  // Create lots in batches
  const createdIds = [];
  for (let i = 0; i < createBatch.length; i += 50) {
    const ids = await lotsTbl.createRecordsAsync(createBatch.slice(i, i + 50));
    createdIds.push(...ids);
  }

  // SpawnedToBulk events per created lot
  if (spawnedToBulkEvtId && hasField(eventsTbl, 'lot_id')) {
    const evts = createdIds.map((id, idx) => ({
      fields: {
        lot_id: [{ id }],
        type: { id: spawnedToBulkEvtId },
        station: 'Spawn to Bulk',
        fields_json: JSON.stringify({
          grain_input_ids: grainIds,
          substrate_input_ids: subIds,
          per_output_unit_size_lb: perOutputUnits[idx],
          output_item_code: chosenItemCodes[idx],
          output_index: idx,
          output_count: outCount
        })
      }
    }));
    for (let i = 0; i < evts.length; i += 50) {
      await eventsTbl.createRecordsAsync(evts.slice(i, i + 50));
    }
  }

  // Consume inputs (status + events)
  if (CONSUME_INPUTS) {
    // Update input lots to Consumed if status exists
    if (hasField(lotsTbl, 'status')) {
      const consumedStatusId = await getSingleSelectOptionIdByName(lotsTbl, 'status', 'Consumed');
      if (consumedStatusId) {
        const updates = parentIds.map(id => ({ id, fields: { status: { id: consumedStatusId } } }));
        for (let i = 0; i < updates.length; i += 50) {
          await lotsTbl.updateRecordsAsync(updates.slice(i, i + 50));
        }
      }
    }
    // Log Consumed events if supported
    if (consumedEvtId && hasField(eventsTbl, 'lot_id')) {
      const ce = parentIds.map(id => ({
        fields: {
          lot_id: [{ id }],
          type: { id: consumedEvtId },
          station: 'Spawn to Bulk',
          fields_json: JSON.stringify({ consumed_by_lot_ids: createdIds })
        }
      }));
      for (let i = 0; i < ce.length; i += 50) {
        await eventsTbl.createRecordsAsync(ce.slice(i, i + 50));
      }
    }
  }

  await clearUiError(staging.id);

  if (typeof output !== 'undefined' && output && output.set) {
    output.set('result', `Created ${createdIds.length} fruiting block lot(s). unit_size(s): ${perOutputUnits.map(x => Number(x.toFixed(2))).join(', ')}`);
  }
}

main().catch(async (e) => {
  try {
    const cfg = input.config() || {};
    const stagingId = cfg.recordId || cfg.stagingLotId || cfg.stagingLotID || cfg.lotId;
    if (stagingId) await setUiError(stagingId, (e && e.message) ? e.message : String(e));
  } catch {}
  if (typeof output !== 'undefined' && output && output.set) {
    output.set('error', (e && e.message) ? e.message : String(e));
  } else {
    throw e;
  }
});
