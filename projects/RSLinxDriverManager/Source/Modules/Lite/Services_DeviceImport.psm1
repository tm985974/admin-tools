# Services_DeviceImport.psm1   (LITE TIER)
#
# Turns device-registry data (pasted text or a CSV file) into RSLinx driver rows.
#
# Device registry columns (header row optional - without one this order is assumed):
#   Asset, Active, Asset Type, Lease, Location, Facility Type, Zone, Has IP,
#   Process Team, Primary IP, Secondary IP, Manufacturer, Model, Description,
#   Critical, Last Update, ASET_MFGR_ID, ASET_MODL_ID, ASET_STAT_ID, ASET_TYPE_ID,
#   ASET_ID, LCTN_ID, STAT_SUB_STAT_TYPE_ID, PriIpId, SecIpId
# Used: Lease (site name -> 2-letter code via the Site Codes table), Primary IP, Secondary IP, Manufacturer, Active,
# plus Asset / Model / Description / Location for display.
#
# Also accepted: a driver list with Name,Node columns (the old RSLinx.csv and
# this tool's backups) - loaded as-is.
#
# Comma, tab (pasted from Excel) or semicolon separated; quoted fields are fine.
#
#   $p = ConvertFrom-DeviceRegistryText -Text $text
#        -> @{ Kind = 'Registry' | 'DriverList' | 'Empty'; Rows = @(...); HeaderFound = $bool;
#              Columns = header names; Missing = needed columns not found }
#   $r = ConvertTo-RSLinxDriverRows -Devices $p.Rows -Resolver (New-VlanResolver ...) [-SiteMap (New-SiteCodeMap ...)] `
#            [-ManufacturerMatch 'Allen-Bradley'] [-IncludeInactive] [-PrimaryOnly]
#        -> @{ Rows = @(driver rows); Stats = [ordered]@{...}; Unmatched = @('BL 10.1.2', ...);
#              BadSites = @("'value' (count)", ...) - Lease values that gave no site code }
#   Get-RSLinxSiteCode -Lease 'Belridge' -SiteMap $m   -> 'BL'  ('' when no code is found)
#   ConvertFrom-RSLinxDriverList -Rows $p.Rows   -> driver rows from Name,Node data
#   Test-RSLinxDriverRow -Row $row               -> '' when the row can be applied, else why not
#
# A driver row: Include, Driver, IP, Site, Asset, Source (Primary/Secondary/List),
# Model, Description, Location, Match (Exact/Range/Default/List), Note.

$script:RegistryColumns = @(
    'Asset', 'Active', 'Asset Type', 'Lease', 'Location', 'Facility Type', 'Zone', 'Has IP',
    'Process Team', 'Primary IP', 'Secondary IP', 'Manufacturer', 'Model', 'Description',
    'Critical', 'Last Update', 'ASET_MFGR_ID', 'ASET_MODL_ID', 'ASET_STAT_ID', 'ASET_TYPE_ID',
    'ASET_ID', 'LCTN_ID', 'STAT_SUB_STAT_TYPE_ID', 'PriIpId', 'SecIpId'
)

# normalised names of the columns read (see Get-NormalizedColumnName)
$script:UsedColumns = @('asset', 'active', 'lease', 'location', 'primaryip', 'secondaryip', 'manufacturer', 'model', 'description', 'name', 'node')

# 'Primary IP' / 'primary_ip' / ' PRIMARY IP ' -> 'primaryip'
function Get-NormalizedColumnName([string]$Name) {
    return ([regex]::Replace(([string]$Name).ToLowerInvariant(), '[^a-z0-9]', ''))
}

