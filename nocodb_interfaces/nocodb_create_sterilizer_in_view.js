/**
 * Create ""Sterilizer In"" view
 * Table: sterilization_runs
 */
import fetch from "node-fetch";

const BASE_URL = process.env.NOCO_BASE_URL || "https://your-nocodb-instance.com";
const PROJECT_SLUG = process.env.NOCO_PROJECT || "mushroom_inventory";
const TABLE_NAME = "sterilization_runs";
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
  console.log("ðŸ”§ Creating 'Sterilizer In' view...");
  const tables = await api(project//tables);
  const table = tables.list.find(t => t.title === TABLE_NAME || t.table_name === TABLE_NAME);
  if (!table) throw new Error(Table '' not found);

  const meta = {
    "allowPrint":  true,
    "sort":  [

             ],
    "groupBy":  [
                    {
                        "column_name":  "process_type",
                        "order":  "asc"
                    }
                ],
    "fields":  [
                   "steri_run_id",
                   "planned_item",
                   "planned_recipe",
                   "planned_unit_size",
                   "planned_count",
                   "process_type",
                   "target_temp_c",
                   "pressure_mode",
                   "start_time",
                   "operator",
                   "notes",
                   "ui_error"
               ],
    "allowExport":  false
};

  const view = await api(	ables//views, "POST", {
    title: "Sterilizer In",
    type: "grid",
    fk_model_id: table.id,
    meta
  });
  console.log(âœ… Created view: );
    await api(iews//actions, "POST", { "title":"Start Run","type":"updateRow","meta":{"updates":[{"column_name":"action","value":"StartRun"}]}});
  console.log("âœ… Added custom action: " + (.title || ''));
  console.log("ðŸŽ‰ Done.");
}

main().catch(e => { console.error("âŒ", e.message); process.exit(1); });
