#region -- ADDirectory.UserSessions.Dialog.psm1 -------------------------------
# Concern : Show-UserSessionsDialog - fixed-size popup launched from the
#           Directory tab Users grid right-click menu ("Find Domain Sessions...").
#           Scans every enabled domain computer with quser via a throttled
#           runspace pool, streaming results into a ListView as they arrive.
#           Includes Stop, Copy, Export CSV, Close, and a ListView right-click
#           "Force Logoff Selected Session(s)" action.
# Load order: 26 - depends on Services.AD.Connection.Query (Get-DomainComputers)
#                            (no other AD-Admin module deps; self-contained dialog)
# Notes     : Runspace pool capped at 15 threads per RDS dual-role constraint
#             (NetworkEnvironment.txt [RDS_Constraint] Tier = LIMITED).
#             Force Logoff shells out to logoff.exe /server:<computer> per
#             selected session (native session-manager RPC - no WinRM/PS
#             remoting dependency, no new module dependency).
#             No ternary operators, no ??= operator, no -Parallel foreach.
#             PS 5.1 compatible throughout.
#endregion

#region -- quser scriptblock (runs inside each runspace) ---------------------
# Defined at script scope so Show-UserSessionsDialog can capture it cleanly
# via a local variable before passing into runspaces (same pattern as
# $script:QuserBlock in the standalone AD Session Investigator tool).
$script:SesQuserBlock = {
    param([string]$ComputerName, [string]$SamAccount)
    try {
        $raw = (query user /server:$ComputerName 2>$null)
        if (-not $raw) { return $null }
        $pattern = "(?i)^\s*>?\s*$([regex]::Escape($SamAccount))\s"
        $line    = $raw | Where-Object { $_ -match $pattern } | Select-Object -First 1
        if ($line) {
            $line      = $line.Trim()
            $logonTime = $null
            if ($line -match '(\d{1,2}/\d{1,2}/\d{4}\s+\d{1,2}:\d{2}\s+[AP]M)') {
                try { $logonTime = [datetime]$Matches[1] } catch { $logonTime = $null }
            }
            $sessionId = $null
            if ($line -match '^\S+\s+\S+\s+(\d+)\s') {
                $sessionId = $Matches[1]
            } elseif ($line -match '^\S+\s+(\d+)\s') {
                $sessionId = $Matches[1]
            }
            return [PSCustomObject]@{
                ComputerName = $ComputerName
                SessionLine  = $line
                LogonTime    = $logonTime
                SessionId    = $sessionId
                Found        = $true
            }
        }
    } catch { }
    return $null
}
#endregion

