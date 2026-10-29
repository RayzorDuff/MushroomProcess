"""Provider-neutral snapshot validator. No production or ERP writes."""

def validate_snapshot(rows):
    seen = set()
    errors = []
    for row in rows:
        identity = (row["provider"], row["site_key"], str(row["ecommerce_id"]))
        if identity in seen:
            errors.append({"identity": identity, "error": "Duplicate mapping"})
        seen.add(identity)
        if not str(row.get("erp_item_code") or "").strip():
            errors.append({"identity": identity, "error": "Missing reviewed ERP Item link"})
        quantity = row.get("desired_quantity")
        if isinstance(quantity, bool) or not isinstance(quantity, int) or quantity < 0:
            errors.append({"identity": identity, "error": "Invalid operational quantity"})
    return errors
