# Services_ToolTips.psm1   (BASE TIER)
#
# Hover help for everything you can click: buttons, check boxes, radio buttons,
# link labels, menu items (right-click menus included) and tabs.
#
# The texts live in ONE catalog, not in the modules:
#   - engine entries (this file: the developer buttons, the Environment tab,
#     common buttons such as OK / Cancel / Close)
#   - Config\ToolTips.json (project-owned): the project's own controls; an
#     entry there wins over an engine entry with the same key
#
#   {
#     "ToolTips": {
#       "Refresh":                    "fallback for any 'Refresh' button",
#       "Computers > Refresh":        "the 'Refresh' button on the Computers tab",
#       "Tools > Ping List > Ping":   "a button on a sub-tab",
#       "Ping Computers > Copy":      "a button in a dialog titled 'Ping Computers'",
#       "Tools > Ping List":          "the 'Ping List' sub-tab itself",
#       "Some button":                ""   <- empty = deliberately no tooltip
#     }
#   }
#
# A key is the control's text, optionally preceded by where it is: the titles
# of the tab pages / group boxes around it (outermost first) and, inside a
# dialog, the dialog's title (the part before " - ", so "Reset Password  -
# jdoe" is "Reset Password"). Matching ignores case, '&' mnemonics, a trailing
# "..." and repeated spaces. The most specific key that matches wins; any of the
# "where" parts may be left out ("Tools > Ping" also matches the Ping button on
# Tools > Ping List). Menu items use the place of the control the menu belongs
# to, plus the parent item's text for sub-menu items.
#
# Applied automatically: _AppLauncher.ps1 calls Start-AppToolTips once; a light
# timer then picks up every form that opens and every control added later (lazy
# tabs, dialogs, menus swapped at run time). Nothing to call from a module.
#
#   Set-AppToolTip -Control $c -Text '...'   set one in code (wins over the catalog)
#   Update-AppToolTips [-Root $c]            sweep now (normally not needed)
#   Get-AppToolTipMissing                    controls that have no entry yet
#
# Developer build: every clickable control without an entry is written to
#   <data root>\Logs\ToolTips_missing.txt   as ready-to-paste JSON lines
# so coverage can be completed by filling in Config\ToolTips.json.
# Buttons registered with Register-AppCommand (Services_Commands.psm1) get an
# extra line: "Right-click: show or copy the exact command."

$script:EngineToolTips = [ordered]@{
    # developer buttons (developer build only)
    'Build Lite'      = 'Developer build: make <ExeName>Lite.exe, the sealed build to hand out. Asks for a user and an admin password; the modules are encrypted with them and the source is left out.'
    'Version History' = 'Show every version of this app with its CHANGELOG notes.'
    'Open'            = 'Open a folder: the app folder (Lite EXE, Build-App.cmd), the Source folder, the Logs folder in use, or AppData (Settings, Extract).'
    'More'            = 'The zip-based tools from before git, for when you need them: Update from a zip or folder, Update Template from a template zip, Extract the source to a zip, Archive this version.'

    # Environment tab (template)
    'Environment'                                              = 'Pick, create and edit environments (one per domain / site). Editing needs the admin password.'
    'Environment > General'                                    = 'Name, log & data path, list and logging options, and when commands are shown before running.'
    'Environment > New'                                        = 'Create a new environment, optionally as a copy of the selected one (its domain and server are not copied).'
    'Environment > Delete'                                     = 'Delete the selected environment and all of its settings (developer build: from Source\Config\Environments.json; Lite: from this machine).'
    'Environment > Save'                                       = 'Save every page of the selected environment (and the app-wide logging and command settings).'
    'Environment > Filter as I type'                           = 'On: lists re-filter on every keystroke. Off: they filter when you press Enter (better for very large lists).'
    'Environment > Diagnostic / troubleshooting logging'       = 'Write extra troubleshooting detail (including the code of every command run) to Session.log. Leave off unless investigating.'
    'Overview'                                                 = 'What this app does and how it is laid out.'

    # common buttons (any tab or dialog; a project entry with a place wins)
    'OK'                = 'Accept and close this window.'
    'Cancel'            = 'Close this window without making any change.'
    'Close'             = 'Close this window.'
    'Browse'            = 'Pick a file or folder.'
    'Refresh'           = 'Read the data again and redraw this list.'
    'Copy to Clipboard' = 'Copy what is shown here to the clipboard as text.'
    'Export CSV'        = 'Save the rows shown in this list to a CSV file (opens in Excel).'
    'Export HTML'       = 'Save what is shown here as an HTML report and open it in the browser.'
    'Select All'        = 'Tick every item in the list.'
    'Select None'       = 'Untick every item in the list.'
    'Stop'              = 'Stop the operation that is running. Results so far are kept.'
    'Show command'      = 'Show the exact PowerShell this runs, with the values currently filled in. Nothing is run.'
    'Copy command'      = 'Copy the exact PowerShell this runs to the clipboard. Nothing is run.'
}

