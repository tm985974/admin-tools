# SAM_Helpers.psm1   (LITE TIER)
#
# Generic helpers ported from SCCM_App_Lifecycle_Manager.ps1 v8.4:
# versions, folders, JSON files, installers, MSI ProductCode, robocopy,
# WQL quoting and device-name parsing.

$global:SamVersionFolderRegex = '^\d+(\.\d+){1,4}$'
$global:SamGuidPattern        = '\{[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\}'

function Compare-SamVersion {
    param([string]$A, [string]$B)
    if ([string]::IsNullOrWhiteSpace($A) -and [string]::IsNullOrWhiteSpace($B)) { return 0 }
    if ([string]::IsNullOrWhiteSpace($A)) { return -1 }
    if ([string]::IsNullOrWhiteSpace($B)) { return 1 }
    $pa = $A.Split('.'); $pb = $B.Split('.')
    $n = [Math]::Max($pa.Count, $pb.Count)
    for ($i = 0; $i -lt $n; $i++) {
        [long]$x = 0; [long]$y = 0
        if ($i -lt $pa.Count) { [void][long]::TryParse($pa[$i], [ref]$x) }
        if ($i -lt $pb.Count) { [void][long]::TryParse($pb[$i], [ref]$y) }
        if ($x -gt $y) { return 1 }
        if ($x -lt $y) { return -1 }
    }
    return 0
}

function Format-SamVer {
    param($Value)
    if ($Value) { return [string]$Value } else { return 'n/a' }
}

# @{Version; Path} of the highest version-named subfolder, or $null.
function Get-SamLatestVersionFolder {
    param([string]$Path)
    if (-not $Path) { return $null }
    try {
        if (-not [IO.Directory]::Exists($Path)) { return $null }
        $best = $null
        foreach ($d in [IO.Directory]::EnumerateDirectories($Path)) {
            $n = [IO.Path]::GetFileName($d)
            if ($n -match $global:SamVersionFolderRegex) {
                if (-not $best -or (Compare-SamVersion $n $best.Version) -gt 0) {
                    $best = [pscustomobject]@{ Version = $n; Path = $d }
                }
            }
        }
        return $best
    }
    catch {
        Write-SamLog "  Cannot read $Path : $($_.Exception.Message)" -Level Warning
        return $null
    }
}

# Cheap "folder contains at least one file" check (stops at the first file).
function Test-SamFolderHasFiles {
    param([string]$Path)
    try {
        if (-not [IO.Directory]::Exists($Path)) { return $false }
        $e = [IO.Directory]::EnumerateFiles($Path, '*', [IO.SearchOption]::AllDirectories).GetEnumerator()
        return $e.MoveNext()
    }
    catch { return $false }
}

# "Adobe Reader DC 24.1.2" -> Base "Adobe Reader DC", Version "24.1.2"
function Split-SamAppNameVersion {
    param([string]$DisplayName, [string]$SoftwareVersion)
    $name = [string]$DisplayName
    $m = $null
    if ($SoftwareVersion) {
        $m = [regex]::Match($name, '(?<![\d.])' + [regex]::Escape($SoftwareVersion) + '(?![\d.]*\d)')
        if (-not $m.Success) { $m = $null }
    }
    if (-not $m) {
        $all = [regex]::Matches($name, '(?<![\d.])\d+(?:\.\d+)+')
        if ($all.Count -gt 0) { $m = $all[$all.Count - 1] }
    }
    if (-not $m) { return [pscustomobject]@{ Base = $name.Trim(); Version = $null } }
    $base = $name.Remove($m.Index, $m.Length) -replace '\s{2,}', ' '
    $base = ($base.Trim() -replace '[\s\-_]+[vV]?$', '').Trim()
    return [pscustomobject]@{ Base = $base; Version = $m.Value }
}

