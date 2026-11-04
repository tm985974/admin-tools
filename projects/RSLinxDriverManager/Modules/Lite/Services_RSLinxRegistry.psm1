# Services_RSLinxRegistry.psm1   (LITE TIER)
#
# Reads and writes RSLinx Classic Ethernet (AB_ETH) drivers in the registry:
#   HKLM\SOFTWARE\WOW6432Node\Rockwell Software\RSLinx\Drivers\AB_ETH\AB_ETH-<n>
#       Name = 'BL(25)SCADA', Startup, Station, Inactivity Timeout, Ping Timeout
#       \Node Table   "0" = "137.206.25.10", "1" = ...
# (opened through the 32-bit registry view, so the path is right on 32- and
# 64-bit Windows). Writing needs an elevated (Run as administrator) process.
#
#   Test-RSLinxAdministrator                      -> $true when elevated
#   Get-RSLinxDrivers                             -> @( @{ Key; Number; Name; Nodes = string[] } )
#   New-RSLinxApplyPlan -Current $d -Entries $e -Mode Add|Overwrite
#        $e = objects with Driver + IP. Returns
#        @{ Mode; Items = @( @{ Key; Name; Nodes; Added; IsNew } ); DeleteKeys; NewDrivers;
#           ExtendedDrivers; AddedIPs; SkippedIPs }
#        Add       keeps every driver; an IP goes into the existing driver of the same
#                  name (case-insensitive) or into a new AB_ETH-<next> driver.
#        Overwrite deletes every AB_ETH-<n> driver and writes the entries as AB_ETH-1..n.
#   Invoke-RSLinxApplyPlan -Plan $plan            -> writes it (throws on the first failure)
#   Remove-RSLinxDriverNodes -Targets @(@{ Key; IP }, ...)
#        removes those IPs; a driver left with no IPs is deleted. Returns counts.

$script:AbEthSubKey = 'SOFTWARE\Rockwell Software\RSLinx\Drivers\AB_ETH'

function Test-RSLinxAdministrator {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

function Open-RSLinxAbEthKey {
    param([bool]$Writable = $false)
    $hklm = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry32)
    if ($Writable) { return $hklm.CreateSubKey($script:AbEthSubKey) }
    return $hklm.OpenSubKey($script:AbEthSubKey, $false)
}

function Get-RSLinxDrivers {
    [CmdletBinding()]
    param()
    $key = Open-RSLinxAbEthKey -Writable $false
    if ($null -eq $key) { return @() }
    try {
        $list = foreach ($sub in $key.GetSubKeyNames()) {
            $num = 0
            if ($sub -match '^AB_ETH-(\d+)$') { $num = [int]$Matches[1] }
            $dk = $key.OpenSubKey($sub, $false)
            if ($null -eq $dk) { continue }
            try {
                $name = [string]$dk.GetValue('Name', '')
                $nodes = @()
                $nt = $dk.OpenSubKey('Node Table', $false)
                if ($nt) {
                    try {
                        $nodes = @($nt.GetValueNames() | Where-Object { $_ -match '^\d+$' } | Sort-Object { [int]$_ } |
                                   ForEach-Object { [string]$nt.GetValue($_, '') } | Where-Object { $_ -ne '' })
                    } finally { $nt.Close() }
                }
                [pscustomobject]@{ Key = $sub; Number = $num; Name = $name; Nodes = $nodes }
            } finally { $dk.Close() }
        }
        return @($list | Sort-Object Number, Key)
    } finally { $key.Close() }
}

function Get-SortedIPv4List([string[]]$IPs) {
    return @($IPs | Sort-Object { $n = ConvertTo-IPv4Number -IP $_; if ($null -eq $n) { [double]::MaxValue } else { [double]$n } })
}

