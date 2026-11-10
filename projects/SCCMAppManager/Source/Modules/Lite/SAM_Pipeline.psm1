# SAM_Pipeline.psm1   (LITE TIER)
#
# Update Pipeline status engine (ported from v8.4), per application keyed by
# the JSON file / AppBaseName:
#
#   SCCM app       --(Export)----------->  <LocalRoot>\<AppBaseName>_<SITE>.json
#   Incoming share --(1. Pull)---------->  <LocalRoot>\<AppBaseName>\<Version>\
#   JSON           --(2. Update JSON)--->  new version, commands, detection
#   Local          --(3. Upload)-------->  <Repository>\<AppBaseName>\<Version>\
#   JSON           --(4. Create)-------->  new SCCM application + script DT
#   Application    --(5. Deploy...)----->  any collection, Required / Available
#
# Multi-site: a JSON belongs to the site in its SiteCode (or ExportedFrom.SCCMSite).
# The scan shows the JSON files of the ACTIVE environment's site plus untagged
# ones; other sites' JSON files are counted and hidden. The local content folder
# <LocalRoot>\<AppBaseName>\<Version> is shared by every site's JSON.

$global:SamActPull   = '1. Pull from Incoming'
$global:SamActJson   = '2. Update JSON'
$global:SamActUpload = '3. Upload to Repository'
$global:SamActCreate = '4. Create in SCCM'
$global:SamActDeploy = '5. Deploy to Test'
$global:SamActDone   = 'Up to date'

function Test-SamCanPull       { param($r) return [bool]($r.IncomingVersion -and (Compare-SamVersion $r.IncomingVersion $r.LocalVersion) -gt 0) }
function Test-SamCanUpdateJson { param($r) return [bool]($r.Config -and $r.LocalVersion -and (Compare-SamVersion $r.LocalVersion $r.JsonVersion) -gt 0) }
function Test-SamCanUpload     { param($r) return [bool]($r.LocalHasJsonVersion -and -not $r.RepoHasJsonVersion) }
function Test-SamCanCreate     { param($r) return [bool]($global:SAM.Connected -and $r.RepoHasJsonVersion -and -not $r.AppExists -and -not $r.Error) }
function Test-SamCanDeploy     { param($r) return [bool]($global:SAM.Connected -and $r.AppExists -and -not $r.TestDeployed) }

function Get-SamNextAction {
    param($r)
    if ($r.Error)                       { return "Error: $($r.Error)" }
    if (Test-SamCanPull $r)             { return $global:SamActPull }
    if (Test-SamCanUpdateJson $r)       { return $global:SamActJson }
    if (-not $r.RepoHasJsonVersion) {
        if ($r.LocalHasJsonVersion)     { return $global:SamActUpload }
        return 'Missing source files'
    }
    if (-not $global:SAM.Connected)     { return '(connect to SCCM)' }
    if (-not $r.AppExists)              { return $global:SamActCreate }
    if (-not $r.TestDeployed)           { return $global:SamActDeploy }
    return $global:SamActDone
}

function Update-SamRowSccmStatus {
    param($r)
    $S = $global:SAM
    $r.AppExists = $false; $r.Deployments = 0; $r.TestDeployed = $false; $r.SccmLatest = $null
    if ($S.Connected -and $r.AppName) {
        $app = $S.Cache.AppsByName[$r.AppName]
        if ($app) {
            $r.AppExists    = $true
            $r.Deployments  = $app.Deployments
            $r.TestDeployed = $app.TestDeployed
        }
        $family = $S.Cache.AppsByBase[$r.BaseName]
        if ($family) {
            foreach ($a in $family) {
                $v = if ($a.NameVersion) { $a.NameVersion } else { $a.Version }
                if ((Compare-SamVersion $v $r.SccmLatest) -gt 0) { $r.SccmLatest = $v }
            }
        }
    }
    $r.NextAction = Get-SamNextAction $r
    if ($S.Connected -and -not $r.Error -and $r.SccmLatest -and (Compare-SamVersion $r.SccmLatest $r.JsonVersion) -gt 0) {
        $r.NextAction += "  [NEWER $($r.SccmLatest) IN SCCM]"
    }
}

# Apps in SCCM of the same family (base name) with a higher version than $Version.
function Get-SamNewerApps {
    param([string]$BaseName, [string]$Version)
    $out = New-Object System.Collections.ArrayList
    if (-not $BaseName -or -not $Version) { return $out.ToArray() }
    $family = $global:SAM.Cache.AppsByBase[$BaseName]
    if ($family) {
        foreach ($a in $family) {
            $v = if ($a.NameVersion) { $a.NameVersion } else { $a.Version }
            if ((Compare-SamVersion $v $Version) -gt 0) { [void]$out.Add($a) }
        }
    }
    return $out.ToArray()
}

