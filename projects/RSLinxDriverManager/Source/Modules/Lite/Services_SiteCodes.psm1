# Services_SiteCodes.psm1   (LITE TIER)
#
# Site codes: the device registry's Lease name -> the 2-letter site code used
# in driver names (Belridge -> BL), so names stay within the RSLinx limit.
#
# Storage: shipped default = Config\SiteCodes.json (embedded). The working copy
# is <data root>\Settings\SiteCodes.json (seeded from the default on first use).
#
#   Get-SiteCodePath -App $App                 -> Settings\SiteCodes.json
#   Get-SiteCodeTable -App $App [-Defaults]    -> @( @{ Lease; Code } )
#   Save-SiteCodeTable -App $App -Entries $list
#   New-SiteCodeMap -Entries $list             -> hashtable for Get-RSLinxSiteCode -SiteMap
#   Get-SiteCodeKey -Lease ' south  midway '   -> 'SOUTH MIDWAY' (the lookup key: trimmed,
#                                                 single spaces, upper case)
#   Test-SiteCodeTable -Entries $list          -> one issue text per entry ('' = ok)

function Get-SiteCodeKey {
    [CmdletBinding()]
    param([AllowNull()] [AllowEmptyString()] [string]$Lease)
    return ([regex]::Replace(([string]$Lease).Trim(), '\s+', ' ')).ToUpperInvariant()
}

function Get-SiteCodePath {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $App)
    return (Join-Path (Get-AppSettingsDir -App $App) 'SiteCodes.json')
}

function ConvertTo-SiteCodeEntry {
    param($Raw)
    $lease = ''; $code = ''
    if ($Raw -is [System.Collections.IDictionary]) { $lease = [string]$Raw['Lease']; $code = [string]$Raw['Code'] }
    else { $lease = [string]$Raw.Lease; $code = [string]$Raw.Code }
    return [pscustomobject]@{ Lease = ([regex]::Replace($lease.Trim(), '\s+', ' ')); Code = $code.Trim().ToUpperInvariant() }
}

function Get-SiteCodeTable {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $App, [switch]$Defaults)
    $paths = @()
    if (-not $Defaults) { $paths += (Get-SiteCodePath -App $App) }
    $paths += (Join-Path (Join-Path ([string]$App.LocalAppData) 'Config') 'SiteCodes.json')
    foreach ($p in $paths) {
        if (-not (Test-Path -LiteralPath $p)) { continue }
        try {
            $j = [System.IO.File]::ReadAllText($p) | ConvertFrom-Json -ErrorAction Stop
            return @(foreach ($e in @($j.Entries)) { if ($null -ne $e) { ConvertTo-SiteCodeEntry -Raw $e } })
        }
        catch { if ($App) { $App.Log('ERROR', 'SiteCodes', "cannot read $p : $($_.Exception.Message)") } }
    }
    return @()
}

function Save-SiteCodeTable {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $App, [AllowEmptyCollection()] [object[]]$Entries = @())
    $path = Get-SiteCodePath -App $App
    $list = @(foreach ($e in $Entries) {
        $n = ConvertTo-SiteCodeEntry -Raw $e
        if ($n.Lease -eq '' -and $n.Code -eq '') { continue }
        [ordered]@{ Lease = $n.Lease; Code = $n.Code }
    })
    $doc = [ordered]@{
        _note   = 'Site codes: device registry Lease name -> 2-letter site code. Edit on the Site Codes tab.'
        Saved   = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + ' by ' + $env:USERNAME + ' on ' + $env:COMPUTERNAME
        Entries = $list
    }
    $tmp = $path + '.tmp'
    [System.IO.File]::WriteAllText($tmp, (ConvertTo-Json -InputObject $doc -Depth 5), (New-Object System.Text.UTF8Encoding($false)))
    if (Test-Path -LiteralPath $path) { Copy-Item -LiteralPath $path -Destination ($path + '.bak') -Force }
    Move-Item -LiteralPath $tmp -Destination $path -Force
    return $path
}

function New-SiteCodeMap {
    [CmdletBinding()]
    param([AllowEmptyCollection()] [object[]]$Entries = @())
    $m = @{}
    foreach ($e in $Entries) {
        if ($null -eq $e) { continue }
        $k = Get-SiteCodeKey -Lease $e.Lease
        $c = ([string]$e.Code).Trim().ToUpperInvariant()
        if ($k -ne '' -and $c -match '^[A-Z]{2}$' -and -not $m.ContainsKey($k)) { $m[$k] = $c }   # first entry wins
    }
    return $m
}

function Test-SiteCodeTable {
    [CmdletBinding()]
    param([AllowEmptyCollection()] [object[]]$Entries = @())
    $seen = @{}
    foreach ($e in $Entries) { $k = Get-SiteCodeKey -Lease $e.Lease; if ($seen.ContainsKey($k)) { $seen[$k]++ } else { $seen[$k] = 1 } }
    foreach ($e in $Entries) {
        $issues = @()
        if ((Get-SiteCodeKey -Lease $e.Lease) -eq '') { $issues += 'Lease name is empty' }
        if ([string]$e.Code -notmatch '^[A-Za-z]{2}$') { $issues += 'Code must be 2 letters' }
        if ($seen[(Get-SiteCodeKey -Lease $e.Lease)] -gt 1) { $issues += 'Duplicate Lease name (the first one is used)' }
        ($issues -join '; ')
    }
}
