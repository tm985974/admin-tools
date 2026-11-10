# Define the path to the executable
$exePath = "C:\Windows\SysWOW64\rserver30\rserver3.exe"

# Define the license key
$key = "xxx"

# Get the computer name
$computerName = $env:COMPUTERNAME

# Define the output request file path
$requestFilePath = "C:\FAS\$computerName.request"

# Ensure the output directory exists
$dir = [System.IO.Path]::GetDirectoryName($requestFilePath)
if (-not (Test-Path $dir)) {
    New-Item -Path $dir -ItemType Directory -Force | Out-Null
}

# Build the argument list
$args = "/saverequest /key:$key /requestfile:`"$requestFilePath`""

# Execute the command
Start-Process -FilePath $exePath -ArgumentList $args -Wait -NoNewWindow
