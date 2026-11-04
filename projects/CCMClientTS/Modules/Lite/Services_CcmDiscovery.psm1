# Services_CcmDiscovery.psm1   (LITE TIER)
#
# Read-only discovery of the Configuration Manager client and the Windows
# pieces it depends on. Nothing here changes the machine.
#
#   $r = Invoke-CcmDiscovery -App $App [-Deep] [-Progress { param($text) }]
#        Findings (Category, Check, Status OK|WARN|FAIL|INFO, Detail, Fix)
#        Facts    (hashtable of everything measured)
#        State / StateLevel / StateDetail   the verdict
#        Recommended   step Ids, in catalog order
#        InstallReady / InstallBlockers / ShareReady / ShareBlockers
#        Stored in (Get-CcmTSState).Discovery; ScanHandlers are called after.
#
# Helpers used by the other tabs:
#   Test-CcmElevated, Get-CcmSystemExe, Invoke-CcmNative, Test-CcmTcp,
#   Get-CcmLogEntries, Get-CcmLogCatalog, Get-CcmRegistrationInfo,
#   Get-CcmSfcSummary, Test-CcmRepairSource, Get-CcmServiceSpec,
#   Format-CcmReport
#
# Security-tool friendly by design: no encoded commands, no Add-Type / csc,
# no downloads, no certutil / nltest / msdt / regsvr32, no port scanning (only
# the configured MP is contacted), nothing hidden that changes the system.

$script:CcmLogDir = Join-Path $env:windir 'CCM\Logs'

function Test-CcmElevated {
    [CmdletBinding()]
    param()
    try {
        return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

# System32 path of a native tool that also works from a 32-bit host (Sysnative).
function Get-CcmSystemExe {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Name)
    $sys = Join-Path $env:windir 'System32'
    if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
        $sn = Join-Path $env:windir 'Sysnative'
        if (Test-Path -LiteralPath $sn) { $sys = $sn }
    }
    return (Join-Path $sys $Name)
}

# Short native command, output captured, UI kept responsive. For long tools use
# the job runner (Admin\Services_CcmJobs.psm1) instead.
function Invoke-CcmNative {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$FilePath, [string]$Arguments = '', [int]$TimeoutSec = 60)
    $r = [pscustomobject]@{ ExitCode = -1; Output = ''; TimedOut = $false; Error = '' }
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $FilePath
        $psi.Arguments = $Arguments
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $p = [System.Diagnostics.Process]::Start($psi)
        $o = $p.StandardOutput.ReadToEndAsync()
        $e = $p.StandardError.ReadToEndAsync()
        $deadline = (Get-Date).AddSeconds($TimeoutSec)
        while (-not $p.HasExited) {
            [System.Windows.Forms.Application]::DoEvents()
            if ((Get-Date) -gt $deadline) { try { $p.Kill() } catch { }; $r.TimedOut = $true; break }
            Start-Sleep -Milliseconds 100
        }
        try { [void]$p.WaitForExit(5000) } catch { }
        if (-not $r.TimedOut) { try { $r.ExitCode = $p.ExitCode } catch { } }
        $txt = ''
        try { if ($o.Wait(3000)) { $txt += [string]$o.Result } } catch { }
        try { if ($e.Wait(1000)) { $txt += "`n" + [string]$e.Result } } catch { }
        $r.Output = ($txt -replace "`0", '').Trim()
    }
    catch { $r.Error = $_.Exception.Message }
    return $r
}

function Test-CcmTcp {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$HostName, [Parameter(Mandatory)] [int]$Port, [int]$TimeoutMs = 2000)
    $c = New-Object System.Net.Sockets.TcpClient
    try {
        $ar = $c.BeginConnect($HostName, $Port, $null, $null)
        $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
        while (-not $ar.IsCompleted -and (Get-Date) -lt $deadline) {
            [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 50
        }
        if (-not $ar.IsCompleted) { return $false }
        try { $c.EndConnect($ar); return $c.Connected } catch { return $false }
    }
    catch { return $false }
    finally { try { $c.Close() } catch { } }
}

# ---------------------------------------------------------------- log reading
# Tail of a log file (shared read, works while the client is writing it),
# decoded (UTF-8 / UTF-16 detected) and parsed: CMTrace lines become
# Time / Component / Type (1 info, 2 warning, 3 error) / Message; plain
# text logs (CBS, DISM, msi) get a Type from their level / wording.
function Get-CcmLogEntries {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Path, [int]$MaxBytes = 524288)
    $out = New-Object System.Collections.ArrayList
    if (-not (Test-Path -LiteralPath $Path)) { return ,$out }
    $buf = $null; $read = 0; $start = 0
    try {
        $fs = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, ([System.IO.FileShare]'ReadWrite, Delete'))
        try {
            $len = $fs.Length
            $start = [Math]::Max([long]0, $len - $MaxBytes)
            [void]$fs.Seek($start, [System.IO.SeekOrigin]::Begin)
            $buf = New-Object byte[] ([int]($len - $start))
            while ($read -lt $buf.Length) { $n = $fs.Read($buf, $read, $buf.Length - $read); if ($n -le 0) { break }; $read += $n }
        } finally { $fs.Dispose() }
    } catch { return ,$out }
    if ($read -le 0) { return ,$out }

    # UTF-16 LE when a good share of the bytes are 0
    $probe = [Math]::Min($read, 400); $zeros = 0
    for ($i = 0; $i -lt $probe; $i++) { if ($buf[$i] -eq 0) { $zeros++ } }
    if ($zeros -gt ($probe / 4)) {
        $off = 0
        if ($start -eq 0 -and $read -ge 2 -and $buf[0] -eq 0xFF -and $buf[1] -eq 0xFE) { $off = 2 }
        elseif (($start % 2) -eq 1) { $off = 1 }
        $text = [System.Text.Encoding]::Unicode.GetString($buf, $off, $read - $off)
    } else {
        $text = [System.Text.Encoding]::UTF8.GetString($buf, 0, $read)
    }
    $text = $text -replace "`0", ''
    if ($start -gt 0) { $nl = $text.IndexOf("`n"); if ($nl -ge 0) { $text = $text.Substring($nl + 1) } }

    $rx = [regex]'(?s)<!\[LOG\[(?<m>.*?)\]LOG\]!><time="(?<t>[^"]*)"\s+date="(?<d>[^"]*)"\s+component="(?<c>[^"]*)"[^>]*?type="(?<y>\d)"'
    $ms = $rx.Matches($text)
    if ($ms.Count -gt 0) {
        foreach ($m in $ms) {
            $t = $m.Groups['t'].Value; $dot = $t.IndexOf('.'); if ($dot -gt 0) { $t = $t.Substring(0, $dot) }
            $d = $m.Groups['d'].Value
            $when = [datetime]::MinValue
            [void][datetime]::TryParseExact("$d $t", 'M-d-yyyy H:mm:ss', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$when)
            [void]$out.Add([pscustomobject]@{
                When      = $when
                Time      = $(if ($when -ne [datetime]::MinValue) { $when.ToString('yyyy-MM-dd HH:mm:ss') } else { "$d $t" })
                Component = $m.Groups['c'].Value
                Type      = [int]$m.Groups['y'].Value
                Message   = $m.Groups['m'].Value.Trim()
            })
        }
        return ,$out
    }

    $plain = [regex]'^(?<dt>\d{4}-\d\d-\d\d \d\d:\d\d:\d\d),\s+(?<lvl>\w+)\s+(?<c>\S+)\s+(?<m>.*)$'
    foreach ($ln in ($text -split "`r?`n")) {
        if (-not $ln.Trim()) { continue }
        $when = [datetime]::MinValue; $comp = ''; $msg = $ln; $type = 1
        $pm = $plain.Match($ln)
        if ($pm.Success) {
            [void][datetime]::TryParseExact($pm.Groups['dt'].Value, 'yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$when)
            $comp = $pm.Groups['c'].Value; $msg = $pm.Groups['m'].Value
            switch -regex ($pm.Groups['lvl'].Value) { '^Error' { $type = 3 } '^Warning' { $type = 2 } }
        }
        if ($msg -match 'Cannot repair|source file in store is also corrupted|\bfailed\b|\bError\b|HRESULT = 0x8|hr = 0x8|0x800[0-9A-Fa-f]{5}') { $type = 3 }
        elseif ($type -lt 2 -and $msg -match '\bWarning\b') { $type = 2 }
        if ($msg -match 'Overlap: Directory .* is owned twice') { $type = 1 }
        [void]$out.Add([pscustomobject]@{
            When = $when; Time = $(if ($when -ne [datetime]::MinValue) { $when.ToString('yyyy-MM-dd HH:mm:ss') } else { '' })
            Component = $comp; Type = $type; Message = $msg.Trim()
        })
    }
    return ,$out
}

