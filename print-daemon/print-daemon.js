/**
 * Script: print-daemon.js
 * Version: 2026-08-08.3
 * Summary: NocoDB/Airtable print queue with automatic NocoDB v3 table-ID resolution
 * =============================================================================
 * Copyright © 2025 Dank Mushrooms, LLC
 * Licensed under the GNU General Public License v3 (GPL-3.0-only)
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 * =============================================================================
**/

/**
 * Multi-instance support:
 * - You can run multiple daemons on the same machine by setting DAEMON_INSTANCE_ID (and optionally ENV_FILE).
 * - Each instance uses its own logs/temp paths and can filter/claim jobs independently.
 */

// Support loading a non-default env file BEFORE reading process.env settings.
// Usage:
//   node print-daemon.js --env-file C:\path\to\.env.nontrays
// or set ENV_FILE / DOTENV_CONFIG_PATH in the environment.
const dotenv = require('dotenv');
const argv = process.argv.slice(2);
function getArgValue(flag) {
  const idx = argv.findIndex(a => a === flag || a.startsWith(flag + '='));
  if (idx < 0) return '';
  const a = argv[idx];
  if (a.includes('=')) return a.split('=').slice(1).join('=').trim();
  return String(argv[idx + 1] || '').trim();
}
const envFileFromArg = getArgValue('--env-file') || getArgValue('--env') || '';
const ENV_FILE = envFileFromArg || process.env.ENV_FILE || process.env.DOTENV_CONFIG_PATH || '';
dotenv.config(ENV_FILE ? { path: ENV_FILE } : undefined);

const axios = require('axios').default;
const fs = require('fs');
const path = require('path');
const PDFDocument = require('pdfkit');
const QRCode = require('qrcode');
let print = null;
try {
  // pdf-to-printer is Windows-oriented. Keep it optional so the daemon can run on macOS/Linux.
  ({ print } = require('pdf-to-printer'));
} catch (e) {
  print = null;
}
const { spawn } = require('child_process');

const os = require('os');

const PLATFORM = process.platform;
const IS_WINDOWS = PLATFORM === 'win32';
const IS_MAC = PLATFORM === 'darwin';
const IS_POSIX_PRINT = IS_MAC || PLATFORM === 'linux';

const INSTANCE_ID = (process.env.DAEMON_INSTANCE_ID || process.env.INSTANCE_ID || '').trim()
  || `${os.hostname()}-${process.pid}`;

// Instance-scoped directories to avoid collisions when multiple daemons run on the same machine.
const BASE_LOG_DIR = process.env.LOG_DIR || process.env.PDF_ARCHIVE_DIR || './logs';
const LOG_DIR = path.resolve(__dirname, BASE_LOG_DIR, INSTANCE_ID);
if (!fs.existsSync(LOG_DIR)) fs.mkdirSync(LOG_DIR, { recursive: true });

const TEMP_DIR = path.resolve(__dirname, process.env.TEMP_DIR || path.join('tmp', INSTANCE_ID));
if (!fs.existsSync(TEMP_DIR)) fs.mkdirSync(TEMP_DIR, { recursive: true });
/* ---------- Logging ---------- */
const LOG_LEVEL = String(process.env.LOG_LEVEL || (process.env.VERBOSE ? 'debug' : 'info')).toLowerCase();
const LOG_JSON = String(process.env.LOG_JSON || 'false').toLowerCase() === 'true';
const LOG_TO_FILE = String(process.env.LOG_TO_FILE || 'true').toLowerCase() === 'true';
const LOG_TO_CONSOLE = String(process.env.LOG_TO_CONSOLE || 'true').toLowerCase() === 'true';
const LOG_FILE_BASENAME = (process.env.LOG_FILE || 'daemon.log').trim();
const LOG_FILE_PATH = path.join(BASE_LOG_DIR, INSTANCE_ID + "_" + LOG_FILE_BASENAME);
const MAX_LOG_BYTES = safeNum(process.env.MAX_LOG_BYTES, 5 * 1024 * 1024); // 5MB
const MAX_LOG_BACKUPS = safeNum(process.env.MAX_LOG_BACKUPS, 5);

const LEVELS = { error: 0, warn: 1, info: 2, debug: 3, trace: 4 };
const ACTIVE_LEVEL = (LOG_LEVEL in LEVELS) ? LEVELS[LOG_LEVEL] : LEVELS.info;

function rotateLogIfNeeded() {
  if (!LOG_TO_FILE) return;
  try {
    if (!fs.existsSync(LOG_FILE_PATH)) return;
    const st = fs.statSync(LOG_FILE_PATH);
    if (!st.isFile() || st.size < MAX_LOG_BYTES) return;

    // Shift backups: .4 -> .5, .3 -> .4, ... .1 -> .2, base -> .1
    for (let i = MAX_LOG_BACKUPS - 1; i >= 1; i--) {
      const from = `${LOG_FILE_PATH}.${i}`;
      const to = `${LOG_FILE_PATH}.${i + 1}`;
      if (fs.existsSync(from)) {
        try { fs.renameSync(from, to); } catch {}
      }
    }
    try { fs.renameSync(LOG_FILE_PATH, `${LOG_FILE_PATH}.1`); } catch {}
  } catch {}
}

function writeLogLine(line) {
  if (LOG_TO_CONSOLE) {
    // Console output
    process.stdout.write(line + "\n");
  }
  if (LOG_TO_FILE) {
    rotateLogIfNeeded();
    try {
      fs.appendFileSync(LOG_FILE_PATH, line + "\n", { encoding: 'utf8' });
    } catch {}
  }
}

function logLine(level, msg, meta) {
  const lvl = String(level || 'info').toLowerCase();
  const n = (lvl in LEVELS) ? LEVELS[lvl] : LEVELS.info;
  if (n > ACTIVE_LEVEL) return;

  const ts = new Date().toISOString();
  const base = { ts, level: lvl, instance: INSTANCE_ID, msg: String(msg || '') };

  if (LOG_JSON) {
    const out = { ...base };
    if (meta && typeof meta === 'object') out.meta = meta;
    writeLogLine(JSON.stringify(out));
  } else {
    let line = `${ts} [${lvl.toUpperCase()}] [${INSTANCE_ID}] ${base.msg}`;
    if (meta && typeof meta === 'object') {
      // keep compact; avoid dumping giant objects
      const safe = {};
      for (const [k, v] of Object.entries(meta)) {
        if (v == null) continue;
        const s = (typeof v === 'string') ? v : JSON.stringify(v);
        safe[k] = s.length > 500 ? (s.slice(0, 500) + '…') : s;
      }
      const tail = Object.keys(safe).length ? ` ${JSON.stringify(safe)}` : '';
      line += tail;
    }
    writeLogLine(line);
  }
}

const log = {
  error: (m, meta) => logLine('error', m, meta),
  warn:  (m, meta) => logLine('warn',  m, meta),
  info:  (m, meta) => logLine('info',  m, meta),
  debug: (m, meta) => logLine('debug', m, meta),
  trace: (m, meta) => logLine('trace', m, meta),
};

// Standardized status line for operators watching logs.
function status(jobId, phase, meta = {}) {
  log.info(`STATUS job=${jobId} ${phase}`, meta);
}

function nowStamp() {
  return new Date().toISOString().replace(/[:.]/g, '-');
}

const DB_BACKEND = String(process.env.DB_BACKEND || 'airtable').toLowerCase();
const NOCODB_API_VERSION = String(process.env.NOCODB_API_VERSION || 'v2').toLowerCase();
const IS_NOCODB_V3_CONFIG = DB_BACKEND !== 'airtable' && NOCODB_API_VERSION === 'v3';

// NocoDB's v3 data and metadata URLs use the base identifier in the first path
// segment. NOCODB_SOURCE_ID and NOCODB_BASE_SOURCE_ID remain accepted as legacy
// aliases because older daemon examples used those names.
const NOCODB_BASE_ID = (
  process.env.NOCODB_BASE_ID ||
  process.env.NOCODB_SOURCE_ID ||
  process.env.NOCODB_BASE_SOURCE_ID ||
  ''
).trim();
const NOCODB_SOURCE_ID = NOCODB_BASE_ID; // Backward-compatible internal alias.
const NOCODB_PAGE_SIZE = safeNum(process.env.NOCODB_PAGE_SIZE, 25);
const NOCODB_AUTO_RESOLVE_IDS = String(process.env.NOCODB_AUTO_RESOLVE_IDS || 'true').toLowerCase() !== 'false';
const CHECK_CONFIG_ONLY = argv.includes('--check-config');

// Airtable and NocoDB v2 can use table names/IDs directly. NocoDB v3 needs
// internal table IDs, but the daemon resolves the MushroomProcess logical names
// below through NocoDB metadata at startup when IDs were not supplied.
const PRINT_QUEUE_TABLE = process.env.PRINT_QUEUE_TABLE || process.env.AIRTABLE_QUEUE_TABLE || process.env.NOCODB_QUEUE_TABLE_ID || 'print_queue';
let PRINT_QUEUE_READ_TABLE = process.env.PRINT_QUEUE_READ_TABLE || process.env.PRINT_QUEUE_TABLE_READ || (IS_NOCODB_V3_CONFIG ? 'vc_print_queue' : PRINT_QUEUE_TABLE);
let PRINT_QUEUE_WRITE_TABLE = process.env.PRINT_QUEUE_WRITE_TABLE || process.env.PRINT_QUEUE_TABLE_WRITE || PRINT_QUEUE_TABLE;
const PRINT_QUEUE_READ_VIEW_ID = cleanOptionalNocoIdentifier(process.env.PRINT_QUEUE_READ_VIEW_ID || process.env.PRINT_QUEUE_VIEW_ID || process.env.NOCODB_QUEUE_VIEW_ID || '');
const PRINT_QUEUE_WRITE_VIEW_ID = cleanOptionalNocoIdentifier(process.env.PRINT_QUEUE_WRITE_VIEW_ID || '');
const PRINT_QUEUE_WRITE_ID_FIELD = (process.env.PRINT_QUEUE_WRITE_ID_FIELD || 'nocopk').trim();

let STERILIZATION_RUNS_TABLE = process.env.STERILIZATION_RUNS_TABLE || (IS_NOCODB_V3_CONFIG ? 'vc_sterilization_runs' : 'sterilization_runs');
const STERILIZATION_RUNS_VIEW_ID = cleanOptionalNocoIdentifier(process.env.STERILIZATION_RUNS_VIEW_ID || '');
let LOTS_TABLE = process.env.LOTS_TABLE || (IS_NOCODB_V3_CONFIG ? 'vc_lots' : 'lots');
const LOTS_VIEW_ID = cleanOptionalNocoIdentifier(process.env.LOTS_VIEW_ID || '');
let PRODUCTS_TABLE = process.env.PRODUCTS_TABLE || (IS_NOCODB_V3_CONFIG ? 'vc_products' : 'products');
const PRODUCTS_VIEW_ID = cleanOptionalNocoIdentifier(process.env.PRODUCTS_VIEW_ID || '');

const QUEUE_VIEW = process.env.QUEUE_VIEW || null;

// Optional: job routing without relying on Airtable views.
// If PRINT_TARGET_VALUE is set, the daemon will only process jobs where
//   {PRINT_TARGET_FIELD} == PRINT_TARGET_VALUE
// Example:
//   PRINT_TARGET_FIELD=print_target
//   PRINT_TARGET_VALUE=ZEBRA
const PRINT_TARGET_FIELD = (process.env.PRINT_TARGET_FIELD || 'print_target').trim();
const PRINT_TARGET_VALUE = (process.env.PRINT_TARGET_VALUE || '').trim();

// Optional: further Airtable formula/NocoDB where clause overrides (advanced).
const AIRTABLE_EXTRA_FILTER_FORMULA = (process.env.AIRTABLE_EXTRA_FILTER_FORMULA || '').trim();
const NOCODB_EXTRA_WHERE = (process.env.NOCODB_EXTRA_WHERE || '').trim();

// Optional: allow disabling sterilizer sheet printing for secondary daemon instances.
const ENABLE_STERI_SHEETS = String(process.env.ENABLE_STERI_SHEETS || 'true').toLowerCase() === 'true';


const AIRTABLE_BASE_ID = (process.env.AIRTABLE_BASE_ID);
const AIRTABLE_API_KEY =
  process.env.AIRTABLE_API_KEY ||
  process.env.AIRTABLE_TOKEN ||
  process.env.AIRTABLE_API_TOKEN ||
  '';

const NOCODB_BASE_URL = (process.env.NOCODB_URL || '').replace(/\/+$/, '');
const NOCODB_API_TOKEN = process.env.NOCODB_API_TOKEN || process.env.NC_TOKEN || '';


let API, NC;

if (DB_BACKEND === 'airtable') {
  /* ---------- Airtable ---------- */  
  API = axios.create({
    baseURL: `https://api.airtable.com/v0/${AIRTABLE_BASE_ID}/`,
    headers: { Authorization: `Bearer ${AIRTABLE_API_KEY}` },
  });
} else {
  /* ---------- NocoDB  ---------- */
  NC = axios.create({
    baseURL: NOCODB_BASE_URL || 'http://localhost:8080',
    headers: NOCODB_API_TOKEN
      ? { 'xc-token': NOCODB_API_TOKEN }
      : {},
  });
}

/* ---------- Safe numbers & utils ---------- */
function safeNum(val, fb) {
  if (val === undefined || val === null) return fb;
  const n = Number(String(val).trim());
  return Number.isFinite(n) ? n : fb;
}

const in2pt = (inches) => Math.round(safeNum(inches, 0) * 72);

