# UI_Tab_Fleet.psm1   (LITE TIER)
#
# Fleet tab: run from one admin PC inside the air-gapped network.
#   Check status      - which machines have Radmin Server, which are licensed
#   Collect requests  - every unlicensed machine makes <NAME>.request; the file
#                       comes back over WinRM into <Transfer>\Requests\
#   Apply licenses    - every machine with <NAME>.license in <Transfer>\Licenses\
#                       gets it pushed and applied, then the registry key is checked
# Licensed machines have their request + license moved to <Transfer>\Done\.
# Remote machines: WinRM, or the admin share (C$) + WMI where WinRM is off
# (Connect via; Services_RadminBatch.psm1), with an admin account there.
# This PC itself runs in-process.

function New-FleetTab {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Windows.Forms.TabPage]$Page,
        [Parameter(Mandatory)] $App
    )
    Set-LazyTabBuild -Page $Page -App $App -Build ${function:Build-FleetTab}
}

function Build-FleetTab {
    param($Page, $App)

    $R = Get-RadminApi
    $st = @{
        App = $App; R = $R; Rows = (& $R.Fleet -App $App); Batch = $null; Cred = $null
        StartBatch = ${function:Start-RadminBatch}
        Green = [System.Drawing.Color]::FromArgb(24, 128, 56)
        Amber = [System.Drawing.Color]::FromArgb(176, 96, 0)
        Red   = [System.Drawing.Color]::Firebrick
    }
    $columns = @(
        @{ P = 'Machine';    H = 'Machine';          W = 150 }
        @{ P = 'Computer';   H = 'Reports as';       W = 130 }
        @{ P = 'Radmin';     H = 'Radmin';           W = 60 }
        @{ P = 'Licensed';   H = 'Licensed';         W = 70 }
        @{ P = 'Via';        H = 'Via';              W = 55 }
        @{ P = 'Request';    H = 'Request file';     W = 120 }
        @{ P = 'License';    H = 'License file';     W = 120 }
        @{ P = 'LastAction'; H = 'Last action';      W = 90 }
        @{ P = 'Checked';    H = 'When';             W = 125 }
        @{ P = 'Result';     H = 'Result';           W = 400 }
    )
    $st.Columns = $columns

    # ---------------- controls ----------------
    $hdr = New-Object System.Windows.Forms.Label
    $hdr.Text = 'Fleet - collect requests and apply licenses across the network'; $hdr.Dock = 'Top'
    Set-HeaderStyle -App $App -Label $hdr; $hdr.AutoSize = $false; $hdr.Height = 34
    $hdr.Padding = New-Object System.Windows.Forms.Padding(10, 8, 0, 0)

    $tools = New-Object System.Windows.Forms.FlowLayoutPanel
    $tools.Dock = 'Top'; $tools.Height = 38; $tools.WrapContents = $false
    $tools.Padding = New-Object System.Windows.Forms.Padding(8, 2, 0, 0)

    $btn = @{}
    foreach ($b in @(
        @('Add',     'Add machines...'), @('Import', 'Import list...'), @('Remove', 'Remove selected'),
        @('Sep1',    ''),
        @('Status',  'Check status'), @('Request', '1. Collect requests'), @('License', '3. Apply licenses'), @('Stop', 'Stop'),
        @('Sep2',    ''),
        @('Cred',    'Credential...'), @('Open', 'Open transfer folder'), @('Change', 'Change...'), @('Rescan', 'Rescan folder'))) {
        if (-not $b[1]) {
            $sp = New-Object System.Windows.Forms.Label; $sp.Width = 14; $sp.Height = 20
            $tools.Controls.Add($sp); continue
        }
        $x = $App.Theme.MakeButton($b[1]); $btn[$b[0]] = $x; $tools.Controls.Add($x)
    }
    $btn.Request.Font = New-AppFont -App $App -Style ([System.Drawing.FontStyle]::Bold)
    $btn.License.Font = New-AppFont -App $App -Style ([System.Drawing.FontStyle]::Bold)
    $btn.Stop.Enabled = $false
    $st.Btn = $btn
    # Its text changes to "Credential: <user>", so its tooltip is set here, not in Config\ToolTips.json.
    Set-AppToolTip -Control $btn.Cred -Text 'Pick an admin account for the remote machines (Cancel = use your own Windows login). Kept until the app closes; never saved.'

    $bar = New-Object System.Windows.Forms.Panel
    $bar.Dock = 'Top'; $bar.Height = 58; $bar.Padding = New-Object System.Windows.Forms.Padding(10, 0, 0, 0)
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = 'Filter:'; $lbl.AutoSize = $true; $lbl.Location = New-Object System.Drawing.Point(10, 9)
    $box = New-Object System.Windows.Forms.TextBox
    $box.Location = New-Object System.Drawing.Point(58, 6); $box.Width = 260
    $count = New-Object System.Windows.Forms.Label
    $count.AutoSize = $true; $count.Location = New-Object System.Drawing.Point(330, 9); $count.ForeColor = $App.Theme.Muted
    $chkSel = New-Object System.Windows.Forms.CheckBox
    $chkSel.Text = 'Only the selected machines'; $chkSel.AutoSize = $true; $chkSel.Location = New-Object System.Drawing.Point(470, 7)
    $chkForce = New-Object System.Windows.Forms.CheckBox
    $chkForce.Text = 'Also machines that are already licensed'; $chkForce.AutoSize = $true; $chkForce.Location = New-Object System.Drawing.Point(680, 7)
    $lblVia = New-Object System.Windows.Forms.Label
    $lblVia.Text = 'Connect via:'; $lblVia.AutoSize = $true; $lblVia.Location = New-Object System.Drawing.Point(960, 9)
    $cboVia = New-Object System.Windows.Forms.ComboBox
    $cboVia.DropDownStyle = 'DropDownList'; $cboVia.Location = New-Object System.Drawing.Point(1040, 5); $cboVia.Width = 250
    [void]$cboVia.Items.AddRange([object[]]@('Auto (WinRM, then admin share + WMI)', 'WinRM only', 'Admin share + WMI only'))
    $cboVia.SelectedIndex = switch ([string](& $R.Settings -App $App).Transport) { 'WinRM' { 1 } 'SMB' { 2 } default { 0 } }
    $bar.Controls.AddRange(@($lblVia, $cboVia))
    $st.Via = $cboVia
    $hint = New-Object System.Windows.Forms.Label
    $hint.AutoSize = $true; $hint.Location = New-Object System.Drawing.Point(58, 34); $hint.ForeColor = $App.Theme.Muted
    $hint.Text = (Get-FilterHintText) + '   Double-click a row for the full result.'
    $bar.Controls.AddRange(@($lbl, $box, $count, $chkSel, $chkForce, $hint))
    $st.ChkSel = $chkSel; $st.ChkForce = $chkForce; $st.Count = $count

    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Dock = 'Fill'
    $grid.ReadOnly = $true; $grid.AllowUserToAddRows = $false; $grid.AllowUserToDeleteRows = $false
    $grid.AllowUserToResizeRows = $false; $grid.RowHeadersVisible = $false; $grid.MultiSelect = $true
    $grid.SelectionMode = 'FullRowSelect'; $grid.AutoSizeColumnsMode = 'None'
    $grid.BackgroundColor = $App.Theme.Surface; $grid.BorderStyle = 'FixedSingle'; $grid.GridColor = $App.Theme.Border
    $grid.EnableHeadersVisualStyles = $false
    $grid.ColumnHeadersDefaultCellStyle.BackColor = $App.Theme.Header
    $grid.ColumnHeadersDefaultCellStyle.ForeColor = $App.Theme.Title
    $grid.DefaultCellStyle.SelectionBackColor = $App.Theme.Select
    $grid.DefaultCellStyle.SelectionForeColor = $App.Theme.Text
    $grid.AlternatingRowsDefaultCellStyle.BackColor = $App.Theme.AltRow
    foreach ($c in $columns) { $i = $grid.Columns.Add($c.P, $c.H); $grid.Columns[$i].Width = $c.W }
    $grid.Columns[$grid.Columns.Count - 1].AutoSizeMode = 'Fill'
    $st.Grid = $grid

    $foot = New-Object System.Windows.Forms.Panel
    $foot.Dock = 'Bottom'; $foot.Height = 48
    $st.Transfer = New-Object System.Windows.Forms.Label
    $st.Transfer.AutoSize = $true; $st.Transfer.Location = New-Object System.Drawing.Point(10, 6)
    $st.Summary = New-Object System.Windows.Forms.Label
    $st.Summary.AutoSize = $true; $st.Summary.Location = New-Object System.Drawing.Point(10, 26); $st.Summary.ForeColor = $App.Theme.Muted
    $foot.Controls.AddRange(@($st.Transfer, $st.Summary))

    # ---------------- helpers ----------------
    $st.Save = { & $st.R.SaveFleet -App $st.App -Rows $st.Rows }.GetNewClosure()

    $st.ShowTransfer = {
        $t = & $st.R.TransferPaths -App $st.App -NoCreate
        $st.Transfer.Text = 'Transfer folder: ' + $t.Root + $(if ($t.Ok) { '' } else { '   (not found - it is created on the first Collect)' })
        $st.Transfer.ForeColor = $(if ($t.Ok) { $st.App.Theme.Text } else { $st.Amber })
    }.GetNewClosure()

    $st.ScanFiles = {
        param($Rows = $st.Rows)
        $t = & $st.R.TransferPaths -App $st.App -NoCreate
        foreach ($r in @($Rows)) {
            $s = & $st.R.TransferState -App $st.App -Names @($r.Computer, $r.Machine) -Paths $t
            $r.Request = $s.Request; $r.License = $s.License
        }
    }.GetNewClosure()

    $st.Paint = {
        param($gr)
        $r = $gr.Tag
        for ($i = 0; $i -lt $st.Columns.Count; $i++) { $gr.Cells[$i].Value = [string]$r.($st.Columns[$i].P) }
        $lc = $gr.Cells[3].Style
        $lc.ForeColor = $(if ($r.Licensed -eq 'Yes') { $st.Green } elseif ($r.Licensed -eq 'No') { $st.Amber } else { $st.App.Theme.Text })
        $gr.Cells[$st.Columns.Count - 1].Style.ForeColor = $(if ($r.Outcome -eq 'err') { $st.Red } elseif ($r.Outcome -eq 'ok') { $st.Green } else { $st.App.Theme.Text })
    }.GetNewClosure()

    $st.Summarize = {
        $all = @($st.Rows)
        $lic = @($all | Where-Object { $_.Licensed -eq 'Yes' }).Count
        $un  = @($all | Where-Object { $_.Licensed -eq 'No' }).Count
        $unk = $all.Count - $lic - $un
        $req = @($all | Where-Object { $_.Request }).Count
        $lf  = @($all | Where-Object { $_.License -and $_.Licensed -ne 'Yes' }).Count
        $st.Summary.Text = "$($all.Count) machines:  $lic licensed,  $un not licensed,  $unk not checked / unreachable.   " +
                           "$req request file(s) waiting for the website,  $lf license file(s) ready to apply."
    }.GetNewClosure()

    $select = ${function:Select-FilterMatch}
    $props = @('Machine', 'Computer', 'Radmin', 'Licensed', 'Via', 'LastAction', 'Result')
    $onFilter = {
        param($Regex, $Text)
        $show = @(& $select -Items @($st.Rows) -Regex $Regex -Property $props)
        $st.Grid.SuspendLayout()
        try {
            $st.Grid.Rows.Clear()
            foreach ($r in $show) {
                $i = $st.Grid.Rows.Add()
                $gr = $st.Grid.Rows[$i]; $gr.Tag = $r
                & $st.Paint $gr
            }
        }
        finally { $st.Grid.ResumeLayout() }
        $st.Count.Text = '{0} of {1}' -f $show.Count, @($st.Rows).Count
        & $st.Summarize
    }.GetNewClosure()
    $st.Filter = Register-ListFilter -App $App -TextBox $box -OnFilter $onFilter

    $st.RepaintRow = {
        param($row)
        foreach ($gr in $st.Grid.Rows) { if ([object]::ReferenceEquals($gr.Tag, $row)) { & $st.Paint $gr; break } }
        & $st.Summarize
    }.GetNewClosure()

    $st.AddNames = {
        param([string[]]$Names)
        $have = @{}
        foreach ($r in $st.Rows) { $have[$r.Machine.ToLowerInvariant()] = $true }
        $added = 0
        foreach ($n in @($Names)) {
            if (-not $n -or $have.ContainsKey($n.ToLowerInvariant())) { continue }
            $row = & $st.R.NewRow -Machine $n
            [void]$st.Rows.Add($row); $have[$n.ToLowerInvariant()] = $true; $added++
        }
        if ($added) {
            & $st.ScanFiles; & $st.Save; & $st.Filter.Apply
            $st.App.LogAction("Fleet: added $added machine(s).")
        }
        $st.App.SetStatus("$added machine(s) added" + $(if (@($Names).Count -gt $added) { " ($(@($Names).Count - $added) already listed)" } else { '' }) + '.', 'ok')
    }.GetNewClosure()

    $st.Busy = {
        param([bool]$on)
        foreach ($k in @('Add', 'Import', 'Remove', 'Status', 'Request', 'License', 'Change', 'Rescan', 'Cred')) { $st.Btn[$k].Enabled = -not $on }
        $st.Via.Enabled = -not $on
        $st.Btn.Stop.Enabled = $on
    }.GetNewClosure()

    $st.Picked = {
        if ($st.ChkSel.Checked) { return @($st.Grid.SelectedRows | ForEach-Object { $_.Tag } | Where-Object { $_ }) }
        return @($st.Rows)
    }.GetNewClosure()

    # ---------------- the three actions ----------------
    $st.Run = {
        param([string]$Action)
        # GetNewClosure copies only THIS scope's variables: $st lives in the outer
        # closure's module, so make it local here or $onResult / $onDone below
        # would see $st = $null ("The expression after '&' ... was not valid").
        $st = $st
        if ($st.Batch) { return }
        $app = $st.App
        $set = & $st.R.Settings -App $app
        $force = [bool]$st.ChkForce.Checked
        $base = @(& $st.Picked)
        if ($base.Count -eq 0) { $app.SetStatus($(if ($st.ChkSel.Checked) { 'Select one or more machines first.' } else { 'Add machines first (Add machines... / Import list...).' }), 'warn'); return }

        $items = New-Object System.Collections.ArrayList
        switch ($Action) {
            'Status' {
                foreach ($r in $base) { [void]$items.Add(@{ Target = $r.Machine; Row = $r; Via = $r.Via; Opt = (& $st.R.Options -Settings $set -Action Status) }) }
            }
            'Request' {
                if (-not [string]$set.LicenseKey) { [void][System.Windows.Forms.MessageBox]::Show('No Radmin license key is set for this environment.' + "`r`n`r`n" + 'Set it on Environment > Radmin (admin password or developer build).', 'Collect requests', 'OK', 'Warning'); return }
                $t = & $st.R.TransferPaths -App $app
                if (-not $t.Ok) { $app.SetStatus($t.Error, 'err'); return }
                foreach ($r in $base) {
                    if ($r.Licensed -eq 'Yes' -and -not $force) { continue }
                    [void]$items.Add(@{ Target = $r.Machine; Row = $r; Via = $r.Via; Opt = (& $st.R.Options -Settings $set -Action Request -Force:$force) })
                }
                if ($items.Count -eq 0) { $app.SetStatus('Every machine in scope is already licensed - nothing to collect.', 'ok'); return }
            }
            'License' {
                foreach ($r in $base) {
                    if ($r.Licensed -eq 'Yes' -and -not $force) { continue }
                    $f = & $st.R.FindLicense -App $app -Names @($r.Computer, $r.Machine)
                    if (-not $f) { continue }
                    $bytes = [System.IO.File]::ReadAllBytes($f)
                    $expect = [System.IO.Path]::GetFileNameWithoutExtension($f)
                    [void]$items.Add(@{ Target = $r.Machine; Row = $r; Via = $r.Via; File = $f
                                        Opt = (& $st.R.Options -Settings $set -Action License -LicenseBytes $bytes -ExpectedName $expect -Force:$force) })
                }
                if ($items.Count -eq 0) {
                    $t = & $st.R.TransferPaths -App $app -NoCreate
                    $app.SetStatus("No .license files to apply for the machines in scope (looked in $($t.Licenses)).", 'warn'); return
                }
            }
        }

        # The command window is the confirmation (template rule: every action shows its code).
        $transport = @('Auto', 'WinRM', 'SMB')[[Math]::Max(0, $st.Via.SelectedIndex)]
        $targets = @($items | ForEach-Object { [string]$_.Target })
        $files = @{}; foreach ($it in $items) { if ($it.File) { $files[[string]$it.Target] = [string]$it.File } }
        $tRoot = (& $st.R.TransferFolder -App $app)
        $code = & $st.R.CommandText -Settings $set -Action $Action -Targets $targets -Files $files -TransferRoot $tRoot -Transport $transport -Force:$force
        $what = @{ Status = 'Check Radmin Server and its license on'; Request = 'Collect a license request from'; License = 'Apply a license to' }[$Action]
        $sum = "$what $($items.Count) machine(s), $($set.ParallelMachines) at a time, connecting via $transport" +
               $(if ($st.Cred) { " as $($st.Cred.UserName)" } else { '' }) + '.' +
               $(if ($force -and $Action -ne 'Status') { ' Machines that are already licensed are included.' } else { '' })
        $kind = $(if ($Action -eq 'Status') { 'Read' } else { 'Change' })
        $label = @{ Status = 'Check'; Request = 'Collect'; License = 'Apply' }[$Action]
        if (-not (& $st.R.Confirm -App $app -Title "Fleet - $what" -Kind $kind -RunLabel $label -Summary $sum -Code $code)) { return }

        foreach ($it in $items) { $it.Row.LastAction = $Action; $it.Row.Result = 'Working...'; $it.Row.Outcome = ''; & $st.RepaintRow $it.Row }
        & $st.Busy $true
        $app.SetStatus("$Action - $($items.Count) machine(s)...", 'info')

        $onResult = {
            param($Item, $Res)
            $row = $Item.Row
            if ([string]$Res.Computer) { $row.Computer = [string]$Res.Computer }
            if ($null -ne $Res.RadminFound) { $row.Radmin = $(if ($Res.RadminFound) { 'Yes' } else { 'No' }) }
            if ($null -ne $Res.Licensed -and $Res.RadminFound) { $row.Licensed = $(if ($Res.Licensed) { 'Yes' } else { 'No' }) }
            elseif ($Res.RadminFound -eq $false) { $row.Licensed = '-' }
            $msg = [string]$Res.Message
            $row.Outcome = $(if ($Res.Ok) { 'ok' } else { 'err' })
            if ($Res.Ok -and [string]$Res.Via) { $row.Via = [string]$Res.Via }      # the route that worked - Auto goes there first next time
            if ($Action -eq 'Request' -and $Res.Ok -and -not $Res.Skipped) {
                try { $p = & $st.R.SaveRequest -App $st.App -Result $Res -Source 'Fleet'; $msg += " Saved to $p" }
                catch { $msg += " BUT it could not be saved: $($_.Exception.Message)"; $row.Outcome = 'err' }
            }
            if ($Res.Ok -and $Res.Licensed) {
                $moved = @(& $st.R.Complete -App $st.App -Computer $(if ($row.Computer) { $row.Computer } else { $row.Machine }))
                if ($moved.Count -gt 0) { $msg += ' Moved to Done: ' + ($moved -join ', ') }
            }
            $row.Result = $msg; $row.Checked = [string]$Res.Time
            if (-not $row.Checked) { $row.Checked = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') }
            & $st.ScanFiles @($row)
            & $st.RepaintRow $row
            $st.App.LogAction("Fleet $Action $($row.Machine): $(if ($Res.Ok) { 'OK' } else { 'FAILED' }) - $msg")
        }.GetNewClosure()

        $onDone = {
            param($Sum)
            $st.Batch = $null
            & $st.Busy $false
            & $st.Save
            $txt = "$Action finished: $($Sum.Ok) ok, $($Sum.Skipped) skipped, $($Sum.Failed) failed" + $(if ($Sum.Stopped) { ' (stopped)' } else { '' }) + '.'
            if ($Action -eq 'Request' -and $Sum.Ok -gt 0) { $txt += ' Next: take the Requests folder to the internet PC (README-ACTIVATION.txt).' }
            $st.App.SetStatus($txt, $(if ($Sum.Failed -gt 0) { 'warn' } else { 'ok' }))
            $st.App.Log('INFO', 'Radmin', $txt)
        }.GetNewClosure()

        try {
            $st.Batch = & $st.StartBatch -App $app -Action $Action -Items @($items) -Transport $transport -Parallel $set.ParallelMachines `
                                         -TimeoutSec ($set.CallTimeoutSec * 2 + 30) -Credential $st.Cred -OnResult $onResult -OnDone $onDone
        }
        catch {
            $st.Batch = $null; & $st.Busy $false
            $app.SetStatus("Could not start: $($_.Exception.Message)", 'err')
            $app.Log('ERROR', 'Radmin', "Start-RadminBatch: $($_.Exception.ToString())")
        }
    }.GetNewClosure()

    # ---------------- events ----------------
    $btn.Status.Add_Click({ & $st.Run 'Status' }.GetNewClosure())
    $btn.Request.Add_Click({ & $st.Run 'Request' }.GetNewClosure())
    $btn.License.Add_Click({ & $st.Run 'License' }.GetNewClosure())
    $btn.Stop.Add_Click({ if ($st.Batch) { & $st.Batch.Stop; $st.App.SetStatus('Stopping...', 'warn') } }.GetNewClosure())

    $btn.Add.Add_Click({
        $f = New-Object System.Windows.Forms.Form
        $f.Text = 'Add machines'; $f.Size = New-Object System.Drawing.Size(460, 420); $f.StartPosition = 'CenterParent'
        $f.FormBorderStyle = 'FixedDialog'; $f.MaximizeBox = $false; $f.MinimizeBox = $false; $f.BackColor = $st.App.Theme.Surface
        $l = New-Object System.Windows.Forms.Label
        $l.Text = 'Machine names - one per line, or separated by commas / spaces:'; $l.AutoSize = $true; $l.Location = New-Object System.Drawing.Point(12, 12)
        $t = New-Object System.Windows.Forms.TextBox
        $t.Multiline = $true; $t.ScrollBars = 'Vertical'; $t.AcceptsReturn = $true
        $t.Location = New-Object System.Drawing.Point(12, 36); $t.Size = New-Object System.Drawing.Size(420, 290)
        $t.Font = New-Object System.Drawing.Font($st.App.Theme.MonoFontName, 9)
        $ok = $st.App.Theme.MakeButton('Add'); $ok.Location = New-Object System.Drawing.Point(262, 338); $ok.DialogResult = 'OK'
        $cn = $st.App.Theme.MakeButton('Cancel'); $cn.Location = New-Object System.Drawing.Point(350, 338); $cn.DialogResult = 'Cancel'
        $f.Controls.AddRange(@($l, $t, $ok, $cn)); $f.AcceptButton = $null; $f.CancelButton = $cn
        if ($f.ShowDialog() -eq 'OK') { & $st.AddNames @(& $st.R.ParseNames -Text $t.Text) }
        $f.Dispose()
    }.GetNewClosure())

    $btn.Import.Add_Click({
        $d = New-Object System.Windows.Forms.OpenFileDialog
        $d.Title = 'Import machine list'; $d.Filter = 'Text or CSV (*.txt;*.csv)|*.txt;*.csv|All files (*.*)|*.*'
        if ($d.ShowDialog() -eq 'OK') {
            try { & $st.AddNames @(& $st.R.ParseNames -Text ([System.IO.File]::ReadAllText($d.FileName))) }
            catch { $st.App.SetStatus("Import failed: $($_.Exception.Message)", 'err') }
        }
        $d.Dispose()
    }.GetNewClosure())

    $btn.Remove.Add_Click({
        $sel = @($st.Grid.SelectedRows | ForEach-Object { $_.Tag } | Where-Object { $_ })
        if ($sel.Count -eq 0) { $st.App.SetStatus('Select the machines to remove first.', 'warn'); return }
        if ([System.Windows.Forms.MessageBox]::Show("Remove $($sel.Count) machine(s) from the list?", 'Remove', 'OKCancel', 'Question') -ne 'OK') { return }
        foreach ($r in $sel) { $st.Rows.Remove($r) }
        & $st.Save; & $st.Filter.Apply
        $st.App.LogAction("Fleet: removed $($sel.Count) machine(s): $(@($sel | ForEach-Object { $_.Machine }) -join ', ')")
    }.GetNewClosure())

    $btn.Cred.Add_Click({
        $c = $null
        try { $c = Get-Credential -Message 'Admin account for the remote machines (Cancel = use the current Windows login)' } catch { }
        $st.Cred = $c
        $st.Btn.Cred.Text = $(if ($c) { 'Credential: ' + $c.UserName } else { 'Credential...' })
    }.GetNewClosure())

    $btn.Open.Add_Click({
        $t = & $st.R.TransferPaths -App $st.App
        if ($t.Ok) {
            $r = & $st.R.Invoke -App $st.App -Title 'Open transfer folder' -Kind Read -RunLabel 'Open' `
                -Summary 'Open the transfer folder in Explorer (it is created first if missing).' `
                -Code ('Start-Process -FilePath explorer.exe -ArgumentList ' + (& $st.R.Fmt ('"' + $t.Root + '"')))
            if ($r.Errors.Count) { $st.App.SetStatus("Not opened: $($r.Errors[0])", 'err') }
        } else { $st.App.SetStatus($t.Error, 'err') }
        & $st.ShowTransfer
    }.GetNewClosure())

    $btn.Change.Add_Click({
        $d = New-Object System.Windows.Forms.FolderBrowserDialog
        $d.Description = 'Transfer folder (e.g. the USB stick) - Requests, Licenses and Done are made inside it. Cancel keeps the current one.'
        $d.SelectedPath = (& $st.R.TransferFolder -App $st.App)
        if ($d.ShowDialog() -eq 'OK') {
            & $st.R.SetTransfer -App $st.App -Path $d.SelectedPath
            $st.App.LogAction("Fleet: transfer folder on this PC set to $($d.SelectedPath)")
            & $st.ShowTransfer; & $st.ScanFiles; & $st.Filter.Apply
        }
        $d.Dispose()
    }.GetNewClosure())

    $btn.Rescan.Add_Click({ & $st.ShowTransfer; & $st.ScanFiles; & $st.Filter.Apply; $st.App.SetStatus('Transfer folder rescanned.', 'ok') }.GetNewClosure())

    $grid.Add_CellDoubleClick({
        param($s, $e)
        if ($e.RowIndex -lt 0) { return }
        $r = $st.Grid.Rows[$e.RowIndex].Tag
        if ($r) { [void][System.Windows.Forms.MessageBox]::Show(("{0}  ({1})`r`n`r`nLast action: {2}  {3}`r`n`r`n{4}" -f $r.Machine, $r.Computer, $r.LastAction, $r.Checked, $r.Result), 'Result', 'OK', 'Information') }
    }.GetNewClosure())

    $Page.Add_Disposed({ if ($st.Batch) { try { & $st.Batch.Stop } catch { } } }.GetNewClosure())
    Register-EnvironmentChangedHandler -Handler {
        param($a)
        if ($st.Batch) { return }
        $st.Rows = & $st.R.Fleet -App $a
        & $st.ShowTransfer; & $st.ScanFiles; & $st.Filter.Apply
    }.GetNewClosure()

    # Dock order: Fill first, then Bottom, then the Top bands (last added = top-most).
    $Page.Padding = New-Object System.Windows.Forms.Padding(6)
    $Page.Controls.Add($grid)
    $Page.Controls.Add($foot)
    $Page.Controls.Add($bar)
    $Page.Controls.Add($tools)
    $Page.Controls.Add($hdr)

    & $st.ShowTransfer
    & $st.ScanFiles
    & $st.Filter.Apply
}
