Specifications for create_nocodb_relations_and_rollups.js

1. NocoDB V3 API helper functions

GET/POST/PATCH/DELETE wrappers

Automatic retry for meta propagation delays

2. Schema ingestion & field mapping

Parses Airtable _schema.json

Identifies link fields, rollups, formulas, lookups

3. Column replacement logic

Detects placeholder LongText fields

Deletes them before creating LTARs

Ensures fresh creation succeeds 100%

4. V3-compliant LTAR creation

5. Formula translation engine

Rewrites Airtable formulas → Poco formulas

Maps:

DATETIME_FORMAT() → supported formats

RECORD_ID() → {id}

& concatenation → ||

BLANK() → ""

SWITCH() → nested IF()

TRUE() → true, FALSE() → false

6. Rollup translation engine

7. Logging + safety

Logs all successes

Logs failures with full response bodies

No silent fallback to LongText except for formulas you explicitly approved

8.  V2 and V3 compatibility

Version selection & meta prefix

New env var NOCODB_API_VERSION → IS_V2 / IS_V3.

New META_PREFIX:

v2: /api/v2/meta
v3: /api/v3/meta

META_TABLES, META_TABLE_FIELDS(tableId), and META_FIELD(fieldId) now depend on version:

v3

List tables: /api/v3/meta/bases/{baseId}/tables
Create field: /api/v3/meta/bases/{baseId}/tables/{tableId}/fields
Delete field: /api/v3/meta/bases/{baseId}/fields/{fieldId} 
openapi_V3

v2

List tables: /api/v2/meta/bases/{baseId}/tables
Create column: /api/v2/meta/tables/{tableId}/columns
Delete column: /api/v2/meta/columns/{columnId} 
openapi_V2

TODO:

1. Lookups and Rollups sections are scaffolded but not yet implemented

This script creates relations and formulas correctly.

Still remains to be implemented:

Lookup creation
Rollup creation
chained lookup resolution
chained rollup resolution

2. This script will not create relation → lookup → rollup chains in one pass

NocoDB V3 must stabilize LTAR metadata first.