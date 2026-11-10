# Services_Library.psm1   (LITE TIER)
#
# The library: one JSON file of entries, in the writable settings folder
#   <data root>\Settings\Library.json        (Get-AppSettingsDir)
# so it follows the active environment: point an environment's "Log & data
# path" at a share and the whole team uses one library.
#
# The EXE ships a starting set in Config\Library.json. The first time, it is
# copied in; afterwards shipped entries the saved library does not have yet are
# ADDED (never ones you deleted), and a shipped entry with a higher Revision
# replaces the saved one unless you have edited it.
#
#   Read-Library -App $App                -> @{ Path; Entries; DeletedIds }
#   Save-LibraryEntry -App $App -Entry $e  (add or replace by Id; re-reads first)
#   Remove-LibraryEntry -App $App -Id $id
#   Find-LibraryEntries -Entries $e -Text 'lockout ad' [-Category X] [-Deep] [-Ready $map -RunnableOnly]
#   New-LibraryEntry  (an empty entry with every field)
#   Get-/Set-LibraryLastValues -App $App -Id $id   (Run dialog memory; no secrets)
#
# Entry fields: Id, Kind, Name, Function, Category, Tags[], Description, HowToUse,
#   WhereToRun, Requirements, Modules[], Modifies, RemoteCapable, Code, Template, Notes,
#   Methods[] { Label, Template } (fallbacks, tried in order when the main
#   method cannot run here), Elevation ('' = worked out, 'Required', 'No'),
#   Ports[] (extra TCP ports to check on the target),
#   Source { Kind, Project, Version, File, Hash, Imported }, Revision, Edited,
#   Created, Updated
#
# Kind 'Function' (default): Code defines Function, which is called with the
#   Run dialog's values.
# Kind 'Command': a syntax template (Services_CommandTemplate). Code holds only
#   a param() block (with optional comment help) that declares the fields;
#   Template is the command line with {Field} tokens; Function is the command's
#   name for the list.

$script:LibraryFields = @('Id', 'Kind', 'Template', 'Name', 'Function', 'Category', 'Tags', 'Description', 'HowToUse', 'WhereToRun',
    'Requirements', 'Modules', 'Modifies', 'RemoteCapable', 'Code', 'Notes', 'Methods', 'Elevation', 'Ports', 'Source', 'Revision', 'Edited', 'Created', 'Updated')

function Get-LibraryCodeHash {
    [CmdletBinding()]
    param([AllowEmptyString()] [string]$Code)
    $norm = ([string]$Code) -replace "`r`n", "`n"
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($norm))) -replace '-', '').ToLower() }
    finally { $sha.Dispose() }
}

function New-LibraryEntry {
    [CmdletBinding()]
    param()
    $now = (Get-Date).ToUniversalTime().ToString('s') + 'Z'
    [ordered]@{
        Id = [guid]::NewGuid().ToString(); Kind = 'Function'; Name = ''; Function = ''; Category = 'General'; Tags = @()
        Description = ''; HowToUse = ''; WhereToRun = ''; Requirements = ''; Modules = @()
        Modifies = $false; RemoteCapable = $true; Code = ''; Template = ''; Notes = ''
        Methods = @(); Elevation = ''; Ports = @()
        Source = [ordered]@{ Kind = 'Manual'; Project = ''; Version = ''; File = ''; Hash = ''; Imported = '' }
        Revision = 1; Edited = $false; Created = $now; Updated = $now
    }
}

