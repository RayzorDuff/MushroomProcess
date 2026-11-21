'use strict';
const fs = require('fs');
const path = require('path');
const cp = require('child_process');
const os = require('os');
const assert = require('assert');
const root = path.resolve(__dirname, '../..');
const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'mp-commerce-ui-'));
try {
  const output = path.join(directory, 'application.json');
  cp.execFileSync('python3', [path.join(root, 'scripts/commerce_fulfillment_appsmith.py'), '--output', output]);
  const old = JSON.parse(fs.readFileSync(path.join(root, 'appsmith/MushroomProcess.json')));
  const next = JSON.parse(fs.readFileSync(output));
  assert.deepStrictEqual(next.actionCollectionList, old.actionCollectionList);
  assert.deepStrictEqual(next.actionList.slice(0, old.actionList.length), old.actionList);
  for (const [index, page] of old.pageList.entries()) {
    if (page.unpublishedPage.name !== 'Fulfillment') {
      assert.deepStrictEqual(next.pageList[index], page);
      continue;
    }
    for (const side of ['publishedPage', 'unpublishedPage']) {
      const before = page[side].layouts[0].dsl.children;
      const after = next.pageList[index][side].layouts[0].dsl.children;
      assert.deepStrictEqual(after.slice(0, before.length), before);
      const widgets = Object.fromEntries(after.map(w => [w.widgetName, w]));
      assert(widgets.btnWooLabel.onClick.includes('apiWooOpenOrder'));
      assert(widgets.btnWooLabel.onClick.includes('NEW_WINDOW'));
      assert(!widgets.btnWooLabel.onClick.includes('apiWooDispatch'));
      assert(widgets.btnWooDispatch.onClick.includes('apiWooDispatch'));
      for (const name of ['inpWooPackage', 'inpWooScan', 'inpWooCarrier', 'inpWooService', 'inpWooTracking', 'inpWooPostage']) {
        assert.strictEqual(widgets[name].isVisible, true, name + ' must not inherit legacy reconciliation visibility');
      }
    }
  }
  const workflow = JSON.parse(fs.readFileSync(path.join(root, 'n8n/workflows/MushroomProcess - Woo Pack and Dispatch - PGSQL.json')));
  assert.strictEqual(workflow.active, false);
  for (const node of workflow.nodes.filter(n => n.type === 'n8n-nodes-base.webhook')) {
    assert.strictEqual(node.parameters.authentication, 'headerAuth');
  }
  for (const node of workflow.nodes.filter(n => n.type === 'n8n-nodes-base.code')) {
    new Function(node.parameters.jsCode);
  }
  const guard = workflow.nodes.find(n => n.name === 'Validate Woo origin').parameters.jsCode;
  for (const origin of ['https://shop-test.danks.store', 'https://danks.store', 'https://dankmushrooms.net']) {
    assert.deepStrictEqual(new Function('$env', '$input', guard)({MP_COMMERCE_WOO_ORIGIN: origin}, {all: () => ['same order']}), ['same order']);
  }
  for (const origin of ['http://dankmushrooms.net', 'https://dankmushrooms.net.evil.invalid']) {
    assert.throws(() => new Function('$env', '$input', guard)({MP_COMMERCE_WOO_ORIGIN: origin}, {all: () => []}), /Unreviewed/);
  }
  console.log('Woo fulfillment overlay preserves existing MP actions and widgets; authenticated workflow syntax passed.');
} finally {
  fs.rmSync(directory, {recursive: true, force: true});
}
