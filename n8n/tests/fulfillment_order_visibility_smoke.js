#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');

const repoRoot = path.resolve(__dirname, '..', '..');
const workflows = [
  'MushroomProcess - Fulfillment API.json',
  'MushroomProcess - Fulfillment API - PGSQL.json',
];

function item(name, quantity) {
  return { name, quantity };
}

function record(id, fields) {
  return { id, fields };
}

const fixtures = [
  record('rec-assigned-pending', {
    order_code: 'ASSIGNED-PENDING',
    order_date: '2026-07-10T16:00:00.000Z',
    payment_method: 'Sell on the Go - Credit Card',
    payment_status: 'PAID',
    clover_reconciliation_status: 'pending',
    items_json: JSON.stringify([item('Lion Mane', 2)]),
    products: ['rec-product-1', 'rec-product-2'],
    products_report: 'Product 1, Product 2',
    product_ids_report: 'PROD-1, PROD-2',
  }),
  record('rec-unassigned-pending', {
    order_code: 'UNASSIGNED-PENDING',
    order_date: '2026-07-11T16:00:00.000Z',
    payment_method: 'Sell on the Go - Credit Card',
    payment_status: 'PAID',
    clover_reconciliation_status: 'pending',
    items_json: JSON.stringify([item('Oyster', 1)]),
    products: [],
  }),
  record('rec-complete-old', {
    order_code: 'COMPLETE-OLD',
    order_date: '2026-06-01T16:00:00.000Z',
    payment_method: 'Sell on the Go - Credit Card',
    payment_status: 'PAID',
    clover_reconciliation_status: 'reconciled',
    items_json: JSON.stringify([item('Reishi', 1)]),
    products: ['rec-product-3'],
    products_report: 'Product 3',
    product_ids_report: 'PROD-3',
  }),
  record('rec-paid-web', {
    order_code: 'PAID-WEB',
    order_date: '2026-07-13T16:00:00.000Z',
    payment_method: 'Online Card',
    payment_status: 'PAID',
    clover_reconciliation_status: '',
    items_json: JSON.stringify([item('Cordyceps', 1)]),
    products: [],
  }),
  record('rec-accounted-cash', {
    order_code: 'ACCOUNTED-CASH',
    order_date: '2026-07-12T18:00:00.000Z',
    payment_method: 'Sell on the Go - Cash',
    payment_status: 'PAID',
    clover_reconciliation_status: 'accounted',
    items_json: JSON.stringify([item('Lion Mane', 1)]),
    products: [],
  }),
  record('rec-needs-review', {
    order_code: 'NEEDS-REVIEW',
    order_date: '2026-07-12T17:00:00.000Z',
    payment_method: 'Sell on the Go - Credit Card',
    payment_status: 'PAID',
    clover_reconciliation_status: 'needs_review',
    items_json: JSON.stringify([item('Reishi', 1)]),
    products: [],
  }),
  record('rec-unpaid-web', {
    order_code: 'UNPAID-WEB',
    order_date: '2026-07-12T16:00:00.000Z',
    payment_method: 'Online Card',
    payment_status: 'AWAITING_PAYMENT',
    clover_reconciliation_status: '',
    items_json: JSON.stringify([item('Cordyceps', 1)]),
    products: [],
  }),
];

function loadBuildCode(filename) {
  const workflowPath = path.join(repoRoot, 'n8n', 'workflows', filename);
  const workflow = JSON.parse(fs.readFileSync(workflowPath, 'utf8'));
  const node = workflow.nodes.find((entry) => entry.name === 'Code - Build Fulfillment Orders');
  if (!node || !node.parameters || !node.parameters.jsCode) {
    throw new Error(`Build Fulfillment Orders code node missing in ${filename}`);
  }
  return node.parameters.jsCode;
}

function executeBuild(code, req) {
  const fn = new Function('$json', '$', code);
  return fn(
    { records: fixtures },
    (name) => {
      if (name !== 'Code - Parse List Request') {
        throw new Error(`Unexpected node lookup: ${name}`);
      }
      return { first: () => ({ json: req }) };
    },
  )[0].json;
}

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

for (const filename of workflows) {
  const code = loadBuildCode(filename);

  const allDates = executeBuild(code, {
    mode: 'all',
    date: '',
    timezone: 'America/Denver',
    include_review: false,
  });
  const allCodes = allDates.orders.map((row) => row.order_ref);

  assert(
    allCodes.includes('ASSIGNED-PENDING'),
    `${filename}: fully assigned order needing reconciliation was hidden`,
  );
  assert(
    !allCodes.includes('UNASSIGNED-PENDING'),
    `${filename}: unassigned review order appeared without Include Review`,
  );
  assert(
    allCodes.includes('COMPLETE-OLD'),
    `${filename}: completed historical order was hidden when date was blank`,
  );
  assert(
    allCodes.includes('PAID-WEB'),
    `${filename}: paid website order was hidden`,
  );
  assert(
    allCodes.includes('ACCOUNTED-CASH'),
    `${filename}: accounted cash market order was hidden`,
  );
  assert(
    !allCodes.includes('NEEDS-REVIEW'),
    `${filename}: needs-review market order appeared without Include Review`,
  );
  assert(
    !allCodes.includes('UNPAID-WEB'),
    `${filename}: unpaid web order appeared as ready for fulfillment`,
  );

  const assignedPending = allDates.orders.find((row) => row.order_ref === 'ASSIGNED-PENDING');
  assert(assignedPending.product_assignment_complete === true, `${filename}: assignment completion flag incorrect`);
  assert(assignedPending.reconciliation_complete === false, `${filename}: reconciliation completion flag incorrect`);
  assert(assignedPending.assignment_complete_needs_reconciliation === true, `${filename}: outstanding reconciliation flag missing`);
  assert(assignedPending.can_assign_products === false, `${filename}: completed assignment still enabled`);
  assert(assignedPending.can_reconcile === true, `${filename}: reconciliation should remain enabled`);

  const withReview = executeBuild(code, {
    mode: 'all',
    date: '',
    timezone: 'America/Denver',
    include_review: true,
  });
  assert(
    withReview.orders.some((row) => row.order_ref === 'UNASSIGNED-PENDING'),
    `${filename}: Include Review did not expose unassigned pending market order`,
  );
  assert(
    withReview.orders.some((row) => row.order_ref === 'NEEDS-REVIEW'),
    `${filename}: Include Review did not expose needs-review market order`,
  );

  const dateFiltered = executeBuild(code, {
    mode: 'all',
    date: '2026-07-10',
    timezone: 'America/Denver',
    include_review: false,
  });
  assert(
    dateFiltered.orders.length === 1 && dateFiltered.orders[0].order_ref === 'ASSIGNED-PENDING',
    `${filename}: explicit date filter did not constrain results`,
  );

  for (let index = 1; index < allDates.orders.length; index += 1) {
    const prior = String(allDates.orders[index - 1].order_date || '');
    const current = String(allDates.orders[index].order_date || '');
    assert(prior >= current, `${filename}: orders are not sorted newest first`);
  }
}

console.log('Fulfillment order visibility and completed-state smoke tests passed.');
