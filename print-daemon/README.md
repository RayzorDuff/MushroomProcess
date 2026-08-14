# Print Daemon

## `printed_at` ownership

`printed_at` is **daemon-owned**: it should only be set when the print job is actually processed.
Enqueue logic should not pre-populate `printed_at`; it may set fields such as `requested_at`, `print_status`, or payload fields used to render the label.
  

_Label printing for Airtable / NocoDB `print_queue`_

This folder contains:

- `print-daemon.js` – Node.js script that:
  - Watches a `print_queue` view/table.
  - Renders 4×2 inch label PDFs (with optional logo and QR code).
  - Sends them to a thermal printer using Windows printing tools or macOS/Linux CUPS `lp`.
  - Updates each row’s status (`print_status`, `error_msg`, `pdf_path`).

- PowerShell helpers:
  - `Start-PrintDaemon.ps1`, `Stop-PrintDaemon.ps1`
  - `Install-PrintDaemonService.ps1`, `Uninstall-PrintDaemonService.ps1`
  - Other scripts to verify Node, printers, and logs.

It supports both **Airtable** (legacy) and **NocoDB** as the backend for print jobs.

---

## 1. Prerequisites

- **OS:** Windows or macOS. The PowerShell/service helpers are Windows-oriented, but `print-daemon.js` can run in the foreground on macOS.
- **Node.js:** Install from <https://nodejs.org/en/download>.
- **Printer:** 4×2" thermal printer configured in the operating system. On macOS, the printer must be visible to CUPS.
- **PDF viewer / print helper:**
  - Windows: Portable `SumatraPDF.exe` in the daemon folder is optional but recommended.
  - macOS: no SumatraPDF is used. Printing is submitted through the built-in CUPS `lp` command.

Typical Windows folder layout:

```text
C:\print-daemon\
  .env.example
  print-daemon.js
  logo.png               # optional, black & white
  SumatraPDF.exe         # optional, portable viewer
  Start-PrintDaemon.ps1
  Stop-PrintDaemon.ps1
  Install-PrintDaemonService.ps1
  Uninstall-PrintDaemonService.ps1
  logs\
```


Typical macOS folder layout:

```text
~/print-daemon/
  .env
  print-daemon.js
  logo.png               # optional, black & white
  logs/
```

---

## 2. Node Dependencies

The daemon uses libraries such as:

- `pdfkit` – render crisp vector PDFs (great for 203 dpi label printers).
- `qrcode` – generate QR codes from stable MushroomProcess scan URLs.
- `pdf-to-printer` – send PDFs to your Windows printer. This is optional on macOS because the daemon uses CUPS `lp` there.
- `dotenv` - read .env environment
- `axios` - Communicate with Airtable API

Install dependencies in the daemon folder:

```bash
npm install pdfkit qrcode dotenv axios
# Windows only / optional:
npm install pdf-to-printer sumatra
```

(Or install the specific modules if you prefer a slimmer setup.)

---

## 3. Configuration – `.env`

Create a `.env` file in the daemon folder (use .env.example as a basis). Depending on your backend, include:

### Backend selector

```dotenv
# Defaults to "airtable" if omitted
DB_BACKEND=Airtable   # or: NocoDB
```

### Airtable (legacy)

```dotenv
AIRTABLE_BASE_ID=appXXXXXXXXXXXXXX
AIRTABLE_API_KEY=patXXXXXXXXXXXXXX

PRINT_QUEUE_TABLE=print_queue                 # table ID/slug for print_queue
STERILIZATION_RUNS_TABLE=sterilization_runs   # table ID/slug for sterilization_runs
LOTS_TABLE=lots                               # table ID/slug for lots
PRINTER_NAME=Your Printer Name Here
```

### NocoDB v2 / internal tables

Use this mode when NocoDB exposes tables through the older `/api/v2/tables/<table>/records` API. This is the legacy daemon behavior.

```dotenv
DB_BACKEND=NocoDB
NOCODB_API_VERSION=v2
NOCODB_URL=http://your-nocodb-host            # e.g. http://localhost:8080
NOCODB_API_TOKEN=your_api_token               # NocoDB API token

PRINT_QUEUE_TABLE=print_queue                 # table ID/slug for print_queue
STERILIZATION_RUNS_TABLE=sterilization_runs   # table ID/slug for sterilization_runs
LOTS_TABLE=lots                               # table ID/slug for lots
PRINTER_NAME=Your Printer Name Here
```

