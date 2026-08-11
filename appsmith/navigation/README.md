# Appsmith Navigation

`navigation_manifest.json` is the canonical Git-managed definition of the
MushroomProcess application navigation introduced by issue #83.

The manifest stores user-visible navigation labels separately from the actual
Appsmith page names and static slugs. Existing page names and slugs are part of
the navigation contract and must not be renamed merely to shorten a menu label.

## Presentation rule

Presentation is derived from the number of enabled items in each group rather
than stored independently in each page copy:

- zero enabled items: do not render the group;
- one enabled item: render the group as a direct navigation button;
- two or more enabled items: render the group as a dropdown/menu button.

This allows, for example, `Reporting` to remain a direct button until the QR
Scan Analytics page from issue #81 is implemented and enabled.

## Enabled destinations

Every enabled item must have both `page` and `slug` values. They must match the
existing Appsmith page name and static slug in both the published and
unpublished definitions in `../MushroomProcess.json`.

Disabled future destinations may use `null` for `page` and `slug` until their
Appsmith pages exist. The related GitHub issue is retained in the `issue` field
so the intended group and order can be recorded without exposing broken
navigation.

## Synchronization

Run the repository synchronization utility after changing the manifest:

```bash
node scripts/sync_navigation.js
```

Use check mode when validating a proposed commit or export without modifying it:

```bash
node scripts/sync_navigation.js --check
```

The utility validates enabled target page names and slugs against both Appsmith
page states, then updates the logical contents of every existing
`navMainNavigation`. It does not create missing widgets or change their
page-specific IDs, keys, coordinates, or surrounding workflow layout. A page
definition with zero or multiple matching navigation widgets is a validation
error.

`--dry-run` reports which published/unpublished page definitions would change
without writing `MushroomProcess.json`.
