#region -- ADUserActions.Offboard.Tab.psm1 ------------------------------------
# Concern : Builds the Offboarding Workflow panel (Offboard sub-tab of
#           Account Management, full tab width).
#           Wires the Browse OU button, the inactivity filter dropdown, and
#           the Run Offboarding button. Lazily loads the target user list on
#           first visit to this sub-tab.
#           Sets $script:UAOffOUBox, $script:UAOffNote,
#           $script:UAOffChkDisable/ChkGroups/ChkMoveOU/ChkStamp/ChkPwReset,
#           $script:UAOffTargetGrid, $script:UAOffFilterCombo (read by
#           ADUserActions.Offboard.Cleanup and ADUserActions.Offboard.TargetList).
# Load order: 44 - depends on ADUserActions.Banner (script scope),
#                            ADUserActions.Offboard.Cleanup (Invoke-Offboard),
#                            ADUserActions.Offboard.TargetList
#                              (Read-OffboardTargetUsers, Update-OffboardTargetGrid),
#                            ADUserActions.OUPicker.Dialog (Show-OUPicker),
#                            Services.AD.Reporting (New-SectionPanel, New-StdButton,
#                                                   New-StdGrid),
#                            Services.DomainDefaults.Config (Get-DomainDefaults)
# Split from: ADUserActions.psm1
# Changes   : Full rebuild per approved mockup. Previously this panel showed
#             a static 5-step description, a single read-only "Target user"
#             label driven by the Directory tab's SelectedUser, and a plain
#             note textbox - Run Offboarding always ran all 5 steps against
#             that one user.
#             Now: each of the 5 steps has its own checkbox (defaults:
#             Disable=on, Groups=off, MoveOU=off, Stamp=on, PwReset=on) read
#             by Invoke-Offboard to decide which steps to run. The note
#             field is an editable ComboBox with common preset reasons (free
#             typing still works - no separate "Custom" entry needed). The
#             target user is no longer tied to the Directory tab at all -
#             this panel owns its own multiselect AD user grid
#             ($script:UAOffTargetGrid), lazily loaded on first visit via
#             Read-OffboardTargetUsers, with a single-select inactivity
#             filter dropdown ($script:UAOffFilterCombo: All / Inactive 90+
#             days / Inactive 180+ days / Never logged in) that re-filters
#             the already-loaded list client-side (ADUserActions.Offboard.
#             TargetList) rather than re-querying AD per filter change.
#             Disabled Accounts OU now seeds from this domain's saved
#             DefaultDisabledOU (Services.DomainDefaults.Config, edited on
#             Tools > Domain Defaults) instead of starting blank every time -
#             Browse still overrides it exactly as before.
#             Added Update-OffboardDomainDefaults (exported) - called by the
#             Domain Defaults tab's Save button so a saved change to
#             DefaultDisabledOU takes effect immediately in this running
#             session. Overwrites the field if it is blank OR still matches
#             the last value this function (or the build-time seed) auto-
#             applied ($script:UALastDisabledOUDefault) - never overwrites a
#             Browse pick or a genuinely different manual edit. (An earlier
#             "only if blank" version of this function meant a second save
#             to an already-configured domain silently did nothing - same
#             bug as ADUserActions.CreateUser.Tab's Update-
#             CreateUserDomainDefaults, fixed the same way.) Safe no-op if
#             this panel hasn't been built yet.
#             Tab-leave reset / reload: Build-OffboardPanel registers two
#             plain scriptblocks on its hosting TabPage's Tag (the Offboard
#             page of the Bulk Operations tab):
#               Tag['Resets']    - drops the cached target list
#                                  ($script:UAOffAllUsers = $null), resets
#                                  the filter to "All", empties the target
#                                  grid (rows and columns) and returns the
#                                  status bar to "Ready." (emptying the grid
#                                  through Update-OffboardTargetGrid would
#                                  otherwise leave a "0 of 0" message).
#               Tag['Activates'] - reloads the list from AD via
#                                  Read-OffboardTargetUsers when it was
#                                  dropped - the same check as the existing
#                                  Add_Enter lazy-load, which is kept.
#             Run by ADBulkOps.Register-BulkOpsTab. Users created or deleted
#             on other tabs are therefore always reflected on the next
#             visit. Cost: one AD query (all users incl. disabled) per
#             visit to this page. Step checkboxes, Disabled OU and Note are
#             settings, not results, and are kept.
#endregion

