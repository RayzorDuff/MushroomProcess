# Interactive Fulfillment performance correction (063)

Hosted evidence: removing per-order mp_fulfillment_progress from the order-list
query resolved its three-minute delay. That source change is in this batch workflow.
With JIT disabled locally, inventory units took 23 ms, selected-order progress
44 ms, and old search exceeded an 8-second statement timeout inside per-product
eligibility. Do not increase the browser timeout or strip mutation validation.

063 requires deployed 060 and inventory 058, not unfinished Woo migrations. It
saves seven original function definitions, replaces search with a set-based query,
computes progress once and materializes eligible inventory once per request.
It preserves both legacy assignment exclusions, allocation exclusions, optional
Woo picks, pool matching, line remaining quantities, expiry/location eligibility,
search/pagination and response fields. Assign/Dispatch still use their original
validated transactional implementations. Function-local jit=off matches the fast
hosted diagnostic; global and role settings are unchanged. A supporting allocation
index is added. No stock, identity, hold, order or movement rows are altered.

Native regression counts calls: one progress calculation and at most three inventory
calls for a search over 2,100 fixture Products. It rejects any invocation of the old
per-product search helper, checks both legacy link directions, allocated/shipped/
expired exclusion, exact search, unknown line refusal and pagination. Existing
060 mutation/replay/concurrency and 062 identity tests remain enabled. Tests run only
in disposable CI, never against production. Standalone CI covers rollback/reapply.

After this exact candidate passes native CI, pause Fulfillment operator actions,
keep the current production checkout, fetch the approved commit and export only
schema/pgsql/063_fulfillment_search_performance.sql into a private backup directory.
Save a verified pg_dump archive first, apply that SQL with psql ON_ERROR_STOP, then
check all seven saved definitions equal their applied definitions. Do not reapply
060/062 or change inventory ownership. No workflow/Appsmith import is needed for
063; retain the separate fast-list node correction until the batch JSON is imported.

Repeat the read-only selected-order/search timing test with statement_timeout=8s;
function-local settings mean no session-wide jit override is needed. Retry the UI
only after superseded requests finish or are cancelled. Stop on timeout or changed
quantities and preserve the returned error. No real Assign/Dispatch test is inferred
from a successful search. Restricted owner order/fulfillment remains acceptance.

Rollback: pause Fulfillment writes and apply
schema/pgsql/rollback/063_fulfillment_search_performance.sql. It refuses later
function drift, restores prior definitions/configuration and retains allocation/
dispatch data and the supporting index. Roll back 063 before any rollback of 060.