$script:CommandHint = 'Right-click: show or copy the exact command.'

# ---- state ------------------------------------------------------------------------

function Initialize-AppToolTipState {
    [CmdletBinding()]
    param($App)
    $st = $global:AppToolTipState
    if (-not $st) {
        $tt = New-Object System.Windows.Forms.ToolTip
        $tt.AutoPopDelay = 20000; $tt.InitialDelay = 600; $tt.ReshowDelay = 150; $tt.ShowAlways = $true
        $st = @{
            App = $App; Provider = $tt; Catalog = @{}; MainForm = $null; Timer = $null; Busy = $false
            Done = (New-Object System.Collections.Hashtable); Explicit = (New-Object System.Collections.Hashtable)
            Hooked = (New-Object System.Collections.Hashtable); Seen = (New-Object System.Collections.Hashtable)
            MenuCtx = (New-Object System.Collections.Hashtable); Masks = @{}
            Roots = (New-Object System.Collections.Generic.List[object])
            Missing = (New-Object System.Collections.Specialized.OrderedDictionary)
            MissingDirty = $false; LastMissingLog = [datetime]::MinValue; LoggedError = $false
            Developer = $false; EngineCount = 0; ProjectCount = 0; PurgeAt = 6000
        }
        $global:AppToolTipState = $st
    }
    if ($App) {
        $st.App = $App
        $st.Developer = ([string]$App.Tier -eq 'Developer')
    }
    return $st
}

# ---- keys ---------------------------------------------------------------------------

function ConvertTo-AppToolTipKey {
    [CmdletBinding()]
    param([AllowNull()] [string]$Text)
    if (-not $Text) { return '' }
    $t = $Text.Replace('&&', [string][char]1).Replace('&', '').Replace([string][char]1, '&')
    $t = $t.Replace([string][char]0x25BE, '').Replace([string][char]0x2026, '')
    $t = ($t -replace '\s+', ' ').Trim()
    $t = ($t -replace '\s*\.{2,}$', '').Trim()
    return $t.ToLowerInvariant()
}

function ConvertTo-AppToolTipPathKey {
    [CmdletBinding()]
    param([string]$Path)
    $parts = @(($Path -split '>') | ForEach-Object { ConvertTo-AppToolTipKey $_ } | Where-Object { $_ })
    return ($parts -join ' > ')
}

# Display form of a control text for the missing list (as typed in the catalog).
function Get-AppToolTipDisplayText {
    param([string]$Text)
    if (-not $Text) { return '' }
    $t = $Text.Replace('&&', [string][char]1).Replace('&', '').Replace([string][char]1, '&')
    $t = $t.Replace([string][char]0x25BE, '').Replace([string][char]0x2026, '')
    $t = ($t -replace '\s+', ' ').Trim()
    return ($t -replace '\s*\.{2,}$', '').Trim()
}

# ---- catalog ------------------------------------------------------------------------

