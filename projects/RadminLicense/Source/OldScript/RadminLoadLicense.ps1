# Get the local computer name
$computerName = $env:COMPUTERNAME

# Define the path and command
$exePath = "C:\Windows\SysWOW64\rserver30\rserver3.exe"
$key = "xxx"
$requestFilePath = "C:\FAS\$computerName.license"

# Build the argument list
$args = "/uselicense /licensefile`"$requestFilePath`""

# Run the command
Start-Process -FilePath $exePath -ArgumentList $args -NoNewWindow -Wait
