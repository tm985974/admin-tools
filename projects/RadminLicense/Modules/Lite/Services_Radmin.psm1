# Services_Radmin.psm1   (LITE TIER)
#
# Radmin Server 3 offline licensing - the logic behind the This Machine and
# Fleet tabs. No UI here.
#
# The licensing round trip (the device never touches the internet):
#   1. On the unlicensed device:  rserver3.exe /saverequest  ->  <COMPUTERNAME>.request
#   2. The .request file is carried to an internet PC and uploaded to
#      https://activate.famatech.com/ ; the site returns <COMPUTERNAME>.license
#   3. The .license file is carried back:  rserver3.exe /uselicense  on the device
#   Licensed = the registry key  HKLM\SOFTWARE\WOW6432Node\Radmin\v3.0\Shared\
#   Parameters\XferParam\2  exists (no key = unlicensed).
#
# Transfer folder (USB stick or share - the one thing that crosses the air gap):
#   <Transfer>\Requests\<NAME>.request     outstanding requests (upload these)
#   <Transfer>\Requests\_requests.csv      what was collected, when, from where
#   <Transfer>\Licenses\<NAME>.license     licenses from the website (save them here)
#   <Transfer>\Done\                       request + license once a machine is licensed
#   <Transfer>\README-ACTIVATION.txt       steps for whoever does the website part
#
# $script:RadminCore is ONE self-contained script block used both locally
# (in-process) and remotely (Invoke-Command over WinRM), so a single device and
# a whole fleet go through exactly the same code. It depends on nothing in the
# app; everything it needs arrives in -Opt.
#
#   Get-RadminSettings      -App            the active environment's Radmin settings (+ defaults)
#   Get-RadminTransferFolder / Set-RadminTransferFolder -App   (per-machine override, e.g. a USB letter)
#   Get-RadminTransferPaths -App            Root / Requests / Licenses / Done (created)
#   New-RadminOptions       -Settings -Action [-LicenseBytes] [-ExpectedName]
#   Invoke-RadminLocal      -Action -Opt    run the core on this machine
#   Test-RadminLocalTarget  -Name           is this name this machine?
#   Save-RadminRequestFile  -App -Result -Source
#   Find-RadminLicenseFile  -App -Names     <Transfer>\Licenses\<name>.license (or the root)
#   Complete-RadminTransfer -App -Computer  move request + license to Done\
#   Get-RadminTransferState -App -Names     request / license present?
#   Get-/Save-RadminFleet   -App            the machine list + last results (per environment)
#   Test-RadminElevated
#   Get-RadminApi                           the above as script blocks, for UI closures

$script:RadminDefaults = [ordered]@{
    LicenseKey       = ''
    TransferFolder   = ''
    DeviceFolder     = 'C:\FAS'
    RserverPath      = ''
    LicensedRegKey   = 'SOFTWARE\WOW6432Node\Radmin\v3.0\Shared\Parameters\XferParam\2'
    SaveRequestArgs  = '/saverequest /key:{Key} /requestfile:"{File}"'
    UseLicenseArgs   = '/uselicense /licensefile:"{File}"'
    CallTimeoutSec   = 60
    ParallelMachines = 16
}

# The two scripts this replaces disagreed on the syntax (/requestfile:"x" vs
# /requestfile"x"). The configured form is tried first; if it does not produce
# the file (request) or the registry key (license), these are tried next.
$script:RadminFallbackSave    = @('/saverequest /key:{Key} /requestfile:"{File}"', '/saverequest /key:{Key} /requestfile"{File}"')
$script:RadminFallbackLicense = @('/uselicense /licensefile:"{File}"', '/uselicense /licensefile"{File}"')

