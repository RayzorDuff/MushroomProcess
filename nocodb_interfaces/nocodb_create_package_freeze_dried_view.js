/**
 * Create ""Package Freeze Dried"" view
 * Table: products
 */
import fetch from "node-fetch";

const BASE_URL = process.env.NOCO_BASE_URL || "https://your-nocodb-instance.com";
const PROJECT_SLUG = process.env.NOCO_PROJECT || "mushroom_inventory";
const TABLE_NAME = "products";
const API_TOKEN = process.env.NOCO_TOKEN || "YOUR_API_TOKEN_HERE";

async function api(path, method = "GET", body = null) {
  const res = await fetch(${BASE_URL}/api/v2/, {
    method,
    headers: {
      accept: "application/json",
      "xc-token": API_TOKEN,
      "content-type": "application/json",
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  if (!res.ok) {
    const err = await res.text();
    throw new Error(API   failed:  );
  }
  return res.json();
}

async function main() {
  console.log("ðŸ”§ Creating 'Package Freeze Dried' view...");
  const tables = await api(project//tables);
  const table = tables.list.find(t => t.title === TABLE_NAME || t.table_name === TABLE_NAME);
  if (!table) throw new Error(Table '' not found);

  const meta = {
    "sort":  [

             ],
    "groupBy":  [
                    {
                        "column_name":  "strain_species_strain",
                        "order":  "asc"
                    }
                ],
    "filter":  {
                   "condition":  "AND",
                   "children":  [
                                    {
                                        "column_name":  "tray_state",
                                        "comparator":  "eq",
                                        "value":  "freezer_tray"
                                    }
                                ]
               },
    "fields":  [
                   "product_id",
                   "package_item_category",
                   "source_tray_id",
                   "net_weight_g",
                   "net_weight_oz",
                   "operator",
                   "notes",
                   "ui_error",
                   "tray_state"
               ],
    "allowExport":  false,
    "allowPrint":  true
};

  const view = await api(	ables//views, "POST", {
    title: "Package Freeze Dried",
    type: "grid",
    fk_model_id: table.id,
    meta
  });
  console.log(âœ… Created view: );
    await api(iews//actions, "POST", { "title":"FreezeDry","type":"updateRow","meta":{"updates":[{"column_name":"action","value":"FreezeDry"}]}});
  console.log("âœ… Added custom action: " + (.title || ''));
  await api(iews//actions, "POST", { "title":"PackageFreezeDried","type":"updateRow","meta":{"updates":[{"column_name":"action","value":"PackageFreezeDried"}]}});
  console.log("âœ… Added custom action: " + (.title || ''));
  console.log("ðŸŽ‰ Done.");
}

main().catch(e => { console.error("âŒ", e.message); process.exit(1); });
