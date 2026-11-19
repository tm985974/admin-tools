# Services_EnvironmentStore.psm1   (BASE TIER)
#
# The saved environments: one record per environment, holding EVERY setting of
# that environment (General + whatever pages the project adds).
#
# ONE file per EXE ($App.EnvironmentStorePath), template 1.2:
#   Developer build  Source\Config\Environments.json  - the project's own file:
#                    edited here, committed to git, built into the Lite EXE.
#   Lite EXE         <LocalAppData>\<app>\Settings\Environments.json - what an
#                    admin saves on this machine, over the built-in set.
#   {
#     "ActiveDefault": "<Name>",
#     "Environments":  [ { "Name": "...", "Label": "...", "SharedPath": "...", ... }, ... ],
#     "Removed":       [ "<Name of an embedded environment deleted on purpose>" ],
#     ...              (other top-level keys are kept, e.g. one-time import markers)
#   }
#
# Lite EXE: created the first time an admin saves. Until then - and for any
# built-in environment not in it - the built-in set is used ("Removed" lists the
# built-in ones deleted on purpose). The host (AppHost.cs) merges the two the same
# way. Per machine on purpose: the store decides the data root, so it cannot live
# on the shared path. Developer build ($App.EnvironmentsAreSource): the file IS the
# set - nothing is merged, nothing is copied anywhere else.
#
#   Read-AppEnvironmentStore    -App           -> @{ ActiveDefault; Environments (ArrayList of [ordered]); Removed (ArrayList); Extra ([ordered]); Exists }
#   Write-AppEnvironmentStore   -App -Store    -> saves, keeps Environments.json.bak, reloads the host
#   Get-AppEnvironmentRecord    -App [-Name]   -> [ordered] record (default: the active one) or $null
#   Save-AppEnvironmentRecord   -App -Record   -> insert/replace by Name, stamps SavedUtc
#   New-AppEnvironmentRecord    -App -Label [-CopyFrom <record>] [-Exclude <keys>]
#   Remove-AppEnvironmentRecord -App -Name
#
# Records are [ordered] hashtables. Collections here are ArrayLists, never
# List[object]: PowerShell throws "Argument types do not match" on @() of one.

$script:EnvStoreCache = @{ Path = ''; Stamp = [datetime]::MinValue; Json = $null }

function ConvertTo-EnvRecord {
    param($Obj)
    $r = [ordered]@{}
    if ($null -eq $Obj) { return $r }
    if ($Obj -is [System.Collections.IDictionary]) { foreach ($k in @($Obj.Keys)) { $r[[string]$k] = $Obj[$k] }; return $r }
    foreach ($p in $Obj.PSObject.Properties) { $r[$p.Name] = $p.Value }
    return $r
}

function Read-EnvJsonFile {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $null }
    $txt = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    if (-not $txt -or -not $txt.Trim()) { return $null }
    return ($txt | ConvertFrom-Json -ErrorAction Stop)
}

function Read-AppEnvironmentStore {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $App)

    $store = @{
        ActiveDefault = ''
        Environments  = New-Object System.Collections.ArrayList
        Removed       = New-Object System.Collections.ArrayList
        Extra         = [ordered]@{}
        Exists        = $false
    }
    $path = [string]$App.EnvironmentStorePath

    # the store (cached until the file changes)
    $json = $null
    try {
        if ($path -and (Test-Path -LiteralPath $path)) {
            $stamp = (Get-Item -LiteralPath $path).LastWriteTimeUtc
            if ($script:EnvStoreCache.Path -eq $path -and $script:EnvStoreCache.Stamp -eq $stamp -and $script:EnvStoreCache.Json) {
                $json = $script:EnvStoreCache.Json
            } else {
                $json = Read-EnvJsonFile -Path $path
                $script:EnvStoreCache = @{ Path = $path; Stamp = $stamp; Json = $json }
            }
        }
    } catch {
        if ($App) { $App.Log('ERROR', 'Environment', "Environment store $path could not be read (using the embedded set): $($_.Exception.Message)") }
        $json = $null
    }
    if ($json) {
        $store.Exists = $true
        foreach ($p in $json.PSObject.Properties) {
            switch ($p.Name) {
                'ActiveDefault' { $store.ActiveDefault = [string]$p.Value }
                'Environments'  { foreach ($e in @($p.Value)) { if ($e -and $e.Name) { [void]$store.Environments.Add((ConvertTo-EnvRecord $e)) } } }
                'Removed'       { foreach ($n in @($p.Value)) { if ($n) { [void]$store.Removed.Add([string]$n) } } }
                default         { $store.Extra[$p.Name] = $p.Value }
            }
        }
    }

    # Lite EXE: add the built-in set (the host mirrors it to <LocalAppData>\Config
    # each launch). Developer build: the store is the project's file - nothing to add.
    if ($App.EnvironmentsAreSource -and $store.Exists) { return $store }
    $emb = $null
    try { $emb = Read-EnvJsonFile -Path (Join-Path (Join-Path ([string]$App.LocalAppData) 'Config') 'Environments.json') } catch { }
    if ($emb) {
        if (-not $store.ActiveDefault -and $emb.ActiveDefault) { $store.ActiveDefault = [string]$emb.ActiveDefault }
        foreach ($e in @($emb.Environments)) {
            if (-not $e -or -not $e.Name) { continue }
            $n = [string]$e.Name
            if ($store.Removed -contains $n) { continue }
            $have = $false
            foreach ($r in $store.Environments) { if ([string]$r['Name'] -ieq $n) { $have = $true; break } }
            if (-not $have) { [void]$store.Environments.Add((ConvertTo-EnvRecord $e)) }
        }
    }
    return $store
}