# ---------------------------------------------------------------------------
# The core: runs on the target machine (locally, or remotely via WinRM)
# ---------------------------------------------------------------------------
#   Action  Status   - is Radmin Server there, is it licensed
#           Request  - unlicensed: make <COMPUTERNAME>.request, return its bytes
#           License  - write the .license, apply it, check the registry key
#   Opt     RegKey, ExePath, DeviceFolder, Key, SaveArgs[], LicenseArgs[],
#           TimeoutSec, LicenseBytes, ExpectedName, Force
$script:RadminCore = {
    param([string]$Action, [hashtable]$Opt)
    $ErrorActionPreference = 'Stop'
    $r = [ordered]@{
        Action = $Action; Computer = [string]$env:COMPUTERNAME; Ok = $false; Skipped = $false
        RadminFound = $false; ExePath = ''; Licensed = $null; Elevated = $false
        Message = ''; FileBytes = $null; ArgsUsed = ''; ExitCode = $null
        Time = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    }
    try {
        try {
            $id = [Security.Principal.WindowsIdentity]::GetCurrent()
            $r.Elevated = (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        } catch { }

        # ---- licensed = the registry key exists ----
        $regPath = (([string]$Opt.RegKey) -replace '(?i)^(HKLM:?\\|HKEY_LOCAL_MACHINE\\)', '').Trim('\')
        $testLicensed = {
            $checks = @()
            $v64 = $(if ([Environment]::Is64BitOperatingSystem) { [Microsoft.Win32.RegistryView]::Registry64 } else { [Microsoft.Win32.RegistryView]::Default })
            $checks += ,@($v64, $regPath)
            $checks += ,@([Microsoft.Win32.RegistryView]::Registry32, ($regPath -replace '(?i)\\WOW6432Node\\', '\'))
            foreach ($c in $checks) {
                $base = $null
                try {
                    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, $c[0])
                    $k = $base.OpenSubKey([string]$c[1])
                    if ($k) { $k.Close(); return $true }
                    # "XferParam\2" could also be a VALUE named 2 under XferParam
                    $cut = ([string]$c[1]).LastIndexOf('\')
                    if ($cut -gt 0) {
                        $p = $base.OpenSubKey(([string]$c[1]).Substring(0, $cut))
                        if ($p) {
                            $has = @($p.GetValueNames()) -contains ([string]$c[1]).Substring($cut + 1)
                            $p.Close()
                            if ($has) { return $true }
                        }
                    }
                }
                catch { }
                finally { if ($base) { $base.Close() } }
            }
            return $false
        }

        # ---- rserver3.exe ----
        $cands = @()
        if ([string]$Opt.ExePath) { $cands += [Environment]::ExpandEnvironmentVariables([string]$Opt.ExePath) }
        $cands += (Join-Path $env:windir 'SysWOW64\rserver30\rserver3.exe')
        $cands += (Join-Path $env:windir 'System32\rserver30\rserver3.exe')
        foreach ($c in $cands) { if ($c -and (Test-Path -LiteralPath $c -PathType Leaf)) { $r.ExePath = $c; break } }
        $r.RadminFound = [bool]$r.ExePath
        $r.Licensed = [bool](& $testLicensed)

        $run = {
            param([string]$exe, [string]$argLine, [int]$sec)
            $psi = New-Object System.Diagnostics.ProcessStartInfo($exe, $argLine)
            $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
            $p = [System.Diagnostics.Process]::Start($psi)
            if (-not $p.WaitForExit([Math]::Max(5, $sec) * 1000)) { try { $p.Kill() } catch { }; return -999 }
            return $p.ExitCode
        }
        $fill = {
            param([string]$tpl, [string]$file)
            return $tpl.Replace('{Key}', [string]$Opt.Key).Replace('{File}', $file)
        }
        $folder = $(if ([string]$Opt.DeviceFolder) { [Environment]::ExpandEnvironmentVariables([string]$Opt.DeviceFolder) } else { 'C:\FAS' })
        $sec = $(if ([int]$Opt.TimeoutSec -gt 0) { [int]$Opt.TimeoutSec } else { 60 })

        switch ($Action) {
            'Status' {
                $r.Ok = $true
                $r.Message = $(if (-not $r.RadminFound) { 'Radmin Server 3 not found.' } elseif ($r.Licensed) { 'Licensed.' } else { 'Not licensed.' })
            }

            'Request' {
                if (-not $r.RadminFound) { $r.Message = 'Radmin Server 3 (rserver3.exe) not found - nothing to license.'; break }
                if ($r.Licensed -and -not $Opt.Force) { $r.Ok = $true; $r.Skipped = $true; $r.Message = 'Already licensed - no request made.'; break }
                if (-not [string]$Opt.Key) { $r.Message = 'No license key set (Environment > Radmin).'; break }
                if (-not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }
                $file = Join-Path $folder ($env:COMPUTERNAME + '.request')
                if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force }    # so a fresh file proves it worked
                $tried = @()
                foreach ($tpl in @($Opt.SaveArgs)) {
                    if (-not $tpl) { continue }
                    $tried += $tpl
                    $r.ExitCode = & $run $r.ExePath (& $fill $tpl $file) $sec
                    if ((Test-Path -LiteralPath $file) -and (Get-Item -LiteralPath $file).Length -gt 0) { $r.ArgsUsed = $tpl; break }
                }
                if ($r.ArgsUsed) {
                    $r.FileBytes = [System.IO.File]::ReadAllBytes($file)
                    $r.Ok = $true
                    $r.Message = "Request saved ($($r.FileBytes.Length) bytes)."
                }
                else {
                    $why = $(if ($r.ExitCode -eq -999) { "timed out after $sec s" } else { "exit code $($r.ExitCode)" })
                    $r.Message = "rserver3 did not write the request file ($why). Tried: " + ($tried -join ' | ')
                }
            }

            'License' {
                if (-not $r.RadminFound) { $r.Message = 'Radmin Server 3 (rserver3.exe) not found.'; break }
                if ($Opt.ExpectedName -and ([string]$Opt.ExpectedName -ne [string]$env:COMPUTERNAME)) {
                    $r.Message = "This license file is for '$($Opt.ExpectedName)', but this machine is '$env:COMPUTERNAME' - not applied."; break
                }
                if ($r.Licensed -and -not $Opt.Force) { $r.Ok = $true; $r.Skipped = $true; $r.Message = 'Already licensed - license not applied again.'; break }
                $bytes = [byte[]]$Opt.LicenseBytes
                if (-not $bytes -or $bytes.Length -eq 0) { $r.Message = 'The license file is empty.'; break }
                if (-not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }
                $file = Join-Path $folder ($env:COMPUTERNAME + '.license')
                [System.IO.File]::WriteAllBytes($file, $bytes)
                $tried = @()
                foreach ($tpl in @($Opt.LicenseArgs)) {
                    if (-not $tpl) { continue }
                    $tried += $tpl
                    $r.ExitCode = & $run $r.ExePath (& $fill $tpl $file) $sec
                    for ($i = 0; $i -lt 5 -and -not (& $testLicensed); $i++) { Start-Sleep -Milliseconds 600 }
                    if (& $testLicensed) { $r.ArgsUsed = $tpl; break }
                }
                $r.Licensed = [bool](& $testLicensed)
                if ($r.Licensed) { $r.Ok = $true; $r.Message = 'License applied - machine is licensed.' }
                else {
                    $why = $(if ($r.ExitCode -eq -999) { "timed out after $sec s" } else { "exit code $($r.ExitCode)" })
                    $r.Message = "License applied but the licensed registry key did not appear ($why). Wrong machine or wrong file? Tried: " + ($tried -join ' | ')
                }
            }

            default { $r.Message = "Unknown action '$Action'." }
        }
        if (-not $r.Ok -and -not $r.Elevated -and $Action -ne 'Status') { $r.Message += ' (Not running as administrator.)' }
    }
    catch { $r.Ok = $false; $r.Message = 'Error: ' + $_.Exception.Message }
    return [pscustomobject]$r
}

# ---------------------------------------------------------------------------
# App side
# ---------------------------------------------------------------------------

function Get-RadminSettings {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $App)
    $s = [ordered]@{}
    foreach ($k in $script:RadminDefaults.Keys) {
        $v = $script:RadminDefaults[$k]
        try { $v = Get-AppEnvironmentValue -App $App -Key ('Radmin' + $k) -Default $script:RadminDefaults[$k] } catch { }
        $s[$k] = $v
    }
    $n = 0
    if (-not [int]::TryParse([string]$s.CallTimeoutSec, [ref]$n) -or $n -lt 10) { $n = 60 };  $s.CallTimeoutSec = $n
    $n = 0
    if (-not [int]::TryParse([string]$s.ParallelMachines, [ref]$n) -or $n -lt 1) { $n = 16 }; $s.ParallelMachines = [Math]::Min($n, 64)
    return [pscustomobject]$s
}

function Get-RadminDefaults { return $script:RadminDefaults }

# Per-machine override of the transfer folder (a USB stick gets a different
# drive letter on every PC). Kept in LOCAL AppData, never on the shared path.
function Get-RadminLocalPrefsPath {
    param([Parameter(Mandatory)] $App)
    $d = Join-Path ([string]$App.LocalAppData) 'Settings'
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    return (Join-Path $d 'RadminLocal.json')
}

function Get-RadminTransferFolder {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $App)
    try {
        $p = Get-RadminLocalPrefsPath -App $App
        if (Test-Path -LiteralPath $p) {
            $j = Get-Content -LiteralPath $p -Raw | ConvertFrom-Json
            $key = [string]$App.ActiveName
            if ($j.TransferFolder -and $j.TransferFolder.$key) { return [string]$j.TransferFolder.$key }
        }
    } catch { }
    $s = Get-RadminSettings -App $App
    if ([string]$s.TransferFolder) { return [Environment]::ExpandEnvironmentVariables([string]$s.TransferFolder) }
    return (Join-Path ([string]$App.DataRoot) 'Transfer')
}

function Set-RadminTransferFolder {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $App, [AllowEmptyString()] [string]$Path)
    $p = Get-RadminLocalPrefsPath -App $App
    $o = @{ TransferFolder = @{} }
    try {
        if (Test-Path -LiteralPath $p) {
            $j = Get-Content -LiteralPath $p -Raw | ConvertFrom-Json
            if ($j.TransferFolder) { foreach ($pr in $j.TransferFolder.PSObject.Properties) { $o.TransferFolder[$pr.Name] = [string]$pr.Value } }
        }
    } catch { }
    $key = [string]$App.ActiveName
    if ($Path.Trim()) { $o.TransferFolder[$key] = $Path.Trim() } else { [void]$o.TransferFolder.Remove($key) }
    ($o | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $p -Encoding UTF8
}

function Get-RadminTransferPaths {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $App, [switch]$NoCreate)
    $root = Get-RadminTransferFolder -App $App
    $t = [pscustomobject]@{
        Root     = $root
        Requests = Join-Path $root 'Requests'
        Licenses = Join-Path $root 'Licenses'
        Done     = Join-Path $root 'Done'
        Ok       = $false
        Error    = ''
    }
    if ($NoCreate) { $t.Ok = (Test-Path -LiteralPath $root); return $t }
    try {
        foreach ($d in @($t.Requests, $t.Licenses, $t.Done)) {
            if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force -ErrorAction Stop | Out-Null }
        }
        Write-RadminTransferReadme -Root $root
        $t.Ok = $true
    }
    catch { $t.Error = "Transfer folder '$root' is not usable: $($_.Exception.Message)" }
    return $t
}

