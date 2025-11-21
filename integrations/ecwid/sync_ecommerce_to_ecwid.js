/**
 *  Script: sync_ecommerce_to_ecwid.js
 *  Purpose: Read ecommerce mapping table in Airtable and push inventory
 *           quantities to Ecwid (store 95802503) by SKU.
 *
 *  Usage:
 *    npm install node-fetch@2 dotenv
 *    node sync_ecommerce_to_ecwid.js
 */

const fetch = require('node-fetch');
require('dotenv').config();

const {
  AIRTABLE_API_KEY,
  AIRTABLE_BASE_ID,
  AIRTABLE_ECOMMERCE_TABLE,
  AIRTABLE_ECOMMERCE_VIEW,
  AIRTABLE_ECOMMERCE_SKU_FIELD,
  AIRTABLE_ECOMMERCE_QTY_FIELD,
  AIRTABLE_ECOMMERCE_ACTIVE_FIELD,
  ECWID_STORE_ID,
  ECWID_TOKEN,
} = process.env;

function assertEnv() {
  const required = [
    'AIRTABLE_API_KEY',
    'AIRTABLE_BASE_ID',
    'AIRTABLE_ECOMMERCE_TABLE',
    'AIRTABLE_ECOMMERCE_SKU_FIELD',
    'AIRTABLE_ECOMMERCE_QTY_FIELD',
    'ECWID_STORE_ID',
    'ECWID_TOKEN',
  ];

  const missing = required.filter((k) => !process.env[k]);
  if (missing.length) {
    console.error('Missing required env vars:', missing.join(', '));
    process.exit(1);
  }
}

assertEnv();

// ---------- Airtable helpers ----------

async function fetchEcommerceRecords() {
  const records = [];
  let offset = null;

  do {
    const params = new URLSearchParams({
      pageSize: '100',
    });

    if (AIRTABLE_ECOMMERCE_VIEW) {
      params.append('view', AIRTABLE_ECOMMERCE_VIEW);
    }
    if (offset) {
      params.append('offset', offset);
    }

    const url = `https://api.airtable.com/v0/${encodeURIComponent(
      AIRTABLE_BASE_ID
    )}/${encodeURIComponent(AIRTABLE_ECOMMERCE_TABLE)}?${params.toString()}`;

    const res = await fetch(url, {
      headers: {
        Authorization: `Bearer ${AIRTABLE_API_KEY}`,
      },
    });

    if (!res.ok) {
      const text = await res.text();
      throw new Error(`Airtable error (${res.status}): ${text}`);
    }

    const data = await res.json();
    records.push(...data.records);
    offset = data.offset;
  } while (offset);

  return records;
}

// ---------- Ecwid helpers ----------

async function ecwidRequest(path, options = {}) {
  const baseUrl = `https://app.ecwid.com/api/v3/${encodeURIComponent(
    ECWID_STORE_ID
  )}`;

  const res = await fetch(`${baseUrl}${path}`, {
    ...options,
    headers: {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${ECWID_TOKEN}`,
      ...(options.headers || {}),
    },
  });

  if (!res.ok) {
    const text = await res.text();
    throw new Error(`Ecwid error ${res.status} ${path}: ${text}`);
  }

  if (res.status === 204) return null;
  return res.json();
}

/**
 * Find Ecwid product (and possibly variation) by SKU.
 * Returns { product, variation } where variation may be null.
 */
async function findEcwidProductBySku(sku) {
  const params = new URLSearchParams({ sku });
  const data = await ecwidRequest(`/products?${params.toString()}`);

  if (!data.items || !Array.isArray(data.items) || data.items.length === 0) {
    return { product: null, variation: null };
  }

  const product = data.items[0];

  // Exact base product SKU match?
  if (product.sku === sku) {
    return { product, variation: null };
  }

  // Look through variations (combinations)
  if (Array.isArray(product.variations)) {
    const variation = product.variations.find((v) => v.sku === sku);
    if (variation) {
      return { product, variation };
    }
  }

  // Product found, but SKU didn't match base or a variation explicitly
  return { product, variation: null };
}

/**
 * Update base product quantity via Update Product API.
 */
async function updateEcwidBaseProductQuantity(productId, quantity) {
  const body = {
    quantity,
    unlimited: false,
  };

  return ecwidRequest(`/products/${productId}`, {
    method: 'PUT',
    body: JSON.stringify(body),
  });
}

/**
 * Update variation quantity via Update Product Variation API.
 */
async function updateEcwidVariationQuantity(productId, combinationId, quantity) {
  const body = {
    quantity,
    unlimited: false,
  };

  return ecwidRequest(
    `/products/${productId}/combinations/${combinationId}`,
    {
      method: 'PUT',
      body: JSON.stringify(body),
    }
  );
}

// ---------- Sync logic ----------

function shouldSkipRecord(record) {
  const fields = record.fields || {};

  const sku = fields[AIRTABLE_ECOMMERCE_SKU_FIELD];
  const qtyRaw = fields[AIRTABLE_ECOMMERCE_QTY_FIELD];

  if (!sku || String(sku).trim() === '') return true;

  const quantity = Number(qtyRaw);
  if (!Number.isFinite(quantity) || quantity < 0) return true;

  // Extra guard: optional active flag in addition to the view filter
  if (AIRTABLE_ECOMMERCE_ACTIVE_FIELD) {
    const active = Boolean(fields[AIRTABLE_ECOMMERCE_ACTIVE_FIELD]);
    if (!active) return true;
  }

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
      `Fetching ecommerce records from table "${AIRTABLE_ECOMMERCE_TABLE}" (view "${AIRTABLE_ECOMMERCE_VIEW || 'default'}")...`
    );
    const records = await fetchEcommerceRecords();
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
