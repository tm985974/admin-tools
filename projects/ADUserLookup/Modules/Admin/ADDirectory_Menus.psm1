#region -- ADDirectory.Menus.psm1 --------------------------------------------
# Concern : Context menu factories for Users, Groups, and Computers.
#           New-UserContextMenu  - find domain sessions, reset, expiry, edit
#                                   groups, unlock, enable, disable,
#                                   delete user(s), copy.
#           New-GroupContextMenu - edit members, remove user from group(s),
#                                   delete group(s), copy group name.
#           New-ComputerContextMenu - test connectivity, RDP, Radmin, ping,
#                                   MMC, BitLocker key
#                                   dialog, LAPS password dialog,
#                                   delete computer(s), copy.
#           All menus use -TargetProvider pattern (scriptblock) so the same
#           factory builds both grid menus and tree-leaf menus.
# Load order: 25 - depends on ADDirectory.Context.Common (script scope),
#                            ADDirectory.Context.DisableUser (Show-DisableAccountDialog),
#                            ADDirectory.Context.GroupMembers (Show-GroupMembersDialog),
#                            ADDirectory.Context.UserGroups (Show-EditUserGroupsDialog),
#                            ADDirectory.UserSessions.Dialog (Show-UserSessionsDialog),
#                            ADDirectory.Context.LockoutStatus (Show-LockoutStatusDialog),
#                            ADComputers.BitLocker.Dialog (Show-BitLockerDialog),
#                            ADComputers.LAPS.Dialog (Show-LAPSDialog),
#                            ADComputers.Sessions.Dialog (Show-ComputerSessionsDialog),
#                            ADDirectory.Context.DeleteComputer (Invoke-DeleteComputers),
#                            ADDirectory.Context.DeleteUser (Invoke-DeleteUsers),
#                            ADDirectory.Context.DeleteGroup (Invoke-DeleteGroups),
#                            Services.AD.Reporting (Confirm-Action, Write-OperationLog),
#                            Services.Mail.Dialog (Show-NotificationMailDialog) [4c],
#                            ADDirectory.Users.Load (Update-CachedUser)
# Split from: ADDirectory.Menus.psm1
# Changes   : Added 'Delete User(s)...' to New-UserContextMenu, directly
#             below Disable Account, set apart with a separator on both
#             sides (the single most destructive item on this menu).
#             Added 'Delete Group(s)...' to New-GroupContextMenu, between
#             the optional Remove User from Group(s) block and Copy Group
#             Name(s). Both are captured via ${function:Invoke-DeleteUsers} /
#             ${function:Invoke-DeleteGroups} the same way
#             'Delete Computer(s)...' already captures
#             ${function:Invoke-DeleteComputers} - this menu only gathers
#             the selected SAMs/names and calls the matching function with
#             $script:DirContext; the confirm prompt, per-target recovery
#             snapshot, deletion, cache patch, and admin tracking mail all
#             live in ADDirectory.Context.DeleteUser /
#             ADDirectory.Context.DeleteGroup respectively. Because these
#             two menu factories are shared verbatim between the Directory
#             tab's grids and the OU tree's leaf nodes, both new actions are
#             immediately available on the tree with no tree-specific code.
# v1.6.0    : Notification email trimmed to basic information: Action / DC /
#             rows repeated in the message text and the "administrative tracking
#             only" line removed. Unlock email to the person: Account only
#             (admin still CC'd).
#endregion

