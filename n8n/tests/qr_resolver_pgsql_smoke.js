#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');
const vm = require('vm');

const workflowPath = path.join(
  __dirname,
  '..',
  'workflows',
  'MushroomProcess - QR Resolver - PGSQL.json'
);

function fail(message) {
  throw new Error(message);
}

const workflow = JSON.parse(fs.readFileSync(workflowPath, 'utf8'));
const nodes = new Map(workflow.nodes.map((node) => [node.name, node]));

for (const required of [
  'Webhook - Resolve QR',
  'Code - Normalize QR Identifier',
  'IF - Identifier Valid?',
  'PGSQL - Resolve Inventory',
  'Code - Prepare QR Response',
  'IF - Redirect?',
  'Respond - Redirect',
  'Respond - QR Error',
]) {
  if (!nodes.has(required)) fail(`Missing required node: ${required}`);
}

const webhook = nodes.get('Webhook - Resolve QR');
if (webhook.parameters.httpMethod !== 'GET') fail('QR resolver webhook must use GET');
if (webhook.parameters.path !== 'mushroomprocess/qr/resolve') {
  fail(`Unexpected webhook path: ${webhook.parameters.path}`);
}
if (webhook.parameters.responseMode !== 'responseNode') {
  fail('QR resolver webhook must respond through Respond to Webhook nodes');
}

const pg = nodes.get('PGSQL - Resolve Inventory');
if (!String(pg.parameters.query).includes('public.mp_qr_resolve_inventory')) {
  fail('PostgreSQL node does not call mp_qr_resolve_inventory');
}
if (!String(pg.parameters.query).includes("decode('${String($json.inventory_id_b64")) {
  fail('PostgreSQL resolver query must transport the identifier via base64');
}

const redirect = nodes.get('Respond - Redirect');
if (redirect.parameters.respondWith !== 'redirect') fail('Success response must be a redirect');
if (Number(redirect.parameters.options.responseCode) !== 302) fail('Success redirect must use HTTP 302');
if (!String(redirect.parameters.redirectURL).includes('$json.redirect_url')) {
  fail('Redirect response must use the prepared redirect URL');
}

const redirectHeaders = redirect.parameters.options?.responseHeaders?.entries || [];
const cacheHeader = redirectHeaders.find((entry) => String(entry.name).toLowerCase() === 'cache-control');
if (!cacheHeader || !String(cacheHeader.value).includes('no-store')) {
  fail('Redirect must disable caching so provider changes do not strand printed QR codes');
}

const normalizeCode = nodes.get('Code - Normalize QR Identifier').parameters.jsCode;
const prepareCode = nodes.get('Code - Prepare QR Response').parameters.jsCode;

function runCode(code, json, env = {}) {
  const context = {
    $json: json,
    $env: env,
    Buffer,
    URL,
  };
  return vm.runInNewContext(`(function () {\n${code}\n})()`, context);
}

let out = runCode(normalizeCode, { query: { i: 'PROD-260419-bDew' } });
if (!Array.isArray(out) || out[0]?.json?.valid_id !== true) {
  fail('Valid Product identifier was rejected by normalization');
}
if (Buffer.from(out[0].json.inventory_id_b64, 'base64').toString('utf8') !== 'PROD-260419-bDew') {
  fail('Product identifier base64 transport changed the identifier');
}

out = runCode(normalizeCode, { query: { i: 'not-an-inventory-id' } });
if (out[0]?.json?.valid_id !== false || out[0]?.json?.response_code !== 400) {
  fail('Invalid identifier was not rejected with HTTP 400 preparation');
}

out = runCode(
  prepareCode,
  {
    status: 'ok',
    entity_type: 'product',
    inventory_id: 'PROD-260419-bDew',
    public_url: 'https://danks.store/products/example?existing=1',
  },
  { MP_APP_LOTS_URL: 'https://appsmith.danks.store/app/mushroomprocess/lots' }
);
const productUrl = new URL(out[0].json.redirect_url);
if (out[0].json.response_code !== 302 || out[0].json.should_redirect !== true) {
  fail('Product resolution did not prepare a 302 redirect');
}
if (productUrl.searchParams.get('existing') !== '1'
    || productUrl.searchParams.get('mp_product') !== 'PROD-260419-bDew'
    || productUrl.searchParams.get('source') !== 'qr') {
  fail(`Product redirect query parameters are wrong: ${productUrl}`);
}

out = runCode(
  prepareCode,
  {
    status: 'ok',
    entity_type: 'lot',
    inventory_id: 'LOT-260807-AbCd',
  },
  { MP_APP_LOTS_URL: 'https://appsmith.danks.store/app/mushroomprocess/lots?existing=1' }
);
const lotUrl = new URL(out[0].json.redirect_url);
if (lotUrl.searchParams.get('existing') !== '1'
    || lotUrl.searchParams.get('lot') !== 'LOT-260807-AbCd'
    || lotUrl.searchParams.get('source') !== 'qr') {
  fail(`Lot redirect query parameters are wrong: ${lotUrl}`);
}

out = runCode(
  prepareCode,
  { status: 'product_unmapped', entity_type: 'product', inventory_id: 'PROD-X', message: 'unmapped' },
  {}
);
if (out[0].json.should_redirect !== false || out[0].json.response_code !== 404) {
  fail('Unmapped Product should prepare a 404 response');
}

out = runCode(
  prepareCode,
  { status: 'ok', entity_type: 'lot', inventory_id: 'LOT-X' },
  {}
);
if (out[0].json.should_redirect !== false || out[0].json.response_code !== 503) {
  fail('Lot resolution without MP_APP_LOTS_URL should prepare a 503 response');
}

console.log('QR Resolver PGSQL workflow structure, identifier handling, Product/Lot redirects, and error smoke tests passed.');
