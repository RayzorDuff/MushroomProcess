\set ON_ERROR_STOP on

-- Opt-in runner for tests that invoke the same data-mutating functions used by
-- Appsmith. Every included test manages its own BEGIN/ROLLBACK transaction.
\if :{?allow_schema_modification}
\else
  \set allow_schema_modification false
\endif

\if :allow_schema_modification
  \echo 'Running MushroomProcess component smoke tests with rollback-protected database mutation enabled.'

  \ir 007_sterilizer_component_mode_smoke.sql
  \ir 007_sterilizer_process_type_smoke.sql
  \ir 008_aio_lifecycle_smoke.sql
  \ir 008_aio_package_smoke.sql
  \ir 008_apply_casing_parity_smoke.sql
  \ir 008_draw_syringe_labels_smoke.sql
  \ir 008_freeze_dried_package_smoke.sql
  \ir 008_inoculate_source_modes_smoke.sql
  \ir 008_package_multiple_lots_smoke.sql
  \ir 008_product_tray_actions_smoke.sql
  \ir 009_harvest_mixed_outputs_smoke.sql
  \ir 010_spawn_to_bulk_components_smoke.sql
  \ir 010_spawn_to_bulk_contract_smoke.sql
  \ir 011_print_queue_actions_smoke.sql

  \echo 'All MushroomProcess component smoke tests passed; each test rolled back its fixtures and outputs.'
\else
  \warn 'Mutation tests were not run. Re-run with -v allow_schema_modification=true.'
  \quit 3
\endif
