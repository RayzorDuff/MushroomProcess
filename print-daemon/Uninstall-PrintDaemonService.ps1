param([string]$ServiceName = "MushroomProcessPrintDaemon")
$nssm = "nssm.exe"
& $nssm stop $ServiceName
& $nssm remove $ServiceName confirm
Write-Host "Service '$ServiceName' removed."
