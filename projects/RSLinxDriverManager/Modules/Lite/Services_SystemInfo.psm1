# Services_SystemInfo.psm1   (LITE TIER)
#
# Facts about this PC for the RSLinx tab.
#
#   Get-InstalledSoftwareVersion -DisplayName 'RSLogix 500'   -> '12.00' / '9.05, 10.00' / 'Not found'
#   Get-RSLinxSystemInfo                                       -> ordered @{ Label = Value }

function Get-InstalledSoftwareVersion {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$DisplayName, [string]$Exclude = '')
    $versions = New-Object System.Collections.Generic.List[string]
    try {
        $paths = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                   'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*')
        foreach ($p in $paths) {
            foreach ($item in @(Get-ItemProperty $p -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -and $_.DisplayName -like "*$DisplayName*" })) {
                if ($Exclude -and $item.DisplayName -match $Exclude) { continue }
                if (-not $item.DisplayVersion) { continue }
                $parts = ([string]$item.DisplayVersion) -split '\.'
                $mm = $(if ($parts.Count -ge 2) { "$($parts[0]).$($parts[1])" } else { [string]$item.DisplayVersion })
                if (-not $versions.Contains($mm)) { $versions.Add($mm) }
            }
        }
    } catch { }
    if ($versions.Count -eq 0) { return 'Not found' }
    return (($versions | Sort-Object) -join ', ')
}

function Get-RSLinxSystemInfo {
    [CmdletBinding()]
    param()
    $ip = ''
    try {
        $ip = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop | Where-Object {
            $_.InterfaceAlias -notlike '*Loopback*' -and $_.InterfaceAlias -notlike '*Hyper-V*' -and
            $_.InterfaceAlias -notlike '*vEthernet*' -and $_.IPAddress -notlike '169.254.*' } |
            Select-Object -ExpandProperty IPAddress) -join ', '
    } catch { }
    if (-not $ip) { $ip = 'Not found' }

    $svc = 'Not installed'
    try {
        $s = Get-Service -Name 'RSLinx' -ErrorAction Stop
        $svc = [string]$s.Status
    } catch { }

    $admin = $(if (Test-RSLinxAdministrator) { 'Yes' } else { 'No - driver changes need Run as administrator' })

    return [ordered]@{
        'Computer'          = $env:COMPUTERNAME
        'IP address'        = $ip
        'Administrator'     = $admin
        'RSLinx service'    = $svc
        'RSLinx Classic'    = (Get-InstalledSoftwareVersion -DisplayName 'RSLinx Classic')
        'RSLogix 5'         = (Get-InstalledSoftwareVersion -DisplayName 'RSLogix 5' -Exclude '500|5000')
        'RSLogix 500'       = (Get-InstalledSoftwareVersion -DisplayName 'RSLogix 500' -Exclude '5000')
        'RSLogix 5000'      = (Get-InstalledSoftwareVersion -DisplayName 'RSLogix 5000')
        'Studio 5000 Logix' = (Get-InstalledSoftwareVersion -DisplayName 'Studio 5000 Logix')
    }
}