function parsePostgresArrayLiteral(value) {
  const text = String(value || '').trim();
  if (text.length < 2 || text[0] !== '{' || text[text.length - 1] !== '}') return null;

  const inner = text.slice(1, -1);
  if (inner === '') return [];

  const values = [];
  let current = '';
  let inQuotes = false;
  let escaped = false;
  let quoted = false;

  const pushValue = () => {
    const raw = quoted ? current : current.trim();
    values.push(!quoted && raw.toUpperCase() === 'NULL' ? null : raw);
    current = '';
    quoted = false;
  };

  for (let i = 0; i < inner.length; i += 1) {
    const ch = inner[i];

    if (escaped) {
      current += ch;
      escaped = false;
      continue;
    }

    if (inQuotes) {
      if (ch === '\\') {
        escaped = true;
      } else if (ch === '"') {
        inQuotes = false;
      } else {
        current += ch;
      }
      continue;
    }

    if (ch === '"' && current.trim() === '') {
      inQuotes = true;
      quoted = true;
      current = '';
      continue;
    }

    if (ch === ',') {
      pushValue();
      continue;
    }

    // Nested PostgreSQL arrays are not expected in label fields. Refuse to
    // transform them rather than flattening potentially meaningful text.
    if (ch === '{' || ch === '}') return null;

    current += ch;
  }

  if (inQuotes || escaped) return null;
  pushValue();
  return values;
}

function structuredTextValue(value) {
  const text = String(value || '').trim();
  if (!text) return null;

  if (
    (text.startsWith('[') && text.endsWith(']')) ||
    (text.startsWith('{') && text.endsWith('}'))
  ) {
    try {
      return JSON.parse(text);
    } catch {
      // PostgreSQL text[] values commonly arrive from NocoDB v3 as strings
      // such as {"Freezer Tray"}. They are not JSON objects, so parse them
      // with PostgreSQL array-literal rules after JSON parsing fails.
    }
  }

  return parsePostgresArrayLiteral(text);
}

function toFlat(v) {
  if (v == null) return '';

  if (Array.isArray(v)) {
    return v
      .map(toFlat)
      .map(value => String(value || '').trim())
      .filter(Boolean)
      .join(', ');
  }

  if (typeof v === 'object') {
    for (const key of ['name', 'title', 'label', 'value', 'display_value', 'text']) {
      if (Object.prototype.hasOwnProperty.call(v, key)) {
        const flattened = toFlat(v[key]);
        if (flattened) return flattened;
      }
    }

    const entries = Object.entries(v).filter(([, value]) => value != null && value !== '');
    if (entries.length === 1) return toFlat(entries[0][1]);
    return '';
  }

  if (typeof v === 'string') {
    const structured = structuredTextValue(v);
    if (structured !== null) return toFlat(structured);
  }

  return String(v);
}

function pick(fields, keys) {
  for (const k of keys) {
    if (k in fields) {
      const val = toFlat(fields[k]);
      if (val) return val;
    }
  }
  return '';
}

function extractInventoryId(value, expectedKind = '') {
  const text = toFlat(value).trim();
  if (!text) return '';

  const matches = text.match(/\b(?:PROD|LOT)-[A-Za-z0-9]+(?:-[A-Za-z0-9]+)*\b/gi) || [];
  const expectedPrefix = String(expectedKind || '').trim().toLowerCase() === 'product'
    ? 'PROD-'
    : String(expectedKind || '').trim().toLowerCase() === 'lot'
      ? 'LOT-'
      : '';

  for (const match of matches) {
    if (!expectedPrefix || match.toUpperCase().startsWith(expectedPrefix)) {
      return match;
    }
  }

  return '';
}

function buildQrResolverUrl(inventoryId) {
  const id = extractInventoryId(inventoryId);
  if (!id) return '';

  const base = String(QR_RESOLVER_BASE_URL || '').trim();
  if (!base) return '';

  const separator = base.includes('?')
    ? (base.endsWith('?') || base.endsWith('&') ? '' : '&')
    : '?';

  return `${base}${separator}i=${encodeURIComponent(id)}`;
}

function stableQrUrlFromFields(fields, kind) {
  const f = fields || {};
  const normalizedKind = String(kind || '').trim().toLowerCase();

  const explicit = pick(f, [
    'scan_url',
    normalizedKind === 'product' ? 'scan_url_from_product_id' : 'scan_url_from_lot_id',
    normalizedKind === 'product' ? 'scan_url (from product_id)' : 'scan_url (from lot_id)',
  ]);
  if (explicit) return explicit;

  const identityCandidates = normalizedKind === 'product'
    ? [
        'product_number',
        'product_code',
        'label_footer_prod',
        'label_footer_prod_from_product_id',
        'label_footer_prod (from product_id)',
      ]
    : [
        'lot_number',
        'lot_code',
        'label_footer_lot',
        'label_footer_lot_from_lot_id',
        'label_footer_lot (from lot_id)',
      ];

  for (const key of identityCandidates) {
    if (!(key in f)) continue;
    const id = extractInventoryId(f[key], normalizedKind);
    const resolved = buildQrResolverUrl(id);
    if (resolved) return resolved;
  }

  return '';
}

function labelQrUrl(fields, kind) {
  return stableQrUrlFromFields(fields, kind);
}

function quoteNocoWhereValue(value) {
  const text = String(value ?? '').trim();
  if (/^-?(?:\d+|\d*\.\d+)$/.test(text)) return text;
  return `"${text
    .replace(/\\/g, '\\\\')
    .replace(/"/g, '\\"')}"`;
}

function nocoV3Where(field, operator, value) {
  const safeField = String(field || '').trim();
  const safeOperator = String(operator || '').trim();
  if (!safeField || !safeOperator) {
    throw new Error('NocoDB where clause requires a field and operator');
  }
  return `(${safeField},${safeOperator},${quoteNocoWhereValue(value)})`;
}

function combineNocoV3WhereClauses(clauses) {
  return (Array.isArray(clauses) ? clauses : [clauses])
    .map(clause => String(clause || '').trim())
    .filter(Boolean)
    .join('~and');
}

function buildNocoV3QueueWhere(
  printTargetField = PRINT_TARGET_FIELD,
  printTargetValue = PRINT_TARGET_VALUE,
  extraWhere = NOCODB_EXTRA_WHERE
) {
  const clauses = [nocoV3Where('print_status', 'eq', 'Queued')];

  const targetValue = String(printTargetValue || '').trim();
  if (targetValue) {
    const targetField = String(printTargetField || 'print_target').trim() || 'print_target';
    clauses.push(nocoV3Where(targetField, 'eq', targetValue));
  }

  const extra = String(extraWhere || '').trim();
  if (extra) clauses.push(extra);

  return combineNocoV3WhereClauses(clauses);
}

function printTargetForSource(sourceKind, itemCategory) {
  const kind = String(sourceKind || '').trim().toLowerCase();
  const category = String(toFlat(itemCategory) || '').trim().toLowerCase();

  if (kind === 'steri_sheet') return 'ZEBRA';
  if (['fresh_mushrooms', 'freezer_tray', 'fresh_tray'].includes(category)) return 'TRAYS';
  return 'ZEBRA';
}

function queueSourceLinkValue(fields, sourceKind) {
  const f = fields || {};
  const kind = String(sourceKind || '').trim().toLowerCase();
  const aliases = kind === 'product'
    ? ['product_id', 'product', 'products']
    : kind === 'lot'
      ? ['lot_id', 'lot', 'lots']
      : [];

  for (const key of aliases) {
    if (Object.prototype.hasOwnProperty.call(f, key) && f[key] != null && f[key] !== '') {
      return f[key];
    }
  }

  // NocoDB can expose external-database link titles with display-oriented
  // punctuation/casing. Match conservative aliases without accidentally
  // accepting lookup fields such as label_*_from_product_id.
  const normalizedAliases = new Set(
    aliases.map(key => key.toLowerCase().replace(/[^a-z0-9]/g, ''))
  );
  for (const [key, value] of Object.entries(f)) {
    const normalizedKey = String(key || '').toLowerCase().replace(/[^a-z0-9]/g, '');
    if (normalizedAliases.has(normalizedKey) && value != null && value !== '') {
      return value;
    }
  }

  return '';
}

function queueSourcePk(fields, sourceKind) {
  const raw = queueSourceLinkValue(fields, sourceKind);
  if (raw == null || raw === '') return '';

  // With linksAsLtar=true, NocoDB v3 returns Link fields as linked record
  // objects. Prefer the linked record's actual Record ID / nocopk, not its
  // display value (which may be a business ID such as PROD-... or LOT-...).
  const linked = linkedNocoValue(raw, ['nocopk']);
  return String(toFlat(linked || raw) || '').trim();
}

function queueSourceBusinessId(fields, sourceKind) {
  const kind = String(sourceKind || '').trim().toLowerCase();
  const businessField = kind === 'product' ? 'product_id' : kind === 'lot' ? 'lot_id' : '';
  if (!businessField) return '';

  const raw = queueSourceLinkValue(fields, kind);
  const one = Array.isArray(raw) ? raw[0] : raw;
  if (!one || typeof one !== 'object') {
    const flat = String(toFlat(one) || '').trim();
    return /^(?:PROD|LOT)-/i.test(flat) ? flat : '';
  }

  const linkedFields = one.fields && typeof one.fields === 'object' ? one.fields : {};
  const idFields = one.id_fields && typeof one.id_fields === 'object' ? one.id_fields : {};
  return String(toFlat(linkedFields[businessField] ?? idFields[businessField] ?? '') || '').trim();
}

function nocoV3SourceFieldNames(sourceKind) {
  const kind = String(sourceKind || '').trim().toLowerCase();
  if (kind === 'product') {
    return [
      'product_id',
      'item_category_mat',
      'label_company_prod',
      'label_companyaddress_prod',
      'label_disclaimer_prod',
      'label_companyinfo_prod',
      'label_cottage_prod',
      'label_title_prod',
      'label_subtitle_prod',
      'label_footer_prod',
      'label_packaged_prod',
      'label_useby_prod',
      'label_inoc_prod',
      'label_spawned_prod',
      'label_proc_prod',
    ];
  }

  if (kind === 'lot') {
    return [
      'lot_id',
      'item_category_mat',
      'label_company_lot',
      'label_title_lot',
      'label_subtitle_lot',
      'label_footer_lot',
      'label_substrateinputblocks_line',
      'label_graininputblocks_line',
      'label_useby_line',
      'label_spawned_line',
      'label_inoc_line',
      'label_proc_line',
    ];
  }

  return [];
}

function mergeQueueSourceFields(queueFields, sourceFields, printTarget) {
  return {
    ...(sourceFields || {}),
    ...(queueFields || {}),
    [PRINT_TARGET_FIELD]: printTarget,
  };
}

function normalizeRunMatchTargets(runIds) {
  const pending = Array.isArray(runIds) ? [...runIds] : [runIds];
  const targets = [];

  while (pending.length) {
    const value = pending.shift();
    if (Array.isArray(value)) {
      pending.unshift(...value);
      continue;
    }
    const target = String(toFlat(value) || '').trim();
    if (target && !targets.includes(target)) targets.push(target);
  }

  return targets;
}

function valueMatchesRunId(value, runIds) {
  const targets = normalizeRunMatchTargets(runIds);
  if (!targets.length || value == null) return false;

  const flat = String(toFlat(value) || '').trim();
  if (targets.includes(flat)) return true;

  const linked = String(toFlat(
    linkedNocoValue(value, ['steri_run_id', 'nocopk'])
  ) || '').trim();
  if (targets.includes(linked)) return true;

  try {
    const encoded = JSON.stringify(value);
    return targets.some(target => encoded.includes(target));
  } catch {
    return false;
  }
}

function lotMatchesRun(row, runIds) {
  const f = row && row.fields && typeof row.fields === 'object'
    ? row.fields
    : nocoV3RecordFields(row);

  return [
    f.steri_run_id,
    f.sterilization_run_id,
    f.sterilization_runs,
  ].some(value => valueMatchesRunId(value, runIds));
}

function steriSheetRunFields(runRec) {
  const f = (runRec && runRec.fields) || {};
  return {
    runNo: pick(f, ['steri_run_id']) || String(runRec?.id || ''),
    processType: pick(f, ['process_type']) || inferProcessTypeFromRun(f),
    operator: pick(f, ['operator']),
    start: f.start_time,
    end: f.end_time || f.override_end_time,
    plannedItem: pick(f, [
      'planned_item_name',
      'planned_item',
      'planned_item_id',
    ]),
    plannedCount: f.planned_count ?? '',
    plannedSize: f.planned_unit_size ?? '',
    goodCount: f.good_count ?? '',
    destroyedCount: f.destroyed_count ?? '',
  };
}

function steriSheetLotFields(lotRec) {
  const f = (lotRec && lotRec.fields) || {};
  const lotId = pick(f, ['lot_id']) || String(lotRec?.id || '');
  return {
    lotId,
    itemName: pick(f, ['item_name', 'item_name_mat', 'item_id']),
    recipeName: pick(f, ['recipe_name', 'name_from_recipe_id', 'recipe_id']),
    unit: pick(f, ['unit_size', 'planned_unit_size']),
    status: pick(f, ['status']),
    qrUrl: pick(f, ['scan_url']) || buildQrResolverUrl(lotId),
  };
}

function isNocoV3() {
  return DB_BACKEND !== 'airtable' && NOCODB_API_VERSION === 'v3';
}

function cleanOptionalNocoIdentifier(value) {
  const text = String(value || '').trim();
  if (!text) return '';
  if (/(_id_?here|placeholder|replace_me)/i.test(text)) return '';
  return text;
}

function looksLikeNocoV3TableId(value) {
  const text = String(value || '').trim();
  return /^(?:m[a-z0-9]{10,}|md_[a-z0-9]{8,})$/i.test(text);
}

function normalizeNocoName(value) {
  return String(value || '')
    .trim()
    .replace(/^public\./i, '')
    .replace(/^"|"$/g, '')
    .toLowerCase();
}

let nocoV3TableMetadataCache = null;

async function listNocoV3Tables() {
  if (nocoV3TableMetadataCache) return nocoV3TableMetadataCache;
  if (!NOCODB_BASE_ID) {
    throw new Error(
      'NOCODB_BASE_ID is required for NocoDB v3. ' +
      'NOCODB_SOURCE_ID is still accepted as a legacy alias.'
    );
  }

  const encodedBase = encodeURIComponent(NOCODB_BASE_ID);
  const endpoints = [
    `/api/v3/meta/bases/${encodedBase}/tables`,
    `/api/v2/meta/bases/${encodedBase}/tables`,
  ];
  const failures = [];

  for (const endpoint of endpoints) {
    try {
      const { data } = await NC.get(endpoint, { params: { pageSize: 1000 } });
      const list = Array.isArray(data)
        ? data
        : Array.isArray(data?.list)
          ? data.list
          : Array.isArray(data?.tables)
            ? data.tables
            : [];

      if (list.length) {
        nocoV3TableMetadataCache = list;
        log.debug('Loaded NocoDB table metadata', { endpoint, count: list.length });
        return list;
      }
      failures.push(`${endpoint}: returned no tables`);
    } catch (error) {
      const statusCode = error?.response?.status;
      failures.push(`${endpoint}: ${statusCode || error?.message || String(error)}`);
    }
  }

  throw new Error(
    'Unable to list NocoDB tables for automatic ID resolution. ' +
    failures.join(' | ') + '. Set the table IDs explicitly or grant the token metadata access.'
  );
}

