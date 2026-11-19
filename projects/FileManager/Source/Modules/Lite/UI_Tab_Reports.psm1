# UI_Tab_Reports.psm1   (LITE TIER)
#
# Reports: every batch of moves (Open batch = the batch window: move, undo or
# delete the steps you tick), the scan history, and the CSV / HTML exports.

function New-FmReportsTab {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Windows.Forms.TabPage]$Page,
        [Parameter(Mandatory)] $App
    )
    Set-LazyTabBuild -Page $Page -App $App -Build ${function:Build-FmReportsTab}
}

function Build-FmReportsTab {
    param($Page, $App)
    $Page.Padding = New-Object System.Windows.Forms.Padding(14)
    $cat = Get-FmCatalog -App $App

    $hdr = New-FmLabel -App $App -Text 'Reports' -Header

    $tabs = New-Object System.Windows.Forms.TabControl
    $tabs.Dock = 'Fill'
    $pgBatches = New-Object System.Windows.Forms.TabPage 'Batches'
    $pgScans = New-Object System.Windows.Forms.TabPage 'Scan history'
    foreach ($pg in @($pgBatches, $pgScans)) { $pg.BackColor = $App.Theme.Surface; $pg.Padding = New-Object System.Windows.Forms.Padding(6); [void]$tabs.TabPages.Add($pg) }

    # ---- batches ----
    $bBar = New-FmBar
    $btnRefresh = $App.Theme.MakeButton('Refresh')
    $btnOpen = $App.Theme.MakeButton('Open batch')
    $btnShow = $App.Theme.MakeButton('Show commands')
    $btnBatchCsv = $App.Theme.MakeButton('Export batch CSV')
    $btnDupCsv = $App.Theme.MakeButton('Export duplicates CSV')
    $btnHtml = $App.Theme.MakeButton('Export HTML report')
    $bBar.Controls.AddRange(@($btnRefresh, $btnOpen, $btnShow, $btnBatchCsv, $btnDupCsv, $btnHtml))

    $split = New-Object System.Windows.Forms.SplitContainer
    $split.Orientation = 'Horizontal'; $split.Size = New-Object System.Drawing.Size(1600, 700); $split.SplitterDistance = 220; $split.Dock = 'Fill'
    $gBatches = New-FmGrid -App $App -Columns @('Batch', 'Built', 'Applied', 'Status', 'Moves', 'Done', 'Failed', 'Deleted', 'Undone', 'Duplicate data', 'What') `
        -Weights @(50, 120, 120, 120, 55, 55, 55, 60, 60, 90, 300)
    $gActions = New-FmGrid -App $App -Columns @('Step', 'Kind', 'Drive', 'From', 'To', 'Status', 'When', 'Note') -Weights @(40, 75, 110, 330, 330, 70, 120, 260)
    $split.Panel1.Controls.Add($gBatches)
    $split.Panel2.Controls.Add($gActions)

    $note = New-FmLabel -App $App -Muted -Height 40 -Text ("Open batch (or double-click a batch) to move, undo or delete the steps you tick. Delete reads every file of each duplicate again and compares it with the kept copy;" +
        [Environment]::NewLine + "anything not identical is kept. The reason for every failed or skipped step is in its Note column.")
    $note.Dock = 'Bottom'

    $pgBatches.Controls.Add($split)
    $pgBatches.Controls.Add($bBar)

    # ---- scan history ----
    $sBar = New-FmBar
    $btnScanRefresh = $App.Theme.MakeButton('Refresh history')
    $sBar.Controls.Add($btnScanRefresh)
    $gScans = New-FmGrid -App $App -Columns @('Scan', 'Drive', 'Kind', 'Started', 'Finished', 'Status', 'Folders', 'Files', 'Data', 'Files read', 'Data read', 'Problems') `
        -Weights @(45, 160, 100, 120, 120, 70, 70, 80, 80, 80, 80, 65)
    $pgScans.Controls.Add($gScans)
    $pgScans.Controls.Add($sBar)

    $s = @{ Cat = $cat; Batches = $gBatches; Actions = $gActions; Scans = $gScans }

    $fillActions = {
        $s.Actions.Rows.Clear()
        $b = Get-FmSelected -Grid $s.Batches
        if (-not $b) { return }
        foreach ($a in $s.Cat.GetActions($b.Id, 20000)) {
            $i = $s.Actions.Rows.Add($a.Seq, $a.Kind, $a.Drive, $a.Src, $a.Dst, $a.Status, $a.Done, $a.Error)
            $s.Actions.Rows[$i].Tag = $a
            if ($a.Status -eq 'failed' -or $a.Error) { $s.Actions.Rows[$i].DefaultCellStyle.ForeColor = [System.Drawing.Color]::FromArgb(180, 35, 24) }
            elseif ($a.Status -eq 'planned' -or $a.Status -eq 'undone') { $s.Actions.Rows[$i].DefaultCellStyle.ForeColor = [System.Drawing.Color]::Gray }
        }
    }.GetNewClosure()
    $s.FillActions = $fillActions

    $refresh = {
        $keep = Get-FmSelected -Grid $s.Batches
        $s.Batches.Rows.Clear()
        foreach ($b in $s.Cat.GetBatches(500)) {
            $i = $s.Batches.Rows.Add($b.Id, $b.Created, $b.Applied, $b.Status, $b.Items, $b.Done, $b.Failed, $b.Deleted, $b.Undone, [FileManagerEngine.Util]::Size($b.Bytes), $b.Note)
            $s.Batches.Rows[$i].Tag = $b
            if ($keep -and $keep.Id -eq $b.Id) { $s.Batches.ClearSelection(); $s.Batches.Rows[$i].Selected = $true }
        }
        & $s.FillActions
        $s.Scans.Rows.Clear()
        foreach ($r in $s.Cat.GetScans(500)) {
            [void]$s.Scans.Rows.Add($r.Id, $r.Drive, $r.Kind, $r.Started, $r.Finished, $r.Status, $r.Folders.ToString('N0'), $r.Files.ToString('N0'),
                [FileManagerEngine.Util]::Size($r.Bytes), $r.Hashed.ToString('N0'), [FileManagerEngine.Util]::Size($r.HashedBytes), $r.Errors)
        }
    }.GetNewClosure()
    $s.Refresh = $refresh
    Register-FmRefresh -Name 'Reports' -Action $refresh

    $gBatches.Add_SelectionChanged({ & $s.FillActions }.GetNewClosure())
    $btnRefresh.Add_Click({ & $s.Refresh }.GetNewClosure())
    $btnScanRefresh.Add_Click({ & $s.Refresh }.GetNewClosure())

    $openBatch = {
        $b = Get-FmSelected -Grid $s.Batches
        if (-not $b) { $App.SetStatus('Select a batch first.', 'warn'); return }
        Show-FmBatchWindow -App $App -BatchId $b.Id
        & $s.Refresh
    }.GetNewClosure()
    $btnOpen.Add_Click({ & $openBatch }.GetNewClosure())
    $gBatches.Add_CellDoubleClick({ param($sender, $e) if ($e.RowIndex -ge 0) { & $openBatch } }.GetNewClosure())

    $btnShow.Add_Click({
        $b = Get-FmSelected -Grid $s.Batches
        if (-not $b) { $App.SetStatus('Select a batch first.', 'warn'); return }
        Show-FmText -App $App -Title "Batch $($b.Id) - commands" -Text $s.Cat.BatchScript($b.Id) -Note 'The PowerShell shown before this batch ran (equivalent to what the tool did).'
    }.GetNewClosure())

    $btnBatchCsv.Add_Click({
        $b = Get-FmSelected -Grid $s.Batches
        if (-not $b) { $App.SetStatus('Select a batch first.', 'warn'); return }
        $dlg = New-Object System.Windows.Forms.SaveFileDialog
        $dlg.Filter = 'CSV file (*.csv)|*.csv'; $dlg.FileName = 'Batch_{0}_{1:yyyyMMdd_HHmm}.csv' -f $b.Id, (Get-Date)
        if ($dlg.ShowDialog() -ne 'OK') { return }
        $n = Invoke-FmSafe -App $App -What 'Export batch CSV' -Action { $s.Cat.ExportBatchCsv($b.Id, $dlg.FileName) }
        if ($null -ne $n) { $App.SetStatus("Exported $n rows to $($dlg.FileName)", 'ok') }
    }.GetNewClosure())

    $btnDupCsv.Add_Click({
        $dlg = New-Object System.Windows.Forms.SaveFileDialog
        $dlg.Filter = 'CSV file (*.csv)|*.csv'; $dlg.FileName = 'Duplicates_{0:yyyyMMdd_HHmm}.csv' -f (Get-Date)
        if ($dlg.ShowDialog() -ne 'OK') { return }
        $n = Invoke-FmSafe -App $App -What 'Export duplicates CSV' -Action { $s.Cat.ExportDuplicatesCsv($dlg.FileName) }
        if ($null -ne $n) { $App.SetStatus("Exported $n rows to $($dlg.FileName)", 'ok') }
    }.GetNewClosure())

    $btnHtml.Add_Click({
        $dlg = New-Object System.Windows.Forms.SaveFileDialog
        $dlg.Filter = 'Web page (*.html)|*.html'; $dlg.FileName = 'FileManager_Report_{0:yyyyMMdd_HHmm}.html' -f (Get-Date)
        if ($dlg.ShowDialog() -ne 'OK') { return }
        [void](Invoke-FmSafe -App $App -What 'Export HTML report' -Action { $s.Cat.ExportHtml($dlg.FileName, 2000) })
        $App.SetStatus("Report saved: $($dlg.FileName)", 'ok')
    }.GetNewClosure())

    $Page.Controls.Add($tabs)
    $Page.Controls.Add($note)
    $Page.Controls.Add($hdr)
    & $refresh
}
