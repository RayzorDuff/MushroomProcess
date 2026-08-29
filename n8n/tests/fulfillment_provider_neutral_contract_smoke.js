#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');

const repoRoot = path.resolve(__dirname, '..', '..');
const workflowPath = path.join(repoRoot, 'n8n', 'workflows', 'MushroomProcess - Fulfillment API - PGSQL.json');
const workflow = JSON.parse(fs.readFileSync(workflowPath, 'utf8'));

function node(name) {
  const found = workflow.nodes.find((entry) => entry.name === name);
  if (!found) throw new Error(`Missing node: ${name}`);
  return found;
}

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

const listSql = node('PGSQL - List Orders').parameters.query;
for (const field of ['provider', 'site_key', 'external_order_id', 'external_skus']) {
  assert(listSql.includes(`'${field}'`), `PGSQL list query does not expose ${field}`);
}

const buildCode = node('Code - Build Fulfillment Orders').parameters.jsCode;
const fn = new Function('$json', '$', buildCode);
const result = fn(
  {
    records: [{
      id: 'moov-pos-order',
      fields: {
        provider: 'moov_pos',
        external_order_id: 'moov-order-1',
        order_code: '',
        order_number: null,
        order_date: '2026-08-28T20:00:00Z',
        customer_name: 'Test Customer',
        payment_method: 'Tap to Pay',
        payment_status: 'PAID',
        payment_processor: 'moov',
        payment_reconciliation_status: 'pending',
        processor_payment_id: 'moov-payment-1',
        processor_payment_status: 'pending',
        processor_payment_amount: 19.50,
        items_json: JSON.stringify([{ name: 'Test Product', quantity: 1 }]),
        products: ['product-1'],
      },
    }],
  },
  (name) => {
    if (name !== 'Code - Parse List Request') throw new Error(`Unexpected node lookup: ${name}`);
    return { first: () => ({ json: { mode: 'all', date: '', timezone: 'America/Denver', include_review: false } }) };
  },
)[0].json;

assert(result.orders.length === 1, 'assigned Moov POS order needing reconciliation should remain visible');
const row = result.orders[0];
assert(row.sales_channel === 'moov_pos', 'Moov POS sales channel not exposed');
assert(row.external_order_id === 'moov-order-1', 'provider-neutral external order id not exposed');
assert(row.order_ref === 'moov-order-1', 'provider-neutral external order id not used as order reference');
assert(row.payment_processor === 'moov', 'Moov processor not exposed');
assert(row.can_reconcile === true, 'Moov POS order should expose generic reconciliation action');
assert(row.assignment_complete_needs_reconciliation === true, 'Moov POS assignment/reconciliation state incorrect');
assert(row.mode === 'market', 'Moov POS order should remain in the current market fulfillment mode');

console.log('PGSQL Fulfillment provider-neutral action contract smoke tests passed.');
