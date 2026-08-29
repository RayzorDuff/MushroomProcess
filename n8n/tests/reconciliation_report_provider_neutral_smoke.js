#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');
const vm = require('vm');

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

const workflowsDir = path.join(__dirname, '..', 'workflows');
const pgPath = path.join(workflowsDir, 'MushroomProcess - Daily Reconciliation Report Email + PDF - PGSQL.json');
const airPath = path.join(workflowsDir, 'MushroomProcess - Daily Reconciliation Report Email + PDF.json');

const pg = JSON.parse(fs.readFileSync(pgPath, 'utf8'));
const air = JSON.parse(fs.readFileSync(airPath, 'utf8'));

function nodeByName(workflow, name) {
  const node = workflow.nodes.find((n) => n.name === name);
  assert(node, `Missing node: ${name}`);
  return node;
}

const query = nodeByName(pg, 'PGSQL - List Orders for Report Date').parameters.query;
for (const field of [
  'provider',
  'external_order_id',
  'payment_processor',
  'payment_reconciliation_status',
  'processor_payment_id',
  'processor_payment_status',
  'processor_payment_amount',
  'processor_payment_time',
  'processor_match_confidence',
]) {
  assert(query.includes(`'${field}'`), `PGSQL report query does not expose ${field}`);
}

function runReport(workflow) {
  const code = nodeByName(workflow, 'Code - Build Daily Text Report').parameters.jsCode;
  assert(code.includes('reconciliationStatus(row)'), 'report does not centralize provider-neutral reconciliation state');
  assert(code.includes('payment_reconciliation_status'), 'report does not prefer generic reconciliation status');
  assert(code.includes('Legacy Clover'), 'source-specific Clover comparison is not explicitly identified as legacy');
  assert(!code.includes('const reconciledOrders = orders.filter((r) => String(r.clover_reconciliation_status'), 'report still classifies orders directly from Clover status');

  const records = [
    {
      id: 'web-1',
      fields: {
        provider: 'ecwid',
        external_order_id: '1001',
        order_code: 'WEB-1001',
        order_date: '2026-08-28T18:00:00Z',
        payment_status: 'PAID',
        payment_method: 'Credit Card',
        order_total: 20,
        clover_reconciliation_status: 'pending',
        items_json: JSON.stringify([{ name: 'Lion Mane', sku: 'LM', productId: 1, quantity: 1 }]),
      },
    },
    {
      id: 'clover-1',
      fields: {
        provider: 'ecwid',
        external_order_id: '1002',
        order_code: 'POS-1002',
        order_date: '2026-08-28T19:00:00Z',
        payment_status: 'PAID',
        payment_method: 'Sell on the Go - Credit Card',
        order_total: 15,
        payment_processor: 'clover',
        payment_reconciliation_status: 'reconciled',
        processor_payment_id: 'clv-1',
        processor_payment_time: '2026-08-28T19:01:00Z',
        clover_reconciliation_status: 'pending',
        clover_payment_id: 'old-clv-id',
        items_json: '[]',
      },
    },
    {
      id: 'moov-1',
      fields: {
        provider: 'moov_pos',
        external_order_id: 'mv-order-1',
        order_date: '2026-08-28T20:00:00Z',
        payment_status: 'PAID',
        order_total: 12,
        payment_processor: 'moov',
        payment_reconciliation_status: 'reconciled',
        processor_payment_id: 'mv-pay-1',
        processor_payment_time: '2026-08-28T20:00:30Z',
        clover_reconciliation_status: 'needs_review',
        items_json: '[]',
      },
    },
    {
      id: 'cash-1',
      fields: {
        provider: 'moov_pos',
        external_order_id: 'cash-order-1',
        order_date: '2026-08-28T20:30:00Z',
        payment_status: 'PAID',
        order_total: 10,
        payment_processor: 'cash',
        payment_reconciliation_status: 'accounted',
        items_json: '[]',
      },
    },
  ];

  const clover = {
    elements: [
      { id: 'clv-1', result: 'SUCCESS', amount: 1500, createdTime: Date.parse('2026-08-28T19:01:00Z') },
      { id: 'clv-unmatched', result: 'SUCCESS', amount: 500, createdTime: Date.parse('2026-08-28T21:00:00Z') },
    ],
  };

  const contextValues = {
    'Code - Prepare Report Context': {
      report_timezone: 'America/Denver',
      report_date: '2026-08-28',
      report_generated_at: '2026-08-29T03:00:00Z',
    },
    'PGSQL - List Orders for Report Date': { records },
    'HTTP - Get Clover Payments for Report': clover,
  };

  function $(name) {
    return { first: () => ({ json: contextValues[name] || {} }) };
  }

  const wrapped = `(function(){\n${code}\n})()`;
  const result = vm.runInNewContext(wrapped, { $, Intl, Date, Number, String, Array, Map, Set, Object, Boolean, console });
  const row = result[0].json;

  assert(row.settled_orders_count === 4, `expected 4 settled orders, got ${row.settled_orders_count}`);
  assert(row.attention_orders_count === 0, `expected no attention orders, got ${row.attention_orders_count}`);
  assert(row.reconciled_orders_count === 2, `expected Clover + Moov reconciled orders, got ${row.reconciled_orders_count}`);
  assert(row.accounted_orders_count === 1, `expected accounted cash order, got ${row.accounted_orders_count}`);
  assert(row.paid_channel_orders_count === 1, `paid Ecwid web order was incorrectly forced into Clover reconciliation`);
  assert(row.unreconciled_clover_payments_count === 1, `generic Clover payment id was not used for unmatched payment comparison`);
  assert(row.report_text.includes('Moov POS mv-order-1'), 'Moov POS order is not represented by its sales channel');
  assert(row.report_text.includes('processor Moov mv-pay-1'), 'Moov processor identity is not reported');
  assert(row.report_text.includes('Ecwid WEB-1001'), 'Ecwid paid web order is missing');
  assert(!row.report_text.includes('Ecwid WEB-1001 | $20.00') || row.report_text.includes('state paid'), 'paid Ecwid web order is not classified as paid');
  assert(row.report_text.includes('Legacy Clover Payments Not Reconciled To Settled Clover Orders'), 'legacy Clover comparison section missing');
  return row;
}

const pgResult = runReport(pg);
const airResult = runReport(air);
assert(pgResult.settled_orders_count === airResult.settled_orders_count, 'PGSQL/Airtable report classification diverged');

console.log('Provider-neutral reconciliation report smoke tests passed.');