### NocoDB v3 / external PostgreSQL sources

Use this mode when NocoDB's API Snippets show URLs like:

```text
/api/v3/data/<baseId>/<tableId>/records?pageSize=25&viewId=<viewId>
```

The first identifier after `/api/v3/data/` is the NocoDB **base ID**. The
daemon now resolves the MushroomProcess table IDs automatically from table
names, so the normal configuration does not require copying every table and
view ID.

#### Which table is read and which table is written?

The split is intentional:

```text
vc_print_queue  --read label/computed fields-->  print daemon
print_queue     <--write status/audit fields--  print daemon
```

- **Read `vc_print_queue`** because it contains computed label fields, linked
  lot/product information, legacy public links, routing fields, and status values used
  to render the label. The daemon now derives the preferred stable QR resolver URL
  from the canonical Product/Lot identifier at render time.
- **Write `print_queue`** because it is the writable base table that owns
  `print_status`, `claimed_by`, `claimed_at`, `printed_by`, `printed_at`,
  `error_msg`, and `pdf_path`.
- Sterilizer sheets read `vc_sterilization_runs` and `vc_lots` when those views
  exist, falling back to `sterilization_runs` and `lots`.

#### Recommended minimal `.env`

```dotenv
DB_BACKEND=NocoDB
NOCODB_API_VERSION=v3
NOCODB_URL=https://nocodb.example.com
NOCODB_API_TOKEN=your_api_token
NOCODB_BASE_ID=pgxxxxxxxxxxxxx

# Optional; true is the default.
NOCODB_AUTO_RESOLVE_IDS=true

# The writable print_queue primary key exposed by NocoDB.
PRINT_QUEUE_WRITE_ID_FIELD=nocopk

PRINTER_NAME=Your Printer Name Here

# Optional override; this is the production default.
QR_RESOLVER_BASE_URL=https://qr.danks.store/r
```

### Stable Product/Lot QR routing (#12 Phase 4)

For current PostgreSQL/NocoDB labels, the daemon does not use Airtable or
storefront `public_link*` values as QR payloads. It extracts the
canonical `PROD-...` or `LOT-...` identifier already present in the computed
label fields and encodes:

```text
https://qr.danks.store/r?i=PROD-...
https://qr.danks.store/r?i=LOT-...
```

The stable resolver can therefore move Product traffic from Ecwid to
WooCommerce later without reprinting labels, while Lot traffic continues to
resolve to the authenticated Appsmith Lots deep link. Sterilizer output sheets
use the same resolver URL for each Lot QR.

Resolution order is now:

1. an explicit `scan_url` supplied by a future database/view contract;
2. a stable resolver URL derived from the canonical Product/Lot identifier.

Legacy Airtable/storefront `public_link*` values are intentionally ignored by the
active daemon. If neither `scan_url` nor a canonical inventory identifier is
available, no QR payload is rendered rather than falling back to a legacy link. Override
`QR_RESOLVER_BASE_URL` only for a development/staging resolver.

Run the QR routing smoke test after daemon changes:

```bash
node print-daemon/tests/qr-routing-smoke.js
```

`NOCODB_SOURCE_ID` and `NOCODB_BASE_SOURCE_ID` remain accepted as legacy
aliases for `NOCODB_BASE_ID`.

At startup the daemon looks up these logical names and logs the resolved IDs:

| Purpose | Preferred logical table | Fallback |
|---|---|---|
| Queue label read | `vc_print_queue` | none |
| Queue status write | `print_queue` | none |
| Sterilizer run read | `vc_sterilization_runs` | `sterilization_runs` |
| Sterilizer lot read | `vc_lots` | `lots` |

When `ENABLE_STERI_SHEETS=false`, the sterilization-run and lots tables are not
resolved because that daemon instance does not use them.

Check the configuration without polling or printing:

```bash
node print-daemon.js --env-file .env --check-config
```

A successful check prints the resolved table IDs and exits. No queue rows are
claimed or changed.

#### Optional manual IDs

