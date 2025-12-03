v1.0.2-beta

* Inoculation workflow:
  * Replace `inoculate.js` with `inoculate_multiple.js` and update the inoculation interface to support inoculating multiple target lots from a single source lot.
  * Add support for inoculation from untracked sources, including better notes/metadata on the source lot.
  * After a batch run, automatically clear `lc_volume_ml` and `target_lot_ids` on the source lot so the interface starts clean for the next inoculation.

* Dark room & event history:
  * Ensure a `FullyColonized` event exists for any lot moved to **Fridge**, **ColdShock**, or **StartFruiting`** via `dark_room_actions.js`, improving downstream event history integrity.

* Ecwid ? Airtable ecommerce integration:
  * Add initial Ecwid integration scripts to keep Ecwid product counts aligned with Airtable inventory.
  * Introduce a shared `lib/ecwid_airtable.js` module for common Ecwid/Airtable API helpers.
  * Implement sync flows to:
    * Populate `ecommerce.products` and `ecommerce.lots` link fields from `products` / `lots`.
    * Maintain an `ecommerce_orders` table mirrored from Ecwid orders.
    * Link `ecommerce_orders` records back to `ecommerce` rows using Ecwid SKUs and related fields.
  * Expand `integrations/ecwid/README.md` and `.env.example` with full configuration, schema requirements, and workflow documentation.
  * Rename sample environment files to `.env.example` in both the Ecwid integration and the print daemon.

* Schema & documentation:
  * Refresh Airtable schema exports to include `ecommerce` and `ecommerce_orders` tables and updated field definitions.
  * Update `FIELD_MAP.md` to reflect the latest schema, including ecommerce-specific fields.

v1.0.1-beta

* Applied GPL licensing
* Updates to logic for bulk sizes in spawn_to_bulk
* Add product creation script
* Add more detailed interface documentation including beginnings of NocoDB and Retool migration information.

v1.0.0-beta

* Database schema running on a production server.
* Untested method for importing schema to a new server.
* Tested automation scripts.
* Example interface screenshots.
* Install documentation.

v0.0.1-alpha

* Initial Release