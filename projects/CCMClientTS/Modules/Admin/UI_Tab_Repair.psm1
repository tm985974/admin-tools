# UI_Tab_Repair.psm1   (ADMIN TIER)
#
# Repair Steps tab: the full step table in working order. Each row shows
# whether Discovery recommends it, whether it needs a reboot, and its saved
# status on this computer (kept across reboots). Select a step, read what it
# does, run it; long tools open in their own console window and the result is
# written back to the table. One step runs at a time.

function New-CcmRepairTab {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Windows.Forms.TabPage]$Page,
        [Parameter(Mandatory)] $App
    )
    if (-not (Register-AppRequirement -App $App -Page $Page -For 'Repair Steps' -Command 'dism.exe' -Hint 'DISM is part of Windows; the tool must run on Windows 10 / 11.')) { return }

    Set-LazyTabBuild -Page $Page -App $App -Build {
        param($Page, $App)
        $Th = $App.Theme
        $cfg = Get-CcmTSConfig -App $App
        $ui = @{ Catalog = @(Get-CcmStepCatalog); Rows = @(); Busy = $false; Running = '' }

        # ---------------- header + info
        $hdr = New-Object System.Windows.Forms.Label
        $hdr.Text = 'Repair Steps - work top to bottom; run discovery between steps'; $hdr.Dock = 'Top'
        Set-HeaderStyle -App $App -Label $hdr; $hdr.AutoSize = $false; $hdr.Height = 34

        $info = New-Object System.Windows.Forms.Panel
        $info.Dock = 'Top'; $info.Height = 66; $info.BackColor = $Th.Header; $info.Padding = New-Object System.Windows.Forms.Padding(10, 6, 10, 4)
        $lblState = New-Object System.Windows.Forms.Label; $lblState.Dock = 'Top'; $lblState.Height = 20; $lblState.Font = New-AppFont -App $App -Style ([System.Drawing.FontStyle]::Bold)
        $lblGate = New-Object System.Windows.Forms.Label; $lblGate.Dock = 'Top'; $lblGate.Height = 20
        $lblJob = New-Object System.Windows.Forms.Label; $lblJob.Dock = 'Top'; $lblJob.Height = 20; $lblJob.ForeColor = $Th.Section
        $info.Controls.Add($lblJob); $info.Controls.Add($lblGate); $info.Controls.Add($lblState)

        # ---------------- toolbar 1
        $bar1 = New-Object System.Windows.Forms.FlowLayoutPanel
        $bar1.Dock = 'Top'; $bar1.Height = 38; $bar1.WrapContents = $false; $bar1.Padding = New-Object System.Windows.Forms.Padding(0, 4, 0, 0)
        $btnScan = $Th.MakeButton('Run discovery')
        $chkDeep = New-Object System.Windows.Forms.CheckBox; $chkDeep.Text = 'Deep'; $chkDeep.AutoSize = $true; $chkDeep.Margin = New-Object System.Windows.Forms.Padding(4, 8, 14, 0)
        $btnNext = $Th.MakeButton('Select next recommended')
        $btnRun = $Th.MakeButton('Run selected step')
        $btnRun.Font = New-AppFont -App $App -Style ([System.Drawing.FontStyle]::Bold)
        $btnDone = $Th.MakeButton('Mark done')
        $btnClear = $Th.MakeButton('Clear status')
        $btnReset = $Th.MakeButton('Clear all statuses')
        $btnLog = $Th.MakeButton('Open related log')
        $btnReboot = $Th.MakeButton('Reboot now...')
        $bar1.Controls.AddRange(@($btnScan, $chkDeep, $btnNext, $btnRun, $btnDone, $btnClear, $btnReset, $btnLog, $btnReboot))

        # ---------------- toolbar 2: repair source + install options
        $bar2 = New-Object System.Windows.Forms.FlowLayoutPanel
        $bar2.Dock = 'Top'; $bar2.Height = 36; $bar2.WrapContents = $false
        $l1 = New-Object System.Windows.Forms.Label; $l1.Text = 'DISM repair source:'; $l1.AutoSize = $true; $l1.Margin = New-Object System.Windows.Forms.Padding(2, 9, 2, 0)
        $txtSrc = New-Object System.Windows.Forms.TextBox; $txtSrc.Width = 330; $txtSrc.Margin = New-Object System.Windows.Forms.Padding(2, 6, 8, 0); $txtSrc.Text = $cfg.RepairSource
        $l2 = New-Object System.Windows.Forms.Label; $l2.Text = 'Healthy PC:'; $l2.AutoSize = $true; $l2.Margin = New-Object System.Windows.Forms.Padding(6, 9, 2, 0)
        $txtPc = New-Object System.Windows.Forms.TextBox; $txtPc.Width = 150; $txtPc.Margin = New-Object System.Windows.Forms.Padding(2, 6, 4, 0)
        $btnUsePc = $Th.MakeButton('Use PC')
        $btnTest = $Th.MakeButton('Test source')
        $chkReset = New-Object System.Windows.Forms.CheckBox; $chkReset.Text = 'Install: RESETKEYINFORMATION=TRUE'; $chkReset.AutoSize = $true; $chkReset.Margin = New-Object System.Windows.Forms.Padding(24, 9, 8, 0)
        $chkForce = New-Object System.Windows.Forms.CheckBox; $chkForce.Text = 'Install: /forceinstall'; $chkForce.AutoSize = $true; $chkForce.Margin = New-Object System.Windows.Forms.Padding(6, 9, 8, 0)
        $bar2.Controls.AddRange(@($l1, $txtSrc, $l2, $txtPc, $btnUsePc, $btnTest, $chkReset, $chkForce))

        # ---------------- filter bar
        $bar3 = New-Object System.Windows.Forms.FlowLayoutPanel
        $bar3.Dock = 'Top'; $bar3.Height = 32; $bar3.WrapContents = $false
        $lf = New-Object System.Windows.Forms.Label; $lf.Text = 'Filter:'; $lf.AutoSize = $true; $lf.Margin = New-Object System.Windows.Forms.Padding(2, 7, 2, 0)
        $box = New-Object System.Windows.Forms.TextBox; $box.Width = 220; $box.Margin = New-Object System.Windows.Forms.Padding(2, 4, 6, 0)
        $count = New-Object System.Windows.Forms.Label; $count.AutoSize = $true; $count.ForeColor = $Th.Muted; $count.Margin = New-Object System.Windows.Forms.Padding(4, 7, 8, 0)
        $hint = New-Object System.Windows.Forms.Label; $hint.AutoSize = $true; $hint.ForeColor = $Th.Muted; $hint.Margin = New-Object System.Windows.Forms.Padding(4, 7, 0, 0)
        $hint.Text = (Get-FilterHintText) + '   Try: dism   client*   reboot   next'
        $bar3.Controls.AddRange(@($lf, $box, $count, $hint))

        # ---------------- grid + details/output split
        $split = New-Object System.Windows.Forms.SplitContainer
        $split.Dock = 'Fill'; $split.Orientation = 'Horizontal'

        $grid = New-Object System.Windows.Forms.DataGridView
        $grid.Dock = 'Fill'
        $grid.ReadOnly = $true; $grid.AllowUserToAddRows = $false; $grid.AllowUserToDeleteRows = $false; $grid.AllowUserToResizeRows = $false
        $grid.RowHeadersVisible = $false; $grid.MultiSelect = $false; $grid.SelectionMode = 'FullRowSelect'
        $grid.BackgroundColor = $Th.Surface; $grid.BorderStyle = 'FixedSingle'; $grid.GridColor = $Th.Border
        $grid.EnableHeadersVisualStyles = $false
        $grid.ColumnHeadersDefaultCellStyle.BackColor = $Th.Header; $grid.ColumnHeadersDefaultCellStyle.ForeColor = $Th.Title
        $grid.DefaultCellStyle.SelectionBackColor = $Th.Select; $grid.DefaultCellStyle.SelectionForeColor = $Th.Text
        foreach ($c in @(@('Order', '#', 34), @('Phase', 'Phase', 130), @('Title', 'Step', 420), @('Next', 'Recommended', 96), @('Kind', 'Runs as', 62), @('Reboot', 'Reboot', 86),
                         @('Risk', 'Risk', 60), @('Status', 'Status', 100), @('LastRun', 'Last run', 118), @('Result', 'Result', 520))) {
            $i = $grid.Columns.Add($c[0], $c[1]); $grid.Columns[$i].Width = $c[2]
        }
        $grid.Columns['Result'].AutoSizeMode = 'Fill'
        $split.Panel1.Controls.Add($grid)

        $split2 = New-Object System.Windows.Forms.SplitContainer
        $split2.Dock = 'Fill'; $split2.Orientation = 'Vertical'
        $txtDetail = New-Object System.Windows.Forms.TextBox
        $txtDetail.Dock = 'Fill'; $txtDetail.Multiline = $true; $txtDetail.ReadOnly = $true; $txtDetail.ScrollBars = 'Vertical'; $txtDetail.BackColor = $Th.Surface
        $txtDetail.Font = New-Object System.Drawing.Font($Th.FontName, $Th.FontSizePt)
        $txtOut = New-Object System.Windows.Forms.TextBox
        $txtOut.Dock = 'Fill'; $txtOut.Multiline = $true; $txtOut.ReadOnly = $true; $txtOut.ScrollBars = 'Both'; $txtOut.WordWrap = $false; $txtOut.BackColor = $Th.Surface
        $txtOut.Font = New-Object System.Drawing.Font($Th.MonoFontName, $Th.FontSizePt)
        $lblD = New-Object System.Windows.Forms.Label; $lblD.Text = 'What the selected step does'; $lblD.Dock = 'Top'; $lblD.Height = 20; Set-SectionStyle -App $App -Label $lblD; $lblD.AutoSize = $false
        $lblO = New-Object System.Windows.Forms.Label; $lblO.Text = 'Output'; $lblO.Dock = 'Top'; $lblO.Height = 20; Set-SectionStyle -App $App -Label $lblO; $lblO.AutoSize = $false
        $split2.Panel1.Controls.Add($txtDetail); $split2.Panel1.Controls.Add($lblD)
        $split2.Panel2.Controls.Add($txtOut); $split2.Panel2.Controls.Add($lblO)
        $split.Panel2.Controls.Add($split2)

        $Page.Controls.Add($split); $Page.Controls.Add($bar3); $Page.Controls.Add($bar2); $Page.Controls.Add($bar1); $Page.Controls.Add($info); $Page.Controls.Add($hdr)

        # splitter positions once the page has its real size
        $sizer = New-Object System.Windows.Forms.Timer; $sizer.Interval = 150
        $sizer.Add_Tick({
            $sizer.Stop(); $sizer.Dispose()
            try { if ($split.Height -gt 300) { $split.SplitterDistance = [int]($split.Height * 0.55) } } catch { }
            try { if ($split2.Width -gt 600) { $split2.SplitterDistance = [int]($split2.Width * 0.42) } } catch { }
        }.GetNewClosure())
        $sizer.Start()

        # ---------------- data + rendering
        $recBack = [System.Drawing.Color]::FromArgb(255, 249, 214)
        $statusColor = @{
            'Done'          = [System.Drawing.Color]::FromArgb(20, 110, 40)
            'Done - reboot' = [System.Drawing.Color]::FromArgb(20, 110, 40)
            'Warning'       = [System.Drawing.Color]::FromArgb(150, 90, 0)
            'Failed'        = [System.Drawing.Color]::FromArgb(170, 20, 20)
            'Skipped'       = [System.Drawing.Color]::FromArgb(108, 118, 130)
            'Running'       = [System.Drawing.Color]::FromArgb(28, 92, 168)
        }
        $build = {
            $prog = Get-CcmStepProgress -App $App
            $d = (Get-CcmTSState).Discovery
            $rec = @(); if ($d) { $rec = @($d.Recommended) }
            $ui.Rows = @(foreach ($s in $ui.Catalog) {
                $p = $(if ($prog.ContainsKey($s.Id)) { $prog[$s.Id] } else { $null })
                $status = $(if ($ui.Running -eq $s.Id) { 'Running' } elseif ($p) { $p.Status } else { '' })
                $ix = [array]::IndexOf($rec, $s.Id)
                [pscustomobject]@{
                    Id = $s.Id; Order = $s.Order; Phase = $s.Phase; Title = $s.Title
                    Next = $(if ($ix -ge 0) { "next #$($ix + 1)" } else { '' })
                    Kind = $s.Kind; Reboot = $s.Reboot; Risk = $s.Risk
                    Status = $status; LastRun = $(if ($p) { $p.LastRun } else { '' }); Result = $(if ($p) { $p.Result } else { '' })
                }
            })
        }.GetNewClosure()

        $cols = @('Phase', 'Title', 'Next', 'Kind', 'Reboot', 'Risk', 'Status', 'Result')
        $onFilter = {
            param($Regex, $Text)
            $selId = ''; if ($grid.SelectedRows.Count -gt 0) { $selId = [string]$grid.SelectedRows[0].Tag }
            $rows = @(Select-FilterMatch -Items $ui.Rows -Regex $Regex -Property $cols)
            $grid.SuspendLayout()
            try {
                $grid.Rows.Clear()
                foreach ($r in $rows) {
                    $ix = $grid.Rows.Add($r.Order, $r.Phase, $r.Title, $r.Next, $r.Kind, $r.Reboot, $r.Risk, $r.Status, $r.LastRun, $r.Result)
                    $row = $grid.Rows[$ix]; $row.Tag = $r.Id
                    if ($r.Next) { $row.DefaultCellStyle.BackColor = $recBack; $row.Cells['Next'].Style.Font = New-AppFont -App $App -Style ([System.Drawing.FontStyle]::Bold) }
                    if ($statusColor.ContainsKey($r.Status)) { $row.Cells['Status'].Style.ForeColor = $statusColor[$r.Status]; $row.Cells['Status'].Style.Font = New-AppFont -App $App -Style ([System.Drawing.FontStyle]::Bold) }
                }
                if ($selId) { foreach ($row in $grid.Rows) { if ([string]$row.Tag -eq $selId) { $row.Selected = $true; break } } }
            } finally { $grid.ResumeLayout() }
            $count.Text = '{0} of {1} steps' -f $rows.Count, @($ui.Rows).Count
        }.GetNewClosure()
        $filter = Register-ListFilter -App $App -TextBox $box -OnFilter $onFilter

        $refreshInfo = {
            $d = (Get-CcmTSState).Discovery
            if ($d) {
                $lblState.Text = "Discovery $($d.Time.ToString('HH:mm:ss')): $($d.State) - $($d.StateDetail)"
                $lblState.ForeColor = $(switch ($d.StateLevel) { 'OK' { [System.Drawing.Color]::FromArgb(20, 100, 40) } 'FAIL' { [System.Drawing.Color]::FromArgb(150, 20, 20) } default { [System.Drawing.Color]::FromArgb(130, 80, 0) } })
                $lblGate.Text = 'Install gate: ' + (Get-CcmInstallReadinessText -Result $d)
            } else { $lblState.Text = 'No discovery yet - click Run discovery.'; $lblGate.Text = '' }
        }.GetNewClosure()
        $refreshAll = { & $build; & $filter.Apply; & $refreshInfo }.GetNewClosure()
        $ui.Refresh = $refreshAll

        $selStep = {
            if ($grid.SelectedRows.Count -eq 0) { return $null }
            $id = [string]$grid.SelectedRows[0].Tag
            foreach ($s in $ui.Catalog) { if ($s.Id -eq $id) { return $s } }
            return $null
        }.GetNewClosure()

        $out = {
            param($line)
            if ($null -eq $line) { return }
            $stamp = (Get-Date).ToString('HH:mm:ss')
            foreach ($l in ([string]$line -split "`r?`n")) { $txtOut.AppendText("[$stamp] $l`r`n") }
            try { $App.Log('INFO', 'Step', [string]$line) } catch { }
        }.GetNewClosure()

        # ---------------- events
        $grid.Add_SelectionChanged({
            $s = & $selStep
            if (-not $s) { $txtDetail.Text = ''; return }
            $txtDetail.Text = ("{0}. {1}`r`n`r`n{2}`r`n`r`n{3}`r`n`r`nRuns as: {4}    Reboot: {5}    Risk: {6}" -f $s.Order, $s.Title, $s.Summary, $s.Details, $s.Kind, $s.Reboot, $s.Risk)
        }.GetNewClosure())

        $btnScan.Add_Click({
            if (Get-CcmActiveJob) { $App.SetStatus('A step is running - wait for it to finish.', 'warn'); return }
            $btnScan.Enabled = $false
            try { [void](Invoke-CcmDiscovery -App $App -Deep:($chkDeep.Checked)) } catch { & $out "Discovery failed: $($_.Exception.Message)" }
            finally { $btnScan.Enabled = $true }
        }.GetNewClosure())

        $btnNext.Add_Click({
            $d = (Get-CcmTSState).Discovery
            if (-not $d) { $App.SetStatus('Run discovery first.', 'warn'); return }
            $prog = Get-CcmStepProgress -App $App
            $target = $null
            foreach ($id in @($d.Recommended)) {
                $p = $(if ($prog.ContainsKey($id)) { $prog[$id] } else { $null })
                # done = finished OK (or skipped) AFTER the latest discovery; anything else is still to do
                $ran = [datetime]::MinValue
                if ($p -and $p.LastRun) { [void][datetime]::TryParseExact($p.LastRun, 'yyyy-MM-dd HH:mm', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$ran) }
                $isDone = $p -and ($p.Status -like 'Done*' -or $p.Status -eq 'Skipped') -and $ran -ge $d.Time.AddMinutes(-1)
                if (-not $isDone) { $target = $id; break }
            }
            if (-not $target) { $App.SetStatus('Every recommended step has been run - run discovery again to re-check.', 'ok'); return }
            if ($box.Text) { $box.Text = ''; & $filter.Apply }
            foreach ($row in $grid.Rows) { if ([string]$row.Tag -eq $target) { $row.Selected = $true; $grid.FirstDisplayedScrollingRowIndex = [Math]::Max(0, $row.Index - 2); break } }
        }.GetNewClosure())

        $btnRun.Add_Click({
            $s = & $selStep
            if (-not $s) { $App.SetStatus('Select a step first.', 'warn'); return }
            if ($ui.Busy -or (Get-CcmActiveJob)) { $App.SetStatus("A step is running ($($ui.Running)) - wait for it to finish.", 'warn'); return }
            if ($s.Confirm) {
                $a = [System.Windows.Forms.MessageBox]::Show($s.Confirm, "$($s.Order). $($s.Title)", 'YesNo', 'Warning', 'Button2')
                if ($a -ne 'Yes') { return }
            }
            $ui.Busy = $true; $ui.Running = $s.Id; $btnRun.Enabled = $false
            & $ui.Refresh
            & $out "==== $($s.Order). $($s.Title)"
            $App.SetStatus("Running: $($s.Title)", 'info')
            $sid = $s.Id; $stitle = $s.Title
            $done = {
                param($status, $summary)
                $ui.Busy = $false; $ui.Running = ''; $btnRun.Enabled = $true
                & $out "RESULT: $status - $summary"
                try { Set-CcmStepProgress -App $App -Id $sid -Status $status -Result $summary } catch { }
                try { $App.LogAction("Step $sid : $status - $summary") } catch { }
                $lvl = $(if ($status -like 'Done*') { 'ok' } elseif ($status -eq 'Failed') { 'err' } else { 'warn' })
                $App.SetStatus("$stitle : $status", $lvl)
                & $ui.Refresh
                if ($status -eq 'Done - reboot') {
                    $a = [System.Windows.Forms.MessageBox]::Show("$stitle finished and needs a reboot.`r`n`r`n$summary`r`n`r`nReboot now? (Progress is saved - reopen the tool after the restart.)", 'Reboot', 'YesNo', 'Question', 'Button2')
                    if ($a -eq 'Yes') { try { Restart-Computer -Force } catch { & $out "Reboot failed: $($_.Exception.Message)" } }
                }
            }.GetNewClosure()
            $ctx = @{ RepairSource = $txtSrc.Text.Trim(); ResetKey = $chkReset.Checked; ForceInstall = $chkForce.Checked; Deep = $chkDeep.Checked }
            try { Invoke-CcmStep -App $App -Id $sid -Ctx $ctx -Out $out -Done $done }
            catch {
                & $out "ERROR: $($_.Exception.Message)"
                try { $App.Log('ERROR', 'Step', "$sid : $($_.Exception.ToString())") } catch { }
                if ($ui.Busy -and -not (Get-CcmActiveJob)) { & $done 'Failed' $_.Exception.Message }
            }
        }.GetNewClosure())

        $btnDone.Add_Click({
            $s = & $selStep; if (-not $s) { return }
            Set-CcmStepProgress -App $App -Id $s.Id -Status 'Done' -Result 'Marked done by operator.'
            & $ui.Refresh
        }.GetNewClosure())
        $btnClear.Add_Click({
            $s = & $selStep; if (-not $s) { return }
            Reset-CcmStepProgress -App $App -Id $s.Id; & $ui.Refresh
        }.GetNewClosure())
        $btnReset.Add_Click({
            $a = [System.Windows.Forms.MessageBox]::Show("Clear the saved status of every step on $env:COMPUTERNAME?", 'Clear all statuses', 'YesNo', 'Question', 'Button2')
            if ($a -eq 'Yes') { Reset-CcmStepProgress -App $App; & $ui.Refresh }
        }.GetNewClosure())

        $btnLog.Add_Click({
            $s = & $selStep; if (-not $s) { return }
            $c = Join-Path $env:windir 'CCM\Logs'
            $map = @{
                Sfc = (Join-Path $env:windir 'Logs\CBS\CBS.log'); DismScan = (Join-Path $env:windir 'Logs\DISM\dism.log')
                DismRestoreSource = (Join-Path $env:windir 'Logs\DISM\dism.log'); DismRestoreWU = (Join-Path $env:windir 'Logs\DISM\dism.log'); DismCleanup = (Join-Path $env:windir 'Logs\DISM\dism.log')
                Uninstall = (Join-Path $env:windir 'ccmsetup\Logs\ccmsetup.log'); InstallLocal = (Join-Path $env:windir 'ccmsetup\Logs\ccmsetup.log')
                InstallShare = (Join-Path $env:windir 'ccmsetup\Logs\ccmsetup.log'); ClientRepair = (Join-Path $env:windir 'ccmsetup\Logs\ccmsetup.log')
                Services = (Join-Path $c 'CertificateMaintenance.log'); RestartCcmExec = (Join-Path $c 'ClientIDManagerStartup.log')
                ResetIdentity = (Join-Path $c 'ClientIDManagerStartup.log'); ServerSide = (Join-Path $c 'ClientIDManagerStartup.log'); Verify = (Join-Path $c 'ClientIDManagerStartup.log')
                TriggerActions = (Join-Path $c 'PolicyAgent.log'); ResetPolicy = (Join-Path $c 'PolicyAgent.log')
            }
            if ($s.Id -eq 'WuTroubleshooter' -and $global:CcmTS.LastReportFolder) { if (Test-Path -LiteralPath $global:CcmTS.LastReportFolder) { Start-Process explorer.exe ('"{0}"' -f $global:CcmTS.LastReportFolder) }; return }
            if (-not $map.ContainsKey($s.Id)) { $App.SetStatus('This step has no log of its own - see the Output pane and Session.log.', 'info'); return }
            $p = $map[$s.Id]
            if (-not (Test-Path -LiteralPath $p)) { $App.SetStatus("Not found: $p", 'warn'); return }
            $cm = Join-Path $env:windir 'CCM\CMTrace.exe'
            if (Test-Path -LiteralPath $cm) { Start-Process -FilePath $cm -ArgumentList ('"{0}"' -f $p) } else { Start-Process -FilePath 'notepad.exe' -ArgumentList ('"{0}"' -f $p) }
        }.GetNewClosure())

        $btnReboot.Add_Click({
            if (Get-CcmActiveJob) { [void][System.Windows.Forms.MessageBox]::Show('A step is still running. Wait for it to finish before rebooting.', 'Reboot', 'OK', 'Warning'); return }
            $a = [System.Windows.Forms.MessageBox]::Show("Restart $env:COMPUTERNAME now?`r`n`r`nStep progress is saved; reopen the tool after the restart and run discovery.", 'Reboot', 'YesNo', 'Question', 'Button2')
            if ($a -eq 'Yes') { try { $App.LogAction('Reboot requested from Repair Steps.'); Restart-Computer -Force } catch { & $out "Reboot failed: $($_.Exception.Message)" } }
        }.GetNewClosure())

        $applySource = { (Get-CcmTSState).RepairSourceOverride = $txtSrc.Text.Trim() }.GetNewClosure()
        $txtSrc.Add_Leave($applySource)
        $btnUsePc.Add_Click({
            $pc = $txtPc.Text.Trim().TrimStart('\')
            if (-not $pc) { $App.SetStatus('Type the name of a healthy PC on the same Windows build.', 'warn'); return }
            $txtSrc.Text = "\\$pc\C$\Windows"; & $applySource
            $btnTest.PerformClick()
        }.GetNewClosure())
        $btnTest.Add_Click({
            & $applySource
            $btnTest.Enabled = $false
            try {
                $t = Test-CcmRepairSource -Source $txtSrc.Text
                & $out ("Repair source test: {0}`r`n  {1}`r`n  this PC build {2}, source build {3}" -f $txtSrc.Text, $t.Detail, $t.LocalBuild, $(if ($t.SourceBuild) { $t.SourceBuild } else { '-' }))
                $App.SetStatus($t.Detail, $(if ($t.Ok -and ($t.Match -or $t.Kind -eq 'Image')) { 'ok' } else { 'warn' }))
            } finally { $btnTest.Enabled = $true }
        }.GetNewClosure())

        # running-job ticker
        $ticker = New-Object System.Windows.Forms.Timer; $ticker.Interval = 1000
        $ticker.Add_Tick({
            $j = Get-CcmActiveJob
            if ($j) { $el = (Get-Date) - $j.Started; $lblJob.Text = ("Running: {0}   {1:hh\:mm\:ss} elapsed   ({2})   - the tool's own console window shows its progress; do not close it." -f $j.Name, $el, $(if ($j.Phase -eq 'Wait') { 'waiting for child processes' } else { "pid $($j.Process.Id)" })) }
            elseif ($ui.Busy) { $lblJob.Text = "Running: $($ui.Running) ..." }
            else { $lblJob.Text = 'No step running.' }
        }.GetNewClosure())
        $ticker.Start()
        $Page.Add_Disposed({ try { $ticker.Stop(); $ticker.Dispose() } catch { } }.GetNewClosure())

        $st = Get-CcmTSState
        [void]$st.ScanHandlers.Add({ param($res) & $ui.Refresh }.GetNewClosure())

        & $ui.Refresh
    }
}
