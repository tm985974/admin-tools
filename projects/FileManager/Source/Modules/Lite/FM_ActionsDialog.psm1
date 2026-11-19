# FM_ActionsDialog.psm1   (LITE TIER)
#
# The Actions window (after a scan, or from the Duplicates tab): tick what to do,
# pick the connected drives to work on, then "Build plan". Nothing moves here: the
# plan opens in the batch window (FM_BatchWindow.psm1), where you tick the steps
# to run. Every move stays on its own drive (an instant rename). Deleting
# duplicates is a separate step, after a re-check.

function Show-FmActionsDialog {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $App, [string]$Folder = '')
    $cat = Get-FmCatalog -App $App
    if ($cat.Busy) {
        $App.SetStatus("Wait for '$($cat.CurrentJob.Name)' to finish, then open Actions again.", 'warn')
        return
    }

    $f = New-Object System.Windows.Forms.Form
    $f.Text = 'Actions'
    $f.StartPosition = 'CenterParent'
    $f.Size = New-Object System.Drawing.Size(980, 760)
    $f.MinimumSize = New-Object System.Drawing.Size(820, 640)
    $f.Font = New-AppFont -App $App
    $f.BackColor = $App.Theme.Surface
    $f.Padding = New-Object System.Windows.Forms.Padding(14)

    $groups = $cat.GroupCount()
    $hdr = New-FmLabel -App $App -Text 'What do you want to do?' -Header
    $sum = New-FmLabel -App $App -Height 44 -Text ('{0:N0} duplicate folder groups, {1} to reclaim.' -f $groups, [FileManagerEngine.Util]::Size($cat.ReclaimTotal()) +
        [Environment]::NewLine + 'Tip: scan every drive (and run the content check) before moving anything, so the best copy is kept.')

    $grp = New-Object System.Windows.Forms.GroupBox
    $grp.Text = 'Tasks'; $grp.Dock = 'Top'; $grp.Height = 190
    $flow = New-Object System.Windows.Forms.FlowLayoutPanel
    $flow.Dock = 'Fill'; $flow.FlowDirection = 'TopDown'; $flow.WrapContents = $false; $flow.Padding = New-Object System.Windows.Forms.Padding(8, 4, 0, 0)
    $chkDup = New-Object System.Windows.Forms.CheckBox
    $chkDup.Text = 'Move duplicate folders to _Duplicates'
    $chkDup.AutoSize = $true; $chkDup.Checked = $true
    $chkClean = New-Object System.Windows.Forms.CheckBox
    $chkClean.Text = 'Move keepers and unique folders to _Clean'
    $chkClean.AutoSize = $true; $chkClean.Checked = $true
    $chkQuick = New-Object System.Windows.Forms.CheckBox
    $chkQuick.Text = 'Include quick matches (not content-checked)'
    $chkQuick.AutoSize = $true
    $chkCsv = New-Object System.Windows.Forms.CheckBox
    $chkCsv.Text = 'Export duplicates report (CSV)'
    $chkCsv.AutoSize = $true
    $chkHtml = New-Object System.Windows.Forms.CheckBox
    $chkHtml.Text = 'Export HTML report'
    $chkHtml.AutoSize = $true
    $hint = New-Object System.Windows.Forms.Label
    $hint.AutoSize = $true; $hint.ForeColor = $App.Theme.Muted
    $hint.Text = 'Build plan moves nothing: it lists every move with a tick box, so you can run all of them or a few at a time. Each drive gets its own X:\_Clean and X:\_Duplicates.'
    $flow.Controls.AddRange(@($chkDup, $chkClean, $chkQuick, $chkCsv, $chkHtml, $hint))
    $grp.Controls.Add($flow)

    $scope = New-FmBar -Height 36
    $rbDrives = New-Object System.Windows.Forms.RadioButton
    $rbDrives.Text = 'Whole drives (ticked below)'
    $rbDrives.AutoSize = $true; $rbDrives.Margin = New-Object System.Windows.Forms.Padding(0, 8, 20, 0)
    $rbOne = New-Object System.Windows.Forms.RadioButton
    $rbOne.Text = 'Only this folder:'
    $rbOne.AutoSize = $true; $rbOne.Margin = New-Object System.Windows.Forms.Padding(0, 8, 6, 0)
    $txtScope = New-Object System.Windows.Forms.TextBox
    $txtScope.Width = 460; $txtScope.Margin = New-Object System.Windows.Forms.Padding(0, 6, 6, 0); $txtScope.Text = $Folder
    $btnScope = $App.Theme.MakeButton('Browse')
    $scope.Controls.AddRange(@($rbDrives, $rbOne, $txtScope, $btnScope))
    if ($Folder) { $rbOne.Checked = $true } else { $rbDrives.Checked = $true }

    $lblDrives = New-FmLabel -App $App -Height 26 -Text 'Drives to work on (connected drives only):'
    $list = New-Object System.Windows.Forms.CheckedListBox
    $list.Dock = 'Top'; $list.Height = 110; $list.CheckOnClick = $true; $list.IntegralHeight = $false
    foreach ($v in $cat.GetVolumes()) {
        if ($v.IsSystem -or $v.DriveId -le 0) { continue }
        $idx = $list.Items.Add($v)
        $list.SetItemChecked($idx, $true)
    }

    $prog = New-FmProgress -App $App -LogHeight 0
    $prog.Panel.Visible = $false

    $bottom = New-Object System.Windows.Forms.Panel
    $bottom.Dock = 'Bottom'; $bottom.Height = 48
    $btnGo = $App.Theme.MakeButton('Build plan')
    $btnGo.Location = New-Object System.Drawing.Point(0, 10)
    $btnClose = $App.Theme.MakeButton('Close')
    $btnClose.Anchor = 'Top, Right'
    $bottom.Controls.AddRange(@($btnGo, $btnClose))
    $btnClose.Location = New-Object System.Drawing.Point(($bottom.Width - $btnClose.Width), 10)

    $s = @{ Cat = $cat; Form = $f; List = $list; Dup = $chkDup; Clean = $chkClean; Quick = $chkQuick; Csv = $chkCsv; Html = $chkHtml
            Prog = $prog; Go = $btnGo; Job = $null; One = $rbOne; Scope = $txtScope }

    $btnScope.Add_Click({
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = 'Pick the folder to clean (scan it first: Scan > One folder)'
        $dlg.ShowNewFolderButton = $false
        if ($s.Scope.Text) { $dlg.SelectedPath = $s.Scope.Text }
        if ($dlg.ShowDialog() -eq 'OK') { $s.Scope.Text = $dlg.SelectedPath; $s.One.Checked = $true }
    }.GetNewClosure())

    $f.Add_FormClosing({
        param($sender, $e)
        if ($s.Job -and -not $s.Job.Finished) {
            $e.Cancel = $true
            $App.SetStatus('The moves are still running. Wait for them to finish (the window closes then).', 'warn')
        }
    }.GetNewClosure())

    $btnClose.Add_Click({ $s.Form.Close() }.GetNewClosure())

    $btnGo.Add_Click({
        $s = $s   # local copy for the OnDone closure (GetNewClosure only captures local variables)
        $log = $s.Prog.Log
        $log.Clear()
        $say = { param([string]$t) $log.AppendText($t + "`r`n") }.GetNewClosure()

        if ($s.Csv.Checked) {
            $dlg = New-Object System.Windows.Forms.SaveFileDialog
            $dlg.Filter = 'CSV file (*.csv)|*.csv'; $dlg.FileName = 'Duplicates_{0:yyyyMMdd_HHmm}.csv' -f (Get-Date)
            if ($dlg.ShowDialog() -eq 'OK') {
                $n = Invoke-FmSafe -App $App -What 'Export CSV' -Action { $s.Cat.ExportDuplicatesCsv($dlg.FileName) }
                if ($null -ne $n) { & $say ("Exported {0:N0} rows to {1}" -f $n, $dlg.FileName) }
            }
        }
        if ($s.Html.Checked) {
            $dlg = New-Object System.Windows.Forms.SaveFileDialog
            $dlg.Filter = 'Web page (*.html)|*.html'; $dlg.FileName = 'FileManager_Report_{0:yyyyMMdd_HHmm}.html' -f (Get-Date)
            if ($dlg.ShowDialog() -eq 'OK') {
                [void](Invoke-FmSafe -App $App -What 'Export HTML' -Action { $s.Cat.ExportHtml($dlg.FileName, 2000) })
                & $say ("Report saved: {0}" -f $dlg.FileName)
            }
        }
        if (-not $s.Dup.Checked -and -not $s.Clean.Checked) { & $say 'Nothing to move (no move task ticked).'; return }

        $ids = New-Object System.Collections.Generic.List[long]
        $scopeFolder = $null
        if ($s.One.Checked) {
            $scopeFolder = $s.Scope.Text.Trim()
            if (-not $scopeFolder) { & $say 'Pick the folder (Browse), or choose Whole drives.'; return }
        }
        else {
            foreach ($item in $s.List.CheckedItems) { $ids.Add([long]$item.DriveId) }
            if ($ids.Count -eq 0) { & $say 'Tick at least one drive.'; return }
        }

        $plan = Invoke-FmSafe -App $App -What 'Build plan' -Action { $s.Cat.BuildPlan($s.Dup.Checked, $s.Clean.Checked, $ids.ToArray(), $s.Quick.Checked, $scopeFolder) }
        if (-not $plan) { return }
        foreach ($n in $plan.Notes) { & $say $n }
        if ($plan.BatchId -le 0) { & $say 'Nothing to move.'; return }

        $App.LogAction("Plan $($plan.BatchId) built: $($plan.DupItems) duplicate folders, $($plan.CleanItems) moves to _Clean.")
        & $say ("Plan {0} built: {1:N0} duplicate folder(s) ({2}) and {3:N0} item(s) for _Clean. Nothing has moved yet." -f $plan.BatchId, $plan.DupItems, [FileManagerEngine.Util]::Size($plan.DupBytes), $plan.CleanItems)
        Invoke-FmRefresh
        Show-FmBatchWindow -App $App -BatchId $plan.BatchId
    }.GetNewClosure())

    # Dock order: Fill (log) first, then Bottom, then Top bands from the bottom up.
    $f.Controls.Add($prog.Log)
    $f.Controls.Add($bottom)
    $f.Controls.Add($prog.Panel)
    $f.Controls.Add($list)
    $f.Controls.Add($lblDrives)
    $f.Controls.Add($scope)
    $f.Controls.Add($grp)
    $f.Controls.Add($sum)
    $f.Controls.Add($hdr)
    $f.CancelButton = $btnClose
    if ($list.Items.Count -eq 0) {
        $prog.Log.Text = "No registered drive is connected. Connect a drive and scan it first (Scan tab)."
        $btnGo.Enabled = $false
    }
    [void]$f.ShowDialog()
    $f.Dispose()
}