function nocoTableNames(table) {
  return [table?.title, table?.table_name, table?.name]
    .map(normalizeNocoName)
    .filter(Boolean);
}

async function resolveNocoV3TableReference(label, configuredValue, fallbackNames) {
  const configured = String(configuredValue || '').trim();
  if (looksLikeNocoV3TableId(configured)) return configured;

  if (!NOCODB_AUTO_RESOLVE_IDS) {
    throw new Error(
      `${label} must be a NocoDB table ID when NOCODB_AUTO_RESOLVE_IDS=false; got "${configured}".`
    );
  }

  const tables = await listNocoV3Tables();
  const requestedNames = [configured, ...(fallbackNames || [])]
    .map(normalizeNocoName)
    .filter(Boolean);

  for (const requested of requestedNames) {
    const matches = tables.filter(table => nocoTableNames(table).includes(requested));
    if (matches.length === 1 && matches[0]?.id) {
      const resolved = String(matches[0].id);
      log.info('Resolved NocoDB table', {
        setting: label,
        requested: configured || requested,
        matched_name: matches[0].title || matches[0].table_name || requested,
        table_id: resolved,
      });
      return resolved;
    }
    if (matches.length > 1) {
      throw new Error(
        `${label} matched more than one NocoDB table named "${requested}". Set its table ID explicitly.`
      );
    }
  }

  const available = tables
    .map(table => table?.title || table?.table_name || table?.id)
    .filter(Boolean)
    .slice(0, 40)
    .join(', ');
  throw new Error(
    `${label} could not resolve "${configured}". Tried: ${requestedNames.join(', ')}. ` +
    `Available tables include: ${available || '(none returned)'}.`
  );
}

async function resolveNocoV3Configuration() {
  if (!isNocoV3()) return;

  // NocoDB currently returns HTTP 500 when querying vc_print_queue even though
  // PostgreSQL can query that view directly. Do not depend on that view for
  // daemon polling; read Queued rows from print_queue and hydrate label data
  // from vc_lots / vc_products instead.
  PRINT_QUEUE_WRITE_TABLE = await resolveNocoV3TableReference(
    'PRINT_QUEUE_WRITE_TABLE',
    PRINT_QUEUE_WRITE_TABLE,
    ['print_queue']
  );
  LOTS_TABLE = await resolveNocoV3TableReference(
    'LOTS_TABLE',
    LOTS_TABLE,
    ['vc_lots', 'lots']
  );
  PRODUCTS_TABLE = await resolveNocoV3TableReference(
    'PRODUCTS_TABLE',
    PRODUCTS_TABLE,
    ['vc_products', 'products']
  );

  if (ENABLE_STERI_SHEETS) {
    STERILIZATION_RUNS_TABLE = await resolveNocoV3TableReference(
      'STERILIZATION_RUNS_TABLE',
      STERILIZATION_RUNS_TABLE,
      ['vc_sterilization_runs', 'sterilization_runs']
    );
  }

  if (PRINT_QUEUE_WRITE_VIEW_ID) {
    log.warn('PRINT_QUEUE_WRITE_VIEW_ID is not used for NocoDB v3 PATCH requests and may be removed from .env.');
  }

}

function nocoV3RecordsPath(tableId) {
  if (!NOCODB_BASE_ID) {
    throw new Error(
      'NOCODB_BASE_ID is required when NOCODB_API_VERSION=v3 ' +
      '(NOCODB_SOURCE_ID is accepted as a legacy alias)'
    );
  }
  if (!tableId) {
    throw new Error('NocoDB v3 table id is required');
  }
  return `/api/v3/data/${encodeURIComponent(NOCODB_BASE_ID)}/${encodeURIComponent(tableId)}/records`;
}

async function fetchNocoV3Records(tableId, viewId = '', params = {}, allPages = false) {
  const out = [];
  let url = nocoV3RecordsPath(tableId);
  let first = true;

  while (url) {
    const requestParams = first
      ? {
          pageSize: NOCODB_PAGE_SIZE,
          ...(viewId ? { viewId } : {}),
          ...params,
        }
      : undefined;

    const { data } = await NC.get(url, requestParams ? { params: requestParams } : undefined);
    const records = data && Array.isArray(data.records) ? data.records : [];
    out.push(...records);

    if (!allPages) break;
    url = data && data.next ? data.next : '';
    first = false;
  }

  return out;
}

function nocoV3RecordFields(row) {
  return (row && row.fields && typeof row.fields === 'object') ? row.fields : {};
}

function nocoV3RecordId(row, preferredField = 'nocopk') {
  const f = nocoV3RecordFields(row);
  const idFields = (row && row.id_fields && typeof row.id_fields === 'object') ? row.id_fields : {};

  const candidates = [
    preferredField ? f[preferredField] : undefined,
    preferredField ? idFields[preferredField] : undefined,
    f.nocopk,
    idFields.nocopk,
    row && row.id,
    row && row.Id,
  ];

  for (const v of candidates) {
    if (v !== undefined && v !== null && String(v).trim() !== '') return v;
  }
  return null;
}

function normalizeNocoV3QueueRecord(row) {
  return {
    id: nocoV3RecordId(row, PRINT_QUEUE_WRITE_ID_FIELD),
    read_id: row && row.id,
    fields: nocoV3RecordFields(row),
    _raw: row,
  };
}

function linkedNocoValue(value, fieldNames = []) {
  if (value == null) return '';
  const one = Array.isArray(value) ? value[0] : value;
  if (one == null) return '';
  if (typeof one !== 'object') return one;

  const f = one.fields && typeof one.fields === 'object' ? one.fields : {};
  const idf = one.id_fields && typeof one.id_fields === 'object' ? one.id_fields : {};

  for (const k of fieldNames) {
    if (f[k] !== undefined && f[k] !== null && String(f[k]).trim() !== '') return f[k];
    if (idf[k] !== undefined && idf[k] !== null && String(idf[k]).trim() !== '') return idf[k];
  }

  return one.id ?? one.Id ?? idf.nocopk ?? '';
}

function nocoV3MatchesRecord(row, value, fieldNames = []) {
  const target = String(value || '').trim();
  if (!target) return false;
  const f = nocoV3RecordFields(row);
  const id = nocoV3RecordId(row);

  if (String(row?.id ?? '').trim() === target) return true;
  if (String(id ?? '').trim() === target) return true;

  for (const k of fieldNames) {
    if (String(f[k] ?? '').trim() === target) return true;
  }

  return false;
}

/* ---------- Env (hardened) ---------- */
const PRINTER = process.env.PRINTER_NAME || process.env.DEFAULT_PRINTER || undefined; // label printer
const POLL_MS = safeNum(process.env.POLL_MS, 10000);

const FORM_NAME = (process.env.PAPER_FORM_NAME || '').trim();
const LABEL_W_IN = safeNum(process.env.LABEL_WIDTH_IN, 4);
const LABEL_H_IN = safeNum(process.env.LABEL_HEIGHT_IN, 2);

const ORIENT = (process.env.ORIENTATION || 'portrait').toLowerCase();
const FORCE_LAND = String(process.env.FORCE_LANDSCAPE || 'false').toLowerCase() === 'true';
const FORCE_PAGE = String(process.env.FORCE_PAGE_SIZE || 'false').toLowerCase() === 'true';
const FORCE_W_PT = safeNum(process.env.FORCE_PAGE_WIDTH_PT, 288); // 4 in
const FORCE_H_PT = safeNum(process.env.FORCE_PAGE_HEIGHT_PT, 144); // 2 in

const MARGIN_PT = safeNum(process.env.MARGIN_PT, 8);
const LOGO_W_PT = safeNum(process.env.LOGO_WIDTH_PT, 140);
const QR_SIZE_PT = safeNum(process.env.QR_SIZE_PT, 90);
const QR_RESOLVER_BASE_URL = String(
  process.env.QR_RESOLVER_BASE_URL || 'https://qr.danks.store/r'
).trim();

// Product_Package_Sample labels are dense 4x2 labels that keep product identity,
// package/use-by dates, and the product disclaimer on one physical label.
const SAMPLE_LOGO_W_PT = safeNum(process.env.SAMPLE_LOGO_WIDTH_PT, Math.min(70, LOGO_W_PT));
const SAMPLE_QR_SIZE_PT = safeNum(process.env.SAMPLE_QR_SIZE_PT, 34);
const SAMPLE_INCLUDE_QR = String(process.env.SAMPLE_INCLUDE_QR || 'true').toLowerCase() !== 'false';
const SAMPLE_LOGO_TEXT_GAP_PT = safeNum(process.env.SAMPLE_LOGO_TEXT_GAP_PT, 2);
const SAMPLE_COMPANY_INFO_MAX_FONT = safeNum(process.env.SAMPLE_COMPANY_INFO_MAX_FONT, 7);
const SAMPLE_COMPANY_ADDRESS_MAX_FONT = safeNum(process.env.SAMPLE_COMPANY_ADDRESS_MAX_FONT, 6);
const SAMPLE_COTTAGE_MAX_FONT = safeNum(process.env.SAMPLE_COTTAGE_MAX_FONT, 6);
const SAMPLE_TITLE_MAX_FONT = safeNum(process.env.SAMPLE_TITLE_MAX_FONT, 7.5);
const SAMPLE_SUBTITLE_MAX_FONT = safeNum(process.env.SAMPLE_SUBTITLE_MAX_FONT, 7.5);
const SAMPLE_META_MAX_FONT = safeNum(process.env.SAMPLE_META_MAX_FONT, 7);
const SAMPLE_DISCLAIMER_MAX_FONT = safeNum(process.env.SAMPLE_DISCLAIMER_MAX_FONT, 6.5);
const SAMPLE_LOWER_MIN_FONT = safeNum(process.env.SAMPLE_LOWER_MIN_FONT, 3.75);
const SAMPLE_FOOTER_MAX_FONT = safeNum(process.env.SAMPLE_FOOTER_MAX_FONT, 7);
const SAMPLE_FOOTER_MIN_FONT = safeNum(process.env.SAMPLE_FOOTER_MIN_FONT, 5);
const SAMPLE_FOOTER_RESERVE_PT = safeNum(process.env.SAMPLE_FOOTER_RESERVE_PT, 11);

const DRAW_BORDER = String(process.env.DRAW_PAGE_BORDER || 'false').toLowerCase() === 'true';

const USE_SUMATRA = IS_WINDOWS && String(process.env.USE_SUMATRA || 'false').toLowerCase() === 'true';
const SUMATRA_EXE = process.env.SUMATRA_EXE || 'SumatraPDF.exe';
const SUMATRA_SETTINGS = process.env.SUMATRA_PRINT_SETTINGS || 'noscale,portrait';

// macOS/Linux printing via CUPS command-line tools. On macOS this uses /usr/bin/lp.
// Use `lpstat -p -d` to find printer names and `lpoptions -p <printer> -l` to inspect driver options.
const LP_COMMAND = process.env.LP_COMMAND || 'lp';
const LP_LABEL_OPTIONS = (process.env.LP_LABEL_OPTIONS || '').trim();
const LP_SHEET_OPTIONS = (process.env.LP_SHEET_OPTIONS || '').trim();
const LP_DEFAULT_OPTIONS = (process.env.LP_DEFAULT_OPTIONS || '').trim();
const LP_DRY_RUN = String(process.env.LP_DRY_RUN || 'false').toLowerCase() === 'true';

// Cross-platform dry run: render PDFs and mark jobs Printed, but skip physical printing.
// Useful on macOS as a replacement for testing with a Windows PDF printer.
// LP_DRY_RUN only logs the lp command path; PRINT_DRY_RUN skips all print backends.
const PRINT_DRY_RUN = String(process.env.PRINT_DRY_RUN || 'false').toLowerCase() === 'true';

const PRINT_DRIVER_DELAY = parseInt(process.env.PRINT_DRIVER_DELAY) || 1000;

/* --- multi-instance / printer locking --- */
const LOCK_DIR = path.resolve(__dirname, process.env.LOCK_DIR || 'locks');
if (!fs.existsSync(LOCK_DIR)) fs.mkdirSync(LOCK_DIR, { recursive: true });

const PRINTER_LOCK_TIMEOUT_MS = safeNum(process.env.PRINTER_LOCK_TIMEOUT_MS, 60000);
const PRINTER_LOCK_RETRY_MS = safeNum(process.env.PRINTER_LOCK_RETRY_MS, 250);

function lockFileForPrinter(printerName) {
  const safe = String(printerName || 'default')
    .replace(/[^a-zA-Z0-9._-]/g, '_')
    .slice(0, 120);
  return path.join(LOCK_DIR, `printer_${safe}.lock`);
}

async function withPrinterLock(printerName, fn) {
  // If no printer name, skip locking (Windows default printer).
  if (!printerName) return await fn();

  const lockPath = lockFileForPrinter(printerName);
  const start = Date.now();
  let fd = null;

  while (Date.now() - start < PRINTER_LOCK_TIMEOUT_MS) {
    try {
      fd = fs.openSync(lockPath, 'wx'); // exclusive create
      fs.writeFileSync(fd, `${INSTANCE_ID} ${new Date().toISOString()}`, { encoding: 'utf8' });
      break;
    } catch (e) {
      // lock held: retry
      await new Promise(r => setTimeout(r, PRINTER_LOCK_RETRY_MS));
    }
  }

  if (!fd) {
    throw new Error(`Timed out waiting for printer lock: ${printerName} (${lockPath})`);
  }

  try {
    return await fn();
  } finally {
    try { fs.closeSync(fd); } catch {}
    try { fs.unlinkSync(lockPath); } catch {}
  }
}