function Write-RadminTransferReadme {
    param([Parameter(Mandatory)] [string]$Root)
    $p = Join-Path $Root 'README-ACTIVATION.txt'
    if (Test-Path -LiteralPath $p) { return }
    $txt = @(
        'Radmin Server 3 - offline activation (transfer folder)'
        '======================================================'
        ''
        'Requests\   one <MACHINE>.request per unlicensed machine. _requests.csv lists them.'
        'Licenses\   put the downloaded <MACHINE>.license files here.'
        'Done\       request + license of machines that are licensed (kept for reference).'
        ''
        'On a PC with internet access:'
        '  1. Open https://activate.famatech.com/'
        '  2. Upload each file from Requests\ (one at a time if the site asks).'
        '  3. Save each .license the site returns into Licenses\'
        '     Keep the name: <MACHINE>.license - the same name as its .request.'
        '  4. Carry this folder back to the air-gapped network and run'
        '     "Apply licenses" (Fleet tab) or "Apply license" (This Machine tab).'
    ) -join "`r`n"
    try { Set-Content -LiteralPath $p -Value $txt -Encoding ASCII } catch { }
}

function New-RadminOptions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Settings,
        [Parameter(Mandatory)] [ValidateSet('Status', 'Request', 'License')] [string]$Action,
        [byte[]]$LicenseBytes = $null,
        [string]$ExpectedName = '',
        [switch]$Force
    )
    $save = @([string]$Settings.SaveRequestArgs) + $script:RadminFallbackSave | Where-Object { $_ } | Select-Object -Unique
    $lic  = @([string]$Settings.UseLicenseArgs)  + $script:RadminFallbackLicense | Where-Object { $_ } | Select-Object -Unique
    return @{
        RegKey       = [string]$Settings.LicensedRegKey
        ExePath      = [string]$Settings.RserverPath
        DeviceFolder = [string]$Settings.DeviceFolder
        Key          = $(if ($Action -eq 'Request') { [string]$Settings.LicenseKey } else { '' })   # the key only travels when needed
        SaveArgs     = @($save)
        LicenseArgs  = @($lic)
        TimeoutSec   = [int]$Settings.CallTimeoutSec
        LicenseBytes = $LicenseBytes
        ExpectedName = $ExpectedName
        Force        = [bool]$Force
    }
}

