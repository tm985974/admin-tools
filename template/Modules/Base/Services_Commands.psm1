# Services_Commands.psm1   (BASE TIER)
#
# "Show me the exact command" for anything that runs a script.
#
# An action builds the PowerShell it is about to run as TEXT, with the real
# values filled in, and hands that text to the engine. The engine decides
# whether to show it first, shows it in one standard window (read-only code
# box, Copy, Run / Cancel), logs it, and - with Invoke-AppCommand - runs that
# same text, so what you saw is what ran.
#
#   Invoke-AppCommand  -App $App -Title 'RDP' -Kind Read -Code $code
#       Confirm (per the preview setting), then run $code. Returns
#       @{ Ran; Output; Errors }. Use it when the action IS a few cmdlet /
#       program calls (Start-Process ..., Unlock-ADAccount ..., shutdown.exe ...).
#
#   Confirm-AppCommand -App $App -Title 'Restart Now' -Kind Change -Code $code -Summary '...'
#       Just the confirm step, for actions whose code runs elsewhere (an engine
#       function with its own error handling). $true = go ahead.
#
#   Show-AppCommandDialog -App $App -Title ... -Code ... [-Summary] [-RunLabel] [-Change] [-ViewOnly]
#       The window itself. A module's own confirmation dialog can be replaced
#       by this one (it IS a confirmation: Run / Cancel) so there is never a
#       second popup.
#
#   Register-AppCommand -App $App -Control $button -Code { <returns the code text> }
#       Right-click on that button: "Show command..." / "Copy command", built
#       from the current values (nothing is run). The tooltip engine adds a
#       "Right-click: show or copy the command" line to the button's tooltip.
#
#   Format-AppCommandValue $value
#       A value as a PowerShell literal ('O''Brien', @('a','b'), $true, 42),
#       for building code text that runs exactly as shown.
#
# When is the window shown?  Environment > General > Commands (app-wide,
# Settings\Commands.json):
#   Always   - before every action that goes through the engine
#   Changes  - (default) before actions that change something (-Kind Change);
#              read-only / launch actions (-Kind Read) just run
#   Never    - never, unless Shift is held
# Shift+click on any button or menu item that goes through the engine shows it
# first, whatever the setting. Every confirmed command is logged to Session.log
# ([Command] <title>; the code itself as DIAG when diagnostics are on).

# ---- settings (Settings\Commands.json) --------------------------------------

function Get-AppCommandSettings {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $App)
    $s = [pscustomobject]@{ PreviewMode = 'Changes' }
    try {
        $p = Join-Path (Get-AppSettingsDir -App $App) 'Commands.json'
        if (Test-Path -LiteralPath $p) {
            $j = Get-Content -LiteralPath $p -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            $m = [string]$j.PreviewMode
            if (@('Always', 'Changes', 'Never') -contains $m) { $s.PreviewMode = $m }
        }
    } catch { if ($App) { $App.Log('WARN', 'Commands', "Commands.json: $($_.Exception.Message)") } }
    return $s
}

function Set-AppCommandSettings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $App,
        [ValidateSet('Always', 'Changes', 'Never')] [string]$PreviewMode = 'Changes'
    )
    $p = Join-Path (Get-AppSettingsDir -App $App) 'Commands.json'
    $o = [ordered]@{}
    try { if (Test-Path -LiteralPath $p) { $old = Get-Content -LiteralPath $p -Raw | ConvertFrom-Json; foreach ($pr in $old.PSObject.Properties) { $o[$pr.Name] = $pr.Value } } } catch { }
    $o['PreviewMode'] = $PreviewMode
    ([pscustomobject]$o | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $p -Encoding UTF8
    if (Get-Command Invoke-AppSettingsChanged -ErrorAction SilentlyContinue) { Invoke-AppSettingsChanged -App $App -Name 'Commands' }
}

# ---- building code text -------------------------------------------------------

