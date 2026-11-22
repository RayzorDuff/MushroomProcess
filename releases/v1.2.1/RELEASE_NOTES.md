# MushroomProcess v1.2.1

Release date: 2026-11-21

Standalone Ecwid shared-inventory correction. Apply only migration 058 after its installed-prerequisite check; it does not require unfinished Woo migrations 054–057. Review current stock/orders, initialize each selected existing Ecwid product with a finite-stock readback and reimport the paused Commercial Inventory Sync workflow before resuming its safe delta path.

See [operator procedure](../../doc/ecwid-inventory-correction.md). No tag for this phase patch.
