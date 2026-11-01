#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');

const repoRoot = path.resolve(__dirname, '..', '..');
const workflowPath = path.join(
  repoRoot,
  'n8n',
  'workflows',
  'MushroomProcess - Ecwid Order Updated - PGSQL.json',
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

assert(workflow.active === false, 'PGSQL workflow must import inactive');
assert(
  node('Webhook - Ecwid Order Updated').parameters.path === 'mushroomprocess/ecwid/order_updated',
  'Webhook path changed during PGSQL port',
);
assert(
  !workflow.nodes.some((entry) => JSON.stringify(entry).toLowerCase().includes('airtable')),
  'PGSQL workflow still contains an Airtable node, credential, or environment reference',
);

const pgNode = node('PGSQL - Upsert Ecwid Order');
assert(pgNode.type === 'n8n-nodes-base.postgres', 'Upsert node is not PostgreSQL');
assert(
  pgNode.parameters.query.includes('mp_ecommerce_order_upsert'),
  'PostgreSQL node does not call mp_ecommerce_order_upsert',
);
assert(
  pgNode.credentials?.postgres?.name === 'Postgres account 2',
  'PostgreSQL credential does not match current MushroomProcess workflows',
);

const validateCode = node('Code - Validate / Filter Webhook').parameters.jsCode;
const validate = new Function('$json', validateCode);

const created = validate({
  body: {
    eventId: 'evt-created',
    eventCreated: 1785175200,
    storeId: 123,
    eventType: 'order.created',
    entityId: 900001,
    data: {
      orderId: 'ABCD1',
      newPaymentStatus: 'AWAITING_PAYMENT',
    },
  },
})[0].json;
assert(created.shouldProcess === true, 'Awaiting-payment order.created was ignored');

const unchanged = validate({
  body: {
    eventId: 'evt-unchanged',
    eventCreated: 1785175200,
    storeId: 123,
    eventType: 'order.updated',
    entityId: 900001,
    data: {
      orderId: 'ABCD1',
      oldPaymentStatus: 'AWAITING_PAYMENT',
      newPaymentStatus: 'AWAITING_PAYMENT',
    },
  },
})[0].json;
assert(unchanged.shouldProcess === false, 'Unchanged awaiting-payment update was processed');

// Regression: paid-at-creation must not depend on an earlier unpaid webhook.
const cases = [
  ['order.created', null, 'PAID', true],
  ['order.created', null, 'AWAITING_PAYMENT', true],
  ['order.updated', 'AWAITING_PAYMENT', 'PAID', true],
  ['order.updated', 'PAID', 'AWAITING_PAYMENT', true],
  ['order.updated', 'PAID', 'PAID', false],
  ['order.updated', 'AWAITING_PAYMENT', 'AWAITING_PAYMENT', false],
  ['order.created', null, 'CANCELLED', false],
  ['order.deleted', 'AWAITING_PAYMENT', 'PAID', false],
];
for (const [eventType, oldPaymentStatus, newPaymentStatus, expected] of cases) {
  const event = {
    eventId: 'synthetic-paid-regression',
    eventCreated: 1793404800,
    storeId: 123,
    eventType,
    entityId: 900002,
    data: { orderId: 'SYNTHETIC-PAID', oldPaymentStatus, newPaymentStatus },
  };
  const result = validate({ body: event })[0].json;
  assert(result.shouldProcess === expected, `Incorrect intake: ${JSON.stringify(event.data)}`);
  assert(result.ecwid_entity_id === '900002', 'Numeric source identity changed');
  assert(result.order_code === 'SYNTHETIC-PAID', 'Display order code changed');
  assert(result.eventId === event.eventId, 'Retry source identity changed');
  assert(
    JSON.stringify(result) === JSON.stringify(validate({ body: event })[0].json),
    'Repeated delivery changed normalized event',
  );
}
assert(
  validate({ body: { eventType: 'order.created', data: { newPaymentStatus: 'PAID' } } })[0]
    .json.shouldProcess === false,
  'Paid event without source order ID was accepted',
);

const mapCode = node('Code - Map Ecwid Order to PostgreSQL Fields').parameters.jsCode;
const map = new Function('$json', '$', mapCode);
const mapped = map(
  {
    id: 900001,
    orderNumber: 'ABCD1',
    fulfillmentStatus: 'AWAITING_PROCESSING',
    paymentStatus: 'AWAITING_PAYMENT',
    paymentMethod: 'Online Card',
    createDate: '2026-07-27T18:30:00.000Z',
    billingPerson: { name: 'Test Customer', email: 'customer@example.invalid' },
    items: [
      { sku: 'SKU-1', quantity: 1 },
      { sku: 'SKU-1', quantity: 2 },
      { sku: 'SKU-2', quantity: 1 },
    ],
    subtotal: 20,
    tax: 1.6,
    total: 21.6,
    currency: 'USD',
  },
  (name) => {
    assert(name === 'Code - Validate / Filter Webhook', `Unexpected node lookup: ${name}`);
    return { first: () => ({ json: created }) };
  },
)[0].json;

assert(mapped.ecwid_order_id === '900001', 'Numeric Ecwid ID was not mapped as text');
assert(mapped.order_code === 'ABCD1', 'Human-facing order code was not mapped');
assert(mapped.customer_name === 'Test Customer', 'Customer name mapping failed');
assert(mapped.ecwid_skus === 'SKU-1, SKU-2', 'SKU de-duplication failed');
assert(mapped.provider === 'ecwid', 'Provider-neutral provider alias missing');
assert(mapped.site_key === 'dank_mushrooms', 'Provider-neutral site key missing');
assert(mapped.external_order_id === '900001', 'Provider-neutral external order ID missing');
assert(mapped.external_skus === 'SKU-1, SKU-2', 'Provider-neutral SKU aliases missing');
assert(mapped.clover_reconciliation_status === 'pending', 'New order reconciliation was not reset to pending');
assert(mapped.ecwid_event_id === 'evt-created', 'Webhook event ID was not preserved');

const paidCreated = validate({
  body: {
    eventId: 'synthetic-paid-created',
    entityId: 900002,
    eventType: 'order.created',
    data: { orderId: 'SYNTHETIC-PAID', newPaymentStatus: 'PAID' },
  },
})[0].json;
const paidMapped = map(
  { id: 900002, orderNumber: 'SYNTHETIC-PAID', paymentStatus: 'PAID', items: [] },
  () => ({ first: () => ({ json: paidCreated }) }),
)[0].json;
assert(paidMapped.payment_status === 'PAID', 'Initial paid state was dropped by mapping');
assert(paidMapped.external_order_id === '900002', 'Paid source identity was lost');
assert(paidMapped.ecwid_event_id === 'synthetic-paid-created', 'Paid event ID was lost');
assert(
  paidMapped.clover_reconciliation_status === 'pending',
  'Paid storefront event must not assert independent Clover reconciliation',
);

const encodeCode = node('Code - Encode PostgreSQL Payload').parameters.jsCode;
const encode = new Function('$json', 'Buffer', encodeCode);
const encoded = encode(mapped, Buffer)[0].json;
const decoded = JSON.parse(Buffer.from(encoded.payload_base64, 'base64').toString('utf8'));
assert(decoded.ecwid_order_id === mapped.ecwid_order_id, 'Base64 payload round-trip failed');
assert(decoded.items_json === mapped.items_json, 'Items JSON changed during payload encoding');

console.log('Ecwid Order Updated PGSQL workflow structure, filtering, mapping, and payload smoke tests passed.');
