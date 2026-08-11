#!/usr/bin/env node
"use strict";

/**
 * Synchronize MushroomProcess Appsmith navigation widgets from the canonical
 * appsmith/navigation/navigation_manifest.json definition.
 *
 * The script intentionally owns only the logical navigation definition inside
 * existing navMainNavigation widgets. It does not create widgets, move layout
 * elements, change widget IDs/keys, or modify unrelated page content.
 */

const fs = require("fs");
const path = require("path");
const { isDeepStrictEqual } = require("util");

const DEFAULT_APPSMITH = "appsmith/MushroomProcess.json";
const DEFAULT_MANIFEST = "appsmith/navigation/navigation_manifest.json";
const NAV_WIDGET_NAME = "navMainNavigation";
const NAV_WIDGET_TYPE = "BUTTON_GROUP_WIDGET";

function usage(exitCode = 0) {
  const text = `
Usage:
  node scripts/sync_navigation.js [options]

Options:
  --check               Validate and exit non-zero if navigation is out of sync.
  --dry-run             Validate and report changes without writing the Appsmith file.
  --appsmith <path>     Appsmith export path (default: ${DEFAULT_APPSMITH}).
  --manifest <path>     Navigation manifest path (default: ${DEFAULT_MANIFEST}).
  -h, --help            Show this help.

Default behavior validates both files and writes only when one or more existing
${NAV_WIDGET_NAME} widgets differ from the manifest-generated logical definition.
`;
  const stream = exitCode === 0 ? process.stdout : process.stderr;
  stream.write(text.trim() + "\n");
  process.exit(exitCode);
}

function parseArgs(argv) {
  const args = {
    mode: "write",
    appsmithPath: DEFAULT_APPSMITH,
    manifestPath: DEFAULT_MANIFEST,
  };

  for (let i = 2; i < argv.length; i++) {
    const arg = argv[i];

    if (arg === "--check") {
      if (args.mode !== "write") {
        throw new Error("Use only one of --check or --dry-run.");
      }
      args.mode = "check";
    } else if (arg === "--dry-run") {
      if (args.mode !== "write") {
        throw new Error("Use only one of --check or --dry-run.");
      }
      args.mode = "dry-run";
    } else if (arg === "--appsmith") {
      args.appsmithPath = requireValue(argv, ++i, "--appsmith");
    } else if (arg === "--manifest") {
      args.manifestPath = requireValue(argv, ++i, "--manifest");
    } else if (arg === "-h" || arg === "--help") {
      usage(0);
    } else {
      throw new Error(`Unknown argument: ${arg}`);
    }
  }

  return args;
}

function requireValue(argv, index, optionName) {
  const value = argv[index];
  if (!value || value.startsWith("--")) {
    throw new Error(`${optionName} requires a path.`);
  }
  return value;
}

function readJson(filePath, label) {
  let raw;
  try {
    raw = fs.readFileSync(filePath, "utf8");
  } catch (error) {
    throw new Error(`Unable to read ${label} "${filePath}": ${error.message}`);
  }

  try {
    return { raw, value: JSON.parse(raw) };
  } catch (error) {
    throw new Error(`Unable to parse ${label} "${filePath}": ${error.message}`);
  }
}

function isNonEmptyString(value) {
  return typeof value === "string" && value.trim().length > 0;
}

function isFiniteNumber(value) {
  return typeof value === "number" && Number.isFinite(value);
}

