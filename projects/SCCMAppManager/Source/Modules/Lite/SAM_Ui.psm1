# SAM_Ui.psm1   (LITE TIER)
#
# Small UI helpers shared by the SCCM tabs and dialogs:
#   New-SamButton, Get-SamOwnerForm, Set-SamProgress,
#   Invoke-SamAction (busy guard + wait cursor + timing + error capture),
#   Invoke-SamSafe, Confirm-SamBatch, Show-SamListPicker, Show-SamGridDialog,
#   New-SamToolbar, Add-SamToolbarLabel.

$global:SamClrWarn = [System.Drawing.Color]::FromArgb(255, 243, 176)
$global:SamClrBad  = [System.Drawing.Color]::FromArgb(255, 210, 210)
$global:SamClrGood = [System.Drawing.Color]::FromArgb(214, 240, 214)
$global:SamClrInfo = [System.Drawing.Color]::FromArgb(214, 230, 250)

function New-SamButton {
    param([string]$Text, [int]$Width = 120, $Color = $null, [string]$Tip = '')
    $App = $global:SAM.App
    $b = $null
    try { $b = $App.Theme.MakeButton($Text) } catch { }
    if (-not $b) { $b = New-Object System.Windows.Forms.Button; $b.Text = $Text }
    $b.AutoSize = $false
    $b.Size = New-Object System.Drawing.Size($Width, 30)
    $b.Margin = New-Object System.Windows.Forms.Padding(3)
    if ($Color) { $b.BackColor = $Color; $b.UseVisualStyleBackColor = $false }
    if ($Tip) {
        # One tooltip provider for the whole app (template rule): the engine's, so the
        # "right-click: show command" hint and Config\ToolTips.json work here too.
        Set-AppToolTip -Control $b -Text $Tip
    }
    return $b
}

function New-SamToolbar {
    $p = New-Object System.Windows.Forms.FlowLayoutPanel
    $p.Dock = 'Top'; $p.AutoSize = $true; $p.WrapContents = $true
    $p.Padding = New-Object System.Windows.Forms.Padding(2)
    return $p
}

function Add-SamToolbarLabel {
    param($Toolbar, [string]$Text, [switch]$Bold)
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Text; $l.AutoSize = $true
    $l.Margin = New-Object System.Windows.Forms.Padding(8, 10, 0, 0)
    if ($Bold) { $l.Font = New-Object System.Drawing.Font($l.Font, [System.Drawing.FontStyle]::Bold) }
    $Toolbar.Controls.Add($l)
    return $l
}

function Get-SamOwnerForm {
    $f = $null
    try { $f = $global:SAM.Tabs.FindForm() } catch { }
    return $f
}

function Set-SamProgress {
    param([int]$Value, [int]$Max, [string]$Text = '')
    if ($Max -le 0) { return }
    $t = if ($Text) { "$Text  ($Value of $Max)" } else { "$Value of $Max" }
    try { $global:SAM.App.SetStatus($t, 'info') } catch { }
}

# Runs a user action: one at a time, buttons disabled, wait cursor, timed,
# errors logged instead of the .NET unhandled-exception dialog.
# -NeedSccm connects first (and stops with a message when that fails).
function Invoke-SamAction {
    param([string]$__UiName, [scriptblock]$__UiAction, [switch]$NeedSccm)
    $S = $global:SAM
    if ($S.Busy) {
        Write-SamLog 'Busy - wait for the current operation to finish.' -Level Warning
        try { $S.App.SetStatus('Busy - wait for the current operation to finish.', 'warn') } catch { }
        return
    }
    $S.Busy = $true
    foreach ($c in @($S.ActionControls.ToArray())) { if (-not $c.IsDisposed) { $c.Enabled = $false } }
    $form = Get-SamOwnerForm
    if ($form) { $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor }
    try { $S.App.SetStatus("$__UiName...", 'info') } catch { }
    Write-SamLog ('-' * 70)
    Write-SamLog "$__UiName - started  [$($S.Settings.EnvLabel) / $($S.Settings.SiteCode)]"
    $failed = $false
    try {
        if ($NeedSccm -and -not (Assert-SamConnected)) { throw 'Not connected to SCCM - check the SCCM Site page on the Environment tab.' }
        Measure-SamStep "TOTAL: $__UiName" $__UiAction | Out-Null
    }
    catch {
        $failed = $true
        Write-SamLog "$__UiName failed: $($_.Exception.Message)" -Level Error
        if ($_.ScriptStackTrace) { Write-SamLog $_.ScriptStackTrace -Level Error }
        try { $S.App.SetStatus("$__UiName failed: $($_.Exception.Message)", 'err') } catch { }
    }
    finally {
        foreach ($c in @($S.ActionControls.ToArray())) { if (-not $c.IsDisposed) { $c.Enabled = $true } }
        if ($form) { $form.Cursor = [System.Windows.Forms.Cursors]::Default }
        $S.Busy = $false
    }
    if (-not $failed) { try { $S.App.SetStatus("$__UiName - done.", 'ok') } catch { } }
}

