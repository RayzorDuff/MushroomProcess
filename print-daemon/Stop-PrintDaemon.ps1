[CmdletBinding()]
param(
  [string]$WorkingDir = $PSScriptRoot,
  [string]$EnvFile = ".env",
  [string]$InstanceId = ""
)


Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Determine instance ID (matches Start-PrintDaemon.ps1 naming)
$inst = $InstanceId
if (-not $inst) {
  # best-effort: parse DAEMON_INSTANCE_ID from env file
  $envPath = Join-Path $WorkingDir $EnvFile
  if (Test-Path $envPath) {
    $line = (Get-Content $envPath | Where-Object { $_ -match '^\s*DAEMON_INSTANCE_ID\s*=' } | Select-Object -First 1)
    if ($line) {
      $parts = $line.Split('=',2)
      if ($parts.Count -eq 2) { $inst = $parts[1].Trim().Trim('"').Trim("'") }
    }
  }
}
if (-not $inst) { $inst = "default" }

$pidFile = Join-Path $WorkingDir ("print-daemon.$inst.pid")
if (-not (Test-Path $pidFile)) {
  Write-Warning "PID file not found: $pidFile"
  return
}
$pid = Get-Content $pidFile | Select-Object -First 1
if (-not $pid) {
  Write-Warning "PID not found in $pidFile"
  return
}

try {
  $proc = Get-Process -Id $pid -ErrorAction Stop
  Write-Host "Stopping PID $pid ($($proc.ProcessName))…" -ForegroundColor Yellow
  $proc.CloseMainWindow() | Out-Null
  Start-Sleep -Seconds 2
  if (!$proc.HasExited) { $proc.Kill() }
} catch {
  Write-Warning "Process $pid not found (maybe already stopped)."
}

Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
Write-Host "Stopped." -ForegroundColor Green