function validateManifest(manifest) {
  const errors = [];

  if (!manifest || typeof manifest !== "object" || Array.isArray(manifest)) {
    throw new Error("Navigation manifest must be a JSON object.");
  }

  if (manifest.schemaVersion !== 1) {
    errors.push(`schemaVersion must be 1; found ${JSON.stringify(manifest.schemaVersion)}.`);
  }

  if (!Array.isArray(manifest.groups)) {
    errors.push("groups must be an array.");
  }

  if (errors.length) {
    throwValidationErrors("Navigation manifest validation failed", errors);
  }

  const groupKeys = new Set();
  const groupOrders = new Set();
  const enabledPages = new Set();
  const enabledSlugs = new Set();
  const normalizedGroups = [];

  manifest.groups.forEach((group, groupIndex) => {
    const prefix = `groups[${groupIndex}]`;

    if (!group || typeof group !== "object" || Array.isArray(group)) {
      errors.push(`${prefix} must be an object.`);
      return;
    }

    if (!isNonEmptyString(group.key)) {
      errors.push(`${prefix}.key must be a non-empty string.`);
    } else if (groupKeys.has(group.key)) {
      errors.push(`${prefix}.key duplicates group key ${JSON.stringify(group.key)}.`);
    } else {
      groupKeys.add(group.key);
    }

    if (!isNonEmptyString(group.label)) {
      errors.push(`${prefix}.label must be a non-empty string.`);
    }

    if (!isFiniteNumber(group.order)) {
      errors.push(`${prefix}.order must be a finite number.`);
    } else if (groupOrders.has(group.order)) {
      errors.push(`${prefix}.order duplicates group order ${group.order}.`);
    } else {
      groupOrders.add(group.order);
    }

    if (!Array.isArray(group.items)) {
      errors.push(`${prefix}.items must be an array.`);
      return;
    }

    const itemOrders = new Set();
    const normalizedItems = [];

    group.items.forEach((item, itemIndex) => {
      const itemPrefix = `${prefix}.items[${itemIndex}]`;

      if (!item || typeof item !== "object" || Array.isArray(item)) {
        errors.push(`${itemPrefix} must be an object.`);
        return;
      }

      if (!isNonEmptyString(item.label)) {
        errors.push(`${itemPrefix}.label must be a non-empty string.`);
      }

      if (!isFiniteNumber(item.order)) {
        errors.push(`${itemPrefix}.order must be a finite number.`);
      } else if (itemOrders.has(item.order)) {
        errors.push(`${itemPrefix}.order duplicates item order ${item.order} within ${group.key || prefix}.`);
      } else {
        itemOrders.add(item.order);
      }

      if (typeof item.enabled !== "boolean") {
        errors.push(`${itemPrefix}.enabled must be true or false.`);
      }

      if (item.enabled === true) {
        if (!isNonEmptyString(item.page)) {
          errors.push(`${itemPrefix}.page must be a non-empty string when enabled.`);
        } else if (enabledPages.has(item.page)) {
          errors.push(`${itemPrefix}.page duplicates enabled page ${JSON.stringify(item.page)}.`);
        } else {
          enabledPages.add(item.page);
        }

        if (!isNonEmptyString(item.slug)) {
          errors.push(`${itemPrefix}.slug must be a non-empty string when enabled.`);
        } else if (enabledSlugs.has(item.slug)) {
          errors.push(`${itemPrefix}.slug duplicates enabled slug ${JSON.stringify(item.slug)}.`);
        } else {
          enabledSlugs.add(item.slug);
        }
      } else if (item.enabled === false) {
        if (item.page !== null && item.page !== undefined && !isNonEmptyString(item.page)) {
          errors.push(`${itemPrefix}.page must be null/omitted or a non-empty string when disabled.`);
        }
        if (item.slug !== null && item.slug !== undefined && !isNonEmptyString(item.slug)) {
          errors.push(`${itemPrefix}.slug must be null/omitted or a non-empty string when disabled.`);
        }
      }

      normalizedItems.push({
        label: item.label,
        page: item.page,
        slug: item.slug,
        order: item.order,
        enabled: item.enabled,
      });
    });

    normalizedGroups.push({
      key: group.key,
      label: group.label,
      order: group.order,
      items: normalizedItems,
    });
  });

  if (errors.length) {
    throwValidationErrors("Navigation manifest validation failed", errors);
  }

  normalizedGroups.sort((a, b) => a.order - b.order);
  for (const group of normalizedGroups) {
    group.items.sort((a, b) => a.order - b.order);
    group.enabledItems = group.items.filter((item) => item.enabled);
  }

  return normalizedGroups;
}

