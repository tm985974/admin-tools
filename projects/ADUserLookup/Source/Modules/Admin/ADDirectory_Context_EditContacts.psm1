#region -- ADDirectory.Context.EditContacts.psm1 ------------------------------
# Concern : Show-EditContactsDialog - modal form to view and edit a single
#           user's contact attributes: Email, Phone, Mobile, Pager. Prefills
#           from AD, saves only changed fields via Set-ADUser (empty field
#           clears the attribute), logs via Write-OperationLog, and fires the
#           admin-only tracking mail popup on a successful save.
# Attribute map:
#           Email  -> EmailAddress (LDAP mail)            Set-ADUser -EmailAddress
#           Phone  -> OfficePhone  (LDAP telephoneNumber) Set-ADUser -OfficePhone
#           Mobile -> MobilePhone  (LDAP mobile)          Set-ADUser -MobilePhone
#           Pager  -> pager        (no named parameter)   Set-ADUser -Replace/-Clear
# Load order: 14b - must load BEFORE ADDirectory.Menus (slot 15) so
#                   ${function:Show-EditContactsDialog} is resolvable when
#                   New-UserContextMenu captures it at menu-build time (same
#                   load-before-Menus requirement as UserSessions / LockoutStatus).
#             depends on Services.AD.Reporting (Confirm-Action),
#                        Services.Logging     (Write-OperationLog),
#                        Services.Mail.Dialog (Show-NotificationMailDialog) [4c],
#                        ADDirectory.Users.Load (Update-CachedUser)
# Split from: (new module)
# Changes   : A successful save now also patches the cached Users row (via
#             Update-CachedUser - Email, Pager, Mobile; the grid has no Phone
#             column so OfficePhone isn't patched) and re-renders the
#             Directory tab's Users grid, if this user is currently loaded
#             there. No AD round trip beyond the save itself; no-op if the
#             user isn't in the currently-loaded OU scope. Previously a save
#             left the grid showing stale contact data until a manual Reload
#             Directory Data.
# v1.6.0    : Notification email trimmed to basic information: Action / DC /
#             rows repeated in the message text and the "administrative tracking
#             only" line removed.
#endregion

