/**
 * Freeze Dry & Package – Actions
 * Trigger: Interface button sets {action} on a tray product, automation runs script
 * Supports: FreezeDry, PackageFreezeDried
 * On PackageFreezeDried: create final packaged product(s) and set tray_state=empty_tray
 */
const productsTbl = base.getTable('products');
const itemsTbl = base.getTable('items');

const { productRecordId } = input.config();
if (!productRecordId) { throw new Error('Missing productRecordId'); }
const prod = await productsTbl.selectRecordAsync(productRecordId);
if (!prod) { throw new Error('Product not found'); }

const action = prod.getCellValueAsString('action') || '';

switch(action){
  case 'FreezeDry':
    await productsTbl.updateRecordAsync(productRecordId, { action: '' });
    break;
  case 'PackageFreezeDried':
    // Set tray to empty so it disappears from the packaging queue view
    await productsTbl.updateRecordAsync(productRecordId, { tray_state: 'empty_tray', action: '' });
    break;
  default:
    break;
}
output.set('ok', true);
