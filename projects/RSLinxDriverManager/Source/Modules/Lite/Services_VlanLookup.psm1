# Services_VlanLookup.psm1   (LITE TIER)
#
# The VLAN lookup table and RSLinx driver naming.
#
# One entry per site + subnet:
#   Site         2-letter site code (the device registry's Lease column)    BL
#   IpBase       first three octets of the subnet                            137.206.25
#   Cidr         prefix length (24 = just that /24; 21 = a /21 block)        24
#   Vlan         VLAN number shown in the driver name                        25
#   Description  VLAN description shown in the driver name                   SCADA
#
# Driver name = SITE(VLAN)DESCRIPTION, e.g. BL(25)SCADA, at most
# Get-RSLinxDriverNameLimit characters (15 - the longest names in use).
#
# An IP is matched to an entry of its own site, in this order:
#   1. Exact  - the entry whose IpBase is the IP's first three octets
#   2. Range  - an entry with Cidr < 24 whose block contains the IP (most specific wins)
#   3. Default- no entry: SITE(<3rd octet>)SCADA
#
# Storage: shipped default = Config\VlanLookup.json (embedded). The working copy
# is <data root>\Settings\VlanLookup.json (seeded from the default on first use,
# shared between machines when the environment has a Log & data path).
#
#   Get-RSLinxDriverNameLimit
#   Test-IPv4Address -IP '10.1.2.3'                       -> $true / $false
#   ConvertTo-IPv4Number -IP '10.1.2.3'                   -> [uint32] (or $null)
#   Get-VlanLookupPath -App $App                          -> Settings\VlanLookup.json
#   Get-VlanLookupTable -App $App [-Defaults]             -> entries
#   Save-VlanLookupTable -App $App -Entries $list
#   ConvertFrom-VlanLookupCsv -Text $csv                  -> entries (this tool's columns or the
#                                                            RSLinx.xlsx VlanLookup columns)
#   Get-VlanDriverName -Entry $e                          -> 'BL(25)SCADA'
#   New-VlanResolver -Entries $list                       -> resolver for Resolve-VlanDriverName
#   Resolve-VlanDriverName -Resolver $r -Site BL -IP 137.206.25.10
#                                                         -> @{ Name; Match; Entry }
#   Test-VlanLookupTable -Entries $list                   -> one issue text per entry ('' = ok)

$script:DriverNameLimit = 15
$script:DefaultDescription = 'SCADA'

function Get-RSLinxDriverNameLimit { return $script:DriverNameLimit }

function Test-IPv4Address {
    [CmdletBinding()]
    param([AllowNull()] [AllowEmptyString()] [string]$IP)
    return ($null -ne (ConvertTo-IPv4Number -IP $IP))
}

function ConvertTo-IPv4Number {
    [CmdletBinding()]
    param([AllowNull()] [AllowEmptyString()] [string]$IP)
    $t = ([string]$IP).Trim()
    if ($t -notmatch '^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$') { return $null }
    [uint32]$n = 0
    for ($i = 1; $i -le 4; $i++) {
        $o = [int]$Matches[$i]
        if ($o -gt 255) { return $null }
        $n = [uint32]($n * 256 + $o)
    }
    return $n
}

function Get-VlanLookupPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $App)
    return (Join-Path (Get-AppSettingsDir -App $App) 'VlanLookup.json')
}

# Normalise one raw entry (from JSON, CSV or the grid) to the standard shape.
function ConvertTo-VlanEntry {
    [CmdletBinding()]
    param($Raw)
    $get = {
        param($names)
        foreach ($n in $names) {
            if ($Raw -is [System.Collections.IDictionary]) { if ($Raw.Contains($n)) { return $Raw[$n] } }
            else { $p = $Raw.PSObject.Properties[$n]; if ($p) { return $p.Value } }
        }
        return $null
    }
    $site = ([string](& $get @('Site', 'LCTN_NME'))).Trim().ToUpperInvariant()
    $base = ([string](& $get @('IpBase', 'VLAN_IP_BASE_TXT', 'IP_Base'))).Trim()
    $base = $base.TrimEnd('.')
    $cidrText = ([string](& $get @('Cidr', 'CIDR'))).Trim()
    $vlanText = ([string](& $get @('Vlan', 'VLAN_NBR'))).Trim()
    $desc = ([string](& $get @('Description', 'VLANNME'))).Trim().ToUpperInvariant()
    $cidr = 24; $tmp = 0
    if ($cidrText -ne '' -and [int]::TryParse($cidrText, [ref]$tmp)) { $cidr = $tmp }
    $vlan = $vlanText
    if ([int]::TryParse($vlanText, [ref]$tmp)) { $vlan = [string]$tmp }
    return [pscustomobject]@{ Site = $site; IpBase = $base; Cidr = $cidr; Vlan = $vlan; Description = $desc }
}