function Get-AppToolTipCatalog {
    [CmdletBinding()]
    param($App, [switch]$Reload)
    $st = Initialize-AppToolTipState -App $App
    if (-not $Reload -and $st.Catalog.Count -gt 0) { return $st.Catalog }
    $cat = @{}
    foreach ($k in $script:EngineToolTips.Keys) { $cat[(ConvertTo-AppToolTipPathKey $k)] = [string]$script:EngineToolTips[$k] }
    $st.EngineCount = $cat.Count
    $proj = 0
    $a = $st.App
    if ($a) {
        $p = Join-Path (Join-Path ([string]$a.LocalAppData) 'Config') 'ToolTips.json'
        if (Test-Path -LiteralPath $p) {
            try {
                $j = [System.IO.File]::ReadAllText($p) | ConvertFrom-Json -ErrorAction Stop
                $src = $j
                if ($j.PSObject.Properties['ToolTips']) { $src = $j.ToolTips }
                foreach ($pr in $src.PSObject.Properties) {
                    if ($pr.Name -like '_*') { continue }
                    $key = ConvertTo-AppToolTipPathKey $pr.Name
                    if (-not $key) { continue }
                    $cat[$key] = [string]$pr.Value
                    $proj++
                }
            }
            catch { $a.Log('ERROR', 'ToolTips', "Config\ToolTips.json could not be read: $($_.Exception.Message)") }
        }
    }
    $st.ProjectCount = $proj
    $st.Catalog = $cat
    return $cat
}

# Bit masks over the context parts, most specific first: more parts first, then
# the ones that keep the inner parts (higher bits = inner).
function Get-AppToolTipMasks {
    param([int]$Count)
    $st = $global:AppToolTipState
    if ($st.Masks.ContainsKey($Count)) { return $st.Masks[$Count] }
    $all = @()
    for ($m = (1 -shl $Count) - 1; $m -ge 0; $m--) {
        $bits = 0; for ($i = 0; $i -lt $Count; $i++) { if ($m -band (1 -shl $i)) { $bits++ } }
        $all += [pscustomobject]@{ Mask = $m; Bits = $bits }
    }
    $sorted = @($all | Sort-Object -Property @{ Expression = 'Bits'; Descending = $true }, @{ Expression = 'Mask'; Descending = $true } | ForEach-Object { $_.Mask })
    $st.Masks[$Count] = $sorted
    return $sorted
}

# @{ Text = ... } for the most specific catalog entry, or $null.
function Find-AppToolTipText {
    [CmdletBinding()]
    param([string[]]$Context = @(), [string]$Text)
    $st = $global:AppToolTipState
    if (-not $st) { return $null }
    $key = ConvertTo-AppToolTipKey $Text
    if (-not $key) { return $null }
    $ctx = @($Context | ForEach-Object { ConvertTo-AppToolTipKey $_ } | Where-Object { $_ })
    if ($ctx.Count -gt 6) { $ctx = @($ctx[($ctx.Count - 6)..($ctx.Count - 1)]) }
    $cat = $st.Catalog
    foreach ($m in (Get-AppToolTipMasks -Count $ctx.Count)) {
        $parts = New-Object System.Collections.Generic.List[string]
        for ($i = 0; $i -lt $ctx.Count; $i++) { if ($m -band (1 -shl $i)) { [void]$parts.Add($ctx[$i]) } }
        [void]$parts.Add($key)
        $k = $parts -join ' > '
        if ($cat.ContainsKey($k)) { return @{ Text = [string]$cat[$k]; Key = $k } }
    }
    return $null
}

# ---- applying -------------------------------------------------------------------------

function Set-AppToolTipCore {
    param($Target, [string]$Text)
    $st = $global:AppToolTipState
    if ($Target -is [System.Windows.Forms.ToolStripItem]) {
        $Target.ToolTipText = $Text
        $Target.AutoToolTip = $false
        if ($Target.Owner) { $Target.Owner.ShowItemToolTips = $true }
    }
    elseif ($Target -is [System.Windows.Forms.TabPage]) {
        $Target.ToolTipText = $Text
        if ($Target.Parent -is [System.Windows.Forms.TabControl]) { $Target.Parent.ShowToolTips = $true }
    }
    elseif ($Target -is [System.Windows.Forms.Control]) {
        $st.Provider.SetToolTip($Target, $Text)
    }
}

function Set-AppToolTip {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Control, [AllowEmptyString()] [string]$Text = '')
    $st = Initialize-AppToolTipState
    $st.Explicit[$Control] = $true
    if ($global:AppCommandRegistry -and $global:AppCommandRegistry.ContainsKey($Control)) {
        if ($Text) { $Text = $Text + "`r`n" + $script:CommandHint } else { $Text = $script:CommandHint }
    }
    Set-AppToolTipCore -Target $Control -Text $Text
}

