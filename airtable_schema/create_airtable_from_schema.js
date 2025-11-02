const fs = require('fs');
const path = require('path');
const axios = require('axios');

// TODO: Replace with your Airtable settings
const AIRTABLE_BASE_ID = 'your_base_id';
const AIRTABLE_ACCESS_TOKEN = 'your_access_token';

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