function Write-AppEnvironmentStore {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $App, [Parameter(Mandatory)] $Store, [switch]$NoReload)

    $path = [string]$App.EnvironmentStorePath
    $dir  = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    $root = [ordered]@{}
    $root['ActiveDefault'] = [string]$Store.ActiveDefault
    $root['Environments']  = [object[]]$Store.Environments.ToArray()
    if (-not $App.EnvironmentsAreSource) { $root['Removed'] = [object[]]$Store.Removed.ToArray() }
    foreach ($k in @($Store.Extra.Keys)) { if (-not $root.Contains($k)) { $root[$k] = $Store.Extra[$k] } }
    $text = ConvertTo-Json -InputObject $root -Depth 20

    if (Test-Path -LiteralPath $path) { try { Copy-Item -LiteralPath $path -Destination ($path + '.bak') -Force } catch { } }
    $tmp = $path + '.tmp'
    [System.IO.File]::WriteAllText($tmp, $text, (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $path -Force
    $script:EnvStoreCache = @{ Path = ''; Stamp = [datetime]::MinValue; Json = $null }

    if (-not $NoReload) { try { $App.ReloadEnvironments() } catch { } }
}

function Get-AppEnvironmentRecord {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $App, [string]$Name = '')
    if (-not $Name) { $Name = [string]$App.ActiveName }
    $store = Read-AppEnvironmentStore -App $App
    foreach ($r in $store.Environments) { if ([string]$r['Name'] -ieq $Name) { return $r } }
    return $null
}

function Save-AppEnvironmentRecord {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $App, [Parameter(Mandatory)] $Record, [switch]$NoReload)
    $rec = ConvertTo-EnvRecord $Record
    if (-not $rec['Name']) { throw 'An environment record needs a Name.' }
    $rec['SavedUtc'] = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    $store = Read-AppEnvironmentStore -App $App
    $idx = -1
    for ($i = 0; $i -lt $store.Environments.Count; $i++) { if ([string]$store.Environments[$i]['Name'] -ieq [string]$rec['Name']) { $idx = $i; break } }
    if ($idx -ge 0) { $store.Environments[$idx] = $rec } else { [void]$store.Environments.Add($rec) }
    Write-AppEnvironmentStore -App $App -Store $store -NoReload:$NoReload
    return $rec
}

function New-AppEnvironmentRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $App,
        [Parameter(Mandatory)] [string]$Label,
        $CopyFrom = $null,
        [string[]]$Exclude = @()
    )
    $store = Read-AppEnvironmentStore -App $App
    $base = ($Label -replace '[^A-Za-z0-9_.-]+', '-').Trim('-')
    if (-not $base) { $base = 'Environment' }
    $name = $base; $n = 2
    while (@($store.Environments | Where-Object { [string]$_['Name'] -ieq $name }).Count -gt 0 -or $store.Removed -contains $name) { $name = "$base-$n"; $n++ }

    $rec = [ordered]@{ Name = $name; Label = $Label.Trim() }
    if ($CopyFrom) {
        $skip = @('Name', 'Label', 'IsDefault', 'SavedUtc') + $Exclude
        foreach ($k in @($CopyFrom.Keys)) { if ($skip -notcontains $k) { $rec[$k] = $CopyFrom[$k] } }
    } else {
        $rec['SharedPath'] = ''; $rec['FilterAsYouType'] = $true; $rec['LogMaxKB'] = 5120
    }
    $rec['IsDefault'] = $false
    [void]$store.Environments.Add($rec)
    Write-AppEnvironmentStore -App $App -Store $store
    return $rec
}

function Remove-AppEnvironmentRecord {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $App, [Parameter(Mandatory)] [string]$Name)
    $store = Read-AppEnvironmentStore -App $App
    if ($store.Environments.Count -le 1) { throw 'The last environment cannot be deleted.' }
    $keep = New-Object System.Collections.ArrayList
    foreach ($r in $store.Environments) { if ([string]$r['Name'] -ine $Name) { [void]$keep.Add($r) } }
    $store.Environments = $keep
    if (-not $App.EnvironmentsAreSource -and -not ($store.Removed -contains $Name)) { [void]$store.Removed.Add($Name) }
    if ($store.ActiveDefault -ieq $Name) { $store.ActiveDefault = [string]$keep[0]['Name'] }
    Write-AppEnvironmentStore -App $App -Store $store
}