Automatic resolution uses NocoDB's metadata API. If the token cannot list table
metadata, set the IDs explicitly. Open the table in NocoDB, choose
**Details → API Snippets**, and copy the table ID from the generated URL:

```bash
curl --request GET \
  --url 'https://nocodb.example.com/api/v3/data/pgqebfafii7ro7t/msy61shkluqfjxf/records?pageSize=25&viewId=vwmevslwqqhc7x54' \
  --header 'xc-token: YOUR_TOKEN'
```

Mapping:

```text
/api/v3/data/<baseId>/<tableId>/records?...&viewId=<viewId>
             └ base ID └ table ID                 └ optional view ID
```

Example manual configuration:

```dotenv
NOCODB_BASE_ID=pgqebfafii7ro7t
NOCODB_AUTO_RESOLVE_IDS=false

PRINT_QUEUE_READ_TABLE=table_id_from_vc_print_queue
PRINT_QUEUE_WRITE_TABLE=table_id_from_print_queue
PRINT_QUEUE_WRITE_ID_FIELD=nocopk

# Required only when ENABLE_STERI_SHEETS=true.
STERILIZATION_RUNS_TABLE=table_id_from_vc_sterilization_runs
LOTS_TABLE=table_id_from_vc_lots
```

View IDs are optional. Leave `PRINT_QUEUE_READ_VIEW_ID`,
`STERILIZATION_RUNS_VIEW_ID`, and `LOTS_VIEW_ID` unset unless the daemon must
respect a particular NocoDB UI view's filters or ordering.
`PRINT_QUEUE_WRITE_VIEW_ID` is not used for PATCH requests and should normally
be omitted.

The NocoDB v3 write request is sent to the writable `print_queue` table in this
shape:

```bash
curl --request PATCH \
  --url 'https://nocodb.example.com/api/v3/data/<baseId>/<print_queue_table_id>/records' \
  --header 'Content-Type: application/json' \
  --header 'xc-token: YOUR_TOKEN' \
  --data '{
    "id": 1,
    "fields": {
      "error_msg": "daemon write test"
    }
  }'
```

### macOS / CUPS printing

On macOS, the daemon renders PDFs exactly as it does on Windows, but it sends the PDF to the printer with the built-in CUPS `lp` command instead of SumatraPDF or `pdf-to-printer`.

Find the printer queue name:

```bash
lpstat -p -d
```

Inspect the printer driver/media options:

```bash
lpoptions -p Your_Printer_Queue_Name -l
```

Example `.env.trays` for a MacBook tray-label instance:

```dotenv
DAEMON_INSTANCE_ID=trays-mac
DB_BACKEND=NocoDB
NOCODB_API_VERSION=v3
NOCODB_URL=https://your-nocodb-host
NOCODB_API_TOKEN=your_api_token
NOCODB_BASE_ID=pgxxxxxxxxxxxxx
NOCODB_AUTO_RESOLVE_IDS=true
PRINT_QUEUE_WRITE_ID_FIELD=nocopk

PRINT_TARGET_FIELD=print_target
PRINT_TARGET_VALUE=TRAYS
PRINTER_NAME=Your_CUPS_Printer_Queue_Name

LABEL_WIDTH_IN=4
LABEL_HEIGHT_IN=2
ORIENTATION=landscape
ENABLE_STERI_SHEETS=false

# Optional. CUPS option names vary by printer driver. Prefer values reported by:
#   lpoptions -p Your_CUPS_Printer_Queue_Name -l
# Examples that may work depending on driver:
#   LP_LABEL_OPTIONS=media=Custom.4x2in,landscape,fit-to-page
#   LP_LABEL_OPTIONS=media=w288h144,landscape,fit-to-page
LP_LABEL_OPTIONS=landscape,fit-to-page

LOG_LEVEL=debug
```

For sterilizer sheets on macOS, configure a letter printer and optional sheet options:

```dotenv
STERI_SHEET_PRINTER=Your_Letter_Printer_Queue_Name
LP_SHEET_OPTIONS=media=Letter,portrait,fit-to-page
```

Useful test commands:

