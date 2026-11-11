# _AppLauncher.ps1 -- launcher only. No business logic.
#
# Run by the C# host (AppHost.cs) on the UI thread after the main window is up.
# The host sets these variables in the runspace before invoking this script:
#   $App       - the App context object (paths, active environment, logging, theme)
#   $MainTabs  - the empty TabControl on the main form, for tabs to fill
#   $AppForm   - the main Form (rarely needed)
#   $Modules   - hashtable: module name -> .psm1 text (embedded in the EXE)
#
# All functionality lives in .\Modules\*.psm1, one function per module, so the
# Function Map (function -> module) stays meaningful. This launcher imports them
# and asks the tab registrar to build the tabs.

Set-StrictMode -Off
$ErrorActionPreference = 'Continue'

Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
Add-Type -AssemblyName System.Drawing        -ErrorAction SilentlyContinue

# ---------------------------------------------------------------------------
# OPTIONAL shared-scope loading (for porting a legacy tool)
# ---------------------------------------------------------------------------
# Configured per project in Config\SharedScope.json (project-owned), so this
# launcher stays identical in every project:
#   {
#     "Modules": [ "Legacy_*", "Shared_*" ],   names or wildcards; [] = none
#     "Order":   [ "Legacy_Core", ... ]        exact names, combined first
#   }
# Greenfield projects: leave both lists EMPTY - every module is imported in
# isolation, which is correct for modules written for this template.
#
# Porting an older PowerShell tool whose files were DOT-SOURCED into one shared
# scope (modules read/write each other's $script: variables)? List those modules
# under "Modules". They are COMBINED into one module and imported once,
# preserving that shared state. "Order" is the combine order (paste the legacy
# tool's own load order if its module-level code depends on it); modules not
# listed follow alphabetically. Everything else stays isolated.
#
# After the combined module is imported, the launcher calls
#   Initialize-SharedScope -App $App
# if one of the shared-scope modules defines it (set up $script: state there).
$SharedScopeModules = @()
$SharedScopeOrder   = @()
try {
    $ssPath = Join-Path (Join-Path ([string]$App.LocalAppData) 'Config') 'SharedScope.json'
    if ($App -and (Test-Path -LiteralPath $ssPath)) {
        $ss = [System.IO.File]::ReadAllText($ssPath) | ConvertFrom-Json
        $SharedScopeModules = @($ss.Modules | Where-Object { $_ })
        $SharedScopeOrder   = @($ss.Order   | Where-Object { $_ })
    }
}
catch { if ($App) { $App.Log('ERROR', 'Launcher', "Config\SharedScope.json could not be read: $($_.Exception.Message)") } }

function Test-SharedScope([string]$name) {
    foreach ($pat in $SharedScopeModules) { if ($name -like $pat) { return $true } }
    return $false
}

# Strip Export-ModuleMember (incl. backtick-continued multi-line forms) so a
# combined module exports every function by default.
function Remove-ExportStatements([string]$text) {
    $out = New-Object System.Collections.Generic.List[string]
    $skip = $false
    foreach ($ln in ($text -split "`r?`n")) {
        if ($skip) { if ($ln -notmatch '`\s*$') { $skip = $false }; continue }
        if ($ln -match '^\s*Export-ModuleMember') { if ($ln -match '`\s*$') { $skip = $true }; continue }
        [void]$out.Add($ln)
    }
    return ($out -join "`r`n")
}

# Every top-level function name defined in a module's text (parser-based, so
# comments/strings don't count). Used to warn when two modules define the same
# function - the later import silently wins, which is a classic porting bug.
function Get-ModuleFunctionNames([string]$text) {
    $names = @()
    try {
        $tokens = $null; $errs = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$errs)
        $names = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false) |
                   Where-Object { -not ($_.Parent -is [System.Management.Automation.Language.FunctionDefinitionAst]) } |
                   ForEach-Object { $_.Name })
    } catch { }
    return $names
}

$sharedNames = New-Object System.Collections.Generic.List[string]
$isolated    = New-Object System.Collections.Generic.List[string]
$fnOwners    = @{}

