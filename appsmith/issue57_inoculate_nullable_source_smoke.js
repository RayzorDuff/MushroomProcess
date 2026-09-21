#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');

const appsmithPath = path.resolve(__dirname, 'MushroomProcess.json');
const app = JSON.parse(fs.readFileSync(appsmithPath, 'utf8'));

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

for (const pageName of ['Lots', 'Lab - Inoculate']) {
  const action = app.actionList.find((entry) =>
    entry.pluginType === 'DB'
      && entry.unpublishedAction?.pageId === pageName
      && entry.unpublishedAction?.name === 'qInoculateLots');

  assert(action, `${pageName}: qInoculateLots action missing`);

  for (const side of ['unpublishedAction', 'publishedAction']) {
    const body = action[side]?.actionConfiguration?.body || '';

    assert(
      body.includes('p_source_lot_id => {{ LotsInoculate.sql.str(appsmith.store.inoc_source_id) }}::bigint'),
      `${pageName}/${side}: nullable source Lot ID is not NULL-safe`
    );
    assert(
      body.includes('p_source_product_id => {{ LotsInoculate.sql.str(appsmith.store.inoc_source_product_id) }}::bigint'),
      `${pageName}/${side}: nullable source Product ID is not NULL-safe`
    );
    assert(
      body.includes('p_lc_volume_ml => {{ LotsInoculate.sql.str(appsmith.store.inoc_lc_vol) }}::numeric'),
      `${pageName}/${side}: nullable LC volume is not NULL-safe`
    );

    assert(
      !body.includes('p_source_lot_id => {{ LotsInoculate.sql.num(appsmith.store.inoc_source_id) }}::bigint'),
      `${pageName}/${side}: source Lot still uses Number(null) path`
    );
    assert(
      !body.includes('p_source_product_id => {{ LotsInoculate.sql.num(appsmith.store.inoc_source_product_id) }}::bigint'),
      `${pageName}/${side}: source Product still uses Number(null) path`
    );
  }
}

console.log('Appsmith Issue #57 nullable inoculation source smoke tests passed.');
