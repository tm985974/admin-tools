# Services_Environment.psm1
#
# Read-only access to the active environment the user picked on the main form.
# The environment DEFINITIONS are embedded in the EXE and editable only in a
# developer build; at runtime they are selected, never edited. These helpers
# just surface the active environment's fields to module code.

function Get-AppSetting {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $App,
        [Parameter(Mandatory)] [string]$Key
    )
    if ($null -ne $App) { return $App.GetSetting($Key) }
    return ''
}

function Get-AppEnvironmentInfo {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $App)
    if ($null -eq $App) { return $null }
    [pscustomobject]@{
        Name           = $App.ActiveName
        Label          = $App.ActiveLabel
        SharedPath     = $App.SharedPath
        DataRoot       = $App.DataRoot
        DataRootStatus = $App.DataRootStatus   # Network | LocalFallback | LocalOnly
        Version        = $App.Version
    }
}

# ---- environment-changed notifications ----
# Modules that cache anything tied to the active environment (a connection, a
# data path) register a handler; the Environment tab calls Invoke-EnvironmentChanged
# after the user picks another environment. Handlers run in registration order
# as  & $Handler $App ; one failing handler is logged and does not stop the rest.
# (Stored globally because every Base module is imported in isolation.)

function Register-EnvironmentChangedHandler {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [scriptblock]$Handler)
    if (-not $global:AppEnvironmentChangedHandlers) {
        $global:AppEnvironmentChangedHandlers = New-Object System.Collections.Generic.List[scriptblock]
    }
    [void]$global:AppEnvironmentChangedHandlers.Add($Handler)
}

function Invoke-EnvironmentChanged {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $App)
    foreach ($h in @($global:AppEnvironmentChangedHandlers)) {
        if (-not $h) { continue }
        try { & $h $App }
        catch { if ($App) { $App.Log('ERROR', 'Environment', "environment-changed handler failed: $($_.Exception.Message)") } }
    }
}

# ---- project pages on the Environment tab ----
# The Environment tab = the environment picker (+ New / Delete / Save) and
# sub-tabs: General (template: name, log/data path, Variable 1-4, lists & logs,
# logging), then one sub-tab per page registered here, in -Order.
#
#   Register-EnvironmentSection -Title 'Mail' -Order 30 -Build {
#       param($Page, $App)
#       # add controls to $Page (a TabPage, AutoScroll on), then return:
#       @{
#           Load     = { param($Record) ... }          # show this environment's values
#           Collect  = { param($Record) @{ Key = value; ... } }   # values to save
#           Validate = { param($Record) '' }           # '' = ok, else the problem (optional)
#           Fingerprint = { param($Record) '...' }     # optional: a string that changes only when the
#                                                       # user changed something (default: Collect's values)
#       }
#   }
#
# $Record is the environment's saved record ([ordered] hashtable - see
# Services_EnvironmentStore). The tab builds every page once (on first view),
# calls Load when the environment changes, and on Save merges every page's
# Collect into the record and writes it. Pages never save on their own.
# A page only appears if its module is loaded (e.g. admin tier only).
# (Stored in an ArrayList: @() of a List[object] throws in PowerShell.)

function Register-EnvironmentSection {
    [CmdletBinding()]
    param(
        [string]$Title = '',
        [Parameter(Mandatory)] [scriptblock]$Build,
        [int]$Order = 100
    )
    if (-not ($global:AppEnvironmentSections -is [System.Collections.ArrayList])) {
        $global:AppEnvironmentSections = New-Object System.Collections.ArrayList
    }
    [void]$global:AppEnvironmentSections.Add([pscustomobject]@{ Title = $Title; Build = $Build; Order = $Order })
}

function Get-EnvironmentSections {
    [CmdletBinding()]
    param()
    if (-not ($global:AppEnvironmentSections -is [System.Collections.ArrayList])) { return @() }
    return @($global:AppEnvironmentSections | Where-Object { $null -ne $_ } | Sort-Object -Property { [int]$_.Order })
}

# The text fields at the top of the General page: Config\EnvironmentFields.json
#   { "Fields": [ { "Key": "Label", "Caption": "Environment name" }, ... ] }
# (read from the embedded-config mirror). Missing file = the template set.
# The rest of General (lists & logs, logging) is built in by the template.
function Get-EnvironmentFieldList {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $App)
    $default = @(
        [pscustomobject]@{ Key = 'Label';      Caption = 'Environment name' }
        [pscustomobject]@{ Key = 'SharedPath'; Caption = 'Log & data path (UNC, optional)' }
        [pscustomobject]@{ Key = 'Variable1';  Caption = 'Variable 1' }
        [pscustomobject]@{ Key = 'Variable2';  Caption = 'Variable 2' }
        [pscustomobject]@{ Key = 'Variable3';  Caption = 'Variable 3' }
        [pscustomobject]@{ Key = 'Variable4';  Caption = 'Variable 4' }
    )
    try {
        $p = Join-Path (Join-Path ([string]$App.LocalAppData) 'Config') 'EnvironmentFields.json'
        if (-not (Test-Path -LiteralPath $p)) { return $default }
        $j = Get-Content -LiteralPath $p -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $list = @($j.Fields | Where-Object { $_.Key } | ForEach-Object {
            [pscustomobject]@{ Key = [string]$_.Key; Caption = $(if ($_.Caption) { [string]$_.Caption } else { [string]$_.Key }) } })
        if ($list.Count -gt 0) { return $list }
    } catch { if ($App) { $App.Log('WARN', 'Environment', "EnvironmentFields.json: $($_.Exception.Message)") } }
    return $default
}

# The key a module should store per-environment data under: the environment's
# Domain when it has one, else its Name.
function Get-AppEnvironmentKey {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $App)
    $d = [string]$App.GetSetting('Domain')
    if ($d.Trim()) { return $d.Trim() }
    return [string]$App.ActiveName
}

# A value of the ACTIVE environment with its saved type (bool, int, object) -
# $App.GetSetting returns strings only. $Default when not set.
function Get-AppEnvironmentValue {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $App, [Parameter(Mandatory)] [string]$Key, $Default = $null)
    $r = $null
    if (Get-Command Get-AppEnvironmentRecord -ErrorAction SilentlyContinue) { $r = Get-AppEnvironmentRecord -App $App }
    if ($r -and $r.Contains($Key) -and $null -ne $r[$Key] -and [string]$r[$Key] -ne '') { return $r[$Key] }
    return $Default
}