# "Are you sure?" gate for Create / Deploy when a newer version already exists.
# Items: objects with Key (app name), Base, Version. Returns the keys that may proceed.
function Confirm-SamNoNewerVersion {
    param($Items, [string]$Action)
    $lines = New-Object System.Collections.ArrayList
    $flagged = @{}
    foreach ($i in @($Items)) {
        $newer = @(Get-SamNewerApps -BaseName $i.Base -Version $i.Version)
        if (-not $newer.Count) { continue }
        $flagged[$i.Key] = $true
        $desc = ($newer | Sort-Object Name | ForEach-Object {
            $state = if ($_.Deployments -gt 0) { "DEPLOYED to $($_.Deployments) collection(s)" } else { 'not deployed' }
            if ($_.Retired) { $state += ', retired' }
            '{0} ({1})' -f $_.Name, $state
        }) -join '; '
        [void]$lines.Add("$($i.Key)`r`n      newer: $desc")
        Write-SamLog "  WARNING: $($i.Key) - a newer version already exists in SCCM: $desc" -Level Warning
    }
    $all = @(@($Items) | ForEach-Object { $_.Key })
    if (-not $lines.Count) { return $all }

    $msg = "A NEWER version of these applications already exists in SCCM:`r`n`r`n" +
           ((@($lines.ToArray()) | Select-Object -First 15 | ForEach-Object { "  - $_" }) -join "`r`n")
    if ($lines.Count -gt 15) { $msg += "`r`n  ... and $($lines.Count - 15) more (see the activity log)" }
    $msg += "`r`n`r`nAre you sure you want to $Action the older version(s)?`r`n`r`n" +
            "Yes = $Action anyway`r`nNo = skip these, continue with the rest`r`nCancel = stop"
    $ans = [System.Windows.Forms.MessageBox]::Show((Get-SamOwnerForm), $msg, 'Newer version already exists', 'YesNoCancel', 'Warning')   # not-a-command: version gate before the command window
    if ($ans -eq [System.Windows.Forms.DialogResult]::Yes) { Write-SamLog "  User chose to $Action anyway." -Level Warning; return $all }
    if ($ans -eq [System.Windows.Forms.DialogResult]::No)  { return @($all | Where-Object { -not $flagged[$_] }) }
    Write-SamLog '  Stopped by user.' -Level Warning
    return @()
}

function New-SamPipelineRow {
    param([string]$JsonPath, [hashtable]$Timers)
    $S = $global:SAM
    $row = [pscustomobject]@{
        BaseName            = [IO.Path]::GetFileNameWithoutExtension($JsonPath)
        JsonPath            = $JsonPath
        JsonFile            = [IO.Path]::GetFileName($JsonPath)
        Site                = ''
        Config              = $null
        AppName             = $null
        JsonVersion         = $null
        IncomingVersion     = $null
        IncomingPath        = $null
        LocalVersion        = $null
        LocalHasJsonVersion = $false
        RepoHasJsonVersion  = $false
        RepoLatest          = $null
        SccmLatest          = $null
        AppExists           = $false
        Deployments         = 0
        TestDeployed        = $false
        NextAction          = ''
        Error               = $null
        OtherSite           = $false
    }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    try { $cfg = Read-SamAppConfig $JsonPath }
    catch {
        $row.Error = 'Invalid JSON'
        Write-SamLog "  $([IO.Path]::GetFileName($JsonPath)): $($_.Exception.Message)" -Level Error
        $row.NextAction = Get-SamNextAction $row
        return $row
    }
    if ($cfg.ConfigType -ne 'SCCM Application Configuration') { return $null }   # not one of ours

    $row.Site = Get-SamJsonSite $cfg
    if ($row.Site -and $row.Site -ne [string]$S.Settings.SiteCode) { $row.OtherSite = $true; return $row }

    $row.Config      = $cfg
    $row.AppName     = [string]$cfg.Application.Name
    $row.JsonVersion = [string]$cfg.PathConfiguration.CurrentVersion
    if ($cfg.PathConfiguration.AppBaseName) { $row.BaseName = [string]$cfg.PathConfiguration.AppBaseName }
    if (-not $row.JsonVersion) { $row.Error = 'No PathConfiguration.CurrentVersion' }
    Add-SamTimer $Timers 'JSON parse' $sw

    if ($S.Settings.IncomingPath) {
        $inc = Get-SamLatestVersionFolder ([IO.Path]::Combine($S.Settings.IncomingPath, $row.BaseName))
        if ($inc) { $row.IncomingVersion = $inc.Version; $row.IncomingPath = $inc.Path }
    }
    Add-SamTimer $Timers 'Incoming share' $sw

    $localBase = [IO.Path]::Combine($S.Settings.LocalRootResolved, $row.BaseName)
    $loc = Get-SamLatestVersionFolder $localBase
    if ($loc) { $row.LocalVersion = $loc.Version }
    if ($row.JsonVersion) { $row.LocalHasJsonVersion = Test-SamFolderHasFiles ([IO.Path]::Combine($localBase, $row.JsonVersion)) }
    Add-SamTimer $Timers 'Local disk' $sw

    if ($S.Settings.RepositoryPath) {
        $repoBase = [IO.Path]::Combine($S.Settings.RepositoryPath, $row.BaseName)
        if ($row.JsonVersion) { $row.RepoHasJsonVersion = Test-SamFolderHasFiles ([IO.Path]::Combine($repoBase, $row.JsonVersion)) }
        $rl = Get-SamLatestVersionFolder $repoBase
        if ($rl) { $row.RepoLatest = $rl.Version }
    }
    Add-SamTimer $Timers 'Repository share' $sw

    Update-SamRowSccmStatus $row
    return $row
}

