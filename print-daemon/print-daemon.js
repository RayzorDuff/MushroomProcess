/** print-daemon.js (with steri_sheet support, robust wrapping)
 * =============================================================================
 *  Copyright © 2025 Dank Mushrooms, LLC
 *  Licensed under the GNU General Public License v3 (GPL-3.0-only)
 *
 *  This program is free software: you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation, either version 3 of the License.
 *
 *  This program is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 *  GNU General Public License for more details.
 *
 *  You should have received a copy of the GNU General Public License
 *  along with this program. If not, see <https://www.gnu.org/licenses/>.
 * =============================================================================
**/

require('dotenv').config();
const axios = require('axios').default;
const fs = require('fs');
const path = require('path');
const PDFDocument = require('pdfkit');
const QRCode = require('qrcode');
const { print } = require('pdf-to-printer');
const { spawn } = require('child_process');

const LOG_DIR = process.env.LOG_DIR || process.env.PDF_ARCHIVE_DIR ||  './logs';
if (!fs.existsSync(LOG_DIR)) fs.mkdirSync(LOG_DIR, { recursive: true });

function nowStamp() {
  return new Date().toISOString().replace(/[:.]/g, '-');
}

/* ---------- Airtable ---------- */
const API = axios.create({
  baseURL: `https://api.airtable.com/v0/${process.env.AIRTABLE_BASE_ID}/`,
  headers: { Authorization: `Bearer ${process.env.AIRTABLE_API_KEY}` },
});

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

/* ---------- Env (hardened) ---------- */
const TABLE      = process.env.PRINT_QUEUE_TABLE || process.env.AIRTABLE_QUEUE_TABLE || 'print_queue';
const QUEUE_VIEW = process.env.QUEUE_VIEW || 'Queue_All';
const PRINTER    = process.env.PRINTER_NAME || process.env.DEFAULT_PRINTER || undefined; // label printer
const POLL_MS    = safeNum(process.env.POLL_MS, 10000);

const FORM_NAME  = (process.env.PAPER_FORM_NAME || '').trim();
const LABEL_W_IN = safeNum(process.env.LABEL_WIDTH_IN, 4);
const LABEL_H_IN = safeNum(process.env.LABEL_HEIGHT_IN, 2);
const ORIENT     = (process.env.ORIENTATION || 'portrait').toLowerCase();
const FORCE_LAND = String(process.env.FORCE_LANDSCAPE || 'false').toLowerCase() === 'true';

const FORCE_PAGE = String(process.env.FORCE_PAGE_SIZE || 'false').toLowerCase() === 'true';
const FORCE_W_PT = safeNum(process.env.FORCE_PAGE_WIDTH_PT, 288);  // 4 in
const FORCE_H_PT = safeNum(process.env.FORCE_PAGE_HEIGHT_PT, 144); // 2 in

const MARGIN_PT  = safeNum(process.env.MARGIN_PT, 8);
const LOGO_W_PT  = safeNum(process.env.LOGO_WIDTH_PT, 140);
const QR_SIZE_PT = safeNum(process.env.QR_SIZE_PT, 90);
const DRAW_BORDER = String(process.env.DRAW_PAGE_BORDER || 'false').toLowerCase() === 'true';

const USE_SUMATRA = String(process.env.USE_SUMATRA || 'false').toLowerCase() === 'true';
const SUMATRA_EXE = process.env.SUMATRA_EXE || 'SumatraPDF.exe';
const SUMATRA_SETTINGS = process.env.SUMATRA_PRINT_SETTINGS || 'noscale,portrait';

const PRINT_DRIVER_DELAY = parseInt(process.env.PRINT_DRIVER_DELAY) || 1000;

/* --- sheet-specific env --- */
const STERI_SHEET_PRINTER = process.env.STERI_SHEET_PRINTER || ''; // never fall back to label printer
const LETTER_MARGIN_IN = safeNum(process.env.LETTER_MARGIN_IN, 0.5);
const INCH = 72;
const LETTER_W = 8.5 * INCH;
const LETTER_H = 11   * INCH;
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
  if (ORIENT === 'portrait'  && PAGE_W > PAGE_H) [PAGE_W, PAGE_H] = [PAGE_H, PAGE_W];
}
const M = MARGIN_PT || 8;
const LINE_GAP = 2;

/* ---------- Airtable helpers ---------- */
async function fetchQueued(viewName) {
  const params = new URLSearchParams({
    view: viewName,
    filterByFormula: `({print_status} = 'Queued')`,
    maxRecords: '25'
  });
  const { data } = await API.get(`${TABLE}?${params.toString()}`);
  return data.records || [];
}
async function markStatus(id, status, errorMsg = null) {
  const payload = {
    records: [{ id, fields: { print_status: status, error_msg: errorMsg } }],
    typecast: true,
  };
  await API.patch(TABLE, payload);
}