```bash
# Print a generated PDF manually with the same queue name.
lp -d Your_CUPS_Printer_Queue_Name -o landscape -o fit-to-page /path/to/label.pdf

# Use the daemon's dry-run mode to log the lp command without printing.
LP_DRY_RUN=true node ./print-daemon.js --env-file .env.trays
```

Notes:

- `LP_COMMAND` defaults to `lp`. Override only if needed.
- `LP_LABEL_OPTIONS` and `LP_SHEET_OPTIONS` are passed as `-o` options to `lp`. They may be comma-separated or whitespace-separated.
- CUPS media names are driver-specific. Do not assume `media=Custom.4x2in` works until `lpoptions -l` confirms the available option name.
- The daemon considers `lp` exit code `0` a successful submission to the print queue. It does not prove that the printer physically completed the job.

Notes:

- `PRINTER_NAME` must exactly match the printer name used by the operating system.
  - Windows: use the name shown in **Settings → Printers & Scanners**.
  - macOS: use the CUPS queue name shown by `lpstat -p -d`.
  - If omitted, the system default printer is used.
- Ensure the printer’s default media is set to **4×2 inch** where possible.

---

## 4. Running the Daemon (Foreground)

From PowerShell in the daemon directory on Windows, or from Terminal on macOS:
### Multi-instance (two printers / one host)

If you want **two daemons on the same Windows machine** (e.g., one for trays on the JD-268 and one for everything else on the Zebra GK420t), use **two separate env files** and a unique `DAEMON_INSTANCE_ID` for each.

Example:

- `.env.trays`  
  - `DAEMON_INSTANCE_ID=trays`
  - `QUEUE_VIEW=Queue_All_Trays` *(or)* `PRINT_TARGET_VALUE=TRAYS`
  - `PRINTER_NAME=JD-268BT_Bluetooth`
  - `ENABLE_STERI_SHEETS=false`

- `.env.labels`  
  - `DAEMON_INSTANCE_ID=labels`
  - `QUEUE_VIEW=Queue_All_but_Trays` *(or)* `PRINT_TARGET_VALUE=ZEBRA`
  - `PRINTER_NAME=Zebra GK420t`
  - `ENABLE_STERI_SHEETS=true`
  - `STERI_SHEET_PRINTER=Your Letter Printer`

Run each instance:

```powershell
.\Start-PrintDaemon.ps1 -EnvFile .env.trays  -InstanceId trays
.\Start-PrintDaemon.ps1 -EnvFile .env.labels -InstanceId labels
```

The daemon creates per-instance log/PDF directories and uses lock files to prevent printer collisions. On macOS, the same `--env-file` argument works from Terminal; the PowerShell helper scripts are not required for foreground use.


```powershell
node .\print-daemon.js
```

macOS:

```bash
node ./print-daemon.js --env-file .env.trays
```

The script:

- Reads `.env` using `dotenv`.
- Polls the configured backend (`print_queue` in Airtable or NocoDB).
- For each row with `print_status = "Queued"`:
  - Generates a label PDF (optionally embedding `logo.png` and a QR code).
  - Sends it to the configured printer.
  - Updates the row to `Printed` or `Error` (and writes `error_msg`, `pdf_path` as appropriate).
  
  - Generates a label PDF (optionally embedding `logo.png` and a QR code).

- For print jobs where `source_kind = "product"`:
  - The daemon normally prints the standard 4×2 product label.
  - If `label_companyinfo_prod (from product_id)` is present (non-blank), the daemon prints a **second 4×2 label** immediately after the first.
  - If `print_queue.label_type = "Product_Package_Sample"`, the daemon instead prints a **single dense 4×2 sample/package label** and does **not** print the second product-info label.

- The second product-info label includes any of the following fields that are defined:
  - `label_companyaddress_prod (from product_id)`
  - `label_companyinfo_prod (from product_id)`
  - `label_disclaimer_prod (from product_id)`
  - `label_cottage_prod (from product_id)`

- The `Product_Package_Sample` label includes these product fields on one label:
  - `label_company_prod` / `label_company_prod (from product_id)`
  - `label_title_prod` / `label_title_prod (from product_id)`
  - `label_subtitle_prod` / `label_subtitle_prod (from product_id)`
  - `label_footer_prod` / `label_footer_prod (from product_id)`
  - `label_packaged_prod` / `label_packaged_prod (from product_id)`
  - `label_useby_prod` / `label_useby_prod (from product_id)`
  - `label_disclaimer_prod` / `label_disclaimer_prod (from product_id)`
  - stable Product scan QR, unless disabled with `SAMPLE_INCLUDE_QR=false`

