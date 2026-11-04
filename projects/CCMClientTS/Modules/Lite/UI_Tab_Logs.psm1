# UI_Tab_Logs.psm1   (LITE TIER)
#
# Logs tab: the logs that matter for client troubleshooting, parsed like
# CMTrace (time / component / type / message; errors red, warnings amber),
# tail-only so huge logs (CBS.log) open instantly, a wildcard filter, an
# errors-only switch and Follow (re-read every 5 s - watch registration live).

function New-CcmLogsTab {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Windows.Forms.TabPage]$Page,
        [Parameter(Mandatory)] $App
    )
    Set-LazyTabBuild -Page $Page -App $App -Build {
        param($Page, $App)
        $Th = $App.Theme
        $ui = @{ Path = ''; Data = @(); Logs = @() }

        $hdr = New-Object System.Windows.Forms.Label
        $hdr.Text = 'Logs - client, setup and Windows servicing logs (newest at the bottom)'; $hdr.Dock = 'Top'
        Set-HeaderStyle -App $App -Label $hdr; $hdr.AutoSize = $false; $hdr.Height = 34

        # ---------------- left: log list
        $left = New-Object System.Windows.Forms.Panel
        $left.Dock = 'Left'; $left.Width = 300; $left.Padding = New-Object System.Windows.Forms.Padding(0, 0, 8, 0)
        $list = New-Object System.Windows.Forms.ListBox
        $list.Dock = 'Fill'; $list.IntegralHeight = $false; $list.BorderStyle = 'FixedSingle'
        $lblPurpose = New-Object System.Windows.Forms.Label
        $lblPurpose.Dock = 'Bottom'; $lblPurpose.Height = 70; $lblPurpose.ForeColor = $Th.Muted; $lblPurpose.Padding = New-Object System.Windows.Forms.Padding(2, 6, 2, 0)
        $leftBar = New-Object System.Windows.Forms.FlowLayoutPanel
        $leftBar.Dock = 'Bottom'; $leftBar.Height = 36; $leftBar.WrapContents = $false
        $btnBrowse = $Th.MakeButton('Open other log...')
        $btnReloadList = $Th.MakeButton('Refresh list')
        $leftBar.Controls.AddRange(@($btnBrowse, $btnReloadList))
        $left.Controls.Add($list); $left.Controls.Add($lblPurpose); $left.Controls.Add($leftBar)

        # ---------------- right: toolbar + grid + message
        $right = New-Object System.Windows.Forms.Panel
        $right.Dock = 'Fill'
        $bar = New-Object System.Windows.Forms.FlowLayoutPanel
        $bar.Dock = 'Top'; $bar.Height = 38; $bar.WrapContents = $false
        $btnRefresh = $Th.MakeButton('Refresh')
        $lblKb = New-Object System.Windows.Forms.Label; $lblKb.Text = 'Read last (KB):'; $lblKb.AutoSize = $true; $lblKb.Margin = New-Object System.Windows.Forms.Padding(10, 9, 2, 0)
        $numKb = New-Object System.Windows.Forms.NumericUpDown; $numKb.Minimum = 32; $numKb.Maximum = 16384; $numKb.Increment = 256; $numKb.Value = 512; $numKb.Width = 70; $numKb.Margin = New-Object System.Windows.Forms.Padding(2, 6, 8, 0)
        $chkErr = New-Object System.Windows.Forms.CheckBox; $chkErr.Text = 'Errors and warnings only'; $chkErr.AutoSize = $true; $chkErr.Margin = New-Object System.Windows.Forms.Padding(6, 9, 8, 0)
        $chkFollow = New-Object System.Windows.Forms.CheckBox; $chkFollow.Text = 'Follow (every 5 s)'; $chkFollow.AutoSize = $true; $chkFollow.Margin = New-Object System.Windows.Forms.Padding(6, 9, 8, 0)
        $lblF = New-Object System.Windows.Forms.Label; $lblF.Text = 'Filter:'; $lblF.AutoSize = $true; $lblF.Margin = New-Object System.Windows.Forms.Padding(12, 9, 2, 0)
        $box = New-Object System.Windows.Forms.TextBox; $box.Width = 200; $box.Margin = New-Object System.Windows.Forms.Padding(2, 6, 6, 0)
        $count = New-Object System.Windows.Forms.Label; $count.AutoSize = $true; $count.ForeColor = $Th.Muted; $count.Margin = New-Object System.Windows.Forms.Padding(4, 9, 8, 0)
        $btnOpen = $Th.MakeButton('Open in viewer')
        $btnFolder = $Th.MakeButton('Open folder')
        $bar.Controls.AddRange(@($btnRefresh, $lblKb, $numKb, $chkErr, $chkFollow, $lblF, $box, $count, $btnOpen, $btnFolder))
        $hint = New-Object System.Windows.Forms.Label
        $hint.Dock = 'Top'; $hint.Height = 20; $hint.ForeColor = $Th.Muted
        $hint.Text = (Get-FilterHintText) + '   Try: RegTask   0x8*   rejected   [SR]*Cannot'

        $grid = New-Object System.Windows.Forms.DataGridView
        $grid.Dock = 'Fill'
        $grid.ReadOnly = $true; $grid.AllowUserToAddRows = $false; $grid.AllowUserToDeleteRows = $false; $grid.AllowUserToResizeRows = $false
        $grid.RowHeadersVisible = $false; $grid.MultiSelect = $false; $grid.SelectionMode = 'FullRowSelect'
        $grid.BackgroundColor = $Th.Surface; $grid.BorderStyle = 'FixedSingle'; $grid.GridColor = $Th.Border
        $grid.EnableHeadersVisualStyles = $false
        $grid.ColumnHeadersDefaultCellStyle.BackColor = $Th.Header; $grid.ColumnHeadersDefaultCellStyle.ForeColor = $Th.Title
        $grid.DefaultCellStyle.SelectionBackColor = $Th.Select; $grid.DefaultCellStyle.SelectionForeColor = $Th.Text
        $grid.DefaultCellStyle.Font = New-Object System.Drawing.Font($Th.MonoFontName, $Th.FontSizePt)
        foreach ($c in @(@('Time', 140), @('Component', 170), @('Type', 50), @('Message', 800))) { $i = $grid.Columns.Add($c[0], $c[0]); $grid.Columns[$i].Width = $c[1] }
        $grid.Columns['Message'].AutoSizeMode = 'Fill'

        $msg = New-Object System.Windows.Forms.TextBox
        $msg.Dock = 'Bottom'; $msg.Height = 110; $msg.Multiline = $true; $msg.ReadOnly = $true; $msg.ScrollBars = 'Vertical'
        $msg.Font = New-Object System.Drawing.Font($Th.MonoFontName, $Th.FontSizePt); $msg.BackColor = $Th.Surface

        $right.Controls.Add($grid); $right.Controls.Add($msg); $right.Controls.Add($hint); $right.Controls.Add($bar)
        $Page.Controls.Add($right); $Page.Controls.Add($left); $Page.Controls.Add($hdr)

        # ---------------- behaviour
        $typeName = @{ 1 = ''; 2 = 'WARN'; 3 = 'ERROR' }
        $onFilter = {
            param($Regex, $Text)
            $src = @($ui.Data)
            if ($chkErr.Checked) { $src = @($src | Where-Object { $_.Type -ge 2 }) }
            $rows = @(Select-FilterMatch -Items $src -Regex $Regex -Property @('Time', 'Component', 'Message'))
            $grid.SuspendLayout()
            try {
                $grid.Rows.Clear()
                foreach ($r in $rows) {
                    $ix = $grid.Rows.Add($r.Time, $r.Component, $typeName[[int]$r.Type], $r.Message)
                    if ($r.Type -eq 3) { $grid.Rows[$ix].DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(252, 222, 222) }
                    elseif ($r.Type -eq 2) { $grid.Rows[$ix].DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(255, 244, 206) }
                }
                if ($grid.Rows.Count -gt 0) { $grid.FirstDisplayedScrollingRowIndex = $grid.Rows.Count - 1 }
            } finally { $grid.ResumeLayout() }
            $count.Text = '{0} of {1}' -f $rows.Count, @($ui.Data).Count
        }.GetNewClosure()
        $filter = Register-ListFilter -App $App -TextBox $box -OnFilter $onFilter

        $load = {
            if (-not $ui.Path) { return }
            if (-not (Test-Path -LiteralPath $ui.Path)) { $ui.Data = @(); $msg.Text = "Not found: $($ui.Path)"; & $filter.Apply; return }
            $ui.Data = @(Get-CcmLogEntries -Path $ui.Path -MaxBytes ([int]$numKb.Value * 1024))
            & $filter.Apply
            $App.SetStatus(("{0}: {1} line(s) from the last {2} KB" -f (Split-Path $ui.Path -Leaf), @($ui.Data).Count, $numKb.Value), 'info')
        }.GetNewClosure()

        $fillList = {
            $ui.Logs = @(Get-CcmLogCatalog -App $App)
            $list.BeginUpdate()
            try {
                $list.Items.Clear()
                foreach ($l in $ui.Logs) { [void]$list.Items.Add($(if ($l.Exists) { $l.Name } else { "$($l.Name)   (missing)" })) }
            } finally { $list.EndUpdate() }
        }.GetNewClosure()

        $list.Add_SelectedIndexChanged({
            $i = $list.SelectedIndex
            if ($i -lt 0 -or $i -ge @($ui.Logs).Count) { return }
            $l = $ui.Logs[$i]
            $ui.Path = $l.Path
            $lblPurpose.Text = "$($l.Purpose)`r`n$($l.Path)`r`n$(if ($l.Exists) { "$($l.Size), modified $($l.Modified)" } else { 'not on this machine' })"
            & $load
        }.GetNewClosure())
        $grid.Add_SelectionChanged({
            if ($grid.SelectedRows.Count -gt 0) { $r = $grid.SelectedRows[0]; $msg.Text = "$($r.Cells['Time'].Value)  $($r.Cells['Component'].Value)`r`n$($r.Cells['Message'].Value)" }
        }.GetNewClosure())
        $btnRefresh.Add_Click($load)
        $chkErr.Add_CheckedChanged({ & $filter.Apply }.GetNewClosure())
        $btnReloadList.Add_Click({ $sel = $list.SelectedIndex; & $fillList; if ($sel -ge 0 -and $sel -lt $list.Items.Count) { $list.SelectedIndex = $sel } }.GetNewClosure())
        $btnBrowse.Add_Click({
            $dlg = New-Object System.Windows.Forms.OpenFileDialog
            $dlg.Filter = 'Log files (*.log;*.lo_;*.txt)|*.log;*.lo_;*.txt|All files (*.*)|*.*'
            $dlg.InitialDirectory = Join-Path $env:windir 'CCM\Logs'
            if ($dlg.ShowDialog() -eq 'OK') { $list.ClearSelected(); $ui.Path = $dlg.FileName; $lblPurpose.Text = $dlg.FileName; & $load }
        }.GetNewClosure())
        $btnOpen.Add_Click({
            if (-not $ui.Path -or -not (Test-Path -LiteralPath $ui.Path)) { return }
            $cm = Join-Path $env:windir 'CCM\CMTrace.exe'
            if (Test-Path -LiteralPath $cm) { Start-Process -FilePath $cm -ArgumentList ('"{0}"' -f $ui.Path) } else { Start-Process -FilePath 'notepad.exe' -ArgumentList ('"{0}"' -f $ui.Path) }
        }.GetNewClosure())
        $btnFolder.Add_Click({ if ($ui.Path) { $d = Split-Path $ui.Path -Parent; if (Test-Path -LiteralPath $d) { Start-Process explorer.exe ('"{0}"' -f $d) } } }.GetNewClosure())

        $timer = New-Object System.Windows.Forms.Timer; $timer.Interval = 5000
        $timer.Add_Tick({ if ($chkFollow.Checked -and $Page.Visible -and $ui.Path) { & $load } }.GetNewClosure())
        $timer.Start()
        $Page.Add_Disposed({ try { $timer.Stop(); $timer.Dispose() } catch { } }.GetNewClosure())

        & $fillList
        if ($list.Items.Count -gt 0) { $list.SelectedIndex = 0 }
    }
}