/* --- sheet-specific env --- */

const STERI_SHEET_PRINTER = process.env.STERI_SHEET_PRINTER || ''; // never fall back to label printer
const LETTER_MARGIN_IN = safeNum(process.env.LETTER_MARGIN_IN, 0.5);
const INCH = 72;
const LETTER_W = 8.5 * INCH;
const LETTER_H = 11 * INCH;
const SHEET_MARGIN_PT = Math.max(0, Math.round(LETTER_MARGIN_IN * 72));

/* ---------- Compute page size for lot labels ---------- */

let PAGE_W, PAGE_H;

if (FORCE_PAGE) {
  PAGE_W = FORCE_W_PT;
  PAGE_H = FORCE_H_PT;
} else {
  PAGE_W = in2pt(LABEL_W_IN);
  PAGE_H = in2pt(LABEL_H_IN);

  if (!PAGE_W) PAGE_W = 288;
  if (!PAGE_H) PAGE_H = 144;

  if (ORIENT === 'landscape' && PAGE_H > PAGE_W) [PAGE_W, PAGE_H] = [PAGE_H, PAGE_W];
  if (ORIENT === 'portrait' && PAGE_W > PAGE_H) [PAGE_W, PAGE_H] = [PAGE_H, PAGE_W];
}

const M = MARGIN_PT || 8;
const LINE_GAP = 2;

async function fetchNocoV3SourceRecord(tableId, viewId, sourcePk, sourceKind, queueFields) {
  const kind = String(sourceKind || '').trim().toLowerCase();
  const fieldNames = nocoV3SourceFieldNames(kind);
  const params = fieldNames.length ? { fields: fieldNames.join(',') } : {};
  const directUrl = `${nocoV3RecordsPath(tableId)}/${encodeURIComponent(sourcePk)}`;

  // sourcePk comes from the LTAR link object's Record ID. Use NocoDB v3's
  // single-record endpoint rather than filtering computed views on nocopk.
  try {
    const { data } = await NC.get(directUrl, Object.keys(params).length ? { params } : undefined);
    const row = data?.record ?? data;
    if (row && typeof row === 'object') return row;
  } catch (directError) {
    const businessId = queueSourceBusinessId(queueFields, kind);
    if (!businessId) throw directError;

    const businessField = kind === 'product' ? 'product_id' : 'lot_id';
    log.warn('Direct NocoDB source record read failed; trying business-id filter', {
      source_kind: kind,
      record_id: sourcePk,
      business_id: businessId,
      ...httpErrorMeta(directError),
    });

    const rows = await fetchNocoV3Records(
      tableId,
      viewId,
      {
        pageSize: 1,
        ...(fieldNames.length ? { fields: fieldNames.join(',') } : {}),
        where: nocoV3Where(businessField, 'eq', businessId),
      },
      false
    );
    return rows[0] || null;
  }

  return null;
}

async function hydrateNocoV3QueueCandidate(candidateRow) {
  const queueFields = nocoV3RecordFields(candidateRow);
  const writeId = nocoV3RecordId(candidateRow, PRINT_QUEUE_WRITE_ID_FIELD);
  if (writeId == null || String(writeId).trim() === '') {
    throw new Error('Queued NocoDB row is missing its writable queue id');
  }

  const sourceKind = String(toFlat(queueFields.source_kind) || '').trim().toLowerCase();
  if (!['lot', 'product', 'steri_sheet'].includes(sourceKind)) {
    throw new Error(`Queued print job ${writeId} has unsupported source_kind="${sourceKind || '(blank)'}"`);
  }

  if (sourceKind === 'steri_sheet') {
    const printTarget = printTargetForSource(sourceKind, '');
    return {
      id: writeId,
      read_id: candidateRow?.id,
      fields: mergeQueueSourceFields(queueFields, {}, printTarget),
      _raw: candidateRow,
    };
  }

  const sourcePk = queueSourcePk(queueFields, sourceKind);
  if (!sourcePk) {
    const availableFields = Object.keys(queueFields).sort().join(', ');
    throw new Error(
      `Queued print job ${writeId} is missing its ${sourceKind}_id/link. ` +
      `Available queue fields: ${availableFields || '(none)'}`
    );
  }

  const tableId = sourceKind === 'product' ? PRODUCTS_TABLE : LOTS_TABLE;
  const viewId = sourceKind === 'product' ? PRODUCTS_VIEW_ID : LOTS_VIEW_ID;
  const sourceRow = await fetchNocoV3SourceRecord(
    tableId,
    viewId,
    sourcePk,
    sourceKind,
    queueFields
  );
  if (!sourceRow) {
    throw new Error(`Queued print job ${writeId} could not find ${sourceKind} nocopk=${sourcePk}`);
  }

  const sourceFields = nocoV3RecordFields(sourceRow);
  const itemCategory = pick(sourceFields, ['item_category_mat', 'item_category']);
  const printTarget = printTargetForSource(sourceKind, itemCategory);

  return {
    id: writeId,
    read_id: candidateRow?.id,
    fields: mergeQueueSourceFields(queueFields, sourceFields, printTarget),
    _raw: candidateRow,
    _source_raw: sourceRow,
  };
}

function httpErrorMeta(error) {
  const meta = {};
  const method = error?.config?.method;
  const baseURL = error?.config?.baseURL || '';
  const url = error?.config?.url || '';
  const statusCode = error?.response?.status;
  const params = error?.config?.params;
  const responseData = error?.response?.data;

  if (method) meta.method = String(method).toUpperCase();
  if (url || baseURL) meta.url = `${baseURL}${url}`;
  if (params && typeof params === 'object') meta.params = params;
  if (statusCode) meta.status = statusCode;
  if (responseData !== undefined) {
    let body;
    try {
      body = typeof responseData === 'string' ? responseData : JSON.stringify(responseData);
    } catch {
      body = String(responseData);
    }
    meta.response = body.length > 500 ? `${body.slice(0, 500)}…` : body;
  }
  return meta;
}

/* ---------- Queue helpers  ---------- */

/**
 * Fetch records from NocoDB/Airtable print_queue where print_status = 'Queued'.
 * We adapt the NocoDB response shape into an Airtable-like { id, fields } object
 * so the rest of the daemon logic can stay unchanged.
 */
async function fetchQueued(viewName) {

  if (DB_BACKEND === 'airtable') {
    // Build Airtable filter formula:
    // - always require print_status='Queued'
    // - optionally require print_target match (PRINT_TARGET_VALUE)
    // - optionally AND in AIRTABLE_EXTRA_FILTER_FORMULA
    const parts = [`({print_status} = 'Queued')`];
    
    if (PRINT_TARGET_VALUE) {
      parts.push(`({${PRINT_TARGET_FIELD}} = '${PRINT_TARGET_VALUE.replace(/'/g, "\\'")}')`);
    }
    if (AIRTABLE_EXTRA_FILTER_FORMULA) {
      parts.push(`(${AIRTABLE_EXTRA_FILTER_FORMULA})`);
    }
    
    const filterByFormula = parts.length === 1 ? parts[0] : `AND(${parts.join(',')})`;
    
    const params = new URLSearchParams({
//      view: viewName,
      filterByFormula,
      maxRecords: '25'
    });
    
    log.debug(`Querying: ${params.toString()}`);
    
    const { data } = await API.get(`${PRINT_QUEUE_TABLE}?${params.toString()}`);
    return data.records || [];
  
  } else {
    if (isNocoV3()) {
      // Poll the simple base print_queue table for Queued rows. Hydrate each
      // candidate from vc_lots or vc_products; vc_print_queue is intentionally
      // bypassed because NocoDB currently returns HTTP 500 for that view.
      const candidateClauses = [nocoV3Where('print_status', 'eq', 'Queued')];
      if (NOCODB_EXTRA_WHERE) candidateClauses.push(NOCODB_EXTRA_WHERE);
      const candidateWhere = combineNocoV3WhereClauses(candidateClauses);

      const candidateRows = await fetchNocoV3Records(
        PRINT_QUEUE_WRITE_TABLE,
        '',
        {
          pageSize: 100,
          where: candidateWhere,
          // Expand external PostgreSQL Link fields so lot_id/product_id carry
          // the linked record ID instead of being omitted or reduced to counts.
          linksAsLtar: 'true',
        },
        true
      );

      const hydrated = [];
      for (const candidateRow of candidateRows) {
        if (hydrated.length >= 25) break;

        const writeId = nocoV3RecordId(candidateRow, PRINT_QUEUE_WRITE_ID_FIELD);
        try {
          const rec = await hydrateNocoV3QueueCandidate(candidateRow);
          if (String(toFlat(rec.fields?.print_status)).trim() !== 'Queued') continue;

          if (PRINT_TARGET_VALUE) {
            const target = String(toFlat(rec.fields?.[PRINT_TARGET_FIELD]) || '').trim();
            if (target !== PRINT_TARGET_VALUE) continue;
          }

          hydrated.push(rec);
        } catch (error) {
          log.error('Failed to hydrate queued print job from source view', {
            id: writeId,
            source_kind: toFlat(nocoV3RecordFields(candidateRow).source_kind),
            err: error?.message || String(error),
            ...httpErrorMeta(error),
          });
        }
      }

      log.debug('Polled NocoDB v3 base print queue', {
        where: candidateWhere,
        candidates: candidateRows.length,
        returned: hydrated.length,
        target: PRINT_TARGET_VALUE || '(all)',
      });

      return hydrated;
    }

    // "viewName" is ignored for NocoDB v2, kept for API compatibility with old code.
    // Build NocoDB where clause:
    // - always require print_status='Queued'
    // - optionally require print_target match (PRINT_TARGET_VALUE)
    // - optionally AND in NOCODB_EXTRA_WHERE (advanced)
    let where = '(print_status,eq,Queued)';
    if (PRINT_TARGET_VALUE) {
      const t = `(${PRINT_TARGET_FIELD},eq,${PRINT_TARGET_VALUE})`;
      where = `and(${where},${t})`;
    }
    if (NOCODB_EXTRA_WHERE) {
      where = `and(${where},(${NOCODB_EXTRA_WHERE}))`;
    }

    const params = {
      where,
      limit: 25,
      offset: 0,
      sort: 'Id,asc',
    };

    const url = `/api/v2/tables/${encodeURIComponent(PRINT_QUEUE_TABLE)}/records`;
    const { data } = await NC.get(url, { params });
  
    const list = data && Array.isArray(data.list) ? data.list : [];
  
    // Normalize to Airtable-like { id, fields } objects
    return list.map(row => ({
      id: row.Id ?? row.id, // NocoDB usually exposes "Id"
      fields: row,
    }));
  }
}

/**
 * Update a single print_queue record's status (and optional error_msg) in NocoDB.
 */
/**
 * Update fields on a print_queue record (Airtable or NocoDB).
 */
async function updateQueueRecord(id, fields) {
  if (id == null) return;
  if (!fields || typeof fields !== 'object') return;

  if (DB_BACKEND === 'airtable') {
    const payload = { records: [{ id, fields }], typecast: true };
    log.debug(`Patching ${PRINT_QUEUE_TABLE}`, { id, fields });
    
    await API.patch(PRINT_QUEUE_TABLE, payload);
  } else {
    if (isNocoV3()) {
      const url = nocoV3RecordsPath(PRINT_QUEUE_WRITE_TABLE);
      await NC.patch(url, { id, fields });
      return;
    }

    const url = `/api/v2/tables/${encodeURIComponent(PRINT_QUEUE_TABLE)}/records/${encodeURIComponent(id)}`;
    await NC.patch(url, fields);
  }
}

/**
 * Update print_status (and optional error_msg) and stamp printed/claimed metadata.
 * - When status is set to 'Printing', the daemon will set claimed_by/claimed_at (if those fields exist).
 * - When status is set to 'Printed', the daemon will set printed_by/printed_at (if those fields exist).
 */
async function markStatus(id, status, errorMsg = null) {
  if (id == null) return;

  const fields = { print_status: status };
  if (errorMsg !== undefined) fields.error_msg = errorMsg;

  const iso = new Date().toISOString();

  if (String(status).toLowerCase() === 'printing') {
    fields.claimed_by = INSTANCE_ID;
    fields.claimed_at = iso;
  }
  if (String(status).toLowerCase() === 'printed') {
    fields.printed_by = INSTANCE_ID;
    fields.printed_at = iso;
  }

  await updateQueueRecord(id, fields);
}


/* ---------- Gather label fields ---------- */
function detectItemCategory(rec) {
  const f = rec.fields || {};
  return (
    pick(f, [
      'item_category_mat_from_product_id',
      'item_category_mat (from product_id)',
    ]) ||
    pick(f, [
      'item_category_mat_from_lot_id',
      'item_category_mat (from lot_id)',
    ]) ||
    pick(f, ['item_category_mat']) ||
    ''
  ).toLowerCase();
}

function isSyringeCategory(category) {
  return ['lc_syringe', 'lc_syringe_purchased'].includes(String(category || '').toLowerCase());
}

