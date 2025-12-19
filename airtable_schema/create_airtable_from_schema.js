#!/usr/bin/env node
require('./load_env');
/**
 * Script: create_airtable_from_schema.js
 * Version: 2025-12-17.1
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
/**

const fs = require('fs');
const path = require('path');
const axios = require('axios');

// Airtable settings via .env (see .env.example)
const AIRTABLE_BASE_ID = process.env.AIRTABLE_BASE_ID || process.env.AIRTABLE_BASE;
const AIRTABLE_ACCESS_TOKEN = process.env.AIRTABLE_TOKEN || process.env.AIRTABLE_KEY;

if (!AIRTABLE_BASE_ID || !AIRTABLE_ACCESS_TOKEN) {
  console.error('[ERROR] AIRTABLE_BASE_ID and AIRTABLE_TOKEN are required (or AIRTABLE_BASE/AIRTABLE_KEY).');
  process.exit(1);
}

const API_BASE = `https://api.airtable.com/v0/bases/${AIRTABLE_BASE_ID}`;
const HEADERS = {
  Authorization: `Bearer ${AIRTABLE_ACCESS_TOKEN}`,
  'Content-Type': 'application/json'
};

async function createTable(tableDef) {
  const url = `${API_BASE}/tables`;
  const body = {
    name: tableDef.name,
    fields: tableDef.fields.map(field => ({
      name: field.name,
      type: field.type,
      options: field.options || undefined
    }))
  };

  try {
    const res = await axios.post(url, body, { headers: HEADERS });
    console.log(`✅ Created table: ${tableDef.name}`);
  } catch (err) {
    console.error(`❌ Error creating table ${tableDef.name}:`, err.response?.data || err.message);
  }
}

async function insertRecords(tableName, records) {
  const url = `https://api.airtable.com/v0/${AIRTABLE_BASE_ID}/${encodeURIComponent(tableName)}`;

  const batchSize = 10;
  for (let i = 0; i < records.length; i += batchSize) {
    const chunk = records.slice(i, i + batchSize).map(record => ({ fields: record }));
    try {
      await axios.post(url, { records: chunk }, { headers: HEADERS });
      console.log(`🔄 Inserted ${chunk.length} records into ${tableName}`);
    } catch (err) {
      console.error(`❌ Error inserting into ${tableName}:`, err.response?.data || err.message);
    }
  }
}

async function main() {
  const schemaPath = path.join(__dirname, '_schema.json');
  const schema = JSON.parse(fs.readFileSync(schemaPath, 'utf8'));

  for (const tableDef of schema.tables) {
    await createTable(tableDef);

    const dataFilePath = path.join(__dirname, `${tableDef.name}.json`);
    if (fs.existsSync(dataFilePath)) {
      const data = JSON.parse(fs.readFileSync(dataFilePath, 'utf8'));
      await insertRecords(tableDef.name, data);
    } else {
      console.warn(`⚠️  No data file found for table: ${tableDef.name}`);
    }
  }
}

main().catch(console.error);