function Edit-SamTextLiteral {
    param([string]$Text, [string]$Find, [string]$With)
    if ([string]::IsNullOrEmpty($Text) -or [string]::IsNullOrEmpty($Find) -or $null -eq $With) { return $Text }
    return [regex]::Replace($Text, [regex]::Escape($Find), $With.Replace('$', '$$'),
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
}

# Whole version numbers only ("1.2" will not touch "11.2" or "1.2.5").
function Edit-SamTextVersion {
    param([string]$Text, [string]$Old, [string]$New)
    if ([string]::IsNullOrEmpty($Text) -or -not $Old -or -not $New -or $Old -eq $New) { return $Text }
    return [regex]::Replace($Text, '(?<![\d.])' + [regex]::Escape($Old) + '(?![\d.]*\d)', $New.Replace('$', '$$'))
}

function Read-SamAppConfig {
    param([string]$Path)
    return ([IO.File]::ReadAllText($Path) | ConvertFrom-Json)
}

function Save-SamAppConfig {
    param($Config, [string]$Path)
    $json = $Config | ConvertTo-Json -Depth 12
    [IO.File]::WriteAllText($Path, $json, (New-Object Text.UTF8Encoding($false)))
}

# Sets a property on a ConvertFrom-Json object, adding it when missing.
function Set-SamJsonProp {
    param($Object, [string]$Name, $Value)
    if ($null -eq $Object) { return }
    if ($Object.PSObject.Properties[$Name]) { $Object.$Name = $Value }
    else { $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force }
}

# Site a JSON config belongs to: SiteCode, else ExportedFrom.SCCMSite, else ''.
function Get-SamJsonSite {
    param($Config)
    if (-not $Config) { return '' }
    if ($Config.PSObject.Properties['SiteCode'] -and [string]$Config.SiteCode) { return ([string]$Config.SiteCode).Trim().ToUpper() }
    if ($Config.ExportedFrom -and [string]$Config.ExportedFrom.SCCMSite) { return ([string]$Config.ExportedFrom.SCCMSite).Trim().ToUpper() }
    return ''
}

function Backup-SamJson {
    param([string]$Path)
    try {
        $dir = [IO.Path]::Combine([IO.Path]::GetDirectoryName($Path), '_Backup')
        if (-not [IO.Directory]::Exists($dir)) { [void][IO.Directory]::CreateDirectory($dir) }
        $dest = [IO.Path]::Combine($dir, ('{0}_{1}.json' -f [IO.Path]::GetFileNameWithoutExtension($Path), (Get-Date -Format 'yyyyMMdd_HHmmss')))
        [IO.File]::Copy($Path, $dest, $true)
        Write-SamLog "  Backup: $dest"
    }
    catch { Write-SamLog "  Could not back up $Path : $($_.Exception.Message)" -Level Warning }
}

function New-SamInstallerInfo {
    param([string]$FullPath)
    return [pscustomobject]@{
        Name     = [IO.Path]::GetFileName($FullPath)
        FullPath = $FullPath
        Type     = [IO.Path]::GetExtension($FullPath).TrimStart('.').ToUpper()
    }
}

# Primary installer: the name the JSON already uses wins, then the same extension
# at the top level, then anywhere. Otherwise MSI > EXE > PS1.
function Find-SamPrimaryInstaller {
    param([string]$Folder, [string]$PreferName)
    if (-not $Folder -or -not [IO.Directory]::Exists($Folder)) { return $null }
    try {
        if ($PreferName) {
            $hit = [IO.Directory]::GetFiles($Folder, $PreferName, [IO.SearchOption]::AllDirectories) | Select-Object -First 1
            if ($hit) { return New-SamInstallerInfo $hit }
            $patterns = @('*' + [IO.Path]::GetExtension($PreferName))
        }
        else { $patterns = @('*.msi', '*.exe', '*.ps1') }

        foreach ($scope in @([IO.SearchOption]::TopDirectoryOnly, [IO.SearchOption]::AllDirectories)) {
            foreach ($p in $patterns) {
                $f = [IO.Directory]::GetFiles($Folder, $p, $scope) | Sort-Object | Select-Object -First 1
                if ($f) { return New-SamInstallerInfo $f }
            }
        }
    }
    catch { Write-SamLog "  Error searching $Folder : $($_.Exception.Message)" -Level Warning }
    return $null
}

function Find-SamFirstFile {
    param([string]$Folder, [string]$Pattern)
    if (-not $Folder -or -not [IO.Directory]::Exists($Folder)) { return $null }
    try {
        $f = [IO.Directory]::GetFiles($Folder, $Pattern, [IO.SearchOption]::TopDirectoryOnly) | Sort-Object | Select-Object -First 1
        if (-not $f) { $f = [IO.Directory]::GetFiles($Folder, $Pattern, [IO.SearchOption]::AllDirectories) | Sort-Object | Select-Object -First 1 }
        return $f
    }
    catch { return $null }
}

# Reads ProductCode and RELEASES the COM objects so the .msi is not left locked.
function Get-SamMsiProductCode {
    param([string]$MsiPath)
    if (-not $MsiPath -or -not [IO.File]::Exists($MsiPath)) { return $null }
    $wi = $null; $db = $null; $view = $null; $rec = $null
    try {
        $wi   = New-Object -ComObject WindowsInstaller.Installer
        $db   = $wi.GetType().InvokeMember('OpenDatabase', 'InvokeMethod', $null, $wi, @($MsiPath, 0))
        $view = $db.GetType().InvokeMember('OpenView', 'InvokeMethod', $null, $db, @("SELECT Value FROM Property WHERE Property = 'ProductCode'"))
        [void]$view.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $view, $null)
        $rec  = $view.GetType().InvokeMember('Fetch', 'InvokeMethod', $null, $view, $null)
        if ($rec) { return ([string]$rec.GetType().InvokeMember('StringData', 'GetProperty', $null, $rec, 1)).Trim() }
        return $null
    }
    catch {
        Write-SamLog "  Could not read ProductCode from $MsiPath : $($_.Exception.Message)" -Level Warning
        return $null
    }
    finally {
        if ($view) { try { [void]$view.GetType().InvokeMember('Close', 'InvokeMethod', $null, $view, $null) } catch { } }
        foreach ($o in @($rec, $view, $db, $wi)) {
            if ($o) { try { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($o) } catch { } }
        }
        [GC]::Collect(); [GC]::WaitForPendingFinalizers()
    }
}

