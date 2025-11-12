/**
 * Create ""Print Queue"" view
 * Table: print_queue
 */
import fetch from "node-fetch";

const BASE_URL = process.env.NOCO_BASE_URL || "https://your-nocodb-instance.com";
const PROJECT_SLUG = process.env.NOCO_PROJECT || "mushroom_inventory";
const TABLE_NAME = "print_queue";
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
  console.log("ðŸ”§ Creating 'Print Queue' view...");
  const tables = await api(project//tables);
  const table = tables.list.find(t => t.title === TABLE_NAME || t.table_name === TABLE_NAME);
  if (!table) throw new Error(Table '' not found);

  const meta = {
    "sort":  [
                 {
                     "column_name":  "created_at",
                     "order":  "desc"
                 }
             ],
    "groupBy":  [
                    {
                        "column_name":  "printer",
                        "order":  "asc"
                    }
                ],
    "filter":  {
                   "condition":  "AND",
                   "children":  [
                                    {
                                        "column_name":  "print_status",
                                        "comparator":  "in",
                                        "value":  [
                                                      "queued",
                                                      "error"
                                                  ]
                                    }
                                ]
               },
    "fields":  [
                   "job_id",
                   "source_kind",
                   "source_id",
                   "label_title",
                   "label_subtitle",
                   "label_footer",
                   "label_qr",
                   "printer",
                   "print_status",
                   "created_at"
               ],
    "allowExport":  false,
    "allowPrint":  true
};

  const view = await api(	ables//views, "POST", {
    title: "Print Queue",
    type: "grid",
    fk_model_id: table.id,
    meta
  });
  console.log(âœ… Created view: );
    await api(iews//actions, "POST", { "title":"Requeue","type":"updateRow","meta":{"updates":[{"column_name":"print_status","value":"queued"}]}});
  console.log("âœ… Added custom action: " + (.title || ''));
  console.log("ðŸŽ‰ Done.");
}

main().catch(e => { console.error("âŒ", e.message); process.exit(1); });
