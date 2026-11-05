#region -- ADComputers.Ping.Panel.psm1 -------------------------------------------
# Concern : New-PingGroupPanel - the group-ping UI (toolbar + results grid),
#           built into any parent control. Hosted by the Ping Computers dialog
#           (ADComputers.Ping.Dialog) and the Tools > Ping List sub-tab
#           (ADTools.PingList.Tab), so both behave the same.
#
#   [Ping once] [Start continuous | Stop]  Every [2 s v]  Timeout [1000 ms v]
#   [ping -t selected] [Copy results]                 12 computers: 10 up, 2 down
#   +-------------------------------------------------------------------------+
#   | Computer | Status | Address | Time (ms) | Sent | Received | Loss % | ... |
#
# Every round goes through the command engine (Confirm-AppCommand -Kind Read):
# with Environment > Commands = Always, or Shift+click, the exact PowerShell
# for the round is shown first (Copy / Run). Right-click "Ping once" also
# shows / copies it. Continuous rounds after the first are not re-confirmed.
# Right-click a result row: the normal computer menu (RDP, Sessions, LAPS ...)
# for the selected row(s), when a Context is given.
#
# -NamesProvider: script block returning the names for the next round (the
# dialog returns its fixed list; Ping List reads its paste box). The grid keeps
# each computer's counters across rounds; names that leave the list are
# removed, new ones added.
#
# Returns a hashtable: Once / Start / Stop (script blocks), Grid, Timer.
# Call & $api.Stop when the host closes (the dialog does on FormClosed).
#endregion