function Get-RadminCore { return $script:RadminCore }

function Invoke-RadminLocal {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Action, [Parameter(Mandatory)] [hashtable]$Opt)
    return (& $script:RadminCore $Action $Opt)
}

function Test-RadminLocalTarget {
    [CmdletBinding()]
    param([string]$Name)
    $n = ([string]$Name).Trim().ToLowerInvariant()
    if ($n -in @('', '.', 'localhost', '127.0.0.1', '::1')) { return $true }
    $me = ([string]$env:COMPUTERNAME).ToLowerInvariant()
    return ($n -eq $me -or $n.Split('.')[0] -eq $me)
}

function Test-RadminElevated {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

# A request result from the core -> <Transfer>\Requests\<COMPUTER>.request (+ _requests.csv)
function Save-RadminRequestFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $App, [Parameter(Mandatory)] $Result, [string]$Source = '')
    $t = Get-RadminTransferPaths -App $App
    if (-not $t.Ok) { throw $t.Error }
    $bytes = [byte[]]$Result.FileBytes
    if (-not $bytes -or $bytes.Length -eq 0) { throw 'No request data to save.' }
    $name = ([string]$Result.Computer).ToUpperInvariant()
    $path = Join-Path $t.Requests ($name + '.request')
    [System.IO.File]::WriteAllBytes($path, $bytes)

    $csv = Join-Path $t.Requests '_requests.csv'
    $rows = New-Object System.Collections.ArrayList
    try { if (Test-Path -LiteralPath $csv) { foreach ($r in @(Import-Csv -LiteralPath $csv)) { if ($r.Computer -ne $name) { [void]$rows.Add($r) } } } } catch { }
    [void]$rows.Add([pscustomobject]@{ Computer = $name; Created = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); Source = $Source; File = ($name + '.request') })
    try { @($rows | Sort-Object Computer) | Export-Csv -LiteralPath $csv -NoTypeInformation -Encoding UTF8 } catch { }
    return $path
}