function Add-AppToolTipMissing {
    param([string[]]$Context, [string]$Text)
    $st = $global:AppToolTipState
    if (-not $st.Developer) { return }
    $parts = @($Context | Where-Object { $_ } | ForEach-Object { Get-AppToolTipDisplayText $_ })
    $parts += (Get-AppToolTipDisplayText $Text)
    $k = (@($parts | Where-Object { $_ }) -join ' > ')
    if ($k -and -not $st.Missing.Contains($k)) { $st.Missing.Add($k, $true); $st.MissingDirty = $true }
}

# Tooltip text for a control/item from the catalog (+ the command hint), or $null.
function Resolve-AppToolTip {
    param([string[]]$Context, [string]$Text, $Target)
    $hit = Find-AppToolTipText -Context $Context -Text $Text
    $tip = $null
    if ($hit) { $tip = [string]$hit.Text }
    if ($global:AppCommandRegistry -and $global:AppCommandRegistry.ContainsKey($Target)) {
        if ($tip) { $tip = $tip + "`r`n" + $script:CommandHint } else { $tip = $script:CommandHint }
    }
    if (-not $hit) { Add-AppToolTipMissing -Context $Context -Text $Text }
    return $tip
}

function Update-AppToolTipControl {
    param($Control, [string[]]$Context)
    $st = $global:AppToolTipState
    $isClick = ($Control -is [System.Windows.Forms.ButtonBase]) -or ($Control -is [System.Windows.Forms.LinkLabel])
    $isTab = ($Control -is [System.Windows.Forms.TabPage])
    if (-not ($isClick -or $isTab)) { return }
    if ($st.Explicit.ContainsKey($Control)) { return }
    $text = [string]$Control.Text
    if (-not $text.Trim()) { return }
    $reg = [bool]($global:AppCommandRegistry -and $global:AppCommandRegistry.ContainsKey($Control))
    $sig = $text + '|' + $reg
    if ($st.Done.ContainsKey($Control) -and [string]$st.Done[$Control] -eq $sig) { return }
    $st.Done[$Control] = $sig
    $tip = Resolve-AppToolTip -Context $Context -Text $text -Target $Control
    if ($null -ne $tip) { Set-AppToolTipCore -Target $Control -Text $tip }
}

function Update-AppToolTipItems {
    param($Items, [string[]]$Context)
    $st = $global:AppToolTipState
    if (-not $Items) { return }
    foreach ($it in @($Items)) {
        if (-not (($it -is [System.Windows.Forms.ToolStripButton]) -or ($it -is [System.Windows.Forms.ToolStripDropDownItem]))) { continue }
        $text = [string]$it.Text
        if ($text.Trim() -and -not $st.Explicit.ContainsKey($it)) {
            if (-not ($st.Done.ContainsKey($it) -and [string]$st.Done[$it] -eq $text)) {
                if (-not $st.Done.ContainsKey($it) -and $it.ToolTipText) {
                    $st.Explicit[$it] = $true                     # the module set its own tooltip
                    if ($it.Owner) { $it.Owner.ShowItemToolTips = $true }
                }
                else {
                    $st.Done[$it] = $text
                    $tip = Resolve-AppToolTip -Context $Context -Text $text -Target $it
                    if ($null -ne $tip) { Set-AppToolTipCore -Target $it -Text $tip }
                }
            }
        }
        if ($it -is [System.Windows.Forms.ToolStripDropDownItem] -and $it.DropDownItems.Count -gt 0) {
            Update-AppToolTipItems -Items $it.DropDownItems -Context (@($Context) + $text)
        }
    }
}

# Event handlers (module-scoped script blocks, shared by every hook).
$script:ControlAddedHandler = { param($s, $e) try { [void]$global:AppToolTipState.Roots.Add($e.Control) } catch { } }
$script:MenuChangedHandler  = { param($s, $e) try { [void]$global:AppToolTipState.Roots.Add($s) } catch { } }
$script:MenuOpeningHandler  = {
    param($s, $e)
    try {
        $st = $global:AppToolTipState
        Update-AppToolTipItems -Items $s.Items -Context @($st.MenuCtx[$s])
    } catch { }
}

