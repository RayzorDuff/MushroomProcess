#!/usr/bin/env node
'use strict';

const assert = require('assert');
const Module = require('module');

process.env.QR_RESOLVER_BASE_URL = 'https://qr.danks.store/r';
process.env.LOG_TO_FILE = 'false';
process.env.LOG_TO_CONSOLE = 'false';

// The production daemon has these dependencies installed beside it. The repository
// smoke test only exercises pure QR-routing helpers, so stub optional/runtime modules
// when they are unavailable in a development checkout.
const originalLoad = Module._load;
Module._load = function(request, parent, isMain) {
  if (request === 'dotenv') return { config: () => ({ parsed: {} }) };
  if (request === 'axios') return { default: { create: () => ({}) } };
  if (request === 'pdfkit') return function PDFDocumentStub() {};
  if (request === 'qrcode') return { toDataURL: async () => '' };
  if (request === 'pdf-to-printer') return { print: async () => {} };
  return originalLoad.call(this, request, parent, isMain);
};

const {
  extractInventoryId,
  buildQrResolverUrl,
  stableQrUrlFromFields,
  labelQrUrl,
  gatherFields,
  steriSheetLotFields,
} = require('../print-daemon.js');

assert.strictEqual(
  extractInventoryId('Lot: LOT-260624-rTT0', 'lot'),
  'LOT-260624-rTT0'
);
assert.strictEqual(
  extractInventoryId('PROD-260801-bojs', 'product'),
  'PROD-260801-bojs'
);
assert.strictEqual(
  buildQrResolverUrl('PROD-260801-bojs'),
  'https://qr.danks.store/r?i=PROD-260801-bojs'
);
assert.strictEqual(
  buildQrResolverUrl('LOT-260624-rTT0'),
  'https://qr.danks.store/r?i=LOT-260624-rTT0'
);

const explicitScanUrl = 'https://qr.danks.store/r?i=PROD-260801-explicit';
assert.strictEqual(
  stableQrUrlFromFields({
    scan_url: explicitScanUrl,
    label_footer_prod_from_product_id: ['PROD-260801-bojs'],
  }, 'product'),
  explicitScanUrl,
  'explicit scan_url should take precedence when a future view supplies one'
);

const productRec = {
  fields: {
    source_kind: 'product',
    label_footer_prod_from_product_id: ['PROD-260801-bojs'],
    public_link_from_product_id: ['https://legacy.example/product'],
  },
};
assert.strictEqual(
  gatherFields(productRec).qr,
  'https://qr.danks.store/r?i=PROD-260801-bojs',
  'product labels should prefer the stable resolver over legacy public_link values'
);

const lotRec = {
  fields: {
    source_kind: 'lot',
    label_footer_lot_from_lot_id: ['Lot: LOT-260624-rTT0'],
    public_link_from_lot_id: ['https://airtable.example/lot'],
  },
};
assert.strictEqual(
  gatherFields(lotRec).qr,
  'https://qr.danks.store/r?i=LOT-260624-rTT0',
  'lot labels should prefer the stable resolver over legacy Airtable links'
);

assert.strictEqual(
  labelQrUrl({ public_link: 'https://legacy.example/fallback' }, 'lot'),
  'https://legacy.example/fallback',
  'legacy public_link must remain a migration fallback when no canonical inventory ID is available'
);

assert.strictEqual(
  steriSheetLotFields({
    fields: {
      lot_id: 'LOT-260624-rTT0',
      public_link: 'https://airtable.example/lot',
    },
  }).qrUrl,
  'https://qr.danks.store/r?i=LOT-260624-rTT0',
  'sterilizer sheet Lot QR codes should use the stable resolver'
);

console.log('Print daemon stable Product/Lot QR routing smoke tests passed.');