function Get-CcmLogCatalog {
    [CmdletBinding()]
    param($App = $null)
    $c = $script:CcmLogDir
    $list = @(
        @('Client: registration',         (Join-Path $c 'ClientIDManagerStartup.log'), 'GUID, hardware ID, RegTask: registered / rejected / pending approval')
        @('Client: certificates',         (Join-Path $c 'CertificateMaintenance.log'), 'Self-signed certificate + TPM / key storage errors (0x800706d9 = KeyIso)')
        @('Client: location / MP',        (Join-Path $c 'LocationServices.log'), 'MP lookup, AD site, trusted root key')
        @('Client: site assignment',      (Join-Path $c 'ClientLocation.log'), 'Site code assignment')
        @('Client: MP messaging',         (Join-Path $c 'CcmMessaging.log'), 'HTTP traffic to the MP (401/403/timeouts)')
        @('Client: policy',               (Join-Path $c 'PolicyAgent.log'), 'Policy requests and downloads')
        @('Client: policy evaluation',    (Join-Path $c 'PolicyEvaluator.log'), 'Policy applied to WMI')
        @('Client: agent host',           (Join-Path $c 'CcmExec.log'), 'SMS Agent Host activity')
        @('Client: inventory',            (Join-Path $c 'InventoryAgent.log'), 'Hardware / discovery inventory')
        @('Client: health (ccmeval)',     (Join-Path $c 'CcmEval.log'), 'Client health evaluation')
        @('Client: install (ccmsetup)',   (Join-Path $env:windir 'ccmsetup\Logs\ccmsetup.log'), 'Install / uninstall result codes')
        @('Client: install (client.msi)', (Join-Path $env:windir 'ccmsetup\Logs\client.msi.log'), 'Windows Installer detail of the client install')
        @('Windows: CBS (SFC)',           (Join-Path $env:windir 'Logs\CBS\CBS.log'), 'SFC [SR] results, servicing errors')
        @('Windows: DISM',                (Join-Path $env:windir 'Logs\DISM\dism.log'), 'DISM ScanHealth / RestoreHealth')
    )
    foreach ($l in $list) {
        $exists = Test-Path -LiteralPath $l[1]
        $size = ''; $mod = ''
        if ($exists) { try { $fi = Get-Item -LiteralPath $l[1]; $size = '{0:N0} KB' -f [Math]::Ceiling($fi.Length / 1KB); $mod = $fi.LastWriteTime.ToString('yyyy-MM-dd HH:mm') } catch { } }
        [pscustomobject]@{ Name = $l[0]; Path = $l[1]; Purpose = $l[2]; Exists = $exists; Size = $size; Modified = $mod }
    }
    if ($App) {
        $sl = Join-Path ([string]$App.DataRoot) 'Logs\Session.log'
        [pscustomobject]@{ Name = 'This tool: Session.log'; Path = $sl; Purpose = 'This tool''s own log (every step it ran)'; Exists = (Test-Path -LiteralPath $sl); Size = ''; Modified = '' }
    }
}

# ---------------------------------------------------------------- interpreters
function Get-CcmRegistrationInfo {
    [CmdletBinding()]
    param()
    $info = [pscustomobject]@{ State = 'Unknown'; Code = ''; Approval = ''; Guid = ''; HardwareId = ''; LastLine = ''; LastTime = ''; CertError = '' }
    $e = Get-CcmLogEntries -Path (Join-Path $script:CcmLogDir 'ClientIDManagerStartup.log') -MaxBytes 262144
    if ($e.Count -eq 0) { $info.State = 'NoLog'; return $info }
    foreach ($x in $e) {
        if ($x.Message -match 'Computed HardwareID=(\S+)') { $info.HardwareId = $Matches[1] }
        if ($x.Message -match 'Sending registration request for (GUID:[0-9A-Fa-f-]+)') { $info.Guid = $Matches[1] }
    }
    $reg = @($e | Where-Object { $_.Message -match 'RegTask' })
    if ($reg.Count -eq 0) { $info.State = 'NoRegTask'; return $info }
    $last = $reg[-1]
    $info.LastLine = $last.Message; $info.LastTime = $last.Time
    $m = $last.Message
    if ($m -match 'Client is registered\. Server assigned ClientID is (GUID:[0-9A-Fa-f-]+)\.\s*Approval status (\d+)') {
        $info.State = 'Registered'; $info.Guid = $Matches[1]; $info.Approval = $Matches[2]
    }
    elseif ($m -match 'Client is already registered') { $info.State = 'Registered' }
    elseif ($m -match 'Server rejected registration request: (\d+)') { $info.State = 'Rejected'; $info.Code = $Matches[1] }
    elseif ($m -match 'Failed to get certificate') { $info.State = 'NoCert'; if ($m -match '(0x[0-9A-Fa-f]{8})') { $info.CertError = $Matches[1] } }
    elseif ($m -match 'pending') { $info.State = 'Pending' }
    elseif ($m -match 'Client is not registered\. Sending registration request') { $info.State = 'Sending' }
    elseif ($m -match 'Executing registration task') { $info.State = 'Sending' }
    # an approval status can be on an earlier line than the last RegTask line
    if (-not $info.Approval) {
        for ($i = $reg.Count - 1; $i -ge 0; $i--) { if ($reg[$i].Message -match 'Approval status (\d+)') { $info.Approval = $Matches[1]; break } }
    }
    return $info
}

function Get-CcmSfcSummary {
    [CmdletBinding()]
    param()
    $s = [pscustomobject]@{ Found = $false; When = ''; Repaired = 0; CannotRepair = 0; Files = @(); Text = 'No SFC run found in the current CBS.log.' }
    $e = Get-CcmLogEntries -Path (Join-Path $env:windir 'Logs\CBS\CBS.log') -MaxBytes 4194304
    if ($e.Count -eq 0) { return $s }
    $startIdx = -1
    for ($i = $e.Count - 1; $i -ge 0; $i--) { if ($e[$i].Message -match '\[SR\] Beginning Verify and Repair transaction') { $startIdx = $i; break } }
    if ($startIdx -lt 0) { return $s }
    # an SFC run has several Verify transactions; walk back to the first of this run (within 2 hours)
    $first = $startIdx
    for ($i = $startIdx - 1; $i -ge 0; $i--) {
        if ($e[$i].Message -match '\[SR\] Beginning Verify and Repair transaction') {
            if ($e[$startIdx].When -ne [datetime]::MinValue -and $e[$i].When -ne [datetime]::MinValue -and ($e[$startIdx].When - $e[$i].When).TotalHours -gt 2) { break }
            $first = $i
        }
    }
    $s.Found = $true; $s.When = $e[$first].Time
    $files = New-Object System.Collections.Generic.HashSet[string]
    for ($i = $first; $i -lt $e.Count; $i++) {
        $m = $e[$i].Message
        if ($m -match '\[SR\] Cannot repair member file \[l:\d+\]''([^'']+)''') { $s.CannotRepair++; [void]$files.Add($Matches[1]) }
        elseif ($m -match '\[SR\] Repairing corrupted file|\[SR\] Repaired file') { $s.Repaired++ }
    }
    $s.Files = @($files)
    if ($s.CannotRepair -gt 0) { $s.Text = "Last SFC ($($s.When)): $($files.Count) file(s) could NOT be repaired: $(@($files) -join ', ')" }
    elseif ($s.Repaired -gt 0) { $s.Text = "Last SFC ($($s.When)): $($s.Repaired) file repair(s), none failed." }
    else { $s.Text = "Last SFC ($($s.When)): no integrity violations recorded." }
    return $s
}

