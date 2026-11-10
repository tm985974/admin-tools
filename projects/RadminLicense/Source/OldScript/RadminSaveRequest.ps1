# Get the local computer name
$computerName = $env:COMPUTERNAME

# Define the path and command
$exePath = "C:\Windows\SysWOW64\rserver30\rserver3.exe"
$key = "xxx"
$requestFilePath = "C:\FAS\$computerName.request"

# Build the argument list
$args = "/saverequest /key:$key /requestfile`"$requestFilePath`""

# Run the command
Start-Process -FilePath $exePath -ArgumentList $args -NoNewWindow -Wait
