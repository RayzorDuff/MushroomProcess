#!/usr/bin/env python3
"""Owner-run Ecwid inventory inspection, current-order reconciliation and first publication.
Credentials stay inside the existing n8n/Postgres containers. No Woo/ERP writes.
"""
import argparse
import json
import re
import subprocess

PG = 'mushroomprocess-bridge-postgres'
NODE = r'''
(async()=>{
 const chunks=[];for await(const c of process.stdin)chunks.push(c);
 const p=JSON.parse(Buffer.concat(chunks));
 const store=process.env.ECWID_STORE_ID,secret=process.env.ECWID_SECRET_TOKEN;
 if(!/^[0-9]+$/.test(store||'') || !secret)throw Error('Ecwid configuration unavailable');
 if(!/^\/(products|orders)(\/|\?|$)/.test(p.path))throw Error('Unsupported Ecwid path');
 const r=await fetch('https://app.ecwid.com/api/v3/'+store+p.path,{
 method:p.method||'GET',redirect:'error',signal:AbortSignal.timeout(30000),
 headers:{Authorization:'Bearer '+secret,'Content-Type':'application/json'},
 body:p.body?JSON.stringify(p.body):undefined});
 if(!r.ok)throw Error('Ecwid HTTP '+r.status);
 const x=await r.json();
 if(p.path.startsWith('/orders?')){
  // Strip customer/payment data before leaving the container.
  console.log(JSON.stringify({total:x.total,count:x.count,items:(x.items||[]).map(o=>({
   id:String(o.id),status:o.fulfillmentStatus,payment_status:o.paymentStatus,updated:o.updateDate,

   items:(o.items||[]).map(i=>({id:i.id,name:i.name||'',sku:i.sku||'',productId:i.productId,quantity:i.quantity}))}))}));
 }else console.log(JSON.stringify(Object.fromEntries(Object.entries(x).filter(([k])=>[
 'id','sku','quantity','unlimited','enabled','updateCount','warning'].includes(k)))));
})().catch(e=>{console.error(e.message);process.exitCode=1});
'''


def run(args, body=None):
    result = subprocess.run(args, input=body, text=True, capture_output=True)
    if result.returncode:
        # Never echo a private SQL statement or API response.
        raise RuntimeError('Container operation failed; inspect private local logs/configuration')
    return result.stdout.strip()


def pg(sql):
    result = run(['sudo','docker','exec','-i',PG,'sh','-ec',
                  'exec psql -X -qAt -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"'], sql)
    return json.loads(result) if result else None


def literal(value):
    return "convert_from(decode('" + str(value).encode("utf-8").hex() + "','hex'),'UTF8')"


def api(container, path, method='GET', body=None):
    return json.loads(run(['sudo','docker','exec','-i',container,'node','-e',NODE],
                          json.dumps(dict(path=path,method=method,body=body))))