# The .license for the first of -Names found in Licenses\, then the transfer root.
function Find-RadminLicenseFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $App, [string[]]$Names, $Paths = $null)
    $t = $(if ($Paths) { $Paths } else { Get-RadminTransferPaths -App $App -NoCreate })
    if (-not $t.Ok) { return '' }
    $tried = @{}
    foreach ($n in @($Names)) {
        foreach ($cand in @(([string]$n).Trim(), ([string]$n).Trim().Split('.')[0])) {
            if (-not $cand -or $tried.ContainsKey($cand.ToLowerInvariant())) { continue }
            $tried[$cand.ToLowerInvariant()] = $true
            foreach ($dir in @($t.Licenses, $t.Root)) {
                $p = Join-Path $dir ($cand + '.license')
                if (Test-Path -LiteralPath $p -PathType Leaf) { return $p }
            }
        }
    }
    return ''
}

# Request + license present in the transfer folder for these names?
function Get-RadminTransferState {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $App, [string[]]$Names, $Paths = $null)
    $t = $(if ($Paths) { $Paths } else { Get-RadminTransferPaths -App $App -NoCreate })
    $req = ''
    if ($t.Ok) {
        foreach ($n in @($Names)) {
            $short = ([string]$n).Trim().Split('.')[0]
            if (-not $short) { continue }
            $p = Join-Path $t.Requests ($short + '.request')
            if (Test-Path -LiteralPath $p) { $req = (Get-Item -LiteralPath $p).LastWriteTime.ToString('yyyy-MM-dd HH:mm'); break }
        }
    }
    $lic = Find-RadminLicenseFile -App $App -Names $Names -Paths $t
    return [pscustomobject]@{
        Request = $req
        License = $(if ($lic) { (Get-Item -LiteralPath $lic).LastWriteTime.ToString('yyyy-MM-dd HH:mm') } else { '' })
        LicensePath = $lic
    }
}

