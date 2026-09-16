#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');

const appsmithPath = path.resolve(__dirname, 'MushroomProcess.json');
const app = JSON.parse(fs.readFileSync(appsmithPath, 'utf8'));

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function pageByName(name) {
  return app.pageList.find((entry) =>
    entry.unpublishedPage?.name === name || entry.publishedPage?.name === name);
}

function flattenWidgets(widget) {
  return [widget, ...(widget.children || []).flatMap(flattenWidgets)];
}

function widgetByName(page, side, name) {
  return flattenWidgets(page[side].layouts[0].dsl)
    .find((widget) => widget.widgetName === name);
}

function actionByName(pageName, name) {
  return app.actionList.find((entry) =>
    entry.pluginType === 'DB'
      && entry.unpublishedAction?.pageId === pageName
      && entry.unpublishedAction?.name === name);
}

function collectionByName(pageName, name) {
  return app.actionCollectionList.find((entry) =>
    entry.unpublishedCollection?.pageId === pageName
      && entry.unpublishedCollection?.name === name);
}

const pageExpectations = [
  ['Lots', 'tblLots', 'can_inoculate_source'],
  ['Lab - Inoculate', 'tblLots', 'can_inoculate_target'],
  ['Lab - Spawn to Bulk', 'tblLots', 'can_spawn_substrate'],
];

for (const [pageName, targetTable] of pageExpectations) {
  const page = pageByName(pageName);
  assert(page, `${pageName}: page not found`);

  for (const side of ['unpublishedPage', 'publishedPage']) {
    const checkbox = widgetByName(page, side, 'chkShowEligibleProducts');
    assert(checkbox, `${pageName}/${side}: Show Eligible Products checkbox missing`);
    assert(checkbox.label === 'Show Eligible Products', `${pageName}/${side}: checkbox label drifted`);
    assert(checkbox.defaultCheckedState === false, `${pageName}/${side}: Products should be opt-in`);

    const table = widgetByName(page, side, targetTable);
    assert(table?.tableData?.includes('qEligibleCultivationProducts'), `${pageName}/${side}: target table does not merge eligible Products`);
  }

  const candidates = actionByName(pageName, 'qEligibleCultivationProducts');
  assert(candidates, `${pageName}: eligible Product query missing`);
  for (const side of ['unpublishedAction', 'publishedAction']) {
    const body = candidates[side].actionConfiguration.body;
    assert(body.includes('v_product_cultivation_candidates'), `${pageName}/${side}: candidate query does not use canonical view`);
  }
}

for (const pageName of ['Lots', 'Lab - Inoculate']) {
  const page = pageByName(pageName);
  for (const side of ['unpublishedPage', 'publishedPage']) {
    const sources = widgetByName(page, side, 'tblInocSourceLots');
    assert(sources.tableData.includes('can_inoculate_source'), `${pageName}/${side}: source table does not limit Products to LC-source capability`);
  }

  const query = actionByName(pageName, 'qInoculateLots');
  assert(query, `${pageName}: inoculation query missing`);
  for (const side of ['unpublishedAction', 'publishedAction']) {
    const body = query[side].actionConfiguration.body;
    assert(body.includes('mp_inoculate_with_products_result'), `${pageName}/${side}: inoculation does not use atomic Product wrapper`);
    assert(body.includes('inoc_source_product_id'), `${pageName}/${side}: source Product id is not submitted`);
    assert(body.includes('inoc_target_product_ids'), `${pageName}/${side}: target Product ids are not submitted`);
  }

  const collection = collectionByName(pageName, 'LotsInoculate');
  assert(collection, `${pageName}: LotsInoculate collection missing`);
  for (const side of ['unpublishedCollection', 'publishedCollection']) {
    const body = collection[side].body;
    assert(body.includes('inoc_source_product_id'), `${pageName}/${side}: source Product state missing`);
    assert(body.includes('inoc_target_product_ids'), `${pageName}/${side}: target Product state missing`);
    assert(body.includes('can_inoculate_source'), `${pageName}/${side}: Product source capability not checked`);
  }
}

for (const pageName of ['Lots', 'Lab - Spawn to Bulk']) {
  const query = actionByName(pageName, 'qSpawnToBulkLots');
  assert(query, `${pageName}: Spawn-to-Bulk query missing`);
  for (const side of ['unpublishedAction', 'publishedAction']) {
    const body = query[side].actionConfiguration.body;
    assert(body.includes('mp_spawn_to_bulk_with_products'), `${pageName}/${side}: Spawn-to-Bulk does not use atomic Product wrapper`);
    assert(body.includes('p_substrate_product_ids'), `${pageName}/${side}: substrate Product ids are not submitted`);
  }

  const collection = collectionByName(pageName, 'LotsSpawnToBulk');
  assert(collection, `${pageName}: LotsSpawnToBulk collection missing`);
  for (const side of ['unpublishedCollection', 'publishedCollection']) {
    const body = collection[side].body;
    assert(body.includes('can_spawn_substrate'), `${pageName}/${side}: Product substrate capability not checked`);
    assert(body.includes('substrateSourceRows().length'), `${pageName}/${side}: default output count does not include Product substrates`);
  }
}

const lotsPage = pageByName('Lots');
for (const side of ['unpublishedPage', 'publishedPage']) {
  const main = widgetByName(lotsPage, side, 'tblLots');
  assert(main.tableData.includes('qEligibleCultivationProducts'), `Lots/${side}: main Lots table does not expose eligible Products`);
}
const lotsPageCollection = collectionByName('Lots', 'LotsPage');
for (const side of ['unpublishedCollection', 'publishedCollection']) {
  const body = lotsPageCollection[side].body;
  assert(body.includes('is a packaged Product and is not eligible for this Lot action'), `Lots/${side}: Product rows are not guarded from Lot-only actions`);
}

console.log('Appsmith Issue #57 Product cultivation return smoke tests passed.');
