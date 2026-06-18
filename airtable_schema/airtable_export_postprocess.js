#!/usr/bin/env node
require('./load_env');
/**
 * airtable_export_postprocess.js
 * Version: 2026-05-31.2
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
 * Post-process Airtable schema export JSON:
 *  - Removes Airtable "lookup/rollup (from ...)" helper fields (names containing " (from ").
 *  - Rewrites specific company/branding formulas by FIELD NAME (not by old string content),
 *    so it works on any base that uses the same schema field names.
 *
 * Usage:
 *   copy export/_schema.json export/_schema.json.orig
 *   node airtable_export_postprocess.js export/_schema.json.orig export/_schema.json
 *
 * Notes:
 *   - This script expects Airtable-exported schema format: { tables: [ { name, id, fields:[...] } ] }.
 *   - If a target field is missing, the script will warn and continue (safe for other schemas).
 */

const fs = require("fs");
const path = require("path");

// Feature toggles
// Defaults preserve existing behavior (both steps enabled).
const POSTPROCESS_REWRITE_COMPANY =
  typeof global.envBool === 'function'
    ? global.envBool('POSTPROCESS_REWRITE_COMPANY', true)
    : (process.env.POSTPROCESS_REWRITE_COMPANY || 'true').toString().toLowerCase() === 'true';

const POSTPROCESS_REMOVE_EXTRA_FIELDS =
  typeof global.envBool === 'function'
    ? global.envBool('POSTPROCESS_REMOVE_EXTRA_FIELDS', true)
    : (process.env.POSTPROCESS_REMOVE_EXTRA_FIELDS || 'true').toString().toLowerCase() === 'true';

const POSTPROCESS_OBFUSCATE_OPERATOR_EMAILS =
  typeof global.envBool === 'function'
    ? global.envBool('POSTPROCESS_OBFUSCATE_OPERATOR_EMAILS', true)
    : (process.env.POSTPROCESS_OBFUSCATE_OPERATOR_EMAILS || 'true').toString().toLowerCase() === 'true';

const POSTPROCESS_REWRITE_BRANDING_STRINGS =
  typeof global.envBool === 'function'
    ? global.envBool('POSTPROCESS_REWRITE_BRANDING_STRINGS', true)
    : (process.env.POSTPROCESS_REWRITE_BRANDING_STRINGS || 'true').toString().toLowerCase() === 'true';

const POSTPROCESS_REWRITE_EXPORT_DATA_FILES =
  typeof global.envBool === 'function'
    ? global.envBool('POSTPROCESS_REWRITE_EXPORT_DATA_FILES', true)
    : (process.env.POSTPROCESS_REWRITE_EXPORT_DATA_FILES || 'true').toString().toLowerCase() === 'true';

function readJson(path) {
  const raw = fs.readFileSync(path, "utf8");
  return JSON.parse(raw);
}

function writeJson(path, obj) {
  fs.writeFileSync(path, JSON.stringify(obj, null, 2) + "\n", "utf8");
}

// --- Company placeholders (these are the ONLY values this script injects) ---
const COMPANY = {
  myBusinessName: "My Business",
  regulatedBusinessName: "Regulated Business",
  myBusinessUrl: "https://www.mybusiness.com/",
  regulatedBusinessUrl: "https://www.regulatedbusiness.com/",
  regulatedBusinessAddressAndContact: "RegulatedBusinessAddressAndContact",
  myBusinessAddressAndContact: "MyBusinessAddressAndContact",
  myBusinessOffering: "MyBusinessOffering",
};

// Airtable-export formulas in _schema.json use field IDs inside { ... }.
// We build formulas using IDs discovered by field NAME in the same table.
const OPERATOR_EMAIL_DOMAIN = (process.env.POSTPROCESS_OPERATOR_EMAIL_DOMAIN || 'mybusiness.com')
  .toString()
  .trim()
  .replace(/^@+/, '') || 'mybusiness.com';

const SAFE_EMAIL_DOMAINS = new Set([
  OPERATOR_EMAIL_DOMAIN.toLowerCase(),
  'mybusiness.com',
  'regulatedbusiness.com',
]);