/* ---------- Gather label fields ---------- */
function gatherFields(rec) {
  const f = rec.fields || {};
  const sourceKind = (toFlat(f.source_kind) || '').toLowerCase();

  if (sourceKind === 'product') {
    return {
      kind: 'product',
      company:  pick(f, ['label_company_prod (from product_id)']) || '',
      title:    pick(f, ['label_title_prod (from product_id)']),
      subtitle: pick(f, ['label_subtitle_prod (from product_id)']),
      footer:   pick(f, ['label_footer_prod (from product_id)']),
      qr:       pick(f, [
                  'public_link (from product_id)',
                  'public_link (from lot_id)',
                  'public_link'
                ]),
      // product-only blocks
      companyAddr: pick(f, ['label_companyaddress_prod (from product_id)']),
      companyInfo: pick(f, ['label_companyinfo_prod (from product_id)']),
      disclaimer:  pick(f, ['label_disclaimer_prod (from product_id)']),
      cottage:     pick(f, ['label_cottage_prod (from product_id)']),
    extras: [
      pick(f, ['label_proc_prod (from product_id)']),
      pick(f, ['label_inoc_prod (from product_id)']),
      pick(f, ['label_spawned_prod (from product_id)']),
      pick(f, ['label_packaged_prod (from product_id)']),      
      pick(f, ['label_useby_prod (from product_id)']),
      ].filter(Boolean)
    };
  }

  // default: lot
  return {
    kind: 'lot',
    company:  pick(f, ['label_company_lot (from lot_id)']) || '',
    title:    pick(f, ['label_title_lot (from lot_id)']),
    subtitle: pick(f, ['label_subtitle_lot (from lot_id)']),
    footer:   pick(f, ['label_footer_lot (from lot_id)']),
    qr:       pick(f, [
                  'public_link (from lot_id)',
                  'public_link (from product_id)',
                  'public_link'
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
    ].filter(Boolean)
  };
}

/* ---------- Logo selection (company → file) ---------- */
function normalizeCompany(str) { return (str || '').replace(/[^a-zA-Z0-9]/g, ''); }
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

// Measure how tall text would be at fontName+fontSize within width
function measureTextHeight(doc, text, width, fontName, fontSize, opts = {}) {
  const prevFont = doc._font;
  const prevSize = doc._fontSize;
  doc.font(fontName).fontSize(fontSize);
  const h = doc.heightOfString(String(text || ''), { width, ...opts });
  doc.font(prevFont).fontSize(prevSize);
  return h;
}

/**
 * Draw a paragraph that:
 * - wraps within width
 * - respects \n
 * - auto-shrinks between maxFont..minFont to fit maxHeight (if provided)
 * Returns new Y cursor.
 */
function drawBlock(doc, text, x, y, width, fontName, {
  maxFont = 12,
  minFont = 7,
  lineGap = 2,
  paragraphGap = 4,
  maxHeight = null
} = {}) {
  if (!text) return y;
  const txt = String(text);

  // choose size to fit
  let size = maxFont;
  if (maxHeight && maxHeight > 0) {
    while (size > minFont) {
      const h = measureTextHeight(doc, txt, width, fontName, size, { lineGap, paragraphGap });
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
async function renderLabelPDF(outPath, rec) {
  const L = gatherFields(rec);
  const company  = L.company || '';
  const title    = L.title || '';
  const subtitle = L.subtitle || '';
  const footer   = L.footer || '';
  const qrUrl    = L.qr || 'https://example.com';

  const doc = new PDFDocument({
    size: [PAGE_W, PAGE_H],
    margins: { top: M, left: M, right: M, bottom: M }
  });
  const stream = fs.createWriteStream(outPath);
  doc.pipe(stream);

  if (DRAW_BORDER) {
    doc.save();
    doc.lineWidth(0.7).rect(0.5, 0.5, PAGE_W - 1, PAGE_H - 1).stroke();
    doc.restore();
    doc.font('Helvetica').fontSize(6).fillColor('black')
       .text(`PAGE: ${PAGE_W}x${PAGE_H}pt | M:${M} | LogoW:${LOGO_W_PT} | QR:${QR_SIZE_PT}`, 2, 2, { width: PAGE_W-4 });
  }

  const contentWidth = PAGE_W - 2 * M;
  let y = M;

  // Logo
  const { path: logoPath } = selectLogoPath(company);
  if (logoPath) {
    try {
      doc.image(logoPath, M, y, { width: LOGO_W_PT });
      y += Math.min(LOGO_W_PT * 0.35, 42);
    } catch {}
  }

  // Title
  if (title) y = drawBlock(doc, title, M, y, contentWidth, 'Helvetica-Bold', { maxFont: 14, minFont: 4, lineGap: 1, paragraphGap: 0 });
  // Subtitle
  if (subtitle) y = drawBlock(doc, subtitle, M, y, contentWidth, 'Helvetica-Bold', { maxFont: 11, minFont: 4, lineGap: 1, paragraphGap: 4 });

  // Extras
  if (Array.isArray(L.extras)) {
    for (const line of L.extras) {
      y = drawBlock(doc, line, M, y, contentWidth, 'Helvetica-Bold', { maxFont: 8, minFont: 4, lineGap: 1, paragraphGap: 0 });
    }
  }

  // Footer (bottom-ish)
  if (footer) {
    const bottomY = PAGE_H - M - 10;
    drawBlock(doc, footer, M, bottomY, contentWidth, 'Helvetica-Bold', { maxFont: 8, minFont: 4, lineGap: 1 });
  }

  // QR lower-right
  if (qrUrl) {
    const qrPng = await QRCode.toDataURL(qrUrl, { errorCorrectionLevel: 'M', margin: 0, scale: 6 });
    const qrBuf = Buffer.from(qrPng.split(',')[1], 'base64');
    doc.image(qrBuf, PAGE_W - M - QR_SIZE_PT, PAGE_H - M - QR_SIZE_PT, { width: QR_SIZE_PT, height: QR_SIZE_PT });
  }

  doc.end();
  await new Promise((res, rej) => { stream.on('finish', res); stream.on('error', rej); });
}


/* ---------- Sheet helpers: Airtable fetch ---------- */
async function fetchRun(runId) {
  const { data } = await API.get(`sterilization_runs/${runId}`);
  return data;
}
async function fetchLotsForRun(runId) {
  // filter: lots whose link field steri_run_id contains this runId
  //console.log("Looking for ", runId);
  const formula = `FIND("${runId}", ARRAYJOIN({steri_run_id}))`;
  const url = `lots?filterByFormula=${encodeURIComponent(formula)}&pageSize=100`;
  const out = [];
  let next;
  let first = true;
  while (first || next) {
    first = false;
    const { data } = await API.get(url + (next ? `&offset=${next}` : ''));
    out.push(...(data.records || []));
    next = data.offset;
  }
  return out;
}

/* ---------- Render Sterilizer Sheet (Letter) with QR per row ---------- */
async function renderSterilizerSheetPDF(outPath, runRec, lotRecs) {
  await fs.promises.mkdir(path.dirname(outPath), { recursive: true });
  const doc = new PDFDocument({
    size: [LETTER_W, LETTER_H],
    margins: { top: SHEET_MARGIN_PT, left: SHEET_MARGIN_PT, right: SHEET_MARGIN_PT, bottom: SHEET_MARGIN_PT }
  });
  const stream = fs.createWriteStream(outPath);
  doc.pipe(stream);

  const f = (runRec && runRec.fields) || {};
  const runNo = f.steri_run_id || runRec.id;
  const processType = (f.process_type || '').toString().trim() || inferProcessTypeFromRun(f);
  const op = (f.operator || '').toString();
  const start = fmtDt(f.start_time);
  const end   = fmtDt(f.end_time || f.override_end_time);
  const plannedItem = toFlat(f.planned_item_id);
  const plannedCount = f.planned_count ?? '';
  const plannedSize = f.planned_unit_size ?? '';
  const good = f.good_count ?? '';
  const bad  = f.destroyed_count ?? '';

  // Header
  doc.fontSize(18).font('Helvetica-Bold').text(`Sterilizer Output Sheet — Run ${runNo}`);
  doc.moveDown(0.25);
  doc.fontSize(10).font('Helvetica').text(`Process: ${processType}    Operator: ${op}`);
  doc.text(`Start: ${start}    End: ${end}`);
  doc.text(`Planned: ${plannedCount || '-'} @ ${plannedSize || '-'} of ${plannedItem || '-'}`);
  doc.text(`Result: Good ${good ?? '-'} / Destroyed ${bad ?? '-'}`);
  doc.moveDown(0.5);
  doc.moveTo(SHEET_MARGIN_PT, doc.y).lineTo(LETTER_W - SHEET_MARGIN_PT, doc.y).stroke();
  doc.moveDown(0.4);

  // Table columns (Lot, Item, Recipe, Unit, Status, QR)
  const cols = [
    { key: 'lot_id',    title: 'Lot',     w: 100, align: 'left' },
    { key: 'item',      title: 'Item',    w: 100, align: 'left' },
    { key: 'recipe',    title: 'Recipe',  w: 100, align: 'left' },
    { key: 'unit',      title: 'Unit',    w: 50,  align: 'right' },
    { key: 'status',    title: 'Status',  w: 50,  align: 'left' },
    { key: 'qr',        title: 'QR',      w: 50,  align: 'center' },
  ];
  const x0 = SHEET_MARGIN_PT;
  let y = doc.y;

  // Header row
  doc.font('Helvetica-Bold').fontSize(10);
  let x = x0;
  for (const c of cols) {
    doc.text(c.title, x, y, { width: c.w, align: c.align || 'left' });
    x += c.w + 8;
  }
  y += 16;
  doc.moveTo(SHEET_MARGIN_PT, y).lineTo(LETTER_W - SHEET_MARGIN_PT, y).stroke();
  y += 4;
  doc.font('Helvetica').fontSize(9);

  // Rows
  for (const lot of lotRecs) {
    const lf = lot.fields || {};
    const lotId = lf.lot_id || lot.id;
    const itemName = toFlat(lf.item_name) || '';
    const recipeName = toFlat(lf.recipe_name) || '';
    const unit = (lf.unit_size != null) ? String(lf.unit_size) : '';
    const status = toFlat(lf.status) || '';
    const qrUrl = lf.public_link || '';

    // text columns
    x = x0;
    const row = [
      { v: lotId,      w: cols[0].w, align: cols[0].align },
      { v: itemName,   w: cols[1].w, align: cols[1].align },
      { v: recipeName, w: cols[2].w, align: cols[2].align },
      { v: unit,       w: cols[3].w, align: cols[3].align },
      { v: status,     w: cols[4].w, align: cols[4].align },
    ];
    for (const cell of row) {
      doc.text(cell.v || '', x, y, { width: cell.w, align: cell.align || 'left' });
      x += cell.w + 8;
    }

    // QR per row
    const qrBoxW = cols[5].w;
    const qrSize = Math.min(qrBoxW, 64);
    if (qrUrl) {
      const png = await QRCode.toDataURL(qrUrl, { errorCorrectionLevel: 'M', margin: 0, scale: 4 });
      const buf = Buffer.from(png.split(',')[1], 'base64');
      const qrX = x + Math.floor((qrBoxW - qrSize) / 2);
      doc.image(buf, qrX, y - 2, { width: qrSize, height: qrSize });
    }

    // advance row
    const rowHeight = 60;
    y += rowHeight;

    // page break
    if (y > (LETTER_H - SHEET_MARGIN_PT - 40)) {
      doc.addPage();
      y = SHEET_MARGIN_PT;
    }
  }

  doc.end();
  await new Promise((res, rej) => { stream.on('finish', res); stream.on('error', rej); });
}

function fmtDt(v) {
  if (!v) return '-';
  const d = (typeof v === 'string') ? new Date(v) : v;
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
async function printWithSumatraTo(printerName, pdfPath, settings = SUMATRA_SETTINGS) {
  if (!USE_SUMATRA) return false;
  if (!printerName) return false;
  const args = ['-silent', '-print-to', printerName, '-print-settings', settings, pdfPath, '-exit-on-print'];
  return await new Promise((resolve) => {
    const p = spawn(SUMATRA_EXE, args, { cwd: __dirname, windowsHide: true });
    let err = '';
    p.stderr.on('data', d => err += d.toString());
    p.on('close', (code) => {
      if (code === 0) resolve(true);
      else {
        console.error('Sumatra print failed:', err || `exit ${code}`);
        resolve(false);
      }
    });
  });
}
async function printLabelPdfWithFallback(pdfPath) {
  // Try Sumatra, then pdf-to-printer
  const ok = await printWithSumatraTo(PRINTER, pdfPath, SUMATRA_SETTINGS);
  if (ok) return true;
  try {
    const opts = { printer: PRINTER, silent: true, margin: 0 };
    if (FORM_NAME) {
      opts.paperSize = FORM_NAME;
    } else {
      opts.paperSize = { width: LABEL_W_IN || 4, height: LABEL_H_IN || 2 };
      opts.landscape = (ORIENT === 'landscape') || FORCE_LAND;
    }
    await print(pdfPath, opts);
    return true;
  } catch (e) {
    console.error('pdf-to-printer failed:', e.message || e);
    return false;
  }
}
async function printSheetPdfNoFallback(pdfPath, preferredPrinter, jobPrinter) {
  // Sheets must NOT fall back to the label printer
  const target = jobPrinter || preferredPrinter || '';
  if (!target) return false;
  const ok = await printWithSumatraTo(target, pdfPath, 'noscale,portrait');
  return ok;
}

/* ---------- Process (branch by source_kind) ---------- */
async function processRecord(rec) {
  const id = rec.id;
  const f = rec.fields || {};
  const kind = (toFlat(f.source_kind) || '').toLowerCase();

  try {
    const archiveDir = process.env.PDF_ARCHIVE_DIR
      ? path.resolve(__dirname, process.env.PDF_ARCHIVE_DIR)
      : path.join(__dirname, 'logs');
    if (!fs.existsSync(archiveDir)) fs.mkdirSync(archiveDir, { recursive: true });
    const timestamp = new Date().toISOString().replace(/[:.]/g, '-');

    // --- Sterilizer sheet ---
    if (kind === 'steri_sheet') {
      //const runLink = f.run_id && Array.isArray(f.run_id) && f.run_id[0] ? f.run_id[0].id : null;
      //console.log(f.run_id, " ", f.run_id[0], " ", f.run_id[0].id, " ", f.run_id[0].steri_run_id);
      const runLink = f.run_id && Array.isArray(f.run_id) && f.run_id[0];
      if (!runLink) throw new Error('steri_sheet job missing run_id link');

      const run = await fetchRun(runLink);
      //console.log(run);
      const r = run.fields || {};
      const lots = await fetchLotsForRun(r.steri_run_id);
      //console.log(lots);

      const outName = `steri-sheet_${(run.fields && run.fields.steri_run_id) || run.id}_${timestamp}.pdf`;
      const outPath = path.join(archiveDir, outName);
      await renderSterilizerSheetPDF(outPath, run, lots);

      const jobPrinter = (f.target_printer || '').toString().trim();
      const envPrinter = (STERI_SHEET_PRINTER || '').toString().trim();
      const ok = await printSheetPdfNoFallback(outPath, envPrinter, jobPrinter);
      if (!ok) {
        throw new Error(`Sterilizer sheet print failed (no valid sheet printer or print error). job.target_printer="${jobPrinter}" env.STERI_SHEET_PRINTER="${envPrinter}"`);
      }
      await markStatus(id, 'Printed', null);
      return;
    }

    // --- Default: lot labels (4×2) ---
    const out = path.join(archiveDir, `label_${timestamp}_${id}.pdf`);
    await renderLabelPDF(out, rec);

    // Optional: write path back
    try { await API.patch(TABLE, { records: [{ id, fields: { pdf_path: out } }], typecast: true }); } catch {}

    // Uncomment to print:
    const ok = await printLabelPdfWithFallback(out);
    if (!ok) throw new Error('Label print failed');

    await markStatus(id, 'Printed', null);
    console.log(`[OK] Lot label rendered → ${out}`);

  } catch (err) {
    const msg = err?.message || String(err);
    await markStatus(id, 'Error', msg);
    console.error('Print error:', msg);
  }
}

/* ---------- Loop ---------- */
async function cycle() {
  try {
    const records = await fetchQueued(QUEUE_VIEW);
    for (const rec of records) {
      const kind = (toFlat(rec.fields?.source_kind) || '').toLowerCase();

      try {
        await processRecord(rec);

      } catch (ep) {
        console.error('Process Record Error:', ep.message || ep);
        // Delay only between label prints, not for steri_sheet
        if (kind !== 'steri_sheet') {
          await new Promise(resolve => setTimeout(resolve, PRINT_DRIVER_DELAY)); // sleep between prints
        }

        // Try a second time and fail after that
        await processRecord(rec);
      }
    }
  } catch (e) {
    console.error('Cycle error:', e.message || e);
  } finally {
    setTimeout(cycle, POLL_MS);
  }
}

console.log('JD268BT-CA print daemon…');
console.log(`Queue: ${QUEUE_VIEW} | Poll: ${POLL_MS}ms | Label printer: ${PRINTER || '(default)'} | Sheet printer: ${STERI_SHEET_PRINTER || '(set per job or env)'}`);
console.log(`FORCE_PAGE_SIZE=${FORCE_PAGE} | LOT PAGE ${PAGE_W}x${PAGE_H} pt | FORM=${FORM_NAME || '(none)'} | ORIENT=${ORIENT}${FORCE_LAND ? ' (forced landscape)' : ''}`);
console.log(`Margins=${M}pt | Logo=${LOGO_W_PT}pt | QR=${QR_SIZE_PT}pt | Border=${DRAW_BORDER} | Sumatra=${USE_SUMATRA ? 'on' : 'off'}`);
cycle();