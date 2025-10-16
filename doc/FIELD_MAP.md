# Field Map (maintain this file as the schema evolves)

> Update this table when fields are renamed/added to keep scripts aligned.

## lots
- status (single select): Planned | Sterilized | Inoculated | Colonizing | FullyColonized | Fridge | Spawned | Fruiting | Retired | Consumed
- action (single select): SpawnToBulk | StartFruiting | Composted | MoveToFridge | ColdShock | ApplyCasing | Shake
- strain_id (link → strains)
- item_id (link → items)
- recipe_id (link → recipes)
- remaining_volume_ml (number)
- casing_lot_id (link → lots)
- ui_error (long text)

## products
- tray_state (single select): fresh_tray | freezer_tray | empty_tray
- item_category (lookup from items.category)
- label_* (label fields for printing)

## print_queue
- source_kind (single select): lot | product
- label_type (single select): Lot_Grain | Lot_Bulk | Product_Package | ...
- print_status (single select): Queued | Printed | Error
- lot_id (link → lots)
- product_id (link → products)
