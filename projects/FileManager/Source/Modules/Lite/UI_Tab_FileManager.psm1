# UI_Tab_FileManager.psm1   (LITE TIER)
#
# The one page: pick a drive, Scan (every file is read into the hash database),
# then a list of the folders at the top of the drive:
#   Duplicate          - the same content is kept elsewhere            -> _Duplicates
#   Older copy found   - older than the copy in _Clean (a swap)        -> this one to _Clean, that one to _Duplicates
#   Keep (has copies)  - this is the copy that is kept                 -> _Clean
#   Partly             - some folders inside have copies (double-click to look inside)
#   Unique             - no copy anywhere in the catalog               -> _Clean
# Sorted by reward (the space you get back), any column sorts. Tick rows, Move selected.
# Rarely changed settings are on the Environment tab (File Manager page).

function New-FmMainTab {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Windows.Forms.TabPage]$Page,
        [Parameter(Mandatory)] $App
    )
    Set-LazyTabBuild -Page $Page -App $App -Build ${function:Build-FmMainTab}
}

# A tab's build function shown in its own window (Drives, History, Consolidate under More).
function Show-FmPageWindow {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $App, [Parameter(Mandatory)] [string]$Title, [Parameter(Mandatory)] [scriptblock]$Build)
    $f = New-Object System.Windows.Forms.Form
    $f.Text = $Title
    $f.StartPosition = 'CenterParent'
    $f.FormBorderStyle = 'FixedDialog'; $f.MaximizeBox = $false; $f.MinimizeBox = $false
    $f.ClientSize = New-Object System.Drawing.Size(1560, 860)
    $f.Font = New-AppFont -App $App
    $f.BackColor = $App.Theme.Surface
    $page = New-EmbeddedTabPage -Parent $f -Width 1560 -Height 860 -Title $Title
    $page.BackColor = $App.Theme.Surface
    try { & $Build $page $App }
    catch {
        $App.Log('ERROR', 'FileManager', "$Title failed to open: $($_.Exception.Message)")
        [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, $Title, 'OK', 'Error')
        $f.Dispose(); return
    }
    [void]$f.ShowDialog()
    $f.Dispose()
}

