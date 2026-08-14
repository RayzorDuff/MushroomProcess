#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');

const repoRoot = path.resolve(__dirname, '..', '..');
const workflowPath = path.join(
  repoRoot,
  'n8n',
  'workflows',
  'MushroomProcess - Ecwid Catalog Sync - PGSQL.json',
);
const workflow = JSON.parse(fs.readFileSync(workflowPath, 'utf8'));

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function node(name) {
  const found = workflow.nodes.find((entry) => entry.name === name);
  assert(found, `Missing workflow node: ${name}`);
  return found;
}

assert(workflow.active === false, 'Ecwid catalog PGSQL workflow must import inactive');
assert(
  !workflow.nodes.some((entry) => JSON.stringify(entry).toLowerCase().includes('airtable')),
  'Ecwid catalog PGSQL workflow still contains an Airtable node, credential, or environment reference',
);

const schedule = node('Schedule - Hourly Ecwid Catalog Sync');
const interval = schedule.parameters?.rule?.interval?.[0] || {};
assert(interval.field === 'hours', 'Catalog sync schedule is not hourly');
assert(Number(interval.hoursInterval) === 1, 'Catalog sync interval is not one hour');

const candidateNode = node('PGSQL - Load Ecwid Catalog Sync Candidates');
assert(candidateNode.type === 'n8n-nodes-base.postgres', 'Candidate node is not PostgreSQL');
assert(
  candidateNode.parameters.query.includes('mp_ecommerce_ecwid_catalog_sync_candidates'),
  'Candidate node does not call the PostgreSQL catalog candidate function',
);
assert(
  candidateNode.credentials?.postgres?.name === 'Postgres account 2',
  'Candidate PostgreSQL credential does not match current MushroomProcess workflows',
);

const findNode = node('HTTP - Find Ecwid Product by SKU');
assert(
  findNode.parameters.url.includes('ECWID_STORE_ID'),
  'Ecwid search URL does not use ECWID_STORE_ID',
);
assert(
  JSON.stringify(findNode.parameters).includes('ECWID_SECRET_TOKEN'),
  'Ecwid search node does not use ECWID_SECRET_TOKEN',
);
assert(
  JSON.stringify(findNode.parameters.queryParameters).includes('external_sku'),
  'Ecwid search node does not search by provider-neutral external_sku',
);

const resolveCode = node('Code - Resolve Ecwid SKU Target').parameters.jsCode;
const resolve = new Function('$json', '$', resolveCode);
const candidate = {
  ecommerce_id: 55,
  ecommerce_name: 'Test Listing',
  ecommerce_status: 'FullyColonized',
  provider: 'ecwid',
  site_key: 'dank_mushrooms',
  external_sku: 'VAR-SKU',
  upc: null,
  available_from_products: 2,
  available_from_lots: 1,
  desired_quantity: 3,
};

const resolved = resolve(
  {
    items: [
      {
        id: 610274451,
        sku: 'BASE-SKU',
        url: 'https://example.invalid/products/test',
        categoryIds: [160277251],
        variations: [
          {
            id: 987654321,
            sku: 'VAR-SKU',
            price: 14.95,
            quantity: 2,
            attributes: [],
          },
        ],
      },
    ],
  },
  (name) => {
    assert(
      name === 'PGSQL - Load Ecwid Catalog Sync Candidates',
      `Unexpected node lookup from resolver: ${name}`,
    );
    return { item: { json: candidate } };
  },
).json;

assert(resolved.should_update === true, 'Exact variation SKU was not accepted');
assert(resolved.ecwid_product_id === '610274451', 'Parent Ecwid product ID was not captured');
assert(resolved.ecwid_variation_id === '987654321', 'Ecwid variation ID was not captured');
assert(resolved.ecwid_category === '160277251', 'Ecwid category was not captured');
assert(resolved.ecwid_url === 'https://example.invalid/products/test', 'Ecwid public URL was not captured');
assert(resolved.needs_upc_reservation === true, 'Missing UPC did not request a PostgreSQL reservation');

const attachCode = node('Code - Attach Reserved UPC').parameters.jsCode;
const attach = new Function('$json', '$', attachCode);
const attached = attach(
  { reserved_upc: '6865787501881' },
  (name) => {
    assert(name === 'Code - Resolve Ecwid SKU Target', `Unexpected attach lookup: ${name}`);
    return { item: { json: resolved } };
  },
).json;

assert(attached.ecwid_upc === '6865787501881', 'Reserved UPC was not attached');
assert(attached.needs_upc_write === true, 'Reserved UPC was not marked for Ecwid write');

const prepareCode = node('Code - Prepare Ecwid Update').parameters.jsCode;
const prepare = new Function('$json', '$env', prepareCode);
const prepared = prepare(attached, { ECWID_STORE_ID: '95802503' }).json;

assert(prepared.desired_quantity === 3, 'Desired quantity changed while preparing Ecwid update');
assert(
  prepared.update_url ===
    'https://app.ecwid.com/api/v3/95802503/products/610274451/combinations/987654321',
  'Variation update URL was not constructed correctly',
);
assert(prepared.update_body.quantity === 3, 'Ecwid update body has wrong quantity');
assert(prepared.update_body.unlimited === false, 'Ecwid update did not disable unlimited inventory');
assert(
  prepared.update_body.attributes?.[0]?.value === '6865787501881',
  'Reserved UPC was not included in Ecwid update body',
);

const encodeCode = node('Code - Encode Catalog Writeback').parameters.jsCode;
const encode = new Function('$json', '$', 'Buffer', encodeCode);
const encoded = encode(
  { id: 987654321, quantity: 3 },
  (name) => {
    assert(name === 'Code - Prepare Ecwid Update', `Unexpected writeback lookup: ${name}`);
    return { item: { json: prepared } };
  },
  Buffer,
).json;

const decoded = JSON.parse(Buffer.from(encoded.payload_base64, 'base64').toString('utf8'));
assert(decoded.ecommerce_id === 55, 'Writeback payload lost ecommerce_id');
assert(decoded.external_sku === 'VAR-SKU', 'Writeback payload lost SKU');
assert(decoded.external_product_id === '610274451', 'Writeback payload lost Ecwid product ID');
assert(decoded.external_variation_id === '987654321', 'Writeback payload lost Ecwid variation ID');
assert(decoded.external_stock === 3, 'Writeback payload lost desired stock');
assert(decoded.public_url === 'https://example.invalid/products/test', 'Writeback payload lost public URL');
assert(decoded.upc === '6865787501881', 'Writeback payload lost UPC');

const writebackNode = node('PGSQL - Persist Ecwid Catalog Metadata');
assert(
  writebackNode.parameters.query.includes('mp_ecommerce_ecwid_catalog_sync_writeback'),
  'Catalog metadata node does not call the PostgreSQL writeback function',
);

console.log(
  'Ecwid Catalog PGSQL workflow structure, exact-SKU resolution, inventory update, UPC, and writeback smoke tests passed.',
);
