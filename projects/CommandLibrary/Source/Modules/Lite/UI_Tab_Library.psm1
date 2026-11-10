# UI_Tab_Library.psm1   (LITE TIER)
#
# The Library tab: search the saved commands, read what each one does and how
# to use it, and run it (Run... builds a prompt from the function's own
# parameters). Output streams into the panel below while the run continues in
# the background.
#
#   left  : search box (name + keywords), category filter, "Runnable here
#           only", the entry list with a Status column (will it work on THIS
#           computer: missing software, needs admin, which fallback it uses)
#   right : Details / Code for the selected entry, Run... / Copy buttons,
#           and the output panel (Results text, Grid, Messages)
#
# New / Edit / Delete appear only when the admin-tier editor module is loaded
# (admin password or developer build).

function New-LibraryTab {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Windows.Forms.TabPage]$Page,
        [Parameter(Mandatory)] $App
    )
    Set-LazyTabBuild -Page $Page -App $App -Build { param($Page, $App) Build-LibraryTab -Page $Page -App $App }
}

function New-LibraryMonoFont {
    param($App, [single]$Size = 9.5)
    $name = 'Consolas'
    try { if ($App.Theme.MonoFontName) { $name = [string]$App.Theme.MonoFontName } } catch { }
    return New-Object System.Drawing.Font($name, $Size)
}

