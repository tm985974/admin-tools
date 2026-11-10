#region -- ADComputers.Restart.Dialog.psm1 --------------------------------------
# Concern : Show-TimedRestartDialog - fixed-size popup invoked from the
#           Computers grid right-click menu ("Timed Restart..."). Lets the
#           admin pick/type a restart reason and a delay, previews the exact
#           message the remote user will see, restarts every selected
#           computer via Invoke-TimedRestart (ADComputers.Restart.Engine),
#           and opens an admin-tracking mail listing the computers and delay.
# Load order: 85c - depends on ADComputers.Restart.Engine (Invoke-
#                            TimedRestart), Services.AD.Reporting
#                            (Confirm-Action), Services.Mail.Dialog (Show-
#                            NotificationMailDialog) [4c]. Same "captured at
#                            run time, not load time" rule as ADComputers.
#                            Sessions.Dialog (85a) - this module can load
#                            anywhere in the ADComputers block, it does not
#                            need to precede ADDirectory.Menus (15).
# Split from: (new module)
# Notes     : Message and Time fields are both standard editable
#             (DropDownStyle='DropDown') ComboBoxes with a preset list -
#             picking a preset item sets the box's .Text and therefore
#             overwrites anything previously typed, exactly like Show-
#             DisableAccountDialog's $cmbReason - no extra wiring needed for
#             "dropdown overwrites custom text", it is the control's native
#             behavior. Typing after picking a preset likewise overwrites it.
#             WinForms standard: fixed size, Segoe UI, explicit positioning,
#             no Dock, no Anchor, no TableLayoutPanel, no GroupBox.
#             BUG FIX: the first version of the Schedule Restart handler
#             called Confirm-Action bare from inside its own
#             .GetNewClosure() block - the same closure-scope resolution
#             bug documented throughout this codebase, but Confirm-Action's
#             failure mode is a hard CommandNotFoundException rather than a
#             silent no-op, so it surfaced as a visible "term not
#             recognized" error and aborted the handler before Invoke-
#             TimedRestart (and therefore the msg.exe pop-up / shutdown /c
#             notification) was ever reached - restarts appeared to
#             schedule successfully from the confirmation dialog's own
#             wording but nothing was actually sent. Fixed by capturing
#             ${function:Confirm-Action} outside the closure (as
#             $confirmActionFn), invoked with & inside it.
#             No ternary operators, no ??= operator. PS 5.1 compatible.
#             The dialog now closes itself once a Schedule Restart batch
#             fully succeeds (FailCount -eq 0), after the admin-tracking
#             mail popup (itself modal) has been dismissed - same precedent
#             as Show-DisableAccountDialog. Previously it stayed open after
#             every click regardless of outcome, requiring an extra manual
#             Close. A partial/total failure still leaves the dialog open
#             so the status detail stays visible for review/retry.
# v1.6.0    : Notification email trimmed to basic information: Action / DC /
#             rows repeated in the message text and the "administrative tracking
#             only" line removed.
#endregion

