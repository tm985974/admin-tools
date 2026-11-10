#region -- ADDirectory.Context.UserGroups.psm1 --------------------------------
# Concern : Show-EditUserGroupsDialog - modal form for adding a single user
#           to one or more groups. Mirrors Show-GroupMembersDialog's
#           inverse: one user, many groups, instead of one group, many users.
#           Left list (read-only) = the user's current group memberships.
#           Right list (multiselect) = groups available to add, sourced from
#           one of three modes: All Groups (default, whole domain, no OU
#           scoping), Filtered (text box), or a second "duplicate user"'s
#           group memberships (for copying another user's group set).
#           Groups the target user already belongs to are highlighted in
#           the right list (still selectable; a pre-flight membership check
#           filters them out before Add runs).
#           No bulk paste/multi-line text path - multiselect + Add covers it.
# Load order: 24 - depends on ADDirectory.Context.Common (script scope),
#                            Services.AD.Reporting (Confirm-Action, Write-OperationLog,
#                                                   New-StdGrid, Set-GridData,
#                                                   New-StdButton),
#                            Services.AD.Connection.Query (Get-DomainUsers,
#                                                          Get-DomainGroups),
#                            Services.Mail.Dialog (Show-NotificationMailDialog) [4c]
# Split from: ADDirectory.Menus.psm1
# Changes   : Add Selected to Group(s): Show-NotificationMailDialog called
#             per user after at least one group add succeeds (non-fatal,
#             guarded with Get-Command).
#             Pre-flight membership guard added to Add Selected to Group(s),
#             matching the Unlock/Enable/Disable account-action pattern. The
#             selected groups are partitioned against the user's current
#             memberships ($currentGroupSet) BEFORE prompting. If every
#             selected group is already a membership, an information box says
#             so ("already a member of '<group>'" for one, or "already a
#             member of all N selected groups") and nothing happens. If the
#             selection is mixed, a warning box lists the already-member
#             group(s) that will be ignored and the operator confirms before
#             continuing with only the actionable set. The action loop no
#             longer needs its own in-loop already-member skip.
#             Admin tracking mail added to Remove from Group(s): opens
#             Show-NotificationMailDialog -AdminOnly (To = admin, no CC) with a
#             one-per-operation summary of the removed membership(s). Fires
#             only when at least one membership was removed. Non-fatal.
# v1.6.0    : Notification email trimmed to basic information: Action / DC /
#             rows repeated in the message text and the "administrative tracking
#             only" line removed. Add-to-groups email to the person: Account
#             only (admin still CC'd).
#endregion