# A DISM repair source: reachable, and on the same build as this PC.
function Test-CcmRepairSource {
    [CmdletBinding()]
    param([AllowEmptyString()] [string]$Source)
    $r = [pscustomobject]@{ Source = $Source; Path = ''; Ok = $false; Kind = ''; Detail = ''; LocalBuild = ''; SourceBuild = ''; Match = $false }
    try {
        $lk = [System.Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path $env:windir 'System32\ntoskrnl.exe'))
        $r.LocalBuild = '{0}.{1}' -f $lk.FileBuildPart, $lk.FilePrivatePart
    } catch { }
    $Source = ([string]$Source).Trim()
    if (-not $Source) { $r.Detail = 'No repair source set (environment RepairSource, or the box on Repair Steps).'; return $r }

    if ($Source -match '^(wim|esd):(.+):(\d+)$') {
        $r.Kind = 'Image'; $file = $Matches[2]
        if (Test-Path -LiteralPath $file) { $r.Ok = $true; $r.Path = $Source; $r.Detail = "Image file found: $file (index $($Matches[3])). Build cannot be compared without mounting - it must contain build $($r.LocalBuild)." }
        else { $r.Detail = "Image file not found: $file" }
        return $r
    }

    $r.Kind = 'Folder'
    if ($Source -match '^\\\\([^\\]+)\\') {
        $h = $Matches[1]
        if (-not (Test-CcmTcp -HostName $h -Port 445 -TimeoutMs 2500)) { $r.Detail = "$h does not answer on SMB (445): offline, name wrong, or firewall."; return $r }
    }
    if (-not (Test-Path -LiteralPath $Source)) { $r.Detail = "Not reachable: $Source (check the name and admin rights to the C$ share)."; return $r }
    $win = $Source
    if (-not (Test-Path -LiteralPath (Join-Path $win 'WinSxS'))) {
        if (Test-Path -LiteralPath (Join-Path $Source 'Windows\WinSxS')) { $win = Join-Path $Source 'Windows' }
        else { $r.Detail = "$Source has no WinSxS folder - point it at the Windows folder (\\PC\C$\Windows)."; return $r }
    }
    try {
        $sk = [System.Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path $win 'System32\ntoskrnl.exe'))
        $r.SourceBuild = '{0}.{1}' -f $sk.FileBuildPart, $sk.FilePrivatePart
    } catch { }
    $r.Ok = $true
    $r.Path = $win
    $r.Match = ($r.SourceBuild -and $r.SourceBuild -eq $r.LocalBuild)
    if ($r.Match) { $r.Detail = "Reachable; same build as this PC ($($r.LocalBuild))." }
    elseif ($r.SourceBuild) { $r.Detail = "Reachable, but the source is build $($r.SourceBuild) and this PC is $($r.LocalBuild). DISM needs the SAME build - pick another PC." }
    else { $r.Detail = 'Reachable; the build could not be read (ntoskrnl.exe).' }
    return $r
}

function Get-CcmServiceSpec {
    [CmdletBinding()]
    param()
    # Name, Display, Default start type, MustRun, Critical (Disabled = FAIL), Protected (Set-Service is refused by Windows)
    @(
        @('KeyIso',            'CNG Key Isolation',            'Manual',    $false, $true,  $false)
        @('Winmgmt',           'Windows Management Instrumentation', 'Automatic', $true, $true, $false)
        @('RpcSs',             'Remote Procedure Call (RPC)',   'Automatic', $true,  $true,  $true)
        @('CryptSvc',          'Cryptographic Services',       'Automatic', $true,  $true,  $false)
        @('BITS',              'Background Intelligent Transfer', 'Manual', $false, $true,  $false)
        @('msiserver',         'Windows Installer',            'Manual',    $false, $true,  $false)
        @('LanmanWorkstation', 'Workstation',                  'Automatic', $true,  $true,  $false)
        @('EventLog',          'Windows Event Log',            'Automatic', $true,  $false, $true)
        @('Schedule',          'Task Scheduler',               'Automatic', $true,  $false, $true)
        @('Dnscache',          'DNS Client',                   'Automatic', $true,  $false, $true)
        @('wuauserv',          'Windows Update',               'Manual',    $false, $false, $false)
        @('TrustedInstaller',  'Windows Modules Installer',    'Manual',    $false, $false, $false)
        @('W32Time',           'Windows Time',                 'Manual',    $false, $false, $false)
    ) | ForEach-Object { [pscustomobject]@{ Name = $_[0]; Display = $_[1]; Default = $_[2]; MustRun = $_[3]; Critical = $_[4]; Protected = $_[5] } }
}