function Update-SamRow {
    param($Row)
    $rows = $global:SAM.Rows
    $idx = $rows.IndexOf($Row)
    $new = New-SamPipelineRow -JsonPath $Row.JsonPath -Timers $null
    if ($idx -ge 0 -and $new -and -not $new.OtherSite) { $rows[$idx] = $new }
}

function Test-SamLocalRoot {
    $r = [string]$global:SAM.Settings.LocalRootResolved
    if ($r -and [IO.Directory]::Exists($r)) { return $true }
    [void][System.Windows.Forms.MessageBox]::Show((Get-SamOwnerForm),
        "Local Root folder does not exist:`r`n$r`r`n`r`nSet Local Root on Environment > SCCM Site (blank = the folder the EXE is in).",
        'Local Root not found', 'OK', 'Warning')
    return $false
}

function Invoke-SamPipelineScan {
    $S = $global:SAM
    if (-not (Test-SamLocalRoot)) { return }
    $root  = [string]$S.Settings.LocalRootResolved
    $files = @(Measure-SamStep 'Scan: list JSON files' { [IO.Directory]::GetFiles($root, '*.json') })
    Write-SamLog "Found $($files.Count) JSON file(s) in $root"

    $timers = @{}
    $rows   = New-Object System.Collections.ArrayList
    $timing = New-Object System.Collections.ArrayList
    $hidden = 0
    $i = 0
    foreach ($f in $files) {
        $i++
        Set-SamProgress $i $files.Count "Scanning $([IO.Path]::GetFileName($f))"
        $sw  = [System.Diagnostics.Stopwatch]::StartNew()
        $row = New-SamPipelineRow -JsonPath $f -Timers $timers
        $sw.Stop()
        if ($row) {
            if ($row.OtherSite) { $hidden++ }
            else {
                [void]$rows.Add($row)
                [void]$timing.Add([pscustomobject]@{ Name = $row.BaseName; Ms = $sw.ElapsedMilliseconds })
            }
        }
        Write-SamPerfRecord -Operation "Scan row: $([IO.Path]::GetFileName($f))" -Milliseconds $sw.ElapsedMilliseconds -Succeeded $true
        if ($i % 5 -eq 0) { [System.Windows.Forms.Application]::DoEvents() }
    }
    $S.Rows = $rows
    $S.HiddenJson = $hidden
    $S.ScannedAt = Get-Date
    if ($hidden) { Write-SamLog "  $hidden JSON file(s) belong to other sites and are hidden (switch environment to see them)." }

    foreach ($k in ($timers.Keys | Sort-Object)) {
        Write-SamLog ('  Scan phase {0,-18}: {1,8:N0} ms total' -f $k, $timers[$k]) -Level Perf
    }
    $slow = @($timing.ToArray() | Sort-Object Ms -Descending | Select-Object -First 5 | ForEach-Object { '{0} ({1:N0} ms)' -f $_.Name, $_.Ms })
    if ($slow.Count) { Write-SamLog ('  Slowest rows: ' + ($slow -join ', ')) -Level Perf }

    Write-SamVersionsFile
    Invoke-SamRenderViews
}

# versions.txt (Incoming versions) in the Local Root, from the scan results.
function Write-SamVersionsFile {
    $S = $global:SAM
    $path = [IO.Path]::Combine($S.Settings.LocalRootResolved, 'versions.txt')
    $sb = New-Object System.Text.StringBuilder
    foreach ($r in ($S.Rows.ToArray() | Where-Object { $_.IncomingVersion } | Sort-Object BaseName)) {
        [void]$sb.AppendLine($r.BaseName); [void]$sb.AppendLine($r.IncomingVersion); [void]$sb.AppendLine('')
    }
    try { [IO.File]::WriteAllText($path, $sb.ToString(), (New-Object Text.UTF8Encoding($false))) }
    catch { Write-SamLog "Could not write versions.txt: $($_.Exception.Message)" -Level Warning }
}

# Selected rows filtered by eligibility, or every eligible row when nothing is selected.
function Get-SamTargetRows {
    param([string]$StepName, [scriptblock]$Eligible, $Selected)
    $sel = @($Selected | Where-Object { $_ })
    $pool = if ($sel.Count) { $sel } else { $global:SAM.Rows.ToArray() }
    $targets = New-Object System.Collections.ArrayList
    foreach ($r in $pool) {
        if (& $Eligible $r) { [void]$targets.Add($r) }
        elseif ($sel.Count) { Write-SamLog "  Skipping $($r.BaseName): not eligible for '$StepName' (next action: $($r.NextAction))" -Level Warning }
    }
    if ($targets.Count -eq 0) { Write-SamLog "Nothing to do for '$StepName'." -Level Warning }
    return $targets.ToArray()
}
