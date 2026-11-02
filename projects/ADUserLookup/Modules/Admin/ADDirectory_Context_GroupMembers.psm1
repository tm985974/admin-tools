#region -- ADDirectory.Context.GroupMembers.psm1 ------------------------------
# Concern : Show-GroupMembersDialog - modal form for viewing and editing group
#           membership. Single add (lazy user combo load) and right-click
#           remove, with per-operation logging. Bulk add/remove via pasted
#           text was removed; multiselect + right-click remove covers that
#           need without a separate text-paste path.
# Load order: 23 - depends on ADDirectory.Context.Common (script scope),
#                            Services.AD.Reporting (Confirm-Action, Write-OperationLog,
#                                                   New-StdGrid, Set-GridData),
#                            Services.AD.Connection.Query (Get-DomainUsers),
#                            Services.AD.RecoverySnapshot (Get-ADRecoverySnapshot) [3a],
#                            Services.Mail.Send (ConvertTo-MailRecoveryBlock) [4b],
#                            Services.Mail.Dialog (Show-NotificationMailDialog) [4c],
#                            ADDirectory.Groups.Load (Read-SelectedUserGroups)
# Split from: ADDirectory.Menus.psm1
# Changes   : Add to Group and Remove Selected Member(s) now also call
#             Read-SelectedUserGroups for each affected user after a
#             successful change, matching the pattern already used by
#             ADDirectory.Context.UserGroups (Show-EditUserGroupsDialog). This
#             dialog already refreshed its own member grid (& $loadMembers);
#             it did not refresh the Directory tab's main Groups pane (the
#             per-user membership view), which stayed stale until a manual
#             reload if the added/removed user happened to be the one
#             currently shown there. Read-SelectedUserGroups is a single
#             targeted AD query for one user's membership, not a full-domain
#             or full-group requery.
#             Admin tracking mail added to Remove Selected Member(s): this
#             action previously sent no mail at all. Before each member is
#             removed, its OU is captured via Get-ADRecoverySnapshot (member
#             Type resolved from the grid's objectClass column - User/
#             Computer/Group; unrecognised types skip the snapshot but the
#             member is still reported). After the batch, if at least one
#             member was actually removed, a single Show-
#             NotificationMailDialog -AdminOnly (To = admin, no CC) is opened
#             listing which group they were removed from, plus one recovery
#             block per removed member (OU only - a member's own group
#             memberships elsewhere are unrelated to this removal). Non-fatal.
# v1.6.0    : Notification email trimmed to basic information: Action / DC /
#             rows repeated in the message text and the "administrative tracking
#             only" line removed.
#endregion