# ---------------------------------------------------------------- discovery
function Invoke-CcmDiscovery {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $App, [switch]$Deep, [scriptblock]$Progress = $null)

    $ProgressPreference = 'SilentlyContinue'
    $cfg = Get-CcmTSConfig -App $App
    $Findings = New-Object System.Collections.ArrayList
    $f = @{}
    function Add-F([string]$cat, [string]$check, [string]$status, [string]$detail, [string]$fix = '') {
        [void]$Findings.Add([pscustomobject]@{ Category = $cat; Check = $check; Status = $status; Detail = $detail; Fix = $fix })
    }
    function Show-Step([string]$t) {
        try { $App.SetStatus("Discovery: $t ...", 'info') } catch { }
        if ($Progress) { try { & $Progress $t } catch { } }
        [System.Windows.Forms.Application]::DoEvents()
    }

    # ============================================================ Session
    Show-Step 'session'
    $f.Elevated = Test-CcmElevated
    if ($f.Elevated) { Add-F 'Session' 'Running as administrator' 'OK' 'Elevated.' }
    else { Add-F 'Session' 'Running as administrator' 'FAIL' 'Not elevated: many checks below are incomplete and no repair can run.' 'Step: Run this tool as administrator' }
    Add-F 'Session' 'Environment' 'INFO' ("{0}  -  site '{1}', MP '{2}', client source '{3}', repair source '{4}'" -f $App.ActiveLabel, $cfg.SiteCode, $cfg.ManagementPoint, $cfg.ClientSource, $(if ($cfg.RepairSource) { $cfg.RepairSource } else { '(none)' }))
    if (-not $cfg.SiteCode -or -not $cfg.ManagementPoint) { Add-F 'Session' 'Site code / MP configured' 'WARN' 'Set Site code and Management point on the Environment tab - several checks and the install need them.' }

    # ============================================================ Identity
    Show-Step 'computer identity'
    $cs = $null; $os = $null; $bios = $null; $csp = $null
    try { $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop } catch { }
    try { $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop } catch { }
    try { $bios = Get-CimInstance Win32_BIOS -ErrorAction Stop } catch { }
    try { $csp = Get-CimInstance Win32_ComputerSystemProduct -ErrorAction Stop } catch { }
    $cv = $null; try { $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop } catch { }
    $f.Computer = $env:COMPUTERNAME
    $f.Serial = $(if ($bios) { [string]$bios.SerialNumber } else { '' })
    $f.SmbiosGuid = $(if ($csp) { [string]$csp.UUID } else { '' })
    $f.Build = $(if ($cv) { "{0}.{1}" -f $cv.CurrentBuild, $cv.UBR } else { '' })
    Add-F 'Identity' 'Computer' 'INFO' ("{0}  ({1} {2})" -f $env:COMPUTERNAME, $(if ($cs) { $cs.Manufacturer } else { '' }), $(if ($cs) { $cs.Model } else { '' }))
    Add-F 'Identity' 'Serial number' 'INFO' $f.Serial
    Add-F 'Identity' 'SMBIOS GUID' 'INFO' $f.SmbiosGuid
    if ($os) { Add-F 'Identity' 'Windows' 'INFO' ("{0}  {1}  build {2}" -f $os.Caption, $(if ($cv) { $cv.DisplayVersion } else { '' }), $f.Build) }

    # ============================================================ Windows
    Show-Step 'Windows: reboot, disk, uptime'
    $pr = New-Object System.Collections.ArrayList
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { [void]$pr.Add('servicing (CBS)') }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { [void]$pr.Add('Windows Update') }
    try { $pfr = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction Stop).PendingFileRenameOperations; if (@($pfr | Where-Object { $_ }).Count -gt 0) { [void]$pr.Add('pending file renames') } } catch { }
    try {
        $cr = Invoke-CimMethod -Namespace 'root\ccm\ClientSDK' -ClassName CCM_ClientUtilities -MethodName DetermineIfRebootPending -ErrorAction Stop
        if ($cr.RebootPending -or $cr.IsHardRebootPending) { [void]$pr.Add('Configuration Manager client') }
    } catch { }
    $f.PendingReboot = @($pr | Where-Object { $_ -ne 'pending file renames' }).Count -gt 0
    if ($pr.Count -eq 0) { Add-F 'Windows' 'Pending reboot' 'OK' 'None.' }
    elseif ($f.PendingReboot) { Add-F 'Windows' 'Pending reboot' 'WARN' ("Reboot pending: " + ($pr -join ', ') + '. Reboot before installing or repairing.') 'Reboot now (Repair Steps)' }
    else { Add-F 'Windows' 'Pending reboot' 'INFO' 'Only pending file renames (usually harmless).' }

    if ($os) {
        $up = (Get-Date) - $os.LastBootUpTime
        Add-F 'Windows' 'Uptime' $(if ($up.TotalDays -gt 30) { 'WARN' } else { 'INFO' }) ("Last boot {0:yyyy-MM-dd HH:mm} ({1:N1} days)." -f $os.LastBootUpTime, $up.TotalDays)
    }
    try {
        $d = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$($env:SystemDrive)'" -ErrorAction Stop
        $f.DiskFreeGB = [Math]::Round($d.FreeSpace / 1GB, 1)
        $st = $(if ($f.DiskFreeGB -lt 2) { 'FAIL' } elseif ($f.DiskFreeGB -lt 8) { 'WARN' } else { 'OK' })
        Add-F 'Windows' 'Free space on system drive' $st ("{0} GB free of {1:N0} GB." -f $f.DiskFreeGB, ($d.Size / 1GB)) $(if ($st -ne 'OK') { 'Free space (ccmcache needs room); Step: DISM StartComponentCleanup' } else { '' })
    } catch { $f.DiskFreeGB = -1 }

    Show-Step 'Windows: domain, secure channel, AD site'
    $f.PartOfDomain = [bool]($cs -and $cs.PartOfDomain)
    if ($f.PartOfDomain) { Add-F 'Windows' 'Domain membership' 'OK' "Joined to $($cs.Domain)." } else { Add-F 'Windows' 'Domain membership' 'WARN' 'Not domain joined - AD-based MP lookup and Windows authentication to the MP will not work.' }
    $f.SecureChannel = $null
    if ($f.PartOfDomain -and $f.Elevated) {
        try { $f.SecureChannel = [bool](Test-ComputerSecureChannel -ErrorAction Stop) } catch { $f.SecureChannel = $false }
        if ($f.SecureChannel) { Add-F 'Windows' 'Domain secure channel' 'OK' 'Trust with the domain is working.' }
        else { Add-F 'Windows' 'Domain secure channel' 'FAIL' 'Broken trust with the domain: the MP will not authenticate this computer.' 'Repair the trust (Test-ComputerSecureChannel -Repair with domain credentials, or rejoin).' }
    }
    if ($f.PartOfDomain) {
        try { [void][System.Reflection.Assembly]::Load('System.DirectoryServices, Version=4.0.0.0, Culture=neutral, PublicKeyToken=b03f5f7f11d50a3a') } catch { }
        try { $site = [System.DirectoryServices.ActiveDirectory.ActiveDirectorySite]::GetComputerSite().Name; Add-F 'Windows' 'AD site' 'INFO' "$site (boundaries / boundary groups must cover it, or this PC's subnet)." }
        catch { Add-F 'Windows' 'AD site' 'WARN' "AD site could not be determined: $($_.Exception.Message)" }
    }

    Show-Step 'Windows: time'
    $f.TimeOffsetSec = $null
    if ($cfg.ManagementPoint) {
        $w = Invoke-CcmNative -FilePath (Get-CcmSystemExe 'w32tm.exe') -Arguments "/stripchart /computer:$($cfg.ManagementPoint) /samples:1 /dataonly" -TimeoutSec 15
        if ($w.Output -match '([+-]\d+(?:\.\d+)?)s') {
            $f.TimeOffsetSec = [double]$Matches[1]
            $abs = [Math]::Abs($f.TimeOffsetSec)
            $st = $(if ($abs -gt 300) { 'FAIL' } elseif ($abs -gt 60) { 'WARN' } else { 'OK' })
            Add-F 'Windows' 'Clock offset vs MP' $st ("{0:N1} s against {1}." -f $f.TimeOffsetSec, $cfg.ManagementPoint) $(if ($st -ne 'OK') { 'Step: Resync the clock with the domain' } else { '' })
        } else { Add-F 'Windows' 'Clock offset vs MP' 'INFO' 'Could not measure (MP does not answer NTP queries - normal for many servers).' }
    }

    # ============================================================ Services
    Show-Step 'services'
    $f.DisabledServices = New-Object System.Collections.ArrayList
    $f.StoppedServices = New-Object System.Collections.ArrayList
    $f.KeyIsoStart = ''
    foreach ($sp in (Get-CcmServiceSpec)) {
        $svc = Get-Service -Name $sp.Name -ErrorAction SilentlyContinue
        if (-not $svc) { Add-F 'Services' $sp.Display $(if ($sp.Critical) { 'FAIL' } else { 'WARN' }) "Service '$($sp.Name)' does not exist." ; continue }
        $stype = [string]$svc.StartType
        if ($sp.Name -eq 'KeyIso') { $f.KeyIsoStart = $stype; $f.KeyIsoStatus = [string]$svc.Status }
        if ($stype -eq 'Disabled') {
            [void]$f.DisabledServices.Add($sp.Name)
            $extra = $(if ($sp.Name -eq 'KeyIso') { ' The client cannot create its key / certificates (CertificateMaintenance 0x800706d9).' } else { '' })
            Add-F 'Services' $sp.Display $(if ($sp.Critical) { 'FAIL' } else { 'WARN' }) "$($sp.Name) is DISABLED (default: $($sp.Default)).$extra" 'Step: Repair required Windows services'
        }
        elseif ($sp.MustRun -and $svc.Status -ne 'Running') {
            [void]$f.StoppedServices.Add($sp.Name)
            Add-F 'Services' $sp.Display $(if ($sp.Critical) { 'FAIL' } else { 'WARN' }) "$($sp.Name) is $($svc.Status) (start type $stype) - it should be running." 'Step: Repair required Windows services'
        }
        else { Add-F 'Services' $sp.Display 'OK' "$($svc.Status), $stype." }
    }

    # ============================================================ Crypto
    Show-Step 'key storage, TPM, certificates'
    $f.KspOk = $true; $f.KspError = ''
    try {
        [void][System.Security.Cryptography.CngKey]::Exists('CcmTS_probe', [System.Security.Cryptography.CngProvider]::MicrosoftSoftwareKeyStorageProvider, [System.Security.Cryptography.CngKeyOpenOptions]::MachineKey)
        Add-F 'Crypto' 'Software key storage provider' 'OK' 'Microsoft Software Key Storage Provider opens.'
    } catch {
        $f.KspOk = $false
        $ex = $_.Exception; while ($ex.InnerException) { $ex = $ex.InnerException }
        $f.KspError = ('0x{0:X8} {1}' -f $ex.HResult, $ex.Message)
        Add-F 'Crypto' 'Software key storage provider' 'FAIL' "Cannot open the Microsoft Software Key Storage Provider: $($f.KspError). The client cannot create certificates." 'Step: Repair required Windows services (CNG Key Isolation / KeyIso)'
    }
    $f.TpmReady = $null
    if ($f.Elevated) {
        try {
            $t = Get-Tpm -ErrorAction Stop
            $f.TpmReady = [bool]($t.TpmPresent -and $t.TpmReady)
            if (-not $t.TpmPresent) { Add-F 'Crypto' 'TPM' 'INFO' 'No TPM - the client uses software keys.' }
            elseif ($t.LockedOut) { Add-F 'Crypto' 'TPM' 'FAIL' 'TPM is in lockout - TPM-backed client keys cannot be created.' 'Wait for the lockout to expire, or clear it per policy (BitLocker / Credential Guard implications - involve IT).' }
            elseif (-not $t.TpmReady) { Add-F 'Crypto' 'TPM' 'WARN' 'TPM present but not ready.' }
            else { Add-F 'Crypto' 'TPM' 'OK' 'Present and ready.' }
        } catch { Add-F 'Crypto' 'TPM' 'INFO' "Could not query: $($_.Exception.Message)" }
    }
    $f.TpmKey = $false
    try {
        $pcp = New-Object System.Security.Cryptography.CngProvider('Microsoft Platform Crypto Provider')
        $f.TpmKey = [System.Security.Cryptography.CngKey]::Exists('ConfigMgrPrimaryKey', $pcp, [System.Security.Cryptography.CngKeyOpenOptions]::MachineKey)
        Add-F 'Crypto' 'Client key in TPM (ConfigMgrPrimaryKey)' 'INFO' $(if ($f.TpmKey) { 'Present.' } else { 'Not present (created by the client when it creates its certificates).' })
    } catch { }
    $f.CertCount = 0
    try {
        $certs = @(Get-ChildItem Cert:\LocalMachine\SMS -ErrorAction Stop)
        $f.CertCount = $certs.Count
        if ($certs.Count -eq 0) { Add-F 'Crypto' 'SMS client certificates' 'WARN' 'Cert:\LocalMachine\SMS is empty - the client has not created its self-signed certificates.' }
        else {
            $exp = @($certs | Where-Object { $_.NotAfter -lt (Get-Date) })
            Add-F 'Crypto' 'SMS client certificates' $(if ($exp.Count) { 'WARN' } else { 'OK' }) ("{0} certificate(s); {1}." -f $certs.Count, $(if ($exp.Count) { "$($exp.Count) EXPIRED" } else { 'none expired' }))
        }
    } catch { Add-F 'Crypto' 'SMS client certificates' 'INFO' 'No SMS certificate store.' }
    try {
        $pki = @(Get-ChildItem Cert:\LocalMachine\My -ErrorAction Stop | Where-Object { $_.NotAfter -gt (Get-Date) -and ($_.EnhancedKeyUsageList | Where-Object { $_.ObjectId -eq '1.3.6.1.5.5.7.3.2' }) })
        Add-F 'Crypto' 'PKI client authentication certificate' 'INFO' $(if ($pki.Count) { "$($pki.Count) valid (used when the site is HTTPS / enhanced HTTP)." } else { 'None (fine for an HTTP site).' })
    } catch { }
    $cmLog = Get-CcmLogEntries -Path (Join-Path $script:CcmLogDir 'CertificateMaintenance.log') -MaxBytes 131072
    $f.CertMaintError = ''
    $cmErr = @($cmLog | Where-Object { $_.Type -eq 3 -or $_.Message -match 'failed' } | Select-Object -Last 1)
    if ($cmErr.Count -and $f.CertCount -gt 0) {
        Add-F 'Crypto' 'Certificate maintenance (log)' 'INFO' ("Earlier error ({0}), certificates exist now: {1}" -f $cmErr[0].Time, $cmErr[0].Message)
    }
    elseif ($cmErr.Count) {
        $f.CertMaintError = $cmErr[0].Message
        $hint = $(if ($cmErr[0].Message -match '0x800706d9') { 'Step: Repair required Windows services (KeyIso), then Restart the SMS Agent Host' } elseif ($cmErr[0].Message -match '0x8028|TPM') { 'TPM problem: check TPM state; Steps: Remove the client key from the TPM (after uninstall)' } else { 'See Logs: Client: certificates' })
        Add-F 'Crypto' 'Certificate maintenance (log)' 'FAIL' ("{0}  {1}" -f $cmErr[0].Time, $cmErr[0].Message) $hint
    } elseif ($cmLog.Count) { Add-F 'Crypto' 'Certificate maintenance (log)' 'OK' 'No recent errors.' }

    # ============================================================ WMI
    Show-Step 'WMI'
    $f.WmiConsistent = $null
    if ($f.Elevated -and $Deep) {
        $w = Invoke-CcmNative -FilePath (Get-CcmSystemExe 'wbem\winmgmt.exe') -Arguments '/verifyrepository' -TimeoutSec 120
        if ($w.Output -match 'not consistent|inconsistent') { $f.WmiConsistent = $false; Add-F 'WMI' 'WMI repository' 'FAIL' $w.Output 'Step: Salvage the WMI repository' }
        elseif ($w.Output -match 'consistent') { $f.WmiConsistent = $true; Add-F 'WMI' 'WMI repository' 'OK' 'Consistent.' }
        else { Add-F 'WMI' 'WMI repository' 'WARN' "Unexpected result: $($w.Output) $($w.Error)" }
    } elseif (-not $Deep) { Add-F 'WMI' 'WMI repository' 'INFO' 'Not verified (tick Deep checks).' }
    try { [void](Get-CimInstance Win32_OperatingSystem -ErrorAction Stop); Add-F 'WMI' 'WMI query (root\cimv2)' 'OK' 'Responds.' }
    catch { $f.WmiConsistent = $false; Add-F 'WMI' 'WMI query (root\cimv2)' 'FAIL' $_.Exception.Message 'Steps: Verify / Salvage the WMI repository' }

    # ============================================================ Component store
    Show-Step 'component store'
    $f.StoreState = 'Unknown'
    if ($Deep -and $f.Elevated) {
        $dc = Invoke-CcmNative -FilePath (Get-CcmSystemExe 'dism.exe') -Arguments '/Online /Cleanup-Image /CheckHealth' -TimeoutSec 180
        if ($dc.Output -match 'No component store corruption detected') { $f.StoreState = 'Healthy'; Add-F 'Component store' 'DISM CheckHealth' 'OK' 'No component store corruption detected.' }
        elseif ($dc.Output -match 'is repairable') { $f.StoreState = 'Repairable'; Add-F 'Component store' 'DISM CheckHealth' 'FAIL' 'The component store is repairable (corruption flagged).' 'Step: Repair the component store from a healthy PC, then SFC' }
        elseif ($dc.Output -match 'not repairable') { $f.StoreState = 'NotRepairable'; Add-F 'Component store' 'DISM CheckHealth' 'FAIL' 'The component store is NOT repairable - in-place upgrade (keep files and apps) needed.' }
        else { $tail = (@($dc.Output -split "`n" | Where-Object { $_.Trim() } | Select-Object -Last 3) -join ' '); Add-F 'Component store' 'DISM CheckHealth' 'WARN' ("Unexpected result (exit {0}): {1} {2}" -f $dc.ExitCode, $tail, $dc.Error) }
    } else { Add-F 'Component store' 'DISM CheckHealth' 'INFO' 'Not run (tick Deep checks).' }
    $sfc = Get-CcmSfcSummary
    $f.SfcCannotRepair = $sfc.CannotRepair
    if ($sfc.Found) { Add-F 'Component store' 'Last SFC result (CBS.log)' $(if ($sfc.CannotRepair) { 'FAIL' } else { 'OK' }) $sfc.Text $(if ($sfc.CannotRepair) { 'Step: Repair the component store from a healthy PC, then SFC again' } else { '' }) }
    else { Add-F 'Component store' 'Last SFC result (CBS.log)' 'INFO' $sfc.Text }
    try {
        $sv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Servicing' -ErrorAction Stop
        Add-F 'Component store' 'Repair-source policy' 'INFO' ("LocalSourcePath='{0}', RepairContentServerSource={1}" -f $sv.LocalSourcePath, $sv.RepairContentServerSource)
    } catch { Add-F 'Component store' 'Repair-source policy' 'INFO' 'Not configured.' }
    try {
        $wu = Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' -ErrorAction Stop
        if ($wu.WUServer) { Add-F 'Component store' 'Update source' 'INFO' "WSUS: $($wu.WUServer) - DISM cannot get repair content from WSUS; use a healthy PC as the source." }
    } catch { }
    $rs = Test-CcmRepairSource -Source $cfg.RepairSource
    $f.RepairSourceOk = ($rs.Ok -and ($rs.Kind -eq 'Image' -or $rs.Match))
    if (-not $cfg.RepairSource) { Add-F 'Component store' 'DISM repair source' 'INFO' $rs.Detail 'Set one on Repair Steps (Healthy PC) for air-gapped repairs.' }
    else { Add-F 'Component store' 'DISM repair source' $(if ($f.RepairSourceOk) { 'OK' } else { 'WARN' }) ("{0}: {1}" -f $cfg.RepairSource, $rs.Detail) }

    # ============================================================ Network / MP
    Show-Step 'management point'
    $f.MpResolves = $false; $f.MpTcp = $false; $f.MpListOk = $false
    if ($cfg.ManagementPoint) {
        $mp = $cfg.ManagementPoint
        try { $ips = @([System.Net.Dns]::GetHostAddresses($mp) | ForEach-Object { $_.IPAddressToString }); $f.MpResolves = $ips.Count -gt 0; Add-F 'Network / MP' 'DNS: management point' 'OK' "$mp -> $($ips -join ', ')" }
        catch { Add-F 'Network / MP' 'DNS: management point' 'FAIL' "$mp does not resolve: $($_.Exception.Message)" 'Fix DNS / the MP name on the Environment tab.' }
        if ($f.MpResolves) {
            $p80 = Test-CcmTcp -HostName $mp -Port 80; $p443 = Test-CcmTcp -HostName $mp -Port 443
            $f.MpTcp = ($p80 -or $p443)
            Add-F 'Network / MP' 'TCP to MP (80 / 443)' $(if ($f.MpTcp) { 'OK' } else { 'FAIL' }) ("80: {0}   443: {1}" -f $(if ($p80) { 'open' } else { 'no answer' }), $(if ($p443) { 'open' } else { 'no answer' })) $(if (-not $f.MpTcp) { 'Firewall / routing between this PC and the MP.' } else { '' })
            if ($f.MpTcp) {
                foreach ($scheme in @($(if ($p80) { 'http' }), $(if ($p443) { 'https' })) | Where-Object { $_ }) {
                    try {
                        $resp = Invoke-WebRequest -Uri "${scheme}://$mp/sms_mp/.sms_aut?mplist" -UseBasicParsing -UseDefaultCredentials -TimeoutSec 10 -ErrorAction Stop
                        if ($resp.StatusCode -eq 200 -and $resp.Content -match '<MPList') { $f.MpListOk = $true; Add-F 'Network / MP' "MP answers ($scheme mplist)" 'OK' 'MP list returned - the management point is healthy and reachable.'; break }
                        else { Add-F 'Network / MP' "MP answers ($scheme mplist)" 'WARN' "HTTP $($resp.StatusCode), unexpected content." }
                    } catch { Add-F 'Network / MP' "MP answers ($scheme mplist)" 'WARN' "Request failed: $($_.Exception.Message)" }
                }
                if (-not $f.MpListOk) { Add-F 'Network / MP' 'Management point health' 'FAIL' 'The MP did not return its MP list - client registration cannot succeed until it does.' 'Check the MP role / IIS on the server (mpcontrol.log), proxy, or HTTPS-only configuration.' }
            }
            $f.Smb = Test-CcmTcp -HostName $mp -Port 445
            $f.ShareOk = $false
            if ($f.Smb -and $cfg.SiteShare) { $f.ShareOk = Test-Path -LiteralPath (Join-Path $cfg.SiteShare 'ccmsetup.exe') }
            if ($cfg.SiteShare) { Add-F 'Network / MP' 'Site client share' $(if ($f.ShareOk) { 'OK' } else { 'INFO' }) ("{0}: {1}" -f $cfg.SiteShare, $(if ($f.ShareOk) { 'ccmsetup.exe found.' } elseif (-not $f.Smb) { 'SMB (445) to the server not reachable.' } else { 'not accessible with this account.' })) }
        }
    }
    $px = Invoke-CcmNative -FilePath (Get-CcmSystemExe 'netsh.exe') -Arguments 'winhttp show proxy' -TimeoutSec 10
    if ($px.Output -match 'Direct access') { Add-F 'Network / MP' 'WinHTTP proxy (system)' 'OK' 'Direct access (no proxy).' }
    elseif ($px.Output) { Add-F 'Network / MP' 'WinHTTP proxy (system)' 'WARN' ((($px.Output -split "`n") | Where-Object { $_.Trim() }) -join ' ') 'A system proxy must bypass the MP.' }

    # ============================================================ Client install
    Show-Step 'client install'
    $svcCcm = Get-Service -Name CcmExec -ErrorAction SilentlyContinue
    $f.ServiceExists = [bool]$svcCcm
    $f.ServiceStatus = $(if ($svcCcm) { [string]$svcCcm.Status } else { '' })
    $f.CcmFolder = Test-Path -LiteralPath (Join-Path $env:windir 'CCM')
    $f.CcmExe = Test-Path -LiteralPath (Join-Path $env:windir 'CCM\CcmExec.exe')
    $f.SmsCfg = Test-Path -LiteralPath (Join-Path $env:windir 'SMSCFG.ini')
    $f.WmiCcm = $false
    try { $f.WmiCcm = [bool](Get-CimInstance -Namespace root -ClassName __Namespace -Filter "Name='ccm'" -ErrorAction Stop) } catch { }
    $f.RegCcm = Test-Path 'HKLM:\SOFTWARE\Microsoft\CCM'
    $f.Remnants = (-not $f.ServiceExists) -and ($f.CcmFolder -or $f.WmiCcm -or $f.SmsCfg -or $f.RegCcm)
    $f.CcmSetupRunning = [bool](Get-Process -Name ccmsetup -ErrorAction SilentlyContinue)
    $f.CcmSetupService = [bool](Get-Service -Name ccmsetup -ErrorAction SilentlyContinue)

    if ($f.ServiceExists) {
        Add-F 'Client install' 'SMS Agent Host (CcmExec)' $(if ($f.ServiceStatus -eq 'Running') { 'OK' } else { 'FAIL' }) ("{0}, {1}." -f $svcCcm.Status, $svcCcm.StartType) $(if ($f.ServiceStatus -ne 'Running') { 'Step: Restart the SMS Agent Host' } else { '' })
    } else { Add-F 'Client install' 'SMS Agent Host (CcmExec)' 'FAIL' 'Not installed.' }
    $parts = @(); if ($f.CcmFolder) { $parts += 'C:\Windows\CCM' }; if ($f.WmiCcm) { $parts += 'WMI root\ccm' }; if ($f.SmsCfg) { $parts += 'SMSCFG.ini' }; if ($f.RegCcm) { $parts += 'HKLM\SOFTWARE\Microsoft\CCM' }
    if ($f.Remnants) { Add-F 'Client install' 'Client remnants' 'FAIL' ("Leftovers of a removed client: " + ($parts -join ', ') + '.') 'Step: Remove client leftovers, reboot, then install' }
    elseif ($f.ServiceExists -and (-not $f.CcmExe -or -not $f.WmiCcm)) { Add-F 'Client install' 'Client components' 'FAIL' ("Service exists but " + $(if (-not $f.CcmExe) { 'CcmExec.exe is missing' } else { 'WMI root\ccm is missing' }) + ' - broken install.') 'Steps: Uninstall, Remove leftovers, Install' }
    elseif ($f.ServiceExists) { Add-F 'Client install' 'Client components' 'OK' ($parts -join ', ') }

    $f.ClientVersion = ''
    if ($f.WmiCcm) { try { $f.ClientVersion = [string](Get-CimInstance -Namespace root\ccm -ClassName SMS_Client -ErrorAction Stop).ClientVersion } catch { } }
    if ($f.ClientVersion) { Add-F 'Client install' 'Client version' 'INFO' $f.ClientVersion }

    if ($f.CcmSetupRunning) { Add-F 'Client install' 'ccmsetup running' 'WARN' 'ccmsetup.exe is running: an install / uninstall / repair is in progress. Wait for it before changing anything.' 'Watch Logs: Client: install (ccmsetup)' }
    elseif ($f.CcmSetupService) { Add-F 'Client install' 'ccmsetup service' 'WARN' 'The ccmsetup service exists (install waiting to retry, or interrupted).' }
    $csl = Get-CcmLogEntries -Path (Join-Path $env:windir 'ccmsetup\Logs\ccmsetup.log') -MaxBytes 262144
    $f.CcmSetupLast = ''
    $last = @($csl | Where-Object { $_.Message -match 'CcmSetup is exiting with return code (\d+)|CcmSetup failed with error code (0x[0-9A-Fa-f]+)|Uninstall succeeded|Installation succeeded' } | Select-Object -Last 1)
    if ($last.Count) {
        $f.CcmSetupLast = $last[0].Message
        $bad = ($last[0].Message -match 'failed|return code [1-9]') -and ($last[0].Message -notmatch 'return code 7\b')
        Add-F 'Client install' 'Last ccmsetup result' $(if ($bad) { 'FAIL' } else { 'INFO' }) ("{0}  {1}" -f $last[0].Time, $last[0].Message) $(if ($bad) { 'Logs: Client: install (ccmsetup) / client.msi.log for the error.' } else { '' })
    }
    if ($f.SmsCfg) {
        try { $ini = [System.IO.File]::ReadAllText((Join-Path $env:windir 'SMSCFG.ini')); if ($ini -match 'Unique Identifier=(\S+)') { $f.IniGuid = $Matches[1]; Add-F 'Client install' 'SMSCFG.ini identity' 'INFO' $f.IniGuid } } catch { }
    }

    $src = $cfg.ClientSource
    $f.SourceOk = (Test-Path -LiteralPath (Join-Path $src 'ccmsetup.exe')) -and (@('x64\client.msi', 'client.msi', 'i386\client.msi') | Where-Object { Test-Path -LiteralPath (Join-Path $src $_) }).Count -gt 0
    $srcVer = ''; try { $srcVer = [System.Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path $src 'ccmsetup.exe')).FileVersion } catch { }
    Add-F 'Client install' 'Local client source' $(if ($f.SourceOk) { 'OK' } else { 'WARN' }) $(if ($f.SourceOk) { "$src  (ccmsetup $srcVer)" } else { "$src is missing ccmsetup.exe or x64\client.msi - copy the whole \\<MP>\SMS_<site>\Client folder." })

    # ============================================================ Registration
    Show-Step 'client registration'
    $f.SiteCode = ''; $f.CurrentMp = ''; $f.PolicyCount = -1; $f.TrustedRootKey = $null
    if ($f.WmiCcm) {
        try { $f.SiteCode = [string](Invoke-CimMethod -Namespace root\ccm -ClassName SMS_Client -MethodName GetAssignedSite -ErrorAction Stop).sSiteCode } catch { }
        try { $f.CurrentMp = [string](Get-CimInstance -Namespace root\ccm -ClassName SMS_Authority -ErrorAction Stop | Select-Object -First 1).CurrentManagementPoint } catch { }
        try { $f.PolicyCount = @(Get-CimInstance -Namespace 'root\ccm\Policy\Machine\ActualConfig' -ClassName CCM_ComponentClientConfig -ErrorAction Stop).Count } catch { $f.PolicyCount = 0 }
        try { $trk = Get-CimInstance -Namespace 'root\ccm\LocationServices' -ClassName TrustedRootKey -ErrorAction Stop | Select-Object -First 1; $f.TrustedRootKey = [bool]($trk -and $trk.TrustedRootKey) } catch { }
    }
    if (-not $f.SiteCode) { try { $f.SiteCode = [string](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\SMS\Mobile Client' -ErrorAction Stop).AssignedSiteCode } catch { } }
    if ($f.ServiceExists) {
        if (-not $f.SiteCode) { Add-F 'Client registration' 'Site assignment' 'FAIL' 'Not assigned to a site.' 'Boundaries / AD publishing, or reinstall with SMSSITECODE=<site>' }
        elseif ($cfg.SiteCode -and $f.SiteCode -ne $cfg.SiteCode) { Add-F 'Client registration' 'Site assignment' 'WARN' "Assigned to $($f.SiteCode); the environment expects $($cfg.SiteCode)." }
        else { Add-F 'Client registration' 'Site assignment' 'OK' $f.SiteCode }
        if ($f.CurrentMp) { Add-F 'Client registration' 'Current management point' 'INFO' $f.CurrentMp }
        if ($null -ne $f.TrustedRootKey) { Add-F 'Client registration' 'Trusted root key' $(if ($f.TrustedRootKey) { 'OK' } else { 'WARN' }) $(if ($f.TrustedRootKey) { 'Present.' } else { 'Missing - the client cannot verify the site (reinstall with RESETKEYINFORMATION=TRUE).' }) }
    }
    $ri = Get-CcmRegistrationInfo
    $f.RegState = $ri.State; $f.RegCode = $ri.Code; $f.Approval = $ri.Approval; $f.HardwareId = $ri.HardwareId; $f.ClientGuid = $ri.Guid
    if ($ri.HardwareId) { Add-F 'Identity' 'Client hardware ID' 'INFO' $ri.HardwareId }
    if ($ri.Guid) { Add-F 'Identity' 'Client GUID' 'INFO' $ri.Guid }
    if ($f.ServiceExists) {
        switch ($ri.State) {
            'Registered' {
                if ($ri.Approval -eq '0') { Add-F 'Client registration' 'Registration' 'WARN' "Registered ($($ri.Guid)) but NOT approved." 'Step: Clear the device on the server (Approve)' }
                else { Add-F 'Client registration' 'Registration' 'OK' ("Registered {0}, approval {1}. ({2})" -f $ri.Guid, $ri.Approval, $ri.LastTime) }
            }
            'Rejected' { Add-F 'Client registration' 'Registration' 'FAIL' ("Server rejected registration request: {0}  ({1}). The server has a blocked / revoked / conflicting record for this device." -f $ri.Code, $ri.LastTime) 'Steps: Clear the device on the server, then Reset the client identity' }
            'NoCert'   { Add-F 'Client registration' 'Registration' 'FAIL' ("No client certificate to register with ({0})." -f $ri.LastTime) 'See Crypto: key storage / KeyIso / TPM' }
            'Pending'  { Add-F 'Client registration' 'Registration' 'WARN' $ri.LastLine 'Step: Clear the device on the server (Approve)' }
            'Sending'  { Add-F 'Client registration' 'Registration' 'WARN' ("Registration request sent, no answer logged yet ({0}). Re-check after the next 5-minute cycle." -f $ri.LastTime) }
            default    { Add-F 'Client registration' 'Registration' 'WARN' "No registration result in ClientIDManagerStartup.log ($($ri.State))." }
        }
        if ($f.PolicyCount -ge 0) {
            if ($f.PolicyCount -eq 0) { Add-F 'Client registration' 'Machine policy received' 'FAIL' 'No client component policy in WMI: the Control Panel applet shows only Machine / User Policy actions.' 'Fix registration first; then Run client actions' }
            else { Add-F 'Client registration' 'Machine policy received' 'OK' "$($f.PolicyCount) client component settings applied (full action list available)." }
        }
        $msgLog = Get-CcmLogEntries -Path (Join-Path $script:CcmLogDir 'CcmMessaging.log') -MaxBytes 131072
        $since = (Get-Date).AddHours(-2)
        $errs = @($msgLog | Where-Object { $_.Type -eq 3 -and $_.When -gt $since })
        if ($errs.Count) { Add-F 'Client registration' 'MP messaging errors (2 h)' 'WARN' ("{0} error(s); last: {1}" -f $errs.Count, $errs[-1].Message) 'Logs: Client: MP messaging' }
        $sc = Test-Path -LiteralPath (Join-Path $env:windir 'CCM\SCClient.exe')
        Add-F 'Client registration' 'Software Center' $(if ($sc) { 'OK' } else { 'WARN' }) $(if ($sc) { 'SCClient.exe present (shortcut appears once policy arrives).' } else { 'SCClient.exe missing - incomplete install.' })
    }

    # ============================================================ Device Guard
    Show-Step 'Device Guard / Secure Boot'
    try {
        $pol = Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceGuard' -ErrorAction Stop
        if ($pol.EnableVirtualizationBasedSecurity -eq 1) {
            $dg = Get-CimInstance -Namespace root\Microsoft\Windows\DeviceGuard -ClassName Win32_DeviceGuard -ErrorAction Stop
            $sb = $null; if ($f.Elevated) { try { $sb = Confirm-SecureBootUEFI -ErrorAction Stop } catch { } }
            if ($dg.VirtualizationBasedSecurityStatus -eq 2) { Add-F 'Device Guard' 'VBS / Credential Guard policy' 'OK' 'Policy applied, VBS running.' }
            else {
                $why = $(if ($sb -eq $false) { 'Secure Boot is OFF - enable it in the firmware (suspend BitLocker first).' } else { 'Requirements missing - see DeviceGuard event 7001.' })
                Add-F 'Device Guard' 'VBS / Credential Guard policy' 'WARN' "GPO enables VBS but it is not running: $why (Causes the {F312195E...} Group Policy error. Unrelated to the client.)"
            }
        }
    } catch { }

    # ============================================================ verdict
    Show-Step 'verdict'
    $v = Resolve-CcmState -Facts $f -Config $cfg
    $res = [pscustomobject]@{
        Time            = Get-Date
        Computer        = $env:COMPUTERNAME
        Deep            = [bool]$Deep
        Findings        = $Findings
        Facts           = $f
        State           = $v.State
        StateLevel      = $v.Level
        StateDetail     = $v.Detail
        Recommended     = $v.Steps
        InstallReady    = $v.InstallReady
        InstallBlockers = $v.InstallBlockers
        ClientPresent   = $v.ClientPresent
        ShareReady      = $v.ShareReady
        ShareBlockers   = $v.ShareBlockers
        Config          = $cfg
    }
    $st = Get-CcmTSState
    $st.Discovery = $res
    try {
        $c = @($Findings | Group-Object Status | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ' '
        $App.Log('INFO', 'Discovery', "State='$($res.State)' $c recommended=$($res.Recommended -join ',') installReady=$($res.InstallReady)")
        $App.LogAction("Discovery: $($res.State) - $($res.StateDetail)")
        $App.SetStatus("Discovery finished: $($res.State)", $(switch ($res.StateLevel) { 'OK' { 'ok' } 'FAIL' { 'err' } default { 'warn' } }))
    } catch { }
    foreach ($h in @($st.ScanHandlers)) { try { & $h $res } catch { try { $App.Log('WARN', 'Discovery', "scan handler: $($_.Exception.Message)") } catch { } } }
    return $res
}

# The verdict: first matching state wins; Windows-health findings add steps.
function Resolve-CcmState {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [hashtable]$Facts, $Config)
    $f = $Facts
    $steps = New-Object System.Collections.Generic.List[string]
    $state = ''; $level = 'WARN'; $detail = ''

    if (-not $f.Elevated) {
        $state = 'Not elevated'; $level = 'FAIL'; $detail = 'Run the tool as administrator, then run discovery again.'; $steps.Add('Elevate')
    }
    elseif ($f.CcmSetupRunning) {
        $state = 'Client setup in progress'; $detail = 'ccmsetup.exe is running. Wait until it finishes (Logs: ccmsetup.log), then Verify.'
    }
    elseif (-not $f.ServiceExists -and -not $f.Remnants) {
        $state = 'Client not installed'; $level = 'FAIL'; $detail = 'No client on this machine. Fix the Windows findings below, clear the server side, then install.'
        $steps.Add('ServerSide'); $steps.Add('InstallLocal')
    }
    elseif (-not $f.ServiceExists -and $f.Remnants) {
        $state = 'Remnants of a removed client'; $level = 'FAIL'; $detail = 'The client was removed but left files / WMI / registry behind - installs over this rarely work. Clean up, reboot, install.'
        $steps.Add('Cleanup'); $steps.Add('ServerSide'); $steps.Add('InstallLocal')
    }
    elseif (-not $f.CcmExe -or -not $f.WmiCcm) {
        $state = 'Broken client install'; $level = 'FAIL'; $detail = 'The service exists but client components are missing. Uninstall, clean up, reboot, reinstall.'
        $steps.Add('Uninstall'); $steps.Add('Cleanup'); $steps.Add('ServerSide'); $steps.Add('InstallLocal')
    }
    elseif ($f.ServiceStatus -ne 'Running') {
        $state = 'SMS Agent Host not running'; $level = 'FAIL'; $detail = "CcmExec is $($f.ServiceStatus)."
        $steps.Add('Services'); $steps.Add('RestartCcmExec')
    }
    elseif (-not $f.KspOk -or ($f.CertCount -eq 0 -and ($f.CertMaintError -or $f.RegState -eq 'NoCert'))) {
        $state = 'Client cannot create its certificates'; $level = 'FAIL'
        if (-not $f.KspOk -or $f.CertMaintError -match '0x800706d9' -or $f.KeyIsoStart -eq 'Disabled') {
            $detail = 'Key storage is unavailable (CNG Key Isolation / KeyIso). Repair services, restart the agent.'
            $steps.Add('Services'); $steps.Add('RestartCcmExec')
        } else {
            $detail = "Certificate creation fails: $($f.CertMaintError). If it is TPM related: uninstall, clean up, remove the TPM key, reinstall."
            $steps.Add('RestartCcmExec'); $steps.Add('Uninstall'); $steps.Add('Cleanup'); $steps.Add('RemoveTpmKey'); $steps.Add('InstallLocal')
        }
    }
    elseif (-not $f.SiteCode) {
        $state = 'Not assigned to a site'; $level = 'FAIL'; $detail = 'The client has no site code. Restart the agent; if it stays unassigned, reinstall with SMSSITECODE.'
        $steps.Add('RestartCcmExec'); $steps.Add('Uninstall'); $steps.Add('Cleanup'); $steps.Add('InstallLocal')
    }
    elseif ($f.RegState -eq 'Rejected') {
        $state = "Registration rejected (code $($f.RegCode))"; $level = 'FAIL'
        $detail = 'The site refuses this identity: blocked, revoked or conflicting record. Clear it on the server FIRST, then reset the identity (or reinstall).'
        $steps.Add('ServerSide'); $steps.Add('ResetIdentity')
    }
    elseif ($f.RegState -eq 'Pending' -or ($f.RegState -eq 'Registered' -and $f.Approval -eq '0')) {
        $state = 'Registered - waiting for approval'; $detail = 'Approve the device in the console (or enable automatic approval for trusted domains).'
        $steps.Add('ServerSide')
    }
    elseif ($f.RegState -ne 'Registered') {
        $state = 'Not registered yet'; $detail = "Registration state: $($f.RegState). The client retries every ~5 minutes."
        if (-not $f.MpListOk) { $detail += ' The MP is not answering - fix that first.' }
        $steps.Add('RestartCcmExec'); $steps.Add('ServerSide')
    }
    elseif ($f.PolicyCount -eq 0) {
        $state = 'Registered - no policy yet'; $detail = 'Registered, but no client policy has arrived. Trigger policy; if nothing changes, reset policy and check the MP.'
        $steps.Add('TriggerActions'); $steps.Add('ResetPolicy')
    }
    else {
        $state = 'Healthy'; $level = 'OK'; $detail = 'Installed, registered, approved and receiving policy.'
    }

    # Windows health adds steps whatever the client state; they come FIRST
    # (in catalog order), then the client steps in the order the state needs
    # them (e.g. server side before an identity reset), then Verify.
    $health = New-Object System.Collections.Generic.List[string]
    if ($f.Elevated) {
        if ($f.DisabledServices.Count -or $f.StoppedServices.Count) { $health.Add('Services') }
        if ($null -ne $f.TimeOffsetSec -and [Math]::Abs($f.TimeOffsetSec) -gt 300) { $health.Add('TimeSync') }
        if ($f.WmiConsistent -eq $false) { $health.Add('WmiSalvage') }
        if ($f.StoreState -eq 'Repairable' -or $f.SfcCannotRepair -gt 0) { $health.Add('DismRestoreSource'); $health.Add('Sfc') }
        if ($f.DiskFreeGB -ge 0 -and $f.DiskFreeGB -lt 8) { $health.Add('DismCleanup') }
    }

    # install readiness (gate for the install steps)
    $b = New-Object System.Collections.Generic.List[string]
    if (-not $f.Elevated) { $b.Add('not elevated') }
    if ($f.CcmSetupRunning) { $b.Add('ccmsetup is already running') }
    if ($f.ServiceExists) { $b.Add('a client is installed (uninstall + clean up first, or use /forceinstall)') }
    if ($f.Remnants) { $b.Add('client remnants present (run Remove client leftovers + reboot)') }
    if ($f.PendingReboot) { $b.Add('a reboot is pending') }
    if (-not $f.KspOk) { $b.Add('software key storage provider fails (KeyIso)') }
    if ($f.KeyIsoStart -eq 'Disabled') { $b.Add('CNG Key Isolation (KeyIso) is disabled') }
    foreach ($s in @('Winmgmt', 'BITS', 'msiserver', 'CryptSvc')) { if ($f.DisabledServices -contains $s) { $b.Add("$s is disabled") } }
    if ($f.WmiConsistent -eq $false) { $b.Add('WMI repository inconsistent') }
    if ($f.DiskFreeGB -ge 0 -and $f.DiskFreeGB -lt 2) { $b.Add('less than 2 GB free') }
    if ($f.SecureChannel -eq $false) { $b.Add('domain secure channel broken') }
    if ($null -ne $f.TimeOffsetSec -and [Math]::Abs($f.TimeOffsetSec) -gt 300) { $b.Add('clock more than 5 minutes off') }
    if (-not $f.MpResolves) { $b.Add('MP name does not resolve') }
    elseif (-not $f.MpTcp) { $b.Add('MP not reachable on 80/443') }
    elseif (-not $f.MpListOk) { $b.Add('MP does not answer (mplist)') }
    if (-not $Config -or -not $Config.SiteCode) { $b.Add('no site code configured') }
    $common = @($b)
    $local = @($common); if (-not $f.SourceOk) { $local += 'local client source incomplete' }
    $share = @($common); if (-not $f.ShareOk) { $share += 'site client share not reachable' }

    # recommended steps: health (catalog order), then the state's own steps, then Verify
    $order = @{}; foreach ($c in (Get-CcmStepCatalog)) { $order[$c.Id] = $c.Order }
    $all = New-Object System.Collections.Generic.List[string]
    foreach ($x in @($health | Sort-Object { if ($order.ContainsKey($_)) { $order[$_] } else { 999 } })) { if (-not $all.Contains($x)) { $all.Add($x) } }
    foreach ($x in $steps) { if (-not $all.Contains($x)) { $all.Add($x) } }
    if ($f.Elevated -and ($level -ne 'OK' -or $all.Count)) { $all.Add('Verify') }
    $uniq = @($all)
    if ($uniq -contains 'InstallLocal' -and $local.Count -and $share.Count -eq 0) { $uniq = @($uniq | ForEach-Object { if ($_ -eq 'InstallLocal') { 'InstallShare' } else { $_ } }) }

    [pscustomobject]@{
        State = $state; Level = $level; Detail = $detail; Steps = $uniq
        ClientPresent = [bool]$f.ServiceExists
        InstallReady = ($local.Count -eq 0); InstallBlockers = $local
        ShareReady = ($share.Count -eq 0); ShareBlockers = $share
    }
}

# One line for banners / reports: can an install run now?
function Get-CcmInstallReadinessText {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Result)
    $other = @($Result.InstallBlockers | Where-Object { $_ -notmatch 'a client is installed' })
    if ($Result.ClientPresent) {
        if ($Result.StateLevel -eq 'OK') { return 'not needed - a healthy client is installed.' }
        return 'a client is installed: reinstall = Uninstall + Remove leftovers + reboot (or /forceinstall)' + $(if ($other.Count) { '; also blocked by: ' + ($other -join '; ') } else { '; no other blockers.' })
    }
    if ($Result.InstallReady) { return 'READY from the local client source.' }
    if ($Result.ShareReady) { return 'ready from the site share (local source incomplete).' }
    return 'BLOCKED - ' + ($other -join '; ')
}

function Format-CcmReport {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Result)
    $sb = New-Object System.Text.StringBuilder
    $f = $Result.Facts
    [void]$sb.AppendLine("CCM Client Troubleshooter - discovery report")
    [void]$sb.AppendLine(("Computer : {0}    Time: {1:yyyy-MM-dd HH:mm:ss}    Deep checks: {2}" -f $Result.Computer, $Result.Time, $Result.Deep))
    [void]$sb.AppendLine(("Serial   : {0}    SMBIOS GUID: {1}" -f $f.Serial, $f.SmbiosGuid))
    [void]$sb.AppendLine(("Client   : GUID {0}    HardwareID {1}" -f $f.ClientGuid, $f.HardwareId))
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine("STATE    : $($Result.State)")
    [void]$sb.AppendLine("           $($Result.StateDetail)")
    $names = @{}; foreach ($c in (Get-CcmStepCatalog)) { $names[$c.Id] = "$($c.Order). $($c.Title)" }
    [void]$sb.AppendLine('NEXT     : ' + $(if ($Result.Recommended.Count) { ($Result.Recommended | ForEach-Object { $names[$_] }) -join '  ->  ' } else { '(nothing)' }))
    [void]$sb.AppendLine('INSTALL  : ' + (Get-CcmInstallReadinessText -Result $Result))
    [void]$sb.AppendLine('')
    foreach ($g in ($Result.Findings | Group-Object Category)) {
        [void]$sb.AppendLine("== $($g.Name)")
        foreach ($x in $g.Group) {
            [void]$sb.AppendLine(("  [{0,-4}] {1}: {2}" -f $x.Status, $x.Check, $x.Detail))
            if ($x.Fix) { [void]$sb.AppendLine("         -> $($x.Fix)") }
        }
    }
    return $sb.ToString()
}
