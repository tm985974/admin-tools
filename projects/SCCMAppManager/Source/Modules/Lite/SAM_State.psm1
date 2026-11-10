# SAM_State.psm1   (LITE TIER)
#
# Session state and per-environment settings for SCCM App Manager.
#
# Every module is imported in isolation, so state that several modules share
# lives in ONE global hashtable: $global:SAM. Never use $script: for shared
# state (closures created with .GetNewClosure() cannot see it either).
#
# One environment = one SCCM site. Its settings are fields of the environment
# record (Environment tab > SCCM Site page):
#   SiteCode, SiteServer, LocalRoot, IncomingPath, RepositoryPath, IconsPath,
#   TestCollection, DPGroup, RobocopyThreads, PruneOldLocalVersions
# A blank field falls back to the old v8 settings file
# (%APPDATA%\SCCMAppManager\settings.json) when that file's SiteCode matches.

function Initialize-SamState {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $App)
    $global:SAM = @{
        App            = $App
        Settings       = @{}
        Cim            = $null
        Ns             = ''
        Connected      = $false
        ConnectedTo    = ''
        CMLoaded       = $false
        Busy           = $false
        Stale          = $false
        Rows           = (New-Object System.Collections.ArrayList)
        HiddenJson     = 0
        Cache          = (New-SamEmptyCache)
        DeviceCache    = $null
        LogLines       = (New-Object System.Collections.ArrayList)
        LogBoxes       = (New-Object System.Collections.ArrayList)
        LastPump       = [DateTime]::MinValue
        ActionControls = (New-Object System.Collections.ArrayList)
        Views          = [ordered]@{}
        Legacy         = $null
        Tabs           = $null
    }
    Update-SamSettings
    Register-EnvironmentChangedHandler -Handler { param($App) Invoke-SamEnvironmentChanged }
    Register-AppSettingsChangedHandler -Handler { param($App, $Name) if ($Name -eq 'Environment') { Invoke-SamSettingsSaved } }
}

# The Environment tab saved: pick up the new values. A different site or SMS
# Provider is handled like an environment switch; changed paths make the Update
# Pipeline tab rescan on its next visit.
function Invoke-SamSettingsSaved {
    $old = $global:SAM.Settings
    $new = Get-SamSettings
    if ($old.EnvName -ne $new.EnvName) { return }
    if ($old.SiteCode -ne $new.SiteCode -or ($new.SiteServer -and $old.SiteServer -ne $new.SiteServer)) { Invoke-SamEnvironmentChanged; return }
    Update-SamSettings
    foreach ($k in @('LocalRootResolved', 'IncomingPath', 'RepositoryPath')) {
        if ([string]$old[$k] -ne [string]$new[$k]) { $global:SAM.ScannedEnv = ''; break }
    }
    Write-SamLog "Settings of '$($new.EnvLabel)' saved."
}

function New-SamEmptyCache {
    return @{
        Loaded            = $false
        Apps              = (New-Object System.Collections.ArrayList)
        AppsByName        = @{}
        AppsByBase        = @{}
        FolderPaths       = @()
        AppFolder         = @{}
        DeployedTo        = @{}      # app name -> @{ collection name = $true }
        AppsByCollection  = @{}      # collection name -> ArrayList of app names
        Assignments       = (New-Object System.Collections.ArrayList)
        AssignByCollId    = @{}      # collection ID -> ArrayList of assignment objects
        Summaries         = (New-Object System.Collections.ArrayList)
        Collections       = (New-Object System.Collections.ArrayList)
        CollectionsByName = @{}
        CollectionsById   = @{}
    }
}

# A value from an environment record, or $Default when missing / blank.
function Get-SamRecordValue {
    param($Record, [string]$Key, $Default = '')
    if ($Record -and $Record.Contains($Key) -and $null -ne $Record[$Key] -and [string]$Record[$Key] -ne '') { return $Record[$Key] }
    return $Default
}

# The v8 script's settings file, read once (used only to fill blank fields).
function Get-SamLegacySettings {
    if ($null -ne $global:SAM.Legacy) { return $global:SAM.Legacy }
    $h = @{}
    try {
        $p = [IO.Path]::Combine($env:APPDATA, 'SCCMAppManager\settings.json')
        if ([IO.File]::Exists($p)) {
            $j = [IO.File]::ReadAllText($p) | ConvertFrom-Json
            foreach ($pr in $j.PSObject.Properties) { $h[$pr.Name] = $pr.Value }
        }
    } catch { }
    $global:SAM.Legacy = $h
    return $h
}

