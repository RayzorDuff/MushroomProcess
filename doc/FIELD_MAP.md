# FIELD_MAP.md

This document maps all tables and their fields as defined in the schema.

---

## ✅ `blocks`

| Field             | Type         |
|------------------|--------------|
| name             | text         |
| notes            | long text    |
| bulk_mix         | link/id      |
| fruiting_tray    | link/id      |
| colonized_at     | date         |
| tray_code        | text         |
| uuid             | formula      |
| is_active        | checkbox     |
| is_colonized     | checkbox     |
| created_at       | created time |
| updated_at       | last modified time |
| ui_error         | text         |

---

## ✅ `events`

| Field             | Type         |
|------------------|--------------|
| lot              | link/id      |
| event_time       | date         |
| event_type       | single select |
| quantity         | number       |
| units            | single select |
| notes            | long text    |
| uuid             | formula      |
| is_active        | checkbox     |
| created_at       | created time |
| updated_at       | last modified time |

---

## ✅ `items`

| Field             | Type         |
|------------------|--------------|
| name             | text         |
| category         | single select |
| is_active        | checkbox     |
| uuid             | formula      |
| created_at       | created time |
| updated_at       | last modified time |

---

## ✅ `lots`

| Field                  | Type         |
|------------------------|--------------|
| item                  | link/id      |
| item_category         | lookup       |
| quantity              | number       |
| units                 | single select |
| recipe                | link/id      |
| parent_lot            | link/id      |
| grain_links           | link/id      |
| notes                 | long text    |
| uuid                  | formula      |
| is_active             | checkbox     |
| inoculated_at         | date         |
| received_at           | date         |
| drawn_at              | date         |
| source_plate          | link/id      |
| source_flask          | link/id      |
| stage_lot             | link/id      |
| stage_block           | link/id      |
| tray_code             | text         |
| stage_tray            | link/id      |
| destination_block     | link/id      |
| destination_lot       | link/id      |
| used_in               | link/id      |
| override_inoc_time    | checkbox     |
| override_quantity     | number       |
| inoculated_by         | user         |
| ui_error              | text         |
| created_at            | created time |
| updated_at            | last modified time |

---

## ✅ `print_queue`

| Field             | Type         |
|------------------|--------------|
| lot              | link/id      |
| label_type       | single select |
| was_printed      | checkbox     |
| print_error      | text         |
| created_at       | created time |
| updated_at       | last modified time |

---

## ✅ `recipes`

| Field             | Type         |
|------------------|--------------|
| name             | text         |
| category         | single select |
| description      | long text    |
| uuid             | formula      |
| is_active        | checkbox     |
| created_at       | created time |
| updated_at       | last modified time |

---

## ✅ `settings`

| Field             | Type         |
|------------------|--------------|
| name             | text         |
| value            | text         |
| uuid             | formula      |
| created_at       | created time |
| updated_at       | last modified time |

---

## ✅ `tray_products`

| Field             | Type         |
|------------------|--------------|
| name             | text         |
| tray             | link/id      |
| product_lot      | link/id      |
| uuid             | formula      |
| is_active        | checkbox     |
| created_at       | created time |
| updated_at       | last modified time |

---
