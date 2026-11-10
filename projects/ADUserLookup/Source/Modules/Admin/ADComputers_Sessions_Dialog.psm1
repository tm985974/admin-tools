#region -- ADComputers.Sessions.Dialog.psm1 ------------------------------------
# Concern : Show-ComputerSessionsDialog - fixed-size popup invoked from the
#           Computers grid right-click menu ("Show Sessions...", New-
#           ComputerContextMenu / ADDirectory.Menus). Lists every active quser
#           session on ONE target computer (inverse of ADDirectory.UserSessions
#           .Dialog, which scans every computer for ONE user). ListView
#           supports multi-select with a right-click "Force Logoff Selected
#           Session(s)" action.
# Load order: 85a - single-target dialog captured by New-ComputerContextMenu
#                    (ADDirectory.Menus, load order 15). Same precedent as
#                    ADComputers.BitLocker.Dialog (83) / ADComputers.LAPS.Dialog
#                    (85): the factory only captures ${function:Name} when it
#                    is INVOKED (during Initialize-AllTabs, after the full
#                    module-load loop finishes), so this module is free to
#                    load anywhere in the ADComputers block - it does not need
#                    to precede ADDirectory_Menus.
# Notes     : Single quser call against one host - no runspace pool needed
#             (unlike ADDirectory.UserSessions.Dialog's whole-domain scan).
#             Force Logoff shells out to logoff.exe /server:<computer>, same
#             native-RPC approach as ADDirectory.UserSessions.Dialog - no
#             WinRM/PS-remoting dependency, no new module dependency.
#             Confirm-Action (Services.AD.Reporting) used for the destructive-
#             action confirmation, matching house style for AD actions
#             elsewhere in the suite.
#             No ternary operators, no ??= operator, no -Parallel foreach.
#             PS 5.1 compatible throughout.
#endregion

#region -- Format-IdleTime (private helper) ------------------------------------
function Format-IdleTime {
    <#
    .SYNOPSIS
        Converts quser's raw IDLE TIME value into a readable "Xd Yh Zm"
        display. quser emits idle time in one of three raw shapes:
          '.'          - none / currently active
          '27+12:03'   - days+HH:MM  (27 days, 12 hours, 3 minutes)
          '01:42'      - HH:MM       (1 hour, 42 minutes)
          '42'         - bare minutes (under an hour)
        Not exported - internal to this module.
    #>
    param([string]$Raw)

    if (-not $Raw -or $Raw -eq '.' -or $Raw -eq 'none' -or $Raw -eq '-') { return '-' }

    $days    = 0
    $hours   = 0
    $minutes = 0

    if ($Raw -match '^(\d+)\+(\d+):(\d+)$') {
        $days    = [int]$Matches[1]
        $hours   = [int]$Matches[2]
        $minutes = [int]$Matches[3]
    } elseif ($Raw -match '^(\d+):(\d+)$') {
        $hours   = [int]$Matches[1]
        $minutes = [int]$Matches[2]
    } elseif ($Raw -match '^(\d+)$') {
        $totalMinutes = [int]$Matches[1]
        $hours        = [math]::Floor($totalMinutes / 60)
        $minutes      = $totalMinutes % 60
    } else {
        # Unrecognized shape - show the raw value rather than hide data.
        return $Raw
    }

    $parts = [System.Collections.Generic.List[string]]::new()
    if ($days -gt 0)  { [void]$parts.Add("${days}d") }
    if ($hours -gt 0) { [void]$parts.Add("${hours}h") }
    if ($minutes -gt 0 -or $parts.Count -eq 0) { [void]$parts.Add("${minutes}m") }
    return ($parts -join ' ')
}
#endregion

#region -- Get-ComputerSessionList (private helper) ---------------------------
function Get-ComputerSessionList {
    <#
    .SYNOPSIS
        Runs quser against a single computer and returns every session found
        as a PSCustomObject (User, SessionId, State, IdleTime, LogonTime).
        Not exported - internal to this module.
    #>
    param([string]$ComputerName)

    $sessions = [System.Collections.Generic.List[PSCustomObject]]::new()
    $raw = (query user /server:$ComputerName 2>$null)
    if (-not $raw) { return $sessions }

    foreach ($rawLine in $raw) {
        if ($rawLine -match '^\s*USERNAME') { continue }   # header row
        $line = $rawLine.Trim()
        if (-not $line) { continue }

        # SESSIONNAME is blank for disconnected sessions, which shifts the
        # column count - try the "with session name" shape first, then fall
        # back to the "no session name" shape. Same twin-pattern strategy
        # already used for ID extraction in ADDirectory.UserSessions.Dialog's
        # $script:SesQuserBlock.
        $sessionId = $null
        $tail      = $null
        if ($line -match '^>?\S+\s+\S+\s+(\d+)\s+(.+)$') {
            $sessionId = $Matches[1]
            $tail      = $Matches[2]
        } elseif ($line -match '^>?\S+\s+(\d+)\s+(.+)$') {
            $sessionId = $Matches[1]
            $tail      = $Matches[2]
        }
        if (-not $sessionId) { continue }

        $userName = (($line -replace '^>', '').Trim() -split '\s+')[0]

        $state     = '-'
        $idleTime  = '-'
        $logonTime = '-'
        if ($tail -match '^(\S+)\s+(\S+)\s+(.+)$') {
            $state     = $Matches[1]
            $idleTime  = $Matches[2]
            $logonTime = $Matches[3]
        } elseif ($tail -match '^(\S+)\s+(.+)$') {
            $state     = $Matches[1]
            $logonTime = $Matches[2]
        }

        [void]$sessions.Add([PSCustomObject]@{
            User      = $userName
            SessionId = $sessionId
            State     = $state
            IdleTime  = $idleTime
            LogonTime = $logonTime
        })
    }
    return $sessions
}
#endregion

