/**
 *  Script: sync_ecommerce_to_ecwid.js
 *  Purpose: Read ecommerce mapping table in Airtable and push inventory
 *           quantities to Ecwid (store 95802503) by SKU.
 *
 *  Usage:
 *    npm install node-fetch@2 dotenv
 *    node sync_ecommerce_to_ecwid.js
 */

const {
  assertCommonEnv,
  airtableFetchAllRecords,
  findEcwidProductBySku,
  updateEcwidBaseProductQuantity,
  updateEcwidVariationQuantity,
} = require('./lib/ecwid_airtable');

const {
  AIRTABLE_ECOMMERCE_TABLE,
  AIRTABLE_ECOMMERCE_SKU_FIELD,
  AIRTABLE_ECOMMERCE_QTY_FIELD,
  AIRTABLE_ECOMMERCE_ACTIVE_FIELD,
} = process.env;

function assertEnv() {
  const required = [
    'AIRTABLE_ECOMMERCE_TABLE',
    'AIRTABLE_ECOMMERCE_SKU_FIELD',
    'AIRTABLE_ECOMMERCE_QTY_FIELD',

  ];

  const missing = required.filter((k) => !process.env[k]);
  if (missing.length) {
    console.error('Missing required env vars:', missing.join(', '));
    process.exit(1);
  }
}

assertCommonEnv();
assertEnv();



// ---------- Sync logic ----------

function shouldSkipRecord(record) {
  const fields = record.fields || {};

  const sku = fields[AIRTABLE_ECOMMERCE_SKU_FIELD];
  const qtyRaw = fields[AIRTABLE_ECOMMERCE_QTY_FIELD];

  if (!sku || String(sku).trim() === '') return true;

  const quantity = Number(qtyRaw);
  if (!Number.isFinite(quantity) || quantity < 0) return true;


  return false;
}

async function syncRecord(record) {
  const fields = record.fields || {};
  const sku = String(fields[AIRTABLE_ECOMMERCE_SKU_FIELD]).trim();
  const quantity = Number(fields[AIRTABLE_ECOMMERCE_QTY_FIELD]);

  console.log(`\nSyncing record ${record.id}: SKU=${sku} => quantity=${quantity}`);

  const { product, variation } = await findEcwidProductBySku(sku);

  if (!product) {
    console.warn(`  No Ecwid product found for SKU ${sku}. Skipping.`);
    return;
  }

  if (!variation) {
    console.log(`  Updating base product ID ${product.id}`);
    await updateEcwidBaseProductQuantity(product.id, quantity);
  } else {
    console.log(
      `  Updating variation combinationId=${variation.id} of product ID ${product.id}`
    );
    await updateEcwidVariationQuantity(product.id, variation.id, quantity);
  }

  console.log('  ✅ Updated successfully');
}

async function main() {
  try {
    console.log(
      `Fetching ecommerce records from table "${AIRTABLE_ECOMMERCE_TABLE}"`
    );
    const records = await airtableFetchAllRecords(AIRTABLE_ECOMMERCE_TABLE);
    console.log(`Fetched ${records.length} raw records.`);

    const usable = records.filter((r) => !shouldSkipRecord(r));
    console.log(`Found ${usable.length} record(s) to sync.`);

    for (const record of usable) {
      try {
        await syncRecord(record);
      } catch (err) {
        console.error(
          `Error syncing record ${record.id} (SKU=${record.fields?.[AIRTABLE_ECOMMERCE_SKU_FIELD]}):`,
          err.message
        );
      }
    }

    console.log('\nDone.');
  } catch (err) {
    console.error('Fatal error:', err.message);
    process.exit(1);
  }
}

main();
