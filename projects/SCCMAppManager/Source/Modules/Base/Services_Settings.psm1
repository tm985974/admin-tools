# Services_Settings.psm1   (BASE TIER)
#
# A WRITABLE, PERSISTENT folder for settings a module saves at runtime (word
# lists, per-domain defaults, user preferences ...).
#
# Why not Config\ ?  <data root>\Config (local AppData) is the host's read-only
# MIRROR of the embedded Config\*.json and is REWRITTEN from the EXE on every
# launch, so anything a module saves there is silently reverted next launch.
#
#   Get-AppSettingsDir -App $App   ->  <DataRoot>\Settings
#
# The folder lives under the resolved data root, so it follows the active
# environment (shared network path when reachable, else local AppData). On
# first use, any embedded Config\*.json not already present is COPIED in as the
# starting value (Environments.json excepted - the host owns it). After that the
# saved copy wins; ship a changed default by deleting the saved file.

function Get-AppSettingsDir {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $App)

    $root = [string]$App.DataRoot
    if (-not $root) { $root = [string]$App.LocalAppData }
    $dir = Join-Path $root 'Settings'
    try { if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null } }
    catch { if ($App) { $App.Log('WARN', 'Settings', "cannot create $dir : $($_.Exception.Message)") } }

    # seed from the embedded-config mirror (local AppData\Config)
    $mirror = Join-Path ([string]$App.LocalAppData) 'Config'
    if (Test-Path -LiteralPath $mirror) {
        foreach ($f in @(Get-ChildItem -LiteralPath $mirror -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
            if ($f.Name -ieq 'Environments.json') { continue }
            $dest = Join-Path $dir $f.Name
            if (-not (Test-Path -LiteralPath $dest)) {
                try { Copy-Item -LiteralPath $f.FullName -Destination $dest -ErrorAction Stop } catch { }
            }
        }
    }
    return $dir
}

# ---- app-wide logging settings (Settings\Logging.json) ----------------------
#   DiagnosticsEnabled : write [DIAG] detail to Session.log (default false)
#   SessionLogMaxKB    : Session.log size cap, oldest lines dropped (default 10240)
# One set for the whole app (all environments). Edited on the Environment tab's
# Logging page; applied to the host with $App.ConfigureLogging.

function Get-AppLoggingSettings {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $App)
    $s = [pscustomobject]@{ DiagnosticsEnabled = $false; SessionLogMaxKB = 10240 }
    try {
        $p = Join-Path (Get-AppSettingsDir -App $App) 'Logging.json'
        if (Test-Path -LiteralPath $p) {
            $j = Get-Content -LiteralPath $p -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            if ($null -ne $j.DiagnosticsEnabled) { $s.DiagnosticsEnabled = [bool]$j.DiagnosticsEnabled }
            if ($j.SessionLogMaxKB -and [int]$j.SessionLogMaxKB -ge 64) { $s.SessionLogMaxKB = [int]$j.SessionLogMaxKB }
        }
    } catch { if ($App) { $App.Log('WARN', 'Settings', "Logging.json: $($_.Exception.Message)") } }
    return $s
}

function Set-AppLoggingSettings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $App,
        [bool]$DiagnosticsEnabled = $false,
        [int]$SessionLogMaxKB = 10240
    )
    if ($SessionLogMaxKB -lt 64) { throw 'Session log max must be 64 KB or more.' }
    $p = Join-Path (Get-AppSettingsDir -App $App) 'Logging.json'
    $o = [ordered]@{}
    try { if (Test-Path -LiteralPath $p) { $old = Get-Content -LiteralPath $p -Raw | ConvertFrom-Json; foreach ($pr in $old.PSObject.Properties) { $o[$pr.Name] = $pr.Value } } } catch { }
    $o['DiagnosticsEnabled'] = $DiagnosticsEnabled
    $o['SessionLogMaxKB']    = $SessionLogMaxKB
    ([pscustomobject]$o | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $p -Encoding UTF8
    Initialize-AppLogging -App $App
    Invoke-AppSettingsChanged -App $App -Name 'Logging'
}

# Apply the saved logging settings to the host (called at start-up by the tab
# registrar, and after every save).
function Initialize-AppLogging {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $App)
    $s = Get-AppLoggingSettings -App $App
    try { $App.ConfigureLogging([bool]$s.DiagnosticsEnabled, [int]$s.SessionLogMaxKB) } catch { }
}

# ---- settings-changed notifications -----------------------------------------
# A module that caches app-wide settings registers a handler; whatever saves
# them calls Invoke-AppSettingsChanged -Name '<area>'. Handlers run as
#   & $Handler $App $Name
function Register-AppSettingsChangedHandler {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [scriptblock]$Handler)
    if (-not $global:AppSettingsChangedHandlers) {
        $global:AppSettingsChangedHandlers = New-Object System.Collections.Generic.List[scriptblock]
    }
    [void]$global:AppSettingsChangedHandlers.Add($Handler)
}

function Invoke-AppSettingsChanged {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $App, [string]$Name = '')
    if (-not $global:AppSettingsChangedHandlers) { return }
    foreach ($h in $global:AppSettingsChangedHandlers) {
        try { & $h $App $Name }
        catch { if ($App) { $App.Log('ERROR', 'Settings', "settings-changed handler failed: $($_.Exception.Message)") } }
    }
}
