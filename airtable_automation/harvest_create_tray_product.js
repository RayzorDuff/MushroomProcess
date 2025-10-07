/**
 * Harvest – Create Tray Product
 * Trigger: Form submit or button on `products`
 * Assumes: item_id is a tray (fresh_tray or freezer_tray), source_block_id links to fruiting block, net_weight_g, flush_no
 * Sets tray_state based on item category, populates label fields if you maintain them, sets public_link (optional)
 */
const productsTbl = base.getTable('products');
const itemsTbl = base.getTable('items');

const { productRecordId } = input.config();
if (!productRecordId) { throw new Error('Missing productRecordId'); }
const prod = await productsTbl.selectRecordAsync(productRecordId);
if (!prod) { throw new Error('Product not found'); }

const itemLink = prod.getCellValue('item_id')?.[0];
if (!itemLink){ throw new Error('item_id (tray) required'); }
const item = await itemsTbl.selectRecordAsync(itemLink.id);
const cat = (item?.getCellValueAsString('category') || '').toLowerCase();
let trayState = '';
if (cat === 'fresh_tray') trayState = 'fresh_tray';
else if (cat === 'freezer_tray') trayState = 'freezer_tray';

await productsTbl.updateRecordAsync(productRecordId, { tray_state: trayState });
output.set('ok', true);