function Register-AppToolTipMenu {
    param($Menu, [string[]]$Context)
    $st = $global:AppToolTipState
    if (-not $Menu) { return }
    if (-not $st.MenuCtx.ContainsKey($Menu)) {
        $st.MenuCtx[$Menu] = @($Context)
        $Menu.add_Opening($script:MenuOpeningHandler)
    }
    $Menu.ShowItemToolTips = $true
    Update-AppToolTipItems -Items $Menu.Items -Context @($st.MenuCtx[$Menu])
}

# A dialog's title as a context part: the text before the first " - " / " -- "
# ("Reset Password  -  jdoe" -> "Reset Password"), so catalog keys need not
# include the variable part.
function Get-AppToolTipFormTitle {
    param($Form)
    $t = ([string]$Form.Text).Trim()
    if (-not $t) { return '' }
    return (($t -split '\s+-+\s+')[0]).Trim()
}

# Where a control sits: tab page / group box titles outermost first, and the
# dialog title when it is not on the main window.
function Get-AppToolTipContext {
    param($Control)
    $st = $global:AppToolTipState
    $parts = New-Object System.Collections.Generic.List[string]
    $p = $Control.Parent
    while ($p) {
        if ($p -is [System.Windows.Forms.TabPage] -or $p -is [System.Windows.Forms.GroupBox]) {
            $t = ([string]$p.Text).Trim(); if ($t) { $parts.Insert(0, $t) }
        }
        if ($p -is [System.Windows.Forms.Form]) {
            $ft = Get-AppToolTipFormTitle -Form $p
            if ($p -ne $st.MainForm -and $ft) { $parts.Insert(0, $ft) }
            break
        }
        $p = $p.Parent
    }
    return , $parts.ToArray()
}

function Update-AppToolTipTree {
    param($Root)
    $st = $global:AppToolTipState
    if (-not $Root -or $Root.IsDisposed) { return }
    $stack = New-Object System.Collections.Stack
    $stack.Push(@($Root, (Get-AppToolTipContext -Control $Root)))
    while ($stack.Count -gt 0) {
        $entry = $stack.Pop()
        $c = $entry[0]; $ctx = @($entry[1])
        if (-not $c -or $c.IsDisposed) { continue }

        Update-AppToolTipControl -Control $c -Context $ctx

        $childCtx = $ctx
        if ($c -is [System.Windows.Forms.TabPage] -or $c -is [System.Windows.Forms.GroupBox]) {
            $t = ([string]$c.Text).Trim(); if ($t) { $childCtx = @($ctx) + $t }
        }
        elseif ($c -is [System.Windows.Forms.Form]) {
            $childCtx = @()
            $ft = Get-AppToolTipFormTitle -Form $c
            if ($c -ne $st.MainForm -and $ft) { $childCtx = @($ft) }
        }

        if (-not $st.Hooked.ContainsKey($c)) {
            $st.Hooked[$c] = $true
            try {
                if ($c -is [System.Windows.Forms.Panel] -or $c -is [System.Windows.Forms.ContainerControl] -or
                    $c -is [System.Windows.Forms.TabControl] -or $c -is [System.Windows.Forms.GroupBox]) {
                    $c.add_ControlAdded($script:ControlAddedHandler)
                }
                if ($c -is [System.Windows.Forms.TreeView] -or $c -is [System.Windows.Forms.ListView] -or
                    $c -is [System.Windows.Forms.DataGridView] -or $c -is [System.Windows.Forms.ListBox] -or
                    $c -is [System.Windows.Forms.Panel]) {
                    $c.add_ContextMenuStripChanged($script:MenuChangedHandler)
                }
            } catch { }
        }

        if ($c -is [System.Windows.Forms.ToolStrip]) { Update-AppToolTipItems -Items $c.Items -Context $childCtx }
        if ($c.ContextMenuStrip) { Register-AppToolTipMenu -Menu $c.ContextMenuStrip -Context $childCtx }

        foreach ($ch in $c.Controls) { $stack.Push(@($ch, $childCtx)) }
    }
}