function Build-LibraryTab {
    param([System.Windows.Forms.TabPage]$Page, $App)

    $st = @{
        App = $App; Page = $Page; Entries = @(); Shown = @(); Run = $null; LastOutCount = -1
        LastTextRefresh = [datetime]::MinValue; CanEdit = [bool](Get-Command Show-LibraryEntryEditor -ErrorAction SilentlyContinue)
        Ready = $null; Snapshot = $null
    }

    # ---------------- top bar ----------------
    $top = New-Object System.Windows.Forms.Panel
    $top.Dock = 'Top'; $top.Height = 44; $top.Padding = New-Object System.Windows.Forms.Padding(8, 8, 8, 4)

    $lblSearch = New-Object System.Windows.Forms.Label
    $lblSearch.Text = 'Search'; $lblSearch.AutoSize = $true; $lblSearch.Location = New-Object System.Drawing.Point(8, 13)
    $txtSearch = New-Object System.Windows.Forms.TextBox
    $txtSearch.Location = New-Object System.Drawing.Point(64, 9); $txtSearch.Width = 340
    $cboCat = New-Object System.Windows.Forms.ComboBox
    $cboCat.DropDownStyle = 'DropDownList'; $cboCat.Location = New-Object System.Drawing.Point(414, 9); $cboCat.Width = 220
    $chkCode = New-Object System.Windows.Forms.CheckBox
    $chkCode.Text = 'Search descriptions too'; $chkCode.AutoSize = $true; $chkCode.Location = New-Object System.Drawing.Point(646, 11)
    $chkReady = New-Object System.Windows.Forms.CheckBox
    $chkReady.Text = 'Runnable here only'; $chkReady.AutoSize = $true; $chkReady.Location = New-Object System.Drawing.Point(810, 11)
    $lblCount = New-Object System.Windows.Forms.Label
    $lblCount.AutoSize = $true; $lblCount.Location = New-Object System.Drawing.Point(960, 13); $lblCount.ForeColor = $App.Theme.Muted
    $tip = New-Object System.Windows.Forms.ToolTip
    $tip.SetToolTip($txtSearch, 'Matches the name and keywords by whole words ("ping" finds Ping, not "mapping"). Every word must match.')
    $tip.SetToolTip($chkCode, 'Also look in the description, how to use, notes and code.')
    $tip.SetToolTip($chkReady, 'Hide entries that cannot run on this computer (missing software or needs admin).')

    $btnReload = $App.Theme.MakeButton('Reload'); $btnReload.Anchor = 'Top,Right'
    $btnNew    = $App.Theme.MakeButton('New...');  $btnNew.Anchor = 'Top,Right'
    $btnEdit   = $App.Theme.MakeButton('Edit...'); $btnEdit.Anchor = 'Top,Right'
    $btnDelete = $App.Theme.MakeButton('Delete');  $btnDelete.Anchor = 'Top,Right'
    $top.Controls.AddRange(@($lblSearch, $txtSearch, $cboCat, $chkCode, $chkReady, $lblCount, $btnReload))
    if ($st.CanEdit) { $top.Controls.AddRange(@($btnNew, $btnEdit, $btnDelete)) }

    # ---------------- main split ----------------
    $split = New-Object System.Windows.Forms.SplitContainer
    $split.Dock = 'Fill'; $split.Orientation = 'Vertical'; $split.SplitterWidth = 6

    $list = New-Object System.Windows.Forms.ListView
    $list.Dock = 'Fill'; $list.View = 'Details'; $list.FullRowSelect = $true; $list.HideSelection = $false
    $list.MultiSelect = $false; $list.GridLines = $false; $list.BorderStyle = 'FixedSingle'
    [void]$list.Columns.Add('Name', 220)
    [void]$list.Columns.Add('Status', 150)
    [void]$list.Columns.Add('Category', 120)
    [void]$list.Columns.Add('Command', 140)
    [void]$list.Columns.Add('Notes', 90)
    $split.Panel1.Controls.Add($list)

    $right = New-Object System.Windows.Forms.SplitContainer
    $right.Dock = 'Fill'; $right.Orientation = 'Horizontal'; $right.SplitterWidth = 6
    $split.Panel2.Controls.Add($right)

    # details / code
    $tabs = New-Object System.Windows.Forms.TabControl
    $tabs.Dock = 'Fill'
    $pgDetails = New-Object System.Windows.Forms.TabPage 'Details'
    $pgCode = New-Object System.Windows.Forms.TabPage 'Code'
    $rtb = New-Object System.Windows.Forms.RichTextBox
    $rtb.Dock = 'Fill'; $rtb.ReadOnly = $true; $rtb.BorderStyle = 'None'; $rtb.BackColor = [System.Drawing.Color]::White
    $rtb.DetectUrls = $true; $rtb.Font = New-AppFont -App $App
    $pgDetails.Controls.Add($rtb); $pgDetails.Padding = New-Object System.Windows.Forms.Padding(8)
    $pgDetails.BackColor = [System.Drawing.Color]::White
    $txtCode = New-Object System.Windows.Forms.TextBox
    $txtCode.Dock = 'Fill'; $txtCode.Multiline = $true; $txtCode.ReadOnly = $true; $txtCode.ScrollBars = 'Both'
    $txtCode.WordWrap = $false; $txtCode.Font = New-LibraryMonoFont -App $App; $txtCode.BackColor = [System.Drawing.Color]::White
    $pgCode.Controls.Add($txtCode)
    $tabs.TabPages.AddRange(@($pgDetails, $pgCode))

    $actions = New-Object System.Windows.Forms.FlowLayoutPanel
    $actions.Dock = 'Bottom'; $actions.Height = 42; $actions.Padding = New-Object System.Windows.Forms.Padding(0, 6, 0, 0)
    $btnRun = $App.Theme.MakeButton('Run...')
    $btnCopyCode = $App.Theme.MakeButton('Copy code')
    $btnCopyCall = $App.Theme.MakeButton('Copy example call')
    $actions.Controls.AddRange(@($btnRun, $btnCopyCode, $btnCopyCall))
    $right.Panel1.Controls.Add($tabs)
    $right.Panel1.Controls.Add($actions)

    # output panel
    $outHead = New-Object System.Windows.Forms.Panel
    $outHead.Dock = 'Top'; $outHead.Height = 40
    $lblOut = New-Object System.Windows.Forms.Label
    $lblOut.AutoSize = $false; $lblOut.Location = New-Object System.Drawing.Point(2, 12); $lblOut.Width = 600; $lblOut.Height = 20
    $lblOut.Text = 'Output - nothing run yet.'; $lblOut.ForeColor = $App.Theme.Muted
    $lblOut.Anchor = 'Top,Left,Right'
    $btnStop = $App.Theme.MakeButton('Stop'); $btnStop.Anchor = 'Top,Right'; $btnStop.Enabled = $false
    $btnCopyOut = $App.Theme.MakeButton('Copy'); $btnCopyOut.Anchor = 'Top,Right'
    $btnExport = $App.Theme.MakeButton('Export CSV...'); $btnExport.Anchor = 'Top,Right'
    $btnClear = $App.Theme.MakeButton('Clear'); $btnClear.Anchor = 'Top,Right'
    $outHead.Controls.AddRange(@($lblOut, $btnStop, $btnCopyOut, $btnExport, $btnClear))

    $outTabs = New-Object System.Windows.Forms.TabControl
    $outTabs.Dock = 'Fill'
    $pgText = New-Object System.Windows.Forms.TabPage 'Results'
    $pgGrid = New-Object System.Windows.Forms.TabPage 'Grid'
    $pgMsg = New-Object System.Windows.Forms.TabPage 'Messages'
    $txtOut = New-Object System.Windows.Forms.TextBox
    $txtOut.Dock = 'Fill'; $txtOut.Multiline = $true; $txtOut.ReadOnly = $true; $txtOut.ScrollBars = 'Both'
    $txtOut.WordWrap = $false; $txtOut.Font = New-LibraryMonoFont -App $App; $txtOut.BackColor = [System.Drawing.Color]::White
    $txtOut.MaxLength = 0
    $pgText.Controls.Add($txtOut)
    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Dock = 'Fill'; $grid.ReadOnly = $true; $grid.AllowUserToAddRows = $false; $grid.AllowUserToDeleteRows = $false
    $grid.AutoSizeColumnsMode = 'DisplayedCells'; $grid.RowHeadersVisible = $false; $grid.BackgroundColor = [System.Drawing.Color]::White
    $grid.SelectionMode = 'FullRowSelect'; $grid.ClipboardCopyMode = 'EnableAlwaysIncludeHeaderText'
    $pgGrid.Controls.Add($grid)
    $txtMsg = New-Object System.Windows.Forms.TextBox
    $txtMsg.Dock = 'Fill'; $txtMsg.Multiline = $true; $txtMsg.ReadOnly = $true; $txtMsg.ScrollBars = 'Both'
    $txtMsg.WordWrap = $false; $txtMsg.Font = New-LibraryMonoFont -App $App; $txtMsg.BackColor = [System.Drawing.Color]::White
    $txtMsg.MaxLength = 0
    $pgMsg.Controls.Add($txtMsg)
    $outTabs.TabPages.AddRange(@($pgText, $pgGrid, $pgMsg))
    $right.Panel2.Controls.Add($outTabs)
    $right.Panel2.Controls.Add($outHead)

    # dock order: Fill first, then the Top band
    $Page.Controls.Add($split)
    $Page.Controls.Add($top)

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 250
    $search = New-Object System.Windows.Forms.Timer
    $search.Interval = 250
    $scanTimer = New-Object System.Windows.Forms.Timer
    $scanTimer.Interval = 400

    $st.Top = $top; $st.Search = $txtSearch; $st.Category = $cboCat; $st.SearchCode = $chkCode; $st.Count = $lblCount
    $st.ReadyOnly = $chkReady; $st.ScanTimer = $scanTimer; $st.Tip = $tip
    $st.List = $list; $st.Rtb = $rtb; $st.CodeBox = $txtCode; $st.Tabs = $tabs
    $st.BtnRun = $btnRun; $st.BtnCopyCode = $btnCopyCode; $st.BtnCopyCall = $btnCopyCall
    $st.BtnEdit = $btnEdit; $st.BtnDelete = $btnDelete; $st.BtnNew = $btnNew; $st.BtnReload = $btnReload
    $st.OutLabel = $lblOut; $st.BtnStop = $btnStop; $st.BtnCopyOut = $btnCopyOut; $st.BtnExport = $btnExport; $st.BtnClear = $btnClear
    $st.OutTabs = $outTabs; $st.PgGrid = $pgGrid; $st.OutText = $txtOut; $st.Grid = $grid; $st.Msg = $txtMsg
    $st.Timer = $timer; $st.SearchTimer = $search; $st.GridStale = $true

    Set-LibraryTopLayout -State $st
    $top.Add_Resize({ Set-LibraryTopLayout -State $st }.GetNewClosure())
    $outHead.Add_Resize({
        $w = $outHead.ClientSize.Width; $x = $w
        foreach ($b in @($btnClear, $btnExport, $btnCopyOut, $btnStop)) { $x -= ($b.Width + 6); $b.Location = New-Object System.Drawing.Point($x, 6) }
        $lblOut.Width = [Math]::Max(100, $x - 10)
    }.GetNewClosure())

    # splitter positions once the page has its real size (now, and again after
    # the first layout pass - a SplitContainer is 150px wide until docked)
    $setSplits = {
        try { $split.SplitterDistance = [int][Math]::Max(300, [Math]::Min(720, $split.ClientSize.Width * 0.36)) } catch { }
        try { $right.SplitterDistance = [int][Math]::Max(160, $right.ClientSize.Height * 0.52) } catch { }
        try { $split.Panel1MinSize = 280; $split.Panel2MinSize = 380 } catch { }
        try { $right.Panel1MinSize = 160; $right.Panel2MinSize = 140 } catch { }
        Set-LibraryTopLayout -State $st
        $w = $outHead.ClientSize.Width; $x = $w
        foreach ($b in @($btnClear, $btnExport, $btnCopyOut, $btnStop)) { $x -= ($b.Width + 6); $b.Location = New-Object System.Drawing.Point($x, 6) }
        $lblOut.Width = [Math]::Max(100, $x - 10)
    }.GetNewClosure()
    & $setSplits
    try { [void]$Page.BeginInvoke([System.Windows.Forms.MethodInvoker]$setSplits) } catch { }

    # ---------------- events ----------------
    $filterAsYouType = $true
    try { $filterAsYouType = [bool](Get-AppEnvironmentValue -App $App -Key 'FilterAsYouType' -Default $true) } catch { }
    if ($filterAsYouType) {
        $txtSearch.Add_TextChanged({ $search.Stop(); $search.Start() }.GetNewClosure())
    }
    $txtSearch.Add_KeyDown({
        param($s, $e)
        if ($e.KeyCode -eq 'Enter') { $e.SuppressKeyPress = $true; Update-LibraryList -State $st }
        elseif ($e.KeyCode -eq 'Down' -and $st.List.Items.Count -gt 0) { $e.SuppressKeyPress = $true; $st.List.Focus(); $st.List.Items[0].Selected = $true }
    }.GetNewClosure())
    $search.Add_Tick({ $search.Stop(); Update-LibraryList -State $st }.GetNewClosure())
    $cboCat.Add_SelectedIndexChanged({ Update-LibraryList -State $st }.GetNewClosure())
    $chkCode.Add_CheckedChanged({ Update-LibraryList -State $st }.GetNewClosure())
    $chkReady.Add_CheckedChanged({ Update-LibraryList -State $st }.GetNewClosure())
    $scanTimer.Add_Tick({ Receive-LibraryTabScan -State $st }.GetNewClosure())

    $list.Add_SelectedIndexChanged({ Show-LibraryEntryDetail -State $st }.GetNewClosure())
    $list.Add_DoubleClick({ Invoke-LibraryRunSelected -State $st }.GetNewClosure())
    $list.Add_KeyDown({ param($s, $e) if ($e.KeyCode -eq 'Enter') { $e.SuppressKeyPress = $true; Invoke-LibraryRunSelected -State $st } }.GetNewClosure())
    $list.Add_ColumnClick({
        param($s, $e)
        $st.SortColumn = $e.Column
        $st.SortDesc = ($st.LastSort -eq $e.Column) -and -not $st.SortDesc
        $st.LastSort = $e.Column
        Update-LibraryList -State $st -KeepSelection
    }.GetNewClosure())

    $btnRun.Add_Click({ Invoke-LibraryRunSelected -State $st }.GetNewClosure())
    $btnCopyCode.Add_Click({
        $e = Get-LibrarySelectedEntry -State $st
        if ($e -and (Test-LibraryCommandEntry $e) -and $e.Template) { [System.Windows.Forms.Clipboard]::SetText([string]$e.Template); $st.App.SetStatus("Copied the syntax template of '$($e.Name)'.", 'ok') }
        elseif ($e -and $e.Code) { [System.Windows.Forms.Clipboard]::SetText([string]$e.Code); $st.App.SetStatus("Copied the code of '$($e.Name)'.", 'ok') }
    }.GetNewClosure())
    $btnCopyCall.Add_Click({
        $e = Get-LibrarySelectedEntry -State $st
        if ($e) { [System.Windows.Forms.Clipboard]::SetText((Get-LibraryExampleCall -Entry $e)); $st.App.SetStatus('Copied an example call.', 'ok') }
    }.GetNewClosure())
    $btnReload.Add_Click({ Import-LibraryEntries -State $st }.GetNewClosure())

    $btnStop.Add_Click({ if ($st.Run) { Stop-LibraryRun -Run $st.Run; $st.OutLabel.Text = 'Stopping...' } }.GetNewClosure())
    $btnClear.Add_Click({
        if ($st.Run -and -not $st.Run.Disposed) { return }
        $st.Run = $null; $st.OutText.Text = ''; $st.Msg.Text = ''; $st.Grid.DataSource = $null
        $st.OutLabel.Text = 'Output - cleared.'; $st.OutLabel.ForeColor = $st.App.Theme.Muted
    }.GetNewClosure())
    $btnCopyOut.Add_Click({
        $t = if ($st.OutTabs.SelectedTab -eq $st.PgGrid -and $st.Grid.Rows.Count) {
            $st.Grid.SelectAll(); $o = $st.Grid.GetClipboardContent(); if ($o) { $o.GetText() } else { '' }
        } elseif ($st.OutTabs.SelectedIndex -eq 2) { $st.Msg.Text } else { $st.OutText.Text }
        if ($t) { [System.Windows.Forms.Clipboard]::SetText($t); $st.App.SetStatus('Output copied.', 'ok') }
    }.GetNewClosure())
    $btnExport.Add_Click({ Export-LibraryResults -State $st }.GetNewClosure())
    $outTabs.Add_SelectedIndexChanged({ if ($st.OutTabs.SelectedTab -eq $st.PgGrid) { Update-LibraryGrid -State $st } }.GetNewClosure())

    $timer.Add_Tick({ Update-LibraryRunOutput -State $st }.GetNewClosure())

    if ($st.CanEdit) {
        $newMenu = New-Object System.Windows.Forms.ContextMenuStrip
        $miCmd = $newMenu.Items.Add('Command (syntax template)...')
        $miFn = $newMenu.Items.Add('Function (paste PowerShell code)...')
        $miCmd.Add_Click({ Edit-LibraryEntryFromTab -State $st -New -Kind Command }.GetNewClosure())
        $miFn.Add_Click({ Edit-LibraryEntryFromTab -State $st -New -Kind Function }.GetNewClosure())
        $btnNew.Add_Click({ $newMenu.Show($btnNew, 0, $btnNew.Height) }.GetNewClosure())
        $btnEdit.Add_Click({ Edit-LibraryEntryFromTab -State $st }.GetNewClosure())
        $btnDelete.Add_Click({
            $e = Get-LibrarySelectedEntry -State $st
            if (-not $e) { return }
            $r = [System.Windows.Forms.MessageBox]::Show($st.Page.FindForm(), "Delete '$($e.Name)' from the library?`r`n`r`nShipped entries you delete stay deleted.", 'Delete entry', 'YesNo', 'Warning')   # not-a-command: library edit
            if ($r -ne 'Yes') { return }
            try { Remove-LibraryEntry -App $st.App -Id $e.Id; Import-LibraryEntries -State $st; $st.App.SetStatus("Deleted '$($e.Name)'.", 'ok') }
            catch { [System.Windows.Forms.MessageBox]::Show($st.Page.FindForm(), $_.Exception.Message, 'Delete failed', 'OK', 'Error') | Out-Null }
        }.GetNewClosure())
    }

    # reload when another tab (Import) or another environment changes the library
    if (Get-Command Register-AppSettingsChangedHandler -ErrorAction SilentlyContinue) {
        Register-AppSettingsChangedHandler -Handler { param($A, $Name) if ($Name -eq 'Library') { Import-LibraryEntries -State $st } }.GetNewClosure()
    }
    if (Get-Command Register-EnvironmentChangedHandler -ErrorAction SilentlyContinue) {
        Register-EnvironmentChangedHandler -Handler { param($A) Import-LibraryEntries -State $st }.GetNewClosure()
    }
    $Page.FindForm().Add_FormClosing({ if ($st.Run -and -not $st.Run.Disposed) { Stop-LibraryRun -Run $st.Run }; Stop-LibraryReadinessScan }.GetNewClosure())

    $global:LibraryTabState = $st     # lets the Import tab read the loaded entries
    Import-LibraryEntries -State $st
    Set-LibraryButtons -State $st
    $txtSearch.Focus() | Out-Null
}

