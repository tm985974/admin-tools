# Services_RSLinxBackup.psm1   (LITE TIER)
#
# Driver backups: CSV files with Name,Node columns - the same layout as the old
# tool's backups and RSLinx.csv, so those still restore.
#
# Folder: the environment's "Driver backup folder (UNC)" (BackupPath) when it is
# reachable, else <data root>\Backups on this machine.
#
#   Get-RSLinxBackupDir -App $App [-Refresh] -> @{ Path; IsFallback; Reason }
#   Save-RSLinxBackup -App $App -Drivers $d -Name 'before-change'   -> full path
#        (written locally when the share cannot be written to)
#   Get-RSLinxBackupFiles -Path $dir         -> FileInfo[], newest first
#   Read-RSLinxBackup -Path $file            -> rows for ConvertFrom-RSLinxDriverList

# The result is remembered per folder for the session (an unreachable UNC path
# can take many seconds to time out); -Refresh checks again.
$script:BackupDirCache = @{}

function Get-RSLinxLocalBackupDir {
    param($App)
    $root = [string]$App.DataRoot; if (-not $root) { $root = [string]$App.LocalAppData }
    $local = Join-Path $root 'Backups'
    if (-not (Test-Path -LiteralPath $local)) { New-Item -ItemType Directory -Path $local -Force | Out-Null }
    return $local
}

function Get-RSLinxBackupDir {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $App, [switch]$Refresh)
    $want = ([string]$App.GetSetting('BackupPath')).Trim()
    $ck = $want + '|' + [string]$App.DataRoot
    if (-not $Refresh -and $script:BackupDirCache.ContainsKey($ck)) { return $script:BackupDirCache[$ck] }

    $result = $null
    $reason = ''
    if ($want -ne '') {
        try {
            if (-not (Test-Path -LiteralPath $want)) { New-Item -ItemType Directory -Path $want -Force -ErrorAction Stop | Out-Null }
            if (Test-Path -LiteralPath $want) { $result = @{ Path = $want; IsFallback = $false; Reason = '' } }
        }
        catch { $reason = "$want is not reachable ($($_.Exception.Message))" }
        if (-not $result -and -not $reason) { $reason = "$want is not reachable" }
    }
    else { $reason = 'no backup folder is set for this environment' }

    if (-not $result) { $result = @{ Path = (Get-RSLinxLocalBackupDir -App $App); IsFallback = $true; Reason = $reason } }
    $script:BackupDirCache[$ck] = $result
    return $result
}

function Save-RSLinxBackup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $App,
        [AllowEmptyCollection()] [object[]]$Drivers = @(),
        [string]$Name = ''
    )
    $b = Get-RSLinxBackupDir -App $App
    $safe = [regex]::Replace(([string]$Name).Trim(), '[^A-Za-z0-9_\-\.\(\) ]', '_')
    $stamp = (Get-Date).ToString('yyyyMMdd_HHmmss')
    $file = '{0}_{1}{2}.csv' -f $env:COMPUTERNAME, $stamp, $(if ($safe) { '_' + $safe } else { '' })
    $rows = foreach ($d in $Drivers) { foreach ($ip in @($d.Nodes)) { [pscustomobject]@{ Name = $d.Name; Node = $ip } } }
    $lines = @('"Name","Node"') + @($rows | Where-Object { $_ } | ForEach-Object { '"{0}","{1}"' -f ($_.Name -replace '"', '""'), $_.Node })
    $enc = New-Object System.Text.UTF8Encoding($false)
    $path = Join-Path $b.Path $file
    try { [System.IO.File]::WriteAllLines($path, [string[]]$lines, $enc) }
    catch {
        if ($b.IsFallback) { throw }
        # the share went away since it was checked: keep the backup locally instead
        $App.Log('WARN', 'Backup', "cannot write $path ($($_.Exception.Message)); saving locally.")
        $path = Join-Path (Get-RSLinxLocalBackupDir -App $App) $file
        [System.IO.File]::WriteAllLines($path, [string[]]$lines, $enc)
    }
    return $path
}

function Get-RSLinxBackupFiles {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    return @(Get-ChildItem -LiteralPath $Path -Filter '*.csv' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
}

function Read-RSLinxBackup {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Path)
    $text = [System.IO.File]::ReadAllText($Path)
    $p = ConvertFrom-DeviceRegistryText -Text $text
    if ($p.Kind -ne 'DriverList') { throw "$([System.IO.Path]::GetFileName($Path)) is not a driver backup (it needs Name and Node columns)." }
    return @($p.Rows)
}