# Small event handlers: log an error instead of showing the .NET dialog.
function Invoke-SamSafe {
    param([string]$__SafeName, [scriptblock]$__SafeBlock)
    try { & $__SafeBlock }
    catch {
        Write-SamLog "$__SafeName failed: $($_.Exception.Message)" -Level Error
        if ($_.InvocationInfo) { Write-SamLog "  at line $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())" -Level Error }
    }
}

# The confirmation for every batch action IS the command window (template rule:
# every action shows its code): the summary and list on top, the exact PowerShell
# below, Copy and Run / Cancel. -Code is the text from Get-SamCmCode (or any
# PowerShell). These always ask, whatever Environment > Commands says, as the
# Yes/No box before them did.
function Confirm-SamBatch {
    param([string]$Title, [string]$Intro, $Lines, [string]$Code = '', [ValidateSet('Change', 'Read')] [string]$Kind = 'Change')
    # Untyped on purpose: [string[]] parameters hit "Argument types do not match" in PS 5.1.
    $all = New-Object System.Collections.ArrayList
    foreach ($l in $Lines) { [void]$all.Add([string]$l) }
    $shown = @($all.ToArray() | Select-Object -First 30)
    $msg = ([string]$Intro).TrimEnd('?', ' ') + '.'
    if ($shown.Count) { $msg += "`r`n" + (($shown | ForEach-Object { "  - $_" }) -join "`r`n") }
    if ($all.Count -gt $shown.Count) { $msg += "`r`n  ... and $($all.Count - $shown.Count) more" }
    if (-not $Code) { $Code = '# (no command text was given for this action)' }
    return [bool](Confirm-AppCommand -App $global:SAM.App -Title $Title -Kind $Kind -Always -RunLabel 'Run' -Summary $msg -Code $Code)
}

# ConfigMgr console PowerShell for the command window: loads the module, goes to
# the site drive, then the given lines. -Note lines are added as comments.
function Get-SamCmCode {
    param($Lines, $Note = @())
    $site = [string]$global:SAM.Settings.SiteCode
    $out = New-Object System.Collections.Generic.List[string]
    $out.Add('# ConfigMgr console PowerShell, site ' + $site + '.')
    foreach ($n in @($Note)) { if ($n) { $out.Add('# ' + $n) } }
    $out.Add("Import-Module (Join-Path `$env:SMS_ADMIN_UI_PATH '..\ConfigurationManager.psd1')")
    $out.Add("Set-Location '" + $site + ":'")
    foreach ($l in @($Lines)) { if ($null -ne $l) { $out.Add([string]$l) } }
    return ($out -join "`r`n")
}

# A value as a PowerShell literal (Base\Services_Commands).
function Format-SamCode { param($Value) return (Format-AppCommandValue $Value) }

