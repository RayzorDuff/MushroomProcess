/**
 * Script: lc_receive_syringe.js
 * Version: 2025-10-16.1
 * Summary: Airtable automation script with resilience guards.
 * Notes: Succinct header; no diff blocks; try/catch + error surfacing.
 */
try {


const { stagingId } = input.config();

const lotsTbl   = base.getTable('lots');
const eventsTbl = base.getTable('events');

// Load staging row
const staging = await lotsTbl.selectRecordAsync(stagingId);
if (!staging) throw new Error('Staging lot not found');

// ---- Read inputs from the staging record ----
const itemLink   = staging.getCellValue('item_id')?.[0] ?? null;  // link to items
const count      = Number(staging.getCellValue('receive_count') ?? NaN);
const vendor     = staging.getCellValueAsString('vendor_name') || '';
const vendorBatch= staging.getCellValueAsString('vendor_batch') || '';
const recDate    = staging.getCellValue('received_date') || null; // date cell if set
const srcType    = staging.getCellValueAsString('source_type') || 'Purchased';

// Volume inputs (support new generic fields and legacy syringe-specific)
const volFromTotal    = Number(staging.getCellValue('total_volume_ml') ?? NaN);
const volFromSyrField = Number(staging.getCellValue('syringe_volume_ml') ?? NaN); // legacy
const defaultSyrVol   = 10;
const unitVol = Number.isFinite(volFromTotal)
  ? volFromTotal
  : (Number.isFinite(volFromSyrField) ? volFromSyrField : defaultSyrVol);

// Determine category from a visible field if you have one; otherwise skip
const itemCategory = staging.getCellValueAsString('item_category')?.toLowerCase()
  || ''; // optional lookup on lots

// ---- Validate inputs ----
const errs = [];
if (!itemLink) errs.push('Select an item (lc_syringe or lc_flask).');
if (!Number.isFinite(count) || count < 1) errs.push('receive_count must be ≥ 1.');
if (!Number.isFinite(unitVol) || unitVol <= 0) errs.push('Unit volume (ml) must be a positive number.');

if (errs.length) {
  const msg = errs.join(' ');
  await lotsTbl.updateRecordAsync(staging.id, {
    ui_error: msg,
    ui_error_at: new Date().toISOString()
  });
  throw new Error(`Receiving validation failed: ${msg}`);
}
// Clear any prior UI error
await lotsTbl.updateRecordAsync(staging.id, { ui_error: null, ui_error_at: null });

// ---- Resolve status & event choices ----
const statusField = lotsTbl.getField('status');
const choices = statusField.options?.choices || [];
// For syringes/flasks received, we typically start as "Sealed"
const sealedChoice = choices.find(c => c.name === 'Sealed');
if (!sealedChoice) {
  const names = choices.map(c => c.name).join(', ');
  throw new Error(`Lots.status missing "Sealed". Has: ${names}`);
}

const evtTypeField = eventsTbl.getField('type');
const evtChoices = evtTypeField.options?.choices || [];
const receivedEvt = evtChoices.find(c => c.name === 'Received');
if (!receivedEvt) {
  const names = evtChoices.map(c => c.name).join(', ');
  throw new Error(`Events.type missing "Received". Has: ${names}`);
}

const tsWritable = (() => { try { return eventsTbl.getField('timestamp').type === 'dateTime'; } catch { return false; }})();
const nowIso = new Date().toISOString();

// ---- Build unit lot fields ----
function unitLotFields() {
  const f = {
    qty: 1,
    status: { id: sealedChoice.id },
    item_id: [{ id: itemLink.id }],
    // Track capacities for both syringes and flasks
    total_volume_ml: unitVol,
    remaining_volume_ml: unitVol,
    source_type: srcType,
    vendor_name: vendor || null,
    vendor_batch: vendorBatch || null
  };

  // Write created_at if you use a writable dateTime field (skip if Created time)
  try { if (lotsTbl.getField('created_at').type === 'dateTime') f.created_at = nowIso; } catch {}
  // Store received_date if provided via form
  if (recDate) f.received_date = recDate;

  // If you keep a storage_location link to "Fridge", set it here (optional):
  // const fridge = staging.getCellValue('storage_location')?.[0] ?? null;
  // if (fridge) f.storage_location = [{ id: fridge.id }];

  return f;
}

// ---- Create unit lots in batches ----
const createdLotIds = [];
let remaining = count;
while (remaining > 0) {
  const batch = Math.min(remaining, 50);
  const payload = Array.from({ length: batch }, () => ({ fields: unitLotFields() }));
  const ids = await lotsTbl.createRecordsAsync(payload);
  createdLotIds.push(...ids);
  remaining -= batch;
}

// ---- Create a Received event per unit (good for traceability) ----
for (let i = 0; i < createdLotIds.length; i += 50) {
  const slice = createdLotIds.slice(i, i + 50);
  await eventsTbl.createRecordsAsync(slice.map(id => {
    const e = {
      fields: {
        lot_id: [{ id }],
        type: { id: receivedEvt.id },
        station: 'Receiving',
        fields_json: JSON.stringify({
          vendor_name: vendor || null,
          vendor_batch: vendorBatch || null,
          unit_volume_ml: unitVol
        })
      }
    };
    if (tsWritable) e.fields.timestamp = nowIso;
    return e;
  }));
}

// ---- Neutralize the staging row so it won't re-trigger ----
await lotsTbl.updateRecordAsync(staging.id, {
  receive_count: 0
  // If you also set action/flags, clear them here too (e.g., action: null)
});

output.set('created_count', createdLotIds.length);

} catch (e) {
  if (typeof output !== 'undefined' && output && output.set) {
    output.set('error', (e && e.message) ? e.message : String(e));
  }
}
