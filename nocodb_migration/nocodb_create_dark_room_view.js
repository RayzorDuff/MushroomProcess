/**
 * Create ""Dark Room"" view
 * Table: lots
 */
import fetch from "node-fetch";

const BASE_URL = process.env.NOCO_BASE_URL || "https://your-nocodb-instance.com";
const PROJECT_SLUG = process.env.NOCO_PROJECT || "mushroom_inventory";
const TABLE_NAME = "lots";
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
  console.log("ðŸ”§ Creating 'Dark Room' view...");
  const tables = await api(project//tables);
  const table = tables.list.find(t => t.title === TABLE_NAME || t.table_name === TABLE_NAME);
  if (!table) throw new Error(Table '' not found);

  const meta = {
    "sort":  [

             ],
    "groupBy":  [
                    {
                        "column_name":  "status",
                        "order":  "asc"
                    }
                ],
    "filter":  {
                   "condition":  "AND",
                   "children":  [
                                    {
                                        "column_name":  "status",
                                        "comparator":  "in",
                                        "value":  [
                                                      "Inoculated",
                                                      "Colonizing",
                                                      "FullyColonized",
                                                      "Fridge"
                                                  ]
                                    },
                                    {
                                        "column_name":  "item_category",
                                        "comparator":  "in",
                                        "value":  [
                                                      "fruiting_block",
                                                      "grain",
                                                      "lc_flask",
                                                      "lc_syringe"
                                                  ]
                                    }
                                ]
               },
    "fields":  [
                   "lot_id",
                   "item_name",
                   "status",
                   "action",
                   "casing_lot_id",
                   "operator",
                   "notes",
                   "ui_error"
               ],
    "allowExport":  false,
    "allowPrint":  true
};

  const view = await api(	ables//views, "POST", {
    title: "Dark Room",
    type: "grid",
    fk_model_id: table.id,
    meta
  });
  console.log(âœ… Created view: );
    await api(iews//actions, "POST", { "title":"Shake","type":"updateRow","meta":{"updates":[{"column_name":"action","value":"Shake"}]}});
  console.log("âœ… Added custom action: " + (.title || ''));
  await api(iews//actions, "POST", { "title":"Move to Fridge","type":"updateRow","meta":{"updates":[{"column_name":"action","value":"MoveToFridge"}]}});
  console.log("âœ… Added custom action: " + (.title || ''));
  await api(iews//actions, "POST", { "title":"Cold Shock","type":"updateRow","meta":{"updates":[{"column_name":"action","value":"ColdShock"}]}});
  console.log("âœ… Added custom action: " + (.title || ''));
  await api(iews//actions, "POST", { "title":"Apply Casing","type":"updateRow","meta":{"updates":[{"column_name":"action","value":"ApplyCasing"}]}});
  console.log("âœ… Added custom action: " + (.title || ''));
  await api(iews//actions, "POST", { "title":"Start Fruiting","type":"updateRow","meta":{"updates":[{"column_name":"action","value":"StartFruiting"}]}});
  console.log("âœ… Added custom action: " + (.title || ''));
  await api(iews//actions, "POST", { "title":"Contaminated","type":"updateRow","meta":{"updates":[{"column_name":"action","value":"Contaminated"}]}});
  console.log("âœ… Added custom action: " + (.title || ''));
  console.log("ðŸŽ‰ Done.");
}

main().catch(e => { console.error("âŒ", e.message); process.exit(1); });