# Robocopy in a hidden process while the UI keeps pumping. Only changed files are
# copied, so re-running an interrupted copy is safe. Exit 0-7 = success, 8+ = failure.
function Invoke-SamRobocopy {
    param([string]$Source, [string]$Destination)
    $src = $Source.TrimEnd('\'); $dst = $Destination.TrimEnd('\')
    if (-not [IO.Directory]::Exists($src)) { Write-SamLog "  Source not found: $src" -Level Error; return $false }
    $dir = [IO.Path]::Combine([string]$global:SAM.LogDir, 'Robocopy')
    try { if (-not [IO.Directory]::Exists($dir)) { [void][IO.Directory]::CreateDirectory($dir) } } catch { }
    $rcLog = [IO.Path]::Combine($dir, ('robocopy_{0}.log' -f (Get-Date -Format 'yyyyMMdd_HHmmss_fff')))
    $threads = [int]$global:SAM.Settings.RobocopyThreads
    if ($threads -lt 1) { $threads = 8 }
    $argLine = '"{0}" "{1}" /E /COPY:DAT /R:2 /W:5 /MT:{2} /NP /NDL /NFL /LOG:"{3}"' -f $src, $dst, $threads, $rcLog
    Write-SamLog "  robocopy $src  ->  $dst"
    $p = Start-Process -FilePath 'robocopy.exe' -ArgumentList $argLine -WindowStyle Hidden -PassThru
    $null = $p.Handle   # required so ExitCode is populated
    while (-not $p.HasExited) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 150
    }
    $code = $p.ExitCode
    try {
        foreach ($l in [IO.File]::ReadAllLines($rcLog)) {
            if ($l -match '^\s*(Dirs|Files|Bytes|Speed)\s*:') { Write-SamLog ('    ' + $l.Trim()) }
        }
    } catch { }
    if ($code -ge 8) { Write-SamLog "  robocopy FAILED (exit code $code). Details: $rcLog" -Level Error; return $false }
    Write-SamLog "  robocopy OK (exit code $code)" -Level Success
    return $true
}

function ConvertTo-SamWql {
    param([string]$Value)
    return "'" + (([string]$Value) -replace '\\', '\\' -replace "'", "\'") + "'"
}

# Pasted text -> unique device names. One per line or separated by commas,
# semicolons, tabs or spaces. "pc01.contoso.com" and "CONTOSO\pc01" become "PC01".
function ConvertTo-SamDeviceNames {
    param([string]$Text)
    $seen = @{}
    $out = New-Object System.Collections.ArrayList
    foreach ($tok in ([string]$Text -split '[\r\n,;\t ]+')) {
        $n = $tok.Trim().Trim('"', "'")
        if (-not $n) { continue }
        if ($n.Contains('\')) { $n = $n.Split('\')[-1] }
        if ($n.Contains('.')) { $n = $n.Split('.')[0] }
        $n = $n.ToUpper()
        if ($n -and -not $seen.ContainsKey($n)) { $seen[$n] = $true; [void]$out.Add($n) }
    }
    return $out.ToArray()
}
