/**
 * Script: print-daemon.js
 * Version: 2026-01-26.1
 * Summary: NocoDB or Airtable backed print_queue, steri_sheet and lots updates
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
const NOCODB_SOURCE_ID = (process.env.NOCODB_SOURCE_ID || process.env.NOCODB_BASE_SOURCE_ID || '').trim();
const NOCODB_PAGE_SIZE = safeNum(process.env.NOCODB_PAGE_SIZE, 25);

// Airtable uses table names/IDs directly. NocoDB v2 also used table names/IDs directly.
// NocoDB v3 external PostgreSQL sources usually require internal table/view IDs from API Snippets.
// For v3, the daemon can read rendered label fields from vc_print_queue while writing status fields
// back to the underlying print_queue table.
const PRINT_QUEUE_TABLE = process.env.PRINT_QUEUE_TABLE || process.env.AIRTABLE_QUEUE_TABLE || process.env.NOCODB_QUEUE_TABLE_ID || 'print_queue';
const PRINT_QUEUE_READ_TABLE = process.env.PRINT_QUEUE_READ_TABLE || process.env.PRINT_QUEUE_TABLE_READ || PRINT_QUEUE_TABLE;
const PRINT_QUEUE_WRITE_TABLE = process.env.PRINT_QUEUE_WRITE_TABLE || process.env.PRINT_QUEUE_TABLE_WRITE || PRINT_QUEUE_TABLE;
const PRINT_QUEUE_READ_VIEW_ID = (process.env.PRINT_QUEUE_READ_VIEW_ID || process.env.PRINT_QUEUE_VIEW_ID || process.env.NOCODB_QUEUE_VIEW_ID || '').trim();
const PRINT_QUEUE_WRITE_VIEW_ID = (process.env.PRINT_QUEUE_WRITE_VIEW_ID || '').trim();
const PRINT_QUEUE_WRITE_ID_FIELD = (process.env.PRINT_QUEUE_WRITE_ID_FIELD || 'nocopk').trim();

const STERILIZATION_RUNS_TABLE = process.env.STERILIZATION_RUNS_TABLE || 'sterilization_runs';
const STERILIZATION_RUNS_VIEW_ID = (process.env.STERILIZATION_RUNS_VIEW_ID || '').trim();
const LOTS_TABLE = process.env.LOTS_TABLE || 'lots';
const LOTS_VIEW_ID = (process.env.LOTS_VIEW_ID || '').trim();

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

function toFlat(v) {
  if (v == null) return '';
  if (Array.isArray(v)) return v.filter(Boolean).map(toFlat).join(', ');
  if (typeof v === 'object' && v.name) return v.name;
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

function isNocoV3() {
  return DB_BACKEND !== 'airtable' && NOCODB_API_VERSION === 'v3';
}

function nocoV3RecordsPath(tableId) {
  if (!NOCODB_SOURCE_ID) {
    throw new Error('NOCODB_SOURCE_ID is required when NOCODB_API_VERSION=v3');
  }
  if (!tableId) {
    throw new Error('NocoDB v3 table id is required');
  }
  return `/api/v3/data/${encodeURIComponent(NOCODB_SOURCE_ID)}/${encodeURIComponent(tableId)}/records`;
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
      // NocoDB v3 external PostgreSQL API. Read from vc_print_queue or another read view
      // that contains rendered label fields; write status updates back to print_queue.
      const records = await fetchNocoV3Records(
        PRINT_QUEUE_READ_TABLE,
        PRINT_QUEUE_READ_VIEW_ID,
        {},
        false
      );

      return records
        .map(normalizeNocoV3QueueRecord)
        .filter(rec => String(toFlat(rec.fields?.print_status)).trim() === 'Queued')
        .filter(rec => {
          if (!PRINT_TARGET_VALUE) return true;
          const v = toFlat(rec.fields?.[PRINT_TARGET_FIELD]);
          return String(v || '').trim() === PRINT_TARGET_VALUE;
        });
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
    pick(f, ['item_category_mat (from product_id)']) ||
    pick(f, ['item_category_mat (from lot_id)']) ||
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
      'label_packaged_prod (from product_id)',
    ]);
    const useBy = pick(f, [
      'label_useby_prod',
      'label_useby_prod (from product_id)',
    ]);

    return {
      kind: 'product',
      labelType,
      isPackageSampleLabel: String(labelType).trim().toLowerCase() === 'product_package_sample',
      itemCategory,
      isSyringeLabel: isSyringeCategory(itemCategory),
      company: pick(f, ['label_company_prod', 'label_company_prod (from product_id)']) || '',
      title: pick(f, ['label_title_prod', 'label_title_prod (from product_id)']),
      subtitle: pick(f, ['label_subtitle_prod', 'label_subtitle_prod (from product_id)']),
      footer: pick(f, ['label_footer_prod', 'label_footer_prod (from product_id)']),
      packaged,
      useBy,
      qr: pick(f, [
        'public_link (from product_id)',
        'public_link (from lot_id)',
        'public_link',
      ]),
      // product-only blocks
      companyAddr: pick(f, ['label_companyaddress_prod', 'label_companyaddress_prod (from product_id)']),
      companyInfo: pick(f, ['label_companyinfo_prod', 'label_companyinfo_prod (from product_id)']),
      disclaimer: pick(f, ['label_disclaimer_prod', 'label_disclaimer_prod (from product_id)']),
      cottage: pick(f, ['label_cottage_prod', 'label_cottage_prod (from product_id)']),
      extras: [
        pick(f, ['label_proc_prod', 'label_proc_prod (from product_id)']),
        pick(f, ['label_inoc_prod', 'label_inoc_prod (from product_id)']),
        pick(f, ['label_spawned_prod', 'label_spawned_prod (from product_id)']),
        packaged,
        useBy,
      ].filter(Boolean),
    };
  }

  // default: lot
  return {
    kind: 'lot',
    itemCategory,
    isSyringeLabel: isSyringeCategory(itemCategory),
    company: pick(f, ['label_company_lot (from lot_id)']) || '',
    title: pick(f, ['label_title_lot (from lot_id)']),
    subtitle: pick(f, ['label_subtitle_lot (from lot_id)']),
    footer: pick(f, ['label_footer_lot (from lot_id)']),
    qr: pick(f, [
      'public_link (from lot_id)',
      'public_link (from product_id)',
      'public_link',
    ]),
    extras: [
      pick(f, ['label_proc_line (from lot_id)']),
      pick(f, ['label_inoc_line (from lot_id)']),
      pick(f, ['label_spawned_line (from lot_id)']),
      pick(f, ['label_useby_line (from lot_id)']),
      (() => {
        const v = pick(f, ['label_graininputblocks_line (from lot_id)']);
        return v ? `Grain: ${v}` : '';
      })(),
      (() => {
        const v = pick(f, ['label_substrateinputblocks_line (from lot_id)']);
        return v ? `Substrate: ${v}` : '';
      })(),
    ].filter(Boolean),
  };
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
  const qrUrl = L.qr || 'https://example.com';
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
  const qrUrl = L.qr || 'https://example.com';

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
    
    // NocoDB v3: fetch from the configured sterilization_runs table/view and match locally.
    if (isNocoV3()) {
      if (runId == null || runId === '') return null;
      const target = String(runId).trim();
      const rows = await fetchNocoV3Records(STERILIZATION_RUNS_TABLE, STERILIZATION_RUNS_VIEW_ID, {}, true);
      const row = rows.find(r => nocoV3MatchesRecord(r, target, ['steri_run_id']));
      return row ? { id: nocoV3RecordId(row), fields: nocoV3RecordFields(row), _raw: row } : null;
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

async function fetchLotsForRun(runId) {
  
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
      if (runId == null || runId === '') return [];
      const target = String(runId).trim();
      const rows = await fetchNocoV3Records(LOTS_TABLE, LOTS_VIEW_ID, {}, true);
      return rows
        .filter(row => {
          const f = nocoV3RecordFields(row);
          if (String(f.steri_run_id ?? '').includes(target)) return true;
          if (String(f.sterilization_run_id ?? '').includes(target)) return true;
          if (String(f.sterilization_runs ?? '').includes(target)) return true;
          return JSON.stringify(f).includes(target);
        })
        .map(row => ({ id: nocoV3RecordId(row), fields: nocoV3RecordFields(row), _raw: row }));
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

  const f = (runRec && runRec.fields) || {};
  const runNo = f.steri_run_id || runRec.id;
  const processType =
    (f.process_type || '').toString().trim() ||
    inferProcessTypeFromRun(f);
  const op = (f.operator || '').toString();
  const start = fmtDt(f.start_time);
  const end = fmtDt(f.end_time || f.override_end_time);
  const plannedItem = toFlat(f.planned_item_id);
  const plannedCount = f.planned_count ?? '';
  const plannedSize = f.planned_unit_size ?? '';
  const good = f.good_count ?? '';
  const bad = f.destroyed_count ?? '';

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
    const lf = lot.fields || {};
    const lotId = lf.lot_id || lot.id;
    const itemName = toFlat(lf.item_name) || '';
    const recipeName = toFlat(lf.recipe_name) || '';
    const unit =
      lf.unit_size != null ? String(lf.unit_size) : '';
    const status = toFlat(lf.status) || '';
    const qrUrl = lf.public_link || '';

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
      const runLink =
        f.run_id && Array.isArray(f.run_id) && f.run_id[0]
          ? f.run_id[0]
          : (
              linkedNocoValue(f.sterilization_runs, ['steri_run_id', 'nocopk']) ||
              linkedNocoValue(f.run_id, ['steri_run_id', 'nocopk']) ||
              f.steri_run_id ||
              f.sterilization_run_id ||
              null
            );
      if (!runLink)
        throw new Error(
          'steri_sheet job missing run_id/sterilization_runs link'
        );

      const run = await fetchRun(runLink);
      if (!run) {
        throw new Error(`steri_sheet run not found for run_id="${runLink}"`);
      }      
      const r = run.fields || {};
      const lots = await fetchLotsForRun(r.steri_run_id || runLink);

      const outName = `steri-sheet_${
        (run.fields && run.fields.steri_run_id) || run.id
      }_${timestamp}.pdf`;
      const outPath = path.join(archiveDir, outName);

      await markStatus(id, 'Printing', null);
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
    await markStatus(id, 'Printing', null);
    const gathered = gatherFields(rec);
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
    log.error('Cycle error', { err: e?.message || String(e) });
  } finally {
    setTimeout(cycle, POLL_MS);
  }
}

  log.info(`MushroomProcess print daemon starting`, { backend: DB_BACKEND, instance: INSTANCE_ID });
  if (DB_BACKEND !== 'airtable') {
    log.info('NocoDB config', {
      api_version: NOCODB_API_VERSION,
      source_id: NOCODB_SOURCE_ID || '(v2/not set)',
      queue_read_table: PRINT_QUEUE_READ_TABLE,
      queue_read_view: PRINT_QUEUE_READ_VIEW_ID || '(none)',
      queue_write_table: PRINT_QUEUE_WRITE_TABLE,
      queue_write_id_field: PRINT_QUEUE_WRITE_ID_FIELD,
      lots_table: LOTS_TABLE,
      lots_view: LOTS_VIEW_ID || '(none)',
      sterilization_runs_table: STERILIZATION_RUNS_TABLE,
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
  log.info(
    `Logs: ${LOG_DIR}`
);
  log.info(
  `FORCE_PAGE_SIZE=${FORCE_PAGE} | LOT PAGE ${PAGE_W}x${PAGE_H} pt | FORM=${
    FORM_NAME || '(none)'
  } | ORIENT=${ORIENT}${
    FORCE_LAND ? ' (forced landscape)' : ''
  }`
);
log.info(
  `Margins=${M}pt | Logo=${LOGO_W_PT}pt | QR=${QR_SIZE_PT}pt | Border=${DRAW_BORDER} | Platform=${PLATFORM} | Sumatra=${
    USE_SUMATRA ? 'on' : 'off'
  } | lp=${IS_POSIX_PRINT ? LP_COMMAND : 'n/a'} | PRINT_DRY_RUN=${PRINT_DRY_RUN} | LP_DRY_RUN=${LP_DRY_RUN}`
);



// Optional heartbeat so you can tell the daemon is alive even when the queue is empty.
const HEARTBEAT_MS = safeNum(process.env.HEARTBEAT_MS, 60000);
if (HEARTBEAT_MS > 0) {
  setInterval(() => {
    log.debug('Heartbeat', { backend: DB_BACKEND, poll_ms: POLL_MS });
  }, HEARTBEAT_MS).unref?.();
}

cycle();