function validateAppsmithTargets(appsmith, groups) {
  const errors = [];

  if (!appsmith || typeof appsmith !== "object" || Array.isArray(appsmith)) {
    throw new Error("Appsmith export must be a JSON object.");
  }

  if (!Array.isArray(appsmith.pageList)) {
    throw new Error("Appsmith export pageList must be an array.");
  }

  const pageEntriesByUnpublishedName = new Map();

  appsmith.pageList.forEach((entry, index) => {
    const unpublished = entry && entry.unpublishedPage;
    const published = entry && entry.publishedPage;

    if (!unpublished || !published) {
      errors.push(`pageList[${index}] must contain both unpublishedPage and publishedPage.`);
      return;
    }

    if (!isNonEmptyString(unpublished.name)) {
      errors.push(`pageList[${index}].unpublishedPage.name must be a non-empty string.`);
      return;
    }

    if (pageEntriesByUnpublishedName.has(unpublished.name)) {
      errors.push(`Duplicate unpublished Appsmith page name ${JSON.stringify(unpublished.name)}.`);
      return;
    }

    pageEntriesByUnpublishedName.set(unpublished.name, entry);
  });

  for (const group of groups) {
    for (const item of group.enabledItems) {
      const entry = pageEntriesByUnpublishedName.get(item.page);
      if (!entry) {
        errors.push(`Enabled destination ${JSON.stringify(item.label)} targets missing Appsmith page ${JSON.stringify(item.page)}.`);
        continue;
      }

      for (const stateName of ["unpublishedPage", "publishedPage"]) {
        const state = entry[stateName];
        if (state.name !== item.page) {
          errors.push(`${item.page}/${stateName} name is ${JSON.stringify(state.name)}, expected ${JSON.stringify(item.page)}.`);
        }
        if (state.slug !== item.slug) {
          errors.push(`${item.page}/${stateName} slug is ${JSON.stringify(state.slug)}, expected ${JSON.stringify(item.slug)}.`);
        }
      }
    }
  }

  if (errors.length) {
    throwValidationErrors("Appsmith navigation target validation failed", errors);
  }
}

function throwValidationErrors(title, errors) {
  const lines = errors.map((error) => `  - ${error}`);
  throw new Error(`${title}:\n${lines.join("\n")}`);
}

function collectNamedWidgets(node, widgetName, matches) {
  if (!node || typeof node !== "object") {
    return;
  }

  if (node.widgetName === widgetName) {
    matches.push(node);
  }

  if (Array.isArray(node.children)) {
    for (const child of node.children) {
      collectNamedWidgets(child, widgetName, matches);
    }
  }
}

function findNavigationWidget(pageState, pageName, stateName) {
  const matches = [];
  const layouts = pageState && pageState.layouts;

  if (!Array.isArray(layouts) || layouts.length === 0) {
    throw new Error(`${pageName}/${stateName} has no layouts to search for ${NAV_WIDGET_NAME}.`);
  }

  for (const layout of layouts) {
    if (layout && layout.dsl) {
      collectNamedWidgets(layout.dsl, NAV_WIDGET_NAME, matches);
    }
  }

  if (matches.length !== 1) {
    throw new Error(`${pageName}/${stateName} must contain exactly one ${NAV_WIDGET_NAME}; found ${matches.length}.`);
  }

  const widget = matches[0];
  if (widget.type !== NAV_WIDGET_TYPE) {
    throw new Error(`${pageName}/${stateName} ${NAV_WIDGET_NAME} has type ${JSON.stringify(widget.type)}, expected ${NAV_WIDGET_TYPE}.`);
  }

  if (!isNonEmptyString(widget.widgetId) || !isNonEmptyString(widget.key)) {
    throw new Error(`${pageName}/${stateName} ${NAV_WIDGET_NAME} must retain non-empty widgetId and key values.`);
  }

  return widget;
}