#region -- New-UserContextMenu ------------------------------------------------
function New-UserContextMenu {
    <#
    .SYNOPSIS
        Builds a user right-click menu. -TargetProvider is a scriptblock that
        returns the current target users as @({Sam, Display}) objects.
        GetNewClosure() captures the provider so the same factory builds both
        the grid menu and the tree-leaf menu.
    #>
    param([scriptblock]$TargetProvider, [PSCustomObject]$Context)
    $menu      = New-Object System.Windows.Forms.ContextMenuStrip
    $menu.Font = New-Object System.Drawing.Font('Segoe UI', 9)

    # Confirm-Action / Write-OperationLog (Services.AD.Reporting / Services.Logging)
    # and Update-TreeLeavesForSelection / Show-DisableAccountDialog (other modules)
    # are unreachable by bare name from inside .GetNewClosure() blocks (same bug
    # class fixed for Show-GroupMembersDialog in New-GroupContextMenu), so they
    # are captured here once and invoked via & in every closure that needs them.
    $confirmActionFn      = ${function:Confirm-Action}
    $writeOpLogFn         = ${function:Write-OperationLog}
    $updateTreeLeaves     = ${function:Update-TreeLeavesForSelection}
    $updateCachedUserFn   = ${function:Update-CachedUser}
    $showDisableDlgFn     = ${function:Show-DisableAccountDialog}
    $showEditGroupsFn     = ${function:Show-EditUserGroupsDialog}
    $showEditContactsFn   = ${function:Show-EditContactsDialog}
    $showUserSessionsFn   = ${function:Show-UserSessionsDialog}
    $showLockoutStatusFn  = ${function:Show-LockoutStatusDialog}
    $showResetPwFn        = ${function:Show-ResetPasswordDialog}
    $setCloneFn           = ${function:Set-CloneUserSource}
    $showMailDlgFn        = ${function:Show-NotificationMailDialog}
    $invDeleteUserFn      = ${function:Invoke-DeleteUsers}
    # Context threaded in from the caller (see param). The Menus module has
    # its own $script:DirContext which is never populated - per-module script
    # scope means the launcher's Context set in other modules is not visible
    # here. Capture the real Context so every closure passes a live object.
    $capturedDirContext = $Context

    # Find Domain Sessions
    $miSessions      = New-Object System.Windows.Forms.ToolStripMenuItem
    $miSessions.Text = 'Find Domain Sessions...'
    $miSessions.Add_Click(({
        $targets = @(& $TargetProvider)
        if ($targets.Count -ne 1) {
            [System.Windows.Forms.MessageBox]::Show('Select exactly one user.','Find Domain Sessions','OK','Information'); return
        }
        $t = $targets[0]
        if ($showUserSessionsFn) {
            & $showUserSessionsFn -Sam $t.Sam -DisplayName $t.Display -Context $capturedDirContext
        } else {
            [System.Windows.Forms.MessageBox]::Show('UserSessions dialog module not loaded.','Find Domain Sessions','OK','Warning')
        }
    }).GetNewClosure())
    [void]$menu.Items.Add($miSessions)

    # Check Lockout Status
    $miLockout      = New-Object System.Windows.Forms.ToolStripMenuItem
    $miLockout.Text = 'Check Lockout Status...'
    $miLockout.Add_Click(({
        $targets = @(& $TargetProvider)
        if ($targets.Count -ne 1) {
            [System.Windows.Forms.MessageBox]::Show('Select exactly one user.','Check Lockout Status','OK','Information'); return
        }
        $t = $targets[0]
        if ($showLockoutStatusFn) {
            & $showLockoutStatusFn -Sam $t.Sam -DisplayName $t.Display -Context $capturedDirContext
        } else {
            [System.Windows.Forms.MessageBox]::Show('LockoutStatus dialog module not loaded.','Check Lockout Status','OK','Warning')
        }
    }).GetNewClosure())
    [void]$menu.Items.Add($miLockout)
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

    # Reset Password
    $miReset      = New-Object System.Windows.Forms.ToolStripMenuItem
    $miReset.Text = 'Reset Password...'
    $miReset.Add_Click(({
        $targets = @(& $TargetProvider)
        if ($targets.Count -ne 1) {
            [System.Windows.Forms.MessageBox]::Show('Select exactly one user.','Reset Password','OK','Information'); return
        }
        $u = [PSCustomObject]@{ SamAccountName=$targets[0].Sam; DisplayName=$targets[0].Display }
        if ($showResetPwFn) {
            & $showResetPwFn -User $u -Context $capturedDirContext
        } else {
            [System.Windows.Forms.MessageBox]::Show('Reset Password dialog module not loaded.','Reset Password','OK','Warning')
        }
    }).GetNewClosure())
    [void]$menu.Items.Add($miReset)

    # Set Account Expiry
    $miExpiry      = New-Object System.Windows.Forms.ToolStripMenuItem
    $miExpiry.Text = 'Set Account Expiry...'
    $miExpiry.Add_Click(({
        $targets = @(& $TargetProvider)
        if ($targets.Count -ne 1) {
            [System.Windows.Forms.MessageBox]::Show('Select exactly one user.','Set Expiry','OK','Information'); return
        }
        $u = [PSCustomObject]@{ SamAccountName=$targets[0].Sam; DisplayName=$targets[0].Display }
        if (Get-Command Show-SetExpiryDialog -ErrorAction SilentlyContinue) {
            Show-SetExpiryDialog -User $u -Context $capturedDirContext
        }
    }).GetNewClosure())
    [void]$menu.Items.Add($miExpiry)

    # Edit Groups
    $miEditGroups      = New-Object System.Windows.Forms.ToolStripMenuItem
    $miEditGroups.Text = 'Edit Groups...'
    $miEditGroups.Add_Click(({
        $targets = @(& $TargetProvider)
        if ($targets.Count -ne 1) {
            [System.Windows.Forms.MessageBox]::Show('Select exactly one user.','Edit Groups','OK','Information'); return
        }
        if ($showEditGroupsFn) {
            & $showEditGroupsFn -Sam $targets[0].Sam -DisplayName $targets[0].Display -Context $capturedDirContext
        }
    }).GetNewClosure())
    [void]$menu.Items.Add($miEditGroups)

    # Edit Contacts - single-target editor for Email / Phone / Mobile / Pager.
    $miEditContacts      = New-Object System.Windows.Forms.ToolStripMenuItem
    $miEditContacts.Text = 'Edit Contacts...'
    $miEditContacts.Add_Click(({
        $targets = @(& $TargetProvider)
        if ($targets.Count -ne 1) {
            [System.Windows.Forms.MessageBox]::Show('Select exactly one user.','Edit Contacts','OK','Information'); return
        }
        if ($showEditContactsFn) {
            & $showEditContactsFn -Sam $targets[0].Sam -DisplayName $targets[0].Display -Context $capturedDirContext
        } else {
            [System.Windows.Forms.MessageBox]::Show('Edit Contacts dialog module not loaded.','Edit Contacts','OK','Warning')
        }
    }).GetNewClosure())
    [void]$menu.Items.Add($miEditContacts)

    # Clone User - open Account Management prefilled with this user's OU and
    # set as the "Copy Groups From" source. All identity/logon fields are left
    # blank for the operator. Single-select only.
    $miClone      = New-Object System.Windows.Forms.ToolStripMenuItem
    $miClone.Text = 'Clone User...'
    $miClone.Add_Click(({
        $targets = @(& $TargetProvider)
        if ($targets.Count -ne 1) {
            [System.Windows.Forms.MessageBox]::Show('Select exactly one user.','Clone User','OK','Information'); return
        }
        $sam  = $targets[0].Sam
        $disp = $targets[0].Display

        # Resolve the source user's parent OU (DN with the leading RDN removed,
        # honouring escaped commas inside the CN).
        $sourceOU = ''
        try {
            $srvParam = if ($capturedDirContext -and $capturedDirContext.TargetDC) {
                @{ Server = $capturedDirContext.TargetDC }
            } else { @{} }
            $srcUser = Get-ADUser -Identity $sam -Properties DistinguishedName @srvParam -ErrorAction Stop
            $dn = [string]$srcUser.DistinguishedName
            if ($dn -match '^(?:[^,\\]|\\.)*,(.*)$') { $sourceOU = $Matches[1] }
        } catch {
            [System.Windows.Forms.MessageBox]::Show("Could not resolve OU for '$sam': $($_.Exception.Message)",'Clone User','OK','Warning')
        }

        # Prefill the Create User form (this also loads the Copy Groups list).
        if ($setCloneFn) {
            & $setCloneFn -Sam $sam -Display $disp -SourceOU $sourceOU
        } else {
            [System.Windows.Forms.MessageBox]::Show('Create User module not loaded.','Clone User','OK','Warning')
        }

        # Bring the Account Management tab to front. This module is dot-sourced
        # via [scriptblock]::Create, so reaching the launcher's $script:Tabs /
        # $script:Context navigation state from here is unreliable (that is why
        # the earlier attempts silently no-oped). Instead, locate the TabControl
        # from a handle this menu genuinely owns at click time - the
        # ContextMenuStrip's SourceControl - walk up to its Form, find the main
        # TabControl, and select the Account Management page. The switch is
        # deferred via BeginInvoke so it survives the ContextMenuStrip closing and
        # restoring focus to the source grid, which would otherwise snap the
        # selection back to this tab. If the tab cannot be located the operator is
        # told, rather than the switch failing silently.
        $navForm = $null
        $navSrc  = $menu.SourceControl
        if ($navSrc) { $navForm = $navSrc.FindForm() }
        if (-not $navForm) { $navForm = [System.Windows.Forms.Form]::ActiveForm }

        $navDone = $false
        if ($navForm) {
            $navTabCtl = $null
            $navQueue  = New-Object System.Collections.Generic.Queue[System.Windows.Forms.Control]
            foreach ($navChild in $navForm.Controls) { $navQueue.Enqueue($navChild) }
            while ($navQueue.Count -gt 0) {
                $navCtl = $navQueue.Dequeue()
                if ($navCtl -is [System.Windows.Forms.TabControl]) { $navTabCtl = $navCtl; break }
                foreach ($navChild in $navCtl.Controls) { $navQueue.Enqueue($navChild) }
            }
            if ($navTabCtl) {
                foreach ($navPage in $navTabCtl.TabPages) {
                    if ((([string]$navPage.Text).Trim()) -eq 'Account Management') {
                        $navTargetCtl = $navTabCtl
                        $navTargetTab = $navPage
                        $navSwitch = { $navTargetCtl.SelectedTab = $navTargetTab }.GetNewClosure()
                        [void]$navTargetCtl.BeginInvoke([System.Windows.Forms.MethodInvoker]$navSwitch)
                        $navDone = $true
                        break
                    }
                }
            }
        }
        if (-not $navDone) {
            [System.Windows.Forms.MessageBox]::Show(
                'Clone: fields were populated, but the Account Management tab could not be located to switch to.',
                'Clone User','OK','Warning')
        }
    }).GetNewClosure())
    [void]$menu.Items.Add($miClone)

    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

    # Unlock Account
    $miUnlock      = New-Object System.Windows.Forms.ToolStripMenuItem
    $miUnlock.Text = 'Unlock Account'
    $invSetStatus  = ${function:Invoke-SetStatus}
    $miUnlock.Add_Click(({
        $targets  = @(& $TargetProvider)
        if ($targets.Count -eq 0) { return }
        $srvParam = if ($capturedDirContext.TargetDC) { @{ Server = $capturedDirContext.TargetDC } } else { @{} }

        # -- Pre-flight state check -------------------------------------------
        # Resolve LockedOut for every selected target BEFORE prompting and
        # partition into actionable (locked), already-unlocked, and unreadable.
        # Unlock-ADAccount succeeds silently on an account that is not locked,
        # so acting on a no-op would report a false 'unlocked' and send a
        # spurious notification. Filtering here removes no-ops before the loop.
        $actionable = [System.Collections.Generic.List[object]]::new()
        $already    = [System.Collections.Generic.List[string]]::new()
        $unreadable = [System.Collections.Generic.List[string]]::new()
        foreach ($t in $targets) {
            $tSam = $t.Sam
            if (-not $tSam) { continue }
            try {
                $st = Get-ADUser -Identity $tSam -Properties LockedOut @srvParam -ErrorAction Stop
                if ($st.LockedOut) { [void]$actionable.Add($t) } else { [void]$already.Add($tSam) }
            } catch {
                [void]$unreadable.Add($tSam)
            }
        }

        # Nothing actionable and nothing unreadable: every selected account is
        # already unlocked. Say so and do nothing.
        if ($actionable.Count -eq 0 -and $unreadable.Count -eq 0) {
            $noneMsg = if ($already.Count -eq 1) {
                "Account '$($already[0])' is already unlocked."
            } else {
                "All $($already.Count) selected accounts are already unlocked."
            }
            [System.Windows.Forms.MessageBox]::Show($noneMsg,'Unlock Account','OK','Information')
            return
        }

        # Mixed selection: some accounts are already unlocked or unreadable.
        # Warn which will be ignored, then continue with the actionable set.
        if ($already.Count -gt 0 -or $unreadable.Count -gt 0) {
            $warn = 'The following selected account(s) will be ignored:'
            if ($already.Count -gt 0)    { $warn += "`n`nAlready unlocked ($($already.Count)):`n$($already -join ', ')" }
            if ($unreadable.Count -gt 0) { $warn += "`n`nState could not be read ($($unreadable.Count)):`n$($unreadable -join ', ')" }
            $warn += "`n`nContinue and unlock the remaining $($actionable.Count) account(s)?"
            $go = [System.Windows.Forms.MessageBox]::Show($warn,'Unlock Account','YesNo','Warning')
            if ($go -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        }

        $sams = @($actionable | ForEach-Object { $_.Sam })
        $msg  = if ($sams.Count -eq 1) { "Unlock account for $($sams[0])?" } else { "Unlock $($sams.Count) selected accounts?" }
        if (-not (& $confirmActionFn -Title 'Unlock Account' -Message $msg -ActionLabel 'Unlock')) { return }

        $ok = 0; $fail = 0
        $unlockedOk = [System.Collections.Generic.List[string]]::new()
        foreach ($sam in $sams) {
            try {
                Unlock-ADAccount -Identity $sam @srvParam -ErrorAction Stop
                & $writeOpLogFn -Context $capturedDirContext -Action 'UNLOCK' -Target $sam -Result 'OK'
                [void]$unlockedOk.Add($sam)
                $ok++

                # -- Mail notification per successfully unlocked account (non-fatal) --
                if ($showMailDlgFn) {
                    $disp = ($targets | Where-Object { $_.Sam -eq $sam } | Select-Object -First 1).Display
                    if (-not $disp) { $disp = $sam }

                    $details = [ordered]@{
                        'Account'   = "$disp ($sam)"
                    }

                    $bodyText = "The Active Directory account listed above has been unlocked." + "`r`n`r`n" +
                                "If you did not request this action, please contact your IT administrator immediately."

                    & $showMailDlgFn `
                        -Context     $capturedDirContext `
                        -Sam         $sam `
                        -ActionTitle 'Account Unlocked' `
                        -Subject     "AD Account Unlocked: $disp ($sam)" `
                        -Details     $details `
                        -BodyText    $bodyText
                }

            } catch {
                & $writeOpLogFn -Context $capturedDirContext -Action 'UNLOCK' -Target $sam -Result 'FAIL' -Detail $_.Exception.Message
                $fail++
            }
        }
        & $invSetStatus "Unlock: $ok unlocked, $fail failed." $(if ($fail -gt 0) {'warn'} else {'ok'})

        # Visible feedback: the status bar is easy to miss, so surface bulk and
        # failure results in a MessageBox. A single actionable success stays
        # quiet (status bar only) to avoid a click-through on the common path.
        if ($sams.Count -eq 1) {
            if ($fail -eq 1) {
                [System.Windows.Forms.MessageBox]::Show(
                    "Failed to unlock '$($sams[0])'.",
                    'Unlock Account','OK','Warning')
            }
        } else {
            $icon = if ($fail -gt 0) { 'Warning' } else { 'Information' }
            [System.Windows.Forms.MessageBox]::Show(
                "Unlock complete.`n`nUnlocked: $ok`nFailed: $fail",
                'Unlock Account', 'OK', $icon)
        }

        # Patch only the affected row(s) in the cached Users list and
        # re-render the grid - no full-domain/OU requery.
        if ($updateCachedUserFn) {
            foreach ($us in $unlockedOk) {
                & $updateCachedUserFn -Sam $us -Properties @{ LockedOut = 'False' }
            }
        }
        & $updateTreeLeaves
    }).GetNewClosure())
    [void]$menu.Items.Add($miUnlock)

    # Enable Account
    $miEnable      = New-Object System.Windows.Forms.ToolStripMenuItem
    $miEnable.Text = 'Enable Account'
    $invSetStatus2 = ${function:Invoke-SetStatus}
    $miEnable.Add_Click(({
        $targets  = @(& $TargetProvider)
        if ($targets.Count -eq 0) { return }
        $srvParam = if ($capturedDirContext.TargetDC) { @{ Server = $capturedDirContext.TargetDC } } else { @{} }

        # -- Pre-flight state check -------------------------------------------
        # Resolve Enabled for every selected target BEFORE prompting and
        # partition into actionable (disabled), already-enabled, and unreadable.
        # Enable-ADAccount succeeds silently on an already-enabled account and
        # the Description stamp below would overwrite for a no-op, so no-ops are
        # filtered out here.
        $actionable = [System.Collections.Generic.List[object]]::new()
        $already    = [System.Collections.Generic.List[string]]::new()
        $unreadable = [System.Collections.Generic.List[string]]::new()
        foreach ($t in $targets) {
            $tSam = $t.Sam
            if (-not $tSam) { continue }
            try {
                $st = Get-ADUser -Identity $tSam -Properties Enabled @srvParam -ErrorAction Stop
                if ($st.Enabled) { [void]$already.Add($tSam) } else { [void]$actionable.Add($t) }
            } catch {
                [void]$unreadable.Add($tSam)
            }
        }

        # Nothing actionable and nothing unreadable: every selected account is
        # already enabled. Say so and do nothing.
        if ($actionable.Count -eq 0 -and $unreadable.Count -eq 0) {
            $noneMsg = if ($already.Count -eq 1) {
                "Account '$($already[0])' is already enabled."
            } else {
                "All $($already.Count) selected accounts are already enabled."
            }
            [System.Windows.Forms.MessageBox]::Show($noneMsg,'Enable Account','OK','Information')
            return
        }

        # Mixed selection: warn which accounts are ignored, then continue with
        # the actionable set.
        if ($already.Count -gt 0 -or $unreadable.Count -gt 0) {
            $warn = 'The following selected account(s) will be ignored:'
            if ($already.Count -gt 0)    { $warn += "`n`nAlready enabled ($($already.Count)):`n$($already -join ', ')" }
            if ($unreadable.Count -gt 0) { $warn += "`n`nState could not be read ($($unreadable.Count)):`n$($unreadable -join ', ')" }
            $warn += "`n`nContinue and enable the remaining $($actionable.Count) account(s)?"
            $go = [System.Windows.Forms.MessageBox]::Show($warn,'Enable Account','YesNo','Warning')
            if ($go -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        }

        $sams = @($actionable | ForEach-Object { $_.Sam })
        $msg  = if ($sams.Count -eq 1) { "Enable account for $($sams[0])?" } else { "Enable $($sams.Count) selected accounts?" }
        if (-not (& $confirmActionFn -Title 'Enable Account' -Message $msg -ActionLabel 'Enable')) { return }
        $stamp = "Enabled on $(Get-Date -Format 'M/d/yy')."

        $ok = 0; $fail = 0; $failMsg = ''
        $enabledOk = [System.Collections.Generic.List[string]]::new()
        foreach ($sam in $sams) {
            try {
                Enable-ADAccount -Identity $sam @srvParam -ErrorAction Stop
                Set-ADUser       -Identity $sam @srvParam -Description $stamp -ErrorAction Stop
                & $writeOpLogFn -Context $capturedDirContext -Action 'ENABLE' -Target $sam -Result 'OK' -Detail $stamp
                [void]$enabledOk.Add($sam)
                $ok++
            } catch {
                & $writeOpLogFn -Context $capturedDirContext -Action 'ENABLE' -Target $sam -Result 'FAIL' -Detail $_.Exception.Message
                $failMsg += "$sam`: $($_.Exception.Message)`n"; $fail++
            }
        }
        & $invSetStatus2 "Enable: $ok enabled, $fail failed." $(if ($fail -gt 0) {'warn'} else {'ok'})

        # Visible feedback: surface bulk and failure results in a MessageBox. A
        # single actionable success stays quiet (status bar only).
        if ($sams.Count -eq 1) {
            if ($fail -eq 1) {
                [System.Windows.Forms.MessageBox]::Show(
                    "Failed to enable '$($sams[0])':`n`n$failMsg",
                    'Enable Account','OK','Warning')
            }
        } else {
            $summary = "Enable complete.`n`nEnabled: $ok`nFailed: $fail"
            if ($fail -gt 0) { $summary += "`n`nFailures:`n$failMsg" }
            $icon = if ($fail -gt 0) { 'Warning' } else { 'Information' }
            [System.Windows.Forms.MessageBox]::Show($summary, 'Enable Account', 'OK', $icon)
        }

        # -- Admin tracking mail (To admin, no CC) - one summary per operation --
        # Popup pre-addressed to the admin for documentation/tracking. Fires
        # only when at least one account was enabled. Non-fatal.
        if ($ok -gt 0 -and $showMailDlgFn) {
            $enabledCsv = $enabledOk -join ', '
            $details = [ordered]@{
                'Admin'     = if ($capturedDirContext -and $capturedDirContext.AdminAccount) { $capturedDirContext.AdminAccount } else { "$env:USERDOMAIN\$env:USERNAME" }
                'Domain'    = if ($capturedDirContext -and $capturedDirContext.Domain)       { $capturedDirContext.Domain }       else { $env:USERDNSDOMAIN }
                'Timestamp' = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
            }
            $bodyText = "The following account(s) were enabled:" + "`r`n`r`n" +
                        (($enabledOk | ForEach-Object { "- " + $_ }) -join "`r`n")
            & $showMailDlgFn `
                -Context     $capturedDirContext `
                -Sam         '' `
                -ActionTitle 'Account Enabled' `
                -Subject     "AD Account Enabled: $enabledCsv" `
                -Details     $details `
                -BodyText    $bodyText `
                -AdminOnly
        }

        # Patch only the affected row(s) in the cached Users list and
        # re-render the grid - no full-domain/OU requery.
        if ($updateCachedUserFn) {
            foreach ($us in $enabledOk) {
                & $updateCachedUserFn -Sam $us -Properties @{ Enabled = 'True'; Description = $stamp }
            }
        }
        & $updateTreeLeaves
    }).GetNewClosure())
    [void]$menu.Items.Add($miEnable)

    # Disable Account
    $miDisable      = New-Object System.Windows.Forms.ToolStripMenuItem
    $miDisable.Text = 'Disable Account'
    $invSetStatus4  = ${function:Invoke-SetStatus}
    $miDisable.Add_Click(({
        $targets = @(& $TargetProvider)
        if ($targets.Count -eq 0) { return }
        $srvParam = if ($capturedDirContext.TargetDC) { @{ Server = $capturedDirContext.TargetDC } } else { @{} }

        # -- Pre-flight state check -------------------------------------------
        # Show-DisableAccountDialog performs no state check of its own - it
        # disables whatever it is handed. Resolve Enabled here and partition
        # into actionable (enabled), already-disabled, and unreadable so no-op
        # accounts never reach the dialog.
        $actionable = [System.Collections.Generic.List[object]]::new()
        $already    = [System.Collections.Generic.List[string]]::new()
        $unreadable = [System.Collections.Generic.List[string]]::new()
        foreach ($t in $targets) {
            $tSam = $t.Sam
            if (-not $tSam) { continue }
            try {
                $st = Get-ADUser -Identity $tSam -Properties Enabled @srvParam -ErrorAction Stop
                if ($st.Enabled) { [void]$actionable.Add($t) } else { [void]$already.Add($tSam) }
            } catch {
                [void]$unreadable.Add($tSam)
            }
        }

        # Nothing actionable and nothing unreadable: every selected account is
        # already disabled. Say so and do nothing.
        if ($actionable.Count -eq 0 -and $unreadable.Count -eq 0) {
            $noneMsg = if ($already.Count -eq 1) {
                "Account '$($already[0])' is already disabled."
            } else {
                "All $($already.Count) selected accounts are already disabled."
            }
            [System.Windows.Forms.MessageBox]::Show($noneMsg,'Disable Account','OK','Information')
            return
        }

        # Mixed selection: warn which accounts are ignored, then continue with
        # the actionable set.
        if ($already.Count -gt 0 -or $unreadable.Count -gt 0) {
            $warn = 'The following selected account(s) will be ignored:'
            if ($already.Count -gt 0)    { $warn += "`n`nAlready disabled ($($already.Count)):`n$($already -join ', ')" }
            if ($unreadable.Count -gt 0) { $warn += "`n`nState could not be read ($($unreadable.Count)):`n$($unreadable -join ', ')" }
            $warn += "`n`nContinue and disable the remaining $($actionable.Count) account(s)?"
            $go = [System.Windows.Forms.MessageBox]::Show($warn,'Disable Account','YesNo','Warning')
            if ($go -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        }

        $rows = [System.Collections.Generic.List[PSCustomObject]]::new()
        foreach ($t in $actionable) {
            [void]$rows.Add([PSCustomObject]@{ Sam=$t.Sam; Display=$t.Display })
        }
        if ($rows.Count -eq 0) { return }
        # Show-DisableAccountDialog (ADDirectory.Context.DisableUser) now
        # patches the cached Users row for each successfully disabled account
        # itself (it already tracks exactly which succeeded and the
        # description applied), so no cache refresh is needed here.
        & $showDisableDlgFn -Users $rows -Context $capturedDirContext
        & $updateTreeLeaves
    }).GetNewClosure())
    [void]$menu.Items.Add($miDisable)
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

    # Delete User(s) - permanent. Recovery snapshot + admin tracking mail are
    # handled entirely inside Invoke-DeleteUsers (ADDirectory.Context.DeleteUser),
    # same shape as Delete Computer(s) below. Set apart with its own
    # separators on both sides since this is the single most destructive
    # action on this menu.
    $miDeleteUser      = New-Object System.Windows.Forms.ToolStripMenuItem
    $miDeleteUser.Text = 'Delete User(s)...'
    $miDeleteUser.Add_Click(({
        $targets = @(& $TargetProvider)
        if ($targets.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show('Select at least one user.','Delete User(s)','OK','Information'); return
        }
        $sams = @($targets | ForEach-Object { $_.Sam } | Where-Object { $_ })
        if ($invDeleteUserFn) {
            & $invDeleteUserFn -Sams $sams -Context $capturedDirContext
        } else {
            [System.Windows.Forms.MessageBox]::Show('Delete User module not loaded.','Delete User(s)','OK','Warning')
        }
        & $updateTreeLeaves
    }).GetNewClosure())
    [void]$menu.Items.Add($miDeleteUser)
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

    # Copy Username(s)
    $miCopy        = New-Object System.Windows.Forms.ToolStripMenuItem
    $miCopy.Text   = 'Copy Username(s)'
    $invSetStatus3 = ${function:Invoke-SetStatus}
    $miCopy.Add_Click(({
        $targets = @(& $TargetProvider)
        $sams    = @($targets | ForEach-Object { $_.Sam } | Where-Object { $_ })
        if ($sams.Count -gt 0) {
            [System.Windows.Forms.Clipboard]::SetText($sams -join "`r`n")
            & $invSetStatus3 "Copied $($sams.Count) username(s) to clipboard." 'ok'
        }
    }).GetNewClosure())
    [void]$menu.Items.Add($miCopy)

    return $menu
}
#endregion

#region -- New-GroupContextMenu -----------------------------------------------
function New-GroupContextMenu {
    <#
    .SYNOPSIS
        Builds a group right-click menu. -TargetProvider returns @({Name, DN}).
        Membership managed via Edit Members dialog.
        GetNewClosure captures the provider.
    .PARAMETER ShowRemoveFromGroup
        Adds a "Remove from Group" item that removes the currently selected
        user(s) in the Users grid from the target group(s). The grid
        reference ($script:UserGrid) is captured into a local variable
        before .GetNewClosure() - reading $script:UserGrid directly from
        inside the closure returns $null (same bug class fixed for
        Confirm-Action/Write-OperationLog elsewhere in this file; applies to
        cross-file script-scope variables too, not just functions). The
        captured reference still points to the live grid object, so
        SelectedRows is always current.
        Only meaningful where the grid represents one user's group
        membership (the Directory tab's Groups list) - not on the standalone
        Groups tab or the OU tree's leaf menu, where there is no "selected
        user" concept. Omit (default $false) for those call sites.
    #>
    param([scriptblock]$TargetProvider, [switch]$ShowRemoveFromGroup, [PSCustomObject]$Context)
    $menu      = New-Object System.Windows.Forms.ContextMenuStrip
    $menu.Font = New-Object System.Drawing.Font('Segoe UI', 9)

    # Context threaded in from the caller. Cross-module $capturedDirContext
    # is null in this module scope (per-module script scope); capture the
    # real Context here and use it in every closure below.
    $capturedDirContext = $Context
    $invDeleteGroupFn   = ${function:Invoke-DeleteGroups}

    $miEdit      = New-Object System.Windows.Forms.ToolStripMenuItem
    $miEdit.Text = 'Edit Members...'
    $showGroupMembersDlg = ${function:Show-GroupMembersDialog}
    $miEdit.Add_Click(({
        $targets = @(& $TargetProvider)
        if ($targets.Count -ne 1) {
            [System.Windows.Forms.MessageBox]::Show('Select exactly one group.','Edit Members','OK','Information'); return
        }
        & $showGroupMembersDlg -GroupName $targets[0].Name -Context $capturedDirContext
    }).GetNewClosure())
    [void]$menu.Items.Add($miEdit)

    if ($ShowRemoveFromGroup) {
        $miRemoveUser     = New-Object System.Windows.Forms.ToolStripMenuItem
        $miRemoveUser.Text = 'Remove User from Group(s)'
        $confirmActionFn2 = ${function:Confirm-Action}
        $writeOpLogFn2    = ${function:Write-OperationLog}
        $readSelUserGrpFn = ${function:Read-SelectedUserGroups}
        $showMailDlgFn2g  = ${function:Show-NotificationMailDialog}
        $userGridRef      = $script:UserGrid
        $miRemoveUser.Add_Click(({
            $targets = @(& $TargetProvider)
            if ($targets.Count -eq 0) { return }
            $sams = @()
            if ($userGridRef) {
                $sams = @($userGridRef.SelectedRows | ForEach-Object { [string]$_.Cells['SamAccountName'].Value } | Where-Object { $_ })
            }
            if ($sams.Count -eq 0) {
                [System.Windows.Forms.MessageBox]::Show('Select a user first.','Remove from Group','OK','Information'); return
            }
            $names   = @($targets | ForEach-Object { $_.Name } | Where-Object { $_ })
            $samDesc = if ($sams.Count -eq 1) { "'$($sams[0])'" } else { "$($sams.Count) users" }
            $msg = if ($names.Count -eq 1) { "Remove $samDesc from '$($names[0])'?" } `
                   else { "Remove $samDesc from $($names.Count) group(s)?`n`n$($names -join ', ')" }
            if (-not (& $confirmActionFn2 -Title 'Remove from Group' -Message $msg -ActionLabel 'Remove')) { return }
            $srvParam = if ($capturedDirContext.TargetDC) { @{ Server = $capturedDirContext.TargetDC } } else { @{} }
            $ok = 0; $fail = 0; $failMsg = ''
            foreach ($groupName in $names) {
                foreach ($sam in $sams) {
                    try {
                        Remove-ADGroupMember -Identity $groupName -Members $sam `
                            @srvParam -Confirm:$false -ErrorAction Stop
                        & $writeOpLogFn2 -Context $capturedDirContext -Action 'REMOVE-GROUP-MEMBER' `
                            -Target $sam -Result 'OK' -Detail "Group=$groupName"
                        $ok++
                    } catch {
                        & $writeOpLogFn2 -Context $capturedDirContext -Action 'REMOVE-GROUP-MEMBER' `
                            -Target $sam -Result 'FAIL' -Detail "Group=$groupName : $($_.Exception.Message)"
                        $failMsg += "${sam} / ${groupName}: $($_.Exception.Message)`n"; $fail++
                    }
                }
            }
            if ($fail -gt 0) {
                [System.Windows.Forms.MessageBox]::Show("Removed: $ok  |  Failed: $fail`n$failMsg",'Remove from Group','OK','Warning')
            }

            # -- Admin tracking mail (To admin, no CC) - one summary per op --
            # Popup pre-addressed to the admin for documentation/tracking.
            # Fires only when at least one membership was removed. Non-fatal.
            if ($ok -gt 0 -and $showMailDlgFn2g) {
                $usersCsv  = $sams  -join ', '
                $groupsCsv = $names -join ', '
                $details = [ordered]@{
                    'Removed'   = "$ok membership(s)"
                    'Admin'     = if ($capturedDirContext -and $capturedDirContext.AdminAccount) { $capturedDirContext.AdminAccount } else { "$env:USERDOMAIN\$env:USERNAME" }
                    'Domain'    = if ($capturedDirContext -and $capturedDirContext.Domain)       { $capturedDirContext.Domain }       else { $env:USERDNSDOMAIN }
                    'Timestamp' = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
                }
                $bodyText = "The following account(s) were removed from the following group(s):" + "`r`n`r`n" +
                            "Account(s): $usersCsv" + "`r`n" +
                            "Group(s): $groupsCsv"
                & $showMailDlgFn2g `
                    -Context     $capturedDirContext `
                    -Sam         '' `
                    -ActionTitle 'Group Membership Removed' `
                    -Subject     "AD Group Removal: $usersCsv" `
                    -Details     $details `
                    -BodyText    $bodyText `
                    -AdminOnly
            }

            if ($sams.Count -eq 1 -and $readSelUserGrpFn) {
                & $readSelUserGrpFn -Sam $sams[0]
            }
        }).GetNewClosure())
        [void]$menu.Items.Add($miRemoveUser)
    }

    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

    # Delete Group(s) - permanent. Recovery snapshot + admin tracking mail
    # are handled entirely inside Invoke-DeleteGroups
    # (ADDirectory.Context.DeleteGroup), same shape as Delete User(s) /
    # Delete Computer(s). This is the quick single/multi right-click action,
    # distinct from the standalone Batch Delete Groups dialog
    # (ADDirectory.Groups.BatchDelete) - see that module's own header.
    $miDeleteGroup      = New-Object System.Windows.Forms.ToolStripMenuItem
    $miDeleteGroup.Text = 'Delete Group(s)...'
    $miDeleteGroup.Add_Click(({
        $targets = @(& $TargetProvider)
        if ($targets.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show('Select at least one group.','Delete Group(s)','OK','Information'); return
        }
        $names = @($targets | ForEach-Object { $_.Name } | Where-Object { $_ })
        if ($invDeleteGroupFn) {
            & $invDeleteGroupFn -Names $names -Context $capturedDirContext
        } else {
            [System.Windows.Forms.MessageBox]::Show('Delete Group module not loaded.','Delete Group(s)','OK','Warning')
        }
    }).GetNewClosure())
    [void]$menu.Items.Add($miDeleteGroup)
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

    $miCopy          = New-Object System.Windows.Forms.ToolStripMenuItem
    $miCopy.Text     = 'Copy Group Name(s)'
    $invSetStatusGrp = ${function:Invoke-SetStatus}
    $miCopy.Add_Click(({
        $targets = @(& $TargetProvider)
        $names   = @($targets | ForEach-Object { $_.Name } | Where-Object { $_ })
        if ($names.Count -gt 0) {
            [System.Windows.Forms.Clipboard]::SetText($names -join "`r`n")
            & $invSetStatusGrp "Copied $($names.Count) group name(s) to clipboard." 'ok'
        }
    }).GetNewClosure())
    [void]$menu.Items.Add($miCopy)

    return $menu
}
#endregion

#region -- New-ComputerContextMenu --------------------------------------------
function New-ComputerContextMenu {
    <#
    .SYNOPSIS
        Builds a computer right-click menu. -TargetProvider returns @({Name}).
        GetNewClosure captures the provider.
    .NOTES
        Changes: Re-added 'Test Connectivity' (single-target only) as the
        first item - the Computers grid no longer auto-runs the check on
        selection (that update-on-incidental-click behavior was reverted),
        so a deliberate menu trigger is needed again. Calls Set-
        SelectedComputer then Invoke-ComputerCheck, same as the original
        implementation before the brief auto-check experiment.
        Bug fix: the first version of this item resolved Invoke-
        ComputerCheck and Set-SelectedComputer via bare-name Get-Command /
        direct call from inside the .GetNewClosure() block, which silently
        failed ("Computers module not loaded.") even though both functions
        were loaded and working elsewhere - same closure-scope resolution
        bug already documented and worked around for Confirm-Action /
        Write-OperationLog / Show-DisableAccountDialog etc. earlier in this
        file. Fixed the same way: captured via ${function:Name} outside the
        closure, invoked with & inside it.
        Added 'BitLocker Recovery Key...' and 'LAPS Password...' (single-
        target only, same guard pattern) which open the new popup dialogs
        (ADComputers.BitLocker.Dialog / ADComputers.LAPS.Dialog) - these
        replace the removed BitLocker and LAPS sub-tabs.
        Added 'Show Sessions...' (single-target only, same guard pattern,
        placed directly below LAPS Password) which opens Show-
        ComputerSessionsDialog (ADComputers.Sessions.Dialog) - lists every
        active quser session on the selected computer, with its own
        multi-select "Force Logoff Selected Session(s)" right-click action
        inside that dialog. Captured via ${function:Show-
        ComputerSessionsDialog} outside the closure, same workaround as
        Show-BitLockerDialog / Show-LAPSDialog above.
        Added 'Restart Now' / 'Timed Restart...' / 'Open C$ Admin Share' as
        a new group, placed directly below Show Sessions and above the
        Delete Computer(s) separator - keeps the destructive Delete item
        isolated with its own separator on both sides as before. All three
        support multi-select (unlike BitLocker/LAPS/Sessions above), same as
        every other item on this menu besides those three single-target
        dialogs. Restart Now calls Invoke-RemoteRestart
        (ADComputers.Restart.Engine) directly after one Confirm-Action for
        the whole batch - immediate, forced, no admin-tracking mail (not
        requested for this item). Timed Restart... opens Show-
        TimedRestartDialog (ADComputers.Restart.Dialog), which owns its own
        confirmation, delay/message input, and admin-tracking mail. Open C$
        Admin Share loops every selected target and opens \\<name>\c$ in
        Explorer (Start-Process explorer.exe), same per-target try/catch
        loop shape as RDP/Radmin above - read-only browsing action, no
        confirm, no log entry, matching those. Restart Now / Timed Restart
        both captured via ${function:} outside the closure, same workaround
        as BitLocker/LAPS/Sessions above (Invoke-RemoteRestart and Show-
        TimedRestartDialog are dot-sourced, unreachable by bare name from
        inside .GetNewClosure() blocks). Restart Now also opens an admin-
        tracking mail (Show-NotificationMailDialog -AdminOnly) after a
        successful batch, same shape as Delete Computer(s) below - captured
        as $showMailDlgFnComp (this function's own scope; the $showMailDlgFn
        captured in New-UserContextMenu is a different function's local
        variable and not visible here).
        BUG FIX: the first version of Restart Now called Confirm-Action bare
        from inside its own .GetNewClosure() block - same bug class as
        above, but Confirm-Action's failure mode is a hard
        CommandNotFoundException rather than a silent no-op (unlike a bare
        call that simply returns nothing), so it surfaced as a visible
        "term not recognized" error and aborted the handler before Invoke-
        RemoteRestart was ever reached. Fixed the same way: captured via
        ${function:Confirm-Action} outside the closure (as
        $confirmActionCompFn), invoked with & inside it.
    #>
    param([scriptblock]$TargetProvider, [PSCustomObject]$Context)
    $menu             = New-Object System.Windows.Forms.ContextMenuStrip
    $menu.Font        = New-Object System.Drawing.Font('Segoe UI', 9)
    $invSetStatusComp = ${function:Invoke-SetStatus}
    $invComputerCheck = ${function:Invoke-ComputerCheck}
    $setSelectedComp  = ${function:Set-SelectedComputer}
    $showBitLockerFn  = ${function:Show-BitLockerDialog}
    $showLAPSFn       = ${function:Show-LAPSDialog}
    $showSessionsFn   = ${function:Show-ComputerSessionsDialog}
    $invRestartNowFn  = ${function:Invoke-RemoteRestart}
    $showTimedRstFn   = ${function:Show-TimedRestartDialog}
    $confirmActionCompFn = ${function:Confirm-Action}
    $showMailDlgFnComp   = ${function:Show-NotificationMailDialog}
    $invDeleteCompFn  = ${function:Invoke-DeleteComputers}
    # Context threaded in from the caller (see param) - same fix as New-
    # UserContextMenu/New-GroupContextMenu above. Previously this function
    # took no Context at all, and the Delete Computer(s) handler fell back
    # to $script:DirContext, which is this module's OWN private script
    # scope (never populated here - see the capturedDirContext comment in
    # New-UserContextMenu) - so Invoke-DeleteComputers always ran with a
    # $null Context, and its admin tracking mail had no AdminAccount to
    # resolve a "To" address from. Capture the real Context so the mail
    # actually reaches the admin.
    $capturedCompContext = $Context

    $miTest      = New-Object System.Windows.Forms.ToolStripMenuItem
    $miTest.Text = 'Test Connectivity'
    $miTest.Add_Click(({
        $targets = @(& $TargetProvider)
        if ($targets.Count -ne 1) {
            [System.Windows.Forms.MessageBox]::Show('Select exactly one computer.','Test Connectivity','OK','Information'); return
        }
        $name = $targets[0].Name
        if ($setSelectedComp) {
            & $setSelectedComp -Comp ([PSCustomObject]@{ Name=$name })
        }
        if ($invComputerCheck) {
            & $invComputerCheck -Target $name
        } else { & $invSetStatusComp 'Computers module not loaded.' 'warn' }
    }).GetNewClosure())
    [void]$menu.Items.Add($miTest)
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

    $miRDP      = New-Object System.Windows.Forms.ToolStripMenuItem
    $miRDP.Text = 'RDP'
    $miRDP.Add_Click(({
        foreach ($t in @(& $TargetProvider)) {
            try { Start-Process mstsc.exe "/v:$($t.Name)" } catch { & $invSetStatusComp "RDP failed for $($t.Name)." 'err' }
        }
    }).GetNewClosure())
    [void]$menu.Items.Add($miRDP)

    $miRadmin      = New-Object System.Windows.Forms.ToolStripMenuItem
    $miRadmin.Text = 'Radmin'
    $miRadmin.Add_Click(({
        $RADMIN_PORT = 4899   # default Radmin Server listen port
        $paths = @(
            'C:\Program Files (x86)\Radmin Viewer 3\Radmin.exe',
            'C:\Program Files\Radmin Viewer 3\Radmin.exe',
            'C:\Program Files\Radmin\Radmin.exe'
        )
        $exe = $paths | Where-Object { Test-Path $_ } | Select-Object -First 1
        if (-not $exe) { & $invSetStatusComp 'Radmin Viewer not found at standard paths.' 'warn'; return }
        foreach ($t in @(& $TargetProvider)) {
            # Radmin's /connect: switch takes ONE combined HOST:PORT token -
            # there is no separate /port: switch. The prior "/connect:HOST
            # /port:4899" form was invalid syntax and silently failed to
            # connect.
            try { Start-Process $exe "/connect:$($t.Name):$RADMIN_PORT" } catch { & $invSetStatusComp "Radmin failed for $($t.Name)." 'err' }
        }
    }).GetNewClosure())
    [void]$menu.Items.Add($miRadmin)

    $miPing      = New-Object System.Windows.Forms.ToolStripMenuItem
    $miPing.Text = 'Ping (continuous)'
    $miPing.Add_Click(({
        foreach ($t in @(& $TargetProvider)) {
            try { Start-Process cmd.exe "/k ping -t $($t.Name)" } catch { }
        }
    }).GetNewClosure())
    [void]$menu.Items.Add($miPing)

    $miMMC      = New-Object System.Windows.Forms.ToolStripMenuItem
    $miMMC.Text = 'Computer Management (MMC)'
    $miMMC.Add_Click(({
        foreach ($t in @(& $TargetProvider)) {
            try { Start-Process compmgmt.msc "/computer:$($t.Name)" } catch { & $invSetStatusComp "MMC failed for $($t.Name)." 'err' }
        }
    }).GetNewClosure())
    [void]$menu.Items.Add($miMMC)
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

    $miBitLocker      = New-Object System.Windows.Forms.ToolStripMenuItem
    $miBitLocker.Text = 'BitLocker Recovery Key...'
    $miBitLocker.Add_Click(({
        $targets = @(& $TargetProvider)
        if ($targets.Count -ne 1) {
            [System.Windows.Forms.MessageBox]::Show('Select exactly one computer.','BitLocker Recovery Key','OK','Information'); return
        }
        if ($showBitLockerFn) {
            & $showBitLockerFn -ComputerName $targets[0].Name
        } else { & $invSetStatusComp 'BitLocker dialog module not loaded.' 'warn' }
    }).GetNewClosure())
    [void]$menu.Items.Add($miBitLocker)

    $miLAPS      = New-Object System.Windows.Forms.ToolStripMenuItem
    $miLAPS.Text = 'LAPS Password...'
    $miLAPS.Add_Click(({
        $targets = @(& $TargetProvider)
        if ($targets.Count -ne 1) {
            [System.Windows.Forms.MessageBox]::Show('Select exactly one computer.','LAPS Password','OK','Information'); return
        }
        if ($showLAPSFn) {
            & $showLAPSFn -ComputerName $targets[0].Name
        } else { & $invSetStatusComp 'LAPS dialog module not loaded.' 'warn' }
    }).GetNewClosure())
    [void]$menu.Items.Add($miLAPS)

    $miSessions      = New-Object System.Windows.Forms.ToolStripMenuItem
    $miSessions.Text = 'Show Sessions...'
    $miSessions.Add_Click(({
        $targets = @(& $TargetProvider)
        if ($targets.Count -ne 1) {
            [System.Windows.Forms.MessageBox]::Show('Select exactly one computer.','Show Sessions','OK','Information'); return
        }
        if ($showSessionsFn) {
            & $showSessionsFn -ComputerName $targets[0].Name
        } else { & $invSetStatusComp 'Sessions dialog module not loaded.' 'warn' }
    }).GetNewClosure())
    [void]$menu.Items.Add($miSessions)
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

    $miRestartNow      = New-Object System.Windows.Forms.ToolStripMenuItem
    $miRestartNow.Text = 'Restart Now'
    $miRestartNow.Add_Click(({
        $targets = @(& $TargetProvider)
        if ($targets.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show('Select at least one computer.','Restart Now','OK','Information'); return
        }
        $names = @($targets | ForEach-Object { $_.Name } | Where-Object { $_ })
        $preview = ($names | Select-Object -First 15) -join ', '
        if ($names.Count -gt 15) { $preview += ", ... ($($names.Count) total)" }
        $msg = "Immediately restart $($names.Count) computer(s)?`n`n$preview`n`nAny unsaved work on these computers will be lost."
        if (-not (& $confirmActionCompFn -Title 'Restart Now' -Message $msg -ActionLabel 'Restart')) { return }
        if (-not $invRestartNowFn) {
            & $invSetStatusComp 'Restart engine module not loaded.' 'warn'; return
        }
        $result = & $invRestartNowFn -Names $names -Context $capturedCompContext
        if (-not $result) { return }
        $level = if ($result.FailCount -eq 0) { 'ok' } else { 'warn' }
        & $invSetStatusComp "Restart Now: $($result.OkCount) initiated, $($result.FailCount) failed." $level
        if ($result.FailCount -gt 0) {
            $failMsg = ($result.Results | Where-Object { -not $_.Success } | ForEach-Object { "$($_.Name): $($_.Message)" }) -join "`n"
            [System.Windows.Forms.MessageBox]::Show("Restart Now complete.`n`nInitiated: $($result.OkCount)`nFailed: $($result.FailCount)`n`n$failMsg",'Restart Now','OK','Warning')
        }

        # -- Admin tracking mail (To admin, no CC) - one summary per batch ------
        if ($result.OkCount -gt 0 -and $showMailDlgFnComp) {
            $restartedOk = @($result.Results | Where-Object { $_.Success } | ForEach-Object { $_.Name })
            $details = [ordered]@{
                'Admin'     = if ($capturedCompContext -and $capturedCompContext.AdminAccount) { $capturedCompContext.AdminAccount } else { "$env:USERDOMAIN\$env:USERNAME" }
                'Domain'    = if ($capturedCompContext -and $capturedCompContext.Domain)       { $capturedCompContext.Domain }       else { $env:USERDNSDOMAIN }
                'Timestamp' = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
            }
            $bodyText = "An immediate restart was initiated on the following computer(s):" + "`r`n`r`n" +
                        (($restartedOk | ForEach-Object { "- " + $_ }) -join "`r`n") + "`r`n`r`n" +
                        "Batch result: $($result.OkCount) initiated, $($result.FailCount) failed."

            & $showMailDlgFnComp `
                -Context     $capturedCompContext `
                -Sam         '' `
                -ActionTitle 'Computer(s) Restarted' `
                -Subject     "AD Restart Now: $($result.OkCount) initiated, $($result.FailCount) failed" `
                -Details     $details `
                -BodyText    $bodyText `
                -AdminOnly
        }
    }).GetNewClosure())
    [void]$menu.Items.Add($miRestartNow)

    $miTimedRestart      = New-Object System.Windows.Forms.ToolStripMenuItem
    $miTimedRestart.Text = 'Timed Restart...'
    $miTimedRestart.Add_Click(({
        $targets = @(& $TargetProvider)
        if ($targets.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show('Select at least one computer.','Timed Restart','OK','Information'); return
        }
        $names = @($targets | ForEach-Object { $_.Name } | Where-Object { $_ })
        if ($showTimedRstFn) {
            & $showTimedRstFn -ComputerNames $names -Context $capturedCompContext
        } else {
            & $invSetStatusComp 'Timed Restart dialog module not loaded.' 'warn'
        }
    }).GetNewClosure())
    [void]$menu.Items.Add($miTimedRestart)

    $miOpenShare      = New-Object System.Windows.Forms.ToolStripMenuItem
    $miOpenShare.Text = 'Open C$ Admin Share'
    $miOpenShare.Add_Click(({
        foreach ($t in @(& $TargetProvider)) {
            try { Start-Process explorer.exe "\\$($t.Name)\c$" } catch { & $invSetStatusComp "Failed to open C$ share for $($t.Name)." 'err' }
        }
    }).GetNewClosure())
    [void]$menu.Items.Add($miOpenShare)
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

    $miDeleteComp      = New-Object System.Windows.Forms.ToolStripMenuItem
    $miDeleteComp.Text = 'Delete Computer(s)...'
    $miDeleteComp.Add_Click(({
        $targets = @(& $TargetProvider)
        if ($targets.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show('Select at least one computer.','Delete Computer(s)','OK','Information'); return
        }
        $names = @($targets | ForEach-Object { $_.Name } | Where-Object { $_ })
        if ($invDeleteCompFn) {
            & $invDeleteCompFn -Names $names -Context $capturedCompContext
        } else {
            & $invSetStatusComp 'Delete Computer module not loaded.' 'warn'
        }
    }).GetNewClosure())
    [void]$menu.Items.Add($miDeleteComp)
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

    $miCopy      = New-Object System.Windows.Forms.ToolStripMenuItem
    $miCopy.Text = 'Copy Computer Name(s)'
    $miCopy.Add_Click(({
        $names = @(@(& $TargetProvider) | ForEach-Object { $_.Name } | Where-Object { $_ })
        if ($names.Count -gt 0) {
            [System.Windows.Forms.Clipboard]::SetText($names -join "`r`n")
            & $invSetStatusComp "Copied $($names.Count) computer name(s) to clipboard." 'ok'
        }
    }).GetNewClosure())
    [void]$menu.Items.Add($miCopy)

    return $menu
}
#endregion

Export-ModuleMember -Function `
    New-UserContextMenu, `
    New-GroupContextMenu, `
    New-ComputerContextMenu