#region -- Build-OffboardPanel ------------------------------------------------
function Build-OffboardPanel {
    <#
    .SYNOPSIS
        Constructs the Offboarding Workflow panel inside the provided parent.
        Returns the inner content panel.
    #>
    param(
        [System.Windows.Forms.Control]$Parent,
        [int]$X, [int]$Y, [int]$W, [int]$H
    )
    $F_UI   = New-Object System.Drawing.Font('Segoe UI', 9)
    $F_UI_B = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $F_SMALL= New-Object System.Drawing.Font('Segoe UI', 8)

    # ---- Resolve this domain's saved default Disabled OU --------------------
    $defaultDisabledOU = ''
    if ($script:UAContext -and $script:UAContext.Domain -and (Get-Command Get-DomainDefaults -ErrorAction SilentlyContinue)) {
        try { $defaultDisabledOU = [string](Get-DomainDefaults -Domain $script:UAContext.Domain).DefaultDisabledOU } catch { }
    }
    # Tracks the last value auto-applied to $script:UAOffOUBox, so
    # Update-OffboardDomainDefaults can tell "still shows what we last set"
    # apart from "operator picked/typed something else" - see that
    # function's doc comment for why a plain "only if blank" check isn't
    # enough on its own.
    $script:UALastDisabledOUDefault = $defaultDisabledOU

    $offSection = New-SectionPanel -Parent $Parent -Title 'Offboarding Workflow' -X $X -Y $Y -W $W -H $H

    $ly = 8

    $lSteps           = New-Object System.Windows.Forms.Label
    $lSteps.Text      = 'Steps to run (uncheck to skip):'
    $lSteps.Location  = New-Object System.Drawing.Point(8, $ly)
    $lSteps.Size      = New-Object System.Drawing.Size(($W - 18), 18)
    $lSteps.Font      = $F_UI_B
    $lSteps.ForeColor = [System.Drawing.Color]::FromArgb(0,80,160)
    $offSection.Controls.Add($lSteps)
    $ly += 22

    # -- Step 1: Disable the account (default ON) ------------------------------
    $script:UAOffChkDisable          = New-Object System.Windows.Forms.CheckBox
    $script:UAOffChkDisable.Text     = '1. Disable the account'
    $script:UAOffChkDisable.Location = New-Object System.Drawing.Point(8, $ly)
    $script:UAOffChkDisable.Size     = New-Object System.Drawing.Size(($W - 18), 22)
    $script:UAOffChkDisable.Font     = $F_UI
    $script:UAOffChkDisable.Checked  = $true
    $offSection.Controls.Add($script:UAOffChkDisable)
    $ly += 22

    # -- Step 2: Remove all group memberships (default OFF) --------------------
    $script:UAOffChkGroups           = New-Object System.Windows.Forms.CheckBox
    $script:UAOffChkGroups.Text      = '2. Remove all group memberships'
    $script:UAOffChkGroups.Location  = New-Object System.Drawing.Point(8, $ly)
    $script:UAOffChkGroups.Size      = New-Object System.Drawing.Size(($W - 18), 22)
    $script:UAOffChkGroups.Font      = $F_UI
    $script:UAOffChkGroups.Checked   = $false
    $offSection.Controls.Add($script:UAOffChkGroups)
    $ly += 22

    # -- Step 3: Move to Disabled OU (default OFF) ------------------------------
    $script:UAOffChkMoveOU           = New-Object System.Windows.Forms.CheckBox
    $script:UAOffChkMoveOU.Text      = '3. Move to Disabled OU'
    $script:UAOffChkMoveOU.Location  = New-Object System.Drawing.Point(8, $ly)
    $script:UAOffChkMoveOU.Size      = New-Object System.Drawing.Size(($W - 18), 22)
    $script:UAOffChkMoveOU.Font      = $F_UI
    $script:UAOffChkMoveOU.Checked   = $false
    $offSection.Controls.Add($script:UAOffChkMoveOU)
    $ly += 22

    # -- Step 4: Stamp Description with date + admin (default ON) --------------
    $script:UAOffChkStamp            = New-Object System.Windows.Forms.CheckBox
    $script:UAOffChkStamp.Text       = '4. Stamp Description with date + admin'
    $script:UAOffChkStamp.Location   = New-Object System.Drawing.Point(8, $ly)
    $script:UAOffChkStamp.Size       = New-Object System.Drawing.Size(($W - 18), 22)
    $script:UAOffChkStamp.Font       = $F_UI
    $script:UAOffChkStamp.Checked    = $true
    $offSection.Controls.Add($script:UAOffChkStamp)
    $ly += 22

    # -- Step 5: Reset password to random value (default ON) --------------------
    $script:UAOffChkPwReset          = New-Object System.Windows.Forms.CheckBox
    $script:UAOffChkPwReset.Text     = '5. Reset password to random value'
    $script:UAOffChkPwReset.Location = New-Object System.Drawing.Point(8, $ly)
    $script:UAOffChkPwReset.Size     = New-Object System.Drawing.Size(($W - 18), 22)
    $script:UAOffChkPwReset.Font     = $F_UI
    $script:UAOffChkPwReset.Checked  = $true
    $offSection.Controls.Add($script:UAOffChkPwReset)
    $ly += 26

    $lLogged           = New-Object System.Windows.Forms.Label
    $lLogged.Text      = 'All checked steps are logged to the operation log.'
    $lLogged.Location  = New-Object System.Drawing.Point(8, $ly)
    $lLogged.Size      = New-Object System.Drawing.Size(($W - 18), 16)
    $lLogged.Font      = $F_SMALL
    $lLogged.ForeColor = [System.Drawing.Color]::DimGray
    $offSection.Controls.Add($lLogged)
    $ly += 26

    $lDisOU             = New-Object System.Windows.Forms.Label
    $lDisOU.Text        = 'Disabled Accounts OU:'
    $lDisOU.Location    = New-Object System.Drawing.Point(8, $ly)
    $lDisOU.Size        = New-Object System.Drawing.Size(($W - 18), 18)
    $lDisOU.Font        = $F_UI
    $offSection.Controls.Add($lDisOU)
    $ly += 20

    $script:UAOffOUBox          = New-Object System.Windows.Forms.TextBox
    $script:UAOffOUBox.Location = New-Object System.Drawing.Point(8, $ly)
    $script:UAOffOUBox.Size     = New-Object System.Drawing.Size(($W - 92), 24)
    $script:UAOffOUBox.Font     = $F_UI
    $script:UAOffOUBox.ReadOnly = $true
    $script:UAOffOUBox.BackColor= [System.Drawing.Color]::FromArgb(245,245,245)
    $script:UAOffOUBox.Text     = $defaultDisabledOU
    $offSection.Controls.Add($script:UAOffOUBox)

    $btnPickOffOU = New-StdButton -Text 'Browse...' -X ($W - 80) -Y $ly -W 72 -H 24 -Parent $offSection
    $ly += 34

    $lNote              = New-Object System.Windows.Forms.Label
    $lNote.Text         = 'Offboarding note (appended to description):'
    $lNote.Location     = New-Object System.Drawing.Point(8, $ly)
    $lNote.Size         = New-Object System.Drawing.Size(($W - 18), 18)
    $lNote.Font         = $F_UI
    $offSection.Controls.Add($lNote)
    $ly += 20

    # Editable combobox - preset reasons or free typing. No separate "Custom"
    # entry: typing directly into the box already covers that case.
    $script:UAOffNote               = New-Object System.Windows.Forms.ComboBox
    $script:UAOffNote.Location      = New-Object System.Drawing.Point(8, $ly)
    $script:UAOffNote.Size          = New-Object System.Drawing.Size(($W - 18), 24)
    $script:UAOffNote.Font          = $F_UI
    $script:UAOffNote.DropDownStyle = 'DropDown'
    @('Terminated','Due to inactivity 90 days','Due to inactivity 180 days','Never logged on','Other') |
        ForEach-Object { [void]$script:UAOffNote.Items.Add($_) }
    $offSection.Controls.Add($script:UAOffNote)
    $ly += 24

    $lNoteHint           = New-Object System.Windows.Forms.Label
    $lNoteHint.Text      = 'Pick a reason above or type your own.'
    $lNoteHint.Location  = New-Object System.Drawing.Point(8, $ly)
    $lNoteHint.Size      = New-Object System.Drawing.Size(($W - 18), 14)
    $lNoteHint.Font      = $F_SMALL
    $lNoteHint.ForeColor = [System.Drawing.Color]::DimGray
    $offSection.Controls.Add($lNoteHint)
    $ly += 24

    # -- Target user list header + filter dropdown -----------------------------
    $lTarget           = New-Object System.Windows.Forms.Label
    $lTarget.Text      = 'Target User List: (full list of AD users - select one or more)'
    $lTarget.Location  = New-Object System.Drawing.Point(8, ($ly + 4))
    $lTarget.Size      = New-Object System.Drawing.Size(($W - 300), 20)
    $lTarget.Font      = $F_UI_B
    $lTarget.ForeColor = [System.Drawing.Color]::FromArgb(0,80,160)
    $offSection.Controls.Add($lTarget)

    $lFilter           = New-Object System.Windows.Forms.Label
    $lFilter.Text      = 'Filter:'
    $lFilter.Location  = New-Object System.Drawing.Point(($W - 268), ($ly + 4))
    $lFilter.Size      = New-Object System.Drawing.Size(40, 20)
    $lFilter.Font      = $F_UI
    $offSection.Controls.Add($lFilter)

    $script:UAOffFilterCombo               = New-Object System.Windows.Forms.ComboBox
    $script:UAOffFilterCombo.Location      = New-Object System.Drawing.Point(($W - 224), $ly)
    $script:UAOffFilterCombo.Size          = New-Object System.Drawing.Size(216, 24)
    $script:UAOffFilterCombo.Font          = $F_UI
    $script:UAOffFilterCombo.DropDownStyle = 'DropDownList'
    @('All','Inactive 90+ days','Inactive 180+ days','Never logged in') |
        ForEach-Object { [void]$script:UAOffFilterCombo.Items.Add($_) }
    $script:UAOffFilterCombo.SelectedIndex = 0
    $offSection.Controls.Add($script:UAOffFilterCombo)
    $ly += 30

    # -- Target user grid - fills remaining space above the Run button ---------
    $RUN_H    = 34
    $GRID_Y   = $ly
    $GRID_H   = $H - $GRID_Y - $RUN_H - 26
    $script:UAOffTargetGrid = New-StdGrid -X 8 -Y $GRID_Y -W ($W - 18) -H $GRID_H -Parent $offSection
    $script:UAOffTargetGrid.MultiSelect   = $true
    $script:UAOffTargetGrid.SelectionMode = 'FullRowSelect'
    $ly += $GRID_H + 10

    $btnOffboard = New-StdButton -Text 'Run Offboarding' -X 8 -Y $ly -W 160 -H $RUN_H -Parent $offSection
    $btnOffboard.Font      = $F_UI_B

    $lRunHint           = New-Object System.Windows.Forms.Label
    $lRunHint.Text      = 'Runs the checked step(s) above for every selected account.'
    $lRunHint.Location  = New-Object System.Drawing.Point(176, ($ly + 8))
    $lRunHint.Size      = New-Object System.Drawing.Size(($W - 190), 20)
    $lRunHint.Font      = $F_SMALL
    $lRunHint.ForeColor = [System.Drawing.Color]::DimGray
    $offSection.Controls.Add($lRunHint)

    # -- Wiring -----------------------------------------------------------------
    $btnPickOffOU.Add_Click({ $dn = Show-OUPicker -Context $script:UAContext; if ($dn) { $script:UAOffOUBox.Text = $dn } })
    $btnOffboard.Add_Click({ Invoke-Offboard })

    $script:UAOffFilterCombo.Add_SelectedIndexChanged({
        if (Get-Command Update-OffboardTargetGrid -ErrorAction SilentlyContinue) {
            Update-OffboardTargetGrid
        }
    })

    # Lazy-load the target list on first visit to this sub-tab (same pattern
    # used by the Computers tab and the Infrastructure sub-tabs).
    $Parent.Add_Enter({
        if (-not $script:UAOffAllUsers -and (Get-Command Read-OffboardTargetUsers -ErrorAction SilentlyContinue)) {
            Read-OffboardTargetUsers
        }
    })

    # Tab-leave reset / reload on return (see module header). Plain
    # scriptblocks - every reference is $script:-scoped.
    if (-not ($Parent.Tag -is [hashtable])) { $Parent.Tag = @{} }
    if (-not $Parent.Tag.ContainsKey('Resets')) {
        $Parent.Tag['Resets'] = New-Object System.Collections.Generic.List[scriptblock]
    }
    if (-not $Parent.Tag.ContainsKey('Activates')) {
        $Parent.Tag['Activates'] = New-Object System.Collections.Generic.List[scriptblock]
    }
    $Parent.Tag['Resets'].Add({
        $script:UAOffAllUsers = $null
        if ($script:UAOffFilterCombo -and $script:UAOffFilterCombo.Items.Count -gt 0 -and
            $script:UAOffFilterCombo.SelectedIndex -ne 0) {
            $script:UAOffFilterCombo.SelectedIndex = 0
        }
        if ($script:UAOffTargetGrid) {
            $script:UAOffTargetGrid.Rows.Clear()
            $script:UAOffTargetGrid.Columns.Clear()
        }
        if (Get-Command Set-Status -ErrorAction SilentlyContinue) { Set-Status 'Ready.' }
    })
    $Parent.Tag['Activates'].Add({
        if (-not $script:UAOffAllUsers -and (Get-Command Read-OffboardTargetUsers -ErrorAction SilentlyContinue)) {
            Read-OffboardTargetUsers
        }
    })

    return $offSection
}
#endregion

