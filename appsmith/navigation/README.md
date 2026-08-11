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

The navigation synchronization utility added in a later phase of issue #83
will enforce these rules before changing serialized navigation widgets.