function New-RSLinxApplyPlan {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()] [object[]]$Current = @(),
        [AllowEmptyCollection()] [object[]]$Entries = @(),
        [ValidateSet('Add', 'Overwrite')] [string]$Mode = 'Add'
    )
    # wanted: driver name (as first written) -> ordered unique IPs
    $wanted = [ordered]@{}
    $display = @{}
    foreach ($e in $Entries) {
        $n = ([string]$e.Driver).Trim(); $ip = ([string]$e.IP).Trim()
        if ($n -eq '' -or $ip -eq '') { continue }
        $k = $n.ToUpperInvariant()
        if (-not $wanted.Contains($k)) { $wanted[$k] = New-Object System.Collections.Generic.List[string]; $display[$k] = $n }
        if (-not $wanted[$k].Contains($ip)) { $wanted[$k].Add($ip) }
    }

    $items = New-Object System.Collections.ArrayList
    $deleteKeys = @(); $newDrivers = 0; $extended = 0; $added = 0; $skipped = 0

    if ($Mode -eq 'Overwrite') {
        $deleteKeys = @($Current | Where-Object { $_.Key -match '^AB_ETH-\d+$' } | ForEach-Object { $_.Key })
        $i = 1
        foreach ($k in @($wanted.Keys | Sort-Object)) {
            $nodes = Get-SortedIPv4List $wanted[$k].ToArray()
            [void]$items.Add([pscustomobject]@{ Key = "AB_ETH-$i"; Name = $display[$k]; Nodes = $nodes; Added = $nodes.Count; IsNew = $true })
            $i++; $newDrivers++; $added += $nodes.Count
        }
    }
    else {
        $byName = @{}
        foreach ($c in $Current) { $ck = ([string]$c.Name).Trim().ToUpperInvariant(); if ($ck -ne '' -and -not $byName.ContainsKey($ck)) { $byName[$ck] = $c } }
        $next = 1 + [int](@($Current | ForEach-Object { [int]$_.Number }) + 0 | Measure-Object -Maximum).Maximum
        foreach ($k in @($wanted.Keys | Sort-Object)) {
            if ($byName.ContainsKey($k)) {
                $c = $byName[$k]
                $have = @{}; foreach ($ip in @($c.Nodes)) { $have[[string]$ip] = $true }
                $new = @($wanted[$k] | Where-Object { -not $have.ContainsKey($_) })
                $skipped += ($wanted[$k].Count - $new.Count)
                if ($new.Count -eq 0) { continue }
                $nodes = Get-SortedIPv4List (@($c.Nodes) + $new)
                [void]$items.Add([pscustomobject]@{ Key = $c.Key; Name = $c.Name; Nodes = $nodes; Added = $new.Count; IsNew = $false })
                $extended++; $added += $new.Count
            }
            else {
                $nodes = Get-SortedIPv4List $wanted[$k].ToArray()
                [void]$items.Add([pscustomobject]@{ Key = "AB_ETH-$next"; Name = $display[$k]; Nodes = $nodes; Added = $nodes.Count; IsNew = $true })
                $next++; $newDrivers++; $added += $nodes.Count
            }
        }
    }
    return [pscustomobject]@{
        Mode = $Mode; Items = $items.ToArray(); DeleteKeys = $deleteKeys
        NewDrivers = $newDrivers; ExtendedDrivers = $extended; AddedIPs = $added; SkippedIPs = $skipped
    }
}

function Write-RSLinxNodeTable {
    param([Microsoft.Win32.RegistryKey]$DriverKey, [string[]]$Nodes)
    $nt = $DriverKey.CreateSubKey('Node Table')
    try {
        foreach ($v in @($nt.GetValueNames() | Where-Object { $_ -match '^\d+$' })) { $nt.DeleteValue($v, $false) }
        $i = 0
        foreach ($ip in $Nodes) { $nt.SetValue([string]$i, [string]$ip, [Microsoft.Win32.RegistryValueKind]::String); $i++ }
    } finally { $nt.Close() }
}

function Invoke-RSLinxApplyPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Plan)
    $root = Open-RSLinxAbEthKey -Writable $true
    if ($null -eq $root) { throw "Cannot open HKLM\$($script:AbEthSubKey) for writing." }
    try {
        foreach ($k in @($Plan.DeleteKeys)) { $root.DeleteSubKeyTree($k, $false) }
        foreach ($it in @($Plan.Items)) {
            $dk = $root.CreateSubKey($it.Key)
            try {
                if ($it.IsNew) {
                    $dk.SetValue('Name', [string]$it.Name, [Microsoft.Win32.RegistryValueKind]::String)
                    $dk.SetValue('Startup', 0, [Microsoft.Win32.RegistryValueKind]::DWord)
                    $dk.SetValue('Station', 0x3f, [Microsoft.Win32.RegistryValueKind]::DWord)
                    $dk.SetValue('Inactivity Timeout', 0x1e, [Microsoft.Win32.RegistryValueKind]::DWord)
                    $dk.SetValue('Ping Timeout', 6, [Microsoft.Win32.RegistryValueKind]::DWord)
                }
                Write-RSLinxNodeTable -DriverKey $dk -Nodes @($it.Nodes)
            } finally { $dk.Close() }
        }
    } finally { $root.Close() }
}

function Remove-RSLinxDriverNodes {
    [CmdletBinding()]
    param([AllowEmptyCollection()] [object[]]$Targets = @())
    $byKey = @{}
    foreach ($t in $Targets) {
        $k = [string]$t.Key; if ($k -eq '') { continue }
        if (-not $byKey.ContainsKey($k)) { $byKey[$k] = @{} }
        $byKey[$k][[string]$t.IP] = $true
    }
    $current = @(Get-RSLinxDrivers)
    $root = Open-RSLinxAbEthKey -Writable $true
    $removedIPs = 0; $removedDrivers = 0
    try {
        foreach ($c in $current) {
            if (-not $byKey.ContainsKey($c.Key)) { continue }
            $drop = $byKey[$c.Key]
            $keep = @($c.Nodes | Where-Object { -not $drop.ContainsKey([string]$_) })
            $removedIPs += (@($c.Nodes).Count - $keep.Count)
            if ($keep.Count -eq 0) { $root.DeleteSubKeyTree($c.Key, $false); $removedDrivers++ }
            else {
                $dk = $root.OpenSubKey($c.Key, $true)
                try { Write-RSLinxNodeTable -DriverKey $dk -Nodes $keep } finally { $dk.Close() }
            }
        }
    } finally { $root.Close() }
    return [pscustomobject]@{ RemovedIPs = $removedIPs; RemovedDrivers = $removedDrivers }
}
