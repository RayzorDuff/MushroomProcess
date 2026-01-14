# Define the command or script block you want to run
$commandToRun = {
    Write-Output "Running sync_ecommerce_to_ecwid.js"
    node.exe sync_ecommerce_to_ecwid.js > sync.log 2>&1;
    node.exe sync_ecwid_to_ecommerce_orders.js >> sync.log 2>&1;
}

# Define the sleep duration in seconds (15 minutes * 60 seconds/minute = 900 seconds)
$sleepDurationSeconds = 900

while ($true) {
    # Execute the command
    Invoke-Command -ScriptBlock $commandToRun

    # Wait for the specified duration (5 minutes)
    Write-Output "Sleeping for $sleepDurationSeconds seconds..."
    Start-Sleep -Seconds $sleepDurationSeconds
}