# A loaded entry (PSCustomObject from JSON) as an ordered hashtable with every field.
function ConvertTo-LibraryEntry {
    param($Obj)
    $e = New-LibraryEntry
    if ($null -eq $Obj) { return $e }
    foreach ($f in $script:LibraryFields) {
        $has = $false; $v = $null
        if ($Obj -is [System.Collections.IDictionary]) { if ($Obj.Contains($f)) { $has = $true; $v = $Obj[$f] } }
        elseif ($Obj.PSObject.Properties[$f]) { $has = $true; $v = $Obj.$f }
        if (-not $has) { continue }
        if ($f -eq 'Source') {
            $s = [ordered]@{ Kind = 'Manual'; Project = ''; Version = ''; File = ''; Hash = ''; Imported = '' }
            if ($v) { foreach ($k in @($s.Keys)) { $sv = if ($v -is [System.Collections.IDictionary]) { $v[$k] } else { $v.$k }; if ($null -ne $sv) { $s[$k] = [string]$sv } } }
            $e.Source = $s
        }
        elseif ($f -in @('Tags', 'Modules')) { $e[$f] = @($v | Where-Object { $_ } | ForEach-Object { [string]$_ }) }
        elseif ($f -eq 'Methods') {
            # fallbacks: Label + Template (same fields as the entry)
            $e.Methods = @(foreach ($m in @($v)) {
                if (-not $m) { continue }
                $lbl = if ($m -is [System.Collections.IDictionary]) { $m['Label'] } else { $m.Label }
                $tpl = if ($m -is [System.Collections.IDictionary]) { $m['Template'] } else { $m.Template }
                if (([string]$tpl).Trim()) { [ordered]@{ Label = [string]$lbl; Template = [string]$tpl } }
            })
        }
        elseif ($f -eq 'Ports') { $e.Ports = @(@($v) | ForEach-Object { $n = 0; if ([int]::TryParse([string]$_, [ref]$n) -and $n -gt 0) { $n } }) }
        elseif ($f -eq 'Elevation') { $e.Elevation = $(if ([string]$v -in @('Required', 'No')) { [string]$v } else { '' }) }
        elseif ($f -in @('Modifies', 'RemoteCapable', 'Edited')) { $e[$f] = [bool]$v }
        elseif ($f -eq 'Revision') { $n = 1; [void][int]::TryParse([string]$v, [ref]$n); $e[$f] = $n }
        else { $e[$f] = [string]$v }
    }
    if (-not $e.Id) { $e.Id = [guid]::NewGuid().ToString() }
    if ($e.Kind -ne 'Command') { $e.Kind = 'Function' }
    if (-not $e.Name) { $e.Name = $e.Function }
    return $e
}

function Get-LibraryPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $App)
    return (Join-Path (Get-AppSettingsDir -App $App) 'Library.json')
}

function Read-LibraryFile {
    param([string]$Path)
    $r = @{ Entries = @(); DeletedIds = @(); Ok = $false }
    if (-not (Test-Path -LiteralPath $Path)) { return $r }
    $raw = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    if (-not $raw.Trim()) { $r.Ok = $true; return $r }
    $j = $raw | ConvertFrom-Json -ErrorAction Stop
    $r.Entries = @(@($j.Entries) | Where-Object { $_ } | ForEach-Object { ConvertTo-LibraryEntry $_ })
    $r.DeletedIds = @(@($j.DeletedIds) | Where-Object { $_ } | ForEach-Object { [string]$_ })
    $r.Ok = $true
    return $r
}

function Write-LibraryFile {
    param([string]$Path, [object[]]$Entries, [string[]]$DeletedIds)
    $doc = [ordered]@{
        Format     = 1
        Saved      = (Get-Date).ToUniversalTime().ToString('s') + 'Z'
        Entries    = @($Entries | Sort-Object { $_.Category }, { $_.Name })
        DeletedIds = @($DeletedIds | Where-Object { $_ } | Sort-Object -Unique)
    }
    $json = ConvertTo-Json -InputObject $doc -Depth 8
    # write beside, then swap: a crash mid-write never leaves half a library
    $tmp = "$Path.tmp"
    [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false)))
    if (Test-Path -LiteralPath $Path) {
        $bak = "$Path.bak"
        [System.IO.File]::Copy($Path, $bak, $true)
        [System.IO.File]::Delete($Path)
    }
    [System.IO.File]::Move($tmp, $Path)
}

function Read-Library {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $App)
    $path = Get-LibraryPath -App $App
    $lib = @{ Entries = @(); DeletedIds = @(); Ok = $true }
    try { $lib = Read-LibraryFile -Path $path }
    catch {
        if ($App) { $App.Log('ERROR', 'Library', "Library.json could not be read: $($_.Exception.Message)") }
        throw "The library file could not be read ($path): $($_.Exception.Message). A backup may be at Library.json.bak."
    }

    # merge the shipped starting set
    $shippedPath = Join-Path (Join-Path ([string]$App.LocalAppData) 'Config') 'Library.json'
    $changed = $false
    if ((Test-Path -LiteralPath $shippedPath) -and ($shippedPath -ne $path)) {
        try {
            $shipped = Read-LibraryFile -Path $shippedPath
            $byId = @{}
            foreach ($e in $lib.Entries) { $byId[$e.Id] = $e }
            $list = New-Object System.Collections.Generic.List[object]
            foreach ($e in $lib.Entries) { $list.Add($e) }
            foreach ($s in $shipped.Entries) {
                if ($lib.DeletedIds -contains $s.Id) { continue }
                if (-not $byId.ContainsKey($s.Id)) { $list.Add($s); $changed = $true; continue }
                $cur = $byId[$s.Id]
                if ([int]$s.Revision -gt [int]$cur.Revision -and -not $cur.Edited) {
                    $i = $list.IndexOf($cur); $list[$i] = $s; $changed = $true
                }
            }
            $lib.Entries = $list.ToArray()
            if ($changed) {
                Write-LibraryFile -Path $path -Entries $lib.Entries -DeletedIds $lib.DeletedIds
                if ($App) { $App.Log('INFO', 'Library', 'Merged new shipped entries into the library.') }
            }
        }
        catch { if ($App) { $App.Log('WARN', 'Library', "Shipped Config\Library.json not merged: $($_.Exception.Message)") } }
    }
    return @{ Path = $path; Entries = @($lib.Entries); DeletedIds = @($lib.DeletedIds) }
}