function ConvertFrom-DeviceRegistryText {
    [CmdletBinding()]
    param([AllowNull()] [AllowEmptyString()] [string]$Text)

    $t = ([string]$Text).TrimStart([char]0xFEFF)
    $lines = @($t -split "`r?`n" | Where-Object { $_.Trim() -ne '' })
    if ($lines.Count -eq 0) { return @{ Kind = 'Empty'; Rows = @(); HeaderFound = $false; Columns = @(); Missing = @() } }

    $first = $lines[0]
    $tabs = ([regex]::Matches($first, "`t")).Count
    $semi = ([regex]::Matches($first, ';')).Count
    $comma = ([regex]::Matches($first, ',')).Count
    $delim = ','
    if ($tabs -gt 0 -and $tabs -ge $comma) { $delim = "`t" }
    elseif ($semi -gt $comma) { $delim = ';' }

    $firstCells = @($first.Split($delim) | ForEach-Object { Get-NormalizedColumnName ($_.Trim().Trim('"')) })
    $isDriverList = ($firstCells -contains 'name') -and ($firstCells -contains 'node')
    $hasHeader = $isDriverList -or ($firstCells -contains 'primaryip') -or ($firstCells -contains 'lease') -or ($firstCells -contains 'manufacturer')

    $body = ($lines -join "`r`n")
    if ($hasHeader) { $raw = @($body | ConvertFrom-Csv -Delimiter $delim -WarningAction SilentlyContinue) }
    else            { $raw = @($body | ConvertFrom-Csv -Delimiter $delim -Header $script:RegistryColumns) }

    # Normalised property bag per row, so header spelling/spacing does not
    # matter. Only the columns this tool uses are copied (much faster on big pastes).
    $rows = New-Object System.Collections.ArrayList
    $map = New-Object System.Collections.ArrayList          # (original column name, normalised name)
    if ($raw.Count -gt 0) {
        $done = @{}
        $names = @($raw[0].PSObject.Properties | ForEach-Object { $_.Name })
        foreach ($n in $names) {
            $k = Get-NormalizedColumnName $n
            if ($script:UsedColumns -contains $k -and -not $done.ContainsKey($k)) { $done[$k] = $true; [void]$map.Add(@($n, $k)) }
        }
        # Lease exported under a longer name ('Lease Code', 'Lease Name' ...): use the first one.
        if (-not $done.ContainsKey('lease')) {
            foreach ($n in $names) { if ((Get-NormalizedColumnName $n) -like 'lease*') { $done['lease'] = $true; [void]$map.Add(@($n, 'lease')); break } }
        }
    }
    $columns = @(); if ($raw.Count -gt 0) { $columns = @($raw[0].PSObject.Properties | ForEach-Object { $_.Name }) }
    $found = @($map | ForEach-Object { $_[1] })
    $missing = @(@('lease', 'primaryip', 'secondaryip', 'manufacturer') | Where-Object { $found -notcontains $_ })
    foreach ($r in $raw) {
        $h = @{}
        foreach ($m in $map) { $h[$m[1]] = ([string]$r.($m[0])).Trim() }
        [void]$rows.Add($h)
    }
    return @{ Kind = $(if ($isDriverList) { 'DriverList' } else { 'Registry' }); Rows = $rows.ToArray(); HeaderFound = $hasHeader
              Columns = $columns; Missing = $(if ($isDriverList) { @() } else { $missing }) }
}

# The 2-letter site code for a Lease value:
#   1. the Site Codes table (-SiteMap from New-SiteCodeMap): 'Belridge' -> BL
#   2. already a code: 'BL' -> BL
#   3. starts with a code: 'BL - Belridge', 'BL Belridge', 'bl-01', 'BL(North)' -> BL
# Anything else -> '' (the row is skipped and the value logged).
function Get-RSLinxSiteCode {
    [CmdletBinding()]
    param([AllowNull()] [AllowEmptyString()] [string]$Lease, [hashtable]$SiteMap = @{})
    $key = Get-SiteCodeKey -Lease $Lease
    if ($SiteMap.ContainsKey($key)) { return $SiteMap[$key] }
    $v = $key
    if ($v -match '^[A-Z]{2}$') { return $v }
    if ($v -match '^([A-Z]{2})[\s\-_:/\(\.,0-9]') { return $Matches[1] }
    return ''
}

function Test-ManufacturerMatch([string]$Value, [string]$Match) {
    $v = [regex]::Replace(([string]$Value).ToLowerInvariant(), '[^a-z0-9]', '')
    $m = [regex]::Replace(([string]$Match).ToLowerInvariant(), '[^a-z0-9]', '')
    if ($m -eq '') { return $true }
    return $v.Contains($m)
}

function Test-InactiveValue([string]$Value) {
    return ([string]$Value).Trim() -match '^(n|no|false|0|inactive|retired|disposed)$'
}

function Test-RSLinxDriverRow {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Row)
    $limit = Get-RSLinxDriverNameLimit
    $name = ([string]$Row.Driver).Trim()
    if ($name -eq '') { return 'Driver name is empty' }
    if ($name.Length -gt $limit) { return "Driver name is $($name.Length) characters (max $limit)" }
    if ($name -match '[\\"]') { return 'Driver name cannot contain \ or "' }
    if (-not (Test-IPv4Address -IP ([string]$Row.IP))) { return 'Not a valid IPv4 address' }
    return ''
}

function New-RSLinxDriverRow {
    param($Driver, $IP, $Site, $Asset, $Source, $Model, $Description, $Location, $Match)
    $row = [pscustomobject]@{
        Include = $true; Driver = [string]$Driver; IP = [string]$IP; Site = [string]$Site; Asset = [string]$Asset
        Source = [string]$Source; Model = [string]$Model; Description = [string]$Description; Location = [string]$Location
        Match = [string]$Match; Note = ''
    }
    $row.Note = Test-RSLinxDriverRow -Row $row
    return $row
}

