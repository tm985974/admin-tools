#region -- ADDirectory.Context.DisableUser.psm1 -------------------------------
# Concern : Show-DisableAccountDialog - modal form for disabling one or more
#           AD user accounts. Description is built from a required base field
#           plus an optional reason.
# Load order: 22 - depends on ADDirectory.Context.Common (script scope),
#                            Services.AD.Reporting (Confirm-Action, Write-OperationLog),
#                            Services.AD.RecoverySnapshot (Get-ADRecoverySnapshot) [3a],
#                            Services.Mail.Send (ConvertTo-MailRecoveryBlock) [4b],
#                            ADDirectory.Users.Load (Update-CachedUser)
# Split from: ADDirectory.Menus.psm1
# Changes   : Description now built from TWO fields that are concatenated:
#             (1) a required base textbox pre-filled with "Disabled on <date>"
#             (an empty base falls back to that same stamp so it is never
#             blank), and (2) an optional editable reason ComboBox carrying the
#             same preset list as bulk offboarding (Terminated / Due to
#             inactivity 90 days / Due to inactivity 180 days / Never logged on
#             / Other), which may also be typed into freely. When a reason is
#             present it is appended to the base as ". <reason>" (a single
#             space when the base already ends in sentence punctuation). The
#             live preview shows the combined result. Replaces the previous
#             single editable box whose text became the description verbatim.
#             Admin tracking mail added after a successful disable batch: opens
#             Show-NotificationMailDialog -AdminOnly (To = admin, no CC) with a
#             one-per-operation summary listing the disabled account(s) and the
#             Description applied. Fires only when at least one account was
#             disabled. Non-fatal.
#             Each successfully disabled account now also patches its cached
#             Users row (via Update-CachedUser - Enabled, Description) and
#             re-renders the Directory tab's Users grid, if that user is
#             currently loaded there. No AD round trip beyond the disable
#             itself; no-op if a user isn't in the currently-loaded OU scope.
#             This is the same fix applied to Unlock/Enable Account
#             (ADDirectory.Menus) - the caller there no longer requeries the
#             whole OU scope after a Disable, since this dialog now handles
#             its own cache patch precisely (it already knows exactly which
#             accounts succeeded and the description applied to each).
#             Recovery detail added: each account's OU and current group
#             memberships are captured via Get-ADRecoverySnapshot (disabling
#             an account does not remove either, so the snapshot can be taken
#             any time relative to the Disable-ADAccount call; it is taken
#             just before, for consistency with every other action that now
#             does this). The tracking mail body no longer lists disabled
#             accounts as a single comma-separated line - it now uses
#             ConvertTo-MailRecoveryBlock to give each account its own
#             "AD Item N / OU / Groups" block, matching the format used by
#             Offboarding, Batch Delete Groups, and Delete Computer(s).
#             BUG FIX: on a fully successful disable, this dialog used to
#             stay open with its own Disable button greyed out (Enabled =
#             $false) while the admin-tracking mail popup opened on top of
#             it - leaving this window orphaned in the background once the
#             mail popup was dismissed, since nothing ever called
#             $dlg.Close() on the success path. The dialog now closes itself
#             once the batch fully succeeds (after the mail popup, which is
#             itself modal and has already been dismissed one way or another
#             by that point). A partial/total failure still leaves the
#             dialog open, with the Disable button left enabled (no longer
#             force-disabled), so the failure detail stays visible for
#             review and the admin can retry without reopening the dialog.
# v1.6.0    : Notification email trimmed to basic information: Action / DC /
#             rows repeated in the message text and the "administrative tracking
#             only" line removed.
#endregion

