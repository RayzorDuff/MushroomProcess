#!/usr/bin/env node
'use strict';

const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');

const schemaDir = path.resolve(__dirname, '..');
const generator = path.join(schemaDir, 'airtable_export_to_postgres_sql.js');
const exportDir = path.join(schemaDir, 'export');
const schemaPath = path.join(exportDir, '_schema.json');
const tablesDumpPath = path.join(exportDir, 'tables_dump.json');
const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'mp-pg-generator-smoke-'));
const outDir = path.join(tempDir, 'pgsql');
const fixtureTablesDumpPath = path.join(tempDir, 'tables_dump.json');

const tablesDump = JSON.parse(fs.readFileSync(tablesDumpPath, 'utf8'));
const productsTable = (tablesDump.tables || []).find(table => table.name === 'products');
assert(productsTable, 'Production tables_dump.json must contain the products table');

const productUseLookup = (productsTable.fields || []).find(
  field => field.name === 'origin_strain_product_use' && field.type === 'multipleLookupValues'
);
assert(
  productUseLookup,
  'Products must contain the origin_strain_product_use lookup-array field used by the compiler regression'
);

const formulaFixture = (productsTable.fields || []).find(
  field => field.name === 'label_companyinfo_prod' && field.type === 'formula'
);
assert(
  formulaFixture,
  'Products must contain a formula field available for the lookup-array compiler regression'
);

const arraySwitchMarker = '__MP_LOOKUP_ARRAY_SWITCH_TEST__';
formulaFixture.options = {
  ...formulaFixture.options,
  formula: `SWITCH({${productUseLookup.id}}, "${arraySwitchMarker}", "matched", "")`,
  referencedFieldIds: [productUseLookup.id]
};

fs.writeFileSync(fixtureTablesDumpPath, `${JSON.stringify(tablesDump, null, 2)}\n`);
fs.mkdirSync(outDir, { recursive: true });

try {
  const result = spawnSync(process.execPath, [generator], {
    cwd: schemaDir,
    env: {
      ...process.env,
      AIRTABLE_EXPORT_DIR: exportDir,
      AIRTABLE_SCHEMA_PATH: schemaPath,
      TABLES_DUMP_PATH: fixtureTablesDumpPath,
      POSTGRES_OUT_DIR: outDir,
      POSTGRES_SCHEMA: 'public',
      CREATE_VIEWS: 'true',
      BIGINT_PKS: 'true'
    },
    encoding: 'utf8'
  });

  if (result.status !== 0) {
    process.stderr.write(result.stdout || '');
    process.stderr.write(result.stderr || '');
    throw new Error(`Generator exited with status ${result.status}`);
  }

  const computedSql = fs.readFileSync(path.join(outDir, '004_computed_views.sql'), 'utf8');
  const loadSql = fs.readFileSync(path.join(outDir, '100_load.sql'), 'utf8');
  const schema = JSON.parse(fs.readFileSync(schemaPath, 'utf8'));

  const expectedArraySwitch =
    `('${arraySwitchMarker}')::text = ANY((comp.\"origin_strain_product_use\")::text[])`;
  assert(
    computedSql.includes(expectedArraySwitch),
    `Lookup-array SWITCH cases must compile to scalar = ANY(text[]); missing: ${expectedArraySwitch}`
  );
  assert(
    !computedSql.includes(
      `(comp.\"origin_strain_product_use\") = ('${arraySwitchMarker}')`
    ),
    'Generated computed views still contain an unsafe text[] = scalar comparison'
  );


  const legacyPublicLinkColumns = [
    'public_link',
    'public_link_dark_room',
    'public_link_fruiting',
    'public_link_harvest',
    'public_link_spawn_to_bulk',
    'public_link_inoculate_flask',
    'public_link_inoculate_grain',
    'public_link_freeze_dry_package',
    'public_link_substrate_package',
    'public_link_lot_lineage',
    'public_link_from_lot_id',
    'public_link_from_product_id',
  ];
  for (const column of legacyPublicLinkColumns) {
    assert(
      !computedSql.includes(`AS "${column}"`),
      `Generated computed views must not reintroduce legacy QR/public-link column ${column}`
    );
  }
  assert(
    computedSql.includes('-- legacy QR/public-link field omitted: lots.public_link'),
    'Generated computed views should document omitted legacy QR/public-link fields'
  );

  const prefersSingleFields = new Map();
  for (const table of schema.tables || []) {
    for (const field of table.fields || []) {
      if (
        field.type === 'multipleRecordLinks' &&
        field.options &&
        field.options.prefersSingleRecordLink
      ) {
        prefersSingleFields.set(`${table.name}.${field.name}`, true);
      }
    }
  }

  const linkBlockPattern = /-- Link field: ([^.\n]+)\.(.+?) -> [^\n]+\n([\s\S]*?)DROP TABLE [^;]+;/g;
  let match;
  let checked = 0;
  while ((match = linkBlockPattern.exec(loadSql)) !== null) {
    const key = `${match[1]}.${match[2]}`;
    if (!prefersSingleFields.has(key)) continue;
    checked += 1;
    assert(
      match[3].includes('SELECT DISTINCT ON (a.nocopk) a.nocopk, b.nocopk'),
      `${key} must normalize duplicate exported links before inserting into its unique junction`
    );

    const copyMatch = match[3].match(/FROM (csv\/[^ ]+\.csv) WITH/);
    assert(copyMatch, `${key} must reference a generated relationship CSV`);
    const csvLines = fs.readFileSync(path.join(outDir, copyMatch[1]), 'utf8')
      .trim()
      .split(/\r?\n/)
      .slice(1)
      .filter(Boolean);
    const sourceIds = csvLines.map(line => line.split(',', 1)[0]);
    assert.strictEqual(
      new Set(sourceIds).size,
      sourceIds.length,
      `${key} generated more than one relationship row for a prefers-single source record`
    );
  }

  assert(
    checked > 0,
    'Expected at least one generated prefers-single link loader to validate'
  );

  const conflictReport = path.join(outDir, 'csv', '_prefers_single_link_conflicts.csv');
  if (fs.existsSync(conflictReport)) {
    const report = fs.readFileSync(conflictReport, 'utf8').trim().split(/\r?\n/);
    assert(report.length > 1, 'Conflict report should contain at least one data row when emitted');
    assert(
      loadSql.includes('Review csv/_prefers_single_link_conflicts.csv'),
      '100_load.sql should surface the generated prefers-single conflict report'
    );
  }

  console.log('Airtable-to-Postgres generator array, prefers-single link, and legacy public-link omission smoke tests passed.');
} finally {
  fs.rmSync(tempDir, { recursive: true, force: true });
}
