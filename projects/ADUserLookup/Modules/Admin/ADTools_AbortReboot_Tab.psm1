#region -- ADTools.AbortReboot.Tab.psm1 -----------------------------------------
# Concern : Build-AbortRebootTab - constructs the Abort Remote Reboot Tools
#           sub-tab: a paste-list textbox of computer names, an "Abort
#           Pending Restart" button, and a status label. Aborts a pending
#           shutdown/restart on each pasted computer via Invoke-
#           AbortRemoteRestart (ADComputers.Restart.Engine). Every OK/FAIL
#           line reaches the shared Activity Log automatically (Write-
#           OperationLog, called inside Invoke-AbortRemoteRestart itself) -
#           no separate results grid on this page, same as every column on
#           ADBulkOps.BatchDelete.Tab.
# Load order: 121a - depends on ADComputers.Restart.Engine (Invoke-
#                             AbortRemoteRestart), Services.AD.Reporting
#                             (New-StdButton), Services.Mail.Dialog (Show-
#                             NotificationMailDialog) [4c].
#             Must load before ADTools.Register-ToolsTab (126), which calls
#             Build-AbortRebootTab directly (same as every other Build-*Tab
#             function in that registrar).
# Split from: (new module)
# Notes     : Layout is a single column sized and laid out exactly like one
#             of ADBulkOps.BatchDelete.Tab's three columns (Build-
#             BatchDeleteColumn) - header label, paste textbox filling
#             nearly the whole column height, status label, then a button
#             spanning the column's full width underneath - at 25% of the
#             tab's width. No New-SectionPanel border/title chrome, no
#             results grid, matching that module's "no per-column results
#             log" precedent exactly (see that module's own header).
#             BUG FIX (first build of this module): the paste box originally
#             used Set-Placeholder / Get-PlaceholderValue, and the Abort
#             button's Add_Click read it via a bare `Get-PlaceholderValue`
#             call from inside a `.GetNewClosure()` block, and read
#             `$script:ToolsCtx` bare (cross-file script scope) inside that
#             same closure. Both are the same closure-scope resolution bug
#             documented repeatedly elsewhere in this codebase (Confirm-
#             Action / Write-OperationLog / the $userGridRef comment in
#             ADDirectory_Menus.psm1) - bare calls to dot-sourced functions,
#             and bare reads of another module's script-scope variables,
#             both fail to resolve from inside .GetNewClosure() and (with
#             $ErrorActionPreference = 'SilentlyContinue' set by the
#             launcher) fail SILENTLY rather than throwing - the paste box
#             always read back empty regardless of what was pasted. Fixed
#             by dropping the placeholder entirely (plain textbox, read via
#             $tbNames.Text directly - a captured local control reference,
#             not a function call, so nothing to fail to resolve) and by
#             capturing $script:ToolsCtx into a local variable BEFORE the
#             closure is built, then referencing that local inside it -
#             same fix already applied throughout ADDirectory_Menus.psm1
#             ($capturedDirContext / $capturedCompContext) and
#             ADBulkOps_BatchDelete_Tab.psm1 ($capturedContext).
#             No confirmation prompt before aborting - unlike Restart Now /
#             Timed Restart, aborting a pending restart is non-destructive
#             (it can only cancel an already-scheduled action or no-op on a
#             computer with nothing pending), so it follows the same no-
#             confirm precedent as the read-only/reversible items on the
#             Computers grid menu (RDP, Ping, Open C$ Admin Share) rather
#             than the Confirm-Action precedent used for Restart Now/Timed
#             Restart/Delete.
#             No ternary operators, no ??= operator, no -Parallel foreach.
#             PS 5.1 compatible.
# v1.6.0    : Notification email trimmed to basic information: Action / DC /
#             rows repeated in the message text and the "administrative tracking
#             only" line removed.
#endregion