#region -- New-PingGroupPanel ---------------------------------------------------
function New-PingGroupPanel {
    param(
        [Parameter(Mandatory)] [System.Windows.Forms.Control]$Parent,
        [Parameter(Mandatory)] [scriptblock]$NamesProvider,
        $App = $null,
        [PSCustomObject]$Context = $null,
        [string]$Title = 'Ping'
    )
    if (-not $App) { $App = $script:ADApp }
    $F_UI   = New-Object System.Drawing.Font('Segoe UI', 9)
    $F_UI_B = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)

    # Functions used inside closures - captured here (bare names do not resolve
    # reliably from .GetNewClosure() blocks in this codebase).
    $startRoundFn = ${function:Start-PingRound}
    $getResultFn  = ${function:Get-PingRoundResult}
    $cmdTextFn    = ${function:Get-PingGroupCommandText}
    $confirmFn    = ${function:Confirm-AppCommand}
    $invokeFn     = ${function:Invoke-AppCommand}
    $fmtFn        = ${function:Format-AppCommandValue}
    $regCmdFn     = ${function:Register-AppCommand}
    $newCompMenu  = ${function:New-ComputerContextMenu}

    $C_UP_BG   = [System.Drawing.Color]::FromArgb(226, 239, 218)
    $C_UP_FG   = [System.Drawing.Color]::FromArgb(0, 97, 0)
    $C_DOWN_BG = [System.Drawing.Color]::FromArgb(255, 228, 225)
    $C_DOWN_FG = [System.Drawing.Color]::FromArgb(156, 0, 6)

    # ---- toolbar ----
    $bar = New-Object System.Windows.Forms.Panel
    $bar.Dock = 'Top'; $bar.Height = 76
    $bar.BackColor = [System.Drawing.Color]::FromArgb(235, 238, 242)

    $btnOnce = New-Object System.Windows.Forms.Button
    $btnOnce.Text = 'Ping once'; $btnOnce.Font = $F_UI_B
    $btnOnce.Location = New-Object System.Drawing.Point(6, 6); $btnOnce.Size = New-Object System.Drawing.Size(110, 28)
    $bar.Controls.Add($btnOnce)

    $btnCont = New-Object System.Windows.Forms.Button
    $btnCont.Text = 'Start continuous'; $btnCont.Font = $F_UI
    $btnCont.Location = New-Object System.Drawing.Point(122, 6); $btnCont.Size = New-Object System.Drawing.Size(130, 28)
    $bar.Controls.Add($btnCont)

    $lEvery = New-Object System.Windows.Forms.Label
    $lEvery.Text = 'Every'; $lEvery.AutoSize = $true; $lEvery.Location = New-Object System.Drawing.Point(266, 12)
    $bar.Controls.Add($lEvery)
    $cbEvery = New-Object System.Windows.Forms.ComboBox
    $cbEvery.DropDownStyle = 'DropDownList'; $cbEvery.Location = New-Object System.Drawing.Point(306, 8); $cbEvery.Width = 70
    foreach ($s in @('1 s', '2 s', '5 s', '10 s', '30 s')) { [void]$cbEvery.Items.Add($s) }
    $cbEvery.SelectedIndex = 1
    $bar.Controls.Add($cbEvery)

    $lTo = New-Object System.Windows.Forms.Label
    $lTo.Text = 'Timeout'; $lTo.AutoSize = $true; $lTo.Location = New-Object System.Drawing.Point(390, 12)
    $bar.Controls.Add($lTo)
    $cbTimeout = New-Object System.Windows.Forms.ComboBox
    $cbTimeout.DropDownStyle = 'DropDownList'; $cbTimeout.Location = New-Object System.Drawing.Point(444, 8); $cbTimeout.Width = 90
    foreach ($s in @('500 ms', '1000 ms', '2000 ms', '4000 ms')) { [void]$cbTimeout.Items.Add($s) }
    $cbTimeout.SelectedIndex = 1
    $bar.Controls.Add($cbTimeout)

    $btnPingT = New-Object System.Windows.Forms.Button
    $btnPingT.Text = 'ping -t selected'; $btnPingT.Font = $F_UI
    $btnPingT.Location = New-Object System.Drawing.Point(6, 42); $btnPingT.Size = New-Object System.Drawing.Size(130, 28)
    $bar.Controls.Add($btnPingT)

    $btnCopy = New-Object System.Windows.Forms.Button
    $btnCopy.Text = 'Copy results'; $btnCopy.Font = $F_UI
    $btnCopy.Location = New-Object System.Drawing.Point(142, 42); $btnCopy.Size = New-Object System.Drawing.Size(110, 28)
    $bar.Controls.Add($btnCopy)

    $lSummary = New-Object System.Windows.Forms.Label
    $lSummary.AutoSize = $true; $lSummary.Font = $F_UI_B
    $lSummary.Location = New-Object System.Drawing.Point(266, 48)
    $lSummary.ForeColor = [System.Drawing.Color]::FromArgb(0, 80, 160)
    $lSummary.Text = 'Not pinged yet.'
    $bar.Controls.Add($lSummary)

    # ---- grid ----
    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Dock = 'Fill'
    $grid.ReadOnly = $true; $grid.AllowUserToAddRows = $false; $grid.AllowUserToDeleteRows = $false
    $grid.AllowUserToResizeRows = $false; $grid.RowHeadersVisible = $false
    $grid.MultiSelect = $true; $grid.SelectionMode = 'FullRowSelect'
    $grid.AutoSizeColumnsMode = 'Fill'
    $grid.BackgroundColor = [System.Drawing.Color]::White
    $grid.BorderStyle = 'FixedSingle'
    $grid.Font = $F_UI
    $grid.EnableHeadersVisualStyles = $false
    $grid.ColumnHeadersDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(214, 227, 245)
    $grid.ColumnHeadersDefaultCellStyle.Font = $F_UI_B
    $cols = @(
        @{ N = 'Computer'; H = 'Computer';   W = 150; T = [string] }
        @{ N = 'Status';   H = 'Status';     W = 110; T = [string] }
        @{ N = 'Address';  H = 'Address';    W = 120; T = [string] }
        @{ N = 'TimeMs';   H = 'Time (ms)';  W = 70;  T = [int] }
        @{ N = 'Sent';     H = 'Sent';       W = 55;  T = [int] }
        @{ N = 'Received'; H = 'Received';   W = 65;  T = [int] }
        @{ N = 'Loss';     H = 'Loss %';     W = 60;  T = [int] }
        @{ N = 'LastUp';   H = 'Last reply'; W = 80;  T = [string] }
        @{ N = 'Since';    H = 'State since'; W = 80; T = [string] }
        @{ N = 'Detail';   H = 'Detail';     W = 200; T = [string] }
    )
    foreach ($c in $cols) {
        $col = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
        $col.Name = $c.N; $col.HeaderText = $c.H; $col.FillWeight = $c.W; $col.ValueType = $c.T
        $col.SortMode = 'Automatic'
        [void]$grid.Columns.Add($col)
    }

    $Parent.Controls.Add($grid)     # Fill first, then the Top bar (dock order)
    $Parent.Controls.Add($bar)

    # ---- state ----
    $state = @{
        Rows = (New-Object System.Collections.Specialized.OrderedDictionary([System.StringComparer]::OrdinalIgnoreCase))
        Round = $null; Continuous = $false; NextAt = [datetime]::MinValue; RoundNo = 0
        Timer = (New-Object System.Windows.Forms.Timer)
    }
    $state.Timer.Interval = 200

    $getEvery = {
        $v = 2; [void][int]::TryParse(([string]$cbEvery.SelectedItem -replace '[^0-9]', ''), [ref]$v)
        if ($v -lt 1) { $v = 1 }
        return $v
    }.GetNewClosure()
    $getTimeout = {
        $v = 1000; [void][int]::TryParse(([string]$cbTimeout.SelectedItem -replace '[^0-9]', ''), [ref]$v)
        if ($v -lt 100) { $v = 1000 }
        return $v
    }.GetNewClosure()

    # Rows follow the current name list: keep known computers' counters.
    $syncRows = {
        param([string[]]$Names)
        $want = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($n in $Names) { [void]$want.Add($n) }
        foreach ($k in @($state.Rows.Keys)) {
            if (-not $want.Contains([string]$k)) {
                try { $grid.Rows.Remove($state.Rows[$k].Row) } catch { }
                $state.Rows.Remove($k)
            }
        }
        foreach ($n in $Names) {
            if ($state.Rows.Contains($n)) { continue }
            $i = $grid.Rows.Add()
            $row = $grid.Rows[$i]
            $row.Cells['Computer'].Value = $n
            $row.Cells['Status'].Value = 'pending'
            $row.Cells['Sent'].Value = 0; $row.Cells['Received'].Value = 0
            $state.Rows.Add($n, @{ Row = $row; Sent = 0; Recv = 0; Up = $null; Since = '' })
        }
    }.GetNewClosure()

    $summary = {
        $up = 0; $down = 0; $wait = 0
        foreach ($k in $state.Rows.Keys) {
            $u = $state.Rows[$k].Up
            if ($null -eq $u) { $wait++ } elseif ($u) { $up++ } else { $down++ }
        }
        $t = '{0} computer(s): {1} up, {2} down' -f $state.Rows.Count, $up, $down
        if ($wait -gt 0) { $t += ", $wait waiting" }
        if ($state.RoundNo -gt 0) { $t += "  -  round $($state.RoundNo)" }
        if ($state.Continuous) { $t += '  (continuous)' }
        $lSummary.Text = $t
        if ($down -gt 0) { $lSummary.ForeColor = $C_DOWN_FG } elseif ($up -gt 0) { $lSummary.ForeColor = $C_UP_FG } else { $lSummary.ForeColor = [System.Drawing.Color]::FromArgb(0, 80, 160) }
    }.GetNewClosure()

    $applyResult = {
        param($R)
        if (-not $state.Rows.Contains($R.Name)) { return }
        $s = $state.Rows[$R.Name]; $row = $s.Row
        $s.Sent++
        if ($R.Up) { $s.Recv++ }
        if ($null -eq $s.Up -or [bool]$s.Up -ne [bool]$R.Up) { $s.Since = (Get-Date).ToString('HH:mm:ss') }
        $s.Up = [bool]$R.Up
        if ($R.Up) { $row.Cells['Status'].Value = 'Up' }
        else { $st = 'Down'; if ($R.Status -and $R.Status -ne 'Error') { $st = "Down ($($R.Status))" } elseif ($R.Status -eq 'Error') { $st = 'Error' }; $row.Cells['Status'].Value = $st }
        $row.Cells['Address'].Value  = [string]$R.Address
        $row.Cells['TimeMs'].Value   = $R.TimeMs
        $row.Cells['Sent'].Value     = [int]$s.Sent
        $row.Cells['Received'].Value = [int]$s.Recv
        $row.Cells['Loss'].Value     = [int][Math]::Round((($s.Sent - $s.Recv) * 100.0) / [Math]::Max(1, $s.Sent))
        if ($R.Up) { $row.Cells['LastUp'].Value = (Get-Date).ToString('HH:mm:ss') }
        $row.Cells['Since'].Value    = $s.Since
        $row.Cells['Detail'].Value   = [string]$R.Detail
        if ($R.Up) { $row.DefaultCellStyle.BackColor = $C_UP_BG; $row.Cells['Status'].Style.ForeColor = $C_UP_FG }
        else       { $row.DefaultCellStyle.BackColor = $C_DOWN_BG; $row.Cells['Status'].Style.ForeColor = $C_DOWN_FG }
    }.GetNewClosure()

    $beginRound = {
        $names = @(& $NamesProvider)
        & $syncRows $names
        if ($names.Count -eq 0) { $lSummary.Text = 'No computers to ping.'; return $false }
        $state.RoundNo++
        $state.Round = & $startRoundFn -Names $names -TimeoutMs (& $getTimeout)
        & $summary
        return $true
    }.GetNewClosure()

    $setContinuousUi = {
        if ($state.Continuous) { $btnCont.Text = 'Stop'; $btnCont.Font = $F_UI_B } else { $btnCont.Text = 'Start continuous'; $btnCont.Font = $F_UI }
    }.GetNewClosure()

    $state.Timer.Add_Tick({
        if ($state.Round) {
            $pending = 0
            foreach ($it in $state.Round) {
                if ($it.PSObject.Properties['Done'] -and $it.Done) { continue }
                $r = & $getResultFn -Item $it
                if ($null -eq $r) { $pending++; continue }
                $it | Add-Member -NotePropertyName Done -NotePropertyValue $true -Force
                & $applyResult $r
            }
            if ($pending -gt 0) { return }
            $state.Round = $null
            & $summary
            if ($state.Continuous) { $state.NextAt = [datetime]::Now.AddSeconds((& $getEvery)) }
            else { $state.Timer.Stop(); $btnOnce.Enabled = $true }
            return
        }
        if ($state.Continuous -and [datetime]::Now -ge $state.NextAt) {
            if (-not (& $beginRound)) { $state.Continuous = $false; & $setContinuousUi; $state.Timer.Stop(); $btnOnce.Enabled = $true }
        }
    }.GetNewClosure())

    # The exact command for the current list / timeout (shown before a round
    # when the Commands setting or Shift asks for it; right-click on Ping once).
    $codeNow = {
        $names = @(& $NamesProvider)
        $every = 0; if ($state.Continuous) { $every = & $getEvery }
        return (& $cmdTextFn -Names $names -TimeoutMs (& $getTimeout) -IntervalSeconds $every)
    }.GetNewClosure()

    $api = @{ Grid = $grid; Timer = $state.Timer; State = $state; Refresh = $summary }

    $api.Once = {
        param([switch]$NoConfirm)
        if ($state.Round) { return }
        $names = @(& $NamesProvider)
        if ($names.Count -eq 0) { & $syncRows @(); $lSummary.Text = 'No computers to ping.'; return }
        if (-not $NoConfirm -and $confirmFn) {
            $ok = & $confirmFn -App $App -Title "$Title - ping once" -Kind Read -RunLabel 'Ping' `
                -Summary "Ping $($names.Count) computer(s) once." -Code (& $cmdTextFn -Names $names -TimeoutMs (& $getTimeout))
            if (-not $ok) { return }
        }
        if (& $beginRound) { $btnOnce.Enabled = $false; $state.Timer.Start() }
    }.GetNewClosure()

    $api.Start = {
        param([switch]$NoConfirm)
        if ($state.Continuous) { return }
        $names = @(& $NamesProvider)
        if ($names.Count -eq 0) { & $syncRows @(); $lSummary.Text = 'No computers to ping.'; return }
        if (-not $NoConfirm -and $confirmFn) {
            $every = & $getEvery
            $ok = & $confirmFn -App $App -Title "$Title - ping continuously" -Kind Read -RunLabel 'Start' `
                -Summary "Ping $($names.Count) computer(s) every $every s until Stop." `
                -Code (& $cmdTextFn -Names $names -TimeoutMs (& $getTimeout) -IntervalSeconds $every)
            if (-not $ok) { return }
        }
        $state.Continuous = $true
        & $setContinuousUi
        $btnOnce.Enabled = $false
        $state.NextAt = [datetime]::MinValue
        $state.Timer.Start()
    }.GetNewClosure()

    $api.Stop = {
        $state.Continuous = $false
        & $setContinuousUi
        if (-not $state.Round) { $state.Timer.Stop(); $btnOnce.Enabled = $true }
        & $summary
    }.GetNewClosure()

    $onceFn = $api.Once; $startFn = $api.Start; $stopFn = $api.Stop
    $btnOnce.Add_Click({ & $onceFn }.GetNewClosure())
    $btnCont.Add_Click({ if ($state.Continuous) { & $stopFn } else { & $startFn } }.GetNewClosure())

    if ($regCmdFn) { & $regCmdFn -App $App -Control $btnOnce -Title "$Title - ping once" -Code $codeNow }

    # Names of the selected rows (or every row when none is selected).
    $selectedNames = {
        $sel = @($grid.SelectedRows | ForEach-Object { [string]$_.Cells['Computer'].Value } | Where-Object { $_ })
        return , $sel
    }.GetNewClosure()

    $btnPingT.Add_Click({
        $names = @(& $selectedNames)
        if ($names.Count -eq 0) { [System.Windows.Forms.MessageBox]::Show('Select one or more rows first.', 'ping -t', 'OK', 'Information') | Out-Null; return }
        $lines = @($names | ForEach-Object { 'Start-Process -FilePath ''cmd.exe'' -ArgumentList ' + (& $fmtFn ("/k ping -t $_")) })
        if ($invokeFn) {
            $r = & $invokeFn -App $App -Title 'ping -t (command window)' -Kind Read -Code ($lines -join "`r`n") `
                -Summary "Open a command window running ping -t for $($names.Count) computer(s)."
            if ($r.Errors.Count -gt 0) { $lSummary.Text = "ping -t: $($r.Errors[0])" }
        }
    }.GetNewClosure())

    $btnCopy.Add_Click({
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.AppendLine((@($grid.Columns | ForEach-Object { $_.HeaderText }) -join "`t"))
        foreach ($row in $grid.Rows) {
            $vals = @(); foreach ($c in $grid.Columns) { $vals += [string]$row.Cells[$c.Index].Value }
            [void]$sb.AppendLine(($vals -join "`t"))
        }
        try { [System.Windows.Forms.Clipboard]::SetText($sb.ToString()); $lSummary.Text = "Copied $($grid.Rows.Count) row(s) to the clipboard (tab-separated, pastes into Excel)." } catch { }
    }.GetNewClosure())

    # Right-click a row: the usual computer menu for the selected row(s).
    if ($newCompMenu) {
        $provider = { @(& $selectedNames | ForEach-Object { [PSCustomObject]@{ Name = $_ } }) }.GetNewClosure()
        try { $grid.ContextMenuStrip = & $newCompMenu -TargetProvider $provider -Context $Context } catch { }
    }
    # Right-click selects the row under the mouse first (like the other grids).
    $grid.Add_CellMouseDown({
        param($s, $e)
        if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Right -and $e.RowIndex -ge 0) {
            if (-not $grid.Rows[$e.RowIndex].Selected) { $grid.ClearSelection(); $grid.Rows[$e.RowIndex].Selected = $true }
        }
    }.GetNewClosure())

    return $api
}
#endregion
