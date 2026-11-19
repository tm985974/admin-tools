# FM_BatchWindow.psm1   (LITE TIER)
#
# The batch window: every step of one plan (a move to _Duplicates or to _Clean)
# with a tick box. Tick all, some, or one, then Move selected / Undo selected /
# Delete selected duplicates. Steps you do not tick stay "planned" and can be run
# any time later (Reports > Open batch). The command window shows exactly the
# ticked steps before anything happens.
#
#   Show-FmBatchWindow -App $App -BatchId 12

function Show-FmBatchWindow {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $App, [Parameter(Mandatory)] [long]$BatchId)
    $cat = Get-FmCatalog -App $App

    $f = New-Object System.Windows.Forms.Form
    $f.Text = "Batch $BatchId"
    $f.StartPosition = 'CenterParent'
    $f.Size = New-Object System.Drawing.Size(1600, 900)
    $f.MinimumSize = New-Object System.Drawing.Size(1000, 600)
    $f.Font = New-AppFont -App $App
    $f.BackColor = $App.Theme.Surface
    $f.Padding = New-Object System.Windows.Forms.Padding(14)

    $hdr = New-FmLabel -App $App -Text "Batch $BatchId" -Header
    $sum = New-FmLabel -App $App -Height 44

    $bar = New-FmBar
    $btnAll = $App.Theme.MakeButton('Select all')
    $btnNone = $App.Theme.MakeButton('Select none')
    $btnTodo = $App.Theme.MakeButton('Not done yet')
    $btnDups = $App.Theme.MakeButton('Duplicates only')
    $btnClean = $App.Theme.MakeButton('_Clean only')
    $btnHigh = $App.Theme.MakeButton('Tick highlighted')
    $lblFilter = New-Object System.Windows.Forms.Label
    $lblFilter.Text = 'Filter:'; $lblFilter.AutoSize = $true; $lblFilter.Margin = New-Object System.Windows.Forms.Padding(20, 8, 4, 0)
    $txtFilter = New-Object System.Windows.Forms.TextBox
    $txtFilter.Width = 240; $txtFilter.Margin = New-Object System.Windows.Forms.Padding(0, 5, 8, 0)
    $lblSel = New-Object System.Windows.Forms.Label
    $lblSel.AutoSize = $true; $lblSel.Margin = New-Object System.Windows.Forms.Padding(8, 8, 0, 0)
    $lblSel.Font = New-AppFont -App $App -Style ([System.Drawing.FontStyle]::Bold)
    $bar.Controls.AddRange(@($btnAll, $btnNone, $btnTodo, $btnDups, $btnClean, $btnHigh, $lblFilter, $txtFilter, $lblSel))

    $grid = New-FmGrid -App $App -Columns @('Step', 'Kind', 'Drive', 'From', 'To', 'Size', 'Files', 'Status', 'Note') -Weights @(40, 75, 110, 360, 360, 70, 60, 70, 300) -Multi
    $grid.ReadOnly = $false
    foreach ($c in $grid.Columns) { $c.ReadOnly = $true }
    $chk = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
    $chk.Name = 'Pick'; $chk.HeaderText = ''; $chk.FillWeight = 22; $chk.ReadOnly = $false
    $grid.Columns.Insert(0, $chk)

    $prog = New-FmProgress -App $App -LogHeight 110
    $prog.Log.Dock = 'Bottom'
    $prog.Panel.Dock = 'Bottom'

    $bottom = New-Object System.Windows.Forms.FlowLayoutPanel
    $bottom.Dock = 'Bottom'; $bottom.Height = 46; $bottom.FlowDirection = 'LeftToRight'; $bottom.WrapContents = $false
    $bottom.Padding = New-Object System.Windows.Forms.Padding(0, 8, 0, 0)
    $btnMove = $App.Theme.MakeButton('Move selected')
    $btnUndo = $App.Theme.MakeButton('Undo selected')
    $btnDelete = $App.Theme.MakeButton('Delete selected duplicates')
    $btnStop = $App.Theme.MakeButton('Stop')
    $btnStop.Enabled = $false
    $btnClose = $App.Theme.MakeButton('Close')
    $hint = New-Object System.Windows.Forms.Label
    $hint.AutoSize = $true; $hint.ForeColor = $App.Theme.Muted; $hint.Margin = New-Object System.Windows.Forms.Padding(16, 8, 0, 0)
    $hint.Text = 'Tick the steps to run. Steps you leave unticked stay planned (Reports > Open batch). Ticking a folder for _Clean also moves the duplicates inside it first.'
    $bottom.Controls.AddRange(@($btnMove, $btnUndo, $btnDelete, $btnStop, $btnClose, $hint))

    $s = @{ Cat = $cat; Id = $BatchId; Form = $f; Grid = $grid; Sum = $sum; Sel = $lblSel; Prog = $prog; Job = $null; Stop = $btnStop
            Buttons = @($btnMove, $btnUndo, $btnDelete); Regex = $null }

    # ---- helpers ----
    $isTicked = { param($row) [bool]$row.Cells['Pick'].Value }
    $s.IsTicked = $isTicked

    $countSel = {
        $n = 0; $bytes = [long]0
        foreach ($row in $s.Grid.Rows) {
            if (& $s.IsTicked $row) { $n++; $bytes += $row.Tag.Bytes }
        }
        $s.Sel.Text = '{0:N0} of {1:N0} ticked, {2}' -f $n, $s.Grid.Rows.Count, [FileManagerEngine.Util]::Size($bytes)
    }.GetNewClosure()
    $s.CountSel = $countSel

    $fill = {
        $ticked = @{}
        foreach ($row in $s.Grid.Rows) { if (& $s.IsTicked $row) { $ticked[[long]$row.Tag.Id] = $true } }
        $counts = @{}
        $s.Grid.SuspendLayout()
        try {
            $s.Grid.Rows.Clear()
            foreach ($a in $s.Cat.GetActions($s.Id, 200000)) {
                $counts[$a.Status] = 1 + [int]$counts[$a.Status]
                $keep = $ticked.ContainsKey([long]$a.Id) -and ($a.Status -eq 'planned' -or $a.Status -eq 'failed' -or $a.Status -eq 'done')
                $i = $s.Grid.Rows.Add($keep, $a.Seq, $a.Kind, $a.Drive, $a.Src, $a.Dst, [FileManagerEngine.Util]::Size($a.Bytes), $a.Files.ToString('N0'), $a.Status, $a.Error)
                $row = $s.Grid.Rows[$i]
                $row.Tag = $a
                switch ($a.Status) {
                    'done'     { $row.DefaultCellStyle.ForeColor = [System.Drawing.Color]::FromArgb(26, 127, 55) }
                    'failed'   { $row.DefaultCellStyle.ForeColor = [System.Drawing.Color]::FromArgb(180, 35, 24) }
                    'planned'  { }
                    default    { $row.DefaultCellStyle.ForeColor = [System.Drawing.Color]::Gray }
                }
                if ($a.Error -and $a.Status -ne 'failed') { $row.Cells[9].Style.ForeColor = [System.Drawing.Color]::FromArgb(180, 35, 24) }
                if ($s.Regex) {
                    $hit = $false
                    foreach ($v in @($a.Src, $a.Dst, $a.Kind, $a.Status, $a.Drive, $a.Error)) { if ($v -and $s.Regex.IsMatch([string]$v)) { $hit = $true; break } }
                    $row.Visible = $hit
                }
            }
        }
        finally { $s.Grid.ResumeLayout() }
        $parts = @()
        foreach ($k in @('planned', 'done', 'failed', 'undone', 'deleted', 'replaced')) { if ($counts[$k]) { $parts += ('{0} {1:N0}' -f $k, $counts[$k]) } }
        $b = @($s.Cat.GetBatches(1000) | Where-Object { $_.Id -eq $s.Id }) | Select-Object -First 1
        $s.Sum.Text = $(if ($b) { "Built $($b.Created)  |  status: $($b.Status)  |  $($b.Note)" } else { '' }) + [Environment]::NewLine + ($parts -join '   |   ')
        & $s.CountSel
    }.GetNewClosure()
    $s.Fill = $fill

    $tick = {
        param([scriptblock]$Rule)
        $s.Grid.EndEdit()
        foreach ($row in $s.Grid.Rows) { if ($row.Visible) { $row.Cells['Pick'].Value = [bool](& $Rule $row.Tag) } }
        & $s.CountSel
    }.GetNewClosure()

    # Ticked rows whose status fits; returns [long[]] (possibly empty).
    $picked = {
        param([string[]]$Statuses, [string]$Kind = '')
        $ids = New-Object System.Collections.Generic.List[long]
        foreach ($row in $s.Grid.Rows) {
            if (-not (& $s.IsTicked $row)) { continue }
            $a = $row.Tag
            if ($Statuses -notcontains $a.Status) { continue }
            if ($Kind -and $a.Kind -ne $Kind) { continue }
            $ids.Add([long]$a.Id)
        }
        return , $ids.ToArray()
    }.GetNewClosure()

    $setBusy = {
        param([bool]$Busy)
        foreach ($b in $s.Buttons) { $b.Enabled = -not $Busy }
        $s.Stop.Enabled = $Busy
    }.GetNewClosure()

    $run = {
        param($Job, [string]$Text)
        if (-not $Job) { return }
        $s = $s; $setBusy = $setBusy   # local copies for the OnDone closure
        $s.Job = $Job
        & $s.Prog.Reset $Text
        & $setBusy $true
        Start-FmJobWatch -App $App -Job $Job -OnTick $s.Prog.Update -OnDone { param($j) & $setBusy $false; & $s.Fill; Invoke-FmRefresh }.GetNewClosure()
    }.GetNewClosure()

    # ---- events ----
    $grid.Add_CurrentCellDirtyStateChanged({ if ($s.Grid.IsCurrentCellDirty) { $s.Grid.CommitEdit('CurrentCellChange') } }.GetNewClosure())
    $grid.Add_CellValueChanged({ param($sender, $e) if ($e.ColumnIndex -eq 0) { & $s.CountSel } }.GetNewClosure())

    $btnAll.Add_Click({ & $tick { param($a) $true } }.GetNewClosure())
    $btnNone.Add_Click({ & $tick { param($a) $false } }.GetNewClosure())
    $btnTodo.Add_Click({ & $tick { param($a) $a.Status -eq 'planned' -or $a.Status -eq 'failed' } }.GetNewClosure())
    $btnDups.Add_Click({ & $tick { param($a) $a.Kind -eq 'Duplicate' } }.GetNewClosure())
    $btnClean.Add_Click({ & $tick { param($a) $a.Kind -eq 'To _Clean' } }.GetNewClosure())
    $btnHigh.Add_Click({
        $s.Grid.EndEdit()
        foreach ($row in $s.Grid.SelectedRows) { $row.Cells['Pick'].Value = $true }
        & $s.CountSel
    }.GetNewClosure())

    $onFilter = {
        param($Regex, $Text)
        $s.Regex = $Regex
        $s.Grid.CurrentCell = $null
        foreach ($row in $s.Grid.Rows) {
            $a = $row.Tag
            $hit = $true
            if ($Regex) {
                $hit = $false
                foreach ($v in @($a.Src, $a.Dst, $a.Kind, $a.Status, $a.Drive, $a.Error)) { if ($v -and $Regex.IsMatch([string]$v)) { $hit = $true; break } }
            }
            $row.Visible = $hit
        }
    }.GetNewClosure()
    [void](Register-ListFilter -App $App -TextBox $txtFilter -OnFilter $onFilter)

    $btnMove.Add_Click({
        $ids = & $picked @('planned', 'failed')
        if ($ids.Count -eq 0) { $App.SetStatus('Tick at least one step that is planned or failed.', 'warn'); return }
        $all = Invoke-FmSafe -App $App -What 'Move selected' -Action { $s.Cat.ExpandForMove($s.Id, $ids) }
        if (-not $all) { return }
        $extra = $all.Count - $ids.Count
        $summary = 'Move {0:N0} step(s) of batch {1}{2}. Every move stays on its own drive; nothing is deleted; each step can be undone here.' -f $all.Count, $s.Id,
            $(if ($extra -gt 0) { " (including $extra duplicate(s) inside the folders you ticked for _Clean, which move first)" } else { '' })
        if (-not (Confirm-AppCommand -App $App -Title 'Move selected' -Kind Change -Always -Code $s.Cat.MoveScript($s.Id, $all) -Summary $summary -RunLabel 'Move')) { return }
        $App.LogAction("Batch $($s.Id): move $($all.Count) step(s).")
        & $run (Invoke-FmSafe -App $App -What 'Move selected' -Action { $s.Cat.StartApply($s.Id, $ids) }) 'Moving...'
    }.GetNewClosure())

    $btnUndo.Add_Click({
        $ids = & $picked @('done')
        if ($ids.Count -eq 0) { $App.SetStatus('Tick at least one step that is done.', 'warn'); return }
        $all = Invoke-FmSafe -App $App -What 'Undo selected' -Action { $s.Cat.ExpandForUndo($s.Id, $ids) }
        if (-not $all) { return }
        $extra = $all.Count - $ids.Count
        $summary = 'Move {0:N0} step(s) of batch {1} back to where they were, newest first{2}.' -f $all.Count, $s.Id,
            $(if ($extra -gt 0) { " (including $extra folder(s) in _Clean that the ticked duplicates came from, which go back first)" } else { '' })
        if (-not (Confirm-AppCommand -App $App -Title 'Undo selected' -Kind Change -Always -Code $s.Cat.UndoScript($s.Id, $all) -Summary $summary -RunLabel 'Move back')) { return }
        $App.LogAction("Batch $($s.Id): undo $($all.Count) step(s).")
        & $run (Invoke-FmSafe -App $App -What 'Undo selected' -Action { $s.Cat.StartUndo($s.Id, $ids) }) 'Moving back...'
    }.GetNewClosure())

    $btnDelete.Add_Click({
        $ids = & $picked @('done') 'Duplicate'
        if ($ids.Count -eq 0) { $App.SetStatus('Tick at least one duplicate that has been moved (status done).', 'warn'); return }
        $summary = 'PERMANENTLY delete {0:N0} duplicate folder(s) from _Duplicates. Each one is read again and compared with its kept copy first; anything not identical is kept. The drives with the kept copies must be connected. This cannot be undone.' -f $ids.Count
        if (-not (Confirm-AppCommand -App $App -Title 'Delete selected duplicates' -Kind Change -Always -Code $s.Cat.DeleteScript($s.Id, $ids) -Summary $summary -RunLabel 'Delete')) { return }
        $App.LogAction("Batch $($s.Id): delete $($ids.Count) duplicate folder(s) after re-check.")
        & $run (Invoke-FmSafe -App $App -What 'Delete selected duplicates' -Action { $s.Cat.StartDeleteDuplicates($s.Id, $ids) }) 'Re-checking and deleting...'
    }.GetNewClosure())

    $btnStop.Add_Click({ if ($s.Job -and -not $s.Job.Finished) { $s.Job.Cancel(); $s.Prog.Phase.Text = 'Stopping after the current step...' } }.GetNewClosure())
    $btnClose.Add_Click({ $s.Form.Close() }.GetNewClosure())
    $f.Add_FormClosing({
        param($sender, $e)
        if ($s.Job -and -not $s.Job.Finished) {
            $e.Cancel = $true
            $App.SetStatus('A task is still running in the batch window. Stop it or wait for it to finish.', 'warn')
        }
    }.GetNewClosure())

    # Dock order: Fill first, then Bottom bands, then Top bands from the bottom up.
    $f.Controls.Add($grid)
    $f.Controls.Add($prog.Log)
    $f.Controls.Add($prog.Panel)
    $f.Controls.Add($bottom)
    $f.Controls.Add($bar)
    $f.Controls.Add($sum)
    $f.Controls.Add($hdr)
    & $fill
    [void]$f.ShowDialog()
    $f.Dispose()
}