function Build-FmMainTab {
    param($Page, $App)
    $Page.Padding = New-Object System.Windows.Forms.Padding(14)
    $cat = Get-FmCatalog -App $App

    # ---- 1. drive, scan, progress, More ----
    $bar1 = New-FmBar -Height 42
    $lblDrive = New-Object System.Windows.Forms.Label
    $lblDrive.Text = 'Drive:'; $lblDrive.AutoSize = $true; $lblDrive.Margin = New-Object System.Windows.Forms.Padding(0, 9, 6, 0)
    $cbo = New-Object System.Windows.Forms.ComboBox
    $cbo.DropDownStyle = 'DropDownList'; $cbo.Width = 560; $cbo.Margin = New-Object System.Windows.Forms.Padding(0, 5, 8, 0)
    $btnLoad = $App.Theme.MakeButton('Load drives')
    $btnScan = $App.Theme.MakeButton('Scan')
    $btnStop = $App.Theme.MakeButton('Stop')
    $btnStop.Enabled = $false
    $btnMore = $App.Theme.MakeButton('More')
    $btnMore.Margin = New-Object System.Windows.Forms.Padding(30, 3, 3, 3)
    $bar1.Controls.AddRange(@($lblDrive, $cbo, $btnLoad, $btnScan, $btnStop, $btnMore))

    $prog = New-FmProgress -App $App -LogHeight 90
    $prog.Panel.Height = 70
    $prog.Log.Dock = 'Bottom'

    $sum = New-FmLabel -App $App -Height 24
    $sum.Font = New-AppFont -App $App -Style ([System.Drawing.FontStyle]::Bold)

    # ---- 2. the list ----
    $bar2 = New-FmBar -Height 38
    $btnUp = $App.Theme.MakeButton('Up one level')
    $lblWhere = New-Object System.Windows.Forms.Label
    $lblWhere.AutoSize = $true; $lblWhere.Margin = New-Object System.Windows.Forms.Padding(4, 9, 16, 0); $lblWhere.ForeColor = $App.Theme.Title
    $lblShow = New-Object System.Windows.Forms.Label
    $lblShow.Text = 'Show:'; $lblShow.AutoSize = $true; $lblShow.Margin = New-Object System.Windows.Forms.Padding(0, 9, 4, 0)
    $cboShow = New-Object System.Windows.Forms.ComboBox
    $cboShow.DropDownStyle = 'DropDownList'; $cboShow.Width = 170; $cboShow.Margin = New-Object System.Windows.Forms.Padding(0, 5, 12, 0)
    [void]$cboShow.Items.AddRange([object[]]@('All', 'Duplicate', 'Older copy found', 'Keep (has copies)', 'Partly', 'Unique', 'Loose files'))
    $cboShow.SelectedIndex = 0
    $lblFilter = New-Object System.Windows.Forms.Label
    $lblFilter.Text = 'Filter:'; $lblFilter.AutoSize = $true; $lblFilter.Margin = New-Object System.Windows.Forms.Padding(0, 9, 4, 0)
    $txtFilter = New-Object System.Windows.Forms.TextBox
    $txtFilter.Width = 200; $txtFilter.Margin = New-Object System.Windows.Forms.Padding(0, 6, 12, 0)
    $chkParts = New-Object System.Windows.Forms.CheckBox
    $chkParts.Text = 'Show the parts of Partly folders'
    $chkParts.AutoSize = $true; $chkParts.Checked = $true; $chkParts.Margin = New-Object System.Windows.Forms.Padding(0, 8, 12, 0)
    $btnAll = $App.Theme.MakeButton('Select all')
    $btnNone = $App.Theme.MakeButton('Select none')
    $btnOpen = $App.Theme.MakeButton('Open folder')
    $lblSel = New-Object System.Windows.Forms.Label
    $lblSel.AutoSize = $true; $lblSel.Margin = New-Object System.Windows.Forms.Padding(12, 9, 0, 0)
    $bar2.Controls.AddRange(@($btnUp, $lblWhere, $lblShow, $cboShow, $lblFilter, $txtFilter, $chkParts, $btnAll, $btnNone, $btnOpen, $lblSel))

    $grid = New-FmGrid -App $App -Columns @('Status', 'Folder', 'Size', 'Files', 'Folders', 'Copies', 'Reward', 'Oldest file', 'Note') -Weights @(110, 330, 70, 70, 60, 50, 70, 75, 420) -Multi
    $grid.ReadOnly = $false
    $names = @('cStatus', 'cFolder', 'cSize', 'cFiles', 'cFolders', 'cCopies', 'cReward', 'cOldest', 'cNote')
    for ($i = 0; $i -lt $names.Count; $i++) { $grid.Columns[$i].Name = $names[$i]; $grid.Columns[$i].ReadOnly = $true; $grid.Columns[$i].SortMode = 'Automatic' }
    $chk = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
    $chk.Name = 'Pick'; $chk.HeaderText = ''; $chk.FillWeight = 22; $chk.ReadOnly = $false; $chk.SortMode = 'NotSortable'
    $grid.Columns.Insert(0, $chk)

    # ---- 3. act ----
    $bar3 = New-Object System.Windows.Forms.FlowLayoutPanel
    $bar3.Dock = 'Bottom'; $bar3.Height = 46; $bar3.WrapContents = $false; $bar3.Padding = New-Object System.Windows.Forms.Padding(0, 8, 0, 0)
    $btnMove = $App.Theme.MakeButton('Move selected')
    $btnUndo = $App.Theme.MakeButton('Undo last')
    $btnDelete = $App.Theme.MakeButton('Delete duplicates')
    $hint = New-Object System.Windows.Forms.Label
    $hint.AutoSize = $true; $hint.ForeColor = $App.Theme.Muted; $hint.Margin = New-Object System.Windows.Forms.Padding(16, 8, 0, 0)
    $hint.Text = 'Duplicate -> X:\_Duplicates.  Unique, Keep, Partly, Loose files -> X:\_Clean (paths kept).  Every move stays on its drive and can be undone. Nothing is deleted until Delete duplicates.'
    $bar3.Controls.AddRange(@($btnMove, $btnUndo, $btnDelete, $hint))

    $moreMenu = New-Object System.Windows.Forms.ContextMenuStrip
    [void]$moreMenu.Items.Add('Drives and priority...')
    [void]$moreMenu.Items.Add('History...')
    [void]$moreMenu.Items.Add('Check a folder...')
    [void]$moreMenu.Items.Add('Consolidate...')

    $s = @{ Cat = $cat; App = $App; Combo = $cbo; Grid = $grid; Sum = $sum; Where = $lblWhere; Show = $cboShow; Sel = $lblSel; Prog = $prog
            Job = $null; Stop = $btnStop; Busy = @($btnScan, $btnMove, $btnUndo, $btnDelete, $btnLoad); Rel = ''; Rows = @(); Regex = $null; Parts = $chkParts; More = $moreMenu; MoreBtn = $btnMore }

    # ---- helpers ----
    $driveId = { $v = $s.Combo.SelectedItem; if ($v -and $v.DriveId -gt 0) { [long]$v.DriveId } else { [long]0 } }.GetNewClosure()
    $s.DriveId = $driveId

    $countSel = {
        $n = 0; $b = [long]0
        foreach ($row in $s.Grid.Rows) { if ([bool]$row.Cells['Pick'].Value) { $n++; $b += $row.Tag.Bytes } }
        $s.Sel.Text = $(if ($n) { '{0:N0} ticked, {1}' -f $n, [FileManagerEngine.Util]::Size($b) } else { '' })
    }.GetNewClosure()
    $s.CountSel = $countSel

    $applyShow = {
        $want = [string]$s.Show.SelectedItem
        $s.Grid.CurrentCell = $null
        foreach ($row in $s.Grid.Rows) {
            $r = $row.Tag
            $ok = ($want -eq 'All' -or $r.Status -eq $want)
            if ($ok -and $s.Regex) { $ok = ($s.Regex.IsMatch([string]$r.Name) -or $s.Regex.IsMatch([string]$r.Note)) }
            $row.Visible = $ok
        }
    }.GetNewClosure()
    $s.ApplyShow = $applyShow

    $fill = {
        $d = & $s.DriveId
        $s.Grid.Rows.Clear()
        if ($d -le 0) {
            $s.Sum.Text = 'Pick a drive and click Scan. (A new drive is added to the catalog by its first scan.)'
            $s.Where.Text = ''
            & $s.CountSel; return
        }
        $rows = @($s.Cat.GetView($d, $s.Rel, [bool]$s.Parts.Checked))
        $s.Rows = $rows
        $colors = @{
            'Duplicate'         = [System.Drawing.Color]::FromArgb(180, 35, 24)
            'Older copy found'  = [System.Drawing.Color]::FromArgb(142, 68, 173)
            'Keep (has copies)' = [System.Drawing.Color]::FromArgb(26, 127, 55)
            'Partly'            = [System.Drawing.Color]::DarkOrange
        }
        $s.Grid.SuspendLayout()
        try {
            foreach ($r in $rows) {
                $i = $s.Grid.Rows.Add($false, $r.Status, $(if ($r.IsPart) { '      ' + [char]0x21B3 + ' ' + $r.Name } else { $r.Name }), [FileManagerEngine.Util]::Size($r.Bytes), $r.Files.ToString('N0'),
                    $r.Folders.ToString('N0'), $(if ($r.Copies -gt 0) { $r.Copies } else { '' }), $(if ($r.Reward -gt 0) { [FileManagerEngine.Util]::Size($r.Reward) } else { '' }), $r.Oldest, $r.Note)
                $s.Grid.Rows[$i].Tag = $r
                if ($colors.ContainsKey($r.Status)) { $s.Grid.Rows[$i].Cells['cStatus'].Style.ForeColor = $colors[$r.Status] }
                if ($r.IsPart) { $s.Grid.Rows[$i].DefaultCellStyle.BackColor = $s.App.Theme.Panel }
            }
        }
        finally { $s.Grid.ResumeLayout() }
        & $s.ApplyShow
        $drive = $s.Combo.SelectedItem
        $s.Where.Text = $drive.Letter + '\' + $s.Rel
        $dr = @($s.Cat.GetDrives() | Where-Object { $_.Id -eq $d }) | Select-Object -First 1
        $info = $(if ($dr) { '{0:N0} files, {1}, {2:N0} hashed, scanned {3}' -f $dr.Files, [FileManagerEngine.Util]::Size($dr.Bytes), $dr.Hashed, $(if ($dr.LastScan) { $dr.LastScan } else { 'never' }) } else { '' })
        if ($dr -and $dr.NeedsRescan) { $info += '  -  SCAN AGAIN: the drive changed' }
        $s.Sum.Text = $info + '     ' + $s.Cat.ViewSummary($d)
        & $s.CountSel
    }.GetNewClosure()
    $s.Fill = $fill

    $loadDrives = {
        $keep = $(if ($s.Combo.SelectedItem) { $s.Combo.SelectedItem.Key } else { '' })
        $s.Combo.Items.Clear()
        foreach ($v in $s.Cat.GetVolumes()) { if (-not $v.IsSystem) { [void]$s.Combo.Items.Add($v) } }
        for ($i = 0; $i -lt $s.Combo.Items.Count; $i++) { if ($s.Combo.Items[$i].Key -eq $keep) { $s.Combo.SelectedIndex = $i } }
        if ($s.Combo.SelectedIndex -lt 0 -and $s.Combo.Items.Count -gt 0) { $s.Combo.SelectedIndex = 0 }
        if ($s.Combo.Items.Count -eq 0) { & $s.Fill }
    }.GetNewClosure()
    $s.LoadDrives = $loadDrives
    Register-FmRefresh -Name 'Main' -Action { & $s.Fill }.GetNewClosure()

    $setBusy = {
        param([bool]$Busy)
        foreach ($b in $s.Busy) { $b.Enabled = -not $Busy }
        $s.Stop.Enabled = $Busy
    }.GetNewClosure()

    $run = {
        param($Job, [string]$Text, [scriptblock]$After)
        if (-not $Job) { return }
        $s = $s; $setBusy = $setBusy   # local copies for the OnDone closure
        $s.Job = $Job
        $s.Prog.Log.Clear()
        & $s.Prog.Reset $Text
        & $setBusy $true
        Start-FmJobWatch -App $s.App -Job $Job -OnTick $s.Prog.Update -OnDone {
            param($j)
            & $setBusy $false
            $vol = $s.Combo.SelectedItem
            & $s.LoadDrives
            & $s.Fill
            Invoke-FmRefresh -Except 'Main'
            if ($After -and -not $j.Failed -and -not $j.Cancelled) { & $After $j }
        }.GetNewClosure()
    }.GetNewClosure()
    $s.Run = $run

    $ticked = {
        $ids = New-Object System.Collections.Generic.List[long]
        $files = $false; $older = 0; $n = 0
        foreach ($row in $s.Grid.Rows) {
            if (-not [bool]$row.Cells['Pick'].Value) { continue }
            $n++
            if ($row.Tag.Kind -eq 'files') { $files = $true } else { $ids.Add([long]$row.Tag.FolderId) }
            if ($row.Tag.Status -eq 'Older copy found') { $older++ }
        }
        return @{ Ids = $ids.ToArray(); Files = $files; Count = $n; Older = $older }
    }.GetNewClosure()

    # ---- events ----
    $cbo.Add_SelectedIndexChanged({ $s.Rel = ''; & $s.Fill }.GetNewClosure())
    $btnLoad.Add_Click({ & $s.LoadDrives }.GetNewClosure())
    $cboShow.Add_SelectedIndexChanged({ & $s.ApplyShow }.GetNewClosure())
    $chkParts.Add_CheckedChanged({ & $s.Fill }.GetNewClosure())
    [void](Register-ListFilter -App $App -TextBox $txtFilter -OnFilter { param($Regex, $Text) $s.Regex = $Regex; & $s.ApplyShow }.GetNewClosure())
    $grid.Add_CurrentCellDirtyStateChanged({ if ($s.Grid.IsCurrentCellDirty) { $s.Grid.CommitEdit('CurrentCellChange') } }.GetNewClosure())
    $grid.Add_CellValueChanged({ param($sender, $e) if ($e.ColumnIndex -eq 0) { & $s.CountSel } }.GetNewClosure())

    # numbers sort as numbers (the cells show "1.2 GB")
    $grid.Add_SortCompare({
        param($sender, $e)
        $map = @{ cSize = 'Bytes'; cFiles = 'Files'; cFolders = 'Folders'; cCopies = 'Copies'; cReward = 'Reward' }
        $col = $e.Column.Name
        if ($map.ContainsKey($col)) {
            $a = $sender.Rows[$e.RowIndex1].Tag; $b = $sender.Rows[$e.RowIndex2].Tag
            $e.SortResult = ([long]$a.($map[$col])).CompareTo([long]$b.($map[$col]))
            $e.Handled = $true
        }
    })

    # double-click: look inside a folder (Partly ones especially)
    $grid.Add_CellDoubleClick({
        param($sender, $e)
        if ($e.RowIndex -lt 0 -or $e.ColumnIndex -eq 0) { return }
        $r = $s.Grid.Rows[$e.RowIndex].Tag
        if ($r.Kind -ne 'folder' -or -not $r.HasInside) { return }
        $s.Rel = $r.Rel
        & $s.Fill
    }.GetNewClosure())

    $btnUp.Add_Click({
        if (-not $s.Rel) { return }
        $s.Rel = $(if ($s.Rel.Contains('\')) { $s.Rel.Substring(0, $s.Rel.LastIndexOf('\')) } else { '' })
        & $s.Fill
    }.GetNewClosure())

    $btnAll.Add_Click({
        $s.Grid.EndEdit()
        $ask = ([string](Get-FmSetting -App $s.App -Key 'FmSwapOlder')) -eq 'Ask'
        foreach ($row in $s.Grid.Rows) {
            if (-not $row.Visible) { continue }
            $row.Cells['Pick'].Value = -not ($ask -and $row.Tag.Status -eq 'Older copy found')
        }
        & $s.CountSel
    }.GetNewClosure())
    $btnNone.Add_Click({ $s.Grid.EndEdit(); foreach ($row in $s.Grid.Rows) { $row.Cells['Pick'].Value = $false }; & $s.CountSel }.GetNewClosure())

    $btnOpen.Add_Click({
        $vol = $s.Combo.SelectedItem
        if (-not $vol) { return }
        $r = $null
        if ($s.Grid.CurrentRow) { $r = $s.Grid.CurrentRow.Tag }
        $path = $(if ($r -and $r.Kind -eq 'folder') { $vol.Root + $r.Rel } else { $vol.Root + $s.Rel })
        Open-FmFolder -App $s.App -Path $path
    }.GetNewClosure())

    $btnScan.Add_Click({
        $vol = $s.Combo.SelectedItem
        if (-not $vol) { $App.SetStatus('Connect a drive, then click Load drives.', 'warn'); return }
        $o = New-FmOptions -App $App
        $code = "# Read every folder and file on $($vol.Root) into the hash database (read only: nothing on the drive changes).`r`n" +
                "Get-ChildItem -LiteralPath $(Format-AppCommandValue $vol.Root) -Recurse -Force -File |`r`n" +
                "    Get-FileHash -Algorithm $($s.Cat.HashAlgorithm)" + $(if ($o.HashEverything) { '' } else { "   # only files that might be duplicates (Environment > File Manager)" }) + "`r`n" +
                "# Catalog: $($s.Cat.DbPath). Files already hashed and unchanged are not read again."
        if (-not (Confirm-AppCommand -App $App -Title 'Scan' -Kind Read -Code $code -Summary "Scan $($vol.Display)")) { return }
        & $s.Run (Invoke-FmSafe -App $App -What 'Scan' -Action { $s.Cat.StartScan($vol.Root, $o) }) 'Scanning...' $null
    }.GetNewClosure())

    $btnStop.Add_Click({ if ($s.Job -and -not $s.Job.Finished) { $s.Job.Cancel(); $s.Prog.Phase.Text = 'Stopping...' } }.GetNewClosure())

    $btnMove.Add_Click({
        $d = & $s.DriveId
        if ($d -le 0) { $App.SetStatus('Scan the drive first.', 'warn'); return }
        $t = & $ticked
        if ($t.Count -eq 0) { $App.SetStatus('Tick the rows to move first.', 'warn'); return }
        $s.Cat.Options = New-FmOptions -App $App
        $plan = Invoke-FmSafe -App $App -What 'Move selected' -Action { $s.Cat.BuildPlanFor($d, $t.Ids, $t.Files) }
        if (-not $plan) { return }
        if ($plan.BatchId -le 0) {
            [void][System.Windows.Forms.MessageBox]::Show(("Nothing to move.`r`n`r`n" + $plan.NotesText), 'Move selected', 'OK', 'Information')
            return
        }
        $summary = ('{0:N0} folder(s) to _Duplicates ({1}), {2:N0} item(s) to _Clean.' -f $plan.DupItems, [FileManagerEngine.Util]::Size($plan.DupBytes), $plan.CleanItems) +
                   $(if ($t.Older) { " Includes $($t.Older) swap(s): the copy in _Clean goes to _Duplicates and the older one takes its place." } else { '' }) +
                   ' Every move stays on its drive and can be undone. Nothing is deleted.' +
                   $(if ($plan.Notes.Count) { ' Notes: ' + ($plan.Notes -join ' ') } else { '' })
        if (-not (Confirm-AppCommand -App $App -Title 'Move selected' -Kind Change -Always -Code $s.Cat.MoveScript($plan.BatchId, $null) -Summary $summary -RunLabel 'Move')) {
            $s.Cat.CancelBatch($plan.BatchId)
            return
        }
        $App.LogAction("Move selected: batch $($plan.BatchId), $($plan.DupItems) to _Duplicates, $($plan.CleanItems) to _Clean.")
        & $s.Run (Invoke-FmSafe -App $App -What 'Move selected' -Action { $s.Cat.StartApply($plan.BatchId) }) 'Moving...' $null
    }.GetNewClosure())

    $btnUndo.Add_Click({
        $b = $s.Cat.LastUndoableBatch()
        if ($b -le 0) { $App.SetStatus('Nothing to undo.', 'info'); return }
        if (-not (Confirm-AppCommand -App $App -Title 'Undo last' -Kind Change -Always -Code $s.Cat.UndoScript($b) -RunLabel 'Move back' `
                -Summary "Move everything of the last move (batch $b) back to where it was. Older moves: More > History.")) { return }
        $App.LogAction("Undo last: batch $b.")
        & $s.Run (Invoke-FmSafe -App $App -What 'Undo last' -Action { $s.Cat.StartUndo($b) }) 'Moving back...' $null
    }.GetNewClosure())

    $btnDelete.Add_Click({
        $n = $s.Cat.MovedDuplicates()
        if ($n -eq 0) { $App.SetStatus('No moved duplicates are waiting in _Duplicates.', 'info'); return }
        $summary = ('PERMANENTLY delete the {0:N0} duplicate folder(s) waiting in _Duplicates ({1}). Each one is read again and compared with its kept copy first; anything not identical is kept. ' -f $n, [FileManagerEngine.Util]::Size($s.Cat.MovedDuplicateBytes())) +
                   'The drives with the kept copies must be connected. This cannot be undone. To delete only some: More > History.'
        if (-not (Confirm-AppCommand -App $App -Title 'Delete duplicates' -Kind Change -Always -Code $s.Cat.DeleteAllScript() -Summary $summary -RunLabel 'Delete')) { return }
        $App.LogAction("Delete duplicates: $n folder(s), after re-check.")
        & $s.Run (Invoke-FmSafe -App $App -What 'Delete duplicates' -Action { $s.Cat.StartDeleteAllDuplicates() }) 'Re-checking and deleting...' $null
    }.GetNewClosure())

    # ---- More ----
    $btnMore.Add_Click({ $s.More.Show($s.MoreBtn, (New-Object System.Drawing.Point(0, $s.MoreBtn.Height))) }.GetNewClosure())
    $moreMenu.Add_ItemClicked({
        param($sender, $e)
        $what = [string]$e.ClickedItem.Text
        $sender.Close()
        switch -Wildcard ($what) {
            'Drives*'      { Show-FmPageWindow -App $s.App -Title 'Drives and priority' -Build ${function:Build-FmDrivesTab}; & $s.LoadDrives; & $s.Fill }
            'History*'     { Show-FmPageWindow -App $s.App -Title 'History' -Build ${function:Build-FmReportsTab}; & $s.Fill }
            'Consolidate*' { Show-FmPageWindow -App $s.App -Title 'Consolidate' -Build ${function:Build-FmConsolidateTab}; & $s.LoadDrives; & $s.Fill }
            'Check*' {
                $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
                $dlg.Description = 'Pick a folder to compare with the catalog (for example on a thumb drive). Nothing is added or moved.'
                $dlg.ShowNewFolderButton = $false
                if ($dlg.ShowDialog() -ne 'OK') { return }
                $folder = $dlg.SelectedPath
                $code = "# Check a folder: read every file and look it up in the catalog. Nothing is added, nothing moves.`r`n" +
                        "Get-ChildItem -LiteralPath $(Format-AppCommandValue $folder) -Recurse -Force -File | Get-FileHash -Algorithm $($s.Cat.HashAlgorithm)"
                if (-not (Confirm-AppCommand -App $s.App -Title 'Check a folder' -Kind Read -Code $code -Summary "Is $folder already in the catalog?")) { return }
                $s.Cat.Options = New-FmOptions -App $s.App
                $app = $s.App
                & $s.Run (Invoke-FmSafe -App $s.App -What 'Check a folder' -Action { $s.Cat.StartCheck($folder) }) 'Checking...' { param($j) Show-FmCheckWindow -App $app -CheckId $j.ResultId }.GetNewClosure()
            }
        }
    }.GetNewClosure())

    # Dock order: Fill first, then Bottom bands, then Top bands from the bottom up.
    $Page.Controls.Add($grid)
    $Page.Controls.Add($prog.Log)
    $Page.Controls.Add($bar3)
    $Page.Controls.Add($bar2)
    $Page.Controls.Add($sum)
    $Page.Controls.Add($prog.Panel)
    $Page.Controls.Add($bar1)
    & $loadDrives
    if ($cat.Busy) { & $run $cat.CurrentJob 'Working...' $null }
}
