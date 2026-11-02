#region -- ADUserActions.PasswordReset.Dialog.psm1 ---------------------------
# Concern : Show-ResetPasswordDialog - modal form for resetting a user password.
#           Calls Invoke-ResetUserPassword for the AD operation.
# Load order: 44 - depends on ADUserActions.PasswordReset.Engine (Invoke-ResetUserPassword),
#                            ADUserActions.PasswordGenerator (New-GeneratedPassword),
#                            Services.AD.Reporting (Confirm-Action),
#                            Services.Mail.Batch (Get-MailModeSelection,
#                              Send-ADBatchNotificationMail, New-MailModeSelector) [4e],
#                            ADDirectory.Users.Load (Update-CachedUser)
# Split from: ADUserActions.psm1
# Changes   : Copy button now places BOTH the username and the new password on
#             the clipboard (two lines: "User: <sam>" / "Password: <pw>").
#             A successful reset auto-copies the same username+password pair.
#             Title panel/label converted from Dock to explicit positioning to
#             comply with the WinForms fixed-position standard.
#             A successful reset now also patches the cached Users row (via
#             Update-CachedUser - PasswordLastSet, PwNeverExpires) and
#             re-renders the Directory tab's Users grid, if that user is
#             currently loaded there. No AD round trip beyond the reset
#             itself; no-op if the user isn't in the currently-loaded OU
#             scope. Previously a reset left the grid showing stale data
#             until a manual Reload Directory Data.
#             BUG FIX: on a fully successful reset, this dialog used to stay
#             open (Close was only ever wired to the explicit Close button)
#             while the admin-tracking mail popup opened on top of it -
#             leaving this window orphaned in the background once the mail
#             popup was dismissed. It now closes itself once the reset fully
#             succeeds, same fix as Show-DisableAccountDialog. A failed
#             reset still leaves the dialog open so the error stays visible.
#
#             Split admin/user notification mail:
#             This dialog used to fire a single Show-NotificationMailDialog
#             call in normal (-Sam) mode - one email, To the user, Cc'd to
#             the admin, with the new plaintext password sitting in the
#             Details table that BOTH of them saw. That is no longer how
#             this works. The form widened (440 -> 620) to fit a
#             New-MailModeSelector row (Admin Only / Individual / Both /
#             None), defaulted to 'Both' so the admin sees a copy exactly
#             like before unless they actively choose otherwise. On a
#             successful reset, Send-ADBatchNotificationMail (Services.Mail.
#             Batch) is called once with:
#               - AdminDetails/AdminBodyText: the same tracking fields as
#                 before, MINUS the password - the admin's copy never
#                 contains the plaintext password (matches the pattern
#                 already used by Bulk Onboard's admin summary).
#               - Recipients: a single entry (this user) whose OWN Details
#                 table still carries 'New Password' - only that user's own
#                 email contains it.
#             This is a single-recipient use of the same batch orchestrator
#             the Bulk Onboard / Add Users to Groups tabs already use, so no
#             changes were needed in Services.Mail.Batch itself.
#             Blank email on the user's AD account is no longer this
#             dialog's problem to solve - Show-NotificationMailDialog (via
#             Send-ADBatchNotificationMail) now prompts for one and writes
#             it back to AD itself if needed. See Services.Mail.Dialog.
# v1.6.0    : Removed the "Must change at next logon" checkbox (always $false).
#             Emails trimmed: person gets Account / Username / New Password;
#             admin gets Account / Admin / Domain / Timestamp.
#endregion

