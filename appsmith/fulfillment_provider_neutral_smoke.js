#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');

const appsmithPath = path.resolve(__dirname, 'MushroomProcess.json');
const app = JSON.parse(fs.readFileSync(appsmithPath, 'utf8'));

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

const collection = app.actionCollectionList.find((entry) =>
  entry.publishedCollection?.name === 'FulfillmentUI' || entry.unpublishedCollection?.name === 'FulfillmentUI');
assert(collection, 'FulfillmentUI collection not found');

for (const side of ['publishedCollection', 'unpublishedCollection']) {
  const body = collection[side].body;
  assert(body.includes('row.payment_reconciliation_status || row.clover_reconciliation_status'), `${side}: generic reconciliation status is not preferred`);
  assert(body.includes('row.can_reconcile === true'), `${side}: FulfillmentUI does not trust generic can_reconcile`);
  assert(body.includes('row.payment_processor'), `${side}: FulfillmentUI does not use generic processor identity`);
  assert(!body.includes('Enter a Clover payment ID.'), `${side}: Clover-specific manual validation remains`);
}

const fulfillmentPage = app.pageList.find((entry) => entry.publishedPage?.name === 'Fulfillment' || entry.unpublishedPage?.name === 'Fulfillment');
assert(fulfillmentPage, 'Fulfillment page not found');

for (const side of ['publishedPage', 'unpublishedPage']) {
  const children = fulfillmentPage[side].layouts[0].dsl.children;
  const byName = Object.fromEntries(children.map((widget) => [widget.widgetName, widget]));
  assert(byName.inpManualCloverPaymentId.label === 'Processor Payment ID', `${side}: payment id label is not provider-neutral`);
  assert(byName.inpManualCloverPaymentAmount.label === 'Processor Amount', `${side}: amount label is not provider-neutral`);
  assert(byName.inpManualCloverPaymentTime.label === 'Processor Payment Time', `${side}: payment time label is not provider-neutral`);
  assert(byName.btnManualReconcile.text === 'Manual Match Payment', `${side}: manual match button is Clover-specific`);
  const statusColumn = byName.tblFulfillmentOrders.primaryColumns.clover_reconciliation_status;
  assert(statusColumn.label === 'Reconciliation', `${side}: reconciliation column label is Clover-specific`);
  assert(statusColumn.computedValue.includes('payment_reconciliation_status'), `${side}: reconciliation column does not prefer generic status`);
}

const manualApi = app.actionList.find((entry) => entry.publishedAction?.name === 'apiFulfillmentManualReconciliationMatch');
assert(manualApi, 'manual reconciliation API action not found');
for (const side of ['publishedAction', 'unpublishedAction']) {
  const body = manualApi[side].actionConfiguration.body;
  assert(body.includes('"payment_processor"'), `${side}: request does not send payment_processor`);
  assert(body.includes('"processor_payment_id"'), `${side}: request does not send processor_payment_id`);
  assert(body.includes('"processor_payment_amount"'), `${side}: request does not send processor_payment_amount`);
  assert(body.includes('"processor_payment_time"'), `${side}: request does not send processor_payment_time`);
  assert(!body.includes('"clover_payment_id"'), `${side}: request still depends on Clover payment alias`);
}

console.log('Appsmith Fulfillment provider-neutral surface smoke tests passed.');
