[CmdletBinding()]
param(
  [string]$WorkingDir = $PSScriptRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$pidFile = Join-Path $WorkingDir 'print-daemon.pid'
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