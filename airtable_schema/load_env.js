/**
 * load_env.js
 *
 * Lightweight .env loader (no dependencies).
 * - Loads `${__dirname}/.env` if present.
 * - Does NOT overwrite already-defined process.env keys.
 * - Supports simple KEY=VALUE lines with optional quotes.
 * - Ignores blank lines and comments starting with #.
 */
const fs = require('fs');
const path = require('path');

function stripQuotes(v) {
  const s = String(v);
  if ((s.startsWith('"') && s.endsWith('"')) || (s.startsWith("'") && s.endsWith("'"))) {
    return s.slice(1, -1);
  }
  return s;
}

function loadDotEnv(envPath = path.join(__dirname, '.env')) {
  try {
    if (!fs.existsSync(envPath)) return;
    const raw = fs.readFileSync(envPath, 'utf-8');

    for (const line of raw.split(/\r?\n/)) {
      const trimmed = line.trim();
      if (!trimmed || trimmed.startsWith('#')) continue;

      const eq = trimmed.indexOf('=');
      if (eq === -1) continue;

      const key = trimmed.slice(0, eq).trim();
      let val = trimmed.slice(eq + 1).trim();

      // Remove inline comments: KEY=value # comment (only if unquoted)
      if (!(val.startsWith('"') || val.startsWith("'"))) {
        const hash = val.indexOf(' #');
        if (hash !== -1) val = val.slice(0, hash).trim();
        const hash2 = val.indexOf('\t#');
        if (hash2 !== -1) val = val.slice(0, hash2).trim();
        if (val.includes('#')) {
          const h = val.indexOf('#');
          if (h !== -1) val = val.slice(0, h).trim();
        }
      }

      val = stripQuotes(val);
      if (!key) continue;

      if (typeof process.env[key] === 'undefined') {
        process.env[key] = val;
      }
    }
  } catch (err) {
    // Fail-quietly; scripts should still run with explicit env vars
    // eslint-disable-next-line no-console
    console.warn('[WARN] Failed to load .env:', err?.message || err);
  }
}

loadDotEnv();

module.exports = { loadDotEnv };