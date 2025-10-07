/**
 * LC Receive Syringe – intake a purchased syringe as an LC lot
 * Trigger: Form submit or button → Run a script
 * Input: { syringeItemId, strainId }  (or use current record if creating directly on lots)
 * Writes errors to lots.ui_error on the created record (if desired).
 *
 * If you're running this directly on a new lots record (preferred), instead pass: { lotRecordId }
 * and just set item_id + strain_id on the record beforehand; the script will set defaults.
 */
const lotsTbl   = base.getTable('lots');

const { lotRecordId, syringeItemId, strainId } = input.config();

if (lotRecordId){
  // Update existing record with defaults
  await lotsTbl.updateRecordAsync(lotRecordId, {
    remaining_volume_ml: 10,
    status: { name: 'Fridge' }
  });
  output.set('created', lotRecordId);
  return;
}

// alternative path: create new
if (!syringeItemId || !strainId){ throw new Error('Provide syringeItemId and strainId or use lotRecordId path.'); }
const rec = await lotsTbl.createRecordAsync({
  item_id: [{ id: syringeItemId }],
  strain_id: [{ id: strainId }],
  remaining_volume_ml: 10,
  status: { name: 'Fridge' }
});
output.set('created', rec);
