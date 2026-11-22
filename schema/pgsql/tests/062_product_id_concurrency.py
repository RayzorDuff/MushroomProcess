"""Force the same short ID suffix in two concurrent disposable inserts."""
import os
import subprocess
from concurrent.futures import ThreadPoolExecutor
if os.environ.get('PGDATABASE')!='commerce_test':raise SystemExit('Disposable commerce_test only')
def insert(index):
 ident=f'{index:08x}-0000-4000-8000-00000000c062'
 sql=f"BEGIN; INSERT INTO products(nocouuid,nc_created_at) VALUES('{ident}','2099-01-03T12:00:00') RETURNING product_id; SELECT pg_sleep(0.25); COMMIT;"
 r=subprocess.run(['psql','-XAt','-v','ON_ERROR_STOP=1','-c',sql],text=True,capture_output=True,check=True)
 return next(l for l in r.stdout.splitlines() if l.startswith('PROD-'))
with ThreadPoolExecutor(2) as pool:ids=list(pool.map(insert,[1,2]))
assert len(set(ids))==2,ids
print('062 concurrent forced suffix collision: two unique identities, no failed insert')