function ConvertTo-RSLinxDriverRows {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()] [object[]]$Devices = @(),
        [Parameter(Mandatory)] [hashtable]$Resolver,
        [hashtable]$SiteMap = @{},
        [string]$ManufacturerMatch = 'Allen-Bradley',
        [switch]$IncludeInactive,
        [switch]$PrimaryOnly
    )
    $stats = [ordered]@{
        DeviceRows = 0; NotManufacturer = 0; Inactive = 0; BadSite = 0; NoIP = 0; BadIP = 0
        Duplicates = 0; IPs = 0; Drivers = 0; DefaultNamed = 0
    }
    $out = New-Object System.Collections.ArrayList
    $seen = @{}            # 'DRIVER|ip' -> row (duplicates add the asset to its note)
    $unmatched = @{}       # 'BL 10.1.2' -> count of IPs that got the default name
    $badSites = @{}        # Lease value that gave no site code -> count

    foreach ($d in $Devices) {
        $stats.DeviceRows++
        if (-not (Test-ManufacturerMatch $d['manufacturer'] $ManufacturerMatch)) { $stats.NotManufacturer++; continue }
        if (-not $IncludeInactive -and (Test-InactiveValue $d['active'])) { $stats.Inactive++; continue }

        $site = Get-RSLinxSiteCode -Lease $d['lease'] -SiteMap $SiteMap
        if ($site -eq '') {
            $stats.BadSite++
            $bv = ([string]$d['lease']).Trim(); if ($bv -eq '') { $bv = '(blank)' }
            if ($badSites.ContainsKey($bv)) { $badSites[$bv]++ } else { $badSites[$bv] = 1 }
            continue
        }

        $ips = @()
        if ($d['primaryip']) { $ips += ,@('Primary', $d['primaryip']) }
        if (-not $PrimaryOnly -and $d['secondaryip']) { $ips += ,@('Secondary', $d['secondaryip']) }
        if ($ips.Count -eq 0) { $stats.NoIP++; continue }

        foreach ($pair in $ips) {
            $ip = ([string]$pair[1]).Trim()
            if (-not (Test-IPv4Address -IP $ip)) { $stats.BadIP++; continue }
            $res = Resolve-VlanDriverName -Resolver $Resolver -Site $site -IP $ip
            $key = $res.Name.ToUpperInvariant() + '|' + $ip
            if ($seen.ContainsKey($key)) {
                $stats.Duplicates++
                $prev = $seen[$key]
                if ($d['asset'] -and $prev.Asset -ne $d['asset']) {
                    $extra = 'Also: ' + $d['asset']
                    $prev.Note = $(if ($prev.Note) { $prev.Note + '; ' + $extra } else { $extra })
                }
                continue
            }
            if ($res.Match -eq 'Default') {
                $stats.DefaultNamed++
                $uk = $site + ' ' + ($ip.Split('.')[0..2] -join '.')
                if ($unmatched.ContainsKey($uk)) { $unmatched[$uk]++ } else { $unmatched[$uk] = 1 }
            }
            $row = New-RSLinxDriverRow -Driver $res.Name -IP $ip -Site $site -Asset $d['asset'] -Source $pair[0] `
                       -Model $d['model'] -Description $d['description'] -Location $d['location'] -Match $res.Match
            $seen[$key] = $row
            [void]$out.Add($row)
        }
    }

    $sorted = @(Get-SortedRSLinxDriverRows -Rows $out.ToArray())
    $stats.IPs = $sorted.Count
    $stats.Drivers = @($sorted | Select-Object -ExpandProperty Driver -Unique).Count
    $um = @($unmatched.Keys | Sort-Object | ForEach-Object { '{0}  ({1} IP{2})' -f $_, $unmatched[$_], $(if ($unmatched[$_] -eq 1) { '' } else { 's' }) })
    $bs = @($badSites.GetEnumerator() | Sort-Object -Property @{ Expression = 'Value'; Descending = $true }, @{ Expression = 'Key' } |
            ForEach-Object { "'{0}' ({1})" -f $_.Key, $_.Value })
    return @{ Rows = $sorted; Stats = $stats; Unmatched = $um; BadSites = $bs }
}

function ConvertFrom-RSLinxDriverList {
    [CmdletBinding()]
    param([AllowEmptyCollection()] [object[]]$Rows = @())
    $seen = @{}
    $out = foreach ($r in $Rows) {
        $name = ([string]$r['name']).Trim(); $ip = ([string]$r['node']).Trim()
        if ($name -eq '' -and $ip -eq '') { continue }
        $k = $name.ToUpperInvariant() + '|' + $ip
        if ($seen.ContainsKey($k)) { continue }
        $seen[$k] = $true
        $site = $(if ($name -match '^([A-Za-z]{2})\(') { $Matches[1].ToUpperInvariant() } else { '' })
        New-RSLinxDriverRow -Driver $name -IP $ip -Site $site -Source 'List' -Match 'List'
    }
    return @(Get-SortedRSLinxDriverRows -Rows @($out))
}

# Driver name, then IP in numeric order.
function Get-SortedRSLinxDriverRows {
    [CmdletBinding()]
    param([AllowEmptyCollection()] [object[]]$Rows = @())
    return @($Rows | Sort-Object -Property @{ Expression = { ([string]$_.Driver).ToUpperInvariant() } }, @{ Expression = {
        $n = ConvertTo-IPv4Number -IP ([string]$_.IP); if ($null -eq $n) { [double]::MaxValue } else { [double]$n } } })
}
