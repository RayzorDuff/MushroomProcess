# FIELD_MAP.md

This document maps all tables and their fields as defined in the current Airtable schema.

---

## ✅ `strains`

| Field           | Type      |
|-----------------|-----------|
| strain_id       | long text |
| species_strain  | long text |
| lots            | link/id   |
| regulated       | checkbox  |
| ecommerce       | link/id   |
| products          | link/id     |
---
## ✅ `recipes`

| Field              | Type          |
|--------------------|---------------|
| recipe_id          | long text     |
| name               | long text     |
| category           | single select |
| ingredients        | long text     |
| notes              | long text     |
| lots               | link/id       |
| sterilization_runs | link/id       |
| active | checkbox |
---
## ✅ `products`

| Field                     | Type          |
|---------------------------|---------------|
| product_id                | formula       |
| item_id                   | link/id       |
| name                      | lookup        |
| item_category             | lookup        |
| origin_lot_ids_json       | long text     |
| net_weight_g              | number        |
| net_weight_oz             | number        |
| net_volume_ml             | number        |
| pack_date                 | date          |
| use_by                    | date          |
| public_link               | formula       |
| package_item              | link/id       |
| name (from package_item)  | lookup        |
| package_item_category     | lookup        |
| package_size_g            | number        |
| package_count             | number        |
| storage_location          | link/id       |
| action                    | single select |
| origin_lots               | link/id       |
| label_inoc_prod           | lookup        |
| label_spawned_prod        | lookup        |
| label_proc_prod           | lookup        |
| process_type              | lookup        |
| strain_id                   | link/id         |
| species_strain            | lookup        |
| ui_error                  | long text     |
| ui_error_at               | date/time     |
| tray_state                | single select |
| origin_strain_regulated   | lookup        |
| label_company_prod        | formula       |
| label_companyaddress_prod | formula       |
| label_disclaimer_prod     | formula       |
| label_companyinfo_prod    | formula       |
| label_title_prod          | formula       |
| label_subtitle_prod       | formula       |
| label_footer_prod         | formula       |
| label_packaged_prod       | formula       |
| label_cottage_prod        | formula       |
| print_queue               | link/id       |
| unit_lbs                  | lookup        |
| unit_size                 | lookup        |
| label_useby_prod          | formula       |
| ecommerce                 | link/id       |
| ecommerce_orders          | link/id       |
| name_mat                  | single line   |
| item_category_mat         | single line   |
| events                    | link/id       |
| notes                     | long text     |
| merge_tray_products         | link/id         |
---
## ✅ `lots`