function buildNavigationDefinition(groups) {
  const visibleGroups = groups.filter((group) => group.enabledItems.length > 0);
  const groupButtons = {};
  const dynamicBindingPathList = [{ key: "borderRadius" }];
  const dynamicPropertyPathList = [];
  const dynamicTriggerPathList = [];

  visibleGroups.forEach((group, groupIndex) => {
    const groupId = `groupButton${groupIndex + 1}`;
    const slugs = group.enabledItems.map((item) => item.slug);
    const isDirect = group.enabledItems.length === 1;
    const menuItems = {};

    const groupButton = {
      buttonColor: activeColorExpression(slugs),
      buttonType: isDirect ? "SIMPLE" : "MENU",
      disabledWhenInvalid: false,
      id: groupId,
      index: groupIndex,
      isDisabled: false,
      isVisible: true,
      label: group.label,
      menuItems,
      placement: "CENTER",
      widgetId: "",
    };

    dynamicBindingPathList.push({ key: `groupButtons.${groupId}.buttonColor` });

    if (isDirect) {
      const item = group.enabledItems[0];
      const key = `groupButtons.${groupId}.onClick`;
      groupButton.onClick = navigationExpression(item.page);
      addDynamicHandlerKey(key, dynamicBindingPathList, dynamicPropertyPathList, dynamicTriggerPathList);
    } else {
      group.enabledItems.forEach((item, itemIndex) => {
        const menuId = `menuItem${itemIndex + 1}`;
        const key = `groupButtons.${groupId}.menuItems.${menuId}.onClick`;

        menuItems[menuId] = {
          backgroundColor: "#FFFFFF",
          disabledWhenInvalid: false,
          id: menuId,
          index: itemIndex,
          isDisabled: false,
          isVisible: true,
          label: item.label,
          onClick: navigationExpression(item.page),
          widgetId: "",
        };

        addDynamicHandlerKey(key, dynamicBindingPathList, dynamicPropertyPathList, dynamicTriggerPathList);
      });
    }

    groupButtons[groupId] = groupButton;
  });

  return {
    groupButtons,
    dynamicBindingPathList,
    dynamicPropertyPathList,
    dynamicTriggerPathList,
    visibleGroupCount: visibleGroups.length,
    enabledDestinationCount: visibleGroups.reduce((count, group) => count + group.enabledItems.length, 0),
  };
}

function addDynamicHandlerKey(key, binding, property, trigger) {
  binding.push({ key });
  property.push({ key });
  trigger.push({ key });
}

function activeColorExpression(slugs) {
  return `{{ ${JSON.stringify(slugs)}.some(slug => String(appsmith.URL?.pathname || '').includes('/' + slug)) ? appsmith.theme.colors.primaryColor : '#64748B' }}`;
}

function navigationExpression(pageName) {
  return `{{navigateTo(${JSON.stringify(pageName)}, {}, 'SAME_WINDOW')}}`;
}

function logicalSnapshot(widget) {
  return {
    groupButtons: widget.groupButtons,
    dynamicBindingPathList: widget.dynamicBindingPathList,
    dynamicPropertyPathList: widget.dynamicPropertyPathList,
    dynamicTriggerPathList: widget.dynamicTriggerPathList,
  };
}

function applyDefinition(widget, definition) {
  widget.groupButtons = definition.groupButtons;
  widget.dynamicBindingPathList = definition.dynamicBindingPathList;
  widget.dynamicPropertyPathList = definition.dynamicPropertyPathList;
  widget.dynamicTriggerPathList = definition.dynamicTriggerPathList;
}