#region -- Show-UserSessionsDialog --------------------------------------------
function Show-UserSessionsDialog {
    <#
    .SYNOPSIS
        Opens a fixed-size popup that scans every enabled domain computer for
        an active quser session belonging to the specified SamAccountName.
        Results stream into a ListView as each computer responds. Right-click
        one or more result rows to force-logoff those sessions.
    .PARAMETER Sam
        SamAccountName of the user to scan for.
    .PARAMETER DisplayName
        Display name shown in the dialog title (optional).
    .PARAMETER Context
        Shared PSCustomObject context (TargetDC used for Get-DomainComputers).
    #>
    param(
        [string]$Sam,
        [string]$DisplayName = '',
        [PSCustomObject]$Context
    )

    if (-not $Sam) { return }

    $THREAD_CAP = 15   # RDS dual-role throttle
    $F_UI       = New-Object System.Drawing.Font('Segoe UI', 9)
    $F_UI_B     = New-Object System.Drawing.Font('Segoe UI', 9,  [System.Drawing.FontStyle]::Bold)
    $F_UI_T     = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
    $F_MONO     = New-Object System.Drawing.Font('Consolas', 9)

    $titleText = if ($DisplayName) { "$Sam  ($DisplayName)" } else { $Sam }

    # ---- Form -----------------------------------------------------------
    $dlg                  = New-Object System.Windows.Forms.Form
    $dlg.Text             = "Find Domain Sessions - $Sam"
    $dlg.ClientSize       = New-Object System.Drawing.Size(980, 580)
    $dlg.FormBorderStyle  = 'FixedSingle'
    $dlg.MaximizeBox      = $false
    $dlg.MinimizeBox      = $false
    $dlg.StartPosition    = 'CenterParent'
    $dlg.BackColor        = [System.Drawing.Color]::FromArgb(235, 238, 242)
    $dlg.Font             = $F_UI

    # Title bar
    $pTitle               = New-Object System.Windows.Forms.Panel
    $pTitle.Location      = New-Object System.Drawing.Point(0, 0)
    $pTitle.Size          = New-Object System.Drawing.Size(980, 48)
    $pTitle.BackColor     = [System.Drawing.Color]::FromArgb(0, 99, 177)
    $dlg.Controls.Add($pTitle)

    $lTitle               = New-Object System.Windows.Forms.Label
    $lTitle.Text          = "   Find Domain Sessions  -  $titleText"
    $lTitle.Location      = New-Object System.Drawing.Point(0, 0)
    $lTitle.Size          = New-Object System.Drawing.Size(980, 48)
    $lTitle.Font          = $F_UI_T
    $lTitle.ForeColor     = [System.Drawing.Color]::White
    $lTitle.TextAlign     = 'MiddleLeft'
    $pTitle.Controls.Add($lTitle)

    # Progress bar
    $prog                 = New-Object System.Windows.Forms.ProgressBar
    $prog.Location        = New-Object System.Drawing.Point(12, 56)
    $prog.Size            = New-Object System.Drawing.Size(956, 16)
    $prog.Style           = 'Continuous'
    $dlg.Controls.Add($prog)

    # Status label
    $lStatus              = New-Object System.Windows.Forms.Label
    $lStatus.Text         = 'Loading domain computer list...'
    $lStatus.Location     = New-Object System.Drawing.Point(12, 76)
    $lStatus.Size         = New-Object System.Drawing.Size(956, 20)
    $lStatus.Font         = $F_UI
    $lStatus.ForeColor    = [System.Drawing.Color]::DimGray
    $dlg.Controls.Add($lStatus)

    # Summary label
    $lSummary             = New-Object System.Windows.Forms.Label
    $lSummary.Text        = ''
    $lSummary.Location    = New-Object System.Drawing.Point(12, 98)
    $lSummary.Size        = New-Object System.Drawing.Size(956, 22)
    $lSummary.Font        = $F_UI_B
    $lSummary.TextAlign   = 'MiddleCenter'
    $lSummary.Visible     = $false
    $dlg.Controls.Add($lSummary)

    # ListView
    $lv                      = New-Object System.Windows.Forms.ListView
    $lv.Location             = New-Object System.Drawing.Point(12, 124)
    $lv.Size                 = New-Object System.Drawing.Size(956, 390)
    $lv.View                 = 'Details'
    $lv.FullRowSelect        = $true
    $lv.MultiSelect          = $true
    $lv.GridLines            = $true
    $lv.Font                 = $F_MONO
    $lv.BorderStyle          = 'FixedSingle'
    $lv.Columns.Add('Computer',          200) | Out-Null
    $lv.Columns.Add('Operating System',  200) | Out-Null
    $lv.Columns.Add('Logon Time',        145) | Out-Null
    $lv.Columns.Add('Duration',           90) | Out-Null
    $lv.Columns.Add('Session Info',      290) | Out-Null
    $dlg.Controls.Add($lv)

    # ---- ListView right-click context menu: Force Logoff (control only -
    #      event handlers wired down in the "Button events" section below,
    #      alongside the rest of this dialog's event wiring) --------------
    $cmSession              = New-Object System.Windows.Forms.ContextMenuStrip
    $miForceLogoff          = New-Object System.Windows.Forms.ToolStripMenuItem
    $miForceLogoff.Text     = 'Force Logoff Selected Session(s)'
    $miForceLogoff.Font     = $F_UI_B
    [void]$cmSession.Items.Add($miForceLogoff)
    $lv.ContextMenuStrip    = $cmSession

    # Bottom button panel
    $pBtn                 = New-Object System.Windows.Forms.Panel
    $pBtn.Location        = New-Object System.Drawing.Point(12, 522)
    $pBtn.Size            = New-Object System.Drawing.Size(956, 46)
    $pBtn.BackColor       = [System.Drawing.Color]::FromArgb(235, 238, 242)
    $dlg.Controls.Add($pBtn)

    $btnStop              = New-Object System.Windows.Forms.Button
    $btnStop.Text         = 'Stop'
    $btnStop.Location     = New-Object System.Drawing.Point(0, 8)
    $btnStop.Size         = New-Object System.Drawing.Size(90, 30)
    $btnStop.Font         = $F_UI_B
    $btnStop.FlatStyle    = 'Standard'
    $pBtn.Controls.Add($btnStop)

    $btnCopy              = New-Object System.Windows.Forms.Button
    $btnCopy.Text         = 'Copy to Clipboard'
    $btnCopy.Location     = New-Object System.Drawing.Point(98, 8)
    $btnCopy.Size         = New-Object System.Drawing.Size(140, 30)
    $btnCopy.Font         = $F_UI
    $btnCopy.FlatStyle    = 'Standard'
    $btnCopy.Enabled      = $false
    $pBtn.Controls.Add($btnCopy)

    $btnExport            = New-Object System.Windows.Forms.Button
    $btnExport.Text       = 'Export CSV'
    $btnExport.Location   = New-Object System.Drawing.Point(246, 8)
    $btnExport.Size       = New-Object System.Drawing.Size(110, 30)
    $btnExport.Font       = $F_UI
    $btnExport.FlatStyle  = 'Standard'
    $btnExport.Enabled    = $false
    $pBtn.Controls.Add($btnExport)

    $btnClose             = New-Object System.Windows.Forms.Button
    $btnClose.Text        = 'Close'
    $btnClose.Location    = New-Object System.Drawing.Point(856, 8)
    $btnClose.Size        = New-Object System.Drawing.Size(100, 30)
    $btnClose.Font        = $F_UI
    $btnClose.FlatStyle   = 'Standard'
    $pBtn.Controls.Add($btnClose)

    $lThreads             = New-Object System.Windows.Forms.Label
    $lThreads.Text        = "Threads: $THREAD_CAP"
    $lThreads.Location    = New-Object System.Drawing.Point(700, 14)
    $lThreads.Size        = New-Object System.Drawing.Size(148, 18)
    $lThreads.Font        = $F_UI
    $lThreads.ForeColor   = [System.Drawing.Color]::DimGray
    $lThreads.TextAlign   = 'MiddleRight'
    $pBtn.Controls.Add($lThreads)

    # ---- Scan state -----------------------------------------------------
    $script:SesScanStop = $false

    # Capture the quser block locally so closures can reach it
    $quserBlock = $script:SesQuserBlock

    # ---- Button events --------------------------------------------------
    $btnStop.Add_Click({ $script:SesScanStop = $true })
    $btnClose.Add_Click({ $dlg.Close() })

    # Right-click on an unselected row selects it (so right-click acts on
    # the row under the cursor rather than a stale prior selection).
    $lv.Add_MouseUp({
        param($evtSender, $evtArgs)
        if ($evtArgs.Button -eq [System.Windows.Forms.MouseButtons]::Right) {
            $hit = $lv.HitTest($evtArgs.Location)
            if ($hit -and $hit.Item -and (-not $hit.Item.Selected)) {
                $lv.SelectedItems.Clear()
                $hit.Item.Selected = $true
            }
        }
    })

    # Only offer the Force Logoff menu when at least one row is selected.
    $cmSession.Add_Opening({
        param($evtSender, $evtArgs)
        if ($lv.SelectedItems.Count -eq 0) {
            $evtArgs.Cancel = $true
            return
        }
        $miForceLogoff.Text = if ($lv.SelectedItems.Count -eq 1) {
            'Force Logoff Selected Session'
        } else {
            "Force Logoff $($lv.SelectedItems.Count) Selected Sessions"
        }
    })

    $miForceLogoff.Add_Click({
        $targets = [System.Collections.Generic.List[hashtable]]::new()
        foreach ($sel in $lv.SelectedItems) {
            $tag = [string]$sel.Tag
            if (-not $tag) { continue }
            $parts = $tag.Split('|')
            if ($parts.Count -lt 2 -or -not $parts[1]) { continue }
            [void]$targets.Add(@{ Item = $sel; Computer = $parts[0]; SessionId = $parts[1] })
        }

        if ($targets.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show(
                'The selected row(s) do not have a valid session ID to log off.',
                'Force Logoff', 'OK', 'Warning') | Out-Null
            return
        }

        $confirmLines = foreach ($t in $targets) { "  $($t.Computer)  (session $($t.SessionId))" }
        $confirmMsg   = "Force logoff the following session(s)?`r`n`r`n$($confirmLines -join "`r`n")`r`n`r`nThis disconnects the user immediately and cannot be undone."
        $confirm      = [System.Windows.Forms.MessageBox]::Show(
            $confirmMsg, 'Confirm Force Logoff',
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning,
            [System.Windows.Forms.MessageBoxDefaultButton]::Button2)
        if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) { return }

        $okCount   = 0
        $failCount = 0

        foreach ($t in $targets) {
            $lStatus.Text = "Logging off $($t.Computer) (session $($t.SessionId))..."
            [System.Windows.Forms.Application]::DoEvents()

            $succeeded = $false
            try {
                $psi                         = New-Object System.Diagnostics.ProcessStartInfo
                $psi.FileName                = 'logoff.exe'
                $psi.Arguments               = "$($t.SessionId) /server:$($t.Computer)"
                $psi.UseShellExecute         = $false
                $psi.CreateNoWindow          = $true
                $psi.RedirectStandardError   = $true
                $psi.RedirectStandardOutput  = $true

                $proc = [System.Diagnostics.Process]::Start($psi)
                $proc.WaitForExit(15000) | Out-Null

                if (-not $proc.HasExited) {
                    try { $proc.Kill() } catch { }
                    $succeeded = $false
                } elseif ($proc.ExitCode -eq 0) {
                    $succeeded = $true
                } else {
                    $succeeded = $false
                }
            } catch {
                $succeeded = $false
            }

            if ($succeeded) {
                $okCount++
                [void]$lv.Items.Remove($t.Item)
            } else {
                $failCount++
                $t.Item.BackColor = [System.Drawing.Color]::FromArgb(252, 213, 213)
                $t.Item.ForeColor = [System.Drawing.Color]::FromArgb(139, 0, 0)
            }
        }

        if ($failCount -eq 0) {
            $lStatus.Text = "Force logoff complete - $okCount session(s) logged off."
        } else {
            $lStatus.Text = "Force logoff complete - $okCount succeeded, $failCount failed (see highlighted rows)."
        }

        if ($lv.Items.Count -eq 0) {
            $btnCopy.Enabled   = $false
            $btnExport.Enabled = $false
        }
    })

    $btnCopy.Add_Click({
        $lines = [System.Collections.Generic.List[string]]::new()
        foreach ($item in $lv.Items) {
            $cols = [System.Collections.Generic.List[string]]::new()
            [void]$cols.Add($item.Text)
            foreach ($sub in $item.SubItems) {
                if ($sub.Text -ne $item.Text) { [void]$cols.Add($sub.Text) }
            }
            [void]$lines.Add($cols -join "`t")
        }
        if ($lines.Count -gt 0) {
            [System.Windows.Forms.Clipboard]::SetText($lines -join "`r`n")
            $lStatus.Text = "Results copied to clipboard."
        }
    })

    $btnExport.Add_Click({
        $sfd          = New-Object System.Windows.Forms.SaveFileDialog
        $sfd.Filter   = 'CSV Files (*.csv)|*.csv|All Files (*.*)|*.*'
        $stamp        = Get-Date -Format 'yyyyMMdd_HHmm'
        $sfd.FileName = "DomainSessions_${Sam}_$stamp.csv"
        if ($sfd.ShowDialog() -eq 'OK') {
            $rows = [System.Collections.Generic.List[PSCustomObject]]::new()
            foreach ($item in $lv.Items) {
                [void]$rows.Add([PSCustomObject]@{
                    Computer        = $item.Text
                    OperatingSystem = $item.SubItems[1].Text
                    LogonTime       = $item.SubItems[2].Text
                    Duration        = $item.SubItems[3].Text
                    SessionInfo     = $item.SubItems[4].Text
                })
            }
            $rows | Export-Csv -Path $sfd.FileName -NoTypeInformation
            $lStatus.Text = "Exported to: $($sfd.FileName)"
        }
    })

    # ---- Scan runs on Shown so the form is visible while working --------
    $dlg.Add_Shown({
        [System.Windows.Forms.Application]::DoEvents()

        $srvParam = if ($Context -and $Context.TargetDC) { @{ Server = $Context.TargetDC } } else { @{} }

        # Build OS map from domain computer list
        $lStatus.Text = 'Loading domain computer list...'
        [System.Windows.Forms.Application]::DoEvents()

        $osMap = @{}
        try {
            $computers = Get-DomainComputers @srvParam
            foreach ($c in $computers) {
                $osMap[[string]$c.Name] = if ($c.OperatingSystem) { [string]$c.OperatingSystem } else { 'Unknown' }
            }
        } catch {
            $lStatus.Text = "Failed to load computer list: $($_.Exception.Message)"
            $btnStop.Enabled = $false
            return
        }

        $allNames = @($osMap.Keys | Sort-Object)
        $total    = $allNames.Count

        if ($total -eq 0) {
            $lStatus.Text    = 'No domain computers found.'
            $btnStop.Enabled = $false
            return
        }

        $prog.Maximum = $total
        $prog.Value   = 0
        $lStatus.Text = "Starting scan - $total computers, $THREAD_CAP threads..."
        [System.Windows.Forms.Application]::DoEvents()

        $C_OK_BACK = [System.Drawing.Color]::FromArgb(198, 239, 206)
        $C_OK_FORE = [System.Drawing.Color]::FromArgb(0, 97, 0)

        $pool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(1, $THREAD_CAP)
        $pool.Open()

        $jobs = [System.Collections.Generic.List[hashtable]]::new()
        foreach ($pcName in $allNames) {
            if ($script:SesScanStop) { break }
            $ps = [System.Management.Automation.PowerShell]::Create()
            $ps.RunspacePool = $pool
            [void]$ps.AddScript($quserBlock).AddArgument($pcName).AddArgument($Sam)
            [void]$jobs.Add(@{ PS = $ps; Handle = $ps.BeginInvoke(); Computer = $pcName })
        }

        $remaining  = [System.Collections.Generic.List[hashtable]]::new($jobs)
        $scanned    = 0
        $found      = 0
        $wasStopped = $false

        while ($remaining.Count -gt 0) {
            if ($script:SesScanStop) {
                # Do NOT call PS.Dispose(), PS.Stop(), or pool.Close() here.
                # All three block the calling thread until every in-flight
                # pipeline finishes - and pipelines stuck on a slow/offline
                # host's quser call can take 20-30s+ each, which is exactly
                # the "stops scanning but the popup itself won't close" hang.
                # Instead, just drop every reference to $jobs/$remaining/$pool
                # below and let the abandoned runspaces finish on their own;
                # .NET reclaims them via GC without blocking this thread.
                $wasStopped = $true
                $remaining.Clear()
                break
            }

            $done = @($remaining | Where-Object { $_.Handle.IsCompleted })
            foreach ($job in $done) {
                $result = $null
                try { $result = $job.PS.EndInvoke($job.Handle) } catch { }
                $job.PS.Dispose()
                [void]$remaining.Remove($job)
                $scanned++

                if ($result -and $result.Found) {
                    $found++

                    $logonStr = '-'
                    if ($result.LogonTime) {
                        $logonStr = $result.LogonTime.ToString('yyyy-MM-dd  HH:mm')
                    }

                    $durStr = '-'
                    if ($result.LogonTime) {
                        $span = (Get-Date) - $result.LogonTime
                        if ($span.TotalDays -ge 1) {
                            $durStr = "$([int]$span.TotalDays)d $($span.Hours)h $($span.Minutes)m"
                        } else {
                            $durStr = "$($span.Hours)h $($span.Minutes)m"
                        }
                    }

                    $osText = if ($osMap.ContainsKey($job.Computer)) { $osMap[$job.Computer] } else { 'Unknown' }

                    $item           = New-Object System.Windows.Forms.ListViewItem($job.Computer)
                    $item.BackColor = $C_OK_BACK
                    $item.ForeColor = $C_OK_FORE
                    $item.Tag       = "$($job.Computer)|$($result.SessionId)"
                    [void]$item.SubItems.Add($osText)
                    [void]$item.SubItems.Add($logonStr)
                    [void]$item.SubItems.Add($durStr)
                    [void]$item.SubItems.Add($result.SessionLine)
                    $lv.Items.Add($item) | Out-Null
                }

                $prog.Value   = [Math]::Min($scanned, $total)
                $lStatus.Text = "Scanning $scanned / $total  |  Sessions found: $found"
                [System.Windows.Forms.Application]::DoEvents()
            }

            # DoEvents instead of Start-Sleep keeps the UI responsive between
            # poll cycles and ensures the Stop button click registers immediately
            # without waiting for a sleep to expire.
            if ($remaining.Count -gt 0) { [System.Windows.Forms.Application]::DoEvents() }
        }

        # Only close/dispose the pool on normal completion. On the stop path
        # there may still be abandoned pipelines running inside it, and
        # RunspacePool.Close() blocks until they all finish - skip it and let
        # GC reclaim the pool once those background pipelines wrap up on
        # their own.
        if (-not $wasStopped) {
            $pool.Close()
            $pool.Dispose()
        }

        $btnStop.Enabled = $false

        if ($wasStopped) {
            $lStatus.Text  = "Scan stopped at $scanned / $total  |  Sessions found: $found"
            $lSummary.Text = "$Sam  -  scan stopped  |  $found session(s) found so far"
        } else {
            $prog.Value    = $total
            $lStatus.Text  = "Scan complete  |  $total computers checked  |  $found session(s) found"
            $lSummary.Text = if ($found -gt 0) {
                "$Sam is currently logged in on $found computer(s)"
            } else {
                "No active sessions found for $Sam across $total computers"
            }
        }

        $lSummary.Visible = $true

        if ($found -gt 0) {
            $btnCopy.Enabled   = $true
            $btnExport.Enabled = $true
        }
    })

    [void]$dlg.ShowDialog()
}
#endregion

Export-ModuleMember -Function Show-UserSessionsDialog
