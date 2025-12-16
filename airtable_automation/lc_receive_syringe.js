/**
 * Script: lc_receive_syringe.js
 * Version: 2025-12-15.2
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
 * Summary: LC Receive Syringe – intake a purchased syringe as an LC lot
 * Change: Receive exactly ONE syringe per run; remove receive_count usage.
 */
try {
  const { stagingId } = input.config();

  const lotsTbl = base.getTable("lots");
  const itemsTbl = base.getTable("items");
  const eventsTbl = base.getTable("events");
  
  function hasField(tbl, name) {
    try { tbl.getField(name); return true; } catch { return false; }
  }

  function coerceValueForField(table, fieldName, valueStr) {
    if (!valueStr) return null;
    const f = table.getField(fieldName);
    if (f.type === "singleSelect") return { name: valueStr };
    return valueStr; // singleLineText, etc.
  }  

  // Load staging row (this will be updated in-place)
  const staging = await lotsTbl.selectRecordAsync(stagingId);
  if (!staging) throw new Error("Staging lot not found");

  // ---- Read inputs from the staging record ----
  const itemLink = staging.getCellValue("item_id")?.[0] ?? null; // link to items
  const vendor = staging.getCellValueAsString("vendor_name") || "";
  const vendorBatch = staging.getCellValueAsString("vendor_batch") || "";
  const recDate = staging.getCellValue("received_date") || null; // date cell if set
  const srcType = staging.getCellValueAsString("source_type") || "Purchased";

  // Volume inputs
  const totalVolRaw = staging.getCellValue("total_volume_ml");
  const totalVol = Number.isFinite(Number(totalVolRaw)) ? Number(totalVolRaw) : 10;

  // ---- Validate inputs ----
  const errs = [];
  if (!itemLink) errs.push('Select an item in "item_id".');

  if (errs.length) {
    const msg = errs.join(" ");
    await lotsTbl.updateRecordAsync(staging.id, {
      ui_error: msg,
      ui_error_at: new Date().toISOString(),
    });
    throw new Error(`Receiving validation failed: ${msg}`);
  }

  // Clear UI error
  await lotsTbl.updateRecordAsync(staging.id, { ui_error: null, ui_error_at: null });

  // ---- Resolve select choices ----
  function mustFindChoice(tbl, fieldName, choiceName) {
    const field = tbl.getField(fieldName);
    const choices = field.options?.choices || [];
    const found = choices.find((c) => c.name === choiceName);
    if (!found) {
      const names = choices.map((c) => c.name).join(", ");
      throw new Error(`${tbl.name}.${fieldName} missing "${choiceName}". Has: ${names}`);
    }
    return found;
  }

  function findChoice(tbl, fieldName, choiceName) {
    const field = tbl.getField(fieldName);
    const choices = field.options?.choices || [];
    return choices.find((c) => c.name === choiceName) || null;
  }

  // lots.status -> Fridge
  const fridgeChoice = mustFindChoice(lotsTbl, "status", "Fridge");

  // lots.source_type -> by name (fallback Purchased)
  const sourceChoice =
    findChoice(lotsTbl, "source_type", srcType) ||
    findChoice(lotsTbl, "source_type", "Purchased") ||
    null;

  // lots.vendor_name -> match by name (optional)
  const vendorChoice = vendor ? findChoice(lotsTbl, "vendor_name", vendor) : null;

  // lots.action -> MoveToFridge (optional if you want to set it)
  const moveToFridgeChoice = findChoice(lotsTbl, "action", "MoveToFridge");

  // events.type -> Received
  const receivedEvt = mustFindChoice(eventsTbl, "type", "Received");

  // Write timestamp if field exists and is dateTime
  const nowIso = new Date().toISOString();
  let canWriteEventTs = false;
  try {
    canWriteEventTs = eventsTbl.getField("timestamp").type === "dateTime";
  } catch {
    canWriteEventTs = false;
  }

  // ---- Update staging lot IN-PLACE ----
  // Load item record for materialized fields (name/category)
  const itemRec = itemLink ? await itemsTbl.selectRecordAsync(itemLink.id) : null;
  const itemName = itemRec?.getCellValueAsString("name") || "";
  const itemCat  = itemRec?.getCellValueAsString("category") || "";  

  const lotUpdate = {
    qty: 1,
    status: { id: fridgeChoice.id },
    item_id: [{ id: itemLink.id }],
    total_volume_ml: totalVol,
    remaining_volume_ml: totalVol,

    // Single-selects must be objects
    source_type: sourceChoice ? { id: sourceChoice.id } : null,
    vendor_name: vendorChoice ? { id: vendorChoice.id } : null,
    vendor_batch: vendorBatch || null,

    // Optional: if you use action to drive UI buttons/automations
    action: moveToFridgeChoice ? { id: moveToFridgeChoice.id } : null,
  };
  
  // Materialize item fields (type-safe)
  if (hasField(lotsTbl, "item_name_mat")) {
    const v = coerceValueForField(lotsTbl, "item_name_mat", itemName);
    if (v != null) lotUpdate.item_name_mat = v;
  }
  if (hasField(lotsTbl, "item_category_mat")) {
    const v = coerceValueForField(lotsTbl, "item_category_mat", itemCat);
    if (v != null) lotUpdate.item_category_mat = v;
  }  

  // Optional date field
  if (recDate) lotUpdate.received_date = recDate;

  await lotsTbl.updateRecordAsync(staging.id, lotUpdate);

  // ---- Create ONE Received event linked to the SAME lot ----
  const evtFields = {
    lot_id: [{ id: staging.id }],
    type: { id: receivedEvt.id },
    station: "Receiving",
    fields_json: JSON.stringify({
      vendor_name: vendor || null,
      vendor_batch: vendorBatch || null,
      source_type: srcType || null,
      total_volume_ml: totalVol,
    }),
  };
  if (canWriteEventTs) evtFields.timestamp = nowIso;

  await eventsTbl.createRecordsAsync([{ fields: evtFields }]);

  output.set("updated_lot_id", staging.id);
  output.set("updated_count", 1);
} catch (e) {
  if (typeof output !== "undefined" && output?.set) {
    output.set("error", e?.message ? e.message : String(e));
  }
  throw e;
}
