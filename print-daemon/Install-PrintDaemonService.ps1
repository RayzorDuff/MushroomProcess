param(
  [string]$WorkingDir = $PSScriptRoot,
  [string]$ServiceName = "JD268BTPrintDaemon"
)

$node = (Get-Command node -ErrorAction Stop).Source
$nssm = "nssm.exe"  # ensure NSSM is in PATH (or give full path)
$script = Join-Path $WorkingDir 'print-daemon.js'

# Service runs "node print-daemon.js" with WorkingDir where .env lives
& $nssm install $ServiceName $node "print-daemon.js"
& $nssm set $ServiceName AppDirectory $WorkingDir
& $nssm set $ServiceName AppStdout "$WorkingDir\logs\service_stdout.log"
& $nssm set $ServiceName AppStderr "$WorkingDir\logs\service_stderr.log"
& $nssm set $ServiceName AppRotateFiles 1
& $nssm set $ServiceName AppRotateOnline 1
& $nssm set $ServiceName AppRotateSeconds 86400
& $nssm start $ServiceName

Write-Host "Service '$ServiceName' installed and started."