#region -- Show-TimedRestartDialog -----------------------------------------------
function Show-TimedRestartDialog {
    <#
    .SYNOPSIS
        Shows a fixed-size dialog to schedule a delayed, messaged restart on
        one or more computers.
    .PARAMETER ComputerNames
        One or more target computer names, as shown in the Computers grid.
    .PARAMETER Context
        Shared context object (TargetDC, AdminAccount, Domain, mail config).
    #>
    param(
        [string[]]$ComputerNames,
        [PSCustomObject]$Context
    )

    $names = @($ComputerNames | Where-Object { $_ } | Select-Object -Unique)
    if ($names.Count -eq 0) { return }

    $F_UI   = New-Object System.Drawing.Font('Segoe UI', 9)
    $F_UI_B = New-Object System.Drawing.Font('Segoe UI', 9,  [System.Drawing.FontStyle]::Bold)
    $F_13B  = New-Object System.Drawing.Font('Segoe UI', 13, [System.Drawing.FontStyle]::Bold)
    $F_DIM  = New-Object System.Drawing.Font('Segoe UI', 8)

    # Reason presets. Editable box - typing a custom reason works too.
    $reasonPresets = @(
        'Scheduled Maintenance',
        'Software Update / Patch Installation',
        'Performance Issue',
        'System Instability',
        'IT Support Request',
        'Other'
    )
    # Time presets, in minutes. Editable box - a custom whole-number minute
    # value works too.
    $timePresets = @('5', '10', '15', '30', '60', '120')

    $dlg                 = New-Object System.Windows.Forms.Form
    $dlg.Text            = 'Timed Restart'
    $dlg.ClientSize      = New-Object System.Drawing.Size(520, 470)
    $dlg.FormBorderStyle = 'FixedSingle'
    $dlg.MaximizeBox     = $false
    $dlg.MinimizeBox     = $false
    $dlg.StartPosition   = 'CenterParent'
    $dlg.BackColor       = [System.Drawing.Color]::FromArgb(235, 238, 242)

    $pTitle              = New-Object System.Windows.Forms.Panel
    $pTitle.Location     = New-Object System.Drawing.Point(0, 0)
    $pTitle.Size         = New-Object System.Drawing.Size(520, 48)
    $pTitle.BackColor    = [System.Drawing.Color]::FromArgb(0, 99, 177)
    $dlg.Controls.Add($pTitle)
    $lT                  = New-Object System.Windows.Forms.Label
    $lT.Text             = '   Timed Restart'
    $lT.Location         = New-Object System.Drawing.Point(0, 0)
    $lT.Size             = New-Object System.Drawing.Size(520, 48)
    $lT.Font             = $F_13B
    $lT.ForeColor        = [System.Drawing.Color]::White
    $lT.TextAlign        = 'MiddleLeft'
    $pTitle.Controls.Add($lT)

    # -- Target computer list -------------------------------------------------
    $namesPreview = ($names | Select-Object -First 8) -join ', '
    if ($names.Count -gt 8) { $namesPreview += ", ... ($($names.Count) total)" }
    $lTargets           = New-Object System.Windows.Forms.Label
    $lTargets.Text      = "Computer(s): $namesPreview"
    $lTargets.Location  = New-Object System.Drawing.Point(16, 58)
    $lTargets.Size      = New-Object System.Drawing.Size(488, 36)
    $lTargets.Font      = $F_UI_B
    $lTargets.ForeColor = [System.Drawing.Color]::FromArgb(0, 60, 130)
    $dlg.Controls.Add($lTargets)

    # -- Reason / message field -----------------------------------------------
    $lReason          = New-Object System.Windows.Forms.Label
    $lReason.Text     = 'Reason (predefined or custom):'
    $lReason.Location = New-Object System.Drawing.Point(16, 102)
    $lReason.Size     = New-Object System.Drawing.Size(300, 20)
    $lReason.Font     = $F_UI
    $dlg.Controls.Add($lReason)

    $cmbReason               = New-Object System.Windows.Forms.ComboBox
    $cmbReason.Location      = New-Object System.Drawing.Point(16, 122)
    $cmbReason.Size          = New-Object System.Drawing.Size(488, 24)
    $cmbReason.DropDownStyle = 'DropDown'
    $cmbReason.Font          = $F_UI
    $reasonPresets | ForEach-Object { [void]$cmbReason.Items.Add($_) }
    $dlg.Controls.Add($cmbReason)

    # -- Delay field ------------------------------------------------------------
    $lTime          = New-Object System.Windows.Forms.Label
    $lTime.Text     = 'Restart in (minutes - predefined or custom):'
    $lTime.Location = New-Object System.Drawing.Point(16, 158)
    $lTime.Size     = New-Object System.Drawing.Size(340, 20)
    $lTime.Font     = $F_UI
    $dlg.Controls.Add($lTime)

    $cmbTime               = New-Object System.Windows.Forms.ComboBox
    $cmbTime.Location      = New-Object System.Drawing.Point(16, 178)
    $cmbTime.Size          = New-Object System.Drawing.Size(160, 24)
    $cmbTime.DropDownStyle = 'DropDown'
    $cmbTime.Font          = $F_UI
    $timePresets | ForEach-Object { [void]$cmbTime.Items.Add($_) }
    $cmbTime.Text          = '15'
    $dlg.Controls.Add($cmbTime)

    # -- Live preview -----------------------------------------------------------
    $lPreviewCap           = New-Object System.Windows.Forms.Label
    $lPreviewCap.Text      = 'Message the remote user(s) will see:'
    $lPreviewCap.Location  = New-Object System.Drawing.Point(16, 216)
    $lPreviewCap.Size      = New-Object System.Drawing.Size(300, 16)
    $lPreviewCap.Font      = $F_DIM
    $lPreviewCap.ForeColor = [System.Drawing.Color]::DimGray
    $dlg.Controls.Add($lPreviewCap)

    $lPreview           = New-Object System.Windows.Forms.Label
    $lPreview.Location  = New-Object System.Drawing.Point(16, 234)
    $lPreview.Size      = New-Object System.Drawing.Size(488, 56)
    $lPreview.Font      = $F_UI_B
    $lPreview.ForeColor = [System.Drawing.Color]::FromArgb(0, 60, 130)
    $dlg.Controls.Add($lPreview)

    # -- Status / results --------------------------------------------------------
    $lStatus           = New-Object System.Windows.Forms.Label
    $lStatus.Location  = New-Object System.Drawing.Point(16, 300)
    $lStatus.Size      = New-Object System.Drawing.Size(488, 76)
    $lStatus.Font      = $F_UI
    $lStatus.ForeColor = [System.Drawing.Color]::DimGray
    $dlg.Controls.Add($lStatus)

    $btnSchedule      = New-Object System.Windows.Forms.Button
    $btnSchedule.Text = 'Schedule Restart'
    $btnSchedule.FlatStyle = 'Standard'
    $btnSchedule.Location  = New-Object System.Drawing.Point(16, 400)
    $btnSchedule.Size      = New-Object System.Drawing.Size(150, 32)
    $btnSchedule.Font      = $F_UI_B
    $dlg.Controls.Add($btnSchedule)
    $dlg.AcceptButton = $btnSchedule

    $btnCancel      = New-Object System.Windows.Forms.Button
    $btnCancel.Text = 'Close'
    $btnCancel.FlatStyle = 'Standard'
    $btnCancel.Location  = New-Object System.Drawing.Point(424, 400)
    $btnCancel.Size      = New-Object System.Drawing.Size(80, 32)
    $btnCancel.Font      = $F_UI
    $dlg.Controls.Add($btnCancel)
    $dlg.CancelButton = $btnCancel

    # -- Live preview builder -----------------------------------------------
    $getDelayMinutes = {
        $raw = $cmbTime.Text.Trim()
        $val = 0
        if ([int]::TryParse($raw, [ref]$val) -and $val -gt 0) { return $val }
        return $null
    }

    $buildMessage = {
        $mins = & $getDelayMinutes
        $timeText = if ($mins) { "$mins minute(s)" } else { '(enter a valid number of minutes)' }
        $reason = $cmbReason.Text.Trim()
        $msg = "This computer will restart in $timeText."
        if ($reason) { $msg += " Reason: $reason" }
        return $msg
    }

    $updatePreview = { $lPreview.Text = & $buildMessage }
    $cmbReason.Add_TextChanged($updatePreview)
    $cmbReason.Add_SelectedIndexChanged($updatePreview)
    $cmbTime.Add_TextChanged($updatePreview)
    $cmbTime.Add_SelectedIndexChanged($updatePreview)
    & $updatePreview

    # -- Schedule Restart handler ---------------------------------------------
    # Invoke-TimedRestart / Show-NotificationMailDialog are dot-sourced -
    # bare-name calls from inside .GetNewClosure() blocks cannot resolve
    # them reliably (same closure-scope bug class documented throughout
    # this codebase). Captured via ${function:} here, invoked with & below.
    $invTimedRestartFn = ${function:Invoke-TimedRestart}
    $showMailDlgFn      = ${function:Show-NotificationMailDialog}
    $confirmActionFn    = ${function:Confirm-Action}
    $restartCmdTextFn   = ${function:Get-RemoteRestartCommandText}
    $capturedContext    = $Context
    $capturedNames      = $names

    $btnSchedule.Add_Click({
        $mins = & $getDelayMinutes
        if (-not $mins) {
            $lStatus.ForeColor = [System.Drawing.Color]::FromArgb(156, 0, 6)
            $lStatus.Text      = 'Enter a valid whole number of minutes (predefined or custom).'
            return
        }
        $message = & $buildMessage

        $confirmMsg = "Schedule a restart in $mins minute(s) on the following $($capturedNames.Count) computer(s)?`r`n`r`n" +
                      (($capturedNames | Select-Object -First 15) -join ', ') +
                      $(if ($capturedNames.Count -gt 15) { ", ... ($($capturedNames.Count) total)" } else { '' }) +
                      "`r`n`r`nMessage shown to remote user(s):`r`n$message"
        $code = ''
        if ($restartCmdTextFn) { $code = & $restartCmdTextFn -Mode Timed -Names $capturedNames -DelaySeconds ($mins * 60) -Message $message }
        if (-not (& $confirmActionFn -Title 'Timed Restart' -Message $confirmMsg -ActionLabel 'Schedule' -Code $code)) { return }

        if (-not $invTimedRestartFn) {
            $lStatus.ForeColor = [System.Drawing.Color]::FromArgb(156, 0, 6)
            $lStatus.Text      = 'Restart engine module not loaded.'
            return
        }

        $btnSchedule.Enabled = $false
        $lStatus.ForeColor   = [System.Drawing.Color]::DimGray
        $lStatus.Text        = 'Scheduling...'
        $dlg.Refresh()

        $result = & $invTimedRestartFn -Names $capturedNames -DelaySeconds ($mins * 60) -Message $message -Context $capturedContext
        $btnSchedule.Enabled = $true

        if (-not $result) {
            $lStatus.Text = 'No computers to schedule.'
            return
        }

        if ($result.FailCount -eq 0) {
            $lStatus.ForeColor = [System.Drawing.Color]::FromArgb(0, 97, 0)
            $lStatus.Text      = "$($result.OkCount) computer(s) scheduled for restart in $mins minute(s)."
        } else {
            $failNames = ($result.Results | Where-Object { -not $_.Success } | ForEach-Object { "$($_.Name): $($_.Message)" }) -join '; '
            $lStatus.ForeColor = [System.Drawing.Color]::FromArgb(156, 0, 6)
            $lStatus.Text      = "$($result.OkCount) scheduled, $($result.FailCount) failed - $failNames"
        }

        # -- Admin tracking mail (To admin, no CC) - one summary per run --------
        if ($result.OkCount -gt 0 -and $showMailDlgFn) {
            $scheduledOk = @($result.Results | Where-Object { $_.Success } | ForEach-Object { $_.Name })
            $details = [ordered]@{
                'Admin'       = if ($capturedContext -and $capturedContext.AdminAccount) { $capturedContext.AdminAccount } else { "$env:USERDOMAIN\$env:USERNAME" }
                'Domain'      = if ($capturedContext -and $capturedContext.Domain)       { $capturedContext.Domain }       else { $env:USERDNSDOMAIN }
                'Timestamp'   = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
            }
            $bodyText = "A timed restart was scheduled on the following computer(s):" + "`r`n`r`n" +
                        (($scheduledOk | ForEach-Object { "- " + $_ }) -join "`r`n") + "`r`n`r`n" +
                        "Delay: $mins minute(s)" + "`r`n" +
                        "Message shown to remote user(s): $message"

            & $showMailDlgFn `
                -Context     $capturedContext `
                -Sam         '' `
                -ActionTitle 'Timed Restart Scheduled' `
                -Subject     "AD Timed Restart: $($result.OkCount) computer(s) in $mins minute(s)" `
                -Details     $details `
                -BodyText    $bodyText `
                -AdminOnly
        }

        # Close this dialog once the batch fully succeeded - Show-
        # NotificationMailDialog above is itself modal (ShowDialog blocks),
        # so by this point the mail popup has already been dismissed one
        # way or another and there is nothing left in THIS window for the
        # admin to act on. Same precedent as Show-DisableAccountDialog. A
        # partial/total failure leaves the dialog open instead, so the
        # failure detail in $lStatus stays visible for review rather than
        # being closed out from under the admin.
        if ($result.FailCount -eq 0) { $dlg.Close() }
    }.GetNewClosure())

    $btnCancel.Add_Click({ $dlg.Close() })

    [void]$dlg.ShowDialog()
}
#endregion

Export-ModuleMember -Function Show-TimedRestartDialog