#region -- Show-EditContactsDialog --------------------------------------------
function Show-EditContactsDialog {
    <#
    .SYNOPSIS
        Modal editor for a single user's Email / Phone / Mobile / Pager.
        Called from New-UserContextMenu (single-target only).
    #>
    param(
        [string]$Sam,
        [string]$DisplayName,
        [PSCustomObject]$Context
    )

    if (-not $Sam) {
        [System.Windows.Forms.MessageBox]::Show('No user specified.','Edit Contacts','OK','Warning')
        return
    }
    $disp = if ($DisplayName) { $DisplayName } else { $Sam }

    $srvParam = if ($Context -and $Context.TargetDC) { @{ Server = $Context.TargetDC } } else { @{} }

    # -- Load current values ---------------------------------------------------
    $origEmail  = ''
    $origPhone  = ''
    $origMobile = ''
    $origPager  = ''
    try {
        $u = Get-ADUser -Identity $Sam `
             -Properties EmailAddress,OfficePhone,MobilePhone,pager `
             @srvParam -ErrorAction Stop
        if ($u.EmailAddress) { $origEmail  = [string]$u.EmailAddress }
        if ($u.OfficePhone)  { $origPhone  = [string]$u.OfficePhone }
        if ($u.MobilePhone)  { $origMobile = [string]$u.MobilePhone }
        if ($u.pager)        { $origPager  = [string]$u.pager }
    } catch {
        [System.Windows.Forms.MessageBox]::Show(
            "Could not read contact details for '$Sam':`r`n$($_.Exception.Message)",
            'Edit Contacts','OK','Warning')
        return
    }

    # -- Fonts -----------------------------------------------------------------
    $F_UI   = New-Object System.Drawing.Font('Segoe UI', 9)
    $F_UI_B = New-Object System.Drawing.Font('Segoe UI', 9,  [System.Drawing.FontStyle]::Bold)
    $F_13B  = New-Object System.Drawing.Font('Segoe UI', 13, [System.Drawing.FontStyle]::Bold)

    # -- Form ------------------------------------------------------------------
    $dlg                 = New-Object System.Windows.Forms.Form
    $dlg.Text            = "Edit Contacts  -  $disp"
    $dlg.ClientSize      = New-Object System.Drawing.Size(440, 312)
    $dlg.FormBorderStyle = 'FixedSingle'
    $dlg.MaximizeBox     = $false
    $dlg.MinimizeBox     = $false
    $dlg.StartPosition   = 'CenterParent'
    $dlg.BackColor       = [System.Drawing.Color]::FromArgb(235,238,242)

    $pTitle              = New-Object System.Windows.Forms.Panel
    $pTitle.Location     = New-Object System.Drawing.Point(0, 0)
    $pTitle.Size         = New-Object System.Drawing.Size(440, 48)
    $pTitle.BackColor    = [System.Drawing.Color]::FromArgb(0,99,177)
    $dlg.Controls.Add($pTitle)

    $lT                  = New-Object System.Windows.Forms.Label
    $lT.Text             = '   Contact Details'
    $lT.Location         = New-Object System.Drawing.Point(0, 0)
    $lT.Size             = New-Object System.Drawing.Size(440, 48)
    $lT.Font             = $F_13B
    $lT.ForeColor        = [System.Drawing.Color]::White
    $lT.TextAlign        = 'MiddleLeft'
    $pTitle.Controls.Add($lT)

    $lUser               = New-Object System.Windows.Forms.Label
    $lUser.Text          = "Account:  $disp  ($Sam)"
    $lUser.Location      = New-Object System.Drawing.Point(16, 60)
    $lUser.Size          = New-Object System.Drawing.Size(408, 20)
    $lUser.Font          = $F_UI_B
    $lUser.ForeColor     = [System.Drawing.Color]::FromArgb(0,60,130)
    $dlg.Controls.Add($lUser)

    # -- Email -----------------------------------------------------------------
    $lEmail              = New-Object System.Windows.Forms.Label
    $lEmail.Text         = 'Email:'
    $lEmail.Font         = $F_UI
    $lEmail.Location     = New-Object System.Drawing.Point(16, 96)
    $lEmail.Size         = New-Object System.Drawing.Size(70, 20)
    $lEmail.TextAlign    = 'MiddleLeft'
    $dlg.Controls.Add($lEmail)

    $txtEmail            = New-Object System.Windows.Forms.TextBox
    $txtEmail.Font       = $F_UI
    $txtEmail.Location   = New-Object System.Drawing.Point(92, 94)
    $txtEmail.Size       = New-Object System.Drawing.Size(332, 24)
    $txtEmail.Text       = $origEmail
    $dlg.Controls.Add($txtEmail)

    # -- Phone -----------------------------------------------------------------
    $lPhone              = New-Object System.Windows.Forms.Label
    $lPhone.Text         = 'Phone:'
    $lPhone.Font         = $F_UI
    $lPhone.Location     = New-Object System.Drawing.Point(16, 132)
    $lPhone.Size         = New-Object System.Drawing.Size(70, 20)
    $lPhone.TextAlign    = 'MiddleLeft'
    $dlg.Controls.Add($lPhone)

    $txtPhone            = New-Object System.Windows.Forms.TextBox
    $txtPhone.Font       = $F_UI
    $txtPhone.Location   = New-Object System.Drawing.Point(92, 130)
    $txtPhone.Size       = New-Object System.Drawing.Size(332, 24)
    $txtPhone.Text       = $origPhone
    $dlg.Controls.Add($txtPhone)

    # -- Mobile ----------------------------------------------------------------
    $lMobile             = New-Object System.Windows.Forms.Label
    $lMobile.Text        = 'Mobile:'
    $lMobile.Font        = $F_UI
    $lMobile.Location    = New-Object System.Drawing.Point(16, 168)
    $lMobile.Size        = New-Object System.Drawing.Size(70, 20)
    $lMobile.TextAlign   = 'MiddleLeft'
    $dlg.Controls.Add($lMobile)

    $txtMobile           = New-Object System.Windows.Forms.TextBox
    $txtMobile.Font      = $F_UI
    $txtMobile.Location  = New-Object System.Drawing.Point(92, 166)
    $txtMobile.Size      = New-Object System.Drawing.Size(332, 24)
    $txtMobile.Text      = $origMobile
    $dlg.Controls.Add($txtMobile)

    # -- Pager -----------------------------------------------------------------
    $lPager              = New-Object System.Windows.Forms.Label
    $lPager.Text         = 'Pager:'
    $lPager.Font         = $F_UI
    $lPager.Location     = New-Object System.Drawing.Point(16, 204)
    $lPager.Size         = New-Object System.Drawing.Size(70, 20)
    $lPager.TextAlign    = 'MiddleLeft'
    $dlg.Controls.Add($lPager)

    $txtPager            = New-Object System.Windows.Forms.TextBox
    $txtPager.Font       = $F_UI
    $txtPager.Location   = New-Object System.Drawing.Point(92, 202)
    $txtPager.Size       = New-Object System.Drawing.Size(332, 24)
    $txtPager.Text       = $origPager
    $dlg.Controls.Add($txtPager)

    # -- Status ----------------------------------------------------------------
    $lStatus             = New-Object System.Windows.Forms.Label
    $lStatus.Location    = New-Object System.Drawing.Point(16, 240)
    $lStatus.Size        = New-Object System.Drawing.Size(408, 20)
    $lStatus.Font        = $F_UI
    $lStatus.ForeColor   = [System.Drawing.Color]::DimGray
    $dlg.Controls.Add($lStatus)

    # -- Buttons ---------------------------------------------------------------
    $btnSave             = New-Object System.Windows.Forms.Button
    $btnSave.Text        = 'Save'
    $btnSave.FlatStyle   = 'Standard'
    $btnSave.Font        = $F_UI_B
    $btnSave.Location    = New-Object System.Drawing.Point(16, 270)
    $btnSave.Size        = New-Object System.Drawing.Size(100, 30)
    $dlg.Controls.Add($btnSave)

    $btnClose            = New-Object System.Windows.Forms.Button
    $btnClose.Text       = 'Close'
    $btnClose.FlatStyle  = 'Standard'
    $btnClose.Font       = $F_UI
    $btnClose.Location   = New-Object System.Drawing.Point(344, 270)
    $btnClose.Size       = New-Object System.Drawing.Size(80, 30)
    $dlg.Controls.Add($btnClose)

    # Captured for cross-module resolution inside handlers (dot-sourced load).
    $confirmActionFn    = ${function:Confirm-Action}
    $writeOpLogFn       = ${function:Write-OperationLog}
    $showMailDlgFn      = ${function:Show-NotificationMailDialog}
    $updateCachedUserFn = ${function:Update-CachedUser}

    # -- Save handler ----------------------------------------------------------
    $btnSave.Add_Click({
        $newEmail  = $txtEmail.Text.Trim()
        # Phone / Mobile / Pager: store digits only (matches Create New User).
        $newPhone  = ($txtPhone.Text  -replace '\D','')
        $newMobile = ($txtMobile.Text -replace '\D','')
        $newPager  = ($txtPager.Text  -replace '\D','')

        # Change detection (field name -> @{ New; Clear; Attr }).
        $changes = [ordered]@{}
        if ($newEmail  -ne $origEmail)  { $changes['Email']  = @{ New = $newEmail;  Attr = 'mail' } }
        if ($newPhone  -ne $origPhone)  { $changes['Phone']  = @{ New = $newPhone;  Attr = 'telephoneNumber' } }
        if ($newMobile -ne $origMobile) { $changes['Mobile'] = @{ New = $newMobile; Attr = 'mobile' } }
        if ($newPager  -ne $origPager)  { $changes['Pager']  = @{ New = $newPager;  Attr = 'pager' } }

        if ($changes.Count -eq 0) {
            $lStatus.ForeColor = [System.Drawing.Color]::DimGray
            $lStatus.Text      = 'No changes to save.'
            return
        }

        $summary = ($changes.Keys | ForEach-Object {
            $v = $changes[$_].New
            if ($v) { "$_ = $v" } else { "$_ = (cleared)" }
        }) -join '; '

        # Build a single Set-ADUser call: named params for set values, -Replace
        # for pager set, -Clear (LDAP names) for emptied attributes.
        $setSplat  = @{}
        $replace   = @{}
        $clearList = @()
        foreach ($fld in $changes.Keys) {
            $ch   = $changes[$fld]
            $val  = $ch.New
            $attr = $ch.Attr
            if ($val) {
                switch ($fld) {
                    'Email'  { $setSplat['EmailAddress'] = $val }
                    'Phone'  { $setSplat['OfficePhone']  = $val }
                    'Mobile' { $setSplat['MobilePhone']  = $val }
                    'Pager'  { $replace[$attr]           = $val }
                }
            } else {
                $clearList += $attr
            }
        }

        # The command window shows the exact Set-ADUser call (template rule).
        $q = { param($v) "'" + ([string]$v).Replace("'", "''") + "'" }
        $code = 'Set-ADUser -Identity ' + (& $q $Sam)
        foreach ($k in $setSplat.Keys) { $code += " -$k " + (& $q $setSplat[$k]) }
        if ($replace.Count -gt 0) { $code += ' -Replace @{ ' + ((@($replace.Keys) | ForEach-Object { "$_ = " + (& $q $replace[$_]) }) -join '; ') + ' }' }
        if ($clearList.Count -gt 0) { $code += ' -Clear ' + ((@($clearList) | ForEach-Object { & $q $_ }) -join ', ') }
        if ($srvParam.Count -gt 0) { $code += ' -Server ' + (& $q $srvParam['Server']) }

        $confirmed = $false
        if ($confirmActionFn) {
            $confirmed = & $confirmActionFn -Title 'Edit Contacts' `
                -Message "Save contact changes for $Sam?`r`n`r`n$summary" -ActionLabel 'Save' -Code $code
        } else {
            $confirmed = ([System.Windows.Forms.MessageBox]::Show(   # not-a-command: fallback when Confirm-Action is not loaded
                "Save contact changes for $Sam?`r`n`r`n$summary",
                'Edit Contacts','YesNo','Question') -eq [System.Windows.Forms.DialogResult]::Yes)
        }
        if (-not $confirmed) { return }

        try {
            $callParams = @{ Identity = $Sam } + $srvParam + $setSplat
            if ($replace.Count   -gt 0) { $callParams['Replace'] = $replace }
            if ($clearList.Count -gt 0) { $callParams['Clear']   = $clearList }
            Set-ADUser @callParams -ErrorAction Stop

            if ($writeOpLogFn) {
                & $writeOpLogFn -Context $Context -Action 'EDIT_CONTACTS' -Target $Sam -Result 'OK' -Detail $summary
            }

            # Commit succeeded: refresh baselines so a second Save is a no-op.
            $script:__ec_dummy = $null
            $origEmail  = $newEmail
            $origPhone  = $newPhone
            $origMobile = $newMobile
            $origPager  = $newPager

            $lStatus.ForeColor = [System.Drawing.Color]::FromArgb(0,97,0)
            $lStatus.Text      = 'Contact details saved.'

            # -- Patch the cached Users row (Email, Pager, Mobile) ------------
            # No AD round trip - the save itself already happened above. The
            # grid has no Phone column, so OfficePhone is not patched here.
            # No-op if this user isn't in the currently-loaded OU scope.
            if ($updateCachedUserFn) {
                & $updateCachedUserFn -Sam $Sam -Properties @{
                    Email  = $newEmail
                    Pager  = $newPager
                    Mobile = $newMobile
                }
            }

            # -- Admin tracking mail (To admin, no CC). Non-fatal. ------------
            if ($showMailDlgFn) {
                $dispLbl = "$disp ($Sam)"
                $details = [ordered]@{
                    'Admin'     = if ($Context -and $Context.AdminAccount) { $Context.AdminAccount } else { "$env:USERDOMAIN\$env:USERNAME" }
                    'Domain'    = if ($Context -and $Context.Domain)       { $Context.Domain }       else { $env:USERDNSDOMAIN }
                    'Timestamp' = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
                }
                $changeText = ($changes.Keys | ForEach-Object {
                    $v = $changes[$_].New
                    if ($v) { "$_ = $v" } else { "$_ = (cleared)" }
                }) -join "`r`n"
                $bodyText = "The contact details below were updated on the account:" + "`r`n`r`n" +
                            "Account: $dispLbl" + "`r`n`r`n" +
                            "Changes:" + "`r`n" + $changeText
                & $showMailDlgFn `
                    -Context     $Context `
                    -Sam         '' `
                    -ActionTitle 'Contact Details Updated' `
                    -Subject     "AD Contact Update: $dispLbl" `
                    -Details     $details `
                    -BodyText    $bodyText `
                    -AdminOnly
            }

            # Close this dialog once the save fully succeeded - Show-
            # NotificationMailDialog above is itself modal (ShowDialog
            # blocks), so by this point the mail popup has already been
            # dismissed one way or another and there is nothing left in
            # THIS window for the admin to act on (single-target action,
            # not a batch/review list). Previously this dialog only ever
            # closed via the explicit Close button, so a successful save
            # left it orphaned open behind the mail popup once that was
            # dismissed - same bug class already fixed in Show-
            # ResetPasswordDialog / Show-DisableAccountDialog.
            $dlg.Close()
        } catch {
            if ($writeOpLogFn) {
                & $writeOpLogFn -Context $Context -Action 'EDIT_CONTACTS' -Target $Sam -Result 'FAIL' -Detail $_.Exception.Message
            }
            $lStatus.ForeColor = [System.Drawing.Color]::FromArgb(156,0,6)
            $lStatus.Text      = 'Save failed - see message.'
            [System.Windows.Forms.MessageBox]::Show(
                "Failed to save contact details for '$Sam':`r`n$($_.Exception.Message)",
                'Edit Contacts','OK','Warning')
        }
    })

    $btnClose.Add_Click({ $dlg.Close() })
    $dlg.ShowDialog() | Out-Null
}
#endregion

Export-ModuleMember -Function Show-EditContactsDialog
