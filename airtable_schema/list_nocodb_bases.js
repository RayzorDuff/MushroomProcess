#!/usr/bin/env node
/* eslint-disable no-console */

require('./load_env');

async function main() {
  const baseId = ENV.NOCODB_BASE_ID;
  if (!baseId) throw new Error('NOCODB_BASE_ID is not set.');

  const url = `${ENV.META_PREFIX}/bases/${baseId}/sources`;

  const data = await ENV.apiCall('get', url);

  // NocoDB meta responses commonly return { list: [...] } (sometimes directly [...])
  const sources = Array.isArray(data?.list) ? data.list : (Array.isArray(data) ? data : []);

  if (!Array.isArray(sources) || sources.length === 0) {
    console.log('No sources returned (or unexpected response shape). Raw response:');
    console.dir(data, { depth: 6 });
    process.exit(0);
  }

  const rows = sources.map((s) => ({
    id: s.id ?? s.source_id ?? s.sourceId ?? '',
    alias: s.alias ?? s.title ?? s.name ?? '',
    type: s.type ?? s.client ?? s.engine ?? '',
    is_default: s.is_default ?? s.isDefault ?? '',
    status: s.status ?? '',
  }));

  console.log(`Base: ${baseId}`);
  console.log(`Meta API: ${ENV.META_PREFIX} (v${ENV.IS_V2 ? '2' : ENV.IS_V3 ? '3' : 'unknown'})`);
  console.log('');
  console.table(rows);

  // Also print a copy/paste friendly list:
  console.log('\nCopy/paste IDs:');
  for (const r of rows) {
    console.log(`- ${r.alias || '(no alias)'} => ${r.id}`);
  }
}

main().catch((err) => {
  console.error('ERROR:', err?.message || err);
  process.exit(1);
});
