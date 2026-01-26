# Print Daemon  

_Label printing for Airtable / NocoDB `print_queue`_

This folder contains:

- `print-daemon.js` – Node.js script that:
  - Watches a `print_queue` view/table.
  - Renders 4×2 inch label PDFs (with optional logo and QR code).
  - Sends them to a Windows thermal printer.
  - Updates each row’s status (`print_status`, `error_msg`, `pdf_path`).

- PowerShell helpers:
  - `Start-PrintDaemon.ps1`, `Stop-PrintDaemon.ps1`
  - `Install-PrintDaemonService.ps1`, `Uninstall-PrintDaemonService.ps1`
  - Other scripts to verify Node, printers, and logs.

It supports both **Airtable** (legacy) and **NocoDB** as the backend for print jobs.

---

## 1. Prerequisites

- **OS:** Windows (scripts are Windows-oriented).
- **Node.js:** Install from <https://nodejs.org/en/download>.
- **Printer:** 4×2" thermal printer (tested with **JADENS JD268BT-CA**) configured in Windows.
- **PDF viewer:** Portable `SumatraPDF.exe` in the daemon folder (optional but recommended).

Typical folder layout:

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

---

## 2. Node Dependencies

The daemon uses libraries such as:

- `pdfkit` – render crisp vector PDFs (great for 203 dpi label printers).
- `qrcode` – generate QR codes from public links.
- `pdf-to-printer` – send PDFs to your Windows printer.
- `dotenv` - read .env environment
- `axios` - Communicate with Airtable API

Install dependencies in the daemon folder:

```bash
npm install pdfkit qrcode pdf-to-printer dotenv axios sumatra
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

### NocoDB (new)

```dotenv
NOCODB_URL=http://your-nocodb-host            # e.g. http://localhost:8080
NOCODB_API_TOKEN=your_api_token               # NocoDB API token

PRINT_QUEUE_TABLE=print_queue                 # table ID/slug for print_queue
STERILIZATION_RUNS_TABLE=sterilization_runs   # table ID/slug for sterilization_runs
LOTS_TABLE=lots                               # table ID/slug for lots
PRINTER_NAME=Your Printer Name Here
```

Notes:

- `PRINTER_NAME` must exactly match the Windows printer name in **Settings → Printers & Scanners**.
  - If omitted, the system default printer is used.
- Ensure the printer’s **default paper size** is set to **4×2 inch** in Printing Preferences.

---

## 4. Running the Daemon (Foreground)

From PowerShell in the daemon directory:
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

The daemon creates per-instance log/PDF directories and uses lock files to prevent printer collisions.


```powershell
node .\print-daemon.js
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

- **DONE:**
  - The daemon can pull print jobs from NocoDB instead of Airtable.
  - It updates `print_status`, `error_msg`, and `pdf_path` directly in NocoDB.

To switch modes:

1. Update `.env` to point either at Airtable variables or at NocoDB variables.
2. Restart the daemon or Windows service.

---

## 7. Troubleshooting

- If no labels print:
  - Check logs in `.\logs\`.
  - Confirm `print_status = "Queued"` in your `print_queue`.
  - Verify `PRINTER_NAME` matches the Windows printer exactly.

- If labels are the wrong size:
  - Confirm the printer’s default media is 4×2" in the Windows driver.
  - Check any scaling options in `pdf-to-printer` configuration (if exposed).

This daemon is the glue that turns `print_queue` rows from the automations into physical labels on blocks, bags, and finished products.