const BRANDING_REPLACEMENTS = [
  [/Rooted\s+Psyche\s+Church/gi, COMPANY.regulatedBusinessName],
  [/Rooted\s+Psyche/gi, COMPANY.regulatedBusinessName],
  [/Dank\s+Mushrooms,?\s+LLC/gi, COMPANY.myBusinessName],
  [/Dank\s+Mushrooms/gi, COMPANY.myBusinessName],
  [/https?:\/\/(?:www\.)?danks\.store\/?/gi, COMPANY.myBusinessUrl],
  [/\b(?:www\.)?danks\.store\b/gi, 'www.mybusiness.com'],
  [/\bdanks\.store\b/gi, 'mybusiness.com'],
  [/\bdanks\.net\b/gi, 'mybusiness.com'],
  [/\bsales@mybusiness\.com\b/gi, 'contact@mybusiness.com'],
  [/\bsales@danks\.net\b/gi, 'contact@mybusiness.com'],
  [/1726\s+Goldenvue\s+Drive\s*\\nJohnstown,\s*CO\s*80534\s*\\nhttps?:\/\/(?:www\.)?mybusiness\.com\/?\s*\\n970-587-3294\s*\\ncontact@mybusiness\.com/gi, COMPANY.myBusinessAddressAndContact],
  [/1726\s+Goldenvue\s+Drive\s*\\nJohnstown,\s*CO\s*80534\s*\\nhttps?:\/\/(?:www\.)?mybusiness\.com\/?\s*\\n970-587-3294\s*\\n[^\\n\s]+@[^\\n\s]+/gi, COMPANY.myBusinessAddressAndContact],
  [/1726\s+Goldenvue\s+Drive\s*\\nJohnstown,\s*CO\s*80534\s*\\nhttps?:\/\/(?:www\.)?danks\.store\/?\s*\\n970-587-3294\s*\\n(?:sales@danks\.net|contact@mybusiness\.com)/gi, COMPANY.myBusinessAddressAndContact],
  [/1726\s+Goldenvue\s+Drive\s*\nJohnstown,\s*CO\s*80534\s*\nhttps?:\/\/(?:www\.)?mybusiness\.com\/?\s*\n970-587-3294\s*\ncontact@mybusiness\.com/gi, COMPANY.myBusinessAddressAndContact],
  [/1726\s+Goldenvue\s+Drive\s*\nJohnstown,\s*CO\s*80534\s*\nhttps?:\/\/(?:www\.)?mybusiness\.com\/?\s*\n970-587-3294\s*\n[^\n\s]+@[^\n\s]+/gi, COMPANY.myBusinessAddressAndContact],
  [/1726\s+Goldenvue\s+Drive\s*\nJohnstown,\s*CO\s*80534\s*\nhttps?:\/\/(?:www\.)?danks\.store\/?\s*\n970-587-3294\s*\n(?:sales@danks\.net|contact@mybusiness\.com)/gi, COMPANY.myBusinessAddressAndContact],
  [/1726\s+Goldenvue\s+Drive/gi, 'MyBusinessStreetAddress'],
  [/Johnstown,\s*CO\s*80534/gi, 'MyBusinessCityStateZip'],
  [/\b970[-.\s]?587[-.\s]?3294\b/g, 'MyBusinessPhone'],
];

function replaceBrandingInString(value) {
  let out = value;
  for (const [pattern, replacement] of BRANDING_REPLACEMENTS) {
    out = out.replace(pattern, replacement);
  }
  out = out.replaceAll('970-587-3294', 'MyBusinessPhone');
  return out;
}

function createOperatorEmailObfuscator() {
  const emailMap = new Map();
  const emailRe = /\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b/gi;

  function replacementFor(email) {
    const normalized = String(email).trim().toLowerCase();
    const domain = normalized.split('@').pop();
    if (/^operator\d+\.email\.address@/.test(normalized)) return email;
    if (SAFE_EMAIL_DOMAINS.has(domain)) return email;
    if (!emailMap.has(normalized)) {
      emailMap.set(normalized, `operator${emailMap.size + 1}.email.address@${OPERATOR_EMAIL_DOMAIN}`);
    }
    return emailMap.get(normalized);
  }

  function obfuscateString(value) {
    return value.replace(emailRe, (email) => replacementFor(email));
  }

  return { obfuscateString, emailMap };
}

function replaceOperatorDisplayNamesInString(value) {
  return value.replace(/[^<>\r\n"]+<\s*(operator(\d+)\.email\.address@[^<>\s]+)\s*>/gi, (_match, email, n) => {
    return `Operator ${n} <${email}>`;
  });
}

function rewriteStringsDeep(value, transformString) {
  if (typeof value === 'string') return transformString(value);
  if (Array.isArray(value)) return value.map((x) => rewriteStringsDeep(x, transformString));
  if (value && typeof value === 'object') {
    for (const key of Object.keys(value)) {
      value[key] = rewriteStringsDeep(value[key], transformString);
    }
  }
  return value;
}

function makeExportTextTransformer(obfuscator) {
  return function transformExportString(value) {
    let out = value;
    if (POSTPROCESS_REWRITE_BRANDING_STRINGS) out = replaceBrandingInString(out);
    if (POSTPROCESS_OBFUSCATE_OPERATOR_EMAILS) {
      out = obfuscator.obfuscateString(out);
      out = replaceOperatorDisplayNamesInString(out);
    }
    if (POSTPROCESS_REWRITE_BRANDING_STRINGS) out = replaceBrandingInString(out);
    return out;
  };
}

