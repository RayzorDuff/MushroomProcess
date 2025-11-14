/**
 * Spawn to Bulk â€“ create fruiting blocks from grain + substrate inputs
 * Rules:
 *  - Default grain_inputs to current row_id if not provided
 *  - Validate at least 1 grain and 1 substrate; output_count >= 1
 *  - Per-output weight = (totalGrainLb/output_count) + (totalSubLb/output_count)
 *  - FB item_id derived from first substrate item_id (CVG/MM75/MM50) and size (SM/LG threshold 5 lb)
 *  - New lots status=Colonizing; inputs marked Consumed; links recorded
 *  - Event type "SpawnedToBulk"
 */
import { makeNC } from "./lib/noco.js";
const { NOCO_BASE_URL, NOCO_TOKEN, NOCO_PROJECT="mushroom_inventory" } = process.env;
const nc = makeNC({ baseUrl: NOCO_BASE_URL, token: NOCO_TOKEN, projectSlug: NOCO_PROJECT });
function chooseFBItemId({ substrateItemId, bagSizeLb }){ const big = bagSizeLb>=5? "LG":"SM"; if(/CVG/i.test(substrateItemId)) return `FB-COCO-${big}`; if(/MM75/i.test(substrateItemId)) return `FB-MM75-${big}`; if(/MM50/i.test(substrateItemId)) return `FB-MM50-${big}`; return "FB-GENERIC"; }
async function fail(rowId,msg){ if(rowId){ try{ await nc.update("lots", rowId, { ui_error: msg }); }catch{} } throw new Error(msg); }
export default async function handler(req,res){
  try{
    const { grain_inputs, substrate_inputs, output_count, operator, row_id } = req.body || {};
    let grainIds = grain_inputs;
    if(!grainIds?.length && row_id){ grainIds=[row_id]; try{ await nc.update("lots", row_id, { grain_inputs: grainIds }); }catch{} }
    if(!grainIds?.length) return await fail(row_id,"Require at least one grain_input");
    if(!substrate_inputs?.length) return await fail(row_id,"Require at least one substrate_input");
    const outCount = Number(output_count||1); if(!(outCount>0)) return await fail(row_id,"output_count must be >= 1");
    const grains = await Promise.all(grainIds.map(id=>nc.getById("lots", id)));
    const subs   = await Promise.all(substrate_inputs.map(id=>nc.getById("lots", id)));
    for(const g of grains){ if(!["FullyColonized","Fridge"].includes(g.status)) return await fail(row_id,`Grain ${g.lot_id||g.id} not fully colonized`); }
    const totalGrainLb = grains.reduce((t,g)=>t+Number(g.unit_size||0),0);
    const totalSubLb   = subs.reduce((t,s)=>t+Number(s.unit_size||0),0);
    const perOutLb     = (totalGrainLb/outCount) + (totalSubLb/outCount);
    const substrateItemId = subs[0]?.item_id||"";
    const fbItemId = chooseFBItemId({ substrateItemId, bagSizeLb: perOutLb });
    const strain_id = grains[0]?.strain_id||null;
    const now = new Date().toISOString();
    const createRows = Array.from({length:outCount},()=>({
      item_id: fbItemId,
      item_category:"fruiting_block",
      recipe_id: subs[0]?.recipe_id||null,
      strain_id,
      unit_size: perOutLb,
      qty:1,
      status:"Colonizing",
      parents_json: JSON.stringify({ grain_inputs: grainIds, substrate_inputs }),
      operator: operator||"system",
      created_at: now,
      grain_inputs: grainIds,
      substrate_inputs
    }));
    const created = await nc.create("lots", createRows);
    for(const g of grains) await nc.update("lots", g.id, { status:"Consumed" });
    for(const s of subs)   await nc.update("lots", s.id, { status:"Consumed" });
    await nc.create("events", {
      type:"SpawnedToBulk", timestamp: now, operator: operator||"system", station:"Spawn to Bulk",
      fields_json: JSON.stringify({ output_count: outCount, per_output_lb: perOutLb, grain_inputs: grainIds, substrate_inputs })
    });
    if(row_id) await nc.update("lots", row_id, { ui_error: "" });
    res.status(200).json({ ok:true, outputs: created?.list?.length||outCount });
  }catch(e){ res.status(400).json({ ok:false, error:String(e.message||e) }); }
}