def reconcile_orders(container, sku):
    """Re-read all current Ecwid orders, preserving customer fields in MP.
    Existing order upsert's advisory key is reused; no historical export replay.
    Do this while the selected SKU and competing stock writers are paused.
    """
    orders=[]
    for offset in range(0,10000,100):
        page=api(container,f'/orders?limit=100&offset={offset}')
        orders.extend(page['items'])
        if offset+len(page['items']) >= int(page['total']): break
    else: raise RuntimeError('Order pagination exceeds reviewed limit; no stock publication')
    matched=0
    for o in orders:
        if not any(i.get('sku')==sku for i in o['items']): continue
        matched+=1
        if not re.fullmatch(r'[A-Za-z0-9_-]+',o['id']): raise ValueError('Unexpected Ecwid order identity')
        oid=literal(o['id'])
        values=[literal(o['status']),literal(o['payment_status']),literal(json.dumps(o['items']))]
        # Preserve all names, emails, financial and reconciliation fields.
        sql=f"""BEGIN;
SELECT pg_advisory_xact_lock(hashtextextended({oid},0));
DO $stock$ BEGIN
 IF (SELECT count(*) FROM public.ecommerce_orders WHERE ecwid_order_id={oid})>1 THEN
  RAISE EXCEPTION 'Duplicate Ecwid order requires review'; END IF;
 IF EXISTS(SELECT 1 FROM public.ecommerce_orders WHERE ecwid_order_id={oid}) THEN
  UPDATE public.ecommerce_orders SET status={values[0]},payment_status={values[1]},
   items_json=(SELECT jsonb_agg(coalesce((SELECT old FROM jsonb_array_elements(coalesce(nullif(items_json,''),'[]')::jsonb) old WHERE old->>'sku'=fresh->>'sku' AND (old->>'id' IS NULL OR old->>'id'=fresh->>'id') LIMIT 1),'{{}}'::jsonb)||fresh)::text FROM jsonb_array_elements({values[2]}::jsonb) fresh),nc_updated_at=now() WHERE ecwid_order_id={oid};
 ELSE
  IF {literal(o['status'])} NOT IN ('SHIPPED','DELIVERED','WILL_NOT_DELIVER','RETURNED') OR
   {literal(o.get('updated') or '2026-11-21')}::timestamptz >= '2026-11-21T00:00:00Z'::timestamptz THEN
   RAISE EXCEPTION 'Current Ecwid order missing in MP: run existing native order ingestion before stock initialization';
  END IF;
 END IF;
END $stock$;
COMMIT;"""
        # This query returns no data. Suppress the advisory lock's void output.
        run(['sudo','docker','exec','-i',PG,'sh','-ec',
             'exec psql -X -q -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"'],sql)
    print(json.dumps({'matching_orders_checked':matched,'customer_fields':'preserved'}))


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('action',choices=['inspect','sync-orders','initialize'])
    p.add_argument('--ecommerce-id',type=int,default=1)
    p.add_argument('--confirm-paused',action='store_true',help='Selected SKU, MP fulfillment and competing stock writers paused')
    a=p.parse_args()
    if a.ecommerce_id<=0: raise ValueError('Positive MP ecommerce ID required')
    containers=run(['sudo','docker','ps','--filter','label=com.docker.compose.service=n8n','--format','{{.ID}}']).splitlines()
    if len(containers)!=1: raise RuntimeError('Identify exactly one existing n8n container')
    container=containers[0]
    c=pg(f"SELECT row_to_json(x) FROM (SELECT nocopk ecommerce_id,external_sku,external_product_id,external_variation_id FROM public.ecommerce WHERE nocopk={a.ecommerce_id} AND coalesce(provider,'ecwid')='ecwid') x;")
    if not c or not re.fullmatch(r'[0-9]+',c['external_product_id'] or ''): raise ValueError('Existing mapped Ecwid product ID required')
    path='/products/'+c['external_product_id']
    if c['external_variation_id']:
        if not re.fullmatch(r'[0-9]+',c['external_variation_id']): raise ValueError('Numeric variation ID required')
        path+='/combinations/'+c['external_variation_id']
    remote=api(container,path)
    if remote.get('sku')!=c['external_sku']: raise RuntimeError('Ecwid SKU/ID mismatch; do not remap or create a product')
    print(json.dumps({'mp':c,'ecwid':remote}))
    if a.action=='inspect': return
    if not a.confirm_paused: raise ValueError('Pause competing writers and the selected SKU/MP fulfillment first')
    if a.action=='initialize' and (remote.get('enabled') is not False or remote.get('unlimited') is not False):
        raise ValueError('First publication requires a disabled product with finite stock; use the Ecwid admin')
    reconcile_orders(container,c['external_sku'])
    if a.action=='sync-orders': return
    # Refresh after the order catch-up, before any stock adjustment.
    remote=api(container,path)
    if remote.get('enabled') is not False or remote.get('unlimited') is not False: raise RuntimeError('Product pause changed')
    current=remote.get('quantity')
    if type(current) is not int or current<0: raise ValueError('Review Ecwid finite-stock readback')
    net=pg(f'SELECT to_json(available_quantity) FROM public.mp_commerce_inventory() WHERE ecommerce_id={a.ecommerce_id};')
    plan=pg(f'SELECT public.mp_ecwid_inventory_initial_plan({a.ecommerce_id},{current});')
    print(json.dumps({'reviewed_current_net':net,'plan':plan}))
    if plan['status']=='ready':
        receipt=api(container,path+'/inventory','PUT',{'quantityDelta':plan['quantityDelta']})
        if receipt.get('updateCount')!=1 or receipt.get('warning'):
            raise RuntimeError('Unknown Ecwid write outcome: retain pending receipt, do not retry')
        readback=api(container,path)
        if readback.get('quantity')!=net or readback.get('enabled') is not False:
            raise RuntimeError('Readback changed: retain receipt and review; never resend blindly')
        print(json.dumps({'receipt':plan['token'],'readback':readback,
            'ack':pg('SELECT to_json(public.mp_ecwid_inventory_resolve('+literal(plan['token'])+"::uuid,'applied')); ")}))
    elif plan['status']!='unchanged': raise RuntimeError('Publication requires review; leave the product disabled')
    print('Verified first publication. Owner may re-enable this same Ecwid product after the review query passes.')

if __name__=='__main__': main()
