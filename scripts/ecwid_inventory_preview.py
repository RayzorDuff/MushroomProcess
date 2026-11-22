#!/usr/bin/env python3
"""Print the Git migration as a rollback-only SQL preview for psql stdin."""
from pathlib import Path
sql = (Path(__file__).resolve().parents[1] / 'schema/pgsql/058_ecwid_shared_inventory.sql').read_text()
assert sql.endswith('COMMIT;\n'), 'Review migration transaction boundary'
print(sql.removesuffix('COMMIT;\n') + 'ROLLBACK;')