# Licensed: move <NAME>.request and <NAME>.license to Done\ so Requests\ only
# ever holds what still has to go to the website.
function Complete-RadminTransfer {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $App, [Parameter(Mandatory)] [string]$Computer)
    $t = Get-RadminTransferPaths -App $App -NoCreate
    if (-not $t.Ok) { return }
    $name = $Computer.Trim().Split('.')[0]
    if (-not $name) { return }
    if (-not (Test-Path -LiteralPath $t.Done)) { try { New-Item -ItemType Directory -Path $t.Done -Force | Out-Null } catch { return } }
    $moved = @()
    foreach ($src in @((Join-Path $t.Requests ($name + '.request')), (Join-Path $t.Licenses ($name + '.license')), (Join-Path $t.Root ($name + '.license')))) {
        if (-not (Test-Path -LiteralPath $src)) { continue }
        $dest = Join-Path $t.Done ([System.IO.Path]::GetFileName($src))
        try { Move-Item -LiteralPath $src -Destination $dest -Force; $moved += [System.IO.Path]::GetFileName($src) } catch { }
    }
    $csv = Join-Path $t.Requests '_requests.csv'
    try {
        if (Test-Path -LiteralPath $csv) {
            $rest = @(Import-Csv -LiteralPath $csv | Where-Object { $_.Computer -ne $name.ToUpperInvariant() })
            if ($rest.Count -gt 0) { $rest | Export-Csv -LiteralPath $csv -NoTypeInformation -Encoding UTF8 } else { Remove-Item -LiteralPath $csv -Force }
        }
    } catch { }
    return $moved
}

# ---- the fleet: machine list + last results, per environment ----
$script:FleetColumns = @('Machine', 'Computer', 'Radmin', 'Licensed', 'LastAction', 'Result', 'Checked')

function Get-RadminFleetPath {
    param([Parameter(Mandatory)] $App)
    $key = 'Default'
    try { $key = Get-AppEnvironmentKey -App $App } catch { }
    $safe = ($key -replace '[^A-Za-z0-9_.-]', '_')
    return (Join-Path (Get-AppSettingsDir -App $App) ("RadminFleet_" + $safe + '.csv'))
}

function New-RadminFleetRow {
    param([string]$Machine)
    $o = [ordered]@{}
    foreach ($c in $script:FleetColumns) { $o[$c] = '' }
    $o.Machine = $Machine.Trim()
    $o['Request'] = ''; $o['License'] = ''; $o['Outcome'] = ''     # from the transfer folder / this run; not saved
    return [pscustomobject]$o
}