function gatherFields(rec) {
  const f = rec.fields || {};
  const sourceKind = (toFlat(f.source_kind) || '').toLowerCase();
  const itemCategory = detectItemCategory(rec);

  if (sourceKind === 'product') {
    const labelType = toFlat(f.label_type || f.Label_Type || f['label_type']) || '';
    const packaged = pick(f, [
      'label_packaged_prod',
      'label_packaged_prod_from_product_id',
      'label_packaged_prod (from product_id)',
    ]);
    const useBy = pick(f, [
      'label_useby_prod',
      'label_useby_prod_from_product_id',
      'label_useby_prod (from product_id)',
    ]);

    return {
      kind: 'product',
      labelType,
      isPackageSampleLabel: String(labelType).trim().toLowerCase() === 'product_package_sample',
      itemCategory,
      isSyringeLabel: isSyringeCategory(itemCategory),
      company: pick(f, [
        'label_company_prod',
        'label_company_prod_from_product_id',
        'label_company_prod (from product_id)',
      ]) || '',
      title: pick(f, [
        'label_title_prod',
        'label_title_prod_from_product_id',
        'label_title_prod (from product_id)',
      ]),
      subtitle: pick(f, [
        'label_subtitle_prod',
        'label_subtitle_prod_from_product_id',
        'label_subtitle_prod (from product_id)',
      ]),
      footer: pick(f, [
        'label_footer_prod',
        'label_footer_prod_from_product_id',
        'label_footer_prod (from product_id)',
      ]),
      packaged,
      useBy,
      qr: labelQrUrl(f, 'product'),
      companyAddr: pick(f, [
        'label_companyaddress_prod',
        'label_companyaddress_prod_from_product_id',
        'label_companyaddress_prod (from product_id)',
      ]),
      companyInfo: pick(f, [
        'label_companyinfo_prod',
        'label_companyinfo_prod_from_product_id',
        'label_companyinfo_prod (from product_id)',
      ]),
      disclaimer: pick(f, [
        'label_disclaimer_prod',
        'label_disclaimer_prod_from_product_id',
        'label_disclaimer_prod (from product_id)',
      ]),
      cottage: pick(f, [
        'label_cottage_prod',
        'label_cottage_prod_from_product_id',
        'label_cottage_prod (from product_id)',
      ]),
      extras: [
        pick(f, [
          'label_proc_prod',
          'label_proc_prod_from_product_id',
          'label_proc_prod (from product_id)',
        ]),
        pick(f, [
          'label_inoc_prod',
          'label_inoc_prod_from_product_id',
          'label_inoc_prod (from product_id)',
        ]),
        pick(f, [
          'label_spawned_prod',
          'label_spawned_prod_from_product_id',
          'label_spawned_prod (from product_id)',
        ]),
        packaged,
        useBy,
      ].filter(Boolean),
    };
  }

  return {
    kind: 'lot',
    itemCategory,
    isSyringeLabel: isSyringeCategory(itemCategory),
    company: pick(f, [
      'label_company_lot',
      'label_company_lot_from_lot_id',
      'label_company_lot (from lot_id)',
    ]) || '',
    title: pick(f, [
      'label_title_lot',
      'label_title_lot_from_lot_id',
      'label_title_lot (from lot_id)',
    ]),
    subtitle: pick(f, [
      'label_subtitle_lot',
      'label_subtitle_lot_from_lot_id',
      'label_subtitle_lot (from lot_id)',
    ]),
    footer: pick(f, [
      'label_footer_lot',
      'label_footer_lot_from_lot_id',
      'label_footer_lot (from lot_id)',
    ]),
    qr: labelQrUrl(f, 'lot'),
    extras: [
      pick(f, [
        'label_proc_line',
        'label_proc_line_from_lot_id',
        'label_proc_line (from lot_id)',
      ]),
      pick(f, [
        'label_inoc_line',
        'label_inoc_line_from_lot_id',
        'label_inoc_line (from lot_id)',
      ]),
      pick(f, [
        'label_spawned_line',
        'label_spawned_line_from_lot_id',
        'label_spawned_line (from lot_id)',
      ]),
      pick(f, [
        'label_useby_line',
        'label_useby_line_from_lot_id',
        'label_useby_line (from lot_id)',
      ]),
      (() => {
        const v = pick(f, [
          'label_graininputblocks_line',
          'label_graininputblocks_line_from_lot_id',
          'label_graininputblocks_line (from lot_id)',
        ]);
        return v ? `Grain: ${v}` : '';
      })(),
      (() => {
        const v = pick(f, [
          'label_substrateinputblocks_line',
          'label_substrateinputblocks_line_from_lot_id',
          'label_substrateinputblocks_line (from lot_id)',
        ]);
        return v ? `Substrate: ${v}` : '';
      })(),
    ].filter(Boolean),
  };
}

function hasRenderableLabelText(label) {
  if (!label || typeof label !== 'object') return false;
  const values = [
    label.title,
    label.subtitle,
    label.footer,
    label.packaged,
    label.useBy,
    label.companyInfo,
    label.disclaimer,
    label.cottage,
    ...(Array.isArray(label.extras) ? label.extras : []),
  ];
  return values.some(value => String(value || '').trim() !== '');
}

/* ---------- Logo selection (company → file) ---------- */
function normalizeCompany(str) {
  return (str || '').replace(/[^a-zA-Z0-9]/g, '');
}

function selectLogoPath(company) {
  const base = __dirname;
  const candidates = [];
  const compact = normalizeCompany(company);

  if (compact) {
    candidates.push(`${compact}logo.png`);
    candidates.push(`${compact}Logo.png`);
    candidates.push(`${compact.toLowerCase()}logo.png`);
  }
  candidates.push('logo.png');

  for (const fname of candidates) {
    const p = path.join(base, fname);
    if (fs.existsSync(p)) return { path: p, chosen: fname };
  }
  return { path: null, chosen: '(none)' };
}

/* ---------- Text helpers (robust multi-line with auto-shrink) ---------- */

function normalizeLabelText(text) {
  if (text == null) return '';
  return String(text)
    // Airtable formulas sometimes contain literal backslash sequences instead of actual CR/LF.
    .replace(/\\r\\n/g, '\n')
    .replace(/\\n/g, '\n')
    .replace(/\\r/g, '\n')
    // Also normalize real CR/LF variants.
    .replace(/\r\n/g, '\n')
    .replace(/\r/g, '\n')
    // Trim trailing spaces on each line, but preserve intentional blank lines.
    .split('\n')
    .map(line => line.replace(/[ \t]+$/g, ''))
    .join('\n')
    .trim();
}

function imageHeightForWidth(doc, imagePath, width) {
  try {
    const img = doc.openImage(imagePath);
    if (img && img.width && img.height && width) {
      return width * (img.height / img.width);
    }
  } catch {}
  return width * 0.35;
}

function drawImageWithMeasuredHeight(doc, imagePath, x, y, width) {
  const h = imageHeightForWidth(doc, imagePath, width);
  doc.image(imagePath, x, y, { width });
  return y + h;
}

// Measure how tall text would be at fontName+fontSize within width
function measureTextHeight(doc, text, width, fontName, fontSize, opts = {}) {
  // NOTE: doc._font is an internal font object; passing it to doc.font(...)
  // causes: "Not a supported font format or standard PDF font."
  // So we restore using a standard font name (best-effort).
  const prevFontName =
    (doc._font && (doc._font.name || doc._font.postscriptName)) || 'Helvetica';
  const prevSize = doc._fontSize;
  doc.font(fontName).fontSize(fontSize);
  const h = doc.heightOfString(String(text || ''), { width, ...opts });
  doc.font(prevFontName).fontSize(prevSize);
  return h;
}

/**
 * Draw a paragraph that:
 * - wraps within width
 * - respects \n
 * - auto-shrinks between maxFont..minFont to fit maxHeight (if provided)
 * Returns new Y cursor.
 */
function drawBlock(
  doc,
  text,
  x,
  y,
  width,
  fontName,
  {
    maxFont = 12,
    minFont = 7,
    lineGap = 2,
    paragraphGap = 4,
    maxHeight = null,
  } = {}
) {
  const txt = normalizeLabelText(text);
  if (!txt) return y;

  // choose size to fit
  let size = maxFont;
  if (maxHeight && maxHeight > 0) {
    while (size > minFont) {
      const h = measureTextHeight(doc, txt, width, fontName, size, {
        lineGap,
        paragraphGap,
      });
      if (h <= maxHeight) break;
      size -= 0.5;
    }
  }

  doc.font(fontName).fontSize(size);
  doc.text(txt, x, y, { width, lineGap, paragraphGap });
  const used = doc.heightOfString(txt, { width, lineGap, paragraphGap });
  return y + used + lineGap;
}

/** Single line helper (kept for lots) */
function drawTextLine(doc, text, x, y, width, fontName, fontSize, opts = {}) {
  if (!text) return y;
  doc.font(fontName).fontSize(fontSize).text(text, x, y, { width, ...opts });
  return y + doc.currentLineHeight() + (opts.lineGap ?? LINE_GAP);
}

/* ---------- Render lot label PDF (logo + fields + QR) ---------- */
async function renderSplitSyringeLabelPDF(outPath, rec) {
  const L = gatherFields(rec);
  const company = L.company || '';
  const title = L.title || '';
  const subtitle = L.subtitle || '';
  const footer = L.footer || '';
  const qrUrl = L.qr || '';
  const extras = Array.isArray(L.extras) ? L.extras.filter(Boolean) : [];

  const doc = new PDFDocument({
    size: [PAGE_W, PAGE_H],
    margins: { top: M, left: M, right: M, bottom: M },
  });

  const stream = fs.createWriteStream(outPath);
  doc.pipe(stream);

  const cutX = PAGE_W / 2;
  const panelPad = Math.max(4, Math.min(8, M));
  const gap = 8;
  const leftX = M;
  const leftW = cutX - M - panelPad;
  const rightX = cutX + panelPad;
  const rightW = PAGE_W - rightX - M;

  if (DRAW_BORDER) {
    doc.save();
    doc.lineWidth(0.7).rect(0.5, 0.5, PAGE_W - 1, PAGE_H - 1).stroke();
    doc.restore();
  }

  doc.save();
  doc.lineWidth(0.7);
  doc.dash(3, { space: 2 });
  doc.moveTo(cutX, M / 2).lineTo(cutX, PAGE_H - M / 2).stroke();
  doc.undash();
  doc.restore();

  let leftY = M;
  let rightY = M;

  const { path: logoPath } = selectLogoPath(company);
  if (logoPath) {
    try {
      const logoW = Math.min(LOGO_W_PT * 0.48, leftW);
      doc.image(logoPath, leftX, leftY, { width: logoW });
      leftY += Math.min(logoW * 0.35, 24);
    } catch {}
  }

  if (title) {
    leftY = drawBlock(doc, title, leftX, leftY, leftW, 'Helvetica-Bold', {
      maxFont: 11,
      minFont: 4.5,
      lineGap: 1,
      paragraphGap: 0,
    });
  }

  if (subtitle) {
    leftY = drawBlock(doc, subtitle, leftX, leftY, leftW, 'Helvetica-Bold', {
      maxFont: 8.5,
      minFont: 4,
      lineGap: 1,
      paragraphGap: 1,
    });
  }

  const leftExtras = extras.slice(0, 2);
  for (const line of leftExtras) {
    leftY = drawBlock(doc, line, leftX, leftY, leftW, 'Helvetica-Bold', {
      maxFont: 6.5,
      minFont: 4,
      lineGap: 1,
      paragraphGap: 0,
    });
  }

  if (footer) {
    leftY = drawBlock(doc, footer, leftX, leftY, leftW, 'Helvetica-Bold', {
      maxFont: 6.5,
      minFont: 4,
      lineGap: 1,
      paragraphGap: 0,
    });
  }

  if (company) {
    rightY = drawBlock(doc, company, rightX, rightY, rightW, 'Helvetica-Bold', {
      maxFont: 10,
      minFont: 4.5,
      lineGap: 1,
      paragraphGap: 0,
    });
  }

  if (title) {
    rightY = drawBlock(doc, title, rightX, rightY, rightW, 'Helvetica-Bold', {
      maxFont: 8.5,
      minFont: 4.5,
      lineGap: 1,
      paragraphGap: 0,
    });
  }

  if (subtitle) {
    rightY = drawBlock(doc, subtitle, rightX, rightY, rightW, 'Helvetica-Bold', {
      maxFont: 7,
      minFont: 4,
      lineGap: 1,
      paragraphGap: 1,
    });
  }

  for (const line of extras) {
    rightY = drawBlock(doc, line, rightX, rightY, rightW, 'Helvetica-Bold', {
      maxFont: 6.5,
      minFont: 4,
      lineGap: 1,
      paragraphGap: 0,
    });
  }

  const qrSize = Math.min(54, rightW);
  const footerSpace = 2;
  const qrY = PAGE_H - M - qrSize - footerSpace;
  const qrX = PAGE_W - M - qrSize - footerSpace;

  if (qrUrl) {
    const qrPng = await QRCode.toDataURL(qrUrl, {
      errorCorrectionLevel: 'M',
      margin: 0,
      scale: 6,
    });
    const qrBuf = Buffer.from(qrPng.split(',')[1], 'base64');
    doc.image(qrBuf, qrX, qrY, { width: qrSize, height: qrSize });
  }

  if (footer) {
    drawBlock(doc, footer, rightX, PAGE_H - M - 12, rightW, 'Helvetica-Bold', {
      maxFont: 6,
      minFont: 4,
      lineGap: 1,
    });
  }

  doc.end();

  await new Promise((res, rej) => {
    stream.on('finish', res);
    stream.on('error', rej);
  });
}

async function renderLabelPDF(outPath, rec) {
  const L = gatherFields(rec);
  const company = L.company || '';
  const title = L.title || '';
  const subtitle = L.subtitle || '';
  const footer = L.footer || '';
  const qrUrl = L.qr || '';

  const doc = new PDFDocument({
    size: [PAGE_W, PAGE_H],
    margins: { top: M, left: M, right: M, bottom: M },
  });

  const stream = fs.createWriteStream(outPath);
  doc.pipe(stream);

  if (DRAW_BORDER) {
    doc.save();
    doc
      .lineWidth(0.7)
      .rect(0.5, 0.5, PAGE_W - 1, PAGE_H - 1)
      .stroke();
    doc.restore();

    doc
      .font('Helvetica')
      .fontSize(6)
      .fillColor('black')
      .text(
        `PAGE: ${PAGE_W}x${PAGE_H}pt | M:${M} | LogoW:${LOGO_W_PT} | QR:${QR_SIZE_PT}`,
        2,
        2,
        { width: PAGE_W - 4 }
      );
  }

  const contentWidth = PAGE_W - 2 * M;
  let y = M;

  // Logo
  const { path: logoPath } = selectLogoPath(company);
  if (logoPath) {
    try {
      doc.image(logoPath, M, y, { width: LOGO_W_PT });
      y += Math.min(LOGO_W_PT * 0.35, 42);
    } catch {
      // ignore logo errors
    }
  }

  // Title
  if (title)
    y = drawBlock(doc, title, M, y, contentWidth, 'Helvetica-Bold', {
      maxFont: 12,
      minFont: 4,
      lineGap: 1,
      paragraphGap: 0,
    });

  // Subtitle
  if (subtitle)
    y = drawBlock(doc, subtitle, M, y, contentWidth, 'Helvetica-Bold', {
      maxFont: 10,
      minFont: 4,
      lineGap: 1,
      paragraphGap: 4,
    });

  // Extras
  if (Array.isArray(L.extras)) {
    for (const line of L.extras) {
      y = drawBlock(doc, line, M, y, contentWidth, 'Helvetica-Bold', {
        maxFont: 7,
        minFont: 4,
        lineGap: 1,
        paragraphGap: 0,
      });
    }
  }

  // Footer (bottom-ish)
  if (footer) {
    const bottomY = PAGE_H - M - 10;
    drawBlock(doc, footer, M, bottomY, contentWidth, 'Helvetica-Bold', {
      maxFont: 8,
      minFont: 4,
      lineGap: 1,
    });
  }

  // QR lower-right
  if (qrUrl) {
    const qrPng = await QRCode.toDataURL(qrUrl, {
      errorCorrectionLevel: 'M',
      margin: 0,
      scale: 6,
    });
    const qrBuf = Buffer.from(qrPng.split(',')[1], 'base64');
    doc.image(
      qrBuf,
      PAGE_W - M - QR_SIZE_PT,
      PAGE_H - M - QR_SIZE_PT,
      { width: QR_SIZE_PT, height: QR_SIZE_PT }
    );
  }

  doc.end();

  await new Promise((res, rej) => {
    stream.on('finish', res);
    stream.on('error', rej);
  });
}


