#!/usr/bin/env node
/**
 * airtable_export_postprocess.js
 *
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
  myBusinessAddressAndContact: "MyBuinessAddressAndContact",
  myBusinessOffering: "MyBusinessOffering",
};

// Airtable-export formulas in _schema.json use field IDs inside { ... }.
// We build formulas using IDs discovered by field NAME in the same table.
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
  for (const table of schema.tables || []) {
    if (!table || !Array.isArray(table.fields)) continue;
    removed += removeFromFields(table);
  }

  rewriteCompanyFormulasProducts(schema);
  rewriteCompanyFormulasLots(schema);
  
  writeJson(outPath, schema);

  console.log(`Wrote ${outPath}`);
  console.log(`Removed ${removed} " From: " fields`);
}

main();
