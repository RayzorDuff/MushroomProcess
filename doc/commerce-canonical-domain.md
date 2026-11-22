# Woo canonical hostname

The existing Woo installation moves from shop-test.danks.store to dankmushrooms.net. Keep provider=woocommerce, site_key=danks.store and existing numeric order/line/package IDs. This workflow-only change adds the canonical transport origin; it does not change SQL migrations, reservations, actions, webhook names or the existing Ecwid workflow.

Deploy after the pack/dispatch PR (#116), using the versioned workflow import procedure. Set private MP_COMMERCE_WOO_ORIGIN=https://dankmushrooms.net only after HTTPS and the same Woo database are verified. Keep MP_COMMERCE_FULFILLMENT_ENABLED unchanged. The workflow stays inactive by default and resolves the exact current administrative URL from Woo, requiring ordinary WordPress login. Do not rewrite historical orders or construct new order identities from the hostname.

Full owner procedure: [RootedOps hostname runbook](https://github.com/RayzorDuff/RootedOps/blob/feature/commerce-canonical-domain/doc/dankmushrooms-canonical-domain.md). Ecwid public routing remains unchanged until the later cutover; danks.store becomes a deprecated frontend redirect afterward.

Verification: node n8n/tests/woo_pack_dispatch_smoke.js executes exact HTTPS host acceptance/rejection and preserves the existing Appsmith overlay behavior. Hosted link opening and workflow deployment await the owner.