- Syringe labels for `lc_syringe` and `lc_syringe_purchased` items now print as two cuttable mini-label panels on a single 4×2 label for both lot and product jobs.

Leave this process running in a console, or convert it to a Windows service (see below).

---

## 5. Running as a Windows Service (NSSM)

The PowerShell helpers offer a “plug-and-play” service setup (assuming [NSSM](https://nssm.cc/) is installed and in `PATH`).

1. **Install the service**

   ```powershell
   .\Install-PrintDaemonService.ps1
   ```

   This script typically:

   - Validates Node and the printer.
   - Configures NSSM to run `node print-daemon.js` in the correct working directory.
   - Sets up log files under `.\logs\`.

2. **Remove the service**

   ```powershell
   .\Uninstall-PrintDaemonService.ps1
   ```

3. **Start/stop manually**

   ```powershell
   .\Start-PrintDaemon.ps1
   .\Stop-PrintDaemon.ps1
   ```

---

## 6. NocoDB vs Airtable Mode

The daemon supports:

- Airtable legacy API mode.
- NocoDB v2 table API mode.
- NocoDB v3 external PostgreSQL data API mode.

In NocoDB v3 mode, prefer reading from `vc_print_queue` and writing to the real `print_queue` table. This lets the daemon render labels from computed/lookup fields while still patching writable status fields on the base table.

To switch modes:

1. Update `.env` to point either at Airtable variables or at NocoDB variables.
2. For NocoDB v3, set `NOCODB_BASE_ID`; table IDs resolve automatically by default.
3. Run `node print-daemon.js --env-file .env --check-config`.
4. Restart the daemon or Windows service.

---

## 7. Troubleshooting

### General

- If no labels print:
  - Check logs in `.\logs\`.
  - Confirm `print_status = "Queued"` in your `print_queue`.
  - Verify `PRINTER_NAME` matches the Windows printer name or macOS CUPS queue name exactly.

- If labels are the wrong size:
  - Confirm the printer’s default media is 4×2" in the printer driver.
  - Windows: check any scaling options in `pdf-to-printer` or Sumatra configuration.
  - macOS: inspect available driver options with `lpoptions -p <printer> -l` and set `LP_LABEL_OPTIONS` accordingly.


### NocoDB v3-specific

- Run `node print-daemon.js --env-file .env --check-config` first. The output shows the logical table names and resolved internal IDs without claiming a job.
- If automatic resolution fails, confirm `NOCODB_BASE_ID` is the first ID after `/api/v3/data/` in an API Snippet and that the token may read table metadata.
- If the daemon does not render labels, confirm the resolved read table is `vc_print_queue`, not base `print_queue`.
- If status updates fail, confirm the resolved write table is `print_queue` and `PRINT_QUEUE_WRITE_ID_FIELD=nocopk`.
- View IDs are not required for normal operation. Remove placeholder `*_VIEW_ID` values rather than leaving text such as `view_id_here` in `.env`.
- If metadata access is unavailable, copy table IDs from **Details → API Snippets**, set `NOCODB_AUTO_RESOLVE_IDS=false`, and use the manual-ID example above.
- If you see `401` or `403`, recreate the NocoDB token and ensure it has access to the MushroomProcess base and external PostgreSQL tables.

### macOS-specific

- Confirm the printer exists:

  ```bash
  lpstat -p -d
  ```

- Print one generated PDF manually:

  ```bash
  lp -d Your_CUPS_Printer_Queue_Name -o landscape -o fit-to-page /path/to/label.pdf
  ```

- If `lp` accepts the job but nothing prints, check the macOS print queue and printer driver/media settings. A successful `lp` exit code means the job was accepted by CUPS, not necessarily completed by the printer.

- To see the exact `lp` command options without physically printing, run:

  ```bash
  LP_DRY_RUN=true node ./print-daemon.js --env-file .env.trays
  ```

This daemon is the glue that turns `print_queue` rows from the automations into physical labels on blocks, bags, and finished products.
