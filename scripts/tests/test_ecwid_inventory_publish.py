import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch
import io

spec=importlib.util.spec_from_file_location('stock',Path(__file__).resolve().parents[1]/'ecwid_inventory_publish.py')
stock=importlib.util.module_from_spec(spec);spec.loader.exec_module(stock)

class PublicationTests(unittest.TestCase):
    def test_external_text_cannot_end_sql_dollar_body(self):
        encoded=stock.literal("x'$stock$; SELECT 'synthetic'")
        self.assertNotIn('$stock$',encoded)
        self.assertNotIn('SELECT',encoded)
        self.assertIn('convert_from(decode(',encoded)

    def config(self):
        return {'ecommerce_id':1,'external_sku':'SYNTHETIC','external_product_id':'711334877','external_variation_id':None}

    def remote(self,q,enabled=False):
        return {'id':711334877,'sku':'SYNTHETIC','quantity':q,'enabled':enabled,'unlimited':False}

    def test_first_publication_uses_current_readback_and_net_not_export_five(self):
        calls=[]
        def pg(sql):
            calls.append(sql)
            if 'row_to_json' in sql:return self.config()
            if 'available_quantity' in sql:return 3
            if 'initial_plan' in sql:return {'status':'ready','token':'05800000-0000-4000-8000-000000000001','quantityDelta':-3}
            return 'applied'
        responses=[self.remote(7),self.remote(6),{'updateCount':1},self.remote(3)]
        with patch.object(stock,'run',return_value='synthetic-container'),patch.object(stock,'pg',side_effect=pg),patch.object(stock,'api',side_effect=responses) as api,patch.object(stock,'reconcile_orders') as catchup,patch('sys.argv',['stock','initialize','--confirm-paused']),patch('sys.stdout',new_callable=io.StringIO):
            stock.main()
        catchup.assert_called_once_with('synthetic-container','SYNTHETIC')
        self.assertTrue(any('initial_plan(1,6)' in c for c in calls))
        self.assertEqual(api.call_args_list[2].args[2:],('PUT',{'quantityDelta':-3}))
        self.assertTrue(any('resolve' in c for c in calls))

    def test_unknown_network_outcome_never_acknowledges_or_retries(self):
        queries=[]
        def pg(sql):
            queries.append(sql)
            if 'row_to_json' in sql:return self.config()
            if 'available_quantity' in sql:return 4
            return {'status':'ready','token':'05800000-0000-4000-8000-000000000001','quantityDelta':2}
        with patch.object(stock,'run',return_value='synthetic-container'),patch.object(stock,'pg',side_effect=pg),patch.object(stock,'api',side_effect=[self.remote(2),self.remote(2),RuntimeError('synthetic timeout')]) as api,patch.object(stock,'reconcile_orders'),patch('sys.argv',['stock','initialize','--confirm-paused']),patch('sys.stdout',new_callable=io.StringIO),self.assertRaises(RuntimeError):
            stock.main()
        self.assertEqual(api.call_count,3)
        self.assertFalse(any('resolve' in c for c in queries))

    def test_active_product_refuses_initialization(self):
        with patch.object(stock,'run',return_value='synthetic-container'),patch.object(stock,'pg',return_value=self.config()),patch.object(stock,'api',return_value=self.remote(2,True)) as api,patch('sys.argv',['stock','initialize','--confirm-paused']),patch('sys.stdout',new_callable=io.StringIO),self.assertRaises(ValueError):stock.main()
        self.assertEqual(api.call_count,1)

    def test_order_catchup_preserves_existing_private_and_line_fields(self):
        page={'total':1,'items':[{'id':'synthetic-1','status':'AWAITING_PROCESSING','payment_status':'PAID','items':[{'sku':'SYNTHETIC','quantity':1,'productId':711334877}]}]}
        with patch.object(stock,'api',return_value=page),patch.object(stock,'run',return_value='') as run,patch('sys.stdout',new_callable=io.StringIO):stock.reconcile_orders('synthetic','SYNTHETIC')
        sql=run.call_args.args[1]
        self.assertNotIn('customer_name',sql)
        self.assertNotIn('customer_email',sql)
        self.assertNotIn('INSERT INTO public.ecommerce_orders',sql)
        self.assertIn('jsonb_agg(coalesce',sql)
        self.assertIn('Current Ecwid order missing in MP',sql)

if __name__=='__main__':unittest.main()