#region -- Show-ResetPasswordDialog -------------------------------------------
function Show-ResetPasswordDialog {
    param([PSCustomObject]$User, [PSCustomObject]$Context)
    if (-not $User -or -not $User.SamAccountName) { return }
    $sam  = $User.SamAccountName
    $disp = if ($User.DisplayName) { $User.DisplayName } else { $sam }

    $F_UI   = New-Object System.Drawing.Font('Segoe UI', 9)
    $F_UI_B = New-Object System.Drawing.Font('Segoe UI', 9,  [System.Drawing.FontStyle]::Bold)
    $F_13B  = New-Object System.Drawing.Font('Segoe UI', 13, [System.Drawing.FontStyle]::Bold)
    $F_MONO = New-Object System.Drawing.Font('Consolas',  9)

    $dlg               = New-Object System.Windows.Forms.Form
    $dlg.Text          = "Reset Password  -  $disp"
    $dlg.ClientSize    = New-Object System.Drawing.Size(620, 330)
    $dlg.FormBorderStyle = 'FixedSingle'
    $dlg.MaximizeBox   = $false
    $dlg.MinimizeBox   = $false
    $dlg.StartPosition = 'CenterParent'
    $dlg.BackColor     = [System.Drawing.Color]::FromArgb(235,238,242)

    $pTitle            = New-Object System.Windows.Forms.Panel
    $pTitle.Location   = New-Object System.Drawing.Point(0, 0)
    $pTitle.Size       = New-Object System.Drawing.Size(620, 48)
    $pTitle.BackColor  = [System.Drawing.Color]::FromArgb(0,99,177)
    $dlg.Controls.Add($pTitle)

    $lT                = New-Object System.Windows.Forms.Label
    $lT.Text           = 'Reset Password'
    $lT.Location       = New-Object System.Drawing.Point(12, 0)
    $lT.Size           = New-Object System.Drawing.Size(596, 48)
    $lT.Font           = $F_13B
    $lT.ForeColor      = [System.Drawing.Color]::White
    $lT.TextAlign      = 'MiddleLeft'
    $pTitle.Controls.Add($lT)

    $lUser             = New-Object System.Windows.Forms.Label
    $lUser.Text        = "Account:  $disp  ($sam)"
    $lUser.Location    = New-Object System.Drawing.Point(16, 60)
    $lUser.Size        = New-Object System.Drawing.Size(588, 20)
    $lUser.Font        = $F_UI_B
    $lUser.ForeColor   = [System.Drawing.Color]::FromArgb(0,60,130)
    $dlg.Controls.Add($lUser)

    $lPw               = New-Object System.Windows.Forms.Label
    $lPw.Text          = 'New Password:'
    $lPw.Location      = New-Object System.Drawing.Point(16, 92)
    $lPw.Size          = New-Object System.Drawing.Size(100, 20)
    $lPw.Font          = $F_UI
    $dlg.Controls.Add($lPw)

    $tbPw              = New-Object System.Windows.Forms.TextBox
    $tbPw.Location     = New-Object System.Drawing.Point(16, 114)
    $tbPw.Size         = New-Object System.Drawing.Size(280, 24)
    $tbPw.Font         = $F_MONO
    $dlg.Controls.Add($tbPw)

    $btnGen            = New-Object System.Windows.Forms.Button
    $btnGen.Text       = 'Generate'
    $btnGen.FlatStyle  = 'Standard'
    $btnGen.Location   = New-Object System.Drawing.Point(304, 114)
    $btnGen.Size       = New-Object System.Drawing.Size(80, 24)
    $btnGen.Font       = $F_UI
    $dlg.Controls.Add($btnGen)

    $btnCopy           = New-Object System.Windows.Forms.Button
    $btnCopy.Text      = 'Copy'
    $btnCopy.FlatStyle = 'Standard'
    $btnCopy.Location  = New-Object System.Drawing.Point(304, 144)
    $btnCopy.Size      = New-Object System.Drawing.Size(80, 24)
    $btnCopy.Font      = $F_UI
    $dlg.Controls.Add($btnCopy)

    # v1.6.0: no "Must change at next logon" option - a reset password is
    # permanent; the engine clears the flag on every reset.
    $chkNever          = New-Object System.Windows.Forms.CheckBox
    $chkNever.Text     = 'Password never expires'
    $chkNever.Location = New-Object System.Drawing.Point(16, 148)
    $chkNever.Size     = New-Object System.Drawing.Size(220, 20)
    $chkNever.Font     = $F_UI
    $dlg.Controls.Add($chkNever)

    # -- Notification: Admin Only / Individual / Both / None ----------------
    # Defaults to 'Both' - matches the old implicit CC-the-admin behavior so
    # nothing changes for an admin who never touches this row. Guarded: if
    # Services.Mail.Batch isn't loaded, $modeSelector stays $null and
    # Get-MailModeSelection's own $null-safe fallback ('AdminOnly') applies
    # at send time - same non-fatal degrade every other mail feature here
    # uses.
    $modeSelector = $null
    if (Get-Command New-MailModeSelector -ErrorAction SilentlyContinue) {
        $modeSelector = New-MailModeSelector -Parent $dlg -X 16 -Y 200 -DefaultMode 'Both'
    }

    $lStatus           = New-Object System.Windows.Forms.Label
    $lStatus.Location  = New-Object System.Drawing.Point(16, 232)
    $lStatus.Size      = New-Object System.Drawing.Size(588, 20)
    $lStatus.Font      = $F_UI
    $lStatus.ForeColor = [System.Drawing.Color]::DimGray
    $dlg.Controls.Add($lStatus)

    $btnReset           = New-Object System.Windows.Forms.Button
    $btnReset.Text      = 'Reset Password'
    $btnReset.FlatStyle = 'Standard'
    $btnReset.Location  = New-Object System.Drawing.Point(16, 264)
    $btnReset.Size      = New-Object System.Drawing.Size(140, 30)
    $btnReset.Font      = $F_UI_B
    $dlg.Controls.Add($btnReset)

    $btnClose          = New-Object System.Windows.Forms.Button
    $btnClose.Text     = 'Close'
    $btnClose.FlatStyle = 'Standard'
    $btnClose.Location = New-Object System.Drawing.Point(524, 264)
    $btnClose.Size     = New-Object System.Drawing.Size(80, 30)
    $btnClose.Font     = $F_UI
    $dlg.Controls.Add($btnClose)

    # -- Capture for closures -----------------------------------------------
    $capturedSam     = $sam
    $capturedDisp    = $disp
    $capturedContext = $Context
    # Cross-module functions called from inside the .GetNewClosure() block below
    # cannot be resolved by bare name (per-module scope); capture and invoke via &.
    # $modeSelector itself is a plain local variable (not a cross-module
    # function), so .GetNewClosure() captures it normally - no & needed for it.
    $confirmActionFn    = ${function:Confirm-Action}
    $resetPwFn          = ${function:Invoke-ResetUserPassword}
    $updateCachedUserFn = ${function:Update-CachedUser}
    $getMailModeFn      = ${function:Get-MailModeSelection}
    $sendBatchMailFn    = ${function:Send-ADBatchNotificationMail}

    $btnGen.Add_Click({
        if (Get-Command New-GeneratedPassword -ErrorAction SilentlyContinue) {
            $tbPw.Text = New-GeneratedPassword
        } else {
            $chars = 'abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789!@#$'
            $tbPw.Text = -join ((1..14) | ForEach-Object { $chars[(Get-Random -Maximum $chars.Length)] })
        }
    })

    $btnCopy.Add_Click({
        $pw = $tbPw.Text
        if ($pw) {
            [System.Windows.Forms.Clipboard]::SetText("User: $capturedSam`r`nPassword: $pw")
            $lStatus.ForeColor = [System.Drawing.Color]::DimGray
            $lStatus.Text      = 'Username and password copied to clipboard.'
        } else {
            $lStatus.ForeColor = [System.Drawing.Color]::FromArgb(156,0,6)
            $lStatus.Text      = 'Enter or generate a password first.'
        }
    }.GetNewClosure())

    $btnReset.Add_Click({
        $pw = $tbPw.Text.Trim()
        if (-not $pw) {
            $lStatus.ForeColor = [System.Drawing.Color]::FromArgb(156,0,6)
            $lStatus.Text      = 'Enter or generate a password first.'
            return
        }

        $mustChange  = $false
        $neverExpires = $chkNever.Checked

        if (-not (& $confirmActionFn -Title 'Reset Password' `
                -Message "Reset password for $capturedDisp ($capturedSam)?`n`nNew password: $pw" `
                -ActionLabel 'Reset')) { return }

        $result = & $resetPwFn `
            -Sam         $capturedSam `
            -NewPassword $pw `
            -MustChange  $mustChange `
            -NeverExpires $neverExpires `
            -Context     $capturedContext

        if ($result.Success) {
            $lStatus.ForeColor = [System.Drawing.Color]::FromArgb(0,97,0)
            [System.Windows.Forms.Clipboard]::SetText("User: $capturedSam`r`nPassword: $pw")
            $lStatus.Text = "$($result.Message)  Username and password copied to clipboard."

            # -- Patch the cached Users row (PasswordLastSet, PwNeverExpires) --
            # No-op if this user isn't in the currently-loaded OU scope. No AD
            # round trip - the reset itself already happened above.
            if ($updateCachedUserFn) {
                & $updateCachedUserFn -Sam $capturedSam -Properties @{
                    PasswordLastSet = (Get-Date -Format 'yyyy-MM-dd')
                    PwNeverExpires  = if ($neverExpires) { 'True' } else { 'False' }
                }
            }

            # -- Mail notification (non-fatal) - split admin/user emails ----
            # AdminDetails/AdminBodyText below deliberately omit the
            # password - only the Recipients entry (this user's own email)
            # carries it. See module header for the full explanation.
            if ($sendBatchMailFn) {
                $mode = if ($getMailModeFn) { & $getMailModeFn -Selector $modeSelector } else { 'AdminOnly' }

                $acctLabel = "$capturedDisp ($capturedSam)"
                $adminInfo = [ordered]@{
                    'Account'       = $acctLabel
                    'Admin'         = if ($capturedContext -and $capturedContext.AdminAccount) { $capturedContext.AdminAccount } else { "$env:USERDOMAIN\$env:USERNAME" }
                    'Domain'        = if ($capturedContext -and $capturedContext.Domain)       { $capturedContext.Domain }       else { $env:USERDNSDOMAIN }
                    'Timestamp'     = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
                }
                $adminBody = "The password for the Active Directory account listed above has been reset."

                $recipDetails = [ordered]@{
                    'Account'       = $acctLabel
                    'Username'      = $capturedSam
                    'New Password'  = $pw
                }
                $recipBody = "The password for the Active Directory account listed above has been reset." + "`r`n`r`n" +
                             "If you did not request this change, please contact your IT administrator immediately."

                & $sendBatchMailFn `
                    -Mode          $mode `
                    -Context       $capturedContext `
                    -ActionTitle   'Password Reset' `
                    -AdminSubject  "AD Password Reset: $acctLabel" `
                    -AdminDetails  $adminInfo `
                    -AdminBodyText $adminBody `
                    -Recipients    @([PSCustomObject]@{
                        Sam      = $capturedSam
                        Subject  = "AD Password Reset: $acctLabel"
                        Details  = $recipDetails
                        BodyText = $recipBody
                    })
            }

            # Close this dialog once the reset fully succeeded - Send-
            # ADBatchNotificationMail above opens its own modal popup(s)
            # (ShowDialog blocks), so by this point any mail popups have
            # already been dismissed one way or another and there is
            # nothing left in THIS window for the admin to act on (single-
            # target action, not a batch/review list). This is the same fix
            # applied to Show-DisableAccountDialog.
            $dlg.Close()

        } else {
            $lStatus.ForeColor = [System.Drawing.Color]::FromArgb(156,0,6)
            $lStatus.Text      = $result.Message
        }
    }.GetNewClosure())

    $btnClose.Add_Click({ $dlg.Close() })

    $dlg.ShowDialog() | Out-Null
}
#endregion

Export-ModuleMember -Function Show-ResetPasswordDialog
