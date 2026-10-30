# Commerce order admission and reservation ledger

Migration 052 is additive and intentionally does not change legacy Ecwid tables,
Clover history, physical Product/Lot lineage or the existing publisher. It supports
MushroomProcess #85 and the RootedOps #20/#3/#26 contracts. No Moov implementation.

The companion RootedOps `integrations/commerce/orders.py` verifies Woo's raw-body
HMAC and normalizes full snapshots. Only an authenticated worker may call
`mp_commerce_ingest(jsonb)`. Parameters must be bound by the driver, never SQL
interpolation. No guest endpoint or production grant is installed by this change.
The normalized envelope has schema_version=1, provider, site_key, external_order_id,
event_id, revision (UTC modified epoch), status, currency, total, lines, refunds,
payment_processor and processor_payment_id. Lines identify stable source line,
approved ecommerce row, ERP Item and positive integer quantity. Refunds identify
source refund and positive amount. Payloads exclude customer contact/card data.

A transaction-scoped global advisory lock serializes inventory admission across
all participating providers. Unique event/order/line keys make retries durable.
Old snapshots are ignored; same-second divergent snapshots stop for authoritative
refetch/manual review. Order line, total, currency and established payment-ID edits
also stop. No event receiver may invent revision numbers to resolve conflicts.

Pending, on-hold, processing and completed snapshots reserve stock. Cancelled,
failed and fully refunded orders release unfulfilled holds. Partial refunds retain
all holds pending explicit operational review. A Woo completed flag only requests
fulfillment; it never moves Products/Lots. Refunds never generate return inventory.
Reservations are conservative across the shared Item/Strain pool, including
parallel provider definitions. They can understate availability when mappings
select different lot statuses; no attempt to allocate individual packages is made.

Use `mp_commerce_inventory()` for the reservation-aware projection, joining by
ecommerce_id. The inactive manual Commercial Catalog Snapshot workflow now uses
this join and retains gross_quantity separately; it requires migration 052. **The legacy Ecwid publisher does not yet consume it.** Before shared
live sales, update every participating publisher/order ingress atomically at the
cutover gate or keep only one selling channel active. Preexisting Appsmith/manual
allocations are not backfilled by this migration. Do not represent these holds as
complete legacy allocation accounting.

The operational fulfillment worker must move the actual packages out of sellable
inventory within the same database transaction as
`mp_commerce_commit_fulfillment(provider,site,order,movement_reference)`. Only the
operational role receives this function. It records a stable reference and releases
the hold once; it cannot itself verify or perform the existing fulfillment move.
Until that integration is wired and tested, leave automatic fulfillment disabled.
Returns, partial shipment and reservation expiry are manual review, not simulated.

`mp_commerce_match_payment(jsonb)` is for a separate trusted Clover verification
adapter role, not the webhook receiver. It validates exact site/order/payment ID,
currency, captured gross total and cumulative refund total. A transaction cannot
match two orders. Authorization alone fails. It records evidence only; no invoice,
Payment Entry, fee, settlement or chargeback accounting is posted automatically.
Merchant API verification and settlement adapter remain RootedOps #26 gates.

Deployment must grant the minimal required table/sequence/select/function rights
to distinct receiver, operational and payment-verifier roles after review. New
write functions revoke PUBLIC execution; they use invoker rights, not SECURITY
DEFINER. No grants or active n8n workflow are shipped. Do not grant the receiver
direct writes to ledger tables; an eventual restricted DB service wrapper must
control function-only access (invoker functions otherwise need table privileges).
The first deployment can use a private trusted worker role pending that wrapper.

Validation: rollback-protected 052 SQL covers duplicate/stale/conflicting events,
atomic oversell refusal, cross-provider holds, cancellation release, capture
matching, completion without stock mutation and refund without restocking. The CI
PostgreSQL 16 job rebuilds without production CSVs and runs two concurrent sessions
for oversell and redelivery. RootedOps #22 remains the later staging recovery gate.
Rollback before activation: stop the new worker and revert code; new ledger tables
may remain inert. After holds exist, reconcile every outstanding order before
switching inventory publishers or dropping any table. Never discard live holds.

## Operational bridge (migration 054)

054 adds immutable per-Product shipment acknowledgments, partial quantities and
ERP site/document identities. It disables new string-only fulfillment releases.
A trusted operator must explicitly move identified Products to Shipped and call
`mp_commerce_acknowledge_products` **in the same transaction**. The function verifies
actual location and Item/Strain, prevents Product reuse, decrements only acknowledged
holds, and retains shipped history through cancellation/refunds. It never moves a
Product itself. Lot-only/bulk/non-unit quantities require manual allocation; this
Product-unit bridge must not pretend to handle them. Reservation confirmation
requires verified unrefunded Clover capture and reviewed ERP invoice/payment links.

Partial shipment snapshots subtract already acknowledged Products before rebuilding
holds; cancelling releases unshipped holds without restocking anything. Refunds
block new acknowledgments for manual review. Returns/reversal require a separately
audited operational return; no endpoint auto-creates inventory from a refund.
`mp_commerce_link_erp(jsonb)` retains source→ERP identities uniquely and refuses drift.
Only a trusted ERP verification worker may call it; names alone are not proof of
accounting or merchant capture. No grants/active workflows are installed.