function Set-LibraryTopLayout {
    param($State)
    $w = $State.Top.ClientSize.Width; $x = $w - 8
    $btns = @($State.BtnReload)
    if ($State.CanEdit) { $btns = @($State.BtnReload, $State.BtnDelete, $State.BtnEdit, $State.BtnNew) }
    foreach ($b in $btns) { $x -= $b.Width; $b.Location = New-Object System.Drawing.Point($x, 6); $x -= 6 }
    try { $State.Count.Location = New-Object System.Drawing.Point(($State.ReadyOnly.Right + 14), 13) } catch { }
}

function Import-LibraryEntries {
    param($State)
    try {
        $lib = Read-Library -App $State.App
        $State.Entries = @($lib.Entries)
        $State.LibraryPath = $lib.Path
    }
    catch {
        $State.Entries = @()
        [System.Windows.Forms.MessageBox]::Show($State.Page.FindForm(), $_.Exception.Message, 'Library', 'OK', 'Error') | Out-Null
    }
    $cur = [string]$State.Category.SelectedItem
    $State.Category.BeginUpdate()
    $State.Category.Items.Clear()
    [void]$State.Category.Items.Add('(all categories)')
    foreach ($c in @($State.Entries | ForEach-Object { $_.Category } | Where-Object { $_ } | Sort-Object -Unique)) { [void]$State.Category.Items.Add($c) }
    $State.Category.EndUpdate()
    $idx = $State.Category.Items.IndexOf($cur)
    $State.Category.SelectedIndex = [Math]::Max(0, $idx)      # fires Update-LibraryList
    Update-LibraryList -State $State -KeepSelection
    # will each entry work here? worked out in the background, then shown in Status
    try { Start-LibraryReadinessScan -Entries $State.Entries; $State.ScanTimer.Start() }
    catch { $State.App.Log('WARN', 'Library', "readiness scan not started: $($_.Exception.Message)") }
}