function Save-LibraryEntry {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $App, [Parameter(Mandatory)] $Entry)
    $path = Get-LibraryPath -App $App
    $lib = Read-LibraryFile -Path $path          # re-read: someone else may have saved meanwhile
    $e = ConvertTo-LibraryEntry $Entry
    $e.Updated = (Get-Date).ToUniversalTime().ToString('s') + 'Z'
    $list = New-Object System.Collections.Generic.List[object]
    $replaced = $false
    foreach ($x in $lib.Entries) {
        if ($x.Id -eq $e.Id) { $list.Add($e); $replaced = $true } else { $list.Add($x) }
    }
    if (-not $replaced) { $list.Add($e) }
    Write-LibraryFile -Path $path -Entries $list.ToArray() -DeletedIds @($lib.DeletedIds | Where-Object { $_ -ne $e.Id })
    if ($App) { $App.LogAction("Library: $(if ($replaced) { 'updated' } else { 'added' }) '$($e.Name)' ($($e.Function))") }
    return $e
}

function Remove-LibraryEntry {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $App, [Parameter(Mandatory)] [string]$Id)
    $path = Get-LibraryPath -App $App
    $lib = Read-LibraryFile -Path $path
    $gone = @($lib.Entries | Where-Object { $_.Id -eq $Id })
    $keep = @($lib.Entries | Where-Object { $_.Id -ne $Id })
    Write-LibraryFile -Path $path -Entries $keep -DeletedIds (@($lib.DeletedIds) + $Id)
    if ($App -and $gone.Count) { $App.LogAction("Library: deleted '$($gone[0].Name)' ($($gone[0].Function))") }
}

# Search looks at the NAME and the KEYWORDS (tags + the command name) only, by
# whole words: every word you type must start a word of the name or a keyword
# ("ping" finds Ping, not "mapping"). Best matches first: a word of the name
# beats a keyword, a whole word beats a prefix. -Deep also searches the
# description, how-to, notes and code.
$script:LibraryWordCache = @{}
function Get-LibraryWordSet {
    param([string[]]$Text)
    $set = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($t in $Text) {
        $l = ([string]$t).ToLower().Trim()
        if (-not $l) { continue }
        [void]$set.Add($l)
        foreach ($w in ($l -split '[^a-z0-9.$]+')) { if ($w) { [void]$set.Add($w) } }
    }
    return ,$set
}