| Field                                                    | Type          |
|----------------------------------------------------------|---------------|
| lot_id                                                   | formula       |
| item_id                                                  | link/id       |
| item_name                                                | lookup        |
| recipe_id                                                | link/id       |
| recipe_name                                              | lookup        |
| strain_id                                                | link/id       |
| regulated (from strain_id)                               | lookup        |
| strain_species_strain                                    | lookup        |
| qty                                                      | number        |
| unit_size                                                | number        |
| status                                                   | single select |
| parents_json                                             | long text     |
| steri_run_id                                             | link/id       |
| process_type (from steri_run_id)                         | lookup        |
| location_id                                              | link/id       |
| operator                                                 | single select |
| created_at                                               | created time  |
| use_by                                                     | date            |
| public_link                                              | formula       |
| action                                                   | single select |
| events                                                   | link/id       |
| item_category                                            | lookup        |
| target_lot_ids                                           | link/id       |
| lc_volume_ml                                             | number        |
| grain_inputs                                             | link/id       |
| inoculated_at (from grain_inputs)                          | rollup          |
| substrate_inputs                                         | link/id       |
| output_count                                             | number        |
| fruiting_goal                                            | single select |
| flush_no                                                 | number        |
| harvest_weight_g                                         | number        |
| notes                                                    | long text     |
| syringe_count                                            | number        |
| syringe_item                                             | link/id       |
| source_type                                              | single select |
| vendor_name                                              | single select |
| vendor_batch                                             | single line   |
| received_date                                            | date          |
| total_volume_ml                                          | number        |
| ui_error                                                 | long text     |
| ui_error_at                                              | date/time     |
| remaining_volume_ml                                      | number        |
| harvest_item                                             | link/id       |
| harvest_item_category                                    | lookup        |
| products                                                 | link/id       |
| fresh_tray_count                                         | number        |
| frozen_tray_count                                        | number        |
| casing_lot_id                                            | link/id       |
| casing_applied_at                                        | date/time     |
| casing_notes                                             | long text     |
| casing_qty_used_g                                        | number        |
| label_company_lot                                        | formula       |
| unit_lbs                                                 | formula       |
| label_inoc_line                                          | formula       |
| label_spawned_line                                       | formula       |
| label_useby_line                                         | formula       |
| label_template                                           | single select |
| label_title_lot                                          | formula       |
| label_subtitle_lot                                       | formula       |
| label_footer_lot                                         | formula       |
| print_queue                                              | link/id       |
| label_graininputblocks_line                              | formula       |
| label_substrateinputblocks_line                          | formula       |
| override_inoc_time                                       | date/time     |
| inoculated_at                                            | date/time     |
| override_spawn_time                                      | date/time     |
| spawned_at                                               | date/time     |
| sterilized_at                                            | date/time     |
| label_proc_line                                          | formula       |
| public_link_dark_room                                    | formula       |
| public_link_fruiting                                     | formula       |
| public_link_harvest                                      | formula       |
| public_link_spawn_to_bulk                                | formula       |
| public_link_inoculate_flask                              | formula       |
| public_link_inoculate_grain                              | formula       |
| public_link_freeze_dry_package                           | formula       |
| public_link_substrate_package                            | formula       |
| public_link_lot_lineage                                  | formula       |
| first_event_date                                         | rollup        |
| last_event_date                                          | rollup        |
| source_lot_id                                            | link/id       |
| plate_count                                              | number        |
| plate_group_id                                           | long text     |
| parent_lot_id                                            | link/id       |
| ecommerce                                                | link/id       |
| item_name_mat                                            | single line   |
| item_category_mat                                        | single line   |
| process_type_mat                                         | single line   |
| item_name_mat (from grain_inputs)                        | lookup        |
| item_name_mat (from substrate_inputs)                    | lookup        |
| process_type_mat (from substrate_inputs)                   | lookup          |
| strain_species_strain_mat | single line |
| vendor_name_mat | single line |
| retired_at | date/time |
---
## ✅ `items`

| Field                 | Type          |
|-----------------------|---------------|
| item_id               | long text     |
| name                  | single select |
| category              | single select |
| default_unit_size_lb  | number        |
| default_unit_size_ml  | number        |
| default_unit_size_oz  | number        |
| default_unit_size_g   | number        |
| default_unit_size     | single select |
| lots                  | link/id       |
| sterilization_runs    | link/id       |
| lots 2                | link/id       |
| products              | link/id       |
| lots 4                | link/id       |
| products 2            | link/id       |
| ecommerce             | link/id       |
---
## ✅ `events`

| Field                                      | Type          |
|--------------------------------------------|---------------|
| event_id                                   | formula       |
| lot_id                                     | link/id       |
| grain_inputs (from lot_id)                 | lookup        |
| substrate_inputs (from lot_id)             | lookup        |
| vendor_name (from lc_lot_id) (from lot_id) | lookup        |
| strain_species_strain (from lot_id)        | lookup        |
| type                                       | single select |
| timestamp                                  | date/time     |
| operator                                   | long text     |
| station                                    | long text     |
| fields_json                                | long text     |
| event_time_for_rollup                      | formula       |
| lots                                       | single line   |
| product_id                                 | link/id       |
| status (from lot_id)                         | lookup          |
| storage_location (from product_id)           | lookup          |
---
## ✅ `locations`

| Field    | Type        |
|----------|-------------|
| name     | single line |
| type     | single line |
| notes    | long text   |
| lots     | link/id     |
| products | link/id     |
---
## ✅ `sterilization_runs`