function Receive-LibraryTabScan {
    param($State)
    $r = Receive-LibraryReadinessScan
    if (-not $r) { return }
    $State.ScanTimer.Stop()
    $State.Ready = $r.Map; $State.Snapshot = $r.Snapshot
    if ($r.Error) { $State.App.Log('WARN', 'Library', "readiness scan: $($r.Error)") }
    $sn = $r.Snapshot
    $State.App.Log('INFO', 'Library', "Readiness: $(@($r.Map.Values | Where-Object { $_.Level -ne 'Blocked' }).Count) of $($r.Map.Count) entries can run here (admin=$($sn.IsAdmin), domain=$($sn.PartOfDomain), PS $($sn.PSVersion)).")
    Update-LibraryList -State $State -KeepSelection
}

# The readiness of one entry: from the scan, or worked out now (an entry saved since).
function Get-LibraryTabReadiness {
    param($State, $Entry, [switch]$Remote)
    if (-not $Entry) { return $null }
    if (-not $State.Snapshot) { return (Get-LibraryEntryReadiness -Entry $Entry -Snapshot $null) }
    if (-not $Remote -and $State.Ready -and $State.Ready.ContainsKey([string]$Entry.Id)) { return $State.Ready[[string]$Entry.Id] }
    try { return (Get-LibraryEntryReadiness -Entry $Entry -Snapshot $State.Snapshot -Remote:$Remote) } catch { return $null }
}

