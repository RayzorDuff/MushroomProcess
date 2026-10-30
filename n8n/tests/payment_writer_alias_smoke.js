#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');

const repoRoot = path.resolve(__dirname, '..', '..');

function loadWorkflow(filename) {
  return JSON.parse(fs.readFileSync(path.join(repoRoot, 'n8n', 'workflows', filename), 'utf8'));
}

function node(workflow, name) {
  const found = workflow.nodes.find((entry) => entry.name === name);
  if (!found) throw new Error(`Missing node: ${name}`);
  return found;
}

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function runCode(jsCode, json) {
  const fn = new Function('$json', jsCode);
  return fn(json);
}

const poller = loadWorkflow('MushroomProcess - Clover Payment Reconciliation Poller - PGSQL.json');
const pollerBuild = node(poller, 'Code - Build PGSQL Reconciliation Update').parameters.jsCode;
const pollerWrite = node(poller, 'PGSQL - Update Reconciliation').parameters.query;

const pollerResult = runCode(pollerBuild, {
  airtable_record_id: 'rec-test',
  ecwid_order_id: '12345',
  clover_reconciliation_status: 'pending',
  match_action: 'reconciled',
  clover_selected_payment_id: 'clv-pay-1',
  clover_selected_amount_cents: 1250,
  clover_selected_created_ms: Date.parse('2026-08-28T20:00:00Z'),
  clover_match_confidence_num: 0.8,
  reconciliation_note: 'test',
}).json;

assert(pollerResult.fields.payment_processor === 'clover', 'poller did not explicitly identify Clover');
assert(pollerResult.fields.payment_reconciliation_status === 'reconciled', 'poller generic reconciliation status missing');
assert(pollerResult.fields.processor_payment_id === 'clv-pay-1', 'poller generic payment id missing');
assert(pollerResult.fields.processor_payment_status === 'succeeded', 'poller generic processor status missing');
assert(pollerResult.fields.processor_payment_amount === 12.5, 'poller generic payment amount incorrect');
assert(pollerResult.fields.processor_match_confidence === 0.8, 'poller generic confidence missing');
assert(pollerResult.fields.clover_payment_id === pollerResult.fields.processor_payment_id, 'poller legacy/generic ids diverged');

for (const column of [
  'payment_processor',
  'payment_reconciliation_status',
  'processor_payment_id',
  'processor_payment_status',
  'processor_payment_amount',
  'processor_payment_time',
  'processor_match_confidence',
]) {
  assert(pollerWrite.includes(column), `poller SQL does not explicitly write ${column}`);
}

const fulfillment = loadWorkflow('MushroomProcess - Fulfillment API - PGSQL.json');
const manualCode = node(fulfillment, 'Code - Parse Manual Reconciliation Match').parameters.jsCode;
const manualWrite = node(fulfillment, 'PGSQL - Patch Manual Reconciliation Match').parameters.query;
const accountedCode = node(fulfillment, 'Code - Parse Accounted Reconciliation').parameters.jsCode;
const accountedWrite = node(fulfillment, 'PGSQL - Patch Accounted Reconciliation').parameters.query;

const manual = runCode(manualCode, {
  body: {
    airtable_order_record_id: 'rec-manual',
    clover_payment_id: 'clv-manual-1',
    clover_payment_amount: '18.75',
    clover_payment_time: '2026-08-28T20:05:00Z',
    operator: 'operator@example.com',
  },
})[0].json;

assert(manual.fields.payment_processor === 'clover', 'manual match did not explicitly identify Clover');
assert(manual.fields.payment_reconciliation_status === 'reconciled', 'manual generic reconciliation status missing');
assert(manual.fields.processor_payment_id === 'clv-manual-1', 'manual generic payment id missing');
assert(manual.fields.processor_payment_status === 'succeeded', 'manual generic processor status missing');
assert(manual.fields.processor_payment_amount === 18.75, 'manual generic amount incorrect');
assert(manual.fields.clover_payment_id === manual.fields.processor_payment_id, 'manual legacy/generic ids diverged');


const manualMoov = runCode(manualCode, {
  body: {
    airtable_order_record_id: 'rec-manual-moov',
    payment_processor: 'moov',
    processor_payment_id: 'moov-manual-1',
    processor_payment_amount: '22.50',
    processor_payment_time: '2026-08-28T20:06:00Z',
    operator: 'operator@example.com',
  },
})[0].json;

assert(manualMoov.fields.payment_processor === 'moov', 'generic manual match did not preserve Moov processor');
assert(manualMoov.fields.processor_payment_id === 'moov-manual-1', 'generic manual match payment id missing');
assert(manualMoov.fields.processor_payment_amount === 22.5, 'generic manual match amount incorrect');
assert(manualMoov.fields.clover_payment_id === null, 'non-Clover manual match leaked into legacy Clover id');
assert(manualMoov.fields.clover_reconciliation_status === null, 'non-Clover manual match leaked into legacy Clover status');
assert(manualMoov.result.payment_processor === 'moov', 'generic manual result processor missing');

const accounted = runCode(accountedCode, {
  body: {
    airtable_order_record_id: 'rec-cash',
    operator: 'operator@example.com',
  },
})[0].json;

assert(accounted.fields.payment_processor === 'cash', 'accounted cash action did not identify cash processor/tender');
assert(accounted.fields.payment_reconciliation_status === 'accounted', 'accounted generic reconciliation status missing');
assert(accounted.fields.processor_payment_status === 'accounted', 'accounted generic payment status missing');
assert(accounted.fields.clover_reconciliation_status === 'accounted', 'accounted legacy compatibility status missing');

for (const [label, query] of [['manual', manualWrite], ['accounted', accountedWrite]]) {
  for (const column of [
    'payment_processor',
    'payment_reconciliation_status',
    'processor_payment_id',
    'processor_payment_status',
    'processor_payment_amount',
    'processor_payment_time',
    'processor_match_confidence',
  ]) {
    assert(query.includes(column), `${label} SQL does not explicitly write ${column}`);
  }
}

console.log('Provider-neutral payment writer dual-write smoke tests passed.');
