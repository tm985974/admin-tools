# UI_Tab_Discovery.psm1   (LITE TIER)
#
# Discovery tab: runs Invoke-CcmDiscovery (read-only), shows the verdict
# banner (state, what it means, the recommended steps, install readiness) and
# every finding in a filterable grid. Export / copy the report for the server
# admin. Runs automatically the first time the tab is opened.

function New-CcmDiscoveryTab {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Windows.Forms.TabPage]$Page,
        [Parameter(Mandatory)] $App
    )
    if (-not (Register-AppRequirement -App $App -Page $Page -For 'Discovery' -Command 'Get-CimInstance' -Hint 'Windows PowerShell 5.1 (CIM cmdlets) is required.')) { return }

    Set-LazyTabBuild -Page $Page -App $App -LoadingText 'Discovery runs when this tab opens...' -Build {
        param($Page, $App)
        $Th = $App.Theme
        $ui = @{ Data = @(); Running = $false }

        # ---------------- header + banner
        $hdr = New-Object System.Windows.Forms.Label
        $hdr.Text = 'Discovery - current state of the client and the Windows pieces it needs'; $hdr.Dock = 'Top'
        Set-HeaderStyle -App $App -Label $hdr; $hdr.AutoSize = $false; $hdr.Height = 34

        $banner = New-Object System.Windows.Forms.Panel
        $banner.Dock = 'Top'; $banner.Height = 112; $banner.Padding = New-Object System.Windows.Forms.Padding(12, 8, 12, 6)
        $banner.BackColor = $Th.Header
        $lblState = New-Object System.Windows.Forms.Label
        $lblState.Dock = 'Top'; $lblState.Height = 26; $lblState.Font = New-AppFont -App $App -Size ($Th.FontSizePt + 4) -Style ([System.Drawing.FontStyle]::Bold)
        $lblState.Text = 'Not run yet'
        $lblDetail = New-Object System.Windows.Forms.Label
        $lblDetail.Dock = 'Top'; $lblDetail.Height = 22; $lblDetail.Text = ''
        $lblNext = New-Object System.Windows.Forms.Label
        $lblNext.Dock = 'Top'; $lblNext.Height = 22; $lblNext.Font = New-AppFont -App $App -Style ([System.Drawing.FontStyle]::Bold); $lblNext.Text = ''
        $lblInstall = New-Object System.Windows.Forms.Label
        $lblInstall.Dock = 'Top'; $lblInstall.Height = 22; $lblInstall.Text = ''
        $banner.Controls.Add($lblInstall); $banner.Controls.Add($lblNext); $banner.Controls.Add($lblDetail); $banner.Controls.Add($lblState)

        # ---------------- toolbar
        $bar = New-Object System.Windows.Forms.FlowLayoutPanel
        $bar.Dock = 'Top'; $bar.Height = 40; $bar.WrapContents = $false; $bar.Padding = New-Object System.Windows.Forms.Padding(0, 6, 0, 0)
        $btnRun = $Th.MakeButton('Run discovery')
        $chkDeep = New-Object System.Windows.Forms.CheckBox
        $chkDeep.Text = 'Deep checks (WMI verify + DISM CheckHealth, ~1 min)'; $chkDeep.AutoSize = $true; $chkDeep.Margin = New-Object System.Windows.Forms.Padding(8, 8, 16, 0)
        $btnExport = $Th.MakeButton('Export report...')
        $btnCopy = $Th.MakeButton('Copy report')
        $lblF = New-Object System.Windows.Forms.Label; $lblF.Text = 'Filter:'; $lblF.AutoSize = $true; $lblF.Margin = New-Object System.Windows.Forms.Padding(24, 9, 2, 0)
        $box = New-Object System.Windows.Forms.TextBox; $box.Width = 220; $box.Margin = New-Object System.Windows.Forms.Padding(2, 6, 6, 0)
        $count = New-Object System.Windows.Forms.Label; $count.AutoSize = $true; $count.ForeColor = $Th.Muted; $count.Margin = New-Object System.Windows.Forms.Padding(4, 9, 8, 0)
        $hint = New-Object System.Windows.Forms.Label; $hint.AutoSize = $true; $hint.ForeColor = $Th.Muted; $hint.Margin = New-Object System.Windows.Forms.Padding(4, 9, 0, 0)
        $hint.Text = (Get-FilterHintText) + '   Try: fail   warn   crypto   *mp*'
        $bar.Controls.AddRange(@($btnRun, $chkDeep, $btnExport, $btnCopy, $lblF, $box, $count, $hint))

        # ---------------- grid
        $grid = New-Object System.Windows.Forms.DataGridView
        $grid.Dock = 'Fill'
        $grid.ReadOnly = $true; $grid.AllowUserToAddRows = $false; $grid.AllowUserToDeleteRows = $false; $grid.AllowUserToResizeRows = $false
        $grid.RowHeadersVisible = $false; $grid.MultiSelect = $false; $grid.SelectionMode = 'FullRowSelect'
        $grid.BackgroundColor = $Th.Surface; $grid.BorderStyle = 'FixedSingle'; $grid.GridColor = $Th.Border
        $grid.EnableHeadersVisualStyles = $false
        $grid.ColumnHeadersDefaultCellStyle.BackColor = $Th.Header; $grid.ColumnHeadersDefaultCellStyle.ForeColor = $Th.Title
        $grid.DefaultCellStyle.SelectionBackColor = $Th.Select; $grid.DefaultCellStyle.SelectionForeColor = $Th.Text
        $grid.DefaultCellStyle.WrapMode = 'True'; $grid.AutoSizeRowsMode = 'AllCells'
        foreach ($c in @(@('Category', 130), @('Check', 230), @('Status', 60), @('Detail', 640), @('Fix', 380))) {
            $i = $grid.Columns.Add($c[0], $(if ($c[0] -eq 'Fix') { 'Next step / fix' } else { $c[0] }))
            $grid.Columns[$i].Width = $c[1]
        }
        $grid.Columns['Detail'].AutoSizeMode = 'Fill'

        $Page.Controls.Add($grid); $Page.Controls.Add($bar); $Page.Controls.Add($banner); $Page.Controls.Add($hdr)

        # ---------------- behaviour
        $ui.Grid = $grid; $ui.Count = $count
        $cols = @('Category', 'Check', 'Status', 'Detail', 'Fix')
        $colors = @{
            OK   = [System.Drawing.Color]::FromArgb(222, 242, 222)
            WARN = [System.Drawing.Color]::FromArgb(255, 241, 204)
            FAIL = [System.Drawing.Color]::FromArgb(250, 214, 214)
        }
        $onFilter = {
            param($Regex, $Text)
            $rows = @(Select-FilterMatch -Items $ui.Data -Regex $Regex -Property $cols)
            $grid.SuspendLayout()
            try {
                $grid.Rows.Clear()
                foreach ($r in $rows) {
                    $ix = $grid.Rows.Add($r.Category, $r.Check, $r.Status, $r.Detail, $r.Fix)
                    if ($colors.ContainsKey($r.Status)) { $grid.Rows[$ix].Cells['Status'].Style.BackColor = $colors[$r.Status] }
                    if ($r.Status -eq 'FAIL') { $grid.Rows[$ix].DefaultCellStyle.ForeColor = [System.Drawing.Color]::FromArgb(150, 20, 20) }
                }
            } finally { $grid.ResumeLayout() }
            $count.Text = '{0} of {1}' -f $rows.Count, @($ui.Data).Count
        }.GetNewClosure()
        $filter = Register-ListFilter -App $App -TextBox $box -OnFilter $onFilter

        $names = @{}; foreach ($s in (Get-CcmStepCatalog)) { $names[$s.Id] = "$($s.Order). $($s.Title)" }
        $show = {
            param($res)
            if (-not $res) { return }
            $ui.Data = @($res.Findings)
            $lblState.Text = "$($res.State)      ($($res.Time.ToString('HH:mm:ss'))$(if ($res.Deep) { ', deep' }))"
            $lblDetail.Text = $res.StateDetail
            $lblNext.Text = 'Next: ' + $(if (@($res.Recommended).Count) { (@($res.Recommended) | ForEach-Object { $names[$_] }) -join '   ->   ' } else { 'nothing to do' })
            $lblInstall.Text = 'Install readiness: ' + (Get-CcmInstallReadinessText -Result $res)
            switch ($res.StateLevel) {
                'OK'   { $banner.BackColor = [System.Drawing.Color]::FromArgb(222, 242, 222); $lblState.ForeColor = [System.Drawing.Color]::FromArgb(20, 100, 40) }
                'FAIL' { $banner.BackColor = [System.Drawing.Color]::FromArgb(250, 224, 224); $lblState.ForeColor = [System.Drawing.Color]::FromArgb(150, 20, 20) }
                default { $banner.BackColor = [System.Drawing.Color]::FromArgb(255, 244, 214); $lblState.ForeColor = [System.Drawing.Color]::FromArgb(130, 80, 0) }
            }
            & $filter.Apply
        }.GetNewClosure()
        $ui.Show = $show

        $runScan = {
            if ($ui.Running) { return }
            $ui.Running = $true; $btnRun.Enabled = $false
            $frm = $Page.FindForm(); if ($frm) { $frm.Cursor = [System.Windows.Forms.Cursors]::WaitCursor }
            try {
                $lblState.Text = 'Running discovery...'; $lblDetail.Text = ''; $lblNext.Text = ''; $lblInstall.Text = ''
                $banner.BackColor = $Th.Header; $lblState.ForeColor = $Th.Title
                [System.Windows.Forms.Application]::DoEvents()
                $lblDetail = $lblDetail   # local copy so the nested closure below captures it
                $prog = { param($t) $lblDetail.Text = "Checking $t ..."; $lblDetail.Refresh() }.GetNewClosure()
                [void](Invoke-CcmDiscovery -App $App -Deep:($chkDeep.Checked) -Progress $prog)   # ScanHandlers refresh the banner + grid
            }
            catch {
                $lblState.Text = 'Discovery failed'; $lblDetail.Text = $_.Exception.Message
                try { $App.Log('ERROR', 'Discovery', $_.Exception.ToString()) } catch { }
            }
            finally {
                $ui.Running = $false; $btnRun.Enabled = $true
                if ($frm) { $frm.Cursor = [System.Windows.Forms.Cursors]::Default }
            }
        }.GetNewClosure()

        $st = Get-CcmTSState
        [void]$st.ScanHandlers.Add({ param($res) & $show $res }.GetNewClosure())

        $btnRun.Add_Click($runScan)
        $btnCopy.Add_Click({
            $d = (Get-CcmTSState).Discovery
            if (-not $d) { $App.SetStatus('Run discovery first.', 'warn'); return }
            try { [System.Windows.Forms.Clipboard]::SetText((Format-CcmReport -Result $d)); $App.SetStatus('Report copied to the clipboard.', 'ok') } catch { $App.SetStatus("Copy failed: $($_.Exception.Message)", 'err') }
        }.GetNewClosure())
        $btnExport.Add_Click({
            $d = (Get-CcmTSState).Discovery
            if (-not $d) { $App.SetStatus('Run discovery first.', 'warn'); return }
            try {
                $dir = Join-Path ([string]$App.DataRoot) 'Reports'
                if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
                $p = Join-Path $dir ("Discovery_{0}_{1}.txt" -f $env:COMPUTERNAME, $d.Time.ToString('yyyyMMdd_HHmmss'))
                [System.IO.File]::WriteAllText($p, (Format-CcmReport -Result $d), (New-Object System.Text.UTF8Encoding($false)))
                $csv = [System.IO.Path]::ChangeExtension($p, '.csv')
                $d.Findings | Export-Csv -LiteralPath $csv -NoTypeInformation -Encoding UTF8
                $App.LogAction("Discovery report exported: $p")
                $r = Invoke-AppCommand -App $App -Title 'Export report' -Kind Read -Always -RunLabel 'Open folder' `
                    -Summary "Saved:`r`n$p`r`n$csv`r`nOpen the folder? (Cancel = no)" `
                    -Code ('Start-Process -FilePath explorer.exe -ArgumentList ' + (Format-AppCommandValue ('"' + $dir + '"')))
                if ($r.Errors.Count) { $App.SetStatus("Not opened: $($r.Errors[0])", 'err') }
            } catch { $App.SetStatus("Export failed: $($_.Exception.Message)", 'err') }
        }.GetNewClosure())

        # show an earlier result (e.g. from Repair Steps), otherwise scan once the tab has painted
        if ($st.Discovery) { & $show $st.Discovery }
        else {
            $t = New-Object System.Windows.Forms.Timer; $t.Interval = 300
            $t.Add_Tick({ $t.Stop(); $t.Dispose(); & $runScan }.GetNewClosure())
            $t.Start()
        }
    }
}
