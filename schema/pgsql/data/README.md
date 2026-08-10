# PostgreSQL optional example data

Files in this directory are optional data fixtures for release/demo environments.
They are **not** part of the production MushroomProcess recipe catalog and are not
loaded by the normal schema migration or component-smoke-test runners.

## `000_example_recipe_seed.sql`

Creates two clearly synthetic `REC-EXAMPLE-*` recipes, their `ING-EXAMPLE-*`
ingredient masters, per-recipe vendor-source text, structured recipe ingredients,
and ordered recipe steps. Vendor names are deliberately fictional.

Run this file only when example Recipe-management data is desired. It is
idempotent and updates only its own `*-EXAMPLE-*` identifiers.
