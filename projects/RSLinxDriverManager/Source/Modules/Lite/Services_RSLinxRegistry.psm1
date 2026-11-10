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

# ---------------------------------------------------------------------------
#  The PowerShell a change amounts to, for the command window (Base\Services_Commands)
# ---------------------------------------------------------------------------
# Same keys, values and IPs that Invoke-RSLinxApplyPlan / Remove-RSLinxDriverNodes
# write (they do it through the .NET registry API in the 32-bit view; this is the
# registry-provider equivalent you could run by hand, elevated).
#   Get-RSLinxPlanCommandText   -Plan $plan [-BackupNote 'text']
#   Get-RSLinxRemoveCommandText -Targets @(@{ Key; IP }) -Current (Get-RSLinxDrivers) [-BackupNote 'text']

function Get-RSLinxRegistryRoot {
    $base = $(if ([Environment]::Is64BitOperatingSystem) { 'HKLM:\SOFTWARE\WOW6432Node' } else { 'HKLM:\SOFTWARE' })
    return ($base + '\Rockwell Software\RSLinx\Drivers\AB_ETH')
}

function Get-RSLinxCommandPreamble {
    param([string]$BackupNote)
    $q = { param($v) "'" + ([string]$v).Replace("'", "''") + "'" }
    $l = New-Object System.Collections.Generic.List[string]
    $l.Add('# Run elevated. RSLinx Classic Ethernet (AB_ETH) drivers, 32-bit registry view.')
    if ($BackupNote) { $l.Add("# $BackupNote") }
    $l.Add('$root = ' + (& $q (Get-RSLinxRegistryRoot)))
    $l.Add('function Set-NodeTable([string]$Key, [string[]]$IPs) {   # replaces the numbered IP values')
    $l.Add('    $nt = "$root\$Key\Node Table"')
    $l.Add('    if (-not (Test-Path $nt)) { New-Item -Path $nt -Force | Out-Null }')
    $l.Add("    (Get-Item -Path `$nt).Property | Where-Object { `$_ -match '^\d+$' } | ForEach-Object { Remove-ItemProperty -Path `$nt -Name `$_ }")
    $l.Add('    for ($i = 0; $i -lt $IPs.Count; $i++) { New-ItemProperty -Path $nt -Name "$i" -Value $IPs[$i] -PropertyType String -Force | Out-Null }')
    $l.Add('}')
    return $l
}

function Format-RSLinxIpList {
    param([string[]]$IPs)
    return '@(' + ((@($IPs) | ForEach-Object { "'" + ([string]$_).Replace("'", "''") + "'" }) -join ', ') + ')'
}

function Get-RSLinxPlanCommandText {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Plan, [string]$BackupNote = '')
    $q = { param($v) "'" + ([string]$v).Replace("'", "''") + "'" }
    $l = Get-RSLinxCommandPreamble -BackupNote $BackupNote
    foreach ($k in @($Plan.DeleteKeys)) { $l.Add('Remove-Item -Path "$root\' + $k + '" -Recurse -Force') }
    foreach ($it in @($Plan.Items)) {
        if ($it.IsNew) {
            $l.Add('New-Item -Path "$root\' + $it.Key + '" -Force | Out-Null   # new driver ' + $it.Name)
            $l.Add('New-ItemProperty -Path "$root\' + $it.Key + '" -Name Name -Value ' + (& $q $it.Name) + ' -PropertyType String -Force | Out-Null')
            foreach ($v in @(@('Startup', '0'), @('Station', '0x3f'), @('Inactivity Timeout', '0x1e'), @('Ping Timeout', '6'))) {
                $l.Add('New-ItemProperty -Path "$root\' + $it.Key + '" -Name ' + (& $q $v[0]) + ' -Value ' + $v[1] + ' -PropertyType DWord -Force | Out-Null')
            }
        }
        else { $l.Add('# ' + $it.Key + ' (' + $it.Name + '): +' + $it.Added + ' IP(s)') }
        $l.Add('Set-NodeTable ' + (& $q $it.Key) + ' ' + (Format-RSLinxIpList $it.Nodes))
    }
    $l.Add('# Restart RSLinx (or the PC) to load the changed drivers.')
    return ($l -join "`r`n")
}

function Get-RSLinxRemoveCommandText {
    [CmdletBinding()]
    param([AllowEmptyCollection()] [object[]]$Targets = @(), [AllowEmptyCollection()] [object[]]$Current = @(), [string]$BackupNote = '')
    $q = { param($v) "'" + ([string]$v).Replace("'", "''") + "'" }
    $byKey = @{}
    foreach ($t in $Targets) {
        $k = [string]$t.Key; if ($k -eq '') { continue }
        if (-not $byKey.ContainsKey($k)) { $byKey[$k] = @{} }
        $byKey[$k][[string]$t.IP] = $true
    }
    $l = Get-RSLinxCommandPreamble -BackupNote $BackupNote
    foreach ($c in $Current) {
        if (-not $byKey.ContainsKey($c.Key)) { continue }
        $drop = $byKey[$c.Key]
        $keep = @($c.Nodes | Where-Object { -not $drop.ContainsKey([string]$_) })
        if ($keep.Count -eq 0) { $l.Add('Remove-Item -Path "$root\' + $c.Key + '" -Recurse -Force   # ' + $c.Name + ': no IPs left') }
        else { $l.Add('Set-NodeTable ' + (& $q $c.Key) + ' ' + (Format-RSLinxIpList $keep) + '   # ' + $c.Name + ': -' + (@($c.Nodes).Count - $keep.Count) + ' IP(s)') }
    }
    $l.Add('# Restart RSLinx (or the PC) to load the changed drivers.')
    return ($l -join "`r`n")
}