function Get-RadminFleet {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $App)
    $list = New-Object System.Collections.ArrayList
    $p = Get-RadminFleetPath -App $App
    try {
        if (Test-Path -LiteralPath $p) {
            foreach ($r in @(Import-Csv -LiteralPath $p)) {
                if (-not $r.Machine) { continue }
                $row = New-RadminFleetRow -Machine $r.Machine
                foreach ($c in $script:FleetColumns) { if ($r.PSObject.Properties[$c]) { $row.$c = [string]$r.$c } }
                [void]$list.Add($row)
            }
        }
    } catch { $App.Log('WARN', 'Radmin', "machine list $p could not be read: $($_.Exception.Message)") }
    return , $list
}

function Save-RadminFleet {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $App, [Parameter(Mandatory)] [AllowEmptyCollection()] $Rows)
    $p = Get-RadminFleetPath -App $App
    try {
        $out = @($Rows | Select-Object -Property $script:FleetColumns)
        if ($out.Count -gt 0) { $out | Export-Csv -LiteralPath $p -NoTypeInformation -Encoding UTF8 }
        else { Set-Content -LiteralPath $p -Value ('"' + ($script:FleetColumns -join '","') + '"') -Encoding UTF8 }
    } catch { $App.Log('WARN', 'Radmin', "machine list $p could not be saved: $($_.Exception.Message)") }
}

# Machine names from free text / a file: one per line, or separated by , ; space
# or tab. A CSV with a Name / ComputerName / Machine / DNSHostName column works too.
function ConvertTo-RadminMachineNames {
    [CmdletBinding()]
    param([AllowEmptyString()] [string]$Text)
    $lines = @($Text -split "`r?`n" | ForEach-Object { ($_ -replace '#.*$', '').TrimEnd() } | Where-Object { $_.Trim() })
    if ($lines.Count -eq 0) { return }
    $Text = $lines -join "`r`n"
    $first = ([string]$lines[0]).Trim()
    $col = $null
    foreach ($c in @('Name', 'ComputerName', 'Machine', 'DNSHostName', 'Computer', 'Hostname')) {
        if ($first -match ('(^|[,;"\s])' + $c + '(["\s]*([,;]|$))')) { $col = $c; break }
    }
    $names = @()
    if ($col -and $first -match '[,;]') {
        $delim = $(if ($first -match ';' -and $first -notmatch ',') { ';' } else { ',' })
        try { $names = @($Text | ConvertFrom-Csv -Delimiter $delim | ForEach-Object { [string]$_.$col }) } catch { }
    }
    else {
        $names = @($Text -split '[\r\n,;\t ]+')
    }
    $seen = @{}
    foreach ($n in $names) {
        $n = ([string]$n).Trim().Trim('"').Trim()
        if (-not $n -or $n.StartsWith('#') -or $n -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') { continue }
        if ($seen.ContainsKey($n.ToLowerInvariant())) { continue }
        $seen[$n.ToLowerInvariant()] = $true
        $n
    }
}

# Script blocks for UI closures (closures do not see module functions reliably).
function Get-RadminApi {
    return @{
        Settings        = ${function:Get-RadminSettings}
        Defaults        = ${function:Get-RadminDefaults}
        TransferFolder  = ${function:Get-RadminTransferFolder}
        SetTransfer     = ${function:Set-RadminTransferFolder}
        TransferPaths   = ${function:Get-RadminTransferPaths}
        Options         = ${function:New-RadminOptions}
        Core            = $script:RadminCore
        Local           = ${function:Invoke-RadminLocal}
        IsLocal         = ${function:Test-RadminLocalTarget}
        Elevated        = ${function:Test-RadminElevated}
        SaveRequest     = ${function:Save-RadminRequestFile}
        FindLicense     = ${function:Find-RadminLicenseFile}
        TransferState   = ${function:Get-RadminTransferState}
        Complete        = ${function:Complete-RadminTransfer}
        Fleet           = ${function:Get-RadminFleet}
        SaveFleet       = ${function:Save-RadminFleet}
        NewRow          = ${function:New-RadminFleetRow}
        ParseNames      = ${function:ConvertTo-RadminMachineNames}
    }
}