function shouldRewriteExportFile(filePath, schemaInPath) {
  const base = path.basename(filePath);
  const ext = path.extname(filePath).toLowerCase();
  if (!['.json', '.ndjson', '.yml', '.yaml'].includes(ext)) return false;
  if (base.endsWith('.bak') || base.endsWith('.bakn')) return false;
  if (path.resolve(filePath) === path.resolve(schemaInPath)) return false;
  return true;
}

function rewriteExportDataFiles(exportDir, schemaInPath, transformString) {
  if (!exportDir || !fs.existsSync(exportDir)) return { scanned: 0, changed: 0 };
  let scanned = 0;
  let changed = 0;
  for (const entry of fs.readdirSync(exportDir, { withFileTypes: true })) {
    if (!entry.isFile()) continue;
    const filePath = path.join(exportDir, entry.name);
    if (!shouldRewriteExportFile(filePath, schemaInPath)) continue;
    scanned += 1;
    const before = fs.readFileSync(filePath, 'utf8');
    const after = transformString(before);
    if (after !== before) {
      fs.writeFileSync(filePath, after, 'utf8');
      changed += 1;
    }
  }
  return { scanned, changed };
}

function getFieldIdByName(table, fieldName) {
  const f = (table.fields || []).find((x) => x && x.name === fieldName);
  return f ? f.id : null;
}

function setFormulaByFieldName(table, fieldName, formula) {
  const f = (table.fields || []).find((x) => x && x.name === fieldName);
  if (!f) return false;
  if (f.type !== "formula") {
    console.warn(`WARN: ${table.name}.${fieldName} is type ${f.type}, expected formula. Skipping.`);
    return false;
  }
  if (!f.options) f.options = {};
  f.options.formula = formula;
  // Leave referencedFieldIds as-is; Airtable export may include them, but they're optional for NocoDB translation.
  return true;
}

function removeFromFields(table) {
  const before = table.fields.length;
  table.fields = table.fields.filter((f) => {
    const n = (f && f.name) || "";
    // Airtable export names recirocol link fields as: "From field: linked_field"
    // We remove those by name pattern, independent of any company data.
    if (n.includes("From field: ")) return false;
    return true;
  });
  return before - table.fields.length;
}

function rewriteCompanyFormulasLots(schema) {
  for (const table of schema.tables || []) {
    if (!table || !table.name) continue;
    if (table.name !== "lots") continue;

    const itemCategoryMatId = getFieldIdByName(table, "item_category_mat") || getFieldIdByName(table, "item_category");
    const originRegulatedId = getFieldIdByName(table, "regulated (from strain_id)");

    if (!itemCategoryMatId || !originRegulatedId) {
      console.warn(
        `WARN: lots table missing required fields (item_category_mat/item_category and/or origin_strain_regulated). ` +
          `Skipping company formula rewrites for this table.`
      );
      continue;
    }

    // Common OR block used across these formulas.
    const orRetailCats = [
      "freezedriedmushrooms",
      "fresh_mushrooms",
      "freezer_tray",
      "fresh_tray",
    ]
      .map((v) => `{${itemCategoryMatId}} = "${v}"`)
      .join(",\r\n    ");

    // lots.label_company_lot
    setFormulaByFieldName(
      table,
      "label_company_lot",
      `"${COMPANY.myBusinessName}"`
    );    
  }
}


