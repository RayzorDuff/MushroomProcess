<# 
  Starts the JD268BT-CA print daemon.
  - Loads .env into process env (in case any tool other than dotenv needs it)
  - Verifies Node.js, printer, and npm deps
  - Launches node print-daemon.js with stdout/stderr to logs
#>

[CmdletBinding()]
param(
  [string]$WorkingDir = $PSScriptRoot,
  [switch]$NoInstall,          # skip npm install
  [switch]$Foreground          # run in foreground (no background process/log redirect)
)

#Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Helpers ---
function Write-Info($msg){ Write-Host "[INFO] $msg" -ForegroundColor Cyan }
function Write-Warn($msg){ Write-Warning $msg }
function Write-Err ($msg){ Write-Error $msg }

function Import-DotEnv([string]$Path){
  if (-not (Test-Path $Path)) { Write-Info ".env not found at $Path (dotenv in Node will still try)."; return }
  Get-Content -Path $Path | ForEach-Object {
    $line = $_.Trim()
    if ($line -eq '' -or $line.StartsWith('#')) { return }
    # Allow KEY="value with spaces" or KEY=value
    $idx = $line.IndexOf('=')
    if ($idx -lt 1) { return }
    $key = $line.Substring(0, $idx).Trim()
    $val = $line.Substring($idx+1).Trim()
    if ($val.StartsWith('"') -and $val.EndsWith('"')) { $val = $val.Trim('"') }
    if ($val.StartsWith("'") -and $val.EndsWith("'")) { $val = $val.Trim("'") }
    # Environment variables for this process (and children)
    [System.Environment]::SetEnvironmentVariable($key, $val, "Process")
  }
}

function Ensure-Printer([string]$PrinterName){
  if ([string]::IsNullOrWhiteSpace($PrinterName)) { 
    Write-Info "No PRINTER_NAME set; Windows default printer will be used."
    return
  }
  try {
    $p = Get-Printer -Name $PrinterName -ErrorAction Stop
    Write-Info "Printer found: $($p.Name)"
  } catch {
    Write-Err "Printer '$PrinterName' not found. Set PRINTER_NAME in .env to match an installed printer."
    throw
  }
}

# --- Go ---
Set-Location $WorkingDir
Write-Info "WorkingDir: $(Get-Location)"

# Load .env into the PowerShell process (Node also loads via dotenv)
Import-DotEnv -Path (Join-Path $WorkingDir '.env')

# Required envs (Node script has defaults, but we warn here)
$baseId = $env:AIRTABLE_BASE_ID
$apiKey = $env:AIRTABLE_API_KEY
if (-not $baseId) { Write-Warn "AIRTABLE_BASE_ID is not set in .env" }
if (-not $apiKey) { Write-Warn "AIRTABLE_API_KEY is not set in .env" }

# Verify Node
try {
  $nodeVer = & node -v
  Write-Info "Node: $nodeVer"
} catch {
  Write-Err "Node.js is not installed or not in PATH. Install from https://nodejs.org/"
  throw
}

# npm install (unless skipped)
if (-not $NoInstall) {
  if (Test-Path (Join-Path $WorkingDir 'package-lock.json')) {
  Write-Info "Running npm ci"
    & npm ci | Write-Output
  } else {
    Write-Info "Running npm install"
    & npm install | Write-Output
  }
}

# Ensure logs dir
$logsDir = Join-Path $WorkingDir 'logs'
if (-not (Test-Path $logsDir)) { New-Item -ItemType Directory -Path $logsDir | Out-Null }

# Check printer (if PRINTER_NAME present)
Ensure-Printer -PrinterName $env:PRINTER_NAME

# Build log file names with timestamp
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$stdoutLog = Join-Path $logsDir "stdout_$stamp.log"
$stderrLog = Join-Path $logsDir "stderr_$stamp.log"
$pidFile   = Join-Path $WorkingDir 'print-daemon.pid'

# Start process
if ($Foreground) {
  Write-Info "Starting daemon in FOREGROUND� (Ctrl+C to stop)"
  # Foreground: just run node, console output visible
  node .\print-daemon.js
} else {
  Write-Info "Starting daemon in BACKGROUND�"
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = "node"
  $psi.Arguments = "print-daemon.js"
  $psi.WorkingDirectory = $WorkingDir
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError  = $true
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $proc = New-Object System.Diagnostics.Process
  $proc.StartInfo = $psi
  $null = $proc.Start()

  # Async log copy
  $outStream = [System.IO.StreamWriter]::new($stdoutLog, $true)
  $errStream = [System.IO.StreamWriter]::new($stderrLog, $true)
  $proc.BeginOutputReadLine()
  $proc.BeginErrorReadLine()
  $proc.add_OutputDataReceived({ param($s,$e) if ($e.Data) { $outStream.WriteLine($e.Data) } })
  $proc.add_ErrorDataReceived( { param($s,$e) if ($e.Data) { $errStream.WriteLine($e.Data) } })

  # Save PID
  $proc.Id | Out-File -FilePath $pidFile -Encoding ascii -Force

  Write-Info "Daemon PID: $($proc.Id)"
  Write-Info "Logs: `n  $stdoutLog `n  $stderrLog"
  Write-Info "To stop: .\Stop-PrintDaemon.ps1"
}
