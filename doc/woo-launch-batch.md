# Batched Woo launch promotion

This branch combines the existing Woo shipment/packing/hostname/shared-pool stack
(PRs #115, #116, #117, #119) and optional cash receipt source (#121) with current
main. Deployed 058, allocation 060 and Product ID 062 remain intact. Source merge
is separate from database migration, workflow publication and stock ownership.

## Carried-forward owner evidence, 2026-11-22

- Production source main 70b44b9; migrations 058, 060 and 062 installed.
- Existing Product IDs/UUIDs preserved after 062. 060 initially has zero allocations.
- Revised Fulfillment API/Appsmith imported; order list/detail work. Empty legacy
  product search still fails on the host and is deferred, not accepted behavior.
- n8n PostgreSQL role: `mushroomprocess_bridge`; preserve its private credential.
- Ecwid Coco quantity 2 matches MP gross 3 minus one legacy hold; no pending delta.
- Completed Ecwid cash order and Products must not be used as fixtures or replayed.
- Historical Ecwid order import is excluded by owner decision.

## Promotion sequence

Merge this combined candidate after fresh CI, then its paired RootedOps candidate.
Keep checkout restricted and Ecwid operational. Do not merge old stacks a second
time or replace the deployed application with an old raw export. Existing PR heads
are ancestors of this candidate and remain available as review history.

Use the paired RootedOps operator walkthrough for the installed database preflight,
backups, only-missing 054/055/056/057/059, and explicit grants to the confirmed n8n
role. Do not reapply installed 058, 060 or 062. Optional cash 061 is separate;
recording cash and ERP posting are not inferred from fulfillment or status.

Render the combined UI from the backed-up current export using
`scripts/prepare_cash_woo.py` with the checked-in Woo workflow/overlay; it preserves
the allocation/cash interface and adds the separate Woo section. The raw older Woo
renderer alone does not preserve the latest Fulfillment screen. Private datasource
and Header Auth bindings must be retained and only one workflow may own each route.

A restricted owner Woo purchase exercises authenticated intake, MP hold, ERP
commercial/financial references, label handoff, scanned MP dispatch, Woo completion
and stock publication. Inspect each boundary and repeat exact receipts/references
for recovery verification. No synthetic Product/stock mutation should be used on
production to imitate that sale. Public checkout follows acceptance and a staffed
ongoing queue/review procedure; one approved order is not an unattended pipeline.
Cash, refunds, split tender and payout/fees remain separate acceptance cases.

## Order-list timeout correction

The hosted list took about three minutes and exceeded Appsmith's 10-second timeout.
The revised list no longer invokes mp_fulfillment_progress for every historical
order. It retains linked/required summary counts; selected-order detail and Assign/
Dispatch retain authoritative progress and validation. No timeout increase or schema
change is required. Hosted timing must still be verified after workflow import.

The combined native full-schema job passed; standalone inventory CI exposed the
legacy short random Lot ID collision in fixture 058. Only that inventory fixture
now supplies deterministic Lot IDs with a transaction-local trigger rolled back at
test end. Production Lot IDs/generator are unchanged; that generator remains a
separate follow-up, outside the Product-ID correction already deployed.