function Save-AppToolTipMissing {
    $st = $global:AppToolTipState
    if (-not ($st.Developer -and $st.MissingDirty -and $st.App)) { return }
    $st.MissingDirty = $false
    try {
        $dir = Join-Path ([string]$st.App.DataRoot) 'Logs'
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $path = Join-Path $dir 'ToolTips_missing.txt'
        $lines = New-Object System.Collections.Generic.List[string]
        [void]$lines.Add('# Clickable controls with no tooltip yet (developer build, this session).')
        [void]$lines.Add('# Paste the lines you want into the "ToolTips" object of Config\ToolTips.json and fill')
        [void]$lines.Add('# in the text. Shorten a key to make it apply more widely ("Users > Refresh" ->')
        [void]$lines.Add('# "Refresh"); an empty text means "no tooltip, on purpose".')
        [void]$lines.Add('')
        foreach ($k in @($st.Missing.Keys | Sort-Object)) {
            [void]$lines.Add(('    "{0}": "",' -f ([string]$k).Replace('\', '\\').Replace('"', '\"')))
        }
        [System.IO.File]::WriteAllLines($path, $lines.ToArray(), (New-Object System.Text.UTF8Encoding($false)))
        if (([datetime]::Now - $st.LastMissingLog).TotalSeconds -ge 30) {
            $st.LastMissingLog = [datetime]::Now
            $st.App.Log('INFO', 'ToolTips', "$($st.Missing.Count) clickable control(s) have no tooltip yet - see Logs\ToolTips_missing.txt.")
        }
    }
    catch { }
}

function Remove-AppToolTipDisposed {
    $st = $global:AppToolTipState
    # open forms: every time (few entries); the big tables only once they grow
    foreach ($k in @($st.Seen.Keys)) { try { if ($k.IsDisposed) { $st.Seen.Remove($k) } } catch { } }
    $total = $st.Done.Count + $st.Hooked.Count
    if ($total -lt $st.PurgeAt) { return }
    foreach ($tbl in @($st.Done, $st.Explicit, $st.Hooked, $st.MenuCtx)) {
        foreach ($k in @($tbl.Keys)) {
            try { if ($k.IsDisposed) { $tbl.Remove($k) } } catch { }
        }
    }
    $st.PurgeAt = $st.Done.Count + $st.Hooked.Count + 4000
}

$script:TickHandler = {
    $st = $global:AppToolTipState
    if (-not $st -or $st.Busy) { return }
    $st.Busy = $true
    try {
        $roots = New-Object System.Collections.Generic.List[object]
        foreach ($f in [System.Windows.Forms.Application]::OpenForms) {
            if (-not $st.Seen.ContainsKey($f)) { $st.Seen[$f] = $true; [void]$roots.Add($f) }
        }
        if ($st.Roots.Count -gt 0) {
            foreach ($r in $st.Roots.ToArray()) { [void]$roots.Add($r) }
            $st.Roots.Clear()
        }
        if ($roots.Count -gt 0) {
            foreach ($r in $roots) { Update-AppToolTipTree -Root $r }
            Remove-AppToolTipDisposed
            Save-AppToolTipMissing
        }
    }
    catch {
        if (-not $st.LoggedError -and $st.App) { $st.LoggedError = $true; $st.App.Log('ERROR', 'ToolTips', "tooltip sweep failed: $($_.Exception.ToString())") }
    }
    finally { $st.Busy = $false }
}

# Called once by _AppLauncher.ps1 after the tabs are built.
function Start-AppToolTips {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $App, $Form = $null)
    $st = Initialize-AppToolTipState -App $App
    if ($Form) { $st.MainForm = $Form }
    [void](Get-AppToolTipCatalog -App $App -Reload)
    if (-not $st.Timer) {
        $t = New-Object System.Windows.Forms.Timer
        $t.Interval = 350
        $t.add_Tick($script:TickHandler)
        $t.Start()
        $st.Timer = $t
    }
    $App.Log('INFO', 'ToolTips', "Tooltips on: $($st.EngineCount) engine + $($st.ProjectCount) project entries (Config\ToolTips.json).")
}

function Update-AppToolTips {
    [CmdletBinding()]
    param($Root = $null)
    $st = $global:AppToolTipState
    if (-not $st) { return }
    if ($Root) { Update-AppToolTipTree -Root $Root }
    else { foreach ($f in [System.Windows.Forms.Application]::OpenForms) { Update-AppToolTipTree -Root $f } }
    Save-AppToolTipMissing
}

function Get-AppToolTipMissing {
    [CmdletBinding()]
    param()
    $st = $global:AppToolTipState
    if (-not $st) { return @() }
    return @($st.Missing.Keys)
}
