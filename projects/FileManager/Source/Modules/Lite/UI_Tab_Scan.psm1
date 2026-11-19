# UI_Tab_Scan.psm1   (LITE TIER)
#
# Scan: three modes
#   Whole drive  - quick scan of a drive (names, sizes, dates - minutes), optionally the content check
#   One folder   - the same for one folder; the rest of that drive in the catalog is kept
#   Check only   - compare a folder (e.g. on a thumb drive) with the catalog; nothing is added or moved
# Stop at any time (hashes already made are kept; "Content check only" carries on). Also the
# ignore lists. After a scan the Actions window opens (if ticked); after a check, the results.

function New-FmScanTab {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Windows.Forms.TabPage]$Page,
        [Parameter(Mandatory)] $App
    )
    Set-LazyTabBuild -Page $Page -App $App -Build ${function:Build-FmScanTab}
}

function Build-FmScanTab {
    param($Page, $App)
    $Page.Padding = New-Object System.Windows.Forms.Padding(14)
    $cat = Get-FmCatalog -App $App
    $settings = Get-FmSettings -App $App

    $hdr = New-FmLabel -App $App -Text 'Scan' -Header
    $sub = New-FmLabel -App $App -Muted -Height 40 -Text ("Tip: quick-scan EVERY drive before moving anything - the best copy to keep may be on a drive you have not scanned yet." +
        [Environment]::NewLine + "A quick scan reads names and sizes only (minutes). The content check reads the files that might be duplicates (hours for terabytes).")

    $bar0 = New-FmBar -Height 34
    $rbDrive = New-Object System.Windows.Forms.RadioButton
    $rbDrive.Text = 'Whole drive'
    $rbDrive.AutoSize = $true; $rbDrive.Checked = $true; $rbDrive.Margin = New-Object System.Windows.Forms.Padding(0, 6, 24, 0)
    $rbFolder = New-Object System.Windows.Forms.RadioButton
    $rbFolder.Text = 'One folder'
    $rbFolder.AutoSize = $true; $rbFolder.Margin = New-Object System.Windows.Forms.Padding(0, 6, 24, 0)
    $rbCheck = New-Object System.Windows.Forms.RadioButton
    $rbCheck.Text = 'Check only (compare, add nothing)'
    $rbCheck.AutoSize = $true; $rbCheck.Margin = New-Object System.Windows.Forms.Padding(0, 6, 24, 0)
    $bar0.Controls.AddRange(@($rbDrive, $rbFolder, $rbCheck))

    $barF = New-FmBar
    $lblFolder = New-Object System.Windows.Forms.Label
    $lblFolder.Text = 'Folder:'; $lblFolder.AutoSize = $true; $lblFolder.Margin = New-Object System.Windows.Forms.Padding(0, 8, 6, 0)
    $txtFolder = New-Object System.Windows.Forms.TextBox
    $txtFolder.Width = 600; $txtFolder.Margin = New-Object System.Windows.Forms.Padding(0, 5, 8, 0)
    $btnBrowse = $App.Theme.MakeButton('Browse')
    $lblMode = New-Object System.Windows.Forms.Label
    $lblMode.AutoSize = $true; $lblMode.ForeColor = $App.Theme.Muted; $lblMode.Margin = New-Object System.Windows.Forms.Padding(8, 8, 0, 0)
    $barF.Controls.AddRange(@($lblFolder, $txtFolder, $btnBrowse, $lblMode))

    $bar1 = New-FmBar
    $lblDrive = New-Object System.Windows.Forms.Label
    $lblDrive.Text = 'Drive:'; $lblDrive.AutoSize = $true; $lblDrive.Margin = New-Object System.Windows.Forms.Padding(0, 8, 6, 0)
    $cbo = New-Object System.Windows.Forms.ComboBox
    $cbo.DropDownStyle = 'DropDownList'; $cbo.Width = 600; $cbo.Margin = New-Object System.Windows.Forms.Padding(0, 4, 8, 0)
    $btnDrives = $App.Theme.MakeButton('Refresh drives')
    $bar1.Controls.AddRange(@($lblDrive, $cbo, $btnDrives))

    $bar2 = New-FmBar -Height 30
    $chkContent = New-Object System.Windows.Forms.CheckBox
    $chkContent.Text = 'Full content check after the quick scan'
    $chkContent.AutoSize = $true; $chkContent.Margin = New-Object System.Windows.Forms.Padding(0, 4, 24, 0)
    $chkAll = New-Object System.Windows.Forms.CheckBox
    $chkAll.Text = 'Also hash every file whose size matches another file'
    $chkAll.AutoSize = $true; $chkAll.Margin = New-Object System.Windows.Forms.Padding(0, 4, 24, 0)
    $chkActions = New-Object System.Windows.Forms.CheckBox
    $chkActions.Text = 'Show actions when done'
    $chkActions.AutoSize = $true; $chkActions.Checked = [bool]$settings.ShowActionsAfterScan; $chkActions.Margin = New-Object System.Windows.Forms.Padding(0, 4, 0, 0)
    $bar2.Controls.AddRange(@($chkContent, $chkAll, $chkActions))

    $bar3 = New-FmBar
    $btnScan = $App.Theme.MakeButton('Start')
    $btnContent = $App.Theme.MakeButton('Content check only')
    $btnStop = $App.Theme.MakeButton('Stop')
    $btnStop.Enabled = $false
    $bar3.Controls.AddRange(@($btnScan, $btnContent, $btnStop))

    $prog = New-FmProgress -App $App

    # ---- settings ----
    $grp = New-Object System.Windows.Forms.GroupBox
    $grp.Text = 'Settings'; $grp.Dock = 'Bottom'; $grp.Height = 150
    $l1 = New-Object System.Windows.Forms.Label
    $l1.Text = 'Ignore files (wildcards, comma separated):'; $l1.AutoSize = $true; $l1.Location = New-Object System.Drawing.Point(10, 24)
    $txtFiles = New-Object System.Windows.Forms.TextBox
    $txtFiles.Location = New-Object System.Drawing.Point(300, 21); $txtFiles.Width = 900; $txtFiles.Anchor = 'Top, Left, Right'
    $txtFiles.Text = ($settings.IgnoreFiles -join ', ')
    $l2 = New-Object System.Windows.Forms.Label
    $l2.Text = 'Ignore folders (wildcards, comma separated):'; $l2.AutoSize = $true; $l2.Location = New-Object System.Drawing.Point(10, 56)
    $txtFolders = New-Object System.Windows.Forms.TextBox
    $txtFolders.Location = New-Object System.Drawing.Point(300, 53); $txtFolders.Width = 900; $txtFolders.Anchor = 'Top, Left, Right'
    $txtFolders.Text = ($settings.IgnoreFolders -join ', ')
    $l3 = New-Object System.Windows.Forms.Label
    $l3.Text = 'Smallest folder to report (KB, 0 = any):'; $l3.AutoSize = $true; $l3.Location = New-Object System.Drawing.Point(10, 88)
    $numMin = New-Object System.Windows.Forms.NumericUpDown
    $numMin.Location = New-Object System.Drawing.Point(300, 85); $numMin.Width = 110; $numMin.Minimum = 0; $numMin.Maximum = 100000000
    $numMin.Value = [decimal][Math]::Max(0, [double]$settings.MinFolderKB)
    $btnSave = $App.Theme.MakeButton('Save settings')
    $btnSave.Location = New-Object System.Drawing.Point(430, 82)
    $l4 = New-Object System.Windows.Forms.Label
    $l4.AutoSize = $true; $l4.Location = New-Object System.Drawing.Point(10, 120); $l4.ForeColor = $App.Theme.Muted
    $l4.Text = 'Leave both empty (the default) so folders only match when they are identical. Anything listed here is left out when comparing. Changes apply to the next scan.'
    $grp.Controls.AddRange(@($l1, $txtFiles, $l2, $txtFolders, $l3, $numMin, $btnSave, $l4))

    $s = @{ RbDrive = $rbDrive; RbFolder = $rbFolder; RbCheck = $rbCheck; Folder = $txtFolder; ModeLbl = $lblMode; DriveBar = $bar1; FolderBar = $barF
            Cat = $cat; Combo = $cbo; Prog = $prog; Scan = $btnScan; Content = $btnContent; Stop = $btnStop; Job = $null
            ChkContent = $chkContent; ChkAll = $chkAll; ChkActions = $chkActions; Files = $txtFiles; Folders = $txtFolders; Min = $numMin }

    $loadDrives = {
        $keep = $(if ($s.Combo.SelectedItem) { $s.Combo.SelectedItem.Key } else { '' })
        $s.Combo.Items.Clear()
        foreach ($v in $s.Cat.GetVolumes()) { if (-not $v.IsSystem) { [void]$s.Combo.Items.Add($v) } }
        for ($i = 0; $i -lt $s.Combo.Items.Count; $i++) { if ($s.Combo.Items[$i].Key -eq $keep) { $s.Combo.SelectedIndex = $i } }
        if ($s.Combo.SelectedIndex -lt 0 -and $s.Combo.Items.Count -gt 0) { $s.Combo.SelectedIndex = 0 }
    }.GetNewClosure()
    $s.LoadDrives = $loadDrives
    Register-FmRefresh -Name 'ScanDrives' -Action $loadDrives

    $setBusy = {
        param([bool]$Busy)
        $s.Scan.Enabled = -not $Busy
        $s.Content.Enabled = -not $Busy
        $s.Stop.Enabled = $Busy
    }.GetNewClosure()

    $afterJob = {
        param($job)
        & $setBusy $false
        Invoke-FmRefresh -Except 'ScanDrives'
        & $s.LoadDrives
        if ($job.Failed -or $job.Cancelled) { return }
        if ($job.Name -like 'Check *') { Show-FmCheckWindow -App $App -CheckId $job.ResultId; return }
        if (-not $s.ChkActions.Checked) { return }
        if ($s.LastFolder) { Show-FmActionsDialog -App $App -Folder $s.LastFolder } else { Show-FmActionsDialog -App $App }
    }.GetNewClosure()

    $setMode = {
        $drive = $s.RbDrive.Checked
        $s.DriveBar.Enabled = $drive
        $s.FolderBar.Enabled = -not $drive
        $s.ChkContent.Enabled = -not $s.RbCheck.Checked
        $s.ChkActions.Enabled = -not $s.RbCheck.Checked
        $s.ModeLbl.Text = $(if ($s.RbFolder.Checked) { 'Only this folder is scanned; the rest of its drive in the catalog stays as it is.' }
                           elseif ($s.RbCheck.Checked) { 'Reads every file in the folder and compares it with the catalog. Nothing is added or moved.' }
                           else { '' })
    }.GetNewClosure()
    $s.SetMode = $setMode
    foreach ($rb in @($rbDrive, $rbFolder, $rbCheck)) { $rb.Add_CheckedChanged({ & $s.SetMode }.GetNewClosure()) }

    # Other tabs (Workflow) can switch the mode: Invoke-FmHook -Name 'ScanMode' -Arg 'Check'
    Register-FmHook -Name 'ScanMode' -Action {
        param($Mode)
        switch ($Mode) { 'Folder' { $s.RbFolder.Checked = $true } 'Check' { $s.RbCheck.Checked = $true } default { $s.RbDrive.Checked = $true } }
        & $s.SetMode
    }.GetNewClosure()

    $btnBrowse.Add_Click({
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = $(if ($s.RbCheck.Checked) { 'Pick the folder to check against the catalog (for example on a thumb drive)' } else { 'Pick the folder to scan' })
        $dlg.ShowNewFolderButton = $false
        if ($s.Folder.Text) { $dlg.SelectedPath = $s.Folder.Text }
        if ($dlg.ShowDialog() -eq 'OK') { $s.Folder.Text = $dlg.SelectedPath }
    }.GetNewClosure())

    $btnDrives.Add_Click({ & $s.LoadDrives }.GetNewClosure())

    $btnScan.Add_Click({
        $s.LastFolder = $null
        if (-not $s.RbDrive.Checked) {
            $folder = $s.Folder.Text.Trim()
            if (-not $folder -or -not (Test-Path -LiteralPath $folder -PathType Container)) { $App.SetStatus('Pick a folder first (Browse).', 'warn'); return }
            if ($s.RbCheck.Checked) {
                $code = "# Check only: read every file in this folder and look it up in the catalog. Nothing is added, nothing moves.`r`n" +
                        "Get-ChildItem -LiteralPath $(Format-AppCommandValue $folder) -Recurse -Force -File |`r`n    Get-FileHash -Algorithm $($s.Cat.HashAlgorithm)`r`n" +
                        "# Files of the same size in the catalog that have no hash yet are read too, when their drive is connected."
                if (-not (Confirm-AppCommand -App $App -Title 'Check folder' -Kind Read -Code $code -Summary "Check $folder against the catalog.")) { return }
                $s.Cat.Options = New-FmOptions -App $App
                $job = Invoke-FmSafe -App $App -What 'Check folder' -Action { $s.Cat.StartCheck($folder) }
            }
            else {
                $content = $s.ChkContent.Checked
                $code = "Get-ChildItem -LiteralPath $(Format-AppCommandValue $folder) -Recurse -Force -File |`r`n    Select-Object FullName, Length, LastWriteTimeUtc" +
                        $(if ($content) { "`r`n`r`n# Content check: files in folders that might be duplicates`r`nGet-FileHash -Algorithm $($s.Cat.HashAlgorithm) -LiteralPath <each of those files>" } else { '' }) +
                        "`r`n`r`n# Read only: nothing on the drive changes. Only this folder's part of the catalog is replaced."
                if (-not (Confirm-AppCommand -App $App -Title 'Scan folder' -Kind Read -Code $code -Summary "Scan $folder.")) { return }
                $o = New-FmOptions -App $App -ContentCheck:$content -HashAllSameSize:($s.ChkAll.Checked)
                $s.LastFolder = $folder
                $job = Invoke-FmSafe -App $App -What 'Scan folder' -Action { $s.Cat.StartScanFolder($folder, $o) }
            }
            if (-not $job) { return }
            $s.Job = $job
            $s.Prog.Log.Clear()
            & $s.Prog.Reset 'Starting...'
            & $setBusy $true
            Start-FmJobWatch -App $App -Job $job -OnTick $s.Prog.Update -OnDone $afterJob
            return
        }
        $v = $s.Combo.SelectedItem
        if (-not $v) { $App.SetStatus('Connect a drive first, then click Refresh drives.', 'warn'); return }
        $content = $s.ChkContent.Checked
        $code = "Get-ChildItem -LiteralPath $(Format-AppCommandValue $v.Root) -Recurse -Force -File |`r`n    Select-Object FullName, Length, LastWriteTimeUtc"
        if ($content) {
            $code += "`r`n`r`n# Content check: every file in folders whose quick fingerprint matches another folder" +
                     $(if ($s.ChkAll.Checked) { ",`r`n# plus every file whose size matches another file" } else { '' }) +
                     ":`r`nGet-FileHash -Algorithm $($s.Cat.HashAlgorithm) -LiteralPath <each of those files>"
        }
        $code += "`r`n`r`n# Read only: nothing on the drive changes. Results go to the catalog: $($s.Cat.DbPath)"
        $summary = "Scan $($v.Letter) $($v.Label) ($($v.FileSystem), $([FileManagerEngine.Util]::Size($v.TotalBytes)))."
        if (-not (Confirm-AppCommand -App $App -Title 'Scan drive' -Kind Read -Code $code -Summary $summary)) { return }
        $o = New-FmOptions -App $App -ContentCheck:$content -HashAllSameSize:($s.ChkAll.Checked)
        $job = Invoke-FmSafe -App $App -What 'Scan drive' -Action { $s.Cat.StartScan($v.Root, $o) }
        if (-not $job) { return }
        $s.Job = $job
        $s.Prog.Log.Clear()
        & $s.Prog.Reset 'Starting the scan...'
        & $setBusy $true
        Start-FmJobWatch -App $App -Job $job -OnTick $s.Prog.Update -OnDone $afterJob
    }.GetNewClosure())

    $btnContent.Add_Click({
        $code = "# Content check of the files that might be duplicates, on every connected drive" +
                $(if ($s.ChkAll.Checked) { ",`r`n# plus every file whose size matches another file" } else { '' }) + ".`r`n" +
                "# Files already checked are skipped, so this also carries on after Stop.`r`n" +
                "Get-FileHash -Algorithm $($s.Cat.HashAlgorithm) -LiteralPath <each of those files>`r`n`r`n# Read only: nothing on the drives changes."
        if (-not (Confirm-AppCommand -App $App -Title 'Content check' -Kind Read -Code $code -Summary 'Read the files that might be duplicates and confirm which folders really match.')) { return }
        $o = New-FmOptions -App $App -ContentCheck -HashAllSameSize:($s.ChkAll.Checked)
        $job = Invoke-FmSafe -App $App -What 'Content check' -Action { $s.Cat.StartContentCheck($o) }
        if (-not $job) { return }
        $s.Job = $job
        $s.Prog.Log.Clear()
        & $s.Prog.Reset 'Starting the content check...'
        & $setBusy $true
        Start-FmJobWatch -App $App -Job $job -OnTick $s.Prog.Update -OnDone $afterJob
    }.GetNewClosure())

    $btnStop.Add_Click({
        if ($s.Job -and -not $s.Job.Finished) { $s.Job.Cancel(); $s.Prog.Phase.Text = 'Stopping after the current file...' }
    }.GetNewClosure())

    $btnSave.Add_Click({
        $split = { param([string]$t) @($t -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
        $st = Get-FmSettings -App $App
        $st.IgnoreFiles = & $split $s.Files.Text
        $st.IgnoreFolders = & $split $s.Folders.Text
        $st.MinFolderKB = [double]$s.Min.Value
        $st.ShowActionsAfterScan = $s.ChkActions.Checked
        [void](Invoke-FmSafe -App $App -What 'Save settings' -Action { Save-FmSettings -App $App -Settings $st })
        $App.SetStatus('Settings saved. They apply to the next scan and the next Find duplicates.', 'ok')
    }.GetNewClosure())

    # Dock order: Fill first, then Bottom, then Top bands from the bottom up.
    $Page.Controls.Add($prog.Log)
    $Page.Controls.Add($grp)
    $Page.Controls.Add($prog.Panel)
    $Page.Controls.Add($bar3)
    $Page.Controls.Add($bar2)
    $Page.Controls.Add($bar1)
    $Page.Controls.Add($barF)
    $Page.Controls.Add($bar0)
    $Page.Controls.Add($sub)
    $Page.Controls.Add($hdr)
    & $loadDrives
    & $setMode

    # A task started elsewhere (Duplicates, Reports) shows here too when this tab is opened later.
    if ($cat.Busy) {
        $s.Job = $cat.CurrentJob
        & $setBusy $true
        Start-FmJobWatch -App $App -Job $cat.CurrentJob -OnTick $prog.Update -OnDone $afterJob
    }
}
