/**
 * Script: populate_ecommerce_products_lots.js
 * Version: 2025-11-24.1
 * =============================================================================
 *  Copyright © 2025 Dank Mushrooms, LLC
 *  Licensed under the GNU General Public License v3 (GPL-3.0-only)
 *
 *  This program is free software: you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation, either version 3 of the License.
 *
 *  This program is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 *  GNU General Public License for more details.
 *
 *  You should have received a copy of the GNU General Public License
 *  along with this program. If not, see <https://www.gnu.org/licenses/>.
 * =============================================================================
 * Summary: Populate ecommerce.products and ecommerce.lots
 * Notes: 
 * For ecommerce.products:
 *  - products.item_id == ecommerce.item_id
 *  - AND if ecommerce.strain_id is set, products.strain_id == ecommerce.strain_id
 *  - AND products.use_by, if set, is NOT expired (use_by >= today)
 *  - AND products.storage_location != "Shipped"
 *
 * For ecommerce.lots:
 *  - lots.item_id == ecommerce.item_id
 *  - AND if ecommerce.strain_id is set, lots.strain_id == ecommerce.strain_id
 *  - AND lots.use_by, if set, is NOT expired (use_by >= today)
 *  - AND lots.status NOT IN ("Planned", "Consumed", "Retired")
 *
 * Trigger: When record created/updated in ecommerce
 * Input variable: recordId (from trigger)
 */

const { ecommerceRecordId } = input.config();

// ---------- Table & field names (change if needed) ----------

let ecommerceTable = base.getTable('ecommerce');
let productsTable = base.getTable('products');
let lotsTable = base.getTable('lots');

// ecommerce fields
let ECOM_ITEM_FIELD    = 'item_id';    // link to items
let ECOM_STRAIN_FIELD  = 'strain_id';  // link to strains (optional)
let ECOM_PRODUCTS_FIELD = 'products';  // link to products
let ECOM_LOTS_FIELD     = 'lots';      // link to lots
let ECOM_STATUS_FIELD     = 'status';      // link to lots

// products fields
let PROD_ITEM_FIELD      = 'item_id';          // link to items
let PROD_STRAIN_FIELD    = 'strain_id';        // link to strains
let PROD_USE_BY_FIELD    = 'use_by';           // date
let PROD_STORAGE_FIELD   = 'storage_location'; // single select (includes "Shipped")

// lots fields
let LOT_ITEM_FIELD       = 'item_id';   // link to items
let LOT_STRAIN_FIELD     = 'strain_id'; // link to strains
let LOT_USE_BY_FIELD     = 'use_by';    // date (if you use a different name, change here)
let LOT_STATUS_FIELD     = 'status';    // single select with "Planned", "Consumed", "Retired"

// Map ecommerce.status -> allowed lots.status values
const LOT_STATUS_MAP = {
  Sterilized:     ['Sterilized', 'Sealed'],
  Pasteurized:    ['Pasteurized'],
  FullyColonized: ['FullyColonized', 'Fridge', 'ColdShock'],
  Inoculated:     ['Inoculated', 'Colonizing'],
};

// ---------- Load ecommerce record ----------

let ecommerceRecord = await ecommerceTable.selectRecordAsync(ecommerceRecordId);
if (!ecommerceRecord) {
  output.set('error', `No ecommerce record found for ID ${ecommerceRecordId}`);
  return;
}

// Get ecommerce.status (required for including any lots)
let ecommerceStatusCell = ecommerceRecord.getCellValue(ECOM_STATUS_FIELD);
let ecommerceStatusName = ecommerceStatusCell && ecommerceStatusCell.name ? ecommerceStatusCell.name : null;

// Determine which lot statuses are allowed for this ecommerce status
let allowedLotStatuses = ecommerceStatusName
  ? LOT_STATUS_MAP[ecommerceStatusName] || []
  : [];

// If no ecommerce.status or unknown status, we won't include any lots

// Get linked item + strain from ecommerce
let ecommerceItemLinks   = ecommerceRecord.getCellValue(ECOM_ITEM_FIELD)   || [];
let ecommerceStrainLinks = ecommerceRecord.getCellValue(ECOM_STRAIN_FIELD) || [];

if (ecommerceItemLinks.length === 0) {
  // No item_id set; clear links and exit
  await ecommerceTable.updateRecordAsync(ecommerceRecordId, {
    [ECOM_PRODUCTS_FIELD]: [],
    [ECOM_LOTS_FIELD]: [],
  });
  output.set('error', 'No item_id on ecommerce record; cleared products & lots links.');
  return;
}

let ecommerceItemId  = ecommerceItemLinks[0].id;
let ecommerceStrainId = ecommerceStrainLinks.length > 0 ? ecommerceStrainLinks[0].id : null;