function drawLabelDivider(doc, y, x1 = M, x2 = PAGE_W - M) {
  doc.save();
  doc.lineWidth(0.4).moveTo(x1, y).lineTo(x2, y).stroke();
  doc.restore();
}

/* ---------- Render one-piece product package sample label ---------- */
async function renderProductPackageSampleLabelPDF(outPath, rec) {
  const L = gatherFields(rec);
  if (L.kind !== 'product') return;

  const company = L.company || '';
  const title = L.title || '';
  const subtitle = normalizeLabelText(L.subtitle || '');
  const footer = normalizeLabelText(L.footer || '');
  const packaged = normalizeLabelText(L.packaged || '');
  const useBy = normalizeLabelText(L.useBy || '');
  const companyInfo = normalizeLabelText(L.companyInfo || '');
  const companyAddr = normalizeLabelText(L.companyAddr || '');
  const cottage = normalizeLabelText(L.cottage || '');
  const disclaimer = normalizeLabelText(L.disclaimer || '');
  const isRegulatedSample = Boolean(disclaimer);
  const lowerBlocks = isRegulatedSample
    ? [companyInfo, disclaimer].filter(Boolean)
    : [companyInfo, companyAddr, cottage].filter(Boolean);
  const qrUrl = L.qr || '';

  const doc = new PDFDocument({
    size: [PAGE_W, PAGE_H],
    margins: { top: M, left: M, right: M, bottom: M },
  });

  const stream = fs.createWriteStream(outPath);
  doc.pipe(stream);

  if (DRAW_BORDER) {
    doc.save();
    doc.lineWidth(0.7).rect(0.5, 0.5, PAGE_W - 1, PAGE_H - 1).stroke();
    doc.restore();
  }

  const contentWidth = PAGE_W - 2 * M;
  const contentBottom = PAGE_H - M;
  let y = M;

  // Compact top row: logo/company on left, optional small QR on right.
  const qrSize = SAMPLE_INCLUDE_QR && qrUrl ? Math.max(0, Math.min(SAMPLE_QR_SIZE_PT, 46)) : 0;
  const qrGap = qrSize ? 5 : 0;
  const qrX = PAGE_W - M - qrSize;
  const topRightGuard = qrSize ? qrSize + qrGap : 0;
  const textRight = PAGE_W - M - topRightGuard;
  const textWidth = Math.max(80, textRight - M);

  const { path: logoPath } = selectLogoPath(company);
  if (logoPath) {
    try {
      const logoW = Math.min(SAMPLE_LOGO_W_PT, Math.max(42, textWidth * 0.42));
      y = drawImageWithMeasuredHeight(doc, logoPath, M, y, logoW) + SAMPLE_LOGO_TEXT_GAP_PT;
    } catch {
      // ignore logo errors; company text still prints below
    }
  }

  if (company) {
    y = drawBlock(doc, company, M, y, textWidth, 'Helvetica-Bold', {
      maxFont: 8.5,
      minFont: 4,
      lineGap: 0.5,
      paragraphGap: 0,
      maxHeight: 13,
    });
  }

  if (qrSize) {
    try {
      const qrPng = await QRCode.toDataURL(qrUrl, {
        errorCorrectionLevel: 'M',
        margin: 0,
        scale: 4,
      });
      const qrBuf = Buffer.from(qrPng.split(',')[1], 'base64');
      doc.image(qrBuf, qrX, M, { width: qrSize, height: qrSize });
    } catch (e) {
      log.warn('Sample label QR render failed', { err: e?.message || String(e) });
    }
  }

  const metaLines = [packaged, useBy].filter(Boolean);
  const metaText = metaLines.join('   |   ');

  // Reserve a lower information band for either:
  // - regulated samples: responsibility statement + regulated disclaimer, or
  // - unregulated samples: company information + address + cottage-food statement.
  // The blocks share one auto-shrinking band so the sample remains a single 4x2 label.
  const lowerReserve = lowerBlocks.length ? Math.floor(PAGE_H * 0.54) : 0;
  const footerReserve = footer ? SAMPLE_FOOTER_RESERVE_PT : 0;
  const mainBottom = contentBottom - lowerReserve - footerReserve - 2;

  if (title) {
    y = drawBlock(doc, title, M, y, textWidth, 'Helvetica-Bold', {
      maxFont: SAMPLE_TITLE_MAX_FONT,
      minFont: 4.5,
      lineGap: 0.25,
      paragraphGap: 0,
      maxHeight: Math.max(11, mainBottom - y),
    });
  }

  // Always attempt to draw subtitle and package metadata. If the upper band is tight,
  // drawBlock() will shrink them rather than silently omitting them.
  if (subtitle) {
    y = drawBlock(
      doc,
      subtitle,
      M,
      y,
      textWidth,
      'Helvetica-Bold',
      {
        maxFont: SAMPLE_SUBTITLE_MAX_FONT,
        minFont: 3.8,
        lineGap: 0.2,
        paragraphGap: 0,
        maxHeight: Math.max(7, mainBottom - y),
      }
    );
  } else if (String(L.labelType || '').trim().toLowerCase() === 'product_package_sample') {
    log.debug('Product_Package_Sample label has no subtitle field value', {
      queue_id: rec.id,
      available_label_subtitle_keys: Object.keys(rec.fields || {}).filter(k => k.toLowerCase().includes('subtitle')),
    });
  }

  if (metaText) {
    y = drawBlock(doc, metaText, M, y, contentWidth, 'Helvetica-Bold', {
      maxFont: SAMPLE_META_MAX_FONT,
      minFont: 3.8,
      lineGap: 0.2,
      paragraphGap: 0,
      maxHeight: Math.max(7, mainBottom - y),
    });
  }

  if (lowerBlocks.length) {
    const lowerY = Math.max(y + 2, contentBottom - lowerReserve - footerReserve);
    drawLabelDivider(doc, lowerY - 1);
    const lowerHeight = Math.max(14, contentBottom - lowerY - footerReserve - 1);
    let lowerCursor = lowerY + 2;
    const blockGap = 1;

    // Allocate lower-band height according to how much text each block actually needs.
    // Equal slices made the long regulated disclaimer shrink dramatically while short
    // gourmet blocks retained much larger type. Proportional allocation lets the
    // disclaimer use the otherwise-empty space without making short blocks oversized.
    const blockSpecs = lowerBlocks.map((text) => {
      const isAddressBlock = !isRegulatedSample && text === companyAddr;
      const isCottageBlock = !isRegulatedSample && text === cottage;
      const isDisclaimerBlock = isRegulatedSample && text === disclaimer;
      const fontName = isAddressBlock
        ? 'Helvetica'
        : (isRegulatedSample ? 'Helvetica-Bold' : 'Helvetica-Oblique');
      const maxFont = isAddressBlock
        ? SAMPLE_COMPANY_ADDRESS_MAX_FONT
        : (isCottageBlock
            ? SAMPLE_COTTAGE_MAX_FONT
            : (isDisclaimerBlock ? SAMPLE_DISCLAIMER_MAX_FONT : SAMPLE_COMPANY_INFO_MAX_FONT));
      const desiredHeight = measureTextHeight(doc, text, contentWidth, fontName, maxFont, {
        lineGap: 0.2,
        paragraphGap: 0.5,
      });
      const minimumHeight = measureTextHeight(doc, text, contentWidth, fontName, SAMPLE_LOWER_MIN_FONT, {
        lineGap: 0.2,
        paragraphGap: 0.5,
      });
      return { text, fontName, maxFont, desiredHeight, minimumHeight };
    });

    const usableHeight = Math.max(7, lowerHeight - blockGap * (blockSpecs.length - 1));
    const desiredTotal = blockSpecs.reduce((sum, spec) => sum + spec.desiredHeight, 0);
    const minimumTotal = blockSpecs.reduce((sum, spec) => sum + spec.minimumHeight, 0);

    for (let i = 0; i < blockSpecs.length; i++) {
      const spec = blockSpecs[i];
      let allocatedHeight;

      if (desiredTotal <= usableHeight) {
        allocatedHeight = spec.desiredHeight;
      } else if (minimumTotal >= usableHeight) {
        allocatedHeight = usableHeight * (spec.minimumHeight / minimumTotal);
      } else {
        const flexibleHeight = usableHeight - minimumTotal;
        const extraNeedTotal = Math.max(0.001, desiredTotal - minimumTotal);
        const extraNeed = Math.max(0, spec.desiredHeight - spec.minimumHeight);
        allocatedHeight = spec.minimumHeight + flexibleHeight * (extraNeed / extraNeedTotal);
      }

      lowerCursor = drawBlock(doc, spec.text, M, lowerCursor, contentWidth, spec.fontName, {
        maxFont: spec.maxFont,
        minFont: SAMPLE_LOWER_MIN_FONT,
        lineGap: 0.2,
        paragraphGap: 0.5,
        maxHeight: Math.max(6, allocatedHeight),
      });
    }
  }

  if (footer) {
    drawBlock(
      doc,
      footer,
      M,
      PAGE_H - M - SAMPLE_FOOTER_RESERVE_PT,
      contentWidth,
      'Helvetica-Bold',
      {
        maxFont: SAMPLE_FOOTER_MAX_FONT,
        minFont: SAMPLE_FOOTER_MIN_FONT,
        lineGap: 0.25,
        maxHeight: SAMPLE_FOOTER_RESERVE_PT,
      }
    );
  }

  doc.end();

  await new Promise((res, rej) => {
    stream.on('finish', res);
    stream.on('error', rej);
  });
}

/* ---------- Render product info/disclaimer label (2nd label) ---------- */
async function renderProductInfoLabelPDF(outPath, rec) {
  const L = gatherFields(rec);
  if (L.kind !== 'product') return;
  
  const company = L.company || '';

  const doc = new PDFDocument({
    size: [PAGE_W, PAGE_H],
    margins: { top: M, left: M, right: M, bottom: M },
  });

  const stream = fs.createWriteStream(outPath);
  doc.pipe(stream);

  if (DRAW_BORDER) {
    doc.save();
    doc
      .lineWidth(0.7)
      .rect(0.5, 0.5, PAGE_W - 1, PAGE_H - 1)
      .stroke();
    doc.restore();
  }

  const contentWidth = PAGE_W - 2 * M;
  const contentHeight = PAGE_H - 2 * M;
  let y = M;

  // Layout:
  //   Row 1 (two columns):
  //     Left: company + address
  //     Right: company info
  //   Below (full width): cottage + disclaimer (if present)

  const leftText = [company, L.companyAddr].filter((v) => String(v || '').trim()).join('\n');
  const rightText = String(L.companyInfo || '').trim();

  const bottomParts = [L.cottage, L.disclaimer].filter((v) => String(v || '').trim());
  const bottomText = bottomParts.join('\n\n');

  // Column geometry
  const colGap = 8;
  const leftW = Math.floor((contentWidth - colGap) * 0.48);
  const rightW = contentWidth - colGap - leftW;
  const leftX = M;
  const rightX = M + leftW + colGap;

  // Reserve some space for the bottom block if it exists
  const reservedBottomH = bottomText ? Math.floor(contentHeight * 0.45) : 0;
  const topMaxH = Math.max(20, contentHeight - reservedBottomH);

  // Fit font size helper (choose size so the text fits max height)
  function fitFontSize(txt, w, fontName, maxFont, minFont, maxH) {
    if (!txt) return maxFont;
    let size = maxFont;
    while (size > minFont) {
      const h = measureTextHeight(doc, txt, w, fontName, size, { lineGap: 1, paragraphGap: 2 });
      if (h <= maxH) break;
      size -= 0.5;
    }
    return size;
  }

  // Top row: shrink both columns as needed to fit topMaxH
  const leftFont = fitFontSize(leftText, leftW, 'Helvetica-Bold', 9, 4.5, topMaxH);
  const rightFont = fitFontSize(rightText, rightW, 'Helvetica', 8, 4.5, topMaxH);

  // Draw left column (company + address)
  if (leftText) {
    doc.font('Helvetica-Bold').fontSize(leftFont);
    doc.text(leftText, leftX, y, { width: leftW, lineGap: 1, paragraphGap: 2 });
  }

  // Draw right column (company info)
  if (rightText) {
    doc.font('Helvetica-Bold').fontSize(rightFont);
    doc.text(rightText, rightX, y, { width: rightW, lineGap: 1, paragraphGap: 2 });
  }

  // Advance y by the larger of the two rendered heights
  const leftH = leftText
    ? doc.heightOfString(leftText, { width: leftW, lineGap: 1, paragraphGap: 2 })
    : 0;
  const rightH = rightText
    ? doc.heightOfString(rightText, { width: rightW, lineGap: 1, paragraphGap: 2 })
    : 0;
  y += Math.max(leftH, rightH) + 6;

  // Bottom full-width blocks (cottage + disclaimer)
  if (bottomText) {
    const remainingH = Math.max(10, (PAGE_H - M) - y);
    drawBlock(doc, bottomText, M, y, contentWidth, 'Helvetica-Bold', {
      maxFont: 7.5,
      minFont: 4,
      lineGap: 1,
      paragraphGap: 3,
      maxHeight: remainingH,
    });
  }

  doc.end();

  await new Promise((res, rej) => {
    stream.on('finish', res);
    stream.on('error', rej);
  });
}