#region -- Build-AbortRebootTab --------------------------------------------------
function Build-AbortRebootTab {
    <#
    .SYNOPSIS
        Builds the Abort Remote Reboot Tools sub-tab page.
    .PARAMETER Tab
        The TabPage to build into (ADTools.Register-ToolsTab's 'abortreboot'
        page).
    #>
    param([System.Windows.Forms.TabPage]$Tab)
    $PAD    = 8
    $F_UI_B = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $F_MONO = New-Object System.Drawing.Font('Consolas', 9)
    $TW     = $script:_TW; $TH = $script:_TH

    $lHint           = New-Object System.Windows.Forms.Label
    $lHint.Text      = 'Paste one computer name per line, then click Abort Pending Restart. Cancels a pending shutdown.exe /r on each computer listed (no effect on a computer with nothing pending). Results are written to the Activity Log below.'
    $lHint.Location  = New-Object System.Drawing.Point($PAD, $PAD)
    $lHint.Size      = New-Object System.Drawing.Size(($TW-$PAD*2), 18)
    $lHint.Font      = New-Object System.Drawing.Font('Segoe UI', 8)
    $lHint.ForeColor = [System.Drawing.Color]::DimGray
    $Tab.Controls.Add($lHint)

    # Single column, sized and positioned exactly like one of
    # ADBulkOps.BatchDelete.Tab's three columns (Build-BatchDeleteColumn) -
    # 25% of the tab's usable width, full remaining height.
    $COL_Y = $PAD + 26
    $COL_H = $TH - $COL_Y - $PAD
    $COL_W = [int](($TW - ($PAD * 2)) * 0.25)
    $COL_X = $PAD

    $lHeader           = New-Object System.Windows.Forms.Label
    $lHeader.Text      = 'Computer Names'
    $lHeader.Location  = New-Object System.Drawing.Point($COL_X, $COL_Y)
    $lHeader.Size      = New-Object System.Drawing.Size($COL_W, 20)
    $lHeader.Font      = $F_UI_B
    $lHeader.ForeColor = [System.Drawing.Color]::FromArgb(0,80,160)
    $Tab.Controls.Add($lHeader)

    $BOTTOM_H  = 18 + 4 + 30   # status label + gap + button
    $tbNamesH  = $COL_H - 22 - 8 - $BOTTOM_H

    $tbNames               = New-Object System.Windows.Forms.TextBox
    $tbNames.Location      = New-Object System.Drawing.Point($COL_X, ($COL_Y + 22))
    $tbNames.Size          = New-Object System.Drawing.Size($COL_W, $tbNamesH)
    $tbNames.Font          = $F_MONO
    $tbNames.Multiline     = $true
    $tbNames.ScrollBars    = 'Vertical'
    $tbNames.AcceptsReturn = $true
    $Tab.Controls.Add($tbNames)

    $STATUS_Y          = $COL_Y + 22 + $tbNamesH + 8
    $lStatus           = New-Object System.Windows.Forms.Label
    $lStatus.Location  = New-Object System.Drawing.Point($COL_X, $STATUS_Y)
    $lStatus.Size      = New-Object System.Drawing.Size($COL_W, 18)
    $lStatus.Font      = New-Object System.Drawing.Font('Segoe UI', 8)
    $lStatus.ForeColor = [System.Drawing.Color]::DimGray
    $Tab.Controls.Add($lStatus)

    $btnAbort      = New-StdButton -Text 'Abort Pending Restart' -X $COL_X -Y ($STATUS_Y + 18 + 4) -W $COL_W -H 30 -Parent $Tab
    $btnAbort.Font = $F_UI_B

    # Invoke-AbortRemoteRestart / Show-NotificationMailDialog are dot-sourced
    # - bare-name calls from inside .GetNewClosure() blocks cannot resolve
    # them reliably (same closure-scope bug class documented throughout this
    # codebase and in this module's header above). Captured via ${function:}
    # here, invoked with & inside the closure below. $script:ToolsCtx is
    # likewise captured into a plain local HERE (this function's own body,
    # not inside a closure) - the exact fix for the same bug class applied
    # to cross-file script-scope variable reads.
    $invAbortFn      = ${function:Invoke-AbortRemoteRestart}
    $showMailDlgFn   = ${function:Show-NotificationMailDialog}
    $capturedContext = $script:ToolsCtx

    $btnAbort.Add_Click({
        $names = @(
            $tbNames.Text -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique
        )
        if ($names.Count -eq 0) {
            $lStatus.ForeColor = [System.Drawing.Color]::FromArgb(156,0,6)
            $lStatus.Text      = 'Paste at least one computer name.'
            return
        }

        if (-not $invAbortFn) {
            $lStatus.ForeColor = [System.Drawing.Color]::FromArgb(156,0,6)
            $lStatus.Text      = 'Restart engine module not loaded.'
            return
        }

        $btnAbort.Enabled = $false
        $lStatus.ForeColor = [System.Drawing.Color]::DimGray
        $lStatus.Text      = 'Aborting...'
        [System.Windows.Forms.Application]::DoEvents()

        $result = & $invAbortFn -Names $names -Context $capturedContext
        $btnAbort.Enabled = $true

        if (-not $result) {
            $lStatus.Text = 'Nothing to abort.'
            return
        }

        $lStatus.ForeColor = if ($result.FailCount -gt 0) { [System.Drawing.Color]::FromArgb(156,0,6) } else { [System.Drawing.Color]::FromArgb(0,97,0) }
        $lStatus.Text      = "Done. Aborted: $($result.OkCount)  Not aborted: $($result.FailCount) - see Activity Log below for detail."

        # -- Admin tracking mail (To admin, no CC) - one summary per batch ------
        if ($result.OkCount -gt 0 -and $showMailDlgFn) {
            $abortedOk = @($result.Results | Where-Object { $_.Success } | ForEach-Object { $_.Name })
            $notAborted = @($result.Results | Where-Object { -not $_.Success } | ForEach-Object { "$($_.Name): $($_.Message)" })
            $details = [ordered]@{
                'Admin'       = if ($capturedContext -and $capturedContext.AdminAccount) { $capturedContext.AdminAccount } else { "$env:USERDOMAIN\$env:USERNAME" }
                'Domain'      = if ($capturedContext -and $capturedContext.Domain)       { $capturedContext.Domain }       else { $env:USERDNSDOMAIN }
                'Timestamp'   = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
            }
            $bodyText = "A pending restart was aborted on the following computer(s):" + "`r`n`r`n" +
                        (($abortedOk | ForEach-Object { "- " + $_ }) -join "`r`n") + "`r`n`r`n"
            if ($notAborted.Count -gt 0) {
                $bodyText += "Not aborted (no pending restart or an error occurred):" + "`r`n`r`n" +
                             (($notAborted | ForEach-Object { "- " + $_ }) -join "`r`n") + "`r`n`r`n"
            }
            $bodyText = $bodyText.TrimEnd()

            & $showMailDlgFn `
                -Context     $capturedContext `
                -Sam         '' `
                -ActionTitle 'Remote Reboot Aborted' `
                -Subject     "AD Abort Remote Reboot: $($result.OkCount) aborted, $($result.FailCount) not aborted" `
                -Details     $details `
                -BodyText    $bodyText `
                -AdminOnly
        }
    }.GetNewClosure())
}
#endregion

Export-ModuleMember -Function Build-AbortRebootTab