// Compute "today at midnight" for not-expired comparisons
let now = new Date();
let todayMidnight = new Date(now.getFullYear(), now.getMonth(), now.getDate());

// Helper: "not expired" => include if no date, OR use_by >= todayMidnight
function isNotExpired(useByValue) {
  if (!useByValue) {
    // No use_by set -> do NOT exclude
    return true;
  }
  let useByDate = new Date(useByValue);
  return useByDate >= todayMidnight;
}

// ---------- Fetch products ----------

let productsQuery = await productsTable.selectRecordsAsync({
  fields: [PROD_ITEM_FIELD, PROD_STRAIN_FIELD, PROD_USE_BY_FIELD, PROD_STORAGE_FIELD],
});

// Check if a products record matches ecommerce conditions
function productMatches(record) {
  // 1) item_id must match
  let prodItemLinks = record.getCellValue(PROD_ITEM_FIELD) || [];
  let matchesItem = prodItemLinks.some(link => link.id === ecommerceItemId);
  if (!matchesItem) return false;

  // 2) strain logic:
  //    - if ecommerce.strain_id is set: product.strain_id must match
  //    - if ecommerce.strain_id is EMPTY: product.strain_id must also be EMPTY
  let prodStrainLinks = record.getCellValue(PROD_STRAIN_FIELD) || [];
  if (ecommerceStrainId) {
    // require at least one matching strain link
    let matchesStrain = prodStrainLinks.some(link => link.id === ecommerceStrainId);
    if (!matchesStrain) return false;
  } else {
    // ecommerce has no strain; only match products with NO strain
    if (prodStrainLinks.length > 0) return false;
  }

  // 3) use_by not expired (or empty)
  let useBy = record.getCellValue(PROD_USE_BY_FIELD);
  if (!isNotExpired(useBy)) {
    return false;
  }

  // 4) storage_location != "Shipped"
  // storage_location is a link to locations (single link)
  // e.g. [{ id: 'rec...', name: 'Shipped' }]
  let storageLinks = prod.getCellValue(PROD_STORAGE_FIELD) || [];
  let isShipped = storageLinks.some(
    (link) => (link.name || '').trim() === 'Shipped'
  );
  if (isShipped) return false;  

  return true;
}

// ---------- Fetch lots ----------

let lotsQuery = await lotsTable.selectRecordsAsync({
  fields: [LOT_ITEM_FIELD, LOT_STRAIN_FIELD, LOT_USE_BY_FIELD, LOT_STATUS_FIELD],
});

// Check if a lots record matches ecommerce conditions
function lotMatches(record) {
  // 1) item_id must match
  let lotItemLinks = record.getCellValue(LOT_ITEM_FIELD) || [];
  let matchesItem = lotItemLinks.some(link => link.id === ecommerceItemId);
  if (!matchesItem) return false;

  // 2) strain logic:
  //    - if ecommerce.strain_id is set: lot.strain_id must match
  //    - if ecommerce.strain_id is EMPTY: lot.strain_id must also be EMPTY
  let lotStrainLinks = record.getCellValue(LOT_STRAIN_FIELD) || [];
  if (ecommerceStrainId) {
    let matchesStrain = lotStrainLinks.some(link => link.id === ecommerceStrainId);
    if (!matchesStrain) return false;
  } else {
    if (lotStrainLinks.length > 0) return false;
  }

  // 3) use_by not expired (or empty)
  let useBy = record.getCellValue(LOT_USE_BY_FIELD);
  if (!isNotExpired(useBy)) {
    return false;
  }

  // 4) status must match the allowed set for ecommerce.status
  //    If ecommerce.status is not set or not mapped, allowedLotStatuses = []
  let status = record.getCellValue(LOT_STATUS_FIELD);
  let statusName = status && status.name ? status.name : null;

  if (!statusName) return false;
  if (!allowedLotStatuses.includes(statusName)) {
    return false;
  }

  return true;
}

// ---------- Build link arrays ----------

let matchingProducts = [];
for (let productRecord of productsQuery.records) {
  if (productMatches(productRecord)) {
    matchingProducts.push(productRecord);
  }
}

let matchingLots = [];
for (let lotRecord of lotsQuery.records) {
  if (lotMatches(lotRecord)) {
    matchingLots.push(lotRecord);
  }
}

let productLinks = matchingProducts.map(rec => ({ id: rec.id }));
let lotLinks     = matchingLots.map(rec => ({ id: rec.id }));

// ---------- Update ecommerce record ----------

await ecommerceTable.updateRecordAsync(ecommerceRecordId, {
  [ECOM_PRODUCTS_FIELD]: productLinks,
  [ECOM_LOTS_FIELD]: lotLinks,
});

output.set('result',
  `Linked ${matchingProducts.length} product(s) and ${matchingLots.length} lot(s) to ecommerce record ${ecommerceRecordId}.`
);
