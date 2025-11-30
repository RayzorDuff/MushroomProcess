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