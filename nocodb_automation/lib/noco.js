// lib/noco.js
// Minimal NocoDB REST helper for server-side automations.
// Env required: NOCO_BASE_URL, NOCO_TOKEN, NOCO_PROJECT
import fetch from "node-fetch";

export function makeNC({ baseUrl, token, projectSlug }) {
  if (!baseUrl || !token || !projectSlug) {
    throw new Error("Missing baseUrl / token / projectSlug");
  }
  const base = baseUrl.replace(/\/+$/, "");
  const headers = {
    accept: "application/json",
    "content-type": "application/json",
    "xc-token": token,
  };
  const J = (x) => JSON.stringify(x);

  async function api(path, method = "GET", body) {
    const res = await fetch(`${base}/api/v2/${path}`, {
      method,
      headers,
      body: body ? J(body) : undefined,
    });
    if (!res.ok) {
      const txt = await res.text();
      throw new Error(`NocoDB ${method} ${path} -> ${res.status} ${txt}`);
    }
    return res.json();
  }

  async function getTableIdByName(tableName) {
    const meta = await api(`project/${projectSlug}/tables`);
    const t = meta.list.find(
      (m) => m.title === tableName || m.table_name === tableName
    );
    if (!t) throw new Error(`Table not found: ${tableName}`);
    return t.id;
  }

  async function listTable(tableName, opts = {}) {
    const id = await getTableIdByName(tableName);
    const q = {
      ...(opts.where ? { where: opts.where } : {}),
      ...(opts.fields ? { fields: opts.fields } : {}),
      ...(opts.limit ? { limit: opts.limit } : {}),
      ...(opts.offset ? { offset: opts.offset } : {}),
      ...(opts.sort ? { sort: opts.sort } : {}),
    };
    return api(`tables/${id}/records/query`, "POST", q);
  }

  async function getById(tableName, rowId) {
    const id = await getTableIdByName(tableName);
    return api(`tables/${id}/records/${rowId}`, "GET");
  }

  async function create(tableName, rows) {
    const id = await getTableIdByName(tableName);
    const arr = Array.isArray(rows) ? rows : [rows];
    return api(`tables/${id}/records`, "POST", { data: arr });
  }

  async function update(tableName, rowId, fields) {
    const id = await getTableIdByName(tableName);
    return api(`tables/${id}/records/${rowId}`, "PATCH", { data: fields });
  }

  return { listTable, getById, create, update };
}