function Find-LibraryEntries {
    [CmdletBinding()]
    param([object[]]$Entries = @(), [string]$Text = '', [string]$Category = '', [switch]$Deep, [switch]$IncludeCode,
        [hashtable]$Ready = $null, [switch]$RunnableOnly)
    if ($IncludeCode) { $Deep = $true }
    $words = @(([string]$Text).ToLower() -split '\s+' | Where-Object { $_ })
    $scored = New-Object System.Collections.Generic.List[object]
    foreach ($e in $Entries) {
        if ($Category -and $e.Category -ne $Category) { continue }
        if ($RunnableOnly -and $Ready -and $Ready.ContainsKey([string]$e.Id) -and $Ready[[string]$e.Id].Level -eq 'Blocked') { continue }
        if ($words.Count -eq 0) { $scored.Add([pscustomobject]@{ E = $e; S = 0 }); continue }
        $sig = [string]$e.Name + '|' + (@($e.Tags) -join '|') + '|' + [string]$e.Function
        $wc = $script:LibraryWordCache[[string]$e.Id]
        if (-not $wc -or $wc.Sig -ne $sig) {
            $wc = @{ Sig = $sig; Name = (Get-LibraryWordSet @([string]$e.Name)); Keys = (Get-LibraryWordSet (@($e.Tags) + @([string]$e.Function))) }
            $script:LibraryWordCache[[string]$e.Id] = $wc
        }
        $name = $wc.Name; $keys = $wc.Keys
        $hay = $null
        $score = 0; $ok = $true
        foreach ($w in $words) {
            $kx = $keys.Contains($w)
            if ($name.Contains($w)) { $score += 10 + $(if ($kx) { 3 } else { 0 }); continue }
            $hit = $false
            foreach ($t in $name) { if ($t.StartsWith($w)) { $hit = $true; break } }
            if ($hit) { $score += 6 + $(if ($kx) { 3 } else { 0 }); continue }
            if ($kx) { $score += 5; continue }
            foreach ($t in $keys) { if ($t.StartsWith($w)) { $hit = $true; break } }
            if ($hit) { $score += 3; continue }
            if ($Deep) {
                if ($null -eq $hay) { $hay = (@($e.Description, $e.HowToUse, $e.WhereToRun, $e.Notes, $e.Template, $e.Code) -join ' ').ToLower() }
                if ($hay.Contains($w)) { $score += 1; continue }
            }
            $ok = $false; break
        }
        if (-not $ok) { continue }
        if (([string]$e.Name).ToLower().StartsWith(([string]$Text).Trim().ToLower())) { $score += 4 }
        $scored.Add([pscustomobject]@{ E = $e; S = $score })
    }
    $arr = $scored.ToArray()
    if ($words.Count -eq 0) {
        $keysArr = [string[]]@(foreach ($x in $arr) { [string]$x.E.Category + [char]1 + [string]$x.E.Name })
    }
    else {
        $keysArr = [string[]]@(foreach ($x in $arr) { (1000 - [int]$x.S).ToString('0000') + [char]1 + [string]$x.E.Name })
    }
    # the non-generic overload sorts $arr in place (the generic one would sort a copy)
    [Array]::Sort([Array]$keysArr, [Array]$arr, [System.Collections.IComparer][StringComparer]::OrdinalIgnoreCase)
    return @(foreach ($x in $arr) { $x.E })
}

# ---- Run dialog memory: the last values per entry (never credentials) ----
# Kept per user on this machine (local AppData), even when the library itself
# is on a share.
function Get-LibraryLocalSettingsPath {
    param($App)
    $dir = Join-Path ([string]$App.LocalAppData) 'Settings'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    return (Join-Path $dir 'LibraryLastValues.json')
}

function Get-LibraryLastValues {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $App, [Parameter(Mandatory)] [string]$Id)
    $p = Get-LibraryLocalSettingsPath -App $App
    $h = @{}
    try {
        if (Test-Path -LiteralPath $p) {
            $j = [System.IO.File]::ReadAllText($p) | ConvertFrom-Json
            $node = $j.PSObject.Properties[$Id]
            if ($node) { foreach ($pr in $node.Value.PSObject.Properties) { $h[$pr.Name] = $pr.Value } }
        }
    } catch { }
    return $h
}

function Set-LibraryLastValues {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $App, [Parameter(Mandatory)] [string]$Id, [hashtable]$Values = @{})
    $p = Get-LibraryLocalSettingsPath -App $App
    $all = [ordered]@{}
    try {
        if (Test-Path -LiteralPath $p) {
            $j = [System.IO.File]::ReadAllText($p) | ConvertFrom-Json
            foreach ($pr in $j.PSObject.Properties) { $all[$pr.Name] = $pr.Value }
        }
    } catch { }
    $clean = [ordered]@{}
    foreach ($k in $Values.Keys) {
        $v = $Values[$k]
        if ($v -is [System.Management.Automation.PSCredential] -or $v -is [System.Security.SecureString]) { continue }
        $clean[$k] = $v
    }
    $all[$Id] = $clean
    try { [System.IO.File]::WriteAllText($p, (ConvertTo-Json -InputObject $all -Depth 5), (New-Object System.Text.UTF8Encoding($false))) }
    catch { if ($App) { $App.Log('WARN', 'Library', "last values not saved: $($_.Exception.Message)") } }
}

# The value an environment offers for a parameter (Domain, Server, SearchBase
# ... any Environment field whose key matches the parameter name).
function Get-LibraryEnvironmentDefault {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $App, [Parameter(Mandatory)] [string]$Name)
    $aliases = @{
        'domainname' = 'Domain'; 'dnsdomain' = 'Domain'
        'dc' = 'Server'; 'domaincontroller' = 'Server'
        'ou' = 'SearchBase'; 'searchroot' = 'SearchBase'
    }
    $keys = @($Name)
    if ($aliases.ContainsKey($Name.ToLower())) { $keys += $aliases[$Name.ToLower()] }
    foreach ($k in $keys) {
        if ($k -in @('Label', 'SharedPath', 'Name')) { continue }
        try { $v = [string]$App.GetSetting($k); if ($v.Trim()) { return $v.Trim() } } catch { }
    }
    return ''
}
