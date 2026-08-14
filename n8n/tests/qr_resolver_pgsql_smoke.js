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
  'Code - Prepare QR Log',
  'PGSQL - Log QR Request',
  'Code - Restore QR Response',
  'IF - Redirect?',
  'Respond - Redirect',
  'Respond - QR Error',
]) {
  if (!nodes.has(required)) fail(`Missing required node: ${required}`);
}

const webhook = nodes.get('Webhook - Resolve QR');
if (webhook.parameters.httpMethod && webhook.parameters.httpMethod !== 'GET') fail('QR resolver webhook must use GET');
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
if (!String(pg.parameters.query).includes('request_context_b64')) {
  fail('PostgreSQL resolver query must preserve request context for analytics logging');
}

const pgLog = nodes.get('PGSQL - Log QR Request');
if (!String(pgLog.parameters.query).includes('public.mp_qr_log_scan')) {
  fail('QR logging node does not call mp_qr_log_scan');
}
if (!String(pgLog.parameters.query).includes('qr_log_payload_b64')) {
  fail('QR logging node must transport its JSON payload via base64');
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
const prepareLogCode = nodes.get('Code - Prepare QR Log').parameters.jsCode;
const restoreCode = nodes.get('Code - Restore QR Response').parameters.jsCode;

function runCode(code, json, env = {}) {
  const context = {
    $json: json,
    $env: env,
    Buffer,
    URL,
  };
  return vm.runInNewContext(`(function () {\n${code}\n})()`, context);
}

let out = runCode(normalizeCode, {
  query: { i: 'PROD-260419-bDew' },
  headers: {
    'cf-connecting-ip': '203.0.113.42',
    'cf-ipcountry': 'US',
    'cf-ipcity': 'Johnstown',
    'cf-region': 'Colorado',
    'cf-region-code': 'CO',
    'cf-timezone': 'America/Denver',
    'cf-iplatitude': '40.3369',
    'cf-iplongitude': '-104.9122',
    'cf-ray': 'test-ray-SJC',
    'user-agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 15_0) AppleWebKit/537.36 Chrome/140.0.0.0 Safari/537.36',
    'accept-language': 'en-US,en;q=0.9',
    'host': 'qr.danks.store'
  }
});
if (!Array.isArray(out) || out[0]?.json?.valid_id !== true) {
  fail('Valid Product identifier was rejected by normalization');
}
if (Buffer.from(out[0].json.inventory_id_b64, 'base64').toString('utf8') !== 'PROD-260419-bDew') {
  fail('Product identifier base64 transport changed the identifier');
}
const requestContext = JSON.parse(Buffer.from(out[0].json.request_context_b64, 'base64').toString('utf8'));
if (requestContext.client_ip !== '203.0.113.42'
    || requestContext.cf_city !== 'Johnstown'
    || requestContext.browser_name !== 'Chrome'
    || requestContext.os_name !== 'macOS'
    || requestContext.device_type !== 'desktop'
    || requestContext.request_host !== 'qr.danks.store') {
  fail(`QR request metadata normalization is wrong: ${JSON.stringify(requestContext)}`);
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
    route_kind: 'ecommerce',
  },
  {
    MP_APP_LOTS_URL: 'https://appsmith.danks.store/app/mushroomprocess/lots',
    MP_APP_PRODUCTS_URL: 'https://appsmith.danks.store/app/mushroomprocess/products',
    MP_REGULATED_BUSINESS_URL: 'https://rootedpsyche.org'
  }
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
    entity_type: 'product',
    inventory_id: 'PROD-TRAY-QR',
    route_kind: 'product_internal',
    item_category: 'freezer_tray',
  },
  { MP_APP_PRODUCTS_URL: 'https://appsmith.danks.store/app/mushroomprocess/products?existing=1' }
);
const productInternalUrl = new URL(out[0].json.redirect_url);
if (productInternalUrl.searchParams.get('existing') !== '1'
    || productInternalUrl.searchParams.get('product') !== 'PROD-TRAY-QR'
    || productInternalUrl.searchParams.get('source') !== 'qr') {
  fail(`Tray Product redirect query parameters are wrong: ${productInternalUrl}`);
}

out = runCode(
  prepareCode,
  {
    status: 'ok',
    entity_type: 'product',
    inventory_id: 'PROD-REG-FD',
    route_kind: 'regulated_business',
    regulated: true,
    item_category: 'freezedriedmushrooms',
  },
  { MP_REGULATED_BUSINESS_URL: 'https://rootedpsyche.org/' }
);
if (out[0].json.redirect_url !== 'https://rootedpsyche.org/') {
  fail(`Regulated freeze-dried Product should use the base regulated business URL: ${out[0].json.redirect_url}`);
}

out = runCode(
  prepareCode,
  { status: 'ok', entity_type: 'product', inventory_id: 'PROD-TRAY-X', route_kind: 'product_internal' },
  {}
);
if (out[0].json.should_redirect !== false || out[0].json.response_code !== 503) {
  fail('Internal tray Product without MP_APP_PRODUCTS_URL should prepare a 503 response');
}

out = runCode(
  prepareCode,
  { status: 'ok', entity_type: 'product', inventory_id: 'PROD-REG-X', route_kind: 'regulated_business' },
  {}
);
if (out[0].json.should_redirect !== false || out[0].json.response_code !== 503) {
  fail('Regulated Product without MP_REGULATED_BUSINESS_URL should prepare a 503 response');
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

const analyticsContext = {
  client_ip: '203.0.113.42',
  cf_country: 'US',
  cf_city: 'Johnstown',
  browser_name: 'Chrome',
  os_name: 'macOS',
  device_type: 'desktop',
  query_json: { i: 'PROD-260419-bDew' },
  source: 'qr'
};
out = runCode(prepareLogCode, {
  status: 'ok',
  entity_type: 'product',
  entity_nocopk: 123,
  inventory_id: 'PROD-260419-bDew',
  route_kind: 'ecommerce',
  response_code: 302,
  should_redirect: true,
  redirect_url: 'https://danks.store/products/example?mp_product=PROD-260419-bDew&source=qr',
  company_key: 'primary',
  company_name: 'Dank Mushrooms',
  ecommerce_id: 16,
  provider: 'ecwid',
  site_key: 'dank_mushrooms',
  request_context_b64: Buffer.from(JSON.stringify(analyticsContext), 'utf8').toString('base64')
});
const logPayload = JSON.parse(Buffer.from(out[0].json.qr_log_payload_b64, 'base64').toString('utf8'));
if (logPayload.inventory_id !== 'PROD-260419-bDew'
    || logPayload.client_ip !== '203.0.113.42'
    || logPayload.destination_url.indexOf('danks.store') < 0
    || logPayload.success !== true
    || logPayload.company_name !== 'Dank Mushrooms') {
  fail(`Prepared QR analytics payload is wrong: ${JSON.stringify(logPayload)}`);
}
const passthrough = JSON.parse(Buffer.from(out[0].json.response_passthrough_b64, 'base64').toString('utf8'));
if (passthrough.should_redirect !== true || passthrough.response_code !== 302) {
  fail('QR analytics preparation did not preserve the HTTP response payload');
}

out = runCode(restoreCode, { response_json: passthrough, qr_scan_log_id: 777 });
if (out[0].json.redirect_url !== passthrough.redirect_url || out[0].json.qr_scan_log_id !== 777) {
  fail('QR response restoration after analytics logging failed');
}

console.log('QR Resolver PGSQL workflow structure, routing, request analytics capture, persistence handoff, and response restoration smoke tests passed.');