/* ---------- Sheet helpers: Airtable fetch ---------- */
async function fetchRun(runId) {
  
  if (DB_BACKEND === 'airtable') {
    const { data } = await API.get(`${STERILIZATION_RUNS_TABLE}/${runId}`);
    return data;
      
  } else {
    
    // NocoDB v3: filter on the server. Fetching the entire computed view is
    // both slow and unreliable when the API only returns the first page.
    if (isNocoV3()) {
      if (runId == null || runId === '') return null;
      const target = String(toFlat(runId) || '').trim();
      if (!target) return null;

      const fieldsToTry = /^\d+$/.test(target)
        ? ['nocopk', 'steri_run_id']
        : ['steri_run_id', 'nocopk'];

      for (const field of fieldsToTry) {
        const rows = await fetchNocoV3Records(
          STERILIZATION_RUNS_TABLE,
          STERILIZATION_RUNS_VIEW_ID,
          {
            pageSize: 5,
            where: nocoV3Where(field, 'eq', target),
          },
          false
        );
        const row = rows.find(r => nocoV3MatchesRecord(r, target, ['steri_run_id', 'nocopk']));
        if (row) {
          return {
            id: nocoV3RecordId(row),
            fields: nocoV3RecordFields(row),
            _raw: row,
          };
        }
      }

      return null;
    }

    // NocoDB v2: accept either a numeric record Id or a steri_run_id string
    if (runId == null || runId === '') return null;

    const table = encodeURIComponent(STERILIZATION_RUNS_TABLE);

    // 1) If numeric-ish, try direct record fetch
    if (/^\d+$/.test(String(runId).trim())) {
      try {
        const url = `/api/v2/tables/${table}/records/${encodeURIComponent(runId)}`;
        const { data } = await NC.get(url);
        const row = data?.record ?? data;
        if (row) {
          return { id: row.Id ?? row.id ?? runId, fields: row };
        }
      } catch {}
    }

    // 2) Otherwise (or fallback), fetch by steri_run_id
    const paramsEq = {
      where: `(steri_run_id,eq,${String(runId).trim()})`,
      limit: 1,
      offset: 0,
    };
    const listUrl = `/api/v2/tables/${table}/records`;
    let { data } = await NC.get(listUrl, { params: paramsEq });
    let list = data && Array.isArray(data.list) ? data.list : [];
    if (!list.length) {
      // fallback for cases where steri_run_id is embedded in a JSON-ish string
      const paramsLike = {
        where: `(steri_run_id,like,${String(runId).trim()})`,
        limit: 1,
        offset: 0,
      };
      ({ data } = await NC.get(listUrl, { params: paramsLike }));
      list = data && Array.isArray(data.list) ? data.list : [];
    }
    const row = list[0];
    return row ? { id: row.Id ?? row.id, fields: row } : null;
  }
  
}

async function fetchLotsForRun(runId, runPk = '') {
  
  if (DB_BACKEND === 'airtable') {
    // filter: lots whose link field steri_run_id contains this runId
    const formula = `FIND("${runId}", ARRAYJOIN({steri_run_id}))`;
    const url = `${LOTS_TABLE}?filterByFormula=${encodeURIComponent(
      formula
    )}&pageSize=100`;
  
    const out = [];
    let next;
    let first = true;
  
    while (first || next) {
      first = false;
      const { data } = await API.get(
        url + (next ? `&offset=${next}` : '')
      );
      out.push(...(data.records || []));
      next = data.offset;
    }
    return out;
      
  } else {
    if (isNocoV3()) {
      const matchTargets = normalizeRunMatchTargets([runPk, runId]);
      if (!matchTargets.length) return [];

      // vc_lots retains the PostgreSQL run FK in steri_run_id, while
      // vc_sterilization_runs exposes both that numeric nocopk and the
      // RUN-* business identifier. Query the numeric FK first, then retain
      // the business identifier as a compatibility fallback.
      for (const candidate of matchTargets) {
        const rows = await fetchNocoV3Records(
          LOTS_TABLE,
          LOTS_VIEW_ID,
          {
            pageSize: 100,
            where: nocoV3Where('steri_run_id', 'eq', candidate),
          },
          true
        );

        const matches = rows
          .filter(row => lotMatchesRun(row, matchTargets))
          .map(row => ({
            id: nocoV3RecordId(row),
            fields: nocoV3RecordFields(row),
            _raw: row,
          }))
          .sort((a, b) => steriSheetLotFields(a).lotId.localeCompare(steriSheetLotFields(b).lotId));

        if (matches.length) return matches;
      }

      return [];
    }

    if (runId == null || runId === '') return [];

    const table = encodeURIComponent(LOTS_TABLE);
    const url = `/api/v2/tables/${table}/records`;

    const out = [];
    const limit = 100;
    let offset = 0;

    // Try eq first; then fallback to "like" (helps if link field is stored as a JSON-ish string/array)
    const wheres = [
      `(steri_run_id,eq,${String(runId).trim()})`,
      `(steri_run_id,like,${String(runId).trim()})`,
    ];

    for (const where of wheres) {
      out.length = 0;
      offset = 0;

      while (true) {
        const params = {
          where,
          limit,
          offset,
          sort: 'Id,asc',
        };

        const { data } = await NC.get(url, { params });
        const list = data && Array.isArray(data.list) ? data.list : [];
        for (const row of list) {
          out.push({
            id: row.Id ?? row.id,
            fields: row,
          });
        }

        if (list.length < limit) break;
        offset += limit;
      }

      if (out.length) break;
    }

    return out;
  }
  
}

/* ---------- Render Sterilizer Sheet (Letter) with QR per row ---------- */
async function renderSterilizerSheetPDF(outPath, runRec, lotRecs) {
  await fs.promises.mkdir(path.dirname(outPath), { recursive: true });

  const doc = new PDFDocument({
    size: [LETTER_W, LETTER_H],
    margins: {
      top: SHEET_MARGIN_PT,
      left: SHEET_MARGIN_PT,
      right: SHEET_MARGIN_PT,
      bottom: SHEET_MARGIN_PT,
    },
  });

  const stream = fs.createWriteStream(outPath);
  doc.pipe(stream);

  const runFields = steriSheetRunFields(runRec);
  const runNo = runFields.runNo;
  const processType = runFields.processType;
  const op = runFields.operator;
  const start = fmtDt(runFields.start);
  const end = fmtDt(runFields.end);
  const plannedItem = runFields.plannedItem;
  const plannedCount = runFields.plannedCount;
  const plannedSize = runFields.plannedSize;
  const good = runFields.goodCount;
  const bad = runFields.destroyedCount;

  // Header
  doc.fontSize(18).font('Helvetica-Bold').text(
    `Sterilizer Output Sheet — Run ${runNo}`
  );
  doc.moveDown(0.25);
  doc.fontSize(10).font('Helvetica').text(
    `Process: ${processType}  Operator: ${op}`
  );
  doc.text(`Start: ${start}  End: ${end}`);
  doc.text(
    `Planned: ${plannedCount || '-'} @ ${
      plannedSize || '-'
    } of ${plannedItem || '-'}`
  );
  doc.text(
    `Result: Good ${good ?? '-'} / Destroyed ${bad ?? '-'}`
  );
  doc.moveDown(0.5);

  doc
    .moveTo(SHEET_MARGIN_PT, doc.y)
    .lineTo(LETTER_W - SHEET_MARGIN_PT, doc.y)
    .stroke();
  doc.moveDown(0.4);

  // Table columns (Lot, Item, Recipe, Unit, Status, QR)
  const cols = [
    { key: 'lot_id', title: 'Lot', w: 100, align: 'left' },
    { key: 'item', title: 'Item', w: 100, align: 'left' },
    { key: 'recipe', title: 'Recipe', w: 100, align: 'left' },
    { key: 'unit', title: 'Unit', w: 50, align: 'right' },
    { key: 'status', title: 'Status', w: 50, align: 'left' },
    { key: 'qr', title: 'QR', w: 50, align: 'center' },
  ];

  const x0 = SHEET_MARGIN_PT;
  let y = doc.y;

  // Header row
  doc.font('Helvetica-Bold').fontSize(10);
  let x = x0;
  for (const c of cols) {
    doc.text(c.title, x, y, {
      width: c.w,
      align: c.align || 'left',
    });
    x += c.w + 8;
  }
  y += 16;
  doc
    .moveTo(SHEET_MARGIN_PT, y)
    .lineTo(LETTER_W - SHEET_MARGIN_PT, y)
    .stroke();
  y += 4;

  doc.font('Helvetica').fontSize(9);

  // Rows
  for (const lot of lotRecs) {
    const lotFields = steriSheetLotFields(lot);
    const lotId = lotFields.lotId;
    const itemName = lotFields.itemName;
    const recipeName = lotFields.recipeName;
    const unit = lotFields.unit;
    const status = lotFields.status;
    const qrUrl = lotFields.qrUrl;

    // text columns
    x = x0;
    const row = [
      { v: lotId, w: cols[0].w, align: cols[0].align },
      { v: itemName, w: cols[1].w, align: cols[1].align },
      { v: recipeName, w: cols[2].w, align: cols[2].align },
      { v: unit, w: cols[3].w, align: cols[3].align },
      { v: status, w: cols[4].w, align: cols[4].align },
    ];

    for (const cell of row) {
      doc.text(cell.v || '', x, y, {
        width: cell.w,
        align: cell.align || 'left',
      });
      x += cell.w + 8;
    }

    // QR per row
    const qrBoxW = cols[5].w;
    const qrSize = Math.min(qrBoxW, 64);
    if (qrUrl) {
      const png = await QRCode.toDataURL(qrUrl, {
        errorCorrectionLevel: 'M',
        margin: 0,
        scale: 4,
      });
      const buf = Buffer.from(png.split(',')[1], 'base64');
      const qrX = x + Math.floor((qrBoxW - qrSize) / 2);
      doc.image(buf, qrX, y - 2, {
        width: qrSize,
        height: qrSize,
      });
    }

    // advance row
    const rowHeight = 60;
    y += rowHeight;

    // page break
    if (y > LETTER_H - SHEET_MARGIN_PT - 40) {
      doc.addPage();
      y = SHEET_MARGIN_PT;
    }
  }

  doc.end();

  await new Promise((res, rej) => {
    stream.on('finish', res);
    stream.on('error', rej);
  });
}

function fmtDt(v) {
  if (!v) return '-';
  const d = typeof v === 'string' ? new Date(v) : v;
  if (!(d instanceof Date) || isNaN(d.getTime())) return '-';
  return d.toLocaleString();
}

function inferProcessTypeFromRun(f) {
  const tt = Number(f.target_temp_c);
  const pm = (f.pressure_mode || '').toString().toLowerCase();

  if (Number.isFinite(tt) && tt <= 100) return 'Pasteurized';
  if (pm === 'open') return 'Pasteurized';
  if (Number.isFinite(tt) && tt >= 110) return 'Sterilized';

  return 'Sterilized';
}

/* ---------- Printing ---------- */
function splitPrinterOptions(raw) {
  const txt = String(raw || '').trim();
  if (!txt) return [];

  // Supports either comma-separated or shell-like whitespace-separated options.
  // Examples:
  //   LP_LABEL_OPTIONS=media=Custom.4x2in,fit-to-page,landscape
  //   LP_LABEL_OPTIONS="media=Custom.4x2in fit-to-page landscape"
  return txt
    .split(/[\s,]+/)
    .map(s => s.trim())
    .filter(Boolean);
}

function orientationOption() {
  return (ORIENT === 'landscape' || FORCE_LAND) ? 'landscape' : 'portrait';
}

function defaultLabelLpOptions() {
  const opts = splitPrinterOptions(LP_DEFAULT_OPTIONS);

  // Only add defaults when caller did not provide explicit label options.
  // CUPS media names are driver-specific, so LP_LABEL_OPTIONS is preferred.
  if (!LP_LABEL_OPTIONS) {
    opts.push(orientationOption());
    opts.push('fit-to-page');
  }

  return opts;
}

function labelLpOptions() {
  const explicit = splitPrinterOptions(LP_LABEL_OPTIONS);
  return explicit.length ? explicit : defaultLabelLpOptions();
}

function sheetLpOptions() {
  const explicit = splitPrinterOptions(LP_SHEET_OPTIONS);
  if (explicit.length) return explicit;
  return [...splitPrinterOptions(LP_DEFAULT_OPTIONS), 'media=Letter', 'portrait', 'fit-to-page'];
}

async function printWithLpTo(printerName, pdfPath, options = []) {
  if (!IS_POSIX_PRINT) return false;

  const args = [];
  if (printerName) args.push('-d', printerName);
  for (const opt of options) {
    if (opt) args.push('-o', opt);
  }
  args.push(pdfPath);

  if (LP_DRY_RUN) {
    log.info('LP dry-run print command', { command: LP_COMMAND, args });
    return true;
  }

  return await new Promise((resolve) => {
    const p = spawn(LP_COMMAND, args, {
      cwd: __dirname,
      windowsHide: true,
    });

    let out = '';
    let err = '';
    p.stdout.on('data', (d) => (out += d.toString()));
    p.stderr.on('data', (d) => (err += d.toString()));
    p.on('error', (e) => {
      log.error('lp spawn failed', { command: LP_COMMAND, printer: printerName, pdfPath, err: e?.message || String(e) });
      resolve(false);
    });
    p.on('close', (code) => {
      if (code === 0) {
        log.info('lp print submitted', { printer: printerName || '(default)', pdfPath, options, out: out.trim() });
        resolve(true);
      } else {
        log.error('lp print failed', { command: LP_COMMAND, printer: printerName, pdfPath, options, err: err.trim() || `exit ${code}` });
        resolve(false);
      }
    });
  });
}