| Field                                 | Type          |
|---------------------------------------|---------------|
| steri_run_id                          | formula       |
| planned_item                          | link/id       |
| default_unit_size (from planned_item) | lookup        |
| planned_item_id                       | lookup        |
| planned_item_name                     | lookup        |
| start_time                            | date/time     |
| end_time                              | date/time     |
| operator                              | single select |
| planned_recipe                        | link/id       |
| recipe_id (from planned_recipe)       | lookup        |
| name (from planned_recipe)            | lookup        |
| planned_count                         | number        |
| good_count                            | number        |
| destroyed_count                       | number        |
| planned_unit_size                     | number        |
| ui_error                              | long text     |
| ui_error_at                           | date/time     |
| process_type                          | single select |
| target_temp_c                         | number        |
| pressure_mode                         | single select |
| lots                                  | link/id       |
| override_end_time                     | date/time     |
| print_queue                           | link/id       |
---
## ✅ `print_queue`

| Field                                         | Type          |
|-----------------------------------------------|---------------|
| print_id                                      | auto number   |
| source_kind                                   | single select |
| lot_id                                        | link/id       |
| public_link (from lot_id)                     | lookup        |
| label_company_lot (from lot_id)               | lookup        |
| product_id                                    | link/id       |
| public_link (from product_id)                 | lookup        |
| label_company_prod (from product_id)          | lookup        |
| label_title_prod (from product_id)            | lookup        |
| label_subtitle_prod (from product_id)         | lookup        |
| label_footer_prod (from product_id)           | lookup        |
| print_status                                  | single select |
| label_type                                    | single select |
| error_msg                                     | long text     |
| created_at                                    | created time  |
| label_substrateinputblocks_line (from lot_id) | lookup        |
| label_graininputblocks_line (from lot_id)     | lookup        |
| label_footer_lot (from lot_id)                | lookup        |
| label_subtitle_lot (from lot_id)              | lookup        |
| label_title_lot (from lot_id)                 | lookup        |
| label_template (from lot_id)                  | lookup        |
| label_useby_line (from lot_id)                | lookup        |
| label_spawned_line (from lot_id)              | lookup        |
| label_inoc_line (from lot_id)                 | lookup        |
| label_proc_line (from lot_id)                 | lookup        |
| run_id                                        | link/id       |
| label_cottage_prod (from product_id)          | lookup        |
| label_companyinfo_prod (from product_id)      | lookup        |
| label_disclaimer_prod (from product_id)       | lookup        |
| label_companyaddress_prod (from product_id)   | lookup        |
| label_packaged_prod (from product_id)         | lookup        |
| label_useby_prod (from product_id)            | lookup        |
| label_proc_prod (from product_id)             | lookup        |
| label_spawned_prod (from product_id)          | lookup        |
| label_inoc_prod (from product_id)             | lookup        |
| item_category_mat (from lot_id) | lookup |
| item_category_mat (from product_id) | lookup |
| print_target | formula |
| claimed_by | single line |
| claimed_at | date/time |
| printed_by | single line |
| printed_at | date/time |
| pdf_path | single line |
---
## ✅ `ecommerce`

| Field                   | Type          |
|-------------------------|---------------|
| name                    | single line   |
| item_id                 | link/id       |
| strain_id               | link/id       |
| status                  | single select |
| products                | link/id       |
| lots                    | link/id       |
| ecwid_sku               | single line   |
| sync_to_ecwid           | checkbox      |
| notes                   | long text     |
| ecwid_category          | single line   |
| ecwid_price             | number        |
| ecwid_stock             | number        |
| ecwid_url               | url           |
| ecwid_image               | multipleAttachments |
| available_from_products | rollup        |
| available_from_lots     | rollup        |
| ecommerce_orders        | link/id       |
---
## ✅ `ecommerce_orders`

| Field          | Type          |
|----------------|---------------|
| name           | long text     |
| ecwid_order_id | single line   |
| order_number   | number        |
| status         | single select |
| order_date     | date/time     |
| customer_name  | single line   |
| customer_email | single line   |
| items_json     | long text     |
| products       | link/id       |
| ecommerce      | link/id       |
| ecwid_skus     | long text     |
---