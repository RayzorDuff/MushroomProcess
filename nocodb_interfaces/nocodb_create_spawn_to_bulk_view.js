/**
 * Create ""Spawn to Bulk"" view
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
  console.log("ðŸ”§ Creating 'Spawn to Bulk' view...");
  const tables = await api(project//tables);
  const table = tables.list.find(t => t.title === TABLE_NAME || t.table_name === TABLE_NAME);
  if (!table) throw new Error(Table '' not found);

  const meta = {
    "sort":  [

             ],
    "groupBy":  [
                    {
                        "column_name":  "item_name",
                        "order":  "asc"
                    },
                    {
                        "column_name":  "strain_species_strain",
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
                                                      "FullyColonized",
                                                      "Fridge"
                                                  ]
                                    },
                                    {
                                        "column_name":  "item_category",
                                        "comparator":  "in",
                                        "value":  [
                                                      "grain"
                                                  ]
                                    }
                                ]
               },
    "fields":  [
                   "item_name",
                   "strain_species_strain",
                   "inoculated_at",
                   "substrate_inputs",
                   "output_count",
                   "fruiting_goal",
                   "override_spawn_time",
                   "operator",
                   "notes",
                   "ui_error",
                   "validation"
               ],
    "allowExport":  false,
    "allowPrint":  true
};

  const view = await api(	ables//views, "POST", {
    title: "Spawn to Bulk",
    type: "grid",
    fk_model_id: table.id,
    meta
  });
  console.log(âœ… Created view: );
    await api(iews//actions, "POST", { "title":"Spawn to Bulk","type":"updateRow","meta":{"updates":[{"column_name":"action","value":"SpawnToBulk"}]}});
  console.log("âœ… Added custom action: " + (.title || ''));
  console.log("ðŸŽ‰ Done.");
}

main().catch(e => { console.error("âŒ", e.message); process.exit(1); });
