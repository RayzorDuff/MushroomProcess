param(
  [string]$WorkingDir = $PSScriptRoot,
  [string]$ServiceName = "MushroomProcessPrintDaemon",
  [string]$EnvFile = ".env",
  [string]$InstanceId = ""
)


$node = (Get-Command node -ErrorAction Stop).Source
$nssm = "nssm.exe"  # ensure NSSM is in PATH (or give full path)
$script = Join-Path $WorkingDir 'print-daemon.js'

$logsRoot = Join-Path $WorkingDir 'logs'
if (-not (Test-Path $logsRoot)) { New-Item -ItemType Directory -Path $logsRoot | Out-Null }
$logsDir = Join-Path $logsRoot ($InstanceId ? $InstanceId : $ServiceName)
if (-not (Test-Path $logsDir)) { New-Item -ItemType Directory -Path $logsDir | Out-Null }

# Service runs "node print-daemon.js" with WorkingDir where .env lives
& $nssm install $ServiceName $node "print-daemon.js --env-file `"" + (Join-Path $WorkingDir $EnvFile) + "`""
& $nssm set $ServiceName AppDirectory $WorkingDir
& $nssm set $ServiceName AppStdout "$logsDir\service_stdout.log"
& $nssm set $ServiceName AppStderr "$logsDir\service_stderr.log"
& $nssm set $ServiceName AppRotateFiles 1
& $nssm set $ServiceName AppRotateOnline 1
& $nssm set $ServiceName AppRotateSeconds 86400
if ($InstanceId) {
  & $nssm set $ServiceName AppEnvironmentExtra "DAEMON_INSTANCE_ID=$InstanceId"
}
& $nssm start $ServiceName

Write-Host "Service '$ServiceName' installed and started."