function Update-LibraryList {
    param($State, [switch]$KeepSelection)
    $keepId = $null
    if ($KeepSelection) { $sel = Get-LibrarySelectedEntry -State $State; if ($sel) { $keepId = $sel.Id } }
    $cat = ''
    if ($State.Category.SelectedIndex -gt 0) { $cat = [string]$State.Category.SelectedItem }
    $found = @(Find-LibraryEntries -Entries $State.Entries -Text $State.Search.Text -Category $cat -Deep:($State.SearchCode.Checked) -Ready $State.Ready -RunnableOnly:($State.ReadyOnly.Checked))
    if ($null -ne $State.SortColumn) {
        $rd = $State.Ready
        $key = switch ($State.SortColumn) { 0 { { $_.Name } } 1 { { if ($rd -and $rd.ContainsKey([string]$_.Id)) { $rd[[string]$_.Id].Summary } else { '' } }.GetNewClosure() } 2 { { $_.Category } } 3 { { $_.Function } } default { { Get-LibraryEntryFlags $_ } } }
        $found = @($found | Sort-Object -Property $key -Descending:([bool]$State.SortDesc))
    }
    $State.Shown = $found

    $lv = $State.List
    $lv.BeginUpdate()
    $lv.Items.Clear()
    $toSelect = $null
    $i = 0
    foreach ($e in $found) {
        $it = New-Object System.Windows.Forms.ListViewItem([string]$e.Name)
        $it.UseItemStyleForSubItems = $false
        $rdy = $null
        if ($State.Ready -and $State.Ready.ContainsKey([string]$e.Id)) { $rdy = $State.Ready[[string]$e.Id] }
        $stText = if ($rdy) { [string]$rdy.Summary } elseif ($State.Snapshot) { '' } else { 'Checking...' }
        $sub = $it.SubItems.Add($stText)
        $sub.ForeColor = switch ($(if ($rdy) { $rdy.Level } else { 'Unknown' })) {
            'Ready'   { if ($rdy.Fallback) { [System.Drawing.Color]::FromArgb(30, 110, 140) } else { [System.Drawing.Color]::FromArgb(20, 120, 40) } }
            'Warn'    { [System.Drawing.Color]::FromArgb(170, 110, 0) }
            'Blocked' { [System.Drawing.Color]::Firebrick }
            default   { $State.App.Theme.Muted }
        }
        [void]$it.SubItems.Add([string]$e.Category)
        [void]$it.SubItems.Add([string]$e.Function)
        [void]$it.SubItems.Add((Get-LibraryEntryFlags $e))
        $it.Tag = $e
        if ($e.Modifies) { $it.ForeColor = [System.Drawing.Color]::FromArgb(150, 60, 0) }
        if ($i % 2 -eq 1) { $it.BackColor = $State.App.Theme.AltRow; foreach ($si in $it.SubItems) { $si.BackColor = $State.App.Theme.AltRow } }
        [void]$lv.Items.Add($it)
        if ($keepId -and $e.Id -eq $keepId) { $toSelect = $it }
        $i++
    }
    $lv.EndUpdate()
    $State.Count.Text = "$($found.Count) of $(@($State.Entries).Count) entries$(if ($State.Ready) { "  -  $(@($State.Ready.Values | Where-Object { $_.Level -ne 'Blocked' }).Count) runnable here" } else { '  -  checking what runs here...' })"
    if ($toSelect) { $toSelect.Selected = $true; $toSelect.EnsureVisible() }
    elseif ($lv.Items.Count -gt 0) { $lv.Items[0].Selected = $true }
    elseif ($lv.Items.Count -eq 0) { Show-LibraryEntryDetail -State $State }
}

function Get-LibraryEntryFlags {
    param($Entry)
    $f = @()
    if (Test-LibraryCommandEntry $Entry) { $f += 'syntax' }
    if ($Entry.Modifies) { $f += 'changes' }
    if (@($Entry.Modules).Count) { $f += 'modules' }
    if ($Entry.Source -and $Entry.Source.Kind -eq 'Project') { $f += 'imported' }
    return ($f -join ', ')
}

function Get-LibrarySelectedEntry {
    param($State)
    if ($State.List.SelectedItems.Count -eq 0) { return $null }
    return $State.List.SelectedItems[0].Tag
}

