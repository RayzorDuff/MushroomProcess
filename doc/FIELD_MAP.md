# FIELD_MAP

_Generated from `production/airtable_schema/*.csv` on 2025-10-16T22:31:24.284817Z_

> Types are best-effort inferences from field names. Confirm in Airtable if critical.

## Items
- **id** — `link/id`
- **item_id** — `link/id`
- **name** — `text`
- **category** — `single select`
- **default_unit_size_lb** — `number`
- **default_unit_size_ml** — `number`
- **default_unit_size_oz** — `number`
- **default_unit_size_g** — `number`

## Recipes
- **id** — `link/id`
- **recipe_id** — `link/id`
- **name** — `text`
- **category** — `single select`
- **ingredients** — `text`
- **notes** — `long text`

## Strains
- **id** — `link/id`
- **strain_id** — `link/id`
- **species_strain** — `text`
- **regulated** — `checkbox`

## Locations
- **id** — `link/id`
- **name** — `text`
- **type** — `single select`
- **notes** — `long text`

## Sterilization Runs
- **id** — `link/id`
- **process_type** — `single select`
- **planned_item** — `text`
- **planned_recipe** — `text`
- **planned_unit_size** — `number`
- **planned_count** — `number`
- **good_count** — `number`
- **destroyed_count** — `number`
- **start_time** — `date/time`
- **end_time** — `date/time`
- **operator** — `text`
- **ui_error** — `long text`

## Lots
- **id** — `link/id`
- **lot_id** — `link/id`
- **item_id** — `link/id`
- **recipe_id** — `link/id`
- **strain_id** — `link/id`
- **unit_size** — `number`
- **status** — `single select`
- **steri_run_id** — `link/id`
- **location_id** — `link/id`
- **operator** — `text`
- **inoculated_at** — `date/time`
- **override_inoc_time** — `date/time`
- **spawned_at** — `date/time`
- **override_spawn_time** — `date/time`
- **lc_lot_id** — `link/id`
- **lc_volume_ml** — `number`
- **remaining_volume_ml** — `number`
- **grain_inputs** — `text`
- **substrate_inputs** — `text`
- **output_count** — `number`
- **casing_lot_id** — `link/id`
- **public_link** — `url`
- **ui_error** — `long text`
- **action** — `single select`

## Events
- **id** — `link/id`
- **event_id** — `link/id`
- **lot_id** — `link/id`
- **type** — `single select`
- **timestamp** — `date/time`
- **operator** — `text`
- **station** — `single select`
- **fields_json** — `json/text`

## Products
- **id** — `link/id`
- **product_id** — `link/id`
- **item_id** — `link/id`
- **source_block_id** — `link/id`
- **origin_lot_ids_json** — `json/text`
- **net_weight_g** — `number`
- **net_weight_oz** — `number`
- **pack_date** — `date/time`
- **use_by** — `text`
- **label_template_id** — `text`
- **public_link** — `url`
- **tray_state** — `single select`
- **action** — `single select`

## Print Queue
- **id** — `link/id`
- **source_kind** — `text`
- **source_record_id** — `link/id`
- **print_status** — `single select`
- **error_msg** — `long text`