#region -- Update-OffboardDomainDefaults ---------------------------------------
function Update-OffboardDomainDefaults {
    <#
    .SYNOPSIS
        Re-applies this domain's saved Disabled Accounts OU (Tools > Domain
        Defaults) to the already-built Offboarding panel, without requiring
        the panel to be rebuilt or this sub-tab to be re-entered. Called by
        the Domain Defaults tab's Save button so a save takes effect
        immediately in the same running session.
    .DESCRIPTION
        Overwrites the field with the newly saved value if it is EITHER
        currently blank OR still holds exactly the value this function (or
        the build-time seed) last auto-applied - tracked via
        $script:UALastDisabledOUDefault. If the operator has since picked a
        different OU via Browse (or typed one), it is left alone.
        A plain "only if blank" rule doesn't actually give a live refresh in
        the common case: once a domain has ANY saved Disabled OU, the field
        is never blank again, so a LATER change to that same OU would
        silently stop taking effect here even without an operator's edit -
        see the identical bug (and this same fix) in
        ADUserActions.CreateUser.Tab's Update-CreateUserDomainDefaults.
        Safe no-op if the panel hasn't been built yet, the domain isn't
        connected, or Services.DomainDefaults.Config isn't loaded.
    #>
    if (-not $script:UAOffOUBox) { return }
    if (-not $script:UAContext -or -not $script:UAContext.Domain) { return }
    if (-not (Get-Command Get-DomainDefaults -ErrorAction SilentlyContinue)) { return }

    $ou = ''
    try { $ou = [string](Get-DomainDefaults -Domain $script:UAContext.Domain).DefaultDisabledOU } catch { }
    if ($ou) {
        if ($script:UAOffOUBox.Text -eq '' -or $script:UAOffOUBox.Text -eq $script:UALastDisabledOUDefault) {
            $script:UAOffOUBox.Text = $ou
        }
        $script:UALastDisabledOUDefault = $ou
    }
}
#endregion

Export-ModuleMember -Function Build-OffboardPanel, Update-OffboardDomainDefaults