function Get-VlanLookupTable {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $App, [switch]$Defaults)

    $paths = @()
    if (-not $Defaults) { $paths += (Get-VlanLookupPath -App $App) }
    $paths += (Join-Path (Join-Path ([string]$App.LocalAppData) 'Config') 'VlanLookup.json')

    foreach ($p in $paths) {
        if (-not (Test-Path -LiteralPath $p)) { continue }
        try {
            $j = [System.IO.File]::ReadAllText($p) | ConvertFrom-Json -ErrorAction Stop
            return @(foreach ($e in @($j.Entries)) { if ($null -ne $e) { ConvertTo-VlanEntry -Raw $e } })
        }
        catch { if ($App) { $App.Log('ERROR', 'VlanLookup', "cannot read $p : $($_.Exception.Message)") } }
    }
    if ($App) { $App.Log('WARN', 'VlanLookup', 'No VLAN lookup table found; every driver will get the default name.') }
    return @()
}

function Save-VlanLookupTable {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $App, [AllowEmptyCollection()] [object[]]$Entries = @())
    $path = Get-VlanLookupPath -App $App
    $list = @(foreach ($e in $Entries) {
        $n = ConvertTo-VlanEntry -Raw $e
        if ($n.Site -eq '' -and $n.IpBase -eq '') { continue }
        $vlanNum = 0
        $vlanOut = $(if ([int]::TryParse([string]$n.Vlan, [ref]$vlanNum)) { $vlanNum } else { [string]$n.Vlan })
        [ordered]@{ Site = $n.Site; IpBase = $n.IpBase; Cidr = [int]$n.Cidr; Vlan = $vlanOut; Description = $n.Description }
    })
    $doc = [ordered]@{
        _note   = 'VLAN lookup table. Driver name = Site(Vlan)Description. Edit on the VLAN Lookup tab.'
        Saved   = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + ' by ' + $env:USERNAME + ' on ' + $env:COMPUTERNAME
        Entries = $list
    }
    $json = ConvertTo-Json -InputObject $doc -Depth 5
    $tmp = $path + '.tmp'
    [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false)))
    if (Test-Path -LiteralPath $path) { Copy-Item -LiteralPath $path -Destination ($path + '.bak') -Force }
    Move-Item -LiteralPath $tmp -Destination $path -Force
    return $path
}

function ConvertFrom-VlanLookupCsv {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Text)
    $t = $Text.TrimStart([char]0xFEFF)
    $first = ($t -split "`r?`n" | Where-Object { $_.Trim() -ne '' } | Select-Object -First 1)
    $delim = $(if ($first -match "`t") { "`t" } else { ',' })
    $rows = @($t | ConvertFrom-Csv -Delimiter $delim -WarningAction SilentlyContinue)
    return @(foreach ($r in $rows) {
        $e = ConvertTo-VlanEntry -Raw $r
        if ($e.Site -ne '' -or $e.IpBase -ne '') { $e }
    })
}

function Get-VlanDriverName {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Entry)
    return ('{0}({1}){2}' -f ([string]$Entry.Site).ToUpperInvariant(), [string]$Entry.Vlan, ([string]$Entry.Description).ToUpperInvariant())
}

