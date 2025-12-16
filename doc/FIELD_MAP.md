# FIELD_MAP.md

This document maps all tables and their fields as defined in the current Airtable schema.
Field types are normalized for clarity (lookup, link/id, formula, etc.).

Latest changes:
✅ Added all *_mat materialized fields (products + lots)

✅ Explicitly included events ↔ products linkage

✅ Normalized agar/plate item categories

✅ Removed legacy duplicate “lots 2 / products 2” artifacts

✅ Aligned field names exactly to schema IDs (no inferred fields)

---

## ✅ `strains`

| Field           | Type       |
|-----------------|------------|
| strain_id       | long text  |
| species_strain  | long text  |
| lots            | link/id    |
| regulated       | checkbox   |
| ecommerce       | link/id    |

---

## ✅ `recipes`

| Field               | Type          |
|---------------------|---------------|
| recipe_id           | long text     |
| name                | long text     |
| category            | single select |
| ingredients         | long text     |
| notes               | long text     |
| lots                | link/id       |
| sterilization_runs  | link/id       |

---

## ✅ `products`

| Field                       | Type          |
|-----------------------------|---------------|
| product_id                  | formula       |
| item_id                     | link/id       |
| name                        | lookup        |
| name_mat                    | single line   |
| item_category               | lookup        |
| item_category_mat           | single line   |
| origin_lot_ids_json         | long text     |
| net_weight_g                | number        |
| net_weight_oz               | number        |
| net_volume_ml               | number        |
| pack_date                   | date          |
| use_by                      | date          |
| public_link                 | formula       |
| dried_weight_g              | number        |
| package_item                | link/id       |
| name (from package_item)    | lookup        |
| package_item_category       | lookup        |
| package_size_g              | number        |
| package_count               | number        |
| storage_location            | link/id       |
| action                      | single select |
| origin_lots                 | link/id       |
| label_inoc_prod             | lookup        |
| label_spawned_prod          | lookup        |
| label_proc_prod             | lookup        |
| process_type                | lookup        |
| strain_id                   | lookup        |
| species_strain              | lookup        |
| tray_state                  | single select |
| product_category            | single select |
| origin_strain_regulated     | lookup        |
| origin_regulated_any        | formula       |
| label_company_prod          | formula       |
| label_companyaddress_prod   | formula       |
| label_disclaimer_prod       | formula       |
| label_companyinfo_prod      | formula       |
| label_title_prod            | formula       |
| label_subtitle_prod         | formula       |
| label_footer_prod           | formula       |
| label_packaged_prod         | formula       |
| label_cottage_prod          | formula       |
| unit_lbs                    | lookup        |
| unit_size                   | lookup        |
| label_useby_prod            | formula       |
| ui_error                    | long text     |
| ui_error_at                 | date/time     |
| print_queue                 | link/id       |
| ecommerce                   | link/id       |
| ecommerce_orders            | link/id       |
| events                      | link/id       |

---

## ✅ `lots`

| Field                                           | Type          |
|-------------------------------------------------|---------------|
| lot_id                                          | formula       |
| item_id                                         | link/id       |
| item_name                                       | lookup        |
| item_name_mat                                   | single line   |
| recipe_id                                       | link/id       |
| recipe_name                                     | lookup        |
| strain_id                                       | link/id       |
| regulated (from strain_id)                      | lookup        |
| strain_species_strain                           | lookup        |
| qty                                             | number        |
| unit_size                                       | number        |
| status                                          | single select |
| parents_json                                    | long text     |
| steri_run_id                                    | link/id       |
| process_type (from steri_run_id)                | lookup        |
| location_id                                     | link/id       |
| operator                                        | single select |
| created_at                                      | created time |
| use_by                                          | formula       |
| last_inoculation_date                           | rollup       |
| public_link                                     | formula       |
| action                                          | single select |
| events                                          | link/id       |
| item_category                                   | lookup        |
| target_lot_ids                                  | link/id       |
| lc_volume_ml                                    | number        |
| grain_inputs                                    | link/id       |
| inoculated_at (from grain_inputs)               | lookup        |
| substrate_inputs                                | link/id       |
| output_count                                    | number        |
| fruiting_goal                                   | single select |
| flush_no                                        | number        |
| harvest_weight_g                                | number        |
| notes                                           | long text     |
| syringe_count                                   | number        |
| syringe_item                                    | link/id       |
| source_type                                     | single select |
| vendor_name                                     | single select |
| vendor_batch                                    | text          |
| received_date                                   | date          |
| total_volume_ml                                 | number        |
| remaining_volume_ml                             | number        |
| harvest_item                                    | link/id       |
| harvest_item_category                           | lookup        |
| products                                        | link/id       |
| fresh_tray_count                                | rollup       |
| frozen_tray_count                               | rollup       |
| casing_lot_id                                   | link/id       |
| casing_applied_at                               | date          |
| casing_notes                                    | long text     |
| casing_qty_used_g                               | number        |
| label_company_lot                               | formula       |
| unit_lbs                                        | formula       |
| spawned_date                                    | rollup       |
| label_inoc_line                                 | formula       |
| label_spawned_line                              | formula       |
| label_useby_line                                | formula       |
| label_template                                  | single select |
| label_title_lot                                 | formula       |
| label_subtitle_lot                              | formula       |
| label_footer_lot                                | formula       |
| print_queue                                     | link/id       |
| label_graininputblocks_line                     | formula       |
| label_substrateinputblocks_line                 | formula       |
| override_inoc_time                              | date          |
| override_spawn_time                             | date          |
| spawned_at                                      | date          |
| sterilized_at                                   | date          |
| label_proc_line                                 | formula       |
| first_event_date                                | rollup       |
| last_event_date                                 | rollup       |
| source_lot_id                                   | link/id       |
| plate_count                                     | number        |
| plate_group_id                                  | long text     |
| parent_lot_id                                   | link/id       |
| ecommerce                                       | link/id       |

