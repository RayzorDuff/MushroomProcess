#!/usr/bin/env python3
"""Native PostgreSQL two-session oversell/retry test; synthetic fixtures only."""
from concurrent.futures import ThreadPoolExecutor
import json
import subprocess


def sql(statement,check=True):
    return subprocess.run(['psql','-X','-v','ON_ERROR_STOP=1','-Atc',statement],text=True,capture_output=True,check=check)


def event(ecommerce_id,order):
    return {'schema_version':1,'provider':'woocommerce','site_key':'concurrency-052','external_order_id':order,
            'event_id':'event-'+order,'revision':1,'status':'pending','currency':'USD','total':'1','refunds':[],
            'payment_processor':'clover','processor_payment_id':None,
            'lines':[{'line_id':'1','ecommerce_id':ecommerce_id,'erp_item_code':'CONCURRENCY-052','quantity':1}]}


def ingest(payload):
    literal=json.dumps(payload).replace("'","''")
    return sql("BEGIN; SELECT public.mp_commerce_ingest('"+literal+"'::jsonb); SELECT pg_sleep(0.5); COMMIT;",False)


def main():
    item=int(sql("INSERT INTO public.items(item_id,name,category,active) VALUES('CONCURRENCY-052','Synthetic concurrency','fruiting_block',true) RETURNING nocopk").stdout.splitlines()[0])
    location=int(sql("INSERT INTO public.locations(name,active,type) VALUES('Synthetic concurrency',true,'Storage') RETURNING nocopk").stdout.splitlines()[0])
    try:
        sql(f"INSERT INTO public.products(item_id,storage_location_id,use_by) VALUES({item},{location},CURRENT_DATE+10)")
        ecommerce=int(sql(f"INSERT INTO public.ecommerce(name,item_id,provider,site_key,external_sku,sync_enabled,erp_item_code,status) VALUES('Concurrency',{item},'woocommerce','concurrency-052','CONCURRENCY-052',true,'CONCURRENCY-052','Sterilized') RETURNING nocopk").stdout.splitlines()[0])
        with ThreadPoolExecutor(2) as pool:
            results=list(pool.map(ingest,[event(ecommerce,'A'),event(ecommerce,'B')]))
        assert sorted(r.returncode==0 for r in results)==[False,True], 'Exactly one admission must succeed'
        assert any('Insufficient sellable' in r.stderr for r in results), 'Loser must fail for insufficient stock'
        assert sql("SELECT sum(quantity) FROM public.mp_commerce_reservations WHERE site_key='concurrency-052'").stdout.strip()=='1'
        winner=sql("SELECT external_order_id FROM public.mp_commerce_orders WHERE site_key='concurrency-052'").stdout.strip()
        cancel=event(ecommerce,winner);cancel.update(status='cancelled',revision=2,event_id='cancel')
        assert ingest(cancel).returncode==0
        with ThreadPoolExecutor(2) as pool:
            results=list(pool.map(ingest,[event(ecommerce,'C'),event(ecommerce,'C')]))
        assert all(r.returncode==0 for r in results), 'Duplicate retries should both return successfully'
        assert sql("SELECT count(*) FROM public.mp_commerce_events WHERE site_key='concurrency-052' AND external_order_id='C'").stdout.strip()=='1'
        assert sql("SELECT sum(quantity) FROM public.mp_commerce_reservations WHERE site_key='concurrency-052'").stdout.strip()=='1'
        print('Native two-session oversell and duplicate-delivery tests passed')
    finally:
        sql(f"DELETE FROM public.mp_commerce_payment_matches WHERE site_key='concurrency-052'; DELETE FROM public.mp_commerce_events WHERE site_key='concurrency-052'; DELETE FROM public.mp_commerce_reservations WHERE site_key='concurrency-052'; DELETE FROM public.mp_commerce_orders WHERE site_key='concurrency-052'; DELETE FROM public.ecommerce WHERE item_id={item}; DELETE FROM public.products WHERE item_id={item}; DELETE FROM public.locations WHERE nocopk={location}; DELETE FROM public.items WHERE nocopk={item}")

if __name__=='__main__':main()
