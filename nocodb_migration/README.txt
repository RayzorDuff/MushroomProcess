NocoDB & Retool Interface Bundle
Generated: 2025-11-11 17:05

This package contains:
- NocoDB creator scripts (Node.js) to create views that mirror your Airtable interfaces.
- Retool how-to text files for each interface.

Environment variables required by all NocoDB scripts:
  NOCO_BASE_URL=https://your-nocodb-instance.com
  NOCO_PROJECT=mushroom_inventory
  NOCO_TOKEN=YOUR_API_TOKEN

Run example:
  node nocodb_create_spawn_to_bulk_view.js

Notes:
- The scripts assume NocoDB v2 API endpoints under /api/v2.
- Field names and filters reflect your Airtable model; tweak as needed if your NocoDB schema differs.