#region -- Show-ComputerSessionsDialog -----------------------------------------
function Show-ComputerSessionsDialog {
    <#
    .SYNOPSIS
        Opens a fixed-size popup listing every active quser session on a
        single computer. Right-click one or more rows to force-logoff those
        sessions.
    .PARAMETER ComputerName
        The target computer to query.
    #>
    param([string]$ComputerName)

    if (-not $ComputerName) { return }

    $F_UI   = New-Object System.Drawing.Font('Segoe UI', 9)
    $F_UI_B = New-Object System.Drawing.Font('Segoe UI', 9,  [System.Drawing.FontStyle]::Bold)
    $F_UI_T = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
    $F_MONO = New-Object System.Drawing.Font('Consolas', 9)

    # ---- Form -----------------------------------------------------------
    $dlg                  = New-Object System.Windows.Forms.Form
    $dlg.Text             = "Sessions - $ComputerName"
    $dlg.ClientSize       = New-Object System.Drawing.Size(760, 460)
    $dlg.FormBorderStyle  = 'FixedSingle'
    $dlg.MaximizeBox      = $false
    $dlg.MinimizeBox      = $false
    $dlg.StartPosition    = 'CenterParent'
    $dlg.BackColor        = [System.Drawing.Color]::FromArgb(235, 238, 242)
    $dlg.Font             = $F_UI

    # Title bar
    $pTitle               = New-Object System.Windows.Forms.Panel
    $pTitle.Location      = New-Object System.Drawing.Point(0, 0)
    $pTitle.Size          = New-Object System.Drawing.Size(760, 48)
    $pTitle.BackColor     = [System.Drawing.Color]::FromArgb(0, 99, 177)
    $dlg.Controls.Add($pTitle)

    $lTitle               = New-Object System.Windows.Forms.Label
    $lTitle.Text          = "   Active Sessions  -  $ComputerName"
    $lTitle.Location      = New-Object System.Drawing.Point(0, 0)
    $lTitle.Size          = New-Object System.Drawing.Size(760, 48)
    $lTitle.Font          = $F_UI_T
    $lTitle.ForeColor     = [System.Drawing.Color]::White
    $lTitle.TextAlign     = 'MiddleLeft'
    $pTitle.Controls.Add($lTitle)

    # Status label
    $lStatus              = New-Object System.Windows.Forms.Label
    $lStatus.Text         = 'Loading sessions...'
    $lStatus.Location     = New-Object System.Drawing.Point(12, 58)
    $lStatus.Size         = New-Object System.Drawing.Size(736, 20)
    $lStatus.Font         = $F_UI
    $lStatus.ForeColor    = [System.Drawing.Color]::DimGray
    $dlg.Controls.Add($lStatus)

    # ListView
    $lv                      = New-Object System.Windows.Forms.ListView
    $lv.Location             = New-Object System.Drawing.Point(12, 84)
    $lv.Size                 = New-Object System.Drawing.Size(736, 322)
    $lv.View                 = 'Details'
    $lv.FullRowSelect        = $true
    $lv.MultiSelect          = $true
    $lv.GridLines            = $true
    $lv.Font                 = $F_MONO
    $lv.BorderStyle          = 'FixedSingle'
    $lv.Columns.Add('User',        160) | Out-Null
    $lv.Columns.Add('Session ID',   90) | Out-Null
    $lv.Columns.Add('State',       100) | Out-Null
    $lv.Columns.Add('Idle Time',   110) | Out-Null
    $lv.Columns.Add('Logon Time',  270) | Out-Null
    $dlg.Controls.Add($lv)

    # ---- ListView right-click context menu: Force Logoff ----------------
    $cmSession              = New-Object System.Windows.Forms.ContextMenuStrip
    $miForceLogoff          = New-Object System.Windows.Forms.ToolStripMenuItem
    $miForceLogoff.Text     = 'Force Logoff Selected Session(s)'
    $miForceLogoff.Font     = $F_UI_B
    [void]$cmSession.Items.Add($miForceLogoff)
    $lv.ContextMenuStrip    = $cmSession

    # Bottom button panel
    $pBtn                 = New-Object System.Windows.Forms.Panel
    $pBtn.Location        = New-Object System.Drawing.Point(12, 414)
    $pBtn.Size            = New-Object System.Drawing.Size(736, 40)
    $pBtn.BackColor       = [System.Drawing.Color]::FromArgb(235, 238, 242)
    $dlg.Controls.Add($pBtn)

    $btnRefresh           = New-Object System.Windows.Forms.Button
    $btnRefresh.Text      = 'Refresh'
    $btnRefresh.Location  = New-Object System.Drawing.Point(0, 6)
    $btnRefresh.Size      = New-Object System.Drawing.Size(90, 30)
    $btnRefresh.Font      = $F_UI
    $btnRefresh.FlatStyle = 'Standard'
    $pBtn.Controls.Add($btnRefresh)

    $btnCopy              = New-Object System.Windows.Forms.Button
    $btnCopy.Text         = 'Copy to Clipboard'
    $btnCopy.Location     = New-Object System.Drawing.Point(98, 6)
    $btnCopy.Size         = New-Object System.Drawing.Size(140, 30)
    $btnCopy.Font         = $F_UI
    $btnCopy.FlatStyle    = 'Standard'
    $btnCopy.Enabled      = $false
    $pBtn.Controls.Add($btnCopy)

    $btnClose             = New-Object System.Windows.Forms.Button
    $btnClose.Text        = 'Close'
    $btnClose.Location    = New-Object System.Drawing.Point(636, 6)
    $btnClose.Size        = New-Object System.Drawing.Size(100, 30)
    $btnClose.Font        = $F_UI
    $btnClose.FlatStyle   = 'Standard'
    $pBtn.Controls.Add($btnClose)

    # ---- Load / refresh --------------------------------------------------
    $loadSessions = {
        $lv.Items.Clear()
        $lStatus.Text = "Querying $ComputerName..."
        [System.Windows.Forms.Application]::DoEvents()

        $C_OK_BACK = [System.Drawing.Color]::FromArgb(198, 239, 206)
        $C_OK_FORE = [System.Drawing.Color]::FromArgb(0, 97, 0)

        $sessions = $null
        try {
            $sessions = Get-ComputerSessionList -ComputerName $ComputerName
        } catch {
            $lStatus.Text = "Failed to query $ComputerName - $($_.Exception.Message)"
            $btnCopy.Enabled = $false
            return
        }

        if (-not $sessions -or $sessions.Count -eq 0) {
            $lStatus.Text    = "No active sessions found on $ComputerName."
            $btnCopy.Enabled = $false
            return
        }

        foreach ($s in $sessions) {
            $item           = New-Object System.Windows.Forms.ListViewItem($s.User)
            $item.BackColor = $C_OK_BACK
            $item.ForeColor = $C_OK_FORE
            $item.Tag       = [string]$s.SessionId
            [void]$item.SubItems.Add($s.SessionId)
            [void]$item.SubItems.Add($s.State)
            [void]$item.SubItems.Add((Format-IdleTime $s.IdleTime))
            [void]$item.SubItems.Add($s.LogonTime)
            $lv.Items.Add($item) | Out-Null
        }

        $lStatus.Text    = "$($sessions.Count) session(s) found on $ComputerName."
        $btnCopy.Enabled = $true
    }

    # ---- Button / menu events --------------------------------------------
    $btnClose.Add_Click({ $dlg.Close() })
    $btnRefresh.Add_Click($loadSessions)

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
            $lStatus.Text = "Session list copied to clipboard."
        }
    })

    # Right-click on an unselected row selects it (so right-click acts on
    # the row under the cursor rather than a stale prior selection) - same
    # pattern as ADDirectory.UserSessions.Dialog.
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
            $sid = [string]$sel.Tag
            if (-not $sid) { continue }
            [void]$targets.Add(@{ Item = $sel; SessionId = $sid; User = $sel.Text })
        }

        if ($targets.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show(
                'The selected row(s) do not have a valid session ID to log off.',
                'Force Logoff', 'OK', 'Warning') | Out-Null
            return
        }

        $confirmLines = foreach ($t in $targets) { "  $($t.User)  (session $($t.SessionId))" }
        $confirmMsg   = "Force logoff the following session(s) on ${ComputerName}?`r`n`r`n$($confirmLines -join "`r`n")`r`n`r`nThis disconnects the user immediately and cannot be undone."
        $code         = (@($targets | ForEach-Object { "logoff.exe $($_.SessionId) /server:$ComputerName" }) -join "`r`n")
        $confirmed    = Confirm-Action -Title 'Confirm Force Logoff' -Message $confirmMsg -ActionLabel 'Force Logoff' -Code $code
        if (-not $confirmed) { return }

        $okCount   = 0
        $failCount = 0

        foreach ($t in $targets) {
            $lStatus.Text = "Logging off $($t.User) (session $($t.SessionId))..."
            [System.Windows.Forms.Application]::DoEvents()

            $succeeded = $false
            try {
                $psi                         = New-Object System.Diagnostics.ProcessStartInfo
                $psi.FileName                = 'logoff.exe'
                $psi.Arguments               = "$($t.SessionId) /server:$ComputerName"
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

        if ($lv.Items.Count -eq 0) { $btnCopy.Enabled = $false }
    })

    $dlg.Add_Shown($loadSessions)

    [void]$dlg.ShowDialog()
}
#endregion

Export-ModuleMember -Function Show-ComputerSessionsDialog