function Format-AppCommandValue {
    [CmdletBinding()]
    param([Parameter(Position = 0)] [AllowNull()] $Value)
    if ($null -eq $Value) { return '$null' }
    if ($Value -is [bool]) { if ($Value) { return '$true' } else { return '$false' } }
    if ($Value -is [string] -or $Value -is [char]) { return "'" + ([string]$Value).Replace("'", "''") + "'" }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal] -or $Value -is [single] -or $Value -is [byte] -or $Value -is [int16]) {
        return ([System.IFormattable]$Value).ToString($null, [System.Globalization.CultureInfo]::InvariantCulture)
    }
    if ($Value -is [datetime]) { return "[datetime]'" + $Value.ToString('yyyy-MM-ddTHH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture) + "'" }
    if ($Value -is [System.Security.SecureString]) { return '(Read-Host -AsSecureString -Prompt ''Value'')' }
    if ($Value -is [System.Collections.IDictionary]) {
        $parts = @()
        foreach ($k in $Value.Keys) { $parts += ('{0} = {1}' -f (Format-AppCommandValue ([string]$k)), (Format-AppCommandValue $Value[$k])) }
        return '@{ ' + ($parts -join '; ') + ' }'
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $parts = @()
        foreach ($v in $Value) { $parts += (Format-AppCommandValue $v) }
        return '@(' + ($parts -join ', ') + ')'
    }
    return "'" + ([string]$Value).Replace("'", "''") + "'"
}

# ---- the window ------------------------------------------------------------------

function Show-AppCommandDialog {
    [CmdletBinding()]
    param(
        $App,
        [Parameter(Mandatory)] [string]$Title,
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$Code,
        [string]$Summary = '',
        [string]$RunLabel = 'Run',
        [switch]$Change,
        [switch]$ViewOnly
    )
    $fontName = 'Segoe UI'; $monoName = 'Consolas'; $size = [single]9
    $titleColor = [System.Drawing.Color]::FromArgb(31, 78, 140)
    $muted = [System.Drawing.Color]::FromArgb(108, 118, 130)
    $panel = [System.Drawing.Color]::FromArgb(236, 238, 242)
    if ($App -and $App.Theme) {
        $fontName = $App.Theme.FontName; $monoName = $App.Theme.MonoFontName; $size = [single]$App.Theme.FontSizePt
        $titleColor = $App.Theme.Title; $muted = $App.Theme.Muted; $panel = $App.Theme.Panel
    }
    $isChange = ($Change -and -not $ViewOnly)
    $band = $titleColor
    if ($isChange) { $band = [System.Drawing.Color]::FromArgb(150, 38, 28) }

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = $Title
    $dlg.StartPosition = 'CenterParent'
    $dlg.ClientSize = New-Object System.Drawing.Size(800, 470)
    $dlg.MinimumSize = New-Object System.Drawing.Size(540, 340)
    $dlg.MinimizeBox = $false
    $dlg.ShowInTaskbar = $false
    $dlg.Font = New-Object System.Drawing.Font($fontName, $size)

    # code box (Fill) - added first so the Top/Bottom bands dock around it
    $pCode = New-Object System.Windows.Forms.Panel
    $pCode.Dock = 'Fill'; $pCode.Padding = New-Object System.Windows.Forms.Padding(12, 0, 12, 0)
    $tb = New-Object System.Windows.Forms.TextBox
    $tb.Multiline = $true; $tb.ReadOnly = $true; $tb.WordWrap = $false; $tb.ScrollBars = 'Both'
    $tb.Dock = 'Fill'; $tb.Font = New-Object System.Drawing.Font($monoName, ($size + 0.5))
    $tb.BackColor = [System.Drawing.Color]::FromArgb(250, 250, 250)
    $tb.Text = ($Code -replace "`r?`n", "`r`n")
    $pCode.Controls.Add($tb)
    $dlg.Controls.Add($pCode)

    # buttons (Bottom)
    $pBtn = New-Object System.Windows.Forms.Panel
    $pBtn.Dock = 'Bottom'; $pBtn.Height = 54; $pBtn.BackColor = $panel
    $dlg.Controls.Add($pBtn)

    $btnCopy = New-Object System.Windows.Forms.Button
    $btnCopy.Text = 'Copy'; $btnCopy.Size = New-Object System.Drawing.Size(100, 30); $btnCopy.Location = New-Object System.Drawing.Point(12, 12)
    $pBtn.Controls.Add($btnCopy)
    $lCopied = New-Object System.Windows.Forms.Label
    $lCopied.AutoSize = $true; $lCopied.Location = New-Object System.Drawing.Point(122, 19); $lCopied.ForeColor = $muted
    $pBtn.Controls.Add($lCopied)

    $w = $dlg.ClientSize.Width
    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Size = New-Object System.Drawing.Size(100, 30)
    $btnCancel.Location = New-Object System.Drawing.Point(($w - 112), 12)
    $btnCancel.Anchor = 'Top, Right'
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $pBtn.Controls.Add($btnCancel)
    $dlg.CancelButton = $btnCancel

    $btnRun = $null
    if ($ViewOnly) {
        $btnCancel.Text = 'Close'
    }
    else {
        $btnCancel.Text = 'Cancel'
        $btnRun = New-Object System.Windows.Forms.Button
        $btnRun.Text = $RunLabel
        $btnRun.Size = New-Object System.Drawing.Size(120, 30)
        $btnRun.Location = New-Object System.Drawing.Point(($w - 240), 12)
        $btnRun.Anchor = 'Top, Right'
        $btnRun.Font = New-Object System.Drawing.Font($fontName, $size, [System.Drawing.FontStyle]::Bold)
        $btnRun.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $pBtn.Controls.Add($btnRun)
        # A change is never run by a stray Enter: only a click (or Alt+key) runs it.
        if (-not $isChange) { $dlg.AcceptButton = $btnRun }
    }

    # caption (Top)
    $lCap = New-Object System.Windows.Forms.Label
    $lCap.Dock = 'Top'; $lCap.Height = 24; $lCap.Padding = New-Object System.Windows.Forms.Padding(12, 6, 12, 0)
    $lCap.ForeColor = $muted
    if ($ViewOnly) { $lCap.Text = 'The PowerShell this action runs, with the current values (nothing is run from this window):' }
    else { $lCap.Text = 'This PowerShell will run:' }
    $dlg.Controls.Add($lCap)

    # summary (Top)
    if ($Summary) {
        $lSum = New-Object System.Windows.Forms.Label
        $lSum.Dock = 'Top'; $lSum.AutoSize = $false
        $lSum.Padding = New-Object System.Windows.Forms.Padding(12, 10, 12, 2)
        $lSum.Text = ($Summary -replace "`r?`n", "`r`n")
        $meas = [System.Windows.Forms.TextRenderer]::MeasureText($lSum.Text, $dlg.Font, (New-Object System.Drawing.Size(760, 0)), [System.Windows.Forms.TextFormatFlags]::WordBreak)
        $lSum.Height = [Math]::Min(200, [Math]::Max(30, $meas.Height + 16))
        $dlg.Controls.Add($lSum)
    }

    # title band (Top, outermost - added last)
    $pBand = New-Object System.Windows.Forms.Panel
    $pBand.Dock = 'Top'; $pBand.Height = 44; $pBand.BackColor = $band
    $lBand = New-Object System.Windows.Forms.Label
    $lBand.Dock = 'Fill'; $lBand.TextAlign = 'MiddleLeft'; $lBand.ForeColor = [System.Drawing.Color]::White
    $lBand.Font = New-Object System.Drawing.Font($fontName, ($size + 3), [System.Drawing.FontStyle]::Bold)
    if ($ViewOnly) { $lBand.Text = '   Command: ' + $Title } else { $lBand.Text = '   ' + $Title }
    $pBand.Controls.Add($lBand)
    $dlg.Controls.Add($pBand)

    # tooltips for this window's own buttons
    if (Get-Command Set-AppToolTip -ErrorAction SilentlyContinue) {
        Set-AppToolTip -Control $btnCopy -Text 'Copy the whole command to the clipboard (select part of it and press Ctrl+C to copy just that part).'
        if ($btnRun) { Set-AppToolTip -Control $btnRun -Text 'Run this command now.' }
        if ($ViewOnly) { Set-AppToolTip -Control $btnCancel -Text 'Close this window. Nothing is run.' }
        else { Set-AppToolTip -Control $btnCancel -Text 'Close this window without running anything.' }
    }

    $btnCopy.Add_Click({
        try {
            $t = $tb.SelectedText
            if (-not $t) { $t = $tb.Text }
            if ($t) { [System.Windows.Forms.Clipboard]::SetText($t); $lCopied.Text = 'Copied to the clipboard.' }
        } catch { $lCopied.Text = "Copy failed: $($_.Exception.Message)" }
    }.GetNewClosure())

    $dlg.Add_Shown({
        $tb.SelectionStart = 0; $tb.SelectionLength = 0
        if ($btnRun -and -not $isChange) { [void]$btnRun.Focus() } else { [void]$btnCancel.Focus() }
    }.GetNewClosure())

    $owner = [System.Windows.Forms.Form]::ActiveForm
    $r = [System.Windows.Forms.DialogResult]::Cancel
    try {
        if ($owner -and $owner -ne $dlg) { $r = $dlg.ShowDialog($owner) } else { $r = $dlg.ShowDialog() }
    }
    finally { $dlg.Dispose() }
    return (-not $ViewOnly -and $r -eq [System.Windows.Forms.DialogResult]::OK)
}

# ---- confirm / run ------------------------------------------------------------

function Test-AppCommandPreview {
    # $true when the window should be shown for an action of this kind now.
    [CmdletBinding()]
    param($App, [ValidateSet('Change', 'Read')] [string]$Kind = 'Change')
    $shift = (([System.Windows.Forms.Control]::ModifierKeys -band [System.Windows.Forms.Keys]::Shift) -eq [System.Windows.Forms.Keys]::Shift)
    if ($shift) { return $true }
    $mode = 'Changes'
    if ($App) { try { $mode = [string](Get-AppCommandSettings -App $App).PreviewMode } catch { } }
    if ($mode -eq 'Always') { return $true }
    if ($mode -eq 'Changes' -and $Kind -eq 'Change') { return $true }
    return $false
}

function Write-AppCommandLog {
    [CmdletBinding()]
    param($App, [string]$Title, [string]$Code, [string]$Result = 'Run')
    if (-not $App) { return }
    try {
        $App.Log('INFO', 'Command', "$Result : $Title")
        $one = (($Code -split "`r?`n") | ForEach-Object { $_.Trim() } | Where-Object { $_ }) -join ' ; '
        if ($one.Length -gt 2000) { $one = $one.Substring(0, 2000) + ' ...' }
        $App.Diag('Command', "$Title : $one")
    } catch { }
}

function Confirm-AppCommand {
    [CmdletBinding()]
    param(
        $App,
        [Parameter(Mandatory)] [string]$Title,
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$Code,
        [string]$Summary = '',
        [string]$RunLabel = 'Run',
        [ValidateSet('Change', 'Read')] [string]$Kind = 'Change',
        [switch]$Always
    )
    if ($Always -or (Test-AppCommandPreview -App $App -Kind $Kind)) {
        $ok = Show-AppCommandDialog -App $App -Title $Title -Code $Code -Summary $Summary -RunLabel $RunLabel -Change:($Kind -eq 'Change')
        if (-not $ok) { Write-AppCommandLog -App $App -Title $Title -Code $Code -Result 'Cancelled'; return $false }
    }
    Write-AppCommandLog -App $App -Title $Title -Code $Code
    return $true
}

function Invoke-AppCommand {
    [CmdletBinding()]
    param(
        $App,
        [Parameter(Mandatory)] [string]$Title,
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$Code,
        [string]$Summary = '',
        [string]$RunLabel = 'Run',
        [ValidateSet('Change', 'Read')] [string]$Kind = 'Change',
        [switch]$Always
    )
    $res = [pscustomobject]@{ Ran = $false; Output = @(); Errors = @() }
    if (-not $Code.Trim()) { return $res }
    if (-not (Confirm-AppCommand -App $App -Title $Title -Code $Code -Summary $Summary -RunLabel $RunLabel -Kind $Kind -Always:$Always)) { return $res }
    $res.Ran = $true
    $errs = New-Object System.Collections.Generic.List[string]
    $outs = New-Object System.Collections.Generic.List[object]
    try {
        $sb = [scriptblock]::Create($Code)
        foreach ($o in @(& $sb 2>&1)) {
            if ($o -is [System.Management.Automation.ErrorRecord]) { [void]$errs.Add($o.Exception.Message) } else { [void]$outs.Add($o) }
        }
    }
    catch { [void]$errs.Add($_.Exception.Message) }
    $res.Output = $outs.ToArray()
    $res.Errors = $errs.ToArray()
    if ($errs.Count -gt 0 -and $App) { $App.Log('WARN', 'Command', "$Title : $($errs -join ' | ')") }
    return $res
}

# ---- right-click "Show / Copy command" on a button -----------------------------

function Register-AppCommand {
    [CmdletBinding()]
    param(
        $App,
        [Parameter(Mandatory)] [System.Windows.Forms.Control]$Control,
        [Parameter(Mandatory)] [scriptblock]$Code,
        [string]$Title = ''
    )
    if (-not $Title) { $Title = ([string]$Control.Text).Replace('&', '').Trim() }
    if (-not $global:AppCommandRegistry) { $global:AppCommandRegistry = New-Object System.Collections.Hashtable }
    $global:AppCommandRegistry[$Control] = $true

    $menu = $Control.ContextMenuStrip
    if (-not $menu) {
        $menu = New-Object System.Windows.Forms.ContextMenuStrip
        $Control.ContextMenuStrip = $menu
    }
    elseif ($menu.Items.Count -gt 0) { [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) }
    $menu.ShowItemToolTips = $true

    $getText = {
        try { return [string](& $Code) }
        catch { return "# The command cannot be built yet: $($_.Exception.Message)" }
    }.GetNewClosure()
    $showFn = ${function:Show-AppCommandDialog}

    $miShow = New-Object System.Windows.Forms.ToolStripMenuItem
    $miShow.Text = 'Show command...'
    $miShow.ToolTipText = 'Show the exact PowerShell this button runs, with the values currently filled in. Nothing is run.'
    $miShow.Add_Click({ & $showFn -App $App -Title $Title -Code (& $getText) -ViewOnly }.GetNewClosure())
    [void]$menu.Items.Add($miShow)

    $miCopy = New-Object System.Windows.Forms.ToolStripMenuItem
    $miCopy.Text = 'Copy command'
    $miCopy.ToolTipText = 'Copy the exact PowerShell this button runs to the clipboard. Nothing is run.'
    $miCopy.Add_Click({
        $t = & $getText
        if ($t) {
            try { [System.Windows.Forms.Clipboard]::SetText($t); if ($App) { $App.SetStatus("Command copied: $Title", 'ok') } } catch { }
        }
    }.GetNewClosure())
    [void]$menu.Items.Add($miCopy)
}

function Test-AppCommandRegistered {
    [CmdletBinding()]
    param($Control)
    return [bool]($global:AppCommandRegistry -and $null -ne $Control -and $global:AppCommandRegistry.ContainsKey($Control))
}