# Settings for an environment record (default: the active environment).
function Get-SamSettings {
    [CmdletBinding()]
    param($Record = $null)
    $App = $global:SAM.App
    if (-not $Record) { $Record = Get-AppEnvironmentRecord -App $App }
    $site = ([string](Get-SamRecordValue $Record 'SiteCode' '')).Trim().ToUpper()
    $legacy = Get-SamLegacySettings
    $useLegacy = ($site -and [string]$legacy['SiteCode'] -ieq $site)

    $s = [ordered]@{
        EnvName     = [string](Get-SamRecordValue $Record 'Name' '')
        EnvLabel    = [string](Get-SamRecordValue $Record 'Label' '')
        SiteCode    = $site
    }
    foreach ($k in @('SiteServer', 'LocalRoot', 'IncomingPath', 'RepositoryPath', 'IconsPath', 'TestCollection', 'DPGroup')) {
        $v = ([string](Get-SamRecordValue $Record $k '')).Trim()
        if (-not $v -and $useLegacy) {
            $lk = if ($k -eq 'LocalRoot') { 'LocalRootOverride' } else { $k }
            $v = ([string]$legacy[$lk]).Trim()
        }
        $s[$k] = $v
    }
    $t = 8; [void][int]::TryParse([string](Get-SamRecordValue $Record 'RobocopyThreads' '8'), [ref]$t)
    if ($t -lt 1) { $t = 8 }; if ($t -gt 128) { $t = 128 }
    $s['RobocopyThreads'] = $t
    $prune = Get-SamRecordValue $Record 'PruneOldLocalVersions' $true
    $s['PruneOldLocalVersions'] = ([string]$prune -ne 'False' -and [string]$prune -ne '0')
    $rl = Get-SamRecordValue $Record 'ReloadOnTabSelect' $true
    $s['ReloadOnTabSelect'] = ([string]$rl -ne 'False' -and [string]$rl -ne '0')
    $s['LocalRootResolved'] = Resolve-SamLocalRoot -Value $s['LocalRoot']
    return $s
}

# Local Root: blank or .\ = the folder the EXE is in; relative = relative to it.
function Resolve-SamLocalRoot {
    param([string]$Value)
    $exeDir = ''
    try { $exeDir = [IO.Path]::GetDirectoryName([string]$global:SAM.App.ExePath) } catch { }
    $o = ([string]$Value).Trim()
    if (-not $o -or $o -eq '.' -or $o -eq '.\') { return $exeDir }
    if ([IO.Path]::IsPathRooted($o)) { return $o.TrimEnd('\') }
    if ($exeDir) { return [IO.Path]::GetFullPath([IO.Path]::Combine($exeDir, $o)).TrimEnd('\') }
    return $o
}

function Update-SamSettings {
    $global:SAM.Settings = Get-SamSettings
    $root = [string]$global:SAM.App.DataRoot
    if (-not $root) { $root = [string]$global:SAM.App.LocalAppData }
    $dir = [IO.Path]::Combine($root, 'Logs')
    try { if (-not [IO.Directory]::Exists($dir)) { [void][IO.Directory]::CreateDirectory($dir) } } catch { }
    $global:SAM.LogDir   = $dir
    $global:SAM.PerfFile = [IO.Path]::Combine($dir, 'perf.csv')
}

# Every saved environment with its SCCM settings (for "copy JSON to environment").
function Get-SamAllEnvironments {
    $out = New-Object System.Collections.ArrayList
    $store = Read-AppEnvironmentStore -App $global:SAM.App
    foreach ($r in $store.Environments) { [void]$out.Add((Get-SamSettings -Record $r)) }
    return $out.ToArray()
}

# Environment tab switched environments: drop the connection and all cached
# data; the next visit to a SCCM tab reconnects and reloads.
function Invoke-SamEnvironmentChanged {
    Disconnect-Sam
    $global:SAM.Rows       = New-Object System.Collections.ArrayList
    $global:SAM.Cache      = New-SamEmptyCache
    $global:SAM.DeviceCache = $null
    $global:SAM.ScannedEnv = ""
    $global:SAM.ConnectFailedFor = ""
    Update-SamSettings
    $global:SAM.Stale = $true
    Write-SamLog "Environment changed to '$($global:SAM.Settings.EnvLabel)' (site $($global:SAM.Settings.SiteCode)). Data reloads when you open a SCCM tab."
    Invoke-SamRenderViews
}