async function printWithSumatraTo(
  printerName,
  pdfPath,
  settings = SUMATRA_SETTINGS
) {
  if (!IS_WINDOWS) return false;
  if (!USE_SUMATRA) return false;
  if (!printerName) return false;

  const args = [
    '-silent',
    '-print-to',
    printerName,
    '-print-settings',
    settings,
    pdfPath,
    '-exit-on-print',
  ];

  return await new Promise((resolve) => {
    const p = spawn(SUMATRA_EXE, args, {
      cwd: __dirname,
      windowsHide: true,
    });
    let err = '';
    p.stderr.on('data', (d) => (err += d.toString()));
    p.on('error', (e) => {
      log.error('Sumatra spawn failed', { printer: printerName, pdfPath, err: e?.message || String(e) });
      resolve(false);
    });
    p.on('close', (code) => {
      if (code === 0) resolve(true);
      else {
        log.error('Sumatra print failed', { printer: printerName, pdfPath, err: err || `exit ${code}` });
        resolve(false);
      }
    });
  });
}

async function printWithPdfToPrinter(pdfPath) {
  if (!IS_WINDOWS) return false;
  if (!print) {
    log.error('pdf-to-printer is not available', { platform: PLATFORM });
    return false;
  }

  try {
    const opts = { printer: PRINTER, silent: true, margin: 0 };

    if (FORM_NAME) {
      opts.paperSize = FORM_NAME;
    } else {
      opts.paperSize = {
        width: LABEL_W_IN || 4,
        height: LABEL_H_IN || 2,
      };
      opts.landscape =
        ORIENT === 'landscape' || FORCE_LAND;
    }

    await print(pdfPath, opts);
    return true;
  } catch (e) {
    log.error('pdf-to-printer failed', { printer: PRINTER, pdfPath, err: e?.message || String(e) });
    return false;
  }
}

async function printLabelPdfWithFallback(pdfPath) {
  return await withPrinterLock(PRINTER, async () => {
    if (PRINT_DRY_RUN) {
      log.info('PRINT_DRY_RUN enabled; skipping physical label print', {
        printer: PRINTER || '(default)',
        pdfPath,
        platform: PLATFORM,
      });
      return true;
    }

    if (IS_POSIX_PRINT) {
      return await printWithLpTo(PRINTER, pdfPath, labelLpOptions());
    }

    // Windows path: try Sumatra, then pdf-to-printer.
    const ok = await printWithSumatraTo(
      PRINTER,
      pdfPath,
      SUMATRA_SETTINGS
    );
    if (ok) return true;

    return await printWithPdfToPrinter(pdfPath);
  });
}

async function printSheetPdfNoFallback(
  pdfPath,
  preferredPrinter,
  jobPrinter
) {
  // Sheets must NOT fall back to the label printer
  const target = jobPrinter || preferredPrinter || '';
  if (!target) return false;

  return await withPrinterLock(target, async () => {
    if (PRINT_DRY_RUN) {
      log.info('PRINT_DRY_RUN enabled; skipping physical sheet print', {
        printer: target,
        pdfPath,
        platform: PLATFORM,
      });
      return true;
    }

    if (IS_POSIX_PRINT) {
      return await printWithLpTo(target, pdfPath, sheetLpOptions());
    }

    const ok = await printWithSumatraTo(
      target,
      pdfPath,
      'noscale,portrait'
    );
    return ok;
  });
}

/* ---------- Process (branch by source_kind) ---------- */

async function processRecord(rec) {
  const id = rec.id;
  const f = rec.fields || {};
  const kind = (toFlat(f.source_kind) || '').toLowerCase();

  try {
    status(id, 'picked', { kind });

    const archiveDir = path.resolve(
      __dirname,
      LOG_DIR
    );

    if (!fs.existsSync(archiveDir)) {
      fs.mkdirSync(archiveDir, { recursive: true });
    }

    const timestamp = new Date().toISOString().replace(/[:.]/g, '-');

    // --- Sterilizer sheet ---
    if (kind === 'steri_sheet') {
      const runLinkRaw =
        f.run_id && Array.isArray(f.run_id) && f.run_id[0]
          ? f.run_id[0]
          : (
              linkedNocoValue(f.sterilization_runs, ['steri_run_id', 'nocopk']) ||
              linkedNocoValue(f.run_id, ['steri_run_id', 'nocopk']) ||
              f.steri_run_id ||
              f.sterilization_run_id ||
              null
            );
      const runLink = String(toFlat(runLinkRaw) || '').trim();
      if (!runLink) {
        throw new Error(
          'steri_sheet job missing run_id/sterilization_runs link'
        );
      }

      // Claim the job before any NocoDB lookups so another daemon cannot
      // pick the same sheet while its run/lot data is being loaded.
      await markStatus(id, 'Printing', null);

      const loadStartedAt = Date.now();
      status(id, 'loading_sheet_run', { run_id: runLink });
      const run = await fetchRun(runLink);
      if (!run) {
        throw new Error(`steri_sheet run not found for run_id="${runLink}"`);
      }

      const runFields = steriSheetRunFields(run);
      const businessRunId = runFields.runNo || runLink;
      status(id, 'loading_sheet_lots', { run_id: businessRunId });
      const lots = await fetchLotsForRun(businessRunId, run.id);
      const expectedGood = safeNum(runFields.goodCount, 0);

      status(id, 'sheet_data_loaded', {
        run_id: businessRunId,
        run_pk: run.id,
        lot_count: lots.length,
        expected_good: expectedGood,
        elapsed_ms: Date.now() - loadStartedAt,
      });

      if (!lots.length && expectedGood > 0) {
        throw new Error(
          `Sterilizer sheet run ${businessRunId} reports ${expectedGood} good lot(s), ` +
          'but no linked lots were returned. Refusing to print a blank sheet.'
        );
      }
      if (lots.length && expectedGood !== lots.length) {
        log.warn('Sterilizer sheet lot count differs from good_count', {
          run_id: businessRunId,
          lot_count: lots.length,
          expected_good: expectedGood,
        });
      }

      const outName = `steri-sheet_${businessRunId}_${timestamp}.pdf`;
      const outPath = path.join(archiveDir, outName);

      status(id, 'rendering_sheet', { pdf: outPath });
      await renderSterilizerSheetPDF(outPath, run, lots);

      const jobPrinter = (f.target_printer || '')
        .toString()
        .trim();
      const envPrinter = (STERI_SHEET_PRINTER || '')
        .toString()
        .trim();

      status(id, 'printing_sheet', { printer: jobPrinter || envPrinter, pdf: outPath });

      const ok = await printSheetPdfNoFallback(
        outPath,
        envPrinter,
        jobPrinter
      );
      if (!ok) {
        throw new Error(
          `Sterilizer sheet print failed (no valid sheet printer or print error).
job.target_printer="${jobPrinter}" env.STERI_SHEET_PRINTER="${envPrinter}"`
        );
      }

      status(id, 'printed');
      await markStatus(id, 'Printed', null);
      return;
    }

    // --- Default: lot labels (4×2) ---
    const out = path.join(
      archiveDir,
      `label_${timestamp}_${id}.pdf`
    );
    status(id, 'rendering_label', { pdf: out });
    const gathered = gatherFields(rec);
    if (!hasRenderableLabelText(gathered)) {
      const availableFields = Object.keys(f).sort().join(', ');
      throw new Error(
        'No renderable label text was returned for this print job. ' +
        'Verify that the queued job resolves to vc_lots/vc_products and exposes the expected label fields. ' +
        `Available fields: ${availableFields || '(none)'}`
      );
    }
    await markStatus(id, 'Printing', null);
    if (gathered.isSyringeLabel) {
      await renderSplitSyringeLabelPDF(out, rec);
    } else if (gathered.isPackageSampleLabel) {
      await renderProductPackageSampleLabelPDF(out, rec);
    } else {
      await renderLabelPDF(out, rec);
    }

    // Write PDF path back to the active backend (best-effort)
    try {
      await updateQueueRecord(id, { pdf_path: out });
    } catch {}
    
    status(id, 'printing_label', { printer: PRINTER, pdf: out });
    const ok = await printLabelPdfWithFallback(out);
    if (!ok) throw new Error('Label print failed');
    
    log.info('Label rendered', { kind, id, out });
    
    // --- Product-only: print second info label if companyInfo is present ---
    if (
      gathered.kind === 'product' &&
      !gathered.isSyringeLabel &&
      !gathered.isPackageSampleLabel &&
      String(gathered.companyInfo || '').trim()
    ) {
      // small driver delay between two prints, just like between jobs
      await new Promise((resolve) =>
        setTimeout(resolve, PRINT_DRIVER_DELAY)
      );

      const out2 = path.join(
        archiveDir,
        `label_info_${timestamp}_${id}.pdf`
      );

      await renderProductInfoLabelPDF(out2, rec);

      // We intentionally do NOT overwrite pdf_path; primary label remains the canonical path.
      status(id, 'printing_info_label', { printer: PRINTER, pdf: out2 });
      const ok2 = await printLabelPdfWithFallback(out2);
      if (!ok2) throw new Error('Product info label print failed');
      
      log.info('Info label rendered', { kind, id, out: out2 });
      
    }

    status(id, 'printed');
    await markStatus(id, 'Printed', null);
    
  } catch (err) {
    const msg = err?.message || String(err);
    status(id, 'error', { msg });
    await markStatus(id, 'Error', msg);
    log.error('Print error', { id, kind, msg });
  }
}

/* ---------- Loop ---------- */
async function cycle() {
  try {
    const records = await fetchQueued(QUEUE_VIEW);
    for (const rec of records) {
      const kind = (
        toFlat(rec.fields?.source_kind) || ''
      ).toLowerCase();
    
      // Safety net: enforce PRINT_TARGET filtering even if the backend view/formula was misconfigured.
      if (PRINT_TARGET_VALUE) {
        const v = toFlat(rec.fields?.[PRINT_TARGET_FIELD]);
        if (String(v || '').trim() !== PRINT_TARGET_VALUE) {
          continue;
        }
      }
    
      // Optional: only one daemon instance should print sterilizer sheets.
      if (!ENABLE_STERI_SHEETS && kind === 'steri_sheet') {
        continue;
      }
    
      try {
        await processRecord(rec);
      } catch (ep) {
        log.error('ProcessRecord threw', { err: ep?.message || String(ep) });

        // Delay only between label prints, not for steri_sheet
        if (kind !== 'steri_sheet') {
          await new Promise((resolve) =>
            setTimeout(resolve, PRINT_DRIVER_DELAY)
          );
        }

        // Try a second time and fail after that
        await processRecord(rec);
      }
    }
  } catch (e) {
    log.error('Cycle error', { err: e?.message || String(e), ...httpErrorMeta(e) });
  } finally {
    setTimeout(cycle, POLL_MS);
  }
}

async function startDaemon() {
  log.info('MushroomProcess print daemon starting', { backend: DB_BACKEND, instance: INSTANCE_ID });

  await resolveNocoV3Configuration();

  if (DB_BACKEND !== 'airtable') {
    log.info('NocoDB config', {
      api_version: NOCODB_API_VERSION,
      base_id: NOCODB_BASE_ID || '(v2/not set)',
      auto_resolve_ids: NOCODB_AUTO_RESOLVE_IDS,
      queue_read_table: '(vc_print_queue bypassed)',
      queue_read_view: PRINT_QUEUE_READ_VIEW_ID || '(none)',
      queue_write_table: PRINT_QUEUE_WRITE_TABLE,
      queue_write_id_field: PRINT_QUEUE_WRITE_ID_FIELD,
      lots_table: LOTS_TABLE,
      products_table: PRODUCTS_TABLE,
      lots_view: LOTS_VIEW_ID || '(none)',
      sterilization_runs_table: ENABLE_STERI_SHEETS ? STERILIZATION_RUNS_TABLE : '(sterilizer sheets disabled)',
      sterilization_runs_view: STERILIZATION_RUNS_VIEW_ID || '(none)',
    });
  }

  log.info(
    `Queue: ${PRINT_TARGET_FIELD} = ${PRINT_TARGET_VALUE} | Poll: ${POLL_MS}ms | Label printer: ${
      PRINTER || '(default)'
    } | Sheet printer: ${
      STERI_SHEET_PRINTER || '(set per job or env)'
    }`
  );
  log.info(`Logs: ${LOG_DIR}`);
  log.info(
    `FORCE_PAGE_SIZE=${FORCE_PAGE} | LOT PAGE ${PAGE_W}x${PAGE_H} pt | FORM=${
      FORM_NAME || '(none)'
    } | ORIENT=${ORIENT}${FORCE_LAND ? ' (forced landscape)' : ''}`
  );
  log.info(
    `Margins=${M}pt | Logo=${LOGO_W_PT}pt | QR=${QR_SIZE_PT}pt | Border=${DRAW_BORDER} | Platform=${PLATFORM} | Sumatra=${
      USE_SUMATRA ? 'on' : 'off'
    } | lp=${IS_POSIX_PRINT ? LP_COMMAND : 'n/a'} | PRINT_DRY_RUN=${PRINT_DRY_RUN} | LP_DRY_RUN=${LP_DRY_RUN}`
  );

  if (CHECK_CONFIG_ONLY) {
    log.info('Configuration check passed; exiting without polling or printing.');
    return;
  }

  // Optional heartbeat so you can tell the daemon is alive even when the queue is empty.
  const HEARTBEAT_MS = safeNum(process.env.HEARTBEAT_MS, 60000);
  if (HEARTBEAT_MS > 0) {
    setInterval(() => {
      log.debug('Heartbeat', { backend: DB_BACKEND, poll_ms: POLL_MS });
    }, HEARTBEAT_MS).unref?.();
  }

  cycle();
}

if (require.main === module) {
  startDaemon().catch(error => {
    log.error('Print daemon startup failed', { err: error?.message || String(error) });
    process.exitCode = 1;
  });
}

module.exports = {
  detectItemCategory,
  extractInventoryId,
  buildQrResolverUrl,
  stableQrUrlFromFields,
  labelQrUrl,
  gatherFields,
  hasRenderableLabelText,
  nocoV3Where,
  combineNocoV3WhereClauses,
  buildNocoV3QueueWhere,
  printTargetForSource,
  queueSourceLinkValue,
  queueSourcePk,
  queueSourceBusinessId,
  nocoV3SourceFieldNames,
  mergeQueueSourceFields,
  lotMatchesRun,
  steriSheetRunFields,
  steriSheetLotFields,
};