function rewriteCompanyFormulasProducts(schema) {
  for (const table of schema.tables || []) {
    if (!table || !table.name) continue;
    if (table.name !== "products") continue;

    const itemCategoryMatId = getFieldIdByName(table, "item_category_mat") || getFieldIdByName(table, "item_category");
    const originRegulatedId = getFieldIdByName(table, "origin_strain_regulated");

    if (!itemCategoryMatId || !originRegulatedId) {
      console.warn(
        `WARN: products table missing required fields (item_category_mat/item_category and/or origin_strain_regulated). ` +
          `Skipping company formula rewrites for this table.`
      );
      continue;
    }

    // Common OR block used across these formulas.
    const orRetailCats = [
      "freezedriedmushrooms",
      "fresh_mushrooms",
      "freezer_tray",
      "fresh_tray",
    ]
      .map((v) => `{${itemCategoryMatId}} = "${v}"`)
      .join(",\r\n    ");

    // products.public_link
    // Keep the same behavior: for retail categories, switch between regulated/non-regulated URLs;
    // otherwise default to my business.
    setFormulaByFieldName(
      table,
      "public_link",
      `IF(\r\n  OR(\r\n    {${itemCategoryMatId}} = "freezedriedmushrooms",\r\n    {${itemCategoryMatId}} = "fresh_mushrooms"\r\n  ),\r\n  IF({${originRegulatedId}}, "${COMPANY.regulatedBusinessUrl}", "${COMPANY.myBusinessUrl}"),\r\n  "${COMPANY.myBusinessUrl}"\r\n)`
    );

    // products.label_company_prod
    setFormulaByFieldName(
      table,
      "label_company_prod",
      `IF({${originRegulatedId}}, \r\n  IF(OR(\r\n    ${orRetailCats}\r\n  ), "${COMPANY.regulatedBusinessName}", \r\n  "${COMPANY.myBusinessName}"),\r\n"${COMPANY.myBusinessName}")`
    );

    // products.label_companyaddress_prod
    setFormulaByFieldName(
      table,
      "label_companyaddress_prod",
      `IF({${originRegulatedId}}, \r\n  IF(OR(\r\n    ${orRetailCats}\r\n  ), "${COMPANY.regulatedBusinessAddressAndContact}", \r\n  "${COMPANY.myBusinessAddressAndContact}"),\r\n"${COMPANY.myBusinessAddressAndContact}")`
    );
    
    // products.label_companyinfo_prod
    // Replace offering text only; preserve conditional structure.
    setFormulaByFieldName(
      table,
      "label_companyinfo_prod",
      `IF({${originRegulatedId}}, \r\n  IF(OR(\r\n    ${orRetailCats}\r\n  ), "",\r\n  IF({${itemCategoryMatId}} = "fruiting_block", "${COMPANY.myBusinessOffering}","")\r\n  ), IF(OR(\r\n    {${itemCategoryMatId}} = "freezedriedmushrooms",\r\n    {${itemCategoryMatId}} = "fresh_mushrooms",\r\n    {${itemCategoryMatId}} = "fruiting_block"\r\n  ), "${COMPANY.myBusinessOffering}","")\r\n)`
    );
  }
}

function main() {
  const [, , inPath, outPath] = process.argv;
  if (!inPath || !outPath) {
    console.error("Usage: node airtable_export_postprocess.js <input _schema.json> <output _schema.json.mine>");
    process.exit(2);
  }

  const schema = readJson(inPath);

  let removed = 0;
  if (POSTPROCESS_REMOVE_EXTRA_FIELDS) {
    for (const table of schema.tables || []) {
      if (!table || !Array.isArray(table.fields)) continue;
      removed += removeFromFields(table);
    }
  }

  if (POSTPROCESS_REWRITE_COMPANY) {
    rewriteCompanyFormulasProducts(schema);
    rewriteCompanyFormulasLots(schema);
  }
  
  const obfuscator = createOperatorEmailObfuscator();
  const transformExportString = makeExportTextTransformer(obfuscator);
  rewriteStringsDeep(schema, transformExportString);

  writeJson(outPath, schema);

  let exportRewriteStats = { scanned: 0, changed: 0 };
  if (POSTPROCESS_REWRITE_EXPORT_DATA_FILES) {
    exportRewriteStats = rewriteExportDataFiles(path.dirname(outPath), inPath, transformExportString);
  }

  const obfuscatedOperatorEmailCount = obfuscator.emailMap.size;
  console.log(`Wrote ${outPath}`);
  if (POSTPROCESS_REMOVE_EXTRA_FIELDS) {
    console.log(`Removed ${removed} " From: " fields`);
  } else {
    console.log('Skipped removing extra fields (POSTPROCESS_REMOVE_EXTRA_FIELDS=false)');
  }

  if (!POSTPROCESS_REWRITE_COMPANY) {
    console.log('Skipped company formula rewrites (POSTPROCESS_REWRITE_COMPANY=false)');
  }
  if (POSTPROCESS_REWRITE_EXPORT_DATA_FILES) {
    console.log(`Rewrote branding/contact strings in ${exportRewriteStats.changed}/${exportRewriteStats.scanned} export data file(s)`);
  } else {
    console.log('Skipped export data file rewrites (POSTPROCESS_REWRITE_EXPORT_DATA_FILES=false)');
  }
  if (POSTPROCESS_OBFUSCATE_OPERATOR_EMAILS) {
    console.log(`Obfuscated ${obfuscatedOperatorEmailCount} distinct email address(es)`);
  } else {
    console.log('Skipped operator email obfuscation (POSTPROCESS_OBFUSCATE_OPERATOR_EMAILS=false)');
  }

  if (!POSTPROCESS_REWRITE_BRANDING_STRINGS) {
    console.log('Skipped generic branding string rewrites (POSTPROCESS_REWRITE_BRANDING_STRINGS=false)');
  }
}

main();
