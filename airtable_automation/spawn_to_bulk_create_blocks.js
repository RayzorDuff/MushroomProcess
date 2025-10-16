/**
 * Script: spawn_to_bulk_create_blocks.js
 * Version: 2025-10-16.1
 * Summary: Spawn → Bulk – Create Fruiting Blocks
 * Notes: Succinct header; no diff blocks; try/catch + error surfacing.
 */
try {


const { stagingLotId } = input.config();

const lotsTbl   = base.getTable('lots');
const itemsTbl  = base.getTable('items');
const eventsTbl = base.getTable('events');

const staging = await lotsTbl.selectRecordAsync(stagingLotId);
if (!staging) throw new Error('Staging lot not found');

if ((staging.getCellValueAsString('action') || '') !== 'SpawnToBulk') {
  await lotsTbl.updateRecordAsync(staging.id, { action: null });
  return;
}

/* ==== Inputs on staging record ==== */
const grainLinks     = staging.getCellValue('grain_inputs') || [];
const substrateLinks = staging.getCellValue('substrate_inputs') || [];
const outCount       = Number(staging.getCellValue('output_count') ?? NaN);
const outRecipe      = staging.getCellValue('recipe_id')?.[0] || null;   // optional

// NEW: optional override timestamp (Date object from Airtable)
const overrideSpawn  = staging.getCellValue('override_spawn_time'); // may be null
const tsDate         = overrideSpawn || new Date();
//const tsIso          = tsDate.toISOString();

const errs = [];
if (grainLinks.length < 1) errs.push('Select at least one grain lot in grain_inputs.');
if (substrateLinks.length < 1) errs.push('Select at least one substrate lot in substrate_inputs.');
if (!Number.isFinite(outCount) || outCount < 1) errs.push('Set output_count to 1 or more.');
if (errs.length) {
  await lotsTbl.updateRecordAsync(staging.id, {
    ui_error: errs.join(' '),
    ui_error_at: new Date().toISOString(),
    action: null
  });
  throw new Error('Spawn→Bulk validation failed.');
}

/* ==== Gather strain (from grain) and sum unit sizes ==== */
const grainStrainIds = new Set();
let grainUnitSum = 0;
for (const link of grainLinks) {
  const g = await lotsTbl.selectRecordAsync(link.id);
  if (!g) continue;
  // strain
  const sId = g.getCellValue('strain_id')?.[0]?.id;
  if (sId) grainStrainIds.add(sId);
  // unit_size
  const u = Number(g.getCellValue('unit_size') ?? NaN);
  if (!Number.isFinite(u) || u <= 0) errs.push(`Grain lot ${g.name || g.id} missing/invalid unit_size.`);
  else grainUnitSum += u;
}

let subUnitSum = 0;
for (const link of substrateLinks) {
  const s = await lotsTbl.selectRecordAsync(link.id);
  if (!s) continue;
  const u = Number(s.getCellValue('unit_size') ?? NaN);
  if (!Number.isFinite(u) || u <= 0) errs.push(`Substrate lot ${s.name || s.id} missing/invalid unit_size.`);
  else subUnitSum += u;
}

if (grainStrainIds.size === 0) errs.push('Grain inputs are missing strain_id.');
if (grainStrainIds.size > 1)  errs.push('Grain inputs have mixed strains; use a single strain.');
const totalUnit = grainUnitSum + subUnitSum;
if (!(totalUnit > 0)) errs.push('Total input unit_size must be > 0.');
if (errs.length) {
  await lotsTbl.updateRecordAsync(staging.id, {
    ui_error: errs.join(' '),
    ui_error_at: new Date().toISOString(),
    action: null
  });
  throw new Error('Spawn→Bulk strain/unit validation failed.');
}

const [strainId] = [...grainStrainIds];
const perBagUnit = totalUnit / outCount;

/* ==== Determine substrate type tag from substrate_inputs' item_id text ==== */
function detectTypeTagFromSubstrates(records) {
  const tags = new Set();
  for (const r of records) {
    const linkedItemName = r.getCellValueAsString('item_id') || '';
    const txt = linkedItemName.toUpperCase();
    if (txt.includes('CVG'))  tags.add('CVG');
    if (txt.includes('MM75')) tags.add('MM75');
    if (txt.includes('MM50')) tags.add('MM50');
  }
  if (tags.size === 1) return [...tags][0];
  return null; // none or mixed → fallback
}

// Load all substrate lot records once for type detection
const substrateRecs = [];
for (const link of substrateLinks) {
  const rec = await lotsTbl.selectRecordAsync(link.id);
  if (rec) substrateRecs.push(rec);
}
const typeTag = detectTypeTagFromSubstrates(substrateRecs); // 'CVG' | 'MM75' | 'MM50' | null

/* ==== Resolve output item by (typeTag + perBagUnit >= 5 ? LG : SM) ==== */
const wantSizeSuffix = (perBagUnit >= 5) ? 'LG' : 'SM';
const desiredCodes = [];
if (typeTag) {
  desiredCodes.push(`FB-${typeTag}-${wantSizeSuffix}`);   // e.g. FB-CVG-LG
}
desiredCodes.push('FB-GENERIC'); // fallback

// Build an index of items by item_id and by name
const itemsQuery = await itemsTbl.selectRecordsAsync({ fields: ['item_id','name','category'] });
const byCodeOrName = new Map();
for (const rec of itemsQuery.records) {
  const code = (rec.getCellValueAsString('item_id') || '').toUpperCase();
  const name = (rec.getCellValueAsString('name') || '').toUpperCase();
  if (code) byCodeOrName.set(code, rec);
  if (name) byCodeOrName.set(name, rec);
}

// pick first available desired code
let fbItem = null;
for (const code of desiredCodes) {
  const rec = byCodeOrName.get(code.toUpperCase());
  if (rec) { fbItem = rec; break; }
}
if (!fbItem) throw new Error(`Items: could not find any of [${desiredCodes.join(', ')}].`);

// (Optional) sanity: ensure category is fruiting_block
const catVal = (fbItem.getCellValueAsString('category') || '').toLowerCase();
if (catVal !== 'fruiting_block') {
  // warn but continue
}

/* ==== Status & events ==== */
const statusField = lotsTbl.getField('status');
const statusColonizing = (statusField.options?.choices || []).find(c => c.name === 'Colonizing');
const statusSpawned    = (statusField.options?.choices || []).find(c => c.name === 'Spawned');
const outputStatus     = statusColonizing || statusSpawned;
if (!outputStatus) {
  const names = (statusField.options?.choices || []).map(c => c.name).join(', ');
  throw new Error(`lots.status missing "Colonizing" or "Spawned". Has: ${names}`);
}

const evtTypeField = eventsTbl.getField('type');
const spawnedToBulkEvt = (evtTypeField.options?.choices || []).find(c => c.name === 'SpawnedToBulk');
if (!spawnedToBulkEvt) {
  const names = (evtTypeField.options?.choices || []).map(c => c.name).join(', ');
  throw new Error(`events.type missing "SpawnedToBulk". Has: ${names}`);
}
const consumedEvt = (evtTypeField.options?.choices || []).find(c => c.name === 'Consumed')
                 || (evtTypeField.options?.choices || []).find(c => c.name === 'Retired');
if (!consumedEvt) {
  const names = (evtTypeField.options?.choices || []).map(c => c.name).join(', ');
  throw new Error(`events.type missing "Consumed" (or Retired). Has: ${names}`);
}
const tsWritable = (() => { try { return eventsTbl.getField('timestamp').type === 'dateTime'; } catch { return false; }})();

/* ==== Create output bulk lots (stamp spawned_at = tsDate) ==== */
const parentIds = [...grainLinks.map(x => x.id), ...substrateLinks.map(x => x.id)];
const createBatch = [];
for (let i = 0; i < outCount; i++) {
  const fields = {
    status: { id: outputStatus.id },
    item_id: [{ id: fbItem.id }],
    unit_size: perBagUnit,
    qty: 1,
    parents_json: JSON.stringify(parentIds),
    strain_id: [{ id: strainId }],
    spawned_at: tsDate   // NEW: writable date on each new block
  };
  if (outRecipe) fields.recipe_id = [{ id: outRecipe.id }];

  // Link inputs on the newly created block (not on the inputs)
  try { lotsTbl.getField('grain_inputs');      fields.grain_inputs      = grainLinks.map(l => ({ id: l.id })); } catch {}
  try { lotsTbl.getField('substrate_inputs');  fields.substrate_inputs  = substrateLinks.map(l => ({ id: l.id })); } catch {}

  createBatch.push({ fields });
}
const createdIds = [];
for (let i = 0; i < createBatch.length; i += 50) {
  const res = await lotsTbl.createRecordsAsync(createBatch.slice(i, i + 50));
  createdIds.push(...res);
}

/* ==== Log SpawnedToBulk on each new lot (timestamp = tsDate) ==== */
const createdEventBatch = createdIds.map(id => {
  const f = {
    lot_id: [{ id }],
    type: { id: spawnedToBulkEvt.id },
    station: 'Spawn to Bulk',
    fields_json: JSON.stringify({
      type_tag: typeTag,
      chosen_item: fbItem.getCellValueAsString('item_id') || fbItem.name,
      grain_input_ids: grainLinks.map(g => g.id),
      substrate_input_ids: substrateLinks.map(s => s.id),
      per_bag_unit_size: perBagUnit,
      output_count: outCount
    })
  };
  if (tsWritable) f.timestamp = tsDate;
  return { fields: f };
});
for (let i = 0; i < createdEventBatch.length; i += 50) {
  await eventsTbl.createRecordsAsync(createdEventBatch.slice(i, i + 50));
}

/* ==== Mark all input lots as Consumed (or Retired) and log events (timestamp = tsDate) ==== */
const consumedStatus = (statusField.options?.choices || []).find(c => c.name === 'Consumed')
                    || (statusField.options?.choices || []).find(c => c.name === 'Retired');
if (!consumedStatus) {
  const names = (statusField.options?.choices || []).map(c => c.name).join(', ');
  throw new Error(`lots.status missing "Consumed" (or Retired). Has: ${names}`);
}

const inputIds = parentIds;
for (let i = 0; i < inputIds.length; i += 50) {
  await lotsTbl.updateRecordsAsync(
    inputIds.slice(i, i + 50).map(id => ({ id, fields: { status: { id: consumedStatus.id } } }))
  );
}

const consumeEvents = inputIds.map(id => {
  const f = {
    lot_id: [{ id }],
    type: { id: consumedEvt.id },
    station: 'Spawn to Bulk',
    fields_json: JSON.stringify({ output_bulk_ids: createdIds })
  };
  if (tsWritable) f.timestamp = tsDate;
  return { fields: f };
});
for (let i = 0; i < consumeEvents.length; i += 50) {
  await eventsTbl.createRecordsAsync(consumeEvents.slice(i, i + 50));
}

/* ==== Clear staging action/errors ==== */
await lotsTbl.updateRecordAsync(staging.id, {
  action: null,
  ui_error: null,
  ui_error_at: null
});

} catch (e) {
  if (typeof output !== 'undefined' && output && output.set) {
    output.set('error', (e && e.message) ? e.message : String(e));
  }
}