# Opens a folder or file through the command window (Kind Read: a launch).
function Open-SamPath {
    param([string]$Path, [string]$Exe = 'explorer.exe', [string]$Title = 'Open folder')
    $r = Invoke-AppCommand -App $global:SAM.App -Title $Title -Kind Read -RunLabel 'Open' -Summary "Open $Path" `
        -Code ('Start-Process -FilePath ' + (Format-AppCommandValue $Exe) + ' -ArgumentList ' + (Format-AppCommandValue ('"' + $Path + '"')))
    if ($r.Errors.Count) { Write-SamLog "$Title failed: $($r.Errors[0])" -Level Warning }
}

# Searchable picker. Items are objects; Columns = @(@{ Name; Header; Width }, ...).
# Returns the chosen item(s) as an array, or $null when cancelled.
function Show-SamListPicker {
    param(
        [string]$Title,
        [string]$Prompt = '',
        $Columns,
        $Items,
        [switch]$Multi,
        [string]$OkText = 'OK',
        [string]$PreselectProperty = '',
        [string]$PreselectValue = ''
    )
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = $Title
    $dlg.Size = New-Object System.Drawing.Size(900, 620)
    $dlg.StartPosition = 'CenterParent'
    $dlg.MinimizeBox = $false
    $dlg.ShowInTaskbar = $false

    $top = New-SamToolbar
    if ($Prompt) { [void](Add-SamToolbarLabel $top $Prompt -Bold) }
    [void](Add-SamToolbarLabel $top 'Filter:')
    $txt = New-Object System.Windows.Forms.TextBox
    $txt.Width = 280; $txt.Margin = New-Object System.Windows.Forms.Padding(3, 7, 3, 0)
    $top.Controls.Add($txt)
    $lblCount = Add-SamToolbarLabel $top ''

    $g = New-SamDataGrid -Columns $Columns -Multi:$Multi
    $g.Grid.Dock = 'Fill'
    Set-SamGridData -G $g -Items $Items
    Set-SamGridFilter -G $g -Text '' -CountLabel $lblCount

    $foot = New-Object System.Windows.Forms.FlowLayoutPanel
    $foot.Dock = 'Bottom'; $foot.Height = 44; $foot.FlowDirection = 'RightToLeft'
    $btnCancel = New-SamButton 'Cancel' 110
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $btnOk = New-SamButton $OkText 140 $global:SamClrGood
    $btnOk.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $foot.Controls.Add($btnCancel); $foot.Controls.Add($btnOk)
    $dlg.AcceptButton = $btnOk; $dlg.CancelButton = $btnCancel

    $dlg.Controls.Add($g.Grid); $dlg.Controls.Add($top); $dlg.Controls.Add($foot)

    $state = @{ G = $g; Txt = $txt; Lbl = $lblCount }
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 200
    $timer.Add_Tick({ $timer.Stop(); Set-SamGridFilter -G $state.G -Text $state.Txt.Text -CountLabel $state.Lbl }.GetNewClosure())
    $txt.Add_TextChanged({ $timer.Stop(); $timer.Start() }.GetNewClosure())
    $g.Grid.Add_CellDoubleClick({ param($s, $e) if ($e.RowIndex -ge 0) { $dlg.DialogResult = [System.Windows.Forms.DialogResult]::OK } }.GetNewClosure())

    if ($PreselectProperty -and $PreselectValue) {
        $dlg.Add_Shown({ Select-SamGridRowsBy -G $state.G -Property $PreselectProperty -Values @($PreselectValue) }.GetNewClosure())
    }
    else { $dlg.Add_Shown({ $state.G.Grid.ClearSelection(); $state.Txt.Focus() }.GetNewClosure()) }

    try {
        if ($dlg.ShowDialog((Get-SamOwnerForm)) -ne [System.Windows.Forms.DialogResult]::OK) { return $null }
        $sel = @(Get-SamGridSelected -G $g)
        if (-not $sel.Count) { return $null }
        return $sel
    }
    finally { $timer.Dispose(); $dlg.Dispose() }
}

# Read-only grid in a window (deployments, members, status lists).
# Buttons = @(@{ Text; Width; Color; Click = { param($G, $Dlg) } }, ...)
# Header  = text shown above the grid. Returns after the window closes.
function Show-SamGridDialog {
    param(
        [string]$Title,
        [string]$Header = '',
        $Columns,
        $Items,
        $Buttons = @(),
        $ColorRules = $null,
        [string]$GrayColumn = '',
        [switch]$Multi
    )
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = $Title
    $dlg.Size = New-Object System.Drawing.Size(1150, 680)
    $dlg.StartPosition = 'CenterParent'
    $dlg.MinimizeBox = $false
    $dlg.ShowInTaskbar = $false

    $top = New-SamToolbar
    if ($Header) { [void](Add-SamToolbarLabel $top $Header -Bold) }
    [void](Add-SamToolbarLabel $top 'Filter:')
    $txt = New-Object System.Windows.Forms.TextBox
    $txt.Width = 220; $txt.Margin = New-Object System.Windows.Forms.Padding(3, 7, 3, 0)
    $top.Controls.Add($txt)
    $lblCount = Add-SamToolbarLabel $top ''

    $g = New-SamDataGrid -Columns $Columns -Multi:$Multi -ColorRules $ColorRules -GrayColumn $GrayColumn
    $g.Grid.Dock = 'Fill'
    Set-SamGridData -G $g -Items $Items
    Set-SamGridFilter -G $g -Text '' -CountLabel $lblCount

    $foot = New-Object System.Windows.Forms.FlowLayoutPanel
    $foot.Dock = 'Bottom'; $foot.Height = 44
    $state = @{ G = $g; Txt = $txt; Lbl = $lblCount; Dlg = $dlg }
    foreach ($b in @($Buttons)) {
        if (-not $b) { continue }
        $btn = New-SamButton $b.Text $(if ($b.Width) { [int]$b.Width } else { 140 }) $b.Color
        $click = $b.Click
        $btn.Add_Click({ Invoke-SamSafe $btn.Text { & $click $state.G $state.Dlg } }.GetNewClosure())
        $foot.Controls.Add($btn)
    }
    $btnExport = New-SamButton 'Export CSV...' 110
    $btnExport.Add_Click({ Export-SamGridCsv -G $state.G -Name $dlg.Text }.GetNewClosure())
    $btnClose = New-SamButton 'Close' 100
    $btnClose.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $foot.Controls.Add($btnExport); $foot.Controls.Add($btnClose)
    $dlg.CancelButton = $btnClose

    $dlg.Controls.Add($g.Grid); $dlg.Controls.Add($top); $dlg.Controls.Add($foot)
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 200
    $timer.Add_Tick({ $timer.Stop(); Set-SamGridFilter -G $state.G -Text $state.Txt.Text -CountLabel $state.Lbl }.GetNewClosure())
    $txt.Add_TextChanged({ $timer.Stop(); $timer.Start() }.GetNewClosure())
    $dlg.Add_Shown({ $state.G.Grid.ClearSelection() }.GetNewClosure())
    try { [void]$dlg.ShowDialog((Get-SamOwnerForm)) }
    finally { $timer.Dispose(); $dlg.Dispose() }
}
