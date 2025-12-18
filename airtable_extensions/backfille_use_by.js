/***********************
 * Backfill lots.use_by
 * Airtable Scripting Extension
 *
 * Safe default: only fills use_by if it's blank.
 ***********************/

// ====== CONFIG ======
const LOTS_TABLE_NAME = 'lots';

// Fields on lots
const FIELD_USE_BY = 'use_by';                       // Date field (new)
const FIELD_ITEM_CATEGORY = 'item_category';         // e.g. "grain", "lc_flask", etc.
const FIELD_LAST_INOC = 'last_inoculation_date';     // may be formula or date
const FIELD_INOC_AT = 'inoculated_at';               // date
const FIELD_SPAWNED_AT = 'spawned_at';               // date
const FIELD_STERILIZED_AT = 'sterilized_at';         // date

// Behavior toggles
const ONLY_WHEN_BLANK = true;     // true = do not overwrite existing use_by
const DRY_RUN = false;            // true = preview counts only, no writes
const MAX_RECORDS = 0;            // 0 = no limit; else limit processed records

// ====== Helpers ======
function toDate(value) {
  // Airtable date fields come as JS Date objects; formula fields might be strings.
  if (!value) return null;
  if (value instanceof Date) return isNaN(value.getTime()) ? null : value;
  const d = new Date(value);
  return isNaN(d.getTime()) ? null : d;
}

function addMonths(baseDate, months) {
  // Month-safe-ish add (JS will roll dates; consistent with your earlier automation behavior)
  const d = new Date(baseDate);
  d.setMonth(d.getMonth() + months);
  return d;
}

function getMonthsForCategory(catRaw) {
  const cat = (catRaw || '').toString().trim().toLowerCase();
  if (cat === 'lc_flask' || cat === 'lc_syringe') return 6;
  if (cat === 'grain' || cat === 'substrate' || cat === 'casing' || cat === 'fruiting_block') return 3;
  return null;
}

function pickBaseDate(rec) {
  // precedence: last_inoculation_date -> inoculated_at -> spawned_at -> sterilized_at
  const lastInoc = toDate(rec.getCellValue(FIELD_LAST_INOC));
  if (lastInoc) return { base: lastInoc, source: FIELD_LAST_INOC };

  const inocAt = toDate(rec.getCellValue(FIELD_INOC_AT));
  if (inocAt) return { base: inocAt, source: FIELD_INOC_AT };

  const spawnedAt = toDate(rec.getCellValue(FIELD_SPAWNED_AT));
  if (spawnedAt) return { base: spawnedAt, source: FIELD_SPAWNED_AT };

  const sterAt = toDate(rec.getCellValue(FIELD_STERILIZED_AT));
  if (sterAt) return { base: sterAt, source: FIELD_STERILIZED_AT };

  return { base: null, source: null };
}

// ====== Main ======
const lotsTable = base.getTable(LOTS_TABLE_NAME);

const query = await lotsTable.selectRecordsAsync({
  fields: [
    FIELD_USE_BY,
    FIELD_ITEM_CATEGORY,
    FIELD_LAST_INOC,
    FIELD_INOC_AT,
    FIELD_SPAWNED_AT,
    FIELD_STERILIZED_AT
  ]
});

let processed = 0;
let skippedAlreadySet = 0;
let skippedNoCategory = 0;
let skippedNoBaseDate = 0;
let skippedUnknownCategory = 0;
let toUpdate = [];

let byCategoryCounts = {};   // {cat: {updated: n, skipped: n}}
let bySourceCounts = {};     // {field: n}

function bump(map, key) {
  map[key] = (map[key] || 0) + 1;
}

for (const rec of query.records) {
  if (MAX_RECORDS > 0 && processed >= MAX_RECORDS) break;
  processed++;

  const currentUseBy = toDate(rec.getCellValue(FIELD_USE_BY));
  if (ONLY_WHEN_BLANK && currentUseBy) {
    skippedAlreadySet++;
    continue;
  }

  const catRaw = rec.getCellValue(FIELD_ITEM_CATEGORY);
  const cat = (catRaw || '').toString().trim().toLowerCase();
  if (!cat) {
    skippedNoCategory++;
    continue;
  }

  const months = getMonthsForCategory(cat);
  if (months == null) {
    skippedUnknownCategory++;
    bump(byCategoryCounts, `${cat} (unknown)`);
    continue;
  }

  const { base, source } = pickBaseDate(rec);
  if (!base) {
    skippedNoBaseDate++;
    bump(byCategoryCounts, `${cat} (no base date)`);
    continue;
  }

  const useBy = addMonths(base, months);

  // Track stats
  bump(byCategoryCounts, cat);
  if (source) bump(bySourceCounts, source);

  toUpdate.push({
    id: rec.id,
    fields: {
      [FIELD_USE_BY]: useBy
    }
  });
}

// Write in batches of 50
output.markdown(`### Backfill plan
- Records scanned: **${processed}**
- Updates to apply: **${toUpdate.length}**
- Skipped (already had use_by): **${skippedAlreadySet}**
- Skipped (no item_category): **${skippedNoCategory}**
- Skipped (unknown category): **${skippedUnknownCategory}**
- Skipped (no usable base date): **${skippedNoBaseDate}**
- Mode: **${DRY_RUN ? 'DRY RUN (no writes)' : 'LIVE'}**
- Fill policy: **${ONLY_WHEN_BLANK ? 'only when blank' : 'overwrite allowed'}**
`);

output.markdown(`### Updates by category`);
output.table(
  Object.entries(byCategoryCounts)
    .sort((a, b) => b[1] - a[1])
    .map(([k, v]) => ({ category: k, updates_planned: v }))
);

output.markdown(`### Base date sources used`);
output.table(
  Object.entries(bySourceCounts)
    .sort((a, b) => b[1] - a[1])
    .map(([k, v]) => ({ field_used_as_base_date: k, count: v }))
);

if (DRY_RUN) {
  output.markdown(`✅ Dry run complete. Set \`DRY_RUN = false\` to apply updates.`);
} else {
  let updated = 0;
  while (toUpdate.length) {
    const batch = toUpdate.slice(0, 50);
    toUpdate = toUpdate.slice(50);
    await lotsTable.updateRecordsAsync(batch);
    updated += batch.length;
  }
  output.markdown(`✅ Done. Updated **${updated}** record(s).`);
}
