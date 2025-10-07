Plug-and-play PowerShell setup that:

reads your .env (key=value) safely,

verifies Node & your Windows printer,

starts the Node print daemon (print-daemon.js),

writes rotating logs,

and (optionally) installs it as a Windows service via NSSM.

You can copy/paste these files into the same folder as print-daemon.js and .env.

1) Folder layout
C:\print-daemon\
  .env
  print-daemon.js
  logo.png                 # optional
  Start-PrintDaemon.ps1
  Stop-PrintDaemon.ps1
  Install-PrintDaemonService.ps1   # optional (NSSM)
  Uninstall-PrintDaemonService.ps1 # optional (NSSM)
  logs\


Create logs\ once (or the script will create it).

2) Start script (reads .env + starts Node)

Start-PrintDaemon.ps1

<# 
  Starts the JD268BT-CA print daemon.
  - Loads .env into process env (in case any tool other than dotenv needs it)
  - Verifies Node.js, printer, and npm deps
  - Launches node print-daemon.js with stdout/stderr to logs
#>


3) Stop script

Stop-PrintDaemon.ps1


4) (Optional) Install as a Windows Service via NSSM

This keeps it running in the background after reboots. Requires NSSM (https://nssm.cc/download
).

5) How to run

Open PowerShell as your user (or Admin if installing a service):

Set-ExecutionPolicy -Scope CurrentUser RemoteSigned

cd C:\print-daemon

# One-time (installs deps, checks printer, then starts in background)
.\Start-PrintDaemon.ps1

# …later, to stop:
.\Stop-PrintDaemon.ps1

Foreground mode (for live console output while testing):

.\Start-PrintDaemon.ps1 -Foreground

As a service:

# Make sure NSSM is installed and in PATH
.\Install-PrintDaemonService.ps1
# To remove later:
.\Uninstall-PrintDaemonService.ps1

Notes that save headaches

Ensure your Windows printer Printing Preferences default to 4×2 in media for the JD268BT-CA.

The Node script you already have uses dotenv, so it will read .env as long as the working directory is correct (the scripts above ensure that).

If your printer name differs, set PRINTER_NAME in .env to exactly how it appears in “Printers & Scanners.” The start script will warn if it can’t find it.

Logs live in .\logs\. If you prefer one combined log, adjust the start script.