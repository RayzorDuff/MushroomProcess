/**
 * Script: sterilizer_out_validate_create_lots.js
 * Version: 2025-10-16.1
 * Summary: Sterilizer OUT – Validate & Create Lots
 * Notes: Succinct header; no diff blocks; try/catch + error surfacing.
 */

const { runId } = input.config();

const runsTbl   = base.getTable('sterilization_runs');
const itemsTbl  = base.getTable('items');
const lotsTbl   = base.getTable('lots');
const eventsTbl = base.getTable('events');

/* ---------- helpers ---------- */
function hasField(tbl, name){ try { tbl.getField(name); return true; } catch { return false; } }
function fieldType(tbl, name){ try { return tbl.getField(name).type; } catch { return null; } }
function isLinkField(tbl, name){ return fieldType(tbl, name) === 'multipleRecordLinks'; }
function num(v){ const n = Number(v); return Number.isFinite(n) ? n : null; }
function asStr(rec, f){ try { return rec.getCellValueAsString(f) || ''; } catch { return ''; } }
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
    create_lots: false,
    action: null
  });
  throw new Error('Sterilizer OUT validation failed.');
}

/* ---------- resolve process type (pasteurize vs sterilize) ---------- */
const itemRec = await itemsTbl.selectRecordAsync(plannedItem.id);
const processTypeRaw = asStr(run, 'process_type').toLowerCase();
const targetTempC    = num(run.getCellValue('target_temp_c'));
const pressureMode   = asStr(run, 'pressure_mode').toLowerCase();
function resolveProcess() {
  if (processTypeRaw === 'pasteurize' || processTypeRaw === 'sterilize') return processTypeRaw;
  if (Number.isFinite(targetTempC) && targetTempC <= 100) return 'pasteurize';
  if (pressureMode === 'open') return 'pasteurize';
  if (Number.isFinite(targetTempC) && targetTempC >= 110) return 'sterilize';
  const cat = (itemRec?.getCellValueAsString('category') || '').toLowerCase();
  if (cat === 'casing') return 'pasteurize';
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
  else if (statusSterilized)                      fields.status = { id: statusSterilized.id };
  creates.push({ fields });
}
const createdLotIds = [];
for (let i = 0; i < creates.length; i += 50) {
  const ids = await lotsTbl.createRecordsAsync(creates.slice(i, i + 50));
  createdLotIds.push(...ids);
}

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
        unit_size: unitSize
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
        fields_json: JSON.stringify({ run_id: run.id, run_no: runNo || null, process_type: proc })
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
  create_lots: false,
  action: null
});

// Add a single consolidated sheet job for this run
let pqTbl = null;
try { pqTbl = base.getTable('print_queue'); } catch(_){}
if (pqTbl) {
  const SourceKindField     = pqTbl.getField('source_kind');
  const SteriSheetKind  = (SourceKindField.options?.choices || []).find(c => c.name === 'steri_sheet');
  const PrintStatusField     = pqTbl.getField('print_status');
  const StatusQueued  = (PrintStatusField.options?.choices || []).find(c => c.name === 'Queued');

  await pqTbl.createRecordAsync({
    source_kind: SteriSheetKind,
    run_id: [{ id: run.id }],
    print_status: StatusQueued,
    // Optional: set a specific printer per job here:
    // target_printer: 'HP_Office_Letter'
  });
}

notify(`Created ${createdLotIds.length} ${proc} lot(s). End time = ${tsIso}`);
