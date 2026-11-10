#region -- ADUserActions.Expiry.Dialog.psm1 -----------------------------------
# Concern : Show-SetExpiryDialog - modal form for setting or clearing account
#           expiration. Calls Invoke-SetAccountExpiry / Invoke-ClearAccountExpiry.
# Load order: 46 - depends on ADUserActions.Expiry.Engine (Invoke-SetAccountExpiry,
#                                                           Invoke-ClearAccountExpiry),
#                            Services.AD.Reporting (Confirm-Action),
#                            Services.Mail.Dialog (Show-NotificationMailDialog) [4c]
# Split from: ADUserActions.psm1
# Changes   : Admin tracking mail added after a successful Set Expiry or Clear
#             Expiry. Both open Show-NotificationMailDialog -AdminOnly (To =
#             admin, no CC) with the affected account and the expiry value.
#             Fires only on success. Non-fatal (mail failure never affects the
#             AD operation, which is already committed).
# Note      : Pre-existing $pTitle.Dock='Top' / $lT.Dock='Fill' retained as-is
#             (project WinForms standard prefers explicit positioning; not
#             refactored here to avoid altering an unrelated layout).
# Changes   : BUG FIX: on a fully successful Set Expiry or Clear Expiry, this
#             dialog used to stay open (Close was only ever wired to the
#             explicit Close button) while the admin-tracking mail popup
#             opened on top of it - leaving this window orphaned in the
#             background once the mail popup was dismissed. It now closes
#             itself once either action fully succeeds, same fix as
#             Show-DisableAccountDialog / Show-ResetPasswordDialog. A failed
#             Set/Clear still leaves the dialog open so the error stays
#             visible.
# v1.6.0    : Notification email trimmed to basic information: Action / DC /
#             rows repeated in the message text and the "administrative tracking
#             only" line removed.
#endregion