function Get-LibraryExampleCall {
    param($Entry)
    if (Test-LibraryCommandEntry $Entry) {
        # the template filled with its defaults; required fields without one show as <Name>
        $ps = @(Get-LibraryEntryParameters -Entry $Entry)
        $vals = @{}
        foreach ($p in $ps) {
            $dv = Get-LibraryTemplateDefault -Param $p
            if ($null -ne $dv -and [string]$dv -ne '') { $vals[$p.Name] = $dv }
            elseif ($p.Mandatory -and $p.Kind -notin @('Switch', 'Credential', 'SecureString')) { $vals[$p.Name] = "<$($p.Name)>" }
            elseif ($p.Mandatory -and $p.Kind -eq 'Credential') { $vals[$p.Name] = 'x' }
        }
        $c = ConvertTo-LibraryTemplateText -Template $Entry.Template -Parameters $ps -Values $vals
        return ($c.Display -replace '"<(\w+)>"', '<$1>')
    }
    $help = Get-LibraryFunctionHelp -Code $Entry.Code -Function $Entry.Function
    if (@($help.Examples).Count) {
        $first = (@($help.Examples)[0] -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
        if ($first) { return ($first.Trim() -replace '^PS[^>]*>\s*', '') }
    }
    $parts = @($Entry.Function)
    foreach ($p in @(Get-LibraryParameterInfo -Code $Entry.Code -Function $Entry.Function)) {
        if ($p.Mandatory) { $parts += "-$($p.Name) <$($p.TypeName)>" }
    }
    return ($parts -join ' ')
}

function Add-LibraryRtf {
    param($Rtb, [string]$Text, [System.Drawing.Font]$Font, [System.Drawing.Color]$Color)
    $Rtb.SelectionStart = $Rtb.TextLength; $Rtb.SelectionLength = 0
    $Rtb.SelectionFont = $Font; $Rtb.SelectionColor = $Color
    $Rtb.AppendText($Text)
}

function Show-LibraryEntryDetail {
    param($State)
    $e = Get-LibrarySelectedEntry -State $State
    $App = $State.App
    $rtb = $State.Rtb
    Set-LibraryButtons -State $State
    $rtb.Clear()
    if (-not $e) { $State.CodeBox.Text = ''; return }

    $nl = [Environment]::NewLine
    $fName = $App.Theme.FontName; $fSize = [single]$App.Theme.FontSizePt
    $fTitle = New-Object System.Drawing.Font($fName, ($fSize + 4), [System.Drawing.FontStyle]::Bold)
    $fHead = New-Object System.Drawing.Font($fName, ($fSize + 0.5), [System.Drawing.FontStyle]::Bold)
    $fBody = New-Object System.Drawing.Font($fName, $fSize)
    $fMono = New-LibraryMonoFont -App $App -Size ($fSize)
    $cText = $App.Theme.Text; $cMuted = $App.Theme.Muted; $cHead = $App.Theme.Section
    $cWarn = [System.Drawing.Color]::FromArgb(170, 70, 0)

    Add-LibraryRtf $rtb ([string]$e.Name + $nl) $fTitle $App.Theme.Title
    $src = ''
    if ($e.Source -and $e.Source.Kind -eq 'Project') { $src = "from $($e.Source.Project)$(if ($e.Source.Version) { " v$($e.Source.Version)" }) - $($e.Source.File)" }
    elseif ($e.Source -and $e.Source.Kind -eq 'Chat') { $src = 'from a past chat' }
    $meta = @($e.Category, $e.Function, $src) | Where-Object { $_ }
    Add-LibraryRtf $rtb (($meta -join '   |   ') + $nl) $fBody $cMuted
    if (@($e.Tags).Count) { Add-LibraryRtf $rtb ('Tags: ' + (@($e.Tags) -join ', ') + $nl) $fBody $cMuted }
    if ($e.Modifies) { Add-LibraryRtf $rtb ($nl + 'CHANGES THINGS - review the command before running it.' + $nl) $fHead $cWarn }

    $isCommand = Test-LibraryCommandEntry $e
    $why = Test-LibraryEntryRunnable -Entry $e
    if ($why) { Add-LibraryRtf $rtb ($nl + $why + $nl) $fHead ([System.Drawing.Color]::Firebrick) }

    # will it work here - and if not, why and what to do
    $rd = Get-LibraryTabReadiness -State $State -Entry $e
    if ($rd) {
        $cOk = [System.Drawing.Color]::FromArgb(20, 120, 40); $cAmber = [System.Drawing.Color]::FromArgb(170, 110, 0); $cBad = [System.Drawing.Color]::Firebrick
        $col = switch ($rd.Level) { 'Ready' { $cOk } 'Warn' { $cAmber } 'Blocked' { $cBad } default { $cMuted } }
        $head = switch ($rd.Level) {
            'Ready'   { if ($rd.Fallback) { "Ready on this computer - via $($rd.MethodLabel)" } else { 'Ready on this computer' } }
            'Warn'    { "Probably runs here - $($rd.Summary)" }
            'Blocked' { "Will not run here - $($rd.Summary)" }
            default   { 'Checking what this computer has...' }
        }
        Add-LibraryRtf $rtb ($nl + $head + $nl) $fHead $col
        foreach ($l in @($rd.Lines)) {
            Add-LibraryRtf $rtb ("  $($l.Kind): $($l.Text)" + $nl) $fBody $cText
            if ($l.Fix) { Add-LibraryRtf $rtb ("      Fix: $($l.Fix)" + $nl) $fBody $cMuted }
        }
        if ($rd.Needs -and $rd.Needs.AdminMaybe -and -not ($State.Snapshot -and $State.Snapshot.IsAdmin)) {
            Add-LibraryRtf $rtb ("  Rights: may need Run as administrator for some uses ($($rd.Needs.AdminMaybe -replace '^Where to run: ', ''))" + $nl) $fBody $cMuted
        }
        $alts = @(Get-LibraryEntryMethods -Entry $e | Select-Object -Skip 1)
        if ($alts.Count -and -not $rd.Fallback) { Add-LibraryRtf $rtb ("  Fallback if this fails: $((@($alts | ForEach-Object { $_.Label })) -join ', ')" + $nl) $fBody $cMuted }
    }

    $sections = @(
        @('Description', $e.Description), @('How to use', $e.HowToUse), @('Where to run', $e.WhereToRun),
        @('Requirements', (@($e.Requirements, $(if (@($e.Modules).Count) { 'Modules: ' + (@($e.Modules) -join ', ') })) | Where-Object { $_ }) -join $nl)
    )
    foreach ($s in $sections) {
        if (-not ([string]$s[1]).Trim()) { continue }
        Add-LibraryRtf $rtb ($nl + $s[0] + $nl) $fHead $cHead
        Add-LibraryRtf $rtb (([string]$s[1]).Trim() + $nl) $fBody $cText
    }

    if ($isCommand) {
        Add-LibraryRtf $rtb ($nl + 'Syntax' + $nl) $fHead $cHead
        foreach ($l in (([string]$e.Template) -split "`r?`n")) { Add-LibraryRtf $rtb ('  ' + $l + $nl) $fMono $cText }
        Add-LibraryRtf $rtb ('  {Field} = a value you fill in;  [[ ... ]] = only included when its fields are filled in / ticked' + $nl) $fBody $cMuted
    }
    foreach ($m in @(Get-LibraryEntryMethods -Entry $e | Select-Object -Skip 1)) {
        Add-LibraryRtf $rtb ($nl + "Fallback: $($m.Label)" + $nl) $fHead $cHead
        foreach ($l in (([string]$m.Template) -split "`r?`n")) { Add-LibraryRtf $rtb ('  ' + $l + $nl) $fMono $cText }
    }
    $params = @(Get-LibraryEntryParameters -Entry $e)
    Add-LibraryRtf $rtb ($nl + $(if ($isCommand) { 'Fields' } else { 'Parameters' }) + $nl) $fHead $cHead
    if ($params.Count -eq 0) { Add-LibraryRtf $rtb ('(none)' + $nl) $fBody $cMuted }
    foreach ($p in $params) {
        Add-LibraryRtf $rtb ("  $(if ($isCommand) { $p.Name } else { '-' + $p.Name })") $fMono $cText
        $bits = @("[$($p.TypeName)]")
        if ($p.Mandatory) { $bits += 'required' }
        if ($p.DefaultText) { $bits += "default $($p.DefaultText)" }
        if (@($p.ValidateSet).Count) { $bits += 'one of: ' + (@($p.ValidateSet) -join ', ') }
        Add-LibraryRtf $rtb ('   ' + ($bits -join ', ')) $fBody $cMuted
        if ($p.HelpText) { Add-LibraryRtf $rtb (' - ' + $p.HelpText) $fBody $cText }
        Add-LibraryRtf $rtb $nl $fBody $cText
    }
    Add-LibraryRtf $rtb ($nl + 'Example' + $nl) $fHead $cHead
    Add-LibraryRtf $rtb ('  ' + (Get-LibraryExampleCall -Entry $e) + $nl) $fMono $cText
    if (([string]$e.Notes).Trim()) {
        Add-LibraryRtf $rtb ($nl + 'Notes' + $nl) $fHead $cHead
        Add-LibraryRtf $rtb (([string]$e.Notes).Trim() + $nl) $fBody $cText
    }
    $rtb.SelectionStart = 0; $rtb.ScrollToCaret()
    $codeText = if ($isCommand) { "# Syntax template`n" + [string]$e.Template + "`n`n# Fields`n" + [string]$e.Code } else { [string]$e.Code }
    foreach ($m in @(Get-LibraryEntryMethods -Entry $e | Select-Object -Skip 1)) { $codeText += "`n`n# Fallback: $($m.Label)`n" + [string]$m.Template }
    $State.CodeBox.Text = $codeText -replace "(?<!`r)`n", "`r`n"
}

function Set-LibraryButtons {
    param($State)
    $has = $null -ne (Get-LibrarySelectedEntry -State $State)
    $busy = $State.Run -and -not $State.Run.Disposed
    $State.BtnRun.Enabled = $has -and -not $busy
    $State.BtnCopyCode.Enabled = $has
    $State.BtnCopyCall.Enabled = $has
    $State.BtnEdit.Enabled = $has
    $State.BtnDelete.Enabled = $has
    $State.BtnStop.Enabled = [bool]$busy
    $State.BtnClear.Enabled = -not $busy
    $State.BtnExport.Enabled = (-not $busy) -and $State.Run -and (@($State.Run.Results).Count -gt 0)
}

function Edit-LibraryEntryFromTab {
    param($State, [switch]$New, [string]$Kind = 'Function')
    if (-not (Get-Command Show-LibraryEntryEditor -ErrorAction SilentlyContinue)) { return }
    $entry = if ($New) { New-LibraryEntry } else { Get-LibrarySelectedEntry -State $State }
    if (-not $entry) { return }
    if ($New) {
        $entry.Kind = $(if ($Kind -eq 'Command') { 'Command' } else { 'Function' })
        $cat = if ($State.Category.SelectedIndex -gt 0) { [string]$State.Category.SelectedItem } else { 'General' }
        $entry.Category = $cat
    }
    $cats = @($State.Entries | ForEach-Object { $_.Category } | Where-Object { $_ } | Sort-Object -Unique)
    $res = Show-LibraryEntryEditor -App $State.App -Entry $entry -Categories $cats -Owner $State.Page.FindForm()
    if (-not $res) { return }
    try {
        $saved = Save-LibraryEntry -App $State.App -Entry $res
        Import-LibraryEntries -State $State
        foreach ($it in $State.List.Items) { if ($it.Tag.Id -eq $saved.Id) { $it.Selected = $true; $it.EnsureVisible(); break } }
        $State.App.SetStatus("Saved '$($saved.Name)'.", 'ok')
    }
    catch { [System.Windows.Forms.MessageBox]::Show($State.Page.FindForm(), $_.Exception.Message, 'Save failed', 'OK', 'Error') | Out-Null }
}

# ---------------------------------------------------------------- running ---

function Invoke-LibraryRunSelected {
    param($State)
    $App = $State.App
    $e = Get-LibrarySelectedEntry -State $State
    if (-not $e) { return }
    if ($State.Run -and -not $State.Run.Disposed) {
        [System.Windows.Forms.MessageBox]::Show($State.Page.FindForm(), 'A run is still in progress. Stop it or wait for it to finish.', 'Run', 'OK', 'Information') | Out-Null
        return
    }
    $why = Test-LibraryEntryRunnable -Entry $e
    if ($why) {
        [System.Windows.Forms.MessageBox]::Show($State.Page.FindForm(), "This entry cannot run: $why", 'Run', 'OK', 'Warning') | Out-Null
        return
    }

    $rd = Get-LibraryTabReadiness -State $State -Entry $e
    $req = Show-LibraryRunDialog -App $App -Entry $e -Owner $State.Page.FindForm() -Readiness $rd
    if (-not $req) { return }

    try {
        $State.Run = Start-LibraryRun -Entry $e -CallText $req.CallText -Variables $req.Variables -ComputerName $req.Targets -RemoteCredential $req.RemoteCredential `
            -Plan @($req.Plan) -Hosts @($req.Hosts) -PreCheck:([bool]$req.PreCheck) -Fallback:([bool]$req.Fallback) -Force:([bool]$req.Force)
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show($State.Page.FindForm(), "Could not start the run: $($_.Exception.Message)", 'Run', 'OK', 'Error') | Out-Null
        return
    }
    $where = if (@($req.Targets).Count) { " on $(@($req.Targets).Count) computer(s): $((@($req.Targets) | Select-Object -First 5) -join ', ')$(if (@($req.Targets).Count -gt 5) { ' ...' })" } else { ' on this computer' }
    $App.LogAction("Run '$($e.Name)': $($req.CallText)$where")
    $App.Log('INFO', 'Library', "Run started: $($e.Function)$where")

    $State.OutText.Text = ''; $State.Grid.DataSource = $null; $State.GridStale = $true; $State.FirstError = ''
    $State.LastOutCount = -1; $State.LastTextRefresh = [datetime]::MinValue
    $State.Msg.Text = "> $($req.CallText)$where`r`n"
    $State.OutLabel.ForeColor = $App.Theme.Text
    $State.OutLabel.Text = "Running $($e.Function)$where ..."
    $State.OutTabs.SelectedIndex = 0
    Set-LibraryButtons -State $State
    $App.SetStatus("Running $($e.Function) ...", 'info')
    $State.Timer.Start()
}

function Update-LibraryRunOutput {
    param($State)
    $run = $State.Run
    if (-not $run) { $State.Timer.Stop(); return }
    $done = $run.IsDone
    try {
        $recs = @(Receive-LibraryRun -Run $run)
        $sb = New-Object System.Text.StringBuilder
        $errs = 0
        foreach ($r in $recs) {
            switch ($r.Kind) {
                'Error'   { $errs++; if (-not $State.FirstError) { $State.FirstError = [string]$r.Text }; [void]$sb.Append("[ERROR]   $($r.Text)`r`n") }
                'Warning' { [void]$sb.Append("[WARNING] $($r.Text)`r`n") }
                'Verbose' { [void]$sb.Append("[VERBOSE] $($r.Text)`r`n") }
                'Info'    { [void]$sb.Append("$($r.Text)`r`n") }
                'Host'    { [void]$sb.Append("$($r.Text)`r`n") }
            }
        }
        if ($sb.Length) { $State.Msg.AppendText($sb.ToString()) }
        if ($errs -gt 0) { $State.ErrorCount = [int]$State.ErrorCount + $errs }
    }
    catch { $State.App.Log('WARN', 'Library', "output read: $($_.Exception.Message)") }

    $count = @($run.Output).Count
    $now = Get-Date
    if ($count -ne $State.LastOutCount -and (($now - $State.LastTextRefresh).TotalMilliseconds -gt 1000 -or $done)) {
        $State.OutText.Text = (Format-LibraryResults -Results @($run.Output) -Format $run.Format) -replace "(?<!`r)`n", "`r`n"
        $State.LastOutCount = $count; $State.LastTextRefresh = $now; $State.GridStale = $true
    }
    if (-not $done) {
        $State.OutLabel.Text = "Running $($run.Entry.Function) ... $([int]$run.Elapsed.TotalSeconds)s, $count result(s)$(if ($State.ErrorCount) { ", $($State.ErrorCount) error(s)" })"
        return
    }

    # finished
    $State.Timer.Stop()
    $fatal = Complete-LibraryRun -Run $run
    $results = @($run.Results)
    $State.OutText.Text = (Format-LibraryResults -Results $results -Format $run.Format) -replace "(?<!`r)`n", "`r`n"
    $State.GridStale = $true
    $secs = [Math]::Round($run.Elapsed.TotalSeconds, 1)
    $errCount = [int]$State.ErrorCount
    $State.ErrorCount = 0
    # why it failed, in plain words (rights / connectivity / software / input)
    $whyText = ''
    $src = if ($fatal -and $fatal -ne 'Stopped.') { $fatal } else { [string]$State.FirstError }
    if ($src) {
        $fr = Get-LibraryFailureReason -Text $src
        if ($fr.Kind) { $whyText = "$($fr.Kind): $($fr.Hint)" }
    }
    if ($fatal) {
        $State.Msg.AppendText("[FAILED]  $fatal`r`n")
        if ($whyText) { $State.Msg.AppendText("[WHY]     $whyText`r`n") }
        $State.OutLabel.Text = "$($run.Entry.Function) failed after ${secs}s: $(if ($whyText) { $whyText } else { $fatal })"
        $State.OutLabel.ForeColor = [System.Drawing.Color]::Firebrick
        $State.App.SetStatus("$($run.Entry.Function) failed - see Messages.", 'err')
        $State.App.Log('WARN', 'Library', "Run failed: $($run.Entry.Function): $fatal")
        if ($results.Count -eq 0) { $State.OutTabs.SelectedIndex = 2 }
    }
    else {
        $State.OutLabel.Text = "$($run.Entry.Function) finished in ${secs}s - $($results.Count) result(s)$(if ($errCount) { ", $errCount error(s) (see Messages)" })"
        $State.OutLabel.ForeColor = $(if ($errCount) { [System.Drawing.Color]::FromArgb(170, 70, 0) } else { [System.Drawing.Color]::FromArgb(20, 110, 40) })
        $State.App.SetStatus("$($run.Entry.Function) finished: $($results.Count) result(s).", $(if ($errCount) { 'warn' } else { 'ok' }))
        if ($results.Count -eq 0 -and $State.Msg.Lines.Count -gt 1) { $State.OutTabs.SelectedIndex = 2 }
        if ($errCount -and $whyText) { $State.Msg.AppendText("[WHY]     $whyText`r`n") }
        $State.Msg.AppendText("[DONE]    ${secs}s, $($results.Count) result(s)`r`n")
    }
    if ($State.OutTabs.SelectedTab -eq $State.PgGrid) { Update-LibraryGrid -State $State }
    Set-LibraryButtons -State $State
}

function Update-LibraryGrid {
    param($State)
    if (-not $State.GridStale) { return }
    $res = @()
    if ($State.Run) { $res = @($State.Run.Results) }
    try {
        $dt = ConvertTo-LibraryDataTable -Results $res
        $State.Grid.DataSource = $dt
        $State.GridStale = $false
    }
    catch { $State.App.Log('WARN', 'Library', "grid: $($_.Exception.Message)") }
}

function Export-LibraryResults {
    param($State)
    if (-not $State.Run) { return }
    $res = @($State.Run.Results)
    if ($res.Count -eq 0) { return }
    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Filter = 'CSV files (*.csv)|*.csv'
    $dlg.FileName = "$($State.Run.Entry.Function)-$(Get-Date -Format yyyyMMdd-HHmm).csv"
    if ($dlg.ShowDialog($State.Page.FindForm()) -ne 'OK') { return }
    try {
        $dt = ConvertTo-LibraryDataTable -Results $res
        $rows = foreach ($r in $dt.Rows) {
            $o = [ordered]@{}
            foreach ($c in $dt.Columns) { $o[$c.ColumnName] = $r[$c.ColumnName] }
            [pscustomobject]$o
        }
        $rows | Export-Csv -LiteralPath $dlg.FileName -NoTypeInformation -Encoding UTF8
        $State.App.SetStatus("Exported $($res.Count) row(s) to $($dlg.FileName)", 'ok')
    }
    catch { [System.Windows.Forms.MessageBox]::Show($State.Page.FindForm(), $_.Exception.Message, 'Export failed', 'OK', 'Error') | Out-Null }
}