function synchronize(appsmith, definition) {
  const changed = [];
  let definitionCount = 0;

  for (const entry of appsmith.pageList) {
    const pageName = entry.unpublishedPage.name;
    const widgets = {};

    for (const stateName of ["unpublishedPage", "publishedPage"]) {
      const widget = findNavigationWidget(entry[stateName], pageName, stateName);
      widgets[stateName] = widget;
      definitionCount += 1;
    }

    if (widgets.unpublishedPage.widgetId !== widgets.publishedPage.widgetId) {
      throw new Error(`${pageName}: ${NAV_WIDGET_NAME} widgetId differs between unpublished and published definitions.`);
    }
    if (widgets.unpublishedPage.key !== widgets.publishedPage.key) {
      throw new Error(`${pageName}: ${NAV_WIDGET_NAME} key differs between unpublished and published definitions.`);
    }

    const expected = logicalSnapshot(definition);

    for (const stateName of ["unpublishedPage", "publishedPage"]) {
      const widget = widgets[stateName];
      const before = logicalSnapshot(widget);

      if (!isDeepStrictEqual(before, expected)) {
        applyDefinition(widget, definition);
        changed.push(`${pageName}/${stateName}`);
      }
    }
  }

  return { changed, definitionCount };
}

function serializeLikeSource(value, sourceText) {
  const lineEnding = sourceText.includes("\r\n") ? "\r\n" : "\n";
  const hadTrailingNewline = sourceText.endsWith("\n");
  let output = JSON.stringify(value, null, 2);

  if (lineEnding === "\r\n") {
    output = output.replace(/\n/g, "\r\n");
  }

  if (hadTrailingNewline) {
    output += lineEnding;
  }

  return output;
}

function relativeForMessage(filePath) {
  const relative = path.relative(process.cwd(), path.resolve(filePath));
  return relative && !relative.startsWith("..") ? relative : filePath;
}

function main() {
  const args = parseArgs(process.argv);
  const manifestDoc = readJson(args.manifestPath, "navigation manifest");
  const appsmithDoc = readJson(args.appsmithPath, "Appsmith export");

  const groups = validateManifest(manifestDoc.value);
  validateAppsmithTargets(appsmithDoc.value, groups);

  const definition = buildNavigationDefinition(groups);
  const result = synchronize(appsmithDoc.value, definition);
  const output = serializeLikeSource(appsmithDoc.value, appsmithDoc.raw);
  const fileChanged = output !== appsmithDoc.raw;

  if (result.changed.length === 0 && fileChanged) {
    throw new Error("Navigation widgets are logically synchronized, but serializing the Appsmith export would change unrelated JSON formatting or values. Normalize the export before running this script.");
  }

  const summary = `${appsmithDoc.value.pageList.length} pages, ${result.definitionCount} page definitions, ${definition.visibleGroupCount} visible groups, ${definition.enabledDestinationCount} enabled destinations`;
  const target = relativeForMessage(args.appsmithPath);

  if (args.mode === "check") {
    if (result.changed.length > 0) {
      console.error(`Navigation check failed: ${result.changed.length} ${NAV_WIDGET_NAME} definition(s) differ from the manifest.`);
      for (const name of result.changed) {
        console.error(`  - ${name}`);
      }
      console.error("Run without --check to synchronize the selected Appsmith export.");
      process.exitCode = 1;
      return;
    }

    console.log(`Navigation check passed: ${summary}.`);
    return;
  }

  if (args.mode === "dry-run") {
    if (result.changed.length === 0) {
      console.log(`Navigation dry run: no changes required (${summary}).`);
    } else {
      console.log(`Navigation dry run: would update ${result.changed.length} definition(s) in ${target} (${summary}).`);
      for (const name of result.changed) {
        console.log(`  - ${name}`);
      }
    }
    return;
  }

  if (result.changed.length === 0) {
    console.log(`Navigation already synchronized: ${summary}.`);
    return;
  }

  fs.writeFileSync(args.appsmithPath, output, "utf8");
  console.log(`Updated ${result.changed.length} navigation definition(s) in ${target} (${summary}).`);
}

try {
  main();
} catch (error) {
  console.error(error && error.stack ? error.stack : String(error));
  process.exit(1);
}
