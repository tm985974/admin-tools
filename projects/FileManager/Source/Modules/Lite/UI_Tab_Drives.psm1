# UI_Tab_Drives.psm1   (LITE TIER)
#
# Drives: every drive the catalog knows (connected or not), its priority for
# keeping copies, register a connected drive, health check, forget a drive.

function New-FmDrivesTab {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Windows.Forms.TabPage]$Page,
        [Parameter(Mandatory)] $App
    )
    Set-LazyTabBuild -Page $Page -App $App -Build ${function:Build-FmDrivesTab}
}

function Build-FmDrivesTab {
    param($Page, $App)
    $Page.Padding = New-Object System.Windows.Forms.Padding(14)
    $cat = Get-FmCatalog -App $App

    $hdr = New-FmLabel -App $App -Text 'Drives' -Header
    $sub = New-FmLabel -App $App -Muted -Height 40 -Text ("Every drive in the catalog. Drives are recognised by their serial number, so a changed drive letter does not matter." +
        [Environment]::NewLine + "Priority: when two copies are otherwise equal, the copy on the drive with the LOWER number is kept.")

    # ---- register a connected drive ----
    $bar1 = New-FmBar
    $lblNew = New-Object System.Windows.Forms.Label
    $lblNew.Text = 'Connected drive:'; $lblNew.AutoSize = $true; $lblNew.Margin = New-Object System.Windows.Forms.Padding(0, 8, 6, 0)
    $cboNew = New-Object System.Windows.Forms.ComboBox
    $cboNew.DropDownStyle = 'DropDownList'; $cboNew.Width = 560; $cboNew.Margin = New-Object System.Windows.Forms.Padding(0, 4, 8, 0)
    $btnRegister = $App.Theme.MakeButton('Register drive')
    $btnRefresh = $App.Theme.MakeButton('Refresh')
    $bar1.Controls.AddRange(@($lblNew, $cboNew, $btnRegister, $btnRefresh))

    # ---- actions on the selected drive ----
    $bar2 = New-FmBar
    $lblPrio = New-Object System.Windows.Forms.Label
    $lblPrio.Text = 'Priority:'; $lblPrio.AutoSize = $true; $lblPrio.Margin = New-Object System.Windows.Forms.Padding(0, 8, 6, 0)
    $numPrio = New-Object System.Windows.Forms.NumericUpDown
    $numPrio.Minimum = 1; $numPrio.Maximum = 99; $numPrio.Width = 60; $numPrio.Margin = New-Object System.Windows.Forms.Padding(0, 5, 8, 0)
    $btnPrio = $App.Theme.MakeButton('Set priority')
    $btnHealth = $App.Theme.MakeButton('Health check')
    $btnOpen = $App.Theme.MakeButton('Open drive')
    $btnForget = $App.Theme.MakeButton('Forget drive')
    $btnFresh = $App.Theme.MakeButton('Start fresh')
    $btnFresh.Margin = New-Object System.Windows.Forms.Padding(40, 3, 3, 3)
    $bar2.Controls.AddRange(@($lblPrio, $numPrio, $btnPrio, $btnHealth, $btnOpen, $btnForget, $btnFresh))

    $grid = New-FmGrid -App $App -Columns @('Priority', 'Drive', 'Label', 'Format', 'Size', 'Free', 'Folders', 'Files', 'Data', 'Content-checked files', 'Last scan', 'Status') `
        -Weights @(55, 50, 150, 60, 70, 70, 70, 80, 80, 110, 120, 220)

    $foot = New-FmLabel -App $App -Muted -Height 24
    $foot.Dock = 'Bottom'

    $s = @{ Cat = $cat; Grid = $grid; Combo = $cboNew; Foot = $foot; Num = $numPrio }

    $refresh = {
        $s.Grid.Rows.Clear()
        foreach ($d in $s.Cat.GetDrives()) {
            $status = $(if ($d.NeedsRescan) { 'Needs a new quick scan' } elseif ($d.Connected) { 'Connected' } else { 'Not connected' })
            if (-not $d.LastScan) { $status += ' - not scanned yet' }
            $i = $s.Grid.Rows.Add($d.Priority, $d.Letter, $d.Label, $d.FileSystem, [FileManagerEngine.Util]::Size($d.TotalBytes), [FileManagerEngine.Util]::Size($d.FreeBytes),
                $d.Folders.ToString('N0'), $d.Files.ToString('N0'), [FileManagerEngine.Util]::Size($d.Bytes), $d.Hashed.ToString('N0'), $d.LastScan, $status)
            $s.Grid.Rows[$i].Tag = $d
            if (-not $d.Connected) { $s.Grid.Rows[$i].DefaultCellStyle.ForeColor = [System.Drawing.Color]::Gray }
            if ($d.NeedsRescan) { $s.Grid.Rows[$i].DefaultCellStyle.ForeColor = [System.Drawing.Color]::DarkOrange }
        }
        $s.Combo.Items.Clear()
        foreach ($v in $s.Cat.GetVolumes()) { if (-not $v.IsSystem) { [void]$s.Combo.Items.Add($v) } }
        if ($s.Combo.Items.Count -gt 0) { $s.Combo.SelectedIndex = 0 }
        $s.Foot.Text = $s.Cat.Stats()
    }.GetNewClosure()
    $s.Refresh = $refresh
    Register-FmRefresh -Name 'Drives' -Action $refresh

    $grid.Add_SelectionChanged({
        $d = Get-FmSelected -Grid $s.Grid
        if ($d) { $s.Num.Value = [Math]::Min(99, [Math]::Max(1, $d.Priority)) }
    }.GetNewClosure())

    $btnRefresh.Add_Click({ & $s.Refresh }.GetNewClosure())

    $btnRegister.Add_Click({
        $v = $s.Combo.SelectedItem
        if (-not $v) { $App.SetStatus('Connect a drive first.', 'warn'); return }
        $id = Invoke-FmSafe -App $App -What 'Register drive' -Action { $s.Cat.Register($v.Root) }
        if ($id) { $App.SetStatus("Registered $($v.Letter) $($v.Label). Scan it on the Scan tab.", 'ok'); Invoke-FmRefresh }
    }.GetNewClosure())

    $btnPrio.Add_Click({
        $d = Get-FmSelected -Grid $s.Grid
        if (-not $d) { $App.SetStatus('Select a drive in the list first.', 'warn'); return }
        $s.Cat.SetPriority($d.Id, [long]$s.Num.Value)
        $App.LogAction("Drive $($d.Label) [$($d.Serial)] priority set to $($s.Num.Value).")
        $App.SetStatus("Priority of $($d.Label) set to $($s.Num.Value). Click Find duplicates on the Duplicates tab to use it.", 'ok')
        Invoke-FmRefresh
    }.GetNewClosure())

    $healthCode = {
        "Get-PhysicalDisk | Select-Object FriendlyName, BusType, MediaType, HealthStatus, OperationalStatus, @{ Name = 'SizeGB'; Expression = { [math]::Round(`$_.Size / 1GB) } } | Format-Table -AutoSize | Out-String -Width 220"
    }
    Register-AppCommand -App $App -Control $btnHealth -Title 'Health check' -Code $healthCode
    $btnHealth.Add_Click({
        $r = Invoke-AppCommand -App $App -Title 'Health check' -Kind Read -Code (& $healthCode)
        if (-not $r.Ran) { return }
        $text = (@($r.Output) | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
        if ($r.Errors.Count -gt 0) { $text += [Environment]::NewLine + 'Errors: ' + ($r.Errors -join '; ') }
        Show-FmText -App $App -Title 'Health check' -Text $text -Note ("'Healthy' means Windows sees no problem. Many USB enclosures hide the drive's own health data (SMART), so an old drive can still fail: " +
            "copy anything irreplaceable off it before long scans, and stop if you hear clicking or see read errors in the scan log.")
    }.GetNewClosure())

    $btnOpen.Add_Click({
        $d = Get-FmSelected -Grid $s.Grid
        if (-not $d) { $App.SetStatus('Select a drive in the list first.', 'warn'); return }
        if (-not $d.Connected) { $App.SetStatus("$($d.Label) is not connected.", 'warn'); return }
        Open-FmFolder -App $App -Path ($d.Letter + '\')
    }.GetNewClosure())

    $btnForget.Add_Click({
        $d = Get-FmSelected -Grid $s.Grid
        if (-not $d) { $App.SetStatus('Select a drive in the list first.', 'warn'); return }
        $msg = "Remove $($d.Letter) $($d.Label) and its $($d.Files.ToString('N0')) files from the catalog?`r`n`r`nNothing on the drive changes. Scan it again to bring it back."
        $ans = [System.Windows.Forms.MessageBox]::Show($msg, 'Forget drive', 'YesNo', 'Question')   # not-a-command: removes catalog rows only, nothing on disk
        if ($ans -ne 'Yes') { return }
        [void](Invoke-FmSafe -App $App -What 'Forget drive' -Action { $s.Cat.ForgetDrive($d.Id) })
        $App.LogAction("Drive $($d.Label) [$($d.Serial)] removed from the catalog.")
        Invoke-FmRefresh
    }.GetNewClosure())

    $btnFresh.Add_Click({
        if ($s.Cat.Busy) { $App.SetStatus('Wait for the running task to finish first.', 'warn'); return }
        $msg = "Start fresh: empty the catalog - every drive, scan, file hash and duplicate group.`r`nNothing on any drive changes.`r`n`r`n" +
               "Keep the history of your batches (moves already made)?`r`n`r`n" +
               "Yes  = keep it (recommended if anything was moved: Undo and Delete duplicates keep working after you scan again)`r`n" +
               "No   = clear everything, history too`r`nCancel = do nothing"
        $ans = [System.Windows.Forms.MessageBox]::Show($msg, 'Start fresh', 'YesNoCancel', 'Warning')   # not-a-command: empties the app's own catalog, nothing on disk
        if ($ans -eq 'Cancel') { return }
        $keep = ($ans -eq 'Yes')
        if (-not $keep) {
            $ans2 = [System.Windows.Forms.MessageBox]::Show("Clear everything, including the batch history?`r`n`r`nFolders already moved to _Duplicates or _Clean stay where they are, but this tool can no longer undo those moves or delete those duplicates for you.", 'Start fresh', 'YesNo', 'Warning')   # not-a-command: empties the app's own catalog, nothing on disk
            if ($ans2 -ne 'Yes') { return }
        }
        [void](Invoke-FmSafe -App $App -What 'Start fresh' -Action { $s.Cat.Reset($keep) })
        $App.LogAction("Start fresh: catalog emptied (batch history $(if ($keep) { 'kept' } else { 'cleared' })).")
        $App.SetStatus('The catalog is empty. Scan your drives again (Scan tab).', 'ok')
        Invoke-FmRefresh
    }.GetNewClosure())

    # Dock order: Fill first, then Bottom, then the Top bands (last added = top-most).
    $Page.Controls.Add($grid)
    $Page.Controls.Add($foot)
    $Page.Controls.Add($bar2)
    $Page.Controls.Add($bar1)
    $Page.Controls.Add($sub)
    $Page.Controls.Add($hdr)
    & $refresh
}