#region -- Show-GroupMembersDialog --------------------------------------------
function Show-GroupMembersDialog {
    <#
    .SYNOPSIS
        Edit Members dialog. $loadMembers is defined first so all handlers
        capture it correctly via GetNewClosure(). Combo population is lazy
        (Add_DropDown) so the member grid paints immediately on open.
    #>
    param([string]$GroupName, [PSCustomObject]$Context)

    $F_UI    = New-Object System.Drawing.Font('Segoe UI', 9)
    $F_UI_B  = New-Object System.Drawing.Font('Segoe UI', 9,  [System.Drawing.FontStyle]::Bold)
    $F_13B   = New-Object System.Drawing.Font('Segoe UI', 13, [System.Drawing.FontStyle]::Bold)
    $F_SMALL = New-Object System.Drawing.Font('Segoe UI', 8)

    $C_BLUE = [System.Drawing.Color]::FromArgb(0, 99, 177)
    $C_BG   = [System.Drawing.Color]::FromArgb(235,238,242)
    $C_SEP  = [System.Drawing.Color]::FromArgb(180,195,220)
    $C_DIM  = [System.Drawing.Color]::DimGray
    $C_OK   = [System.Drawing.Color]::FromArgb(0, 97, 0)
    $C_ERR  = [System.Drawing.Color]::FromArgb(156, 0, 6)

    $memberSet = New-Object System.Collections.Generic.HashSet[string]
    $userMap   = @{}

    $dlg                 = New-Object System.Windows.Forms.Form
    $dlg.Text            = "Edit Members  --  $GroupName"
    $dlg.ClientSize      = New-Object System.Drawing.Size(720, 466)
    $dlg.FormBorderStyle = 'FixedSingle'
    $dlg.MaximizeBox     = $false
    $dlg.StartPosition   = 'CenterParent'
    $dlg.BackColor       = $C_BG
    $dlg.Font            = $F_UI

    $pTitle              = New-Object System.Windows.Forms.Panel
    $pTitle.Location     = New-Object System.Drawing.Point(0, 0)
    $pTitle.Size         = New-Object System.Drawing.Size(720, 46)
    $pTitle.BackColor    = $C_BLUE
    $dlg.Controls.Add($pTitle)

    $lTitle              = New-Object System.Windows.Forms.Label
    $lTitle.Text         = "   Edit Members  --  $GroupName"
    $lTitle.Location     = New-Object System.Drawing.Point(0, 0)
    $lTitle.Size         = New-Object System.Drawing.Size(720, 46)
    $lTitle.Font         = $F_13B
    $lTitle.ForeColor    = [System.Drawing.Color]::White
    $lTitle.TextAlign    = 'MiddleLeft'
    $pTitle.Controls.Add($lTitle)

    $lStatus             = New-Object System.Windows.Forms.Label
    $lStatus.Location    = New-Object System.Drawing.Point(12, 54)
    $lStatus.Size        = New-Object System.Drawing.Size(696, 18)
    $lStatus.Font        = $F_UI
    $lStatus.ForeColor   = $C_DIM
    $lStatus.Text        = 'Loading...'
    $dlg.Controls.Add($lStatus)

    $grid                = New-StdGrid -X 12 -Y 76 -W 696 -H 288 -Parent $dlg
    $grid.MultiSelect    = $true
    $grid.SelectionMode  = 'FullRowSelect'

    $lHint               = New-Object System.Windows.Forms.Label
    $lHint.Text          = 'Right-click to remove selected member(s)  |  Shift/Ctrl+Click for multi-select'
    $lHint.Location      = New-Object System.Drawing.Point(12, 368)
    $lHint.Size          = New-Object System.Drawing.Size(696, 16)
    $lHint.Font          = $F_SMALL
    $lHint.ForeColor     = $C_DIM
    $dlg.Controls.Add($lHint)

    $pSep1               = New-Object System.Windows.Forms.Panel
    $pSep1.Location      = New-Object System.Drawing.Point(12, 390)
    $pSep1.Size          = New-Object System.Drawing.Size(696, 1)
    $pSep1.BackColor     = $C_SEP
    $dlg.Controls.Add($pSep1)

    $lAddCap             = New-Object System.Windows.Forms.Label
    $lAddCap.Text        = 'Add member:'
    $lAddCap.Location    = New-Object System.Drawing.Point(12, 398)
    $lAddCap.Size        = New-Object System.Drawing.Size(96, 26)
    $lAddCap.Font        = $F_UI_B
    $lAddCap.TextAlign   = 'MiddleLeft'
    $dlg.Controls.Add($lAddCap)

    $cmbAdd                    = New-Object System.Windows.Forms.ComboBox
    $cmbAdd.Location           = New-Object System.Drawing.Point(112, 397)
    $cmbAdd.Size               = New-Object System.Drawing.Size(450, 24)
    $cmbAdd.DropDownStyle      = 'DropDown'
    $cmbAdd.Font               = $F_UI
    $cmbAdd.AutoCompleteMode   = [System.Windows.Forms.AutoCompleteMode]::SuggestAppend
    $cmbAdd.AutoCompleteSource = [System.Windows.Forms.AutoCompleteSource]::ListItems
    $dlg.Controls.Add($cmbAdd)

    $btnAdd              = New-Object System.Windows.Forms.Button
    $btnAdd.Text         = 'Add to Group'
    $btnAdd.Location     = New-Object System.Drawing.Point(570, 396)
    $btnAdd.Size         = New-Object System.Drawing.Size(138, 26)
    $btnAdd.FlatStyle    = 'Standard'
    $btnAdd.Font         = $F_UI_B
    $dlg.Controls.Add($btnAdd)

    $btnClose            = New-Object System.Windows.Forms.Button
    $btnClose.Text       = 'Close'
    $btnClose.Location   = New-Object System.Drawing.Point(612, 430)
    $btnClose.Size       = New-Object System.Drawing.Size(96, 30)
    $btnClose.FlatStyle  = 'Standard'
    $btnClose.Font       = $F_UI
    $dlg.Controls.Add($btnClose)
    $btnClose.Add_Click({ $dlg.Close() })

    # $loadMembers defined before any handler that references it
    $loadMembers = {
        $lStatus.Text = 'Loading members...'; $lStatus.ForeColor = $C_DIM; $dlg.Refresh()
        $memberSet.Clear()
        $srvParam = if ($Context.TargetDC) { @{ Server = $Context.TargetDC } } else { @{} }
        try {
            $members = Get-ADGroupMember -Identity $GroupName @srvParam -ErrorAction Stop |
                       Sort-Object objectClass, Name
            $data = @($members | ForEach-Object {
                $sam = [string]$_.SamAccountName
                if ($sam) { [void]$memberSet.Add($sam.ToLower()) }
                [PSCustomObject]@{
                    Name           = [string]$_.Name
                    SamAccountName = $sam
                    Type           = [string]$_.objectClass
                }
            })
            Set-GridData -Grid $grid -Data $data -Columns @('Name','SamAccountName','Type')
            $lStatus.ForeColor = $C_DIM
            $lStatus.Text      = "$($data.Count) member(s)"
        } catch {
            $lStatus.ForeColor = $C_ERR
            $lStatus.Text      = "Load failed: $($_.Exception.Message)"
        }
    }

    # Confirm-Action / Write-OperationLog are defined in Services.AD.Reporting /
    # Services.Logging, loaded well before this module. They are unreachable by
    # bare name from inside a .GetNewClosure() block - the same closure-scope
    # resolution bug documented throughout this codebase (see ADDirectory.
    # Register-DirectoryTab for the fuller explanation and ADDirectory.Menus
    # for the Show-DisableAccountDialog call-site fix in the same
    # class as the Show-GroupMembersDialog call-site fix in ADDirectory.Menus),
    # so they are captured here and invoked via & for every closure that needs them.
    # Read-SelectedUserGroups is captured the same way so a successful add/
    # remove can refresh the Directory tab's main Groups pane for the affected
    # user, matching ADDirectory.Context.UserGroups' existing pattern.
    # Get-ADRecoverySnapshot / ConvertTo-MailRecoveryBlock / Show-
    # NotificationMailDialog are captured the same way for the new Remove
    # Selected Member(s) tracking mail.
    $confirmActionFn  = ${function:Confirm-Action}
    $writeOpLogFn     = ${function:Write-OperationLog}
    $readSelUserGrpFn = ${function:Read-SelectedUserGroups}
    $getSnapshotFnM   = ${function:Get-ADRecoverySnapshot}
    $convertRecoveryFnM = ${function:ConvertTo-MailRecoveryBlock}
    $showMailDlgFnM   = ${function:Show-NotificationMailDialog}
    $capturedContextM = $Context
    $capturedGroupNm  = $GroupName

    # Members grid right-click remove
    $membersMenu      = New-Object System.Windows.Forms.ContextMenuStrip
    $membersMenu.Font = $F_UI

    $miRemoveMem      = New-Object System.Windows.Forms.ToolStripMenuItem
    $miRemoveMem.Text = 'Remove Selected Member(s)'
    $miRemoveMem.Add_Click(({
        # Capture Identity + Type (for the recovery snapshot) together, not
        # just the identity string - objectClass tells us which Get-AD*
        # cmdlet to snapshot with.
        $toRemove = [System.Collections.Generic.List[PSCustomObject]]::new()
        foreach ($row in $grid.SelectedRows) {
            $s = $row.Cells['SamAccountName'].Value
            if (-not $s) { $s = $row.Cells['Name'].Value }
            if (-not $s) { continue }
            $oc = [string]$row.Cells['Type'].Value
            $snapType = switch ($oc) {
                'user'     { 'User' }
                'computer' { 'Computer' }
                'group'    { 'Group' }
                default    { '' }
            }
            [void]$toRemove.Add([PSCustomObject]@{ Identity = [string]$s; SnapType = $snapType })
        }
        if ($toRemove.Count -eq 0) { return }
        $msg = if ($toRemove.Count -eq 1) { "Remove '$($toRemove[0].Identity)' from '$GroupName'?" } `
               else { "Remove $($toRemove.Count) member(s) from '$GroupName'?" }
        if (-not (& $confirmActionFn -Title 'Remove Members' -Message $msg -ActionLabel 'Remove')) { return }
        $srvParam = if ($Context.TargetDC) { @{ Server = $Context.TargetDC } } else { @{} }
        $ok = 0; $fail = 0; $failMsg = ''
        $removedOk     = [System.Collections.Generic.List[string]]::new()
        $recoveryItems = [System.Collections.Generic.List[PSCustomObject]]::new()

        foreach ($entry in $toRemove) {
            $id = $entry.Identity

            # -- Recovery snapshot FIRST (OU only - the member's own group
            #    list elsewhere is unrelated to a removal from THIS group).
            #    Skipped gracefully for object types the snapshot function
            #    doesn't recognise; the member is still reported without OU.
            if ($getSnapshotFnM -and $entry.SnapType) {
                $snap = & $getSnapshotFnM -Identity $id -Type $entry.SnapType -SrvParam $srvParam
                if ($snap -and $snap.Found) {
                    [void]$recoveryItems.Add([PSCustomObject]@{ Label = $id; OU = $snap.OU })
                }
            }

            try {
                Remove-ADGroupMember -Identity $GroupName -Members $id `
                    @srvParam -Confirm:$false -ErrorAction Stop
                & $writeOpLogFn -Context $Context -Action 'REMOVE-GROUP-MEMBER' `
                    -Target $id -Result 'OK' -Detail "Group=$GroupName"
                [void]$removedOk.Add($id)
                $ok++
            } catch {
                & $writeOpLogFn -Context $Context -Action 'REMOVE-GROUP-MEMBER' `
                    -Target $id -Result 'FAIL' -Detail $_.Exception.Message
                $failMsg += "${id}: $($_.Exception.Message)`n"; $fail++
            }
        }
        & $loadMembers
        $summary = "Removed: $ok"
        if ($fail -gt 0) { $summary += "  |  Failed: $fail" }
        $lStatus.ForeColor = if ($fail -gt 0) { $C_ERR } else { $C_OK }
        $lStatus.Text = $summary
        if ($fail -gt 0) {
            [System.Windows.Forms.MessageBox]::Show($failMsg,'Remove Failed','OK','Error')
        }

        # Refresh the main Directory tab's Groups pane for each affected user
        # (single targeted AD query per user, no full requery). Only matters
        # if that user happens to be the one currently shown there, but the
        # call is cheap enough to make unconditionally, same as
        # ADDirectory.Context.UserGroups does for its own Add/Remove.
        if ($readSelUserGrpFn) {
            foreach ($rid in $removedOk) { & $readSelUserGrpFn -Sam $rid }
        }

        # -- Admin tracking mail (To admin, no CC) - one summary per removal --
        # New capability: this action previously sent no mail at all. Fires
        # only when at least one member was actually removed. Non-fatal.
        if ($ok -gt 0 -and $showMailDlgFnM) {
            $details = [ordered]@{
                'Removed'     = "$ok member(s)"
                'Failed'      = "$fail"
                'Admin'       = if ($capturedContextM -and $capturedContextM.AdminAccount) { $capturedContextM.AdminAccount } else { "$env:USERDOMAIN\$env:USERNAME" }
                'Domain'      = if ($capturedContextM -and $capturedContextM.Domain)       { $capturedContextM.Domain }       else { $env:USERDNSDOMAIN }
                'Timestamp'   = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
            }

            $bodyText = "The following member(s) were removed from '$capturedGroupNm':" + "`r`n`r`n" +
                        (($removedOk | ForEach-Object { "- " + $_ }) -join "`r`n")

            $recoverySubset = @($recoveryItems | Where-Object { $removedOk -contains $_.Label })
            if ($recoverySubset.Count -gt 0 -and $convertRecoveryFnM) {
                $recoveryBlock = & $convertRecoveryFnM -Items $recoverySubset `
                    -Heading 'Recovery details (OU at time of removal):'
                if ($recoveryBlock) {
                    $bodyText += "`r`n`r`n" + $recoveryBlock
                }
            }

            & $showMailDlgFnM `
                -Context     $capturedContextM `
                -Sam         '' `
                -ActionTitle 'Group Member(s) Removed' `
                -Subject     "AD Remove Group Member(s): $capturedGroupNm" `
                -Details     $details `
                -BodyText    $bodyText `
                -AdminOnly
        }
    }).GetNewClosure())
    [void]$membersMenu.Items.Add($miRemoveMem)
    [void]$membersMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

    $miCopyMem      = New-Object System.Windows.Forms.ToolStripMenuItem
    $miCopyMem.Text = 'Copy Name(s)'
    $miCopyMem.Add_Click(({
        $names = [System.Collections.Generic.List[string]]::new()
        foreach ($row in $grid.SelectedRows) {
            $n = $row.Cells['Name'].Value; if ($n) { [void]$names.Add([string]$n) }
        }
        if ($names.Count -gt 0) { [System.Windows.Forms.Clipboard]::SetText($names -join "`r`n") }
    }).GetNewClosure())
    [void]$membersMenu.Items.Add($miCopyMem)

    $grid.ContextMenuStrip = $membersMenu

    $grid.Add_MouseDown({
        param($s,$e)
        if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Right) { return }
        $hit = $s.HitTest($e.X, $e.Y)
        if ($hit.RowIndex -ge 0 -and -not $s.Rows[$hit.RowIndex].Selected) {
            $s.ClearSelection(); $s.Rows[$hit.RowIndex].Selected = $true
        }
    })

    # Lazy-load domain users on first DropDown
    $dlgDomainDN = $Context.DomainDN
    $dlgTargetDC = $Context.TargetDC
    # Populated on Add_Enter (control receives focus), not Add_DropDown -
    # see ADDirectory.Context.UserGroups.psm1 for why: Add_DropDown mutation
    # crashed with AccessViolationException, and forcing DroppedDown closed/
    # reopen from inside Add_DropDown fought WinForms' own state machine and
    # made the dropdown appear to never populate. Add_Enter avoids both.
    $addUsersLoaded = $false
    $cmbAdd.Add_Enter({
        if ($addUsersLoaded) { return }
        $addUsersLoaded = $true
        $srvParam = if ($dlgTargetDC) { @{ Server = $dlgTargetDC } } else { @{} }
        $items = [System.Collections.Generic.List[string]]::new()
        try {
            $domainUsers = Get-DomainUsers -SearchBase $dlgDomainDN -IncludeDisabled @srvParam |
                           Sort-Object { if ($_.DisplayName) { $_.DisplayName } else { $_.SamAccountName } }
            foreach ($u in $domainUsers) {
                $sam  = [string]$u.SamAccountName
                if (-not $sam) { continue }
                $disp = if ($u.DisplayName) { "$($u.DisplayName) ($sam)" } else { $sam }
                [void]$items.Add($disp)
                $userMap[$disp] = $sam
            }
        } catch {
            $addUsersLoaded = $false
        }
        $cmbAdd.BeginUpdate()
        try {
            foreach ($disp in $items) { [void]$cmbAdd.Items.Add($disp) }
        } finally {
            $cmbAdd.EndUpdate()
        }
    })

    # Add to Group
    $btnAdd.Add_Click(({
        $txt = $cmbAdd.Text.Trim()
        if (-not $txt) {
            [System.Windows.Forms.MessageBox]::Show('Type or select a user to add.','Add Member','OK','Information')
            return
        }
        $id = if ($userMap.ContainsKey($txt)) { $userMap[$txt] }
              else {
                  $found = $userMap.Values | Where-Object { $_ -ieq $txt } | Select-Object -First 1
                  if ($found) { $found } else { $txt }
              }
        if ($memberSet.Contains($id.ToLower())) {
            [System.Windows.Forms.MessageBox]::Show("'$id' is already a member of '$GroupName'.","Already Member",'OK','Information')
            return
        }
        if (-not (& $confirmActionFn -Title 'Add Member' -Message "Add '$id' to '$GroupName'?" -ActionLabel 'Add')) { return }
        $srvParam = if ($Context.TargetDC) { @{ Server = $Context.TargetDC } } else { @{} }
        try {
            Add-ADGroupMember -Identity $GroupName -Members $id @srvParam -ErrorAction Stop
            & $writeOpLogFn -Context $Context -Action 'ADD-GROUP-MEMBER' `
                -Target $id -Result 'OK' -Detail "Group=$GroupName"
            & $loadMembers
            $cmbAdd.Text = ''
            $lStatus.ForeColor = $C_OK
            $lStatus.Text = "Added '$id' successfully."

            # Refresh the main Directory tab's Groups pane for this user
            # (single targeted AD query, not a full requery).
            if ($readSelUserGrpFn) { & $readSelUserGrpFn -Sam $id }
        } catch {
            & $writeOpLogFn -Context $Context -Action 'ADD-GROUP-MEMBER' `
                -Target $id -Result 'FAIL' -Detail $_.Exception.Message
            [System.Windows.Forms.MessageBox]::Show("Failed to add '$id':`n$($_.Exception.Message)",'Add Failed','OK','Error')
        }
    }).GetNewClosure())

    $dlg.Add_Shown(({ & $loadMembers }).GetNewClosure())
    $dlg.ShowDialog() | Out-Null
}
#endregion

Export-ModuleMember -Function Show-GroupMembersDialog