#region -- Show-SetExpiryDialog -----------------------------------------------
function Show-SetExpiryDialog {
    param([PSCustomObject]$User, [PSCustomObject]$Context)
    if (-not $User -or -not $User.SamAccountName) { return }
    $sam  = $User.SamAccountName
    $disp = if ($User.DisplayName) { $User.DisplayName } else { $sam }

    $F_UI   = New-Object System.Drawing.Font('Segoe UI', 9)
    $F_UI_B = New-Object System.Drawing.Font('Segoe UI', 9,  [System.Drawing.FontStyle]::Bold)
    $F_13B  = New-Object System.Drawing.Font('Segoe UI', 13, [System.Drawing.FontStyle]::Bold)

    $dlg               = New-Object System.Windows.Forms.Form
    $dlg.Text          = "Account Expiry  -  $disp"
    $dlg.ClientSize    = New-Object System.Drawing.Size(400, 240)
    $dlg.FormBorderStyle = 'FixedSingle'
    $dlg.MaximizeBox   = $false
    $dlg.StartPosition = 'CenterParent'
    $dlg.BackColor     = [System.Drawing.Color]::FromArgb(235,238,242)

    $pTitle            = New-Object System.Windows.Forms.Panel
    $pTitle.Dock       = 'Top'; $pTitle.Height = 48
    $pTitle.BackColor  = [System.Drawing.Color]::FromArgb(0,99,177)
    $dlg.Controls.Add($pTitle)
    $lT                = New-Object System.Windows.Forms.Label
    $lT.Text           = '   Account Expiration'
    $lT.Dock           = 'Fill'; $lT.Font = $F_13B
    $lT.ForeColor      = [System.Drawing.Color]::White; $lT.TextAlign = 'MiddleLeft'
    $pTitle.Controls.Add($lT)

    $lUser             = New-Object System.Windows.Forms.Label
    $lUser.Text        = "Account:  $disp  ($sam)"
    $lUser.Location    = New-Object System.Drawing.Point(16, 60)
    $lUser.Size        = New-Object System.Drawing.Size(368, 20)
    $lUser.Font        = $F_UI_B; $lUser.ForeColor = [System.Drawing.Color]::FromArgb(0,60,130)
    $dlg.Controls.Add($lUser)

    $lDate             = New-Object System.Windows.Forms.Label
    $lDate.Text        = 'Expiry Date:'; $lDate.Font = $F_UI
    $lDate.Location    = New-Object System.Drawing.Point(16, 92)
    $lDate.Size        = New-Object System.Drawing.Size(100, 20)
    $dlg.Controls.Add($lDate)

    $dtp               = New-Object System.Windows.Forms.DateTimePicker
    $dtp.Location      = New-Object System.Drawing.Point(16, 114)
    $dtp.Size          = New-Object System.Drawing.Size(200, 24)
    $dtp.Format        = 'Short'; $dtp.Font = $F_UI
    $dtp.Value         = [datetime]::Now.AddDays(30)
    $dlg.Controls.Add($dtp)

    $lStatus           = New-Object System.Windows.Forms.Label
    $lStatus.Location  = New-Object System.Drawing.Point(16, 148)
    $lStatus.Size      = New-Object System.Drawing.Size(368, 20); $lStatus.Font = $F_UI
    $lStatus.ForeColor = [System.Drawing.Color]::DimGray
    $dlg.Controls.Add($lStatus)

    $btnSet            = New-Object System.Windows.Forms.Button
    $btnSet.Text       = 'Set Expiry'; $btnSet.FlatStyle = 'Standard'
    $btnSet.Location   = New-Object System.Drawing.Point(16, 178)
    $btnSet.Size       = New-Object System.Drawing.Size(100, 30); $btnSet.Font = $F_UI_B
    $dlg.Controls.Add($btnSet)

    $btnClear          = New-Object System.Windows.Forms.Button
    $btnClear.Text     = 'Clear Expiry'; $btnClear.FlatStyle = 'Standard'
    $btnClear.Location = New-Object System.Drawing.Point(124, 178)
    $btnClear.Size     = New-Object System.Drawing.Size(100, 30); $btnClear.Font = $F_UI
    $dlg.Controls.Add($btnClear)

    $btnClose          = New-Object System.Windows.Forms.Button
    $btnClose.Text     = 'Close'; $btnClose.FlatStyle = 'Standard'
    $btnClose.Location = New-Object System.Drawing.Point(300, 178)
    $btnClose.Size     = New-Object System.Drawing.Size(80, 30); $btnClose.Font = $F_UI
    $dlg.Controls.Add($btnClose)

    # Captured for the tracking-mail popup (To = admin, no CC). Show-
    # NotificationMailDialog lives in Services.Mail.Dialog (dot-sourced);
    # capture via ${function:} and invoke with & for consistency.
    $showMailDlgFnX = ${function:Show-NotificationMailDialog}

    # Builds and shows the admin-only tracking popup for an expiry change.
    # $expiryText is a display string ('2026-08-01' or 'Cleared').
    $sendExpiryMail = {
        param([string]$actionName, [string]$expiryText, [string]$actionTitle)
        if (-not $showMailDlgFnX) { return }
        $dispLbl = "$disp ($sam)"
        $details = [ordered]@{
            'Admin'     = if ($Context -and $Context.AdminAccount) { $Context.AdminAccount } else { "$env:USERDOMAIN\$env:USERNAME" }
            'Domain'    = if ($Context -and $Context.Domain)       { $Context.Domain }       else { $env:USERDNSDOMAIN }
            'Timestamp' = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        }
        $bodyText = "$actionName was performed on the account below." + "`r`n`r`n" +
                    "Account: $dispLbl" + "`r`n" +
                    "Expiry:  $expiryText"
        & $showMailDlgFnX `
            -Context     $Context `
            -Sam         '' `
            -ActionTitle $actionTitle `
            -Subject     "AD Account Expiry: $dispLbl" `
            -Details     $details `
            -BodyText    $bodyText `
            -AdminOnly
    }.GetNewClosure()

    $btnSet.Add_Click({
        $expiry = $dtp.Value
        $code = New-ADCommandText -Cmdlet 'Set-ADAccountExpiration' -Identity @($sam) -Context $Context -Tail ('-DateTime ' + (ConvertTo-ADCodeLiteral $expiry) + ' -ErrorAction Stop')
        if (-not (Confirm-Action -Title 'Set Expiry' `
            -Message "Set expiration for $sam to $($expiry.ToString('yyyy-MM-dd'))?" `
            -ActionLabel 'Set' -Code $code)) { return }
        $result = Invoke-SetAccountExpiry -Sam $sam -ExpiryDate $expiry -Context $Context
        $lStatus.ForeColor = if ($result.Success) { [System.Drawing.Color]::FromArgb(0,97,0) } else { [System.Drawing.Color]::FromArgb(156,0,6) }
        $lStatus.Text = $result.Message
        if ($result.Success) {
            & $sendExpiryMail 'Set Account Expiry' $expiry.ToString('yyyy-MM-dd') 'Account Expiry Set'
            $dlg.Close()
        }
    })
    $btnClear.Add_Click({
        $code = New-ADCommandText -Cmdlet 'Clear-ADAccountExpiration' -Identity @($sam) -Context $Context -Tail '-ErrorAction Stop'
        if (-not (Confirm-Action -Title 'Clear Expiry' -Message "Remove expiration for $sam?" -ActionLabel 'Clear' -Code $code)) { return }
        $result = Invoke-ClearAccountExpiry -Sam $sam -Context $Context
        $lStatus.ForeColor = if ($result.Success) { [System.Drawing.Color]::FromArgb(0,97,0) } else { [System.Drawing.Color]::FromArgb(156,0,6) }
        $lStatus.Text = $result.Message
        if ($result.Success) {
            & $sendExpiryMail 'Clear Account Expiry' 'Cleared (no expiration)' 'Account Expiry Cleared'
            $dlg.Close()
        }
    })
    $btnClose.Add_Click({ $dlg.Close() })
    $dlg.ShowDialog() | Out-Null
}
#endregion

Export-ModuleMember -Function Show-SetExpiryDialog