function New-VlanResolver {
    [CmdletBinding()]
    param([AllowEmptyCollection()] [object[]]$Entries = @())
    $exact  = @{}
    $ranges = @{}
    foreach ($e in $Entries) {
        if ($null -eq $e -or -not $e.Site -or -not $e.IpBase) { continue }
        $site = ([string]$e.Site).ToUpperInvariant()
        $k = $site + '|' + [string]$e.IpBase
        if (-not $exact.ContainsKey($k)) { $exact[$k] = $e }          # first entry wins (duplicates are flagged on the VLAN tab)
        $cidr = [int]$e.Cidr
        if ($cidr -ge 8 -and $cidr -lt 24) {
            $net = ConvertTo-IPv4Number -IP ([string]$e.IpBase + '.0')
            if ($null -ne $net) {
                [uint32]$mask = [uint32](([math]::Pow(2, 32) - [math]::Pow(2, 32 - $cidr)))
                if (-not $ranges.ContainsKey($site)) { $ranges[$site] = New-Object System.Collections.ArrayList }
                [void]$ranges[$site].Add([pscustomobject]@{ Net = [uint32]($net -band $mask); Mask = $mask; Cidr = $cidr; Entry = $e })
            }
        }
    }
    return @{ Exact = $exact; Ranges = $ranges }
}

function Resolve-VlanDriverName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable]$Resolver,
        [Parameter(Mandatory)] [string]$Site,
        [Parameter(Mandatory)] [string]$IP
    )
    $s = $Site.Trim().ToUpperInvariant()
    $ipT = $IP.Trim()
    $parts = $ipT.Split('.')
    $base = ($parts[0..2] -join '.')

    $k = $s + '|' + $base
    if ($Resolver.Exact.ContainsKey($k)) {
        $e = $Resolver.Exact[$k]
        return @{ Name = (Get-VlanDriverName -Entry $e); Match = 'Exact'; Entry = $e }
    }
    $n = ConvertTo-IPv4Number -IP $ipT
    if ($null -ne $n -and $Resolver.Ranges.ContainsKey($s)) {
        $best = $null
        foreach ($r in $Resolver.Ranges[$s]) {
            if ((([uint32]$n) -band $r.Mask) -eq $r.Net) {
                if ($null -eq $best -or $r.Cidr -gt $best.Cidr) { $best = $r }
            }
        }
        if ($best) { return @{ Name = (Get-VlanDriverName -Entry $best.Entry); Match = 'Range'; Entry = $best.Entry } }
    }
    $octet = $(if ($parts.Count -ge 3) { $parts[2] } else { '?' })
    return @{ Name = ('{0}({1}){2}' -f $s, $octet, $script:DefaultDescription); Match = 'Default'; Entry = $null }
}

function Test-VlanLookupTable {
    [CmdletBinding()]
    param([AllowEmptyCollection()] [object[]]$Entries = @())
    $seen = @{}
    foreach ($e in $Entries) { $k = ([string]$e.Site).ToUpperInvariant() + '|' + [string]$e.IpBase; if ($seen.ContainsKey($k)) { $seen[$k]++ } else { $seen[$k] = 1 } }
    $limit = $script:DriverNameLimit
    foreach ($e in $Entries) {
        $issues = @()
        if ([string]$e.Site -notmatch '^[A-Za-z]{2}$') { $issues += 'Site must be 2 letters' }
        if ([string]$e.IpBase -notmatch '^\d{1,3}\.\d{1,3}\.\d{1,3}$' -or -not (Test-IPv4Address -IP ([string]$e.IpBase + '.0'))) { $issues += 'IP base must be 3 octets (e.g. 10.144.32)' }
        $c = 0
        if (-not [int]::TryParse([string]$e.Cidr, [ref]$c) -or $c -lt 8 -or $c -gt 24) { $issues += 'CIDR must be 8-24' }
        if ([string]$e.Vlan -eq '') { $issues += 'VLAN is empty' }
        if ([string]$e.Description -eq '') { $issues += 'Description is empty' }
        $name = Get-VlanDriverName -Entry $e
        if ($name.Length -gt $limit) { $issues += "Driver name is $($name.Length) characters (max $limit)" }
        $k = ([string]$e.Site).ToUpperInvariant() + '|' + [string]$e.IpBase
        if ($seen[$k] -gt 1) { $issues += 'Duplicate site + IP base (the first one is used)' }
        ($issues -join '; ')
    }
}
