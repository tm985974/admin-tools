# UI_Tab_Consolidate.psm1   (LITE TIER)
#
# Consolidate (for later, once there is room): copy a drive's _Clean folder to
# one target folder with Robocopy (never overwrites anything already there),
# verify every file by hash, then remove only the source files that verified.

function New-FmConsolidateTab {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Windows.Forms.TabPage]$Page,
        [Parameter(Mandatory)] $App
    )
    Set-LazyTabBuild -Page $Page -App $App -Build ${function:Build-FmConsolidateTab}
}

function Build-FmConsolidateTab {
    param($Page, $App)
    $Page.Padding = New-Object System.Windows.Forms.Padding(14)
    $cat = Get-FmCatalog -App $App

    $hdr = New-FmLabel -App $App -Text 'Consolidate' -Header
    $sub = New-FmLabel -App $App -Muted -Height 60 -Text ("1. Copy: Robocopy copies X:\_Clean into the target and never overwrites a file that is already there.   " +
        "2. Verify: every file is read on both sides and compared.   3. Remove: only the source files that verified are deleted; anything missing or different stays." +
        [Environment]::NewLine + "Use an NTFS target (FAT32 cannot hold files over 4 GB). Copy each drive's _Clean into the same target folder to merge them.")

    $bar1 = New-FmBar
    $l1 = New-Object System.Windows.Forms.Label
    $l1.Text = 'Source drive:'; $l1.AutoSize = $true; $l1.Margin = New-Object System.Windows.Forms.Padding(0, 8, 6, 0)
    $cbo = New-Object System.Windows.Forms.ComboBox
    $cbo.DropDownStyle = 'DropDownList'; $cbo.Width = 560; $cbo.Margin = New-Object System.Windows.Forms.Padding(0, 4, 8, 0)
    $btnDrives = $App.Theme.MakeButton('Refresh drives')
    $lblSrc = New-Object System.Windows.Forms.Label
    $lblSrc.AutoSize = $true; $lblSrc.ForeColor = $App.Theme.Muted; $lblSrc.Margin = New-Object System.Windows.Forms.Padding(8, 8, 0, 0)
    $bar1.Controls.AddRange(@($l1, $cbo, $btnDrives, $lblSrc))

    $bar2 = New-FmBar
    $l2 = New-Object System.Windows.Forms.Label
    $l2.Text = 'Target folder:'; $l2.AutoSize = $true; $l2.Margin = New-Object System.Windows.Forms.Padding(0, 8, 6, 0)
    $txtTarget = New-Object System.Windows.Forms.TextBox
    $txtTarget.Width = 560; $txtTarget.Margin = New-Object System.Windows.Forms.Padding(0, 5, 8, 0)
    $btnBrowse = $App.Theme.MakeButton('Browse')
    $lblTarget = New-Object System.Windows.Forms.Label
    $lblTarget.AutoSize = $true; $lblTarget.ForeColor = $App.Theme.Muted; $lblTarget.Margin = New-Object System.Windows.Forms.Padding(8, 8, 0, 0)
    $bar2.Controls.AddRange(@($l2, $txtTarget, $btnBrowse, $lblTarget))

    $bar3 = New-FmBar
    $btnCopy = $App.Theme.MakeButton('Copy with Robocopy')
    $btnVerify = $App.Theme.MakeButton('Verify copy')
    $btnRemove = $App.Theme.MakeButton('Remove verified source files')
    $btnStop = $App.Theme.MakeButton('Stop')
    $btnStop.Enabled = $false
    $bar3.Controls.AddRange(@($btnCopy, $btnVerify, $btnRemove, $btnStop))

    $prog = New-FmProgress -App $App -LogHeight 100

    $split = New-Object System.Windows.Forms.SplitContainer
    $split.Orientation = 'Horizontal'; $split.Size = New-Object System.Drawing.Size(1600, 600); $split.SplitterDistance = 170; $split.Dock = 'Fill'
    $gRuns = New-FmGrid -App $App -Columns @('Run', 'Source', 'Target', 'Started', 'Finished', 'Status', 'Match', 'Missing', 'Different', 'Errors', 'Removed') `
        -Weights @(40, 220, 220, 120, 120, 70, 70, 60, 65, 55, 65)
    $gProblems = New-FmGrid -App $App -Columns @('File (inside the source)', 'Size', 'Result', 'Note') -Weights @(520, 80, 80, 300)
    $split.Panel1.Controls.Add($gRuns)
    $split.Panel2.Controls.Add($gProblems)

    $s = @{ Cat = $cat; Combo = $cbo; Target = $txtTarget; SrcLbl = $lblSrc; TgtLbl = $lblTarget; Prog = $prog; Runs = $gRuns; Problems = $gProblems
            Job = $null; Stop = $btnStop; Buttons = @($btnCopy, $btnVerify, $btnRemove) }

    $source = {
        $v = $s.Combo.SelectedItem
        if (-not $v) { return $null }
        return ($v.Root + '_Clean')
    }.GetNewClosure()
    $s.Source = $source

    $target = {
        $t = $s.Target.Text.Trim()
        if (-not $t) { return $null }
        if ($t.Length -gt 3) { $t = $t.TrimEnd('\') }
        return $t
    }.GetNewClosure()
    $s.TargetPath = $target

    $showInfo = {
        $src = & $s.Source
        $s.SrcLbl.Text = $(if (-not $src) { '' } elseif (Test-Path -LiteralPath $src) { "Source: $src" } else { "No $src on this drive yet." })
        $t = & $s.TargetPath
        $s.TgtLbl.Text = ''
        if ($t -and $t.Length -ge 2 -and $t[1] -eq ':') {
            try {
                $di = New-Object System.IO.DriveInfo($t.Substring(0, 1))
                if ($di.IsReady) {
                    $s.TgtLbl.Text = '{0} - {1} free{2}' -f $di.DriveFormat, [FileManagerEngine.Util]::Size($di.AvailableFreeSpace), $(if ($di.DriveFormat -ne 'NTFS') { '  - not NTFS: files over 4 GB may not fit (FAT32)' } else { '' })
                }
                else { $s.TgtLbl.Text = 'Drive not ready.' }
            } catch { }
        }
    }.GetNewClosure()

    $loadDrives = {
        $s.Combo.Items.Clear()
        foreach ($v in $s.Cat.GetVolumes()) { if (-not $v.IsSystem -and $v.DriveId -gt 0) { [void]$s.Combo.Items.Add($v) } }
        if ($s.Combo.Items.Count -gt 0) { $s.Combo.SelectedIndex = 0 }
        & $showInfo
    }.GetNewClosure()

    $fillProblems = {
        $s.Problems.Rows.Clear()
        $r = Get-FmSelected -Grid $s.Runs
        if (-not $r) { return }
        foreach ($p in $s.Cat.GetVerifyProblems($r.Id, 20000)) { [void]$s.Problems.Rows.Add($p.Rel, [FileManagerEngine.Util]::Size($p.Size), $p.Status, $p.Note) }
    }.GetNewClosure()

    $refresh = {
        $s.Runs.Rows.Clear()
        foreach ($r in $s.Cat.GetVerifyRuns(200)) {
            $i = $s.Runs.Rows.Add($r.Id, $r.Source, $r.Target, $r.Started, $r.Finished, $r.Status, $r.Ok.ToString('N0'), $r.Missing, $r.Different, $r.Errors, $r.Removed.ToString('N0'))
            $s.Runs.Rows[$i].Tag = $r
        }
        & $fillProblems
    }.GetNewClosure()
    Register-FmRefresh -Name 'Consolidate' -Action { & $loadDrives; & $refresh }.GetNewClosure()

    $setBusy = {
        param([bool]$Busy)
        foreach ($b in $s.Buttons) { $b.Enabled = -not $Busy }
        $s.Stop.Enabled = $Busy
    }.GetNewClosure()

    $startJob = {
        param($Job, [string]$Text)
        if (-not $Job) { return }
        $setBusy = $setBusy   # local copy: GetNewClosure below only captures local variables
        $s.Job = $Job
        $s.Prog.Log.Clear()
        & $s.Prog.Reset $Text
        & $setBusy $true
        Start-FmJobWatch -App $App -Job $Job -OnTick $s.Prog.Update -OnDone { param($j) & $setBusy $false; Invoke-FmRefresh }.GetNewClosure()
    }.GetNewClosure()

    $cbo.Add_SelectedIndexChanged({ & $showInfo }.GetNewClosure())
    $txtTarget.Add_Leave({ & $showInfo }.GetNewClosure())
    $gRuns.Add_SelectionChanged({ & $fillProblems }.GetNewClosure())
    $btnDrives.Add_Click({ & $loadDrives }.GetNewClosure())
    $btnStop.Add_Click({ if ($s.Job -and -not $s.Job.Finished) { $s.Job.Cancel(); $s.Prog.Phase.Text = 'Stopping after the current file...' } }.GetNewClosure())

    $btnBrowse.Add_Click({
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = 'Pick (or make) the target folder, for example T:\_Clean'
        $dlg.ShowNewFolderButton = $true
        if ($dlg.ShowDialog() -eq 'OK') { $s.Target.Text = $dlg.SelectedPath; & $showInfo }
    }.GetNewClosure())

    # Checks shared by the three steps; returns @(source, target) or $null.
    $check = {
        $src = & $s.Source
        $t = & $s.TargetPath
        if (-not $src) { $App.SetStatus('Pick a source drive first.', 'warn'); return $null }
        if (-not (Test-Path -LiteralPath $src)) { $App.SetStatus("$src does not exist: clean that drive first (Actions).", 'warn'); return $null }
        if (-not $t) { $App.SetStatus('Pick a target folder first.', 'warn'); return $null }
        if ($t.Substring(0, 1) -eq $src.Substring(0, 1)) { $App.SetStatus('The target must be on a different drive than the source.', 'warn'); return $null }
        return @($src, $t)
    }.GetNewClosure()

    $btnCopy.Add_Click({
        $p = & $check
        if (-not $p) { return }
        $src = $p[0]; $t = $p[1]
        $tArg = $(if ($t.Length -eq 2) { $t + '\.' } elseif ($t.EndsWith('\')) { $t + '.' } else { $t })
        $logDir = Join-Path ([string]$App.DataRoot) 'Logs'
        $log = Join-Path $logDir ('Robocopy_{0}_{1:yyyyMMdd_HHmmss}.log' -f $src.Substring(0, 1), (Get-Date))
        $argList = @(('"{0}"' -f $src), ('"{0}"' -f $tArg), '/E', '/COPY:DAT', '/DCOPY:T', '/XC', '/XN', '/XO', '/XJ', '/R:2', '/W:5', '/MT:8', '/NP', '/TEE', ('/LOG+:"{0}"' -f $log))
        $code = 'Start-Process -FilePath ''robocopy.exe'' -ArgumentList ' + (Format-AppCommandValue $argList)
        $r = Invoke-AppCommand -App $App -Title 'Copy with Robocopy' -Kind Change -Code $code -RunLabel 'Copy' `
            -Summary "Copy $src into $t in a Robocopy window. Existing files in the target are never overwritten (/XC /XN /XO). The source is not changed. Log: $log"
        if ($r.Ran -and $r.Errors.Count -eq 0) {
            $App.LogAction("Robocopy started: $src -> $t")
            $App.SetStatus('Robocopy is running in its own window. When it has finished, click Verify copy.', 'ok')
        }
        elseif ($r.Errors.Count -gt 0) { $App.SetStatus("Robocopy did not start: $($r.Errors[0])", 'err') }
    }.GetNewClosure())

    $btnVerify.Add_Click({
        $p = & $check
        if (-not $p) { return }
        $code = "# Compare every file under the source with the same file under the target (read only).`r`n" +
                "`$source = $(Format-AppCommandValue $p[0])`r`n`$target = $(Format-AppCommandValue $p[1])`r`n" +
                "Get-ChildItem -LiteralPath `$source -Recurse -File -Force | ForEach-Object {`r`n" +
                "    `$t = Join-Path `$target `$_.FullName.Substring(`$source.Length)`r`n" +
                "    (Get-FileHash -LiteralPath `$_.FullName -Algorithm $($s.Cat.HashAlgorithm)).Hash -eq (Get-FileHash -LiteralPath `$t -Algorithm $($s.Cat.HashAlgorithm)).Hash`r`n}"
        if (-not (Confirm-AppCommand -App $App -Title 'Verify copy' -Kind Read -Code $code -Summary "Read every file in $($p[0]) and its copy in $($p[1]).")) { return }
        & $startJob (Invoke-FmSafe -App $App -What 'Verify copy' -Action { $s.Cat.StartVerifyCopy($p[0], $p[1]) }) 'Verifying...'
    }.GetNewClosure())

    $btnRemove.Add_Click({
        $r = Get-FmSelected -Grid $s.Runs
        if (-not $r) { $App.SetStatus('Select a finished verify run in the list first.', 'warn'); return }
        if ($r.Status -ne 'done') { $App.SetStatus("Verify run $($r.Id) did not finish ($($r.Status)). Run Verify copy again.", 'warn'); return }
        if ($r.Ok -le $r.Removed) { $App.SetStatus("Nothing left to remove for verify run $($r.Id).", 'info'); return }
        if (-not (Confirm-AppCommand -App $App -Title 'Remove verified source files' -Kind Change -Always -Code $s.Cat.RemoveVerifiedScript($r.Id) -RunLabel 'Remove' `
                -Summary ("PERMANENTLY delete the {0:N0} files in {1} that verified identical in {2}. Missing, different and unreadable files stay. This cannot be undone." -f ($r.Ok - $r.Removed), $r.Source, $r.Target))) { return }
        $App.LogAction("Remove verified source files: run $($r.Id), $($r.Source).")
        & $startJob (Invoke-FmSafe -App $App -What 'Remove verified source files' -Action { $s.Cat.StartRemoveVerified($r.Id) }) 'Removing verified files...'
    }.GetNewClosure())

    $Page.Controls.Add($split)
    $Page.Controls.Add($prog.Log)
    $Page.Controls.Add($prog.Panel)
    $Page.Controls.Add($bar3)
    $Page.Controls.Add($bar2)
    $Page.Controls.Add($bar1)
    $Page.Controls.Add($sub)
    $Page.Controls.Add($hdr)
    & $loadDrives
    & $refresh
}
