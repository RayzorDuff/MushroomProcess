# Appsmith browser testing extension plan

MushroomProcess #109 is blocked on reliable real-Appsmith execution of
SignatureGate #27 (foundation PR RayzorDuff/SignatureGate#28). No MushroomProcess
browser harness or live test is installed here. The readiness JSON and
`node appsmith/commerce_test_readiness_smoke.js` check only canonical published/
unpublished page presence and explicit blockers. They do not test UI, SQL effects,
permissions or dynamic bindings. Existing production exports remain unchanged.

After that gate, use the reusable conventions in SignatureGate/e2e/README.md with
a separate mushroomprocess_e2e DB/user, independent instance marker, explicit reset
opt-in and a dedicated MushroomProcess E2E clone. Do not reset mushroomprocess_test
or a production/restored operational database. Seed synthetic Items/Strains, recipe
components, operational locations, roles, Products/Lots and order/payment identities.
Use the native commerce CI seed only in its guarded commerce_test environment;
it is not a production or browser-fixture bootstrap.

Review exact Appsmith/export/image versions and accessible names. Keep all server
networks internal, external callbacks disabled/local, and browser network requests
scoped to the test origin. Keep screenshots/traces/auth/private evidence out of Git.
Record actual backend event, lineage, location, print queue and reservation effects,
not only toast text. Browser CI is a later decision after deterministic real runs.

Ordered journeys and acceptance are in #109. Catalog mapping remains blocked on
#80's UI; the Fulfillment page does not yet expose all 052/054 ledger operations.
Preserve main's production-equivalent behavior and the production branch. Any
retirement requires explicit approval after WooCommerce cutover/deployment checks.