#region -- Show-EditUserGroupsDialog -------------------------------------------
function Show-EditUserGroupsDialog {
    <#
    .SYNOPSIS
        Edit Groups dialog for a single user. $loadCurrentGroups and
        $applyRightListMode are defined before any handler that references
        them so closures capture them correctly via GetNewClosure().
    #>
    param([string]$Sam, [string]$DisplayName, [PSCustomObject]$Context)

    $F_UI    = New-Object System.Drawing.Font('Segoe UI', 9)
    $F_UI_B  = New-Object System.Drawing.Font('Segoe UI', 9,  [System.Drawing.FontStyle]::Bold)
    $F_13B   = New-Object System.Drawing.Font('Segoe UI', 13, [System.Drawing.FontStyle]::Bold)
    $F_SMALL = New-Object System.Drawing.Font('Segoe UI', 8)

    $C_BLUE   = [System.Drawing.Color]::FromArgb(0, 99, 177)
    $C_BG     = [System.Drawing.Color]::FromArgb(235,238,242)
    $C_SEP    = [System.Drawing.Color]::FromArgb(180,195,220)
    $C_DIM    = [System.Drawing.Color]::DimGray
    $C_OK     = [System.Drawing.Color]::FromArgb(0, 97, 0)
    $C_ERR    = [System.Drawing.Color]::FromArgb(156, 0, 6)
    $C_MEMBER = [System.Drawing.Color]::FromArgb(255,235,156)

    $currentGroupSet = New-Object System.Collections.Generic.HashSet[string]
    $dupUserMap      = @{}
    $allGroupsCache  = [System.Collections.Generic.List[PSCustomObject]]::new()

    $dispLabel = if ($DisplayName) { "$DisplayName ($Sam)" } else { $Sam }

    $dlg                 = New-Object System.Windows.Forms.Form
    $dlg.Text            = "Edit Groups  --  $dispLabel"
    $dlg.ClientSize      = New-Object System.Drawing.Size(940, 560)
    $dlg.FormBorderStyle = 'FixedSingle'
    $dlg.MaximizeBox     = $false
    $dlg.StartPosition   = 'CenterParent'
    $dlg.BackColor       = $C_BG
    $dlg.Font            = $F_UI

    $pTitle              = New-Object System.Windows.Forms.Panel
    $pTitle.Location     = New-Object System.Drawing.Point(0, 0)
    $pTitle.Size         = New-Object System.Drawing.Size(940, 46)
    $pTitle.BackColor    = $C_BLUE
    $dlg.Controls.Add($pTitle)

    $lTitle              = New-Object System.Windows.Forms.Label
    $lTitle.Text         = "   Edit Groups  --  $dispLabel"
    $lTitle.Location     = New-Object System.Drawing.Point(0, 0)
    $lTitle.Size         = New-Object System.Drawing.Size(940, 46)
    $lTitle.Font         = $F_13B
    $lTitle.ForeColor    = [System.Drawing.Color]::White
    $lTitle.TextAlign    = 'MiddleLeft'
    $pTitle.Controls.Add($lTitle)

    $lStatus             = New-Object System.Windows.Forms.Label
    $lStatus.Location    = New-Object System.Drawing.Point(12, 54)
    $lStatus.Size        = New-Object System.Drawing.Size(916, 18)
    $lStatus.Font        = $F_UI
    $lStatus.ForeColor   = $C_DIM
    $lStatus.Text        = 'Loading...'
    $dlg.Controls.Add($lStatus)

    # -------------------------------------------------------------------------
    # Left column: current groups (read-only)
    # -------------------------------------------------------------------------
    $LCOL_X = 12
    $LCOL_W = 380

    $lCurCap           = New-Object System.Windows.Forms.Label
    $lCurCap.Text      = 'Current Groups'
    $lCurCap.Location  = New-Object System.Drawing.Point($LCOL_X, 78)
    $lCurCap.Size      = New-Object System.Drawing.Size($LCOL_W, 20)
    $lCurCap.Font      = $F_UI_B
    $dlg.Controls.Add($lCurCap)

    $gridCurrent                = New-StdGrid -X $LCOL_X -Y 100 -W $LCOL_W -H 390 -Parent $dlg
    $gridCurrent.MultiSelect    = $true
    $gridCurrent.SelectionMode  = 'FullRowSelect'

    $lCurHint            = New-Object System.Windows.Forms.Label
    $lCurHint.Text       = 'Right-click to remove from group(s)  |  Shift/Ctrl+Click for multi-select'
    $lCurHint.Location   = New-Object System.Drawing.Point($LCOL_X, 492)
    $lCurHint.Size       = New-Object System.Drawing.Size($LCOL_W, 16)
    $lCurHint.Font       = $F_SMALL
    $lCurHint.ForeColor  = $C_DIM
    $dlg.Controls.Add($lCurHint)

    # -------------------------------------------------------------------------
    # Right column: groups to add (multiselect, mode-driven)
    # -------------------------------------------------------------------------
    $RCOL_X = $LCOL_X + $LCOL_W + 16
    $RCOL_W = 940 - $RCOL_X - 12

    $lAddCap           = New-Object System.Windows.Forms.Label
    $lAddCap.Text      = 'Add to Groups'
    $lAddCap.Location  = New-Object System.Drawing.Point($RCOL_X, 78)
    $lAddCap.Size      = New-Object System.Drawing.Size(200, 20)
    $lAddCap.Font      = $F_UI_B
    $dlg.Controls.Add($lAddCap)

    $lModeCap          = New-Object System.Windows.Forms.Label
    $lModeCap.Text     = 'View:'
    $lModeCap.Location = New-Object System.Drawing.Point($RCOL_X, 100)
    $lModeCap.Size     = New-Object System.Drawing.Size(38, 24)
    $lModeCap.TextAlign = 'MiddleLeft'
    $lModeCap.Font     = $F_UI
    $dlg.Controls.Add($lModeCap)

    $cmbMode = New-Object System.Windows.Forms.ComboBox
    $cmbMode.Location = New-Object System.Drawing.Point(($RCOL_X+40), 98)
    $cmbMode.Size     = New-Object System.Drawing.Size(180, 24)
    $cmbMode.DropDownStyle = 'DropDownList'
    $cmbMode.Font     = $F_UI
    @('All Groups', 'Filtered', 'Duplicate User''s Groups') |
        ForEach-Object { [void]$cmbMode.Items.Add($_) }
    $cmbMode.SelectedIndex = 0
    $dlg.Controls.Add($cmbMode)

    $tbFilter             = New-Object System.Windows.Forms.TextBox
    $tbFilter.Location    = New-Object System.Drawing.Point(($RCOL_X+228), 98)
    $tbFilter.Size        = New-Object System.Drawing.Size(($RCOL_W-228), 24)
    $tbFilter.Font        = $F_UI
    $tbFilter.Enabled     = $false
    $dlg.Controls.Add($tbFilter)

    $lDupCap            = New-Object System.Windows.Forms.Label
    $lDupCap.Text       = 'Duplicate from user:'
    $lDupCap.Location   = New-Object System.Drawing.Point($RCOL_X, 130)
    $lDupCap.Size       = New-Object System.Drawing.Size(130, 24)
    $lDupCap.TextAlign  = 'MiddleLeft'
    $lDupCap.Font       = $F_UI
    $dlg.Controls.Add($lDupCap)

    $cmbDupUser                    = New-Object System.Windows.Forms.ComboBox
    $cmbDupUser.Location           = New-Object System.Drawing.Point(($RCOL_X+134), 128)
    $cmbDupUser.Size               = New-Object System.Drawing.Size(($RCOL_W-134), 24)
    $cmbDupUser.DropDownStyle      = 'DropDown'
    $cmbDupUser.Font               = $F_UI
    $cmbDupUser.AutoCompleteMode   = [System.Windows.Forms.AutoCompleteMode]::SuggestAppend
    $cmbDupUser.AutoCompleteSource = [System.Windows.Forms.AutoCompleteSource]::ListItems
    $dlg.Controls.Add($cmbDupUser)

    $gridAdd             = New-StdGrid -X $RCOL_X -Y 160 -W $RCOL_W -H 350 -Parent $dlg
    $gridAdd.MultiSelect = $true
    $gridAdd.SelectionMode = 'FullRowSelect'

    $btnAdd              = New-Object System.Windows.Forms.Button
    $btnAdd.Text         = 'Add Selected to Group(s)'
    $btnAdd.Location     = New-Object System.Drawing.Point($RCOL_X, 516)
    $btnAdd.Size         = New-Object System.Drawing.Size(220, 30)
    $btnAdd.FlatStyle    = 'Standard'
    $btnAdd.Font         = $F_UI_B
    $dlg.Controls.Add($btnAdd)

    $btnClose            = New-Object System.Windows.Forms.Button
    $btnClose.Text       = 'Close'
    $btnClose.Location   = New-Object System.Drawing.Point(($RCOL_X+$RCOL_W-96), 516)
    $btnClose.Size       = New-Object System.Drawing.Size(96, 30)
    $btnClose.FlatStyle  = 'Standard'
    $btnClose.Font       = $F_UI
    $dlg.Controls.Add($btnClose)
    $btnClose.Add_Click({ $dlg.Close() })

    # -------------------------------------------------------------------------
    # $loadCurrentGroups: populates the left list and $currentGroupSet, the
    # latter used by $applyRightListMode for highlighting.
    # -------------------------------------------------------------------------
    $loadCurrentGroups = {
        $currentGroupSet.Clear()
        $srvParam = if ($Context.TargetDC) { @{ Server = $Context.TargetDC } } else { @{} }
        try {
            $memberOf = Get-ADPrincipalGroupMembership -Identity $Sam @srvParam -ErrorAction Stop |
                        Sort-Object Name
            $data = @($memberOf | ForEach-Object {
                [void]$currentGroupSet.Add(([string]$_.Name).ToLower())
                [PSCustomObject]@{
                    Name  = [string]$_.Name
                    Type  = [string]$_.GroupCategory
                    Scope = [string]$_.GroupScope
                }
            })
            Set-GridData -Grid $gridCurrent -Data $data -Columns @('Name','Type','Scope')
        } catch {
            $lStatus.ForeColor = $C_ERR
            $lStatus.Text      = "Could not load current groups: $($_.Exception.Message)"
        }
    }

    # -------------------------------------------------------------------------
    # $highlightAddGrid: marks rows in the right list whose Name is already
    # in $currentGroupSet.
    # -------------------------------------------------------------------------
    $highlightAddGrid = {
        foreach ($row in $gridAdd.Rows) {
            $n = [string]$row.Cells['Name'].Value
            if ($n -and $currentGroupSet.Contains($n.ToLower())) {
                $row.DefaultCellStyle.BackColor = $C_MEMBER
            }
        }
    }

    # -------------------------------------------------------------------------
    # $applyRightListMode: pushes the right list's data based on $cmbMode's
    # current selection. 'All Groups' and 'Filtered' both source from
    # $allGroupsCache (loaded once on dialog Shown); 'Filtered' additionally
    # applies $tbFilter.Text. 'Duplicate User''s Groups' sources from
    # whichever user is selected in $cmbDupUser.
    # -------------------------------------------------------------------------
    $applyRightListMode = {
        $mode = [string]$cmbMode.SelectedItem
        if ($mode -eq "Duplicate User's Groups") {
            $dupTxt = $cmbDupUser.Text.Trim()
            $dupSam = if ($dupUserMap.ContainsKey($dupTxt)) { $dupUserMap[$dupTxt] } else { '' }
            if (-not $dupSam) {
                Set-GridData -Grid $gridAdd -Data @() -Columns @('Name','Type','Scope')
                return
            }
            $srvParam = if ($Context.TargetDC) { @{ Server = $Context.TargetDC } } else { @{} }
            try {
                $dupGroups = Get-ADPrincipalGroupMembership -Identity $dupSam @srvParam -ErrorAction Stop |
                             Sort-Object Name
                $data = @($dupGroups | ForEach-Object {
                    [PSCustomObject]@{ Name=[string]$_.Name; Type=[string]$_.GroupCategory; Scope=[string]$_.GroupScope }
                })
                Set-GridData -Grid $gridAdd -Data $data -Columns @('Name','Type','Scope')
            } catch {
                Set-GridData -Grid $gridAdd -Data @() -Columns @('Name','Type','Scope')
                $lStatus.ForeColor = $C_ERR
                $lStatus.Text      = "Could not load groups for $dupSam : $($_.Exception.Message)"
            }
        } else {
            $text = if ($mode -eq 'Filtered') { $tbFilter.Text.Trim().ToLower() } else { '' }
            $data = if ($text) {
                @($allGroupsCache | Where-Object { $_.Name.ToLower() -like "*$text*" })
            } else {
                @($allGroupsCache)
            }
            Set-GridData -Grid $gridAdd -Data $data -Columns @('Name','Type','Scope')
        }
        & $highlightAddGrid
    }

    # -------------------------------------------------------------------------
    # Right-click context menu for $gridCurrent: Remove from Group(s).
    # Function refs captured before GetNewClosure() - same pattern used
    # throughout this codebase for cross-file script-scope functions.
    # $loadCurrentGroups and $applyRightListMode are captured by reference
    # from the enclosing function scope (defined above this block).
    # -------------------------------------------------------------------------
    $confirmActionFnR  = ${function:Confirm-Action}
    $newAdCmdFnR       = ${function:New-ADCommandText}
    $adLiteralFnR      = ${function:ConvertTo-ADCodeLiteral}
    $writeOpLogFnR     = ${function:Write-OperationLog}
    $readSelUserGrpFnR = ${function:Read-SelectedUserGroups}
    $showMailDlgFnR    = ${function:Show-NotificationMailDialog}

    $ctxCurrent      = New-Object System.Windows.Forms.ContextMenuStrip
    $ctxCurrent.Font = New-Object System.Drawing.Font('Segoe UI', 9)

    $miRemove      = New-Object System.Windows.Forms.ToolStripMenuItem
    $miRemove.Text = 'Remove from Group(s)'
    $miRemove.Add_Click(({
        $names = @($gridCurrent.SelectedRows |
                   ForEach-Object { [string]$_.Cells['Name'].Value } |
                   Where-Object { $_ })
        if ($names.Count -eq 0) { return }
        $msg = if ($names.Count -eq 1) {
            "Remove '$Sam' from '$($names[0])'?"
        } else {
            "Remove '$Sam' from $($names.Count) group(s)?`n`n$($names -join ', ')"
        }
        $codeLines = @()
        foreach ($cg in $names) {
            $codeLines += (& $newAdCmdFnR -Cmdlet 'Remove-ADGroupMember' -Identity @($cg) -Context $Context -Tail ('-Members ' + (& $adLiteralFnR $Sam) + ' -Confirm:$false -ErrorAction Stop'))
        }
        if (-not (& $confirmActionFnR -Title 'Remove from Group' -Message $msg -ActionLabel 'Remove' -Code ($codeLines -join "`r`n"))) { return }
        $srvParam = if ($Context.TargetDC) { @{ Server = $Context.TargetDC } } else { @{} }
        $ok = 0; $fail = 0; $failMsg = ''
        $removedOk = [System.Collections.Generic.List[string]]::new()
        foreach ($groupName in $names) {
            try {
                Remove-ADGroupMember -Identity $groupName -Members $Sam @srvParam -Confirm:$false -ErrorAction Stop
                & $writeOpLogFnR -Context $Context -Action 'REMOVE-GROUP-MEMBER' `
                    -Target $Sam -Result 'OK' -Detail "Group=$groupName"
                [void]$removedOk.Add($groupName)
                $ok++
            } catch {
                & $writeOpLogFnR -Context $Context -Action 'REMOVE-GROUP-MEMBER' `
                    -Target $Sam -Result 'FAIL' -Detail "Group=$groupName : $($_.Exception.Message)"
                $failMsg += "${groupName}: $($_.Exception.Message)`n"
                $fail++
            }
        }
        & $loadCurrentGroups
        & $applyRightListMode
        $summary = "Removed: $ok"
        if ($fail -gt 0) { $summary += "  |  Failed: $fail" }
        $lStatus.ForeColor = if ($fail -gt 0) { $C_ERR } else { $C_OK }
        $lStatus.Text      = $summary
        if ($fail -gt 0) {
            [System.Windows.Forms.MessageBox]::Show($failMsg, 'Remove from Group - Failures', 'OK', 'Error')
        }

        # -- Admin tracking mail (To admin, no CC) - one summary per operation --
        # Popup pre-addressed to the admin for documentation/tracking. Fires
        # only when at least one membership was removed. Non-fatal.
        if ($ok -gt 0 -and $showMailDlgFnR) {
            $removedCsv = $removedOk -join ', '
            $dispLbl    = if ($DisplayName) { "$DisplayName ($Sam)" } else { $Sam }
            $details = [ordered]@{
                'Account'   = $dispLbl
                'Admin'     = if ($Context -and $Context.AdminAccount) { $Context.AdminAccount } else { "$env:USERDOMAIN\$env:USERNAME" }
                'Domain'    = if ($Context -and $Context.Domain)       { $Context.Domain }       else { $env:USERDNSDOMAIN }
                'Timestamp' = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
            }
            $bodyText = "'$dispLbl' was removed from the following group(s):" + "`r`n`r`n" +
                        (($removedOk | ForEach-Object { "- " + $_ }) -join "`r`n")
            & $showMailDlgFnR `
                -Context     $Context `
                -Sam         '' `
                -ActionTitle 'Group Membership Removed' `
                -Subject     "AD Group Removal: $dispLbl" `
                -Details     $details `
                -BodyText    $bodyText `
                -AdminOnly
        }

        if ($readSelUserGrpFnR) { & $readSelUserGrpFnR -Sam $Sam }
    }).GetNewClosure())
    [void]$ctxCurrent.Items.Add($miRemove)
    $gridCurrent.ContextMenuStrip = $ctxCurrent

    # -------------------------------------------------------------------------
    # Mode dropdown: enable/clear the filter box per mode, reload right list.
    # -------------------------------------------------------------------------
    $cmbMode.Add_SelectedIndexChanged(({
        $mode = [string]$cmbMode.SelectedItem
        if ($mode -eq 'Filtered') {
            $tbFilter.Enabled = $true
        } else {
            $tbFilter.Text    = ''
            $tbFilter.Enabled = $false
        }
        & $applyRightListMode
    }).GetNewClosure())

    $tbFilter.Add_TextChanged(({
        if ([string]$cmbMode.SelectedItem -eq 'Filtered') { & $applyRightListMode }
    }).GetNewClosure())

    # Lazy-load domain users for the duplicate-user combo. Populated on
    # Add_Enter (control receives focus), not Add_DropDown - this guarantees
    # .Items is fully populated before any popup can open, so nothing ever
    # mutates Items while the native dropdown window is alive. (An earlier
    # version mutated Items live during Add_DropDown, which intermittently
    # corrupted the ComboBox's native list and crashed with
    # AccessViolationException inside WndProc. A follow-up attempt to force
    # DroppedDown closed/reopen from inside Add_DropDown fought WinForms'
    # own open-state machine and made the dropdown appear to never populate.
    # Add_Enter avoids both problems entirely.)
    $dlgDomainDN      = $Context.DomainDN
    $dlgTargetDC      = $Context.TargetDC
    $getDomainUsersFn = ${function:Get-DomainUsers}
    # v1.2.20: a hashtable, so the flag survives between handler calls (the list
    # of every domain user was re-read each time the box got focus).
    $dupUsersLoaded   = @{ Done = $false }
    $cmbDupUser.Add_Enter(({
        if ($dupUsersLoaded.Done) { return }
        $dupUsersLoaded.Done = $true
        $srvParam = if ($dlgTargetDC) { @{ Server = $dlgTargetDC } } else { @{} }
        $items = [System.Collections.Generic.List[string]]::new()
        try {
            $domainUsers = & $getDomainUsersFn -SearchBase $dlgDomainDN -IncludeDisabled @srvParam |
                           Sort-Object { if ($_.DisplayName) { $_.DisplayName } else { $_.SamAccountName } }
            foreach ($u in $domainUsers) {
                $userSam = [string]$u.SamAccountName
                if (-not $userSam) { continue }
                $disp = if ($u.DisplayName) { "$($u.DisplayName) ($userSam)" } else { $userSam }
                [void]$items.Add($disp)
                $dupUserMap[$disp] = $userSam
            }
        } catch {
            $dupUsersLoaded.Done = $false
        }
        $cmbDupUser.BeginUpdate()
        try {
            foreach ($disp in $items) { [void]$cmbDupUser.Items.Add($disp) }
        } finally {
            $cmbDupUser.EndUpdate()
        }
    }).GetNewClosure())

    # Selecting a duplicate user auto-switches mode so the effect is visible.
    $cmbDupUser.Add_SelectedIndexChanged(({
        if ($cmbMode.SelectedItem -ne "Duplicate User's Groups") {
            $cmbMode.SelectedItem = "Duplicate User's Groups"
        } else {
            & $applyRightListMode
        }
    }).GetNewClosure())

    # -------------------------------------------------------------------------
    # Add Selected to Group(s)
    # Confirm-Action / Write-OperationLog / Read-SelectedUserGroups are
    # captured before GetNewClosure(), consistent with the fix applied
    # throughout this codebase for cross-file function calls inside
    # .GetNewClosure() blocks.
    # Show-NotificationMailDialog captured the same way; guarded with
    # if ($showMailDlgFn3) so the dialog degrades cleanly when absent.
    # Notification fires once per Add click (summary of all groups added
    # in that operation), only when at least one Add succeeded.
    # -------------------------------------------------------------------------
    $confirmActionFn3   = ${function:Confirm-Action}
    $newAdCmdFn3        = ${function:New-ADCommandText}
    $adLiteralFn3       = ${function:ConvertTo-ADCodeLiteral}
    $writeOpLogFn3      = ${function:Write-OperationLog}
    $readSelUserGrpFn2  = ${function:Read-SelectedUserGroups}
    $showMailDlgFn3     = ${function:Show-NotificationMailDialog}
    $capturedContext3   = $Context

    $btnAdd.Add_Click(({
        $names = @($gridAdd.SelectedRows | ForEach-Object { [string]$_.Cells['Name'].Value } | Where-Object { $_ })
        if ($names.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show('Select at least one group.','Add to Groups','OK','Information')
            return
        }

        # -- Pre-flight membership check --------------------------------------
        # Partition the selected groups into actionable (not yet a member) and
        # already-a-member BEFORE prompting, matching the Unlock/Enable/Disable
        # account-action guards. $currentGroupSet holds the user's current
        # memberships (lowercased), populated by $loadCurrentGroups.
        $actionable = [System.Collections.Generic.List[string]]::new()
        $alreadyMbr = [System.Collections.Generic.List[string]]::new()
        foreach ($groupName in $names) {
            if ($currentGroupSet.Contains($groupName.ToLower())) { [void]$alreadyMbr.Add($groupName) }
            else { [void]$actionable.Add($groupName) }
        }

        # Nothing actionable: every selected group is already a membership. Say
        # so and do nothing.
        if ($actionable.Count -eq 0) {
            $noneMsg = if ($alreadyMbr.Count -eq 1) {
                "'$Sam' is already a member of '$($alreadyMbr[0])'."
            } else {
                "'$Sam' is already a member of all $($alreadyMbr.Count) selected groups."
            }
            [System.Windows.Forms.MessageBox]::Show($noneMsg,'Add to Groups','OK','Information')
            return
        }

        # Mixed selection: warn which group(s) are ignored, then continue with
        # the actionable set.
        if ($alreadyMbr.Count -gt 0) {
            $warn = 'The following selected group(s) will be ignored:'
            $warn += "`n`nAlready a member ($($alreadyMbr.Count)):`n$($alreadyMbr -join ', ')"
            $warn += "`n`nContinue and add '$Sam' to the remaining $($actionable.Count) group(s)?"
            $go = [System.Windows.Forms.MessageBox]::Show($warn,'Add to Groups','YesNo','Warning')   # not-a-command: lists skipped items; the command window follows
            if ($go -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        }

        $addList = @($actionable)
        $msg = if ($addList.Count -eq 1) { "Add '$Sam' to '$($addList[0])'?" } `
               else { "Add '$Sam' to $($addList.Count) group(s)?`n`n$($addList -join ', ')" }
        $codeLines = @()
        foreach ($cg in $addList) {
            $codeLines += (& $newAdCmdFn3 -Cmdlet 'Add-ADGroupMember' -Identity @($cg) -Context $Context -Tail ('-Members ' + (& $adLiteralFn3 $Sam) + ' -ErrorAction Stop'))
        }
        if (-not (& $confirmActionFn3 -Title 'Add to Groups' -Message $msg -ActionLabel 'Add' -Code ($codeLines -join "`r`n"))) { return }
        $srvParam = if ($Context.TargetDC) { @{ Server = $Context.TargetDC } } else { @{} }
        $ok = 0; $fail = 0; $failMsg = ''
        $addedGroups = [System.Collections.Generic.List[string]]::new()
        foreach ($groupName in $addList) {
            try {
                Add-ADGroupMember -Identity $groupName -Members $Sam @srvParam -ErrorAction Stop
                & $writeOpLogFn3 -Context $Context -Action 'ADD-GROUP-MEMBER' `
                    -Target $Sam -Result 'OK' -Detail "Group=$groupName"
                [void]$addedGroups.Add($groupName)
                $ok++
            } catch {
                & $writeOpLogFn3 -Context $Context -Action 'ADD-GROUP-MEMBER' `
                    -Target $Sam -Result 'FAIL' -Detail "Group=$groupName : $($_.Exception.Message)"
                $failMsg += "${groupName}: $($_.Exception.Message)`n"; $fail++
            }
        }
        & $loadCurrentGroups
        & $applyRightListMode
        $summary = "Added: $ok"
        if ($alreadyMbr.Count -gt 0) { $summary += "  |  Ignored (already a member): $($alreadyMbr.Count)" }
        if ($fail -gt 0)    { $summary += "  |  Failed: $fail" }
        $lStatus.ForeColor = if ($fail -gt 0) { $C_ERR } else { $C_OK }
        $lStatus.Text = $summary
        if ($fail -gt 0) {
            [System.Windows.Forms.MessageBox]::Show($failMsg,'Add to Groups - Failures','OK','Error')
        }
        if ($readSelUserGrpFn2) { & $readSelUserGrpFn2 -Sam $Sam }

        # -- Mail notification: one popup summarising all groups added (non-fatal) --
        if ($ok -gt 0 -and $showMailDlgFn3) {
            $groupSummary = $addedGroups -join ', '
            # Each group on its own line for the body; the comma form is kept
            # for the compact detail-table row. Body line breaks are rendered
            # as <br> by the mail send function.
            $groupLines   = ($addedGroups | ForEach-Object { "- " + $_ }) -join "`r`n"
            $dispLabel2   = if ($DisplayName) { "$DisplayName ($Sam)" } else { $Sam }

            $details = [ordered]@{
                'Account'       = $dispLabel2
            }

            $bodyText = "The Active Directory account listed above has been added to the following group(s):" + "`r`n`r`n" +
                        $groupLines + "`r`n`r`n" +
                        "If you did not expect this change, please contact your IT administrator."

            & $showMailDlgFn3 `
                -Context     $capturedContext3 `
                -Sam         $Sam `
                -ActionTitle 'Group Membership Added' `
                -Subject     "AD Group Add: $dispLabel2" `
                -Details     $details `
                -BodyText    $bodyText
        }

    }).GetNewClosure())

    # -------------------------------------------------------------------------
    # Initial load: current groups, then the whole-domain cache for the
    # right list's default 'All Groups' view.
    # -------------------------------------------------------------------------
    $getDomainGroupsFn = ${function:Get-DomainGroups}
    $dlg.Add_Shown(({
        & $loadCurrentGroups
        $lStatus.Text = 'Loading domain groups...'
        $dlg.Refresh()
        $srvParam = if ($Context.TargetDC) { @{ Server = $Context.TargetDC } } else { @{} }
        try {
            $raw = & $getDomainGroupsFn @srvParam
            $allGroupsCache.Clear()
            foreach ($g in $raw) {
                [void]$allGroupsCache.Add([PSCustomObject]@{
                    Name  = [string]$g.Name
                    Type  = [string]$g.GroupCategory
                    Scope = [string]$g.GroupScope
                })
            }
            & $applyRightListMode
            $lStatus.ForeColor = $C_DIM
            $lStatus.Text      = "$($allGroupsCache.Count) domain group(s) available."
        } catch {
            $lStatus.ForeColor = $C_ERR
            $lStatus.Text      = "Could not load domain groups: $($_.Exception.Message)"
        }
    }).GetNewClosure())

    $dlg.ShowDialog() | Out-Null
}
#endregion

Export-ModuleMember -Function Show-EditUserGroupsDialog
