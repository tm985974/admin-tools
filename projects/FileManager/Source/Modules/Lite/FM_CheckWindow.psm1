# FM_CheckWindow.psm1   (LITE TIER)
#
# Results of Scan > Check only: is this folder (and each folder in it) already in
# the catalog? Folders are listed top-down (nothing below a folder that is fully
# accounted for); "Files not found" lists what you would still need to keep.
#
#   Show-FmCheckWindow -App $App -CheckId 3

function Show-FmCheckWindow {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $App, [Parameter(Mandatory)] [long]$CheckId)
    $cat = Get-FmCatalog -App $App
    $run = $cat.GetCheck($CheckId)
    if (-not $run) { $App.SetStatus("Check $CheckId not found.", 'warn'); return }

    $f = New-Object System.Windows.Forms.Form
    $f.Text = 'Check results'
    $f.StartPosition = 'CenterParent'
    $f.Size = New-Object System.Drawing.Size(1500, 860)
    $f.MinimumSize = New-Object System.Drawing.Size(900, 500)
    $f.Font = New-AppFont -App $App
    $f.BackColor = $App.Theme.Surface
    $f.Padding = New-Object System.Windows.Forms.Padding(14)

    $hdr = New-FmLabel -App $App -Text $run.Folder -Header
    $pct = $(if ($run.Files -gt 0) { [int](100.0 * $run.HaveFiles / $run.Files) } else { 100 })
    $verdict = $(if ($run.Files -eq 0) { 'The folder has no files.' }
                 elseif ($run.HaveFiles -eq $run.Files) { 'Everything in this folder is already in the catalog.' }
                 elseif ($run.NewFiles -eq 0 -and $run.Unreadable -eq 0) { 'Everything is probably in the catalog (some matches are by size only - see below).' }
                 else { 'Some files are not in the catalog yet - see "Files not found".' })
    $sum = New-FmLabel -App $App -Height 66 -Text ($verdict + [Environment]::NewLine +
        ('{0:N0} of {1:N0} files found elsewhere ({2}%)  |  {3:N0} probably (same size, not content-checked)  |  {4:N0} not found ({5})  |  {6:N0} unreadable' -f
            $run.HaveFiles, $run.Files, $pct, $run.Probable, $run.NewFiles, [FileManagerEngine.Util]::Size($run.NewBytes), $run.Unreadable) + [Environment]::NewLine +
        "Checked $($run.Finished). 'Probably' becomes certain when the drive with those files is connected during the check, or after a content check of that drive.")

    $tabs = New-Object System.Windows.Forms.TabControl
    $tabs.Dock = 'Fill'
    $pgFolders = New-Object System.Windows.Forms.TabPage 'Folders'
    $pgFiles = New-Object System.Windows.Forms.TabPage 'Files not found'
    foreach ($pg in @($pgFolders, $pgFiles)) { $pg.BackColor = $App.Theme.Surface; $pg.Padding = New-Object System.Windows.Forms.Padding(6); [void]$tabs.TabPages.Add($pg) }

    $gFolders = New-FmGrid -App $App -Columns @('Result', 'Folder', 'Files', 'Found', 'Size', 'Not found', 'Where it already is') -Weights @(150, 380, 60, 60, 70, 80, 420)
    foreach ($r in $cat.GetCheckRows($CheckId, 'folder', 50000)) {
        $i = $gFolders.Rows.Add($r.Status, $r.Rel, $r.Files.ToString('N0'), $r.Found.ToString('N0'), [FileManagerEngine.Util]::Size($r.Bytes), [FileManagerEngine.Util]::Size($r.NewBytes), $r.Matched)
        $color = switch ($r.Status) {
            'Already have it'           { [System.Drawing.Color]::FromArgb(26, 127, 55) }
            'All files found elsewhere' { [System.Drawing.Color]::FromArgb(26, 127, 55) }
            'New'                       { [System.Drawing.Color]::FromArgb(180, 35, 24) }
            'Partly'                    { [System.Drawing.Color]::DarkOrange }
            default                     { $App.Theme.Text }
        }
        $gFolders.Rows[$i].DefaultCellStyle.ForeColor = $color
    }
    $pgFolders.Controls.Add($gFolders)

    $gFiles = New-FmGrid -App $App -Columns @('Result', 'File', 'Size', 'Note') -Weights @(90, 620, 80, 420)
    foreach ($r in $cat.GetCheckRows($CheckId, 'file', 50000)) {
        $i = $gFiles.Rows.Add($r.Status, $r.Rel, [FileManagerEngine.Util]::Size($r.Bytes), $r.Matched)
        if ($r.Status -eq 'New') { $gFiles.Rows[$i].DefaultCellStyle.ForeColor = [System.Drawing.Color]::FromArgb(180, 35, 24) }
    }
    $pgFiles.Controls.Add($gFiles)

    $bottom = New-Object System.Windows.Forms.FlowLayoutPanel
    $bottom.Dock = 'Bottom'; $bottom.Height = 46; $bottom.Padding = New-Object System.Windows.Forms.Padding(0, 8, 0, 0)
    $btnCsv = $App.Theme.MakeButton('Export CSV')
    $btnClose = $App.Theme.MakeButton('Close')
    $note = New-Object System.Windows.Forms.Label
    $note.AutoSize = $true; $note.ForeColor = $App.Theme.Muted; $note.Margin = New-Object System.Windows.Forms.Padding(16, 8, 0, 0)
    $note.Text = 'Green = already in the catalog, orange = partly, red = new. Nothing was added to the catalog. To keep this folder, copy the new files, or scan it (Scan > One folder).'
    $bottom.Controls.AddRange(@($btnCsv, $btnClose, $note))

    $s = @{ Cat = $cat; Id = $CheckId; Form = $f }
    $btnCsv.Add_Click({
        $dlg = New-Object System.Windows.Forms.SaveFileDialog
        $dlg.Filter = 'CSV file (*.csv)|*.csv'; $dlg.FileName = 'Check_{0}_{1:yyyyMMdd_HHmm}.csv' -f $s.Id, (Get-Date)
        if ($dlg.ShowDialog() -ne 'OK') { return }
        $n = Invoke-FmSafe -App $App -What 'Export CSV' -Action { $s.Cat.ExportCheckCsv($s.Id, $dlg.FileName) }
        if ($null -ne $n) { $App.SetStatus("Exported $n rows to $($dlg.FileName)", 'ok') }
    }.GetNewClosure())
    $btnClose.Add_Click({ $s.Form.Close() }.GetNewClosure())

    $f.Controls.Add($tabs)
    $f.Controls.Add($bottom)
    $f.Controls.Add($sum)
    $f.Controls.Add($hdr)
    $f.CancelButton = $btnClose
    [void]$f.ShowDialog()
    $f.Dispose()
}