#region -- Show-DisableAccountDialog ------------------------------------------
function Show-DisableAccountDialog {
    param(
        [System.Collections.Generic.List[PSCustomObject]]$Users,
        [PSCustomObject]$Context
    )
    $F_UI   = New-Object System.Drawing.Font('Segoe UI', 9)
    $F_UI_B = New-Object System.Drawing.Font('Segoe UI', 9,  [System.Drawing.FontStyle]::Bold)
    $F_13B  = New-Object System.Drawing.Font('Segoe UI', 13, [System.Drawing.FontStyle]::Bold)
    $F_DIM  = New-Object System.Drawing.Font('Segoe UI', 8)

    # Same preset list as the bulk offboarding note field. The reason box is
    # editable, so these are quick-pick shortcuts - typing your own works too.
    $reasonPresets = @('Terminated','Due to inactivity 90 days','Due to inactivity 180 days','Never logged on','Other')

    $dlg               = New-Object System.Windows.Forms.Form
    $dlg.Text          = 'Disable Account'
    $dlg.ClientSize    = New-Object System.Drawing.Size(480, 326)
    $dlg.FormBorderStyle = 'FixedSingle'
    $dlg.MaximizeBox   = $false
    $dlg.StartPosition = 'CenterParent'
    $dlg.BackColor     = [System.Drawing.Color]::FromArgb(235,238,242)

    $pTitle            = New-Object System.Windows.Forms.Panel
    $pTitle.Location   = New-Object System.Drawing.Point(0,0)
    $pTitle.Size       = New-Object System.Drawing.Size(480,48)
    $pTitle.BackColor  = [System.Drawing.Color]::FromArgb(0,99,177)
    $dlg.Controls.Add($pTitle)
    $lT                = New-Object System.Windows.Forms.Label
    $lT.Text           = '   Disable Account'
    $lT.Location       = New-Object System.Drawing.Point(0,0)
    $lT.Size           = New-Object System.Drawing.Size(480,48)
    $lT.Font           = $F_13B; $lT.ForeColor = [System.Drawing.Color]::White; $lT.TextAlign = 'MiddleLeft'
    $pTitle.Controls.Add($lT)

    $names = ($Users | ForEach-Object { $_.Sam }) -join ', '
    $lAcct = New-Object System.Windows.Forms.Label
    $lAcct.Text      = "Account(s): $names"
    $lAcct.Location  = New-Object System.Drawing.Point(16, 60)
    $lAcct.Size      = New-Object System.Drawing.Size(448, 20)
    $lAcct.Font      = $F_UI_B; $lAcct.ForeColor = [System.Drawing.Color]::FromArgb(0,60,130)
    $dlg.Controls.Add($lAcct)

    # -- Required base description field ---------------------------------------
    $lDesc          = New-Object System.Windows.Forms.Label
    $lDesc.Text     = 'Description:'; $lDesc.Font = $F_UI
    $lDesc.Location = New-Object System.Drawing.Point(16, 92)
    $lDesc.Size     = New-Object System.Drawing.Size(84, 20)
    $dlg.Controls.Add($lDesc)

    $tbDesc          = New-Object System.Windows.Forms.TextBox
    $tbDesc.Location = New-Object System.Drawing.Point(104, 90)
    $tbDesc.Size     = New-Object System.Drawing.Size(360, 24); $tbDesc.Font = $F_UI
    $dlg.Controls.Add($tbDesc)

    # -- Optional reason field -------------------------------------------------
    $lAdd          = New-Object System.Windows.Forms.Label
    $lAdd.Text     = 'Add reason (optional):'; $lAdd.Font = $F_DIM
    $lAdd.Location = New-Object System.Drawing.Point(16, 122)
    $lAdd.Size     = New-Object System.Drawing.Size(448, 16)
    $lAdd.ForeColor = [System.Drawing.Color]::DimGray
    $dlg.Controls.Add($lAdd)

    $cmbReason               = New-Object System.Windows.Forms.ComboBox
    $cmbReason.Location      = New-Object System.Drawing.Point(16, 140)
    $cmbReason.Size          = New-Object System.Drawing.Size(448, 24)
    $cmbReason.DropDownStyle = 'DropDown'; $cmbReason.Font = $F_UI
    $reasonPresets | ForEach-Object { [void]$cmbReason.Items.Add($_) }
    $dlg.Controls.Add($cmbReason)

    $lPreviewCap           = New-Object System.Windows.Forms.Label
    $lPreviewCap.Text      = 'Description will be set to:'; $lPreviewCap.Font = $F_DIM
    $lPreviewCap.Location  = New-Object System.Drawing.Point(16, 172)
    $lPreviewCap.Size      = New-Object System.Drawing.Size(200, 16)
    $lPreviewCap.ForeColor = [System.Drawing.Color]::DimGray
    $dlg.Controls.Add($lPreviewCap)

    $lPreview           = New-Object System.Windows.Forms.Label
    $lPreview.Location  = New-Object System.Drawing.Point(16, 190)
    $lPreview.Size      = New-Object System.Drawing.Size(448, 36)
    $lPreview.Font      = $F_UI_B
    $lPreview.ForeColor = [System.Drawing.Color]::FromArgb(0,60,130)
    $dlg.Controls.Add($lPreview)

    $lStatus           = New-Object System.Windows.Forms.Label
    $lStatus.Location  = New-Object System.Drawing.Point(16, 234)
    $lStatus.Size      = New-Object System.Drawing.Size(448, 36)
    $lStatus.Font      = $F_UI; $lStatus.ForeColor = [System.Drawing.Color]::DimGray
    $dlg.Controls.Add($lStatus)

    $btnDisable           = New-Object System.Windows.Forms.Button
    $btnDisable.Text      = 'Disable Account'
    $btnDisable.Location  = New-Object System.Drawing.Point(16, 282)
    $btnDisable.Size      = New-Object System.Drawing.Size(140, 30)
    $btnDisable.FlatStyle = 'Standard'; $btnDisable.Font = $F_UI_B
    $dlg.Controls.Add($btnDisable)

    $btnCancel              = New-Object System.Windows.Forms.Button
    $btnCancel.Text         = 'Cancel'
    $btnCancel.Location     = New-Object System.Drawing.Point(374, 282)
    $btnCancel.Size         = New-Object System.Drawing.Size(90, 30)
    $btnCancel.FlatStyle    = 'Standard'; $btnCancel.Font = $F_UI
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $dlg.Controls.Add($btnCancel)
    $dlg.CancelButton = $btnCancel

    # Description = required base + optional reason. The base is required; an
    # empty base falls back to the date stamp so it is never blank. A reason,
    # when present, is appended as ". <reason>" (single space if the base
    # already ends in sentence punctuation).
    $buildDesc = {
        $base = $tbDesc.Text.Trim()
        if (-not $base) { $base = "Disabled on $(Get-Date -Format 'M/d/yy')" }
        $add = $cmbReason.Text.Trim()
        if ($add) {
            if ($base -match '[.!?]$') { "$base $add" } else { "$base. $add" }
        } else {
            $base
        }
    }

    $updatePreview = { $lPreview.Text = & $buildDesc }
    $tbDesc.Add_TextChanged($updatePreview)
    $cmbReason.Add_SelectedIndexChanged($updatePreview)
    $cmbReason.Add_TextChanged($updatePreview)

    # Pre-fill the required base with "Disabled on <date>" on open.
    $tbDesc.Text = "Disabled on $(Get-Date -Format 'M/d/yy')"
    & $updatePreview

    $showMailDlgFnD     = ${function:Show-NotificationMailDialog}
    $updateCachedUserFn = ${function:Update-CachedUser}
    $btnDisable.Add_Click({
        $desc       = & $buildDesc
        $countNames = ($Users | ForEach-Object { $_.Sam }) -join ', '
        $msg = "Disable $($Users.Count) account(s)?`n$countNames`n`nDescription:`n$desc"
        if (-not (Confirm-Action -Title 'Disable Account' -Message $msg -ActionLabel 'Disable')) { return }
        $srvParam = if ($Context.TargetDC) { @{ Server = $Context.TargetDC } } else { @{} }
        $ok = 0; $fail = 0; $failMsg = ''
        $disabledOk = [System.Collections.Generic.List[string]]::new()
        # Recovery snapshot (OU + current groups) per account. Disabling does
        # not remove either, so ordering relative to Disable-ADAccount below
        # is not load-bearing for correctness - captured first purely for
        # consistency with the other actions that DO require pre-mutation
        # ordering (Offboard, Batch Delete Groups, Delete Computer(s)).
        $recoveryItems = [System.Collections.Generic.List[PSCustomObject]]::new()
        foreach ($u in $Users) {
            try {
                if (Get-Command Get-ADRecoverySnapshot -ErrorAction SilentlyContinue) {
                    $snap = Get-ADRecoverySnapshot -Identity $u.Sam -Type User -SrvParam $srvParam
                    if ($snap -and $snap.Found) {
                        [void]$recoveryItems.Add([PSCustomObject]@{
                            Label     = $u.Sam
                            OU        = $snap.OU
                            ListLabel = 'Groups'
                            List      = $snap.Groups
                        })
                    }
                }
                Disable-ADAccount -Identity $u.Sam @srvParam -ErrorAction Stop
                Set-ADUser        -Identity $u.Sam @srvParam -Description $desc -ErrorAction Stop
                Write-OperationLog -Context $Context -Action 'DISABLE' -Target $u.Sam -Result 'OK' -Detail $desc
                [void]$disabledOk.Add($u.Sam)
                $ok++
            } catch {
                Write-OperationLog -Context $Context -Action 'DISABLE' -Target $u.Sam -Result 'FAIL' -Detail $_.Exception.Message
                $failMsg += "$($u.Sam): $($_.Exception.Message)`n"; $fail++
            }
        }
        if ($fail -gt 0) {
            $lStatus.ForeColor = [System.Drawing.Color]::FromArgb(156,0,6)
            $lStatus.Text = "$ok succeeded. $fail failed: $failMsg"
        } else {
            $lStatus.ForeColor = [System.Drawing.Color]::FromArgb(0,97,0)
            $lStatus.Text = "$ok account(s) disabled successfully."
        }

        # -- Patch each affected cached Users row (Enabled, Description) ------
        # No AD round trip - the disable itself already happened above. No-op
        # for any account not currently loaded in the OU scope.
        if ($updateCachedUserFn) {
            foreach ($us in $disabledOk) {
                & $updateCachedUserFn -Sam $us -Properties @{ Enabled = 'False'; Description = $desc }
            }
        }

        # -- Admin tracking mail (To admin, no CC) - one summary per operation --
        # Popup pre-addressed to the admin for documentation/tracking. Fires
        # only when at least one account was disabled. Non-fatal. Body now
        # gives each disabled account its own recovery block (OU + groups)
        # instead of a single comma-separated account list.
        if ($ok -gt 0 -and $showMailDlgFnD) {
            $disabledCsv = $disabledOk -join ', '
            $details = [ordered]@{
                'Admin'       = if ($Context -and $Context.AdminAccount) { $Context.AdminAccount } else { "$env:USERDOMAIN\$env:USERNAME" }
                'Domain'      = if ($Context -and $Context.Domain)       { $Context.Domain }       else { $env:USERDNSDOMAIN }
                'Timestamp'   = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
            }
            $bodyText = "The following account(s) were disabled:" + "`r`n`r`n" +
                        (($disabledOk | ForEach-Object { "- " + $_ }) -join "`r`n") + "`r`n`r`n" +
                        "Description set to: $desc"

            # Recovery block: each disabled account's OU + group memberships
            # at the time of this run, in case group membership needs to be
            # restored later without a separate lookup.
            $recoverySubset = @($recoveryItems | Where-Object { $disabledOk -contains $_.Label })
            if ($recoverySubset.Count -gt 0 -and (Get-Command ConvertTo-MailRecoveryBlock -ErrorAction SilentlyContinue)) {
                $recoveryBlock = ConvertTo-MailRecoveryBlock -Items $recoverySubset `
                    -Heading 'Recovery details (state at time of disable):'
                if ($recoveryBlock) {
                    $bodyText += "`r`n`r`n" + $recoveryBlock
                }
            }

            & $showMailDlgFnD `
                -Context     $Context `
                -Sam         '' `
                -ActionTitle 'Account Disabled' `
                -Subject     "AD Account Disabled: $disabledCsv" `
                -Details     $details `
                -BodyText    $bodyText `
                -AdminOnly
        }

        # Close this dialog once the batch fully succeeded - Show-
        # NotificationMailDialog above is itself modal (ShowDialog blocks),
        # so by this point the mail popup has already been dismissed one
        # way or another and there is nothing left in THIS window for the
        # admin to act on. A partial/total failure leaves the dialog open
        # instead, so the failure detail in $lStatus stays visible for
        # review rather than being closed out from under the admin.
        if ($fail -eq 0) { $dlg.Close() }
    })
    $btnCancel.Add_Click({ $dlg.Close() })
    $dlg.ShowDialog() | Out-Null
}
#endregion

Export-ModuleMember -Function Show-DisableAccountDialog
