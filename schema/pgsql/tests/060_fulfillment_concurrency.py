"""Native disposable Postgres race: two orders cannot allocate one Product."""
import os
from concurrent.futures import ThreadPoolExecutor
import psycopg
if os.environ.get('PGDATABASE')!='commerce_test':raise SystemExit('Disposable commerce_test only')
with psycopg.connect('') as db:
 item=db.execute("INSERT INTO items(item_id,name,category,active) VALUES('T060-RACE','Synthetic','grain',true) RETURNING nocopk").fetchone()[0]
 loc=db.execute("INSERT INTO locations(name,active,type) VALUES('T060 Race Storage',true,'Storage') RETURNING nocopk").fetchone()[0]
 db.execute("INSERT INTO ecommerce(name,item_id,status,provider,site_key,external_sku,external_product_id,sync_enabled) VALUES('T060 race',%s,'Sterilized','ecwid','t060-race','T060-RACE','900609',true)",(item,))
 product=db.execute("INSERT INTO products(product_id,item_id,storage_location_id,use_by) VALUES('T060-RACE',%s,%s,CURRENT_DATE+1) RETURNING nocopk",(item,loc)).fetchone()[0]
 orders=[db.execute("INSERT INTO ecommerce_orders(ecwid_order_id,provider,site_key,status,items_json) VALUES(%s,'ecwid','t060-race','AWAITING_PROCESSING','[{\"id\":1,\"sku\":\"T060-RACE\",\"quantity\":1}]') RETURNING nocopk",(str(n),)).fetchone()[0] for n in [1,2]]
def assign(order):
 try:
  with psycopg.connect('') as db:
   return db.execute('SELECT mp_fulfillment_assign(%s,%s,%s)',(str(order),str(product),'synthetic@example.invalid')).fetchone()[0]['status']
 except psycopg.Error:return 'refused'
with ThreadPoolExecutor(2) as pool:results=list(pool.map(assign,orders))
assert sorted(results)==['assigned','refused'],results
with psycopg.connect('') as db:
 assert db.execute('SELECT count(*) FROM mp_fulfillment_allocations WHERE product_id=%s',(product,)).fetchone()[0]==1
 assert db.execute('SELECT storage_location_id FROM products WHERE nocopk=%s',(product,)).fetchone()[0]==loc
print('060 concurrent allocation: one winner, one refusal, no physical movement')
