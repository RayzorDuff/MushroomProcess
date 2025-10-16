

/***** Harvest -> create a Fresh/Freezer Tray product with tray_state *****/
const { blockLotId } = input.config();

const lotsTbl     = base.getTable('lots');
const itemsTbl    = base.getTable('items');
const productsTbl = base.getTable('products');
const eventsTbl   = base.getTable('events');

//for (const f of productsTbl.fields) {
//  console.log('products', `${f.id} :: ${f.name} [${f.type}]`);
//}

//for (const e of eventsTbl.fields) {
//  console.log('events', `${e.id} :: ${e.name} [${e.type}]`);
//}

const block = await lotsTbl.selectRecordAsync(blockLotId);
if (!block) throw new Error('Fruiting block not found');

const weightG     = Number(block.getCellValue('harvest_weight_g') ?? NaN);
const flushNo     = Number(block.getCellValue('flush_no') ?? NaN);
const harvestItem = block.getCellValue('harvest_item')?.[0] || null;

const errs = [];
if (!Number.isFinite(weightG) || weightG <= 0) errs.push('Enter harvest_weight_g (positive).');
if (!Number.isFinite(flushNo) || flushNo <= 0) errs.push('Enter flush_no (1,2,3…).');
if (!harvestItem) errs.push('Select harvest_item.');
if (errs.length) {
  const msg = errs.join(' ');
  await lotsTbl.updateRecordAsync(block.id, { ui_error: msg, ui_error_at: new Date().toISOString(), action: null });
  throw new Error(`Harvest validation failed: ${msg}`);
}

// Look up the harvest item's category to seed tray_state
const itemRec = await itemsTbl.selectRecordAsync(harvestItem.id);
const itemCat = itemRec?.getCellValueAsString('category')?.toLowerCase() || '';
if (!['fresh_tray','freezer_tray'].includes(itemCat)) {
  // allow it but warn on the record; default to freezer_tray to keep the flow moving
  await lotsTbl.updateRecordAsync(block.id, { ui_error: `harvest_item.category "${itemCat}" not in {fresh_tray, freezer_tray}. Defaulting tray_state=freezer_tray.` });
}

const productsTrayStateField = productsTbl.getField('tray_state');
const trayChoice = (productsTrayStateField.options?.choices || [])
  .find(c => c.name === (['fresh_tray','freezer_tray'].includes(itemCat) ? itemCat : 'freezer_tray'));
if (!trayChoice) throw new Error('products.tray_state missing one of: fresh_tray, freezer_tray.');

// Optional: copy strain from block (purely for display via lookups you already added)
const srcStrain = block.getCellValue('strain_id')?.[0] || null;

const nowIso = new Date().toISOString();
const prodFields = {
  item_id: [{ id: harvestItem.id }],
  origin_lot_ids_json: JSON.stringify([block.id]),
  origin_lots: [{ id: block.id }],
  net_weight_g: weightG,
  pack_date: nowIso,
  tray_state: { id: trayChoice.id }
};
//if (srcStrain) prodFields.strain_id = [{ id: srcStrain.id }]; // remove if you kept Option A strictly lookup-only

const [productId] = await productsTbl.createRecordsAsync([{ fields: prodFields }]);

// Log HARVEST on the source lot
const evtTypeField = eventsTbl.getField('type');
const harvestEvt = (evtTypeField.options?.choices || []).find(c => c.name === 'Harvest');
const tsWritable = (() => { try { return eventsTbl.getField('timestamp').type === 'dateTime'; } catch { return false; }})();
if (harvestEvt) {
  const e = {
    fields: {
      lot_id: [{ id: block.id }],
      type: { id: harvestEvt.id },
      station: 'Harvest',
      fields_json: JSON.stringify({ created_product_id: productId, harvest_weight_g: weightG, flush_no: flushNo })
    }
  };
  if (tsWritable) e.fields.timestamp = nowIso;
  await eventsTbl.createRecordsAsync([e]);
}

// Clear trigger/error
await lotsTbl.updateRecordAsync(block.id, { action: null, ui_error: null, ui_error_at: null });