if ($Modules) {
    foreach ($name in @($Modules.Keys | Sort-Object)) {
        foreach ($fn in (Get-ModuleFunctionNames ([string]$Modules[$name]))) {
            if ($fnOwners.ContainsKey($fn)) { $fnOwners[$fn] = @($fnOwners[$fn]) + $name } else { $fnOwners[$fn] = @($name) }
        }
        if (Test-SharedScope $name) { [void]$sharedNames.Add($name) } else { [void]$isolated.Add($name) }
    }
    foreach ($fn in @($fnOwners.Keys | Sort-Object)) {
        if (@($fnOwners[$fn]).Count -gt 1 -and $App) {
            $App.Log('WARN', 'Launcher', "Function '$fn' is defined in more than one module: $(@($fnOwners[$fn]) -join ', '). Only one definition survives.")
        }
    }

    foreach ($name in $isolated) {
        try { New-Module -Name $name -ScriptBlock ([ScriptBlock]::Create([string]$Modules[$name])) | Import-Module -Force -Global }
        catch { if ($App) { $App.Log('ERROR', 'Launcher', "module '$name' failed to import: $($_.Exception.Message)") } }
    }
}

if ($sharedNames.Count -gt 0) {
    # deterministic order: $SharedScopeOrder first, the rest alphabetically
    $ordered = New-Object System.Collections.Generic.List[string]
    foreach ($n in $SharedScopeOrder) { if ($sharedNames -contains $n -and -not ($ordered -contains $n)) { [void]$ordered.Add($n) } }
    foreach ($n in $sharedNames)      { if (-not ($ordered -contains $n)) { [void]$ordered.Add($n) } }

    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($n in $ordered) {
        # Parse each part on its own first, so one broken file is named (and
        # skipped) instead of failing the whole combined module.
        $txt = Remove-ExportStatements ([string]$Modules[$n])
        $tokens = $null; $errs = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput($txt, [ref]$tokens, [ref]$errs)
        if ($errs -and $errs.Count -gt 0) {
            if ($App) { $App.Log('ERROR', 'Launcher', "shared module '$n' has a syntax error and was skipped: $($errs[0].Message) (line $($errs[0].Extent.StartLineNumber))") }
            continue
        }
        # Each part runs inside its own try/catch (try does not create a scope in
        # PowerShell, so its functions and $script: state still land in the
        # shared module). A part whose top-level code throws is reported by name
        # and the parts after it still load.
        $nq = $n -replace "'", "''"
        [void]$parts.Add("### ==== $n ====`r`ntry {`r`n$txt`r`n} catch { [void]`$global:SharedScopeLoadErrors.Add('$nq : ' + `$_.Exception.Message) }`r`n")
    }
    try {
        $global:SharedScopeLoadErrors = New-Object System.Collections.Generic.List[string]
        $blob = [string]::Join("`r`n", $parts)
        New-Module -Name 'SharedScope' -ScriptBlock ([ScriptBlock]::Create($blob)) | Import-Module -Force -Global
        foreach ($le in $global:SharedScopeLoadErrors) { if ($App) { $App.Log('ERROR', 'Launcher', "shared module load error: $le") } }
        if ($App) { $App.Log('INFO', 'Launcher', "SharedScope module loaded ($($parts.Count) of $($ordered.Count) parts, $($global:SharedScopeLoadErrors.Count) load error(s)).") }
        if (Get-Command Initialize-SharedScope -ErrorAction SilentlyContinue) { Initialize-SharedScope -App $App }
    }
    catch { if ($App) { $App.Log('ERROR', 'Launcher', "SharedScope combine failed: $($_.Exception.ToString())") } }
}

# ---- build the tabs ----
try {
    if (Get-Command Register-AppTabs -ErrorAction SilentlyContinue) {
        Register-AppTabs -Tabs $MainTabs -App $App
        if ($App) { $App.Log('INFO', 'Launcher', "Tabs built: $($MainTabs.TabPages.Count).") }
    }
    else {
        if ($App) { $App.Log('ERROR', 'Launcher', 'Register-AppTabs not found (UI_Register-Tabs.psm1 missing?).') }
    }
}
catch {
    if ($App) { $App.Log('ERROR', 'Launcher', "Register-AppTabs threw: $($_.Exception.Message)") }
}

# ---- hover help for every clickable control (Base\Services_ToolTips.psm1) ----
# Texts come from the engine and the project's Config\ToolTips.json; controls
# built later (lazy tabs, dialogs, menus) are picked up as they appear.
try {
    if ($App -and (Get-Command Start-AppToolTips -ErrorAction SilentlyContinue)) { Start-AppToolTips -App $App -Form $AppForm }
}
catch {
    if ($App) { $App.Log('ERROR', 'Launcher', "Start-AppToolTips threw: $($_.Exception.Message)") }
}
