# MushroomProcess v1.2.2

Release date: 2026-11-21

Woo-only follow-up to the independent Ecwid correction. Migration 059 requires 054–058 and preserves the shared pool for pick/dispatch/retry. Explicit owner selection and guarded rollback retain existing IDs, reservations and stock receipts. No owner, checkout or workflow is activated by installation.

See [the deployment procedure](../../doc/commerce-shared-pool-cutover.md). No phase tag.

Owner update: no Ecwid order exists for the two newly packaged Products; if paid cash, none is expected. Preserve the unrelated earlier hold. Native regression proves packaging alone is unchanged and an unlinked MP cash-sale dispatch publishes one negative delta, then unchanged on replay.