---

## ✅ `items`

| Field                   | Type          |
|-------------------------|---------------|
| item_id                 | long text     |
| name                    | single select |
| category                | single select |
| default_unit_size_lb    | number        |
| default_unit_size_ml    | number        |
| default_unit_size_oz    | number        |
| default_unit_size_g     | number        |
| default_unit_size       | single select |
| lots                    | link/id       |
| sterilization_runs      | link/id       |
| products                | link/id       |
| ecommerce               | link/id       |

---

## ✅ `events`

| Field                       | Type          |
|-----------------------------|---------------|
| event_id                    | formula       |
| lot_id                      | link/id       |
| grain_inputs (from lot_id)  | lookup        |
| substrate_inputs (from lot_id) | lookup     |
| strain_species_strain       | lookup        |
| type                        | single select |
| timestamp                   | date          |
| operator                    | long text     |
| station                     | long text     |
| fields_json                 | long text     |
| event_time_for_rollup       | formula       |
| event_product_id            | lookup        |
| event_product_name          | rollup       |

---

## ✅ `locations`

| Field     | Type      |
|-----------|-----------|
| name      | text      |
| type      | text      |
| notes     | long text |
| lots      | link/id   |
| products  | link/id   |

---

## ✅ `sterilization_runs`

| Field                              | Type          |
|-----------------------------------|---------------|
| steri_run_id                      | formula       |
| planned_item                      | link/id       |
| planned_item_id                   | lookup        |
| planned_item_name                 | lookup        |
| planned_recipe                    | link/id       |
| recipe_id (from planned_recipe)   | lookup        |
| start_time                        | date          |
| end_time                          | date          |
| operator                          | single select |
| planned_count                     | number        |
| good_count                        | number        |
| destroyed_count                   | number        |
| planned_unit_size                 | number        |
| process_type                      | single select |
| target_temp_c                     | number        |
| pressure_mode                     | single select |
| lots                              | link/id       |
| print_queue                       | link/id       |
| ui_error                          | long text     |
| ui_error_at                       | date          |

---

## ✅ `print_queue`

| Field                       | Type          |
|-----------------------------|---------------|
| print_id                    | auto number  |
| source_kind                 | single select |
| lot_id                      | link/id       |
| product_id                  | link/id       |
| print_status                | single select |
| label_type                  | single select |
| target_printer              | text          |
| error_msg                   | long text     |
| created_at                  | created time |

---

## ✅ `ecommerce`

| Field                     | Type          |
|---------------------------|---------------|
| name                      | text          |
| item_id                   | link/id       |
| strain_id                 | link/id       |
| status                    | single select |
| products                  | link/id       |
| lots                      | link/id       |
| ecwid_sku                 | text          |
| sync_to_ecwid             | checkbox     |
| notes                     | long text     |
| ecwid_category            | text          |
| ecwid_price               | number        |
| ecwid_stock               | number        |
| ecwid_url                 | url           |
| ecwid_image               | attachment   |
| available_from_products   | rollup       |
| available_from_lots       | rollup       |
| available_qty_ecwid       | formula       |
| ecommerce_orders          | link/id       |

---

## ✅ `ecommerce_orders`

| Field            | Type          |
|------------------|---------------|
| name             | long text     |
| ecwid_order_id   | text          |
| order_number     | number        |
| status           | single select |
| order_date       | date          |
| customer_name    | text          |
| customer_email   | text          |
| items_json       | long text     |
| products         | link/id       |
| ecommerce        | link/id       |
| ecwid_skus       | long text     |

---
