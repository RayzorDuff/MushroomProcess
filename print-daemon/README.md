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
- `qrcode` – generate QR codes from public links.
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
/api/v3/data/<sourceId>/<tableId>/records?pageSize=25&viewId=<viewId>
```

This is common when MushroomProcess tables are exposed through a NocoDB external PostgreSQL data source. In this mode the daemon may need to **read from one table/view** and **write to another**:

- Read from `vc_print_queue` or another computed/read view that contains rendered label fields such as `label_title_lot (from lot_id)`, `label_subtitle_lot (from lot_id)`, `public_link`, `print_target`, and `print_status`.
- Write status fields back to the real `print_queue` base table, because the daemon updates `print_status`, `claimed_by`, `claimed_at`, `printed_by`, `printed_at`, `error_msg`, and `pdf_path`.

Example `.env` values:

```dotenv
DB_BACKEND=NocoDB
NOCODB_API_VERSION=v3
NOCODB_URL=https://nocodb.example.com
NOCODB_API_TOKEN=your_api_token
NOCODB_SOURCE_ID=pgxxxxxxxxxxxxx

# Read from vc_print_queue or equivalent.
PRINT_QUEUE_READ_TABLE=vc_print_queue_table_id_here
PRINT_QUEUE_READ_VIEW_ID=vc_print_queue_view_id_here

# Write back to real print_queue.
PRINT_QUEUE_WRITE_TABLE=print_queue_table_id_here
PRINT_QUEUE_WRITE_VIEW_ID=print_queue_view_id_here
PRINT_QUEUE_WRITE_ID_FIELD=nocopk

# Needed for sterilizer sheet jobs. Use table/view IDs from API Snippets.
STERILIZATION_RUNS_TABLE=sterilization_runs_table_id_here
STERILIZATION_RUNS_VIEW_ID=sterilization_runs_view_id_here
LOTS_TABLE=vc_lots_or_lots_table_id_here
LOTS_VIEW_ID=vc_lots_or_lots_view_id_here

PRINTER_NAME=Your Printer Name Here
```

#### How to find the NocoDB v3 identifiers

For each table or view you need, open it in NocoDB and go to **Details → API Snippets**. Use the identifiers from the generated URL. For example:

```bash
curl --request GET \
  --url 'https://nocodb.example.com/api/v3/data/pgqebfafii7ro7t/msy61shkluqfjxf/records?pageSize=25&viewId=vwmevslwqqhc7x54' \
  --header 'xc-token: YOUR_TOKEN'
```

Map that URL to `.env` like this:

```dotenv
NOCODB_URL=https://nocodb.example.com
NOCODB_SOURCE_ID=pgqebfafii7ro7t
PRINT_QUEUE_WRITE_TABLE=msy61shkluqfjxf
PRINT_QUEUE_WRITE_VIEW_ID=vwmevslwqqhc7x54
```

For `PRINT_QUEUE_READ_TABLE` and `PRINT_QUEUE_READ_VIEW_ID`, repeat the same API Snippets lookup while viewing `vc_print_queue`, not the base `print_queue`, so the daemon receives the label/lookup fields it needs for rendering.

To verify write/update behavior, NocoDB v3 should accept PATCH requests in this shape:

```bash
curl --request PATCH \
  --url 'https://nocodb.example.com/api/v3/data/<sourceId>/<print_queue_table_id>/records' \
  --header 'Content-Type: application/json' \
  --header 'xc-token: YOUR_TOKEN' \
  --data '{
    "id": 1,
    "fields": {
      "error_msg": "daemon write test"
    }
  }'
```

The daemon uses that same PATCH shape for status updates.

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
NOCODB_SOURCE_ID=pgxxxxxxxxxxxxx

PRINT_QUEUE_READ_TABLE=vc_print_queue_table_id_here
PRINT_QUEUE_READ_VIEW_ID=vc_print_queue_view_id_here
PRINT_QUEUE_WRITE_TABLE=print_queue_table_id_here
PRINT_QUEUE_WRITE_VIEW_ID=print_queue_view_id_here
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
  - The daemon always prints the normal label (the same 4×2 product label as before).
  - If `label_companyinfo_prod (from product_id)` is present (non-blank), the daemon prints a **second 4×2 label** immediately after the first.

- The second label includes any of the following fields that are defined:
  - `label_companyaddress_prod (from product_id)`
  - `label_companyinfo_prod (from product_id)`
  - `label_disclaimer_prod (from product_id)`
  - `label_cottage_prod (from product_id)`
  
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
2. For NocoDB v3, copy source/table/view identifiers from NocoDB **Details → API Snippets**.
3. Restart the daemon or Windows service.

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

- If the daemon starts but does not render labels, confirm that `PRINT_QUEUE_READ_TABLE` points to `vc_print_queue` or another view/table that includes the label fields. Reading from base `print_queue` alone usually only exposes links and status fields.
- If status updates fail, confirm that `PRINT_QUEUE_WRITE_TABLE` points to the real `print_queue` table and that `PRINT_QUEUE_WRITE_ID_FIELD` matches the primary key field exposed by API Snippets, usually `nocopk`.
- If you see `NOCODB_SOURCE_ID is required`, copy the source id from the v3 API URL segment immediately after `/api/v3/data/`.
- If you see `404`, one of the table/view identifiers is wrong. Re-copy it from API Snippets.
- If you see `401` or `403`, recreate the NocoDB token and ensure it has access to the external PostgreSQL source.

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
