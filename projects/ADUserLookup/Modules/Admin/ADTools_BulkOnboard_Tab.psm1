#region -- ADTools.BulkOnboard.Tab.psm1 ---------------------------------------
# Concern : Build-BulkTab - constructs the Bulk Onboarding sub-tab with file
#           picker, template download, OU picker, EDITABLE preview grid,
#           import results RTB, and Import Users button. Wires all events.
# Load order: 119 - depends on ADTools.BulkOnboard.Engine (Show-BulkCSV,
#                                                           Invoke-BulkOnboard),
#                            ADTools.BulkOnboard.Template (Save-BulkTemplate),
#                            ADTools.BulkOnboard.Log (Write-BulkLog),
#                            ADTools.PasswordGenerator.Engine (script scope),
#                            Services.AD.Reporting (New-SectionPanel, New-StdGrid,
#                                                   New-StdButton, Confirm-Action,
#                                                   Get-GridRowsAsObjects),
#                            Services.DomainDefaults.Config (Get-DomainDefaults),
#                            Services.Mail.Batch (New-MailModeSelector,
#                              Get-MailModeSelection) [4e],
#                            ADDirectory.Users.Load (Get-CachedUsers) [4d] - soft, guarded
# Split from: ADTools.Tab.psm1
# Changes   : Default OU now seeds from this domain's saved
#             DefaultBulkOnboardOU (Services.DomainDefaults.Config, edited on
#             Tools > Domain Defaults) instead of starting blank every time -
#             Browse still overrides it exactly as before.
#             Added Update-BulkOnboardDomainDefaults (exported) - called by
#             the Domain Defaults tab's Save button so a saved change to
#             DefaultBulkOnboardOU takes effect immediately in this running
#             session. Overwrites the field if it is blank OR still matches
#             the last value this function (or the build-time seed) auto-
#             applied ($script:UALastBulkOnboardOUDefault) - never
#             overwrites a Browse pick or a genuinely different manual edit.
#             Added a "Notification:" mode selector (Services.Mail.Batch) to
#             the CSV Import Controls section, defaulting to Admin Only.
#             GUARDED the same way as every other soft cross-module call in
#             this file - see ADTools.BulkOnboard.Engine's header for what
#             each mode now does.
#
#             Preview grid is now EDITABLE (BulkPreviewGrid.ReadOnly forced
#             to $false right after New-StdGrid builds it - a LOCAL override,
#             not a change to New-StdGrid itself, which stays ReadOnly=$true
#             by default for every other grid in this app). CSV Import
#             Controls description label updated to the new column set (see
#             ADTools.BulkOnboard.Template's header). ADTools.BulkOnboard.
#             Engine's Show-BulkCSV now loads the FULL csv (no more 20-row
#             cap) and computes DisplayName/LogonName per row - see that
#             module's header.
#
#             Added Update-BulkGroupsComboColumn (private, NOT exported -
#             called right after every Show-BulkCSV) - converts the
#             plain-text CopyGroupsFrom column into a DataGridViewComboBoxColumn
#             populated from Get-CachedUsers (same source ADUserActions.
#             CreateUser.Tab's own Copy Groups From combo uses), so a row's
#             group-template pick is made from a real dropdown rather than
#             typed free text. Items are plain SamAccountName strings (not
#             the friendlier "Display (SAM)" format the single-user combo
#             uses) - Get-GridRowsAsObjects reads a DataGridViewComboBoxColumn's
#             FormattedValue, which for a plain-string Items list is exactly
#             the SAM value Invoke-BulkOnboard's -Identity group lookup
#             needs; a DisplayMember/ValueMember split would have
#             FormattedValue return the friendly text instead, breaking that
#             lookup. Column type must be re-applied after every grid reload
#             because Set-GridData (Services.AD.Reporting) clears and
#             rebuilds every column as plain text on each call - each row's
#             current selection is preserved across that rebuild.
#             DELIBERATELY a real function, not a scriptblock variable
#             invoked via .GetNewClosure() - an EARLIER version used
#             $applyGroupsComboColumn = {...}.GetNewClosure() and then called
#             it from the Browse/Preview buttons' OWN .GetNewClosure()
#             blocks, which broke $script:BulkTbFile.Text and the
#             Show-BulkCSV call in those same handlers ("property Text
#             cannot be found on this object" / "Show-BulkCSV is not
#             recognized"). This is the SAME documented PS 5.1 behaviour
#             already called out in ADTools.DomainDefaults.Tab's header -
#             $script: variables and bare function names read from inside a
#             .GetNewClosure() block do not reliably resolve - except this
#             file's OWN original Add_Click handlers never needed
#             .GetNewClosure() in the first place (they only ever touched
#             $script: controls and called module functions by bare name,
#             both of which resolve fine from a plain, non-closure
#             scriptblock). Adding .GetNewClosure() to let those same
#             handlers ALSO see a local scriptblock variable introduced the
#             exact failure mode this codebase already has a standing fix
#             for elsewhere. The fix here is different but equivalent:
#             instead of a local scriptblock needing closure capture, this
#             is a normal module function - resolved by ordinary command
#             lookup, the same mechanism that already makes Show-BulkCSV,
#             Write-BulkLog, Save-BulkTemplate, and Confirm-Action work fine
#             as bare names from plain scriptblocks. Every Add_Click handler
#             in this file is back to a plain {...} scriptblock, matching
#             this file's own original, working convention - none of them
#             need .GetNewClosure().
#
#             Import Users no longer re-reads the CSV file - Set-GridData
#             (Services.AD.Reporting) populated the grid at Preview time, and
#             any admin edits since then (including cells the Preview build
#             computed, like DisplayName/LogonName, and the new CopyGroupsFrom
#             combo) live only in the grid, not in the original file. The
#             Import button now reads the grid's CURRENT contents via
#             Get-GridRowsAsObjects (Services.AD.Reporting, already used
#             elsewhere in this app for HTML/CSV export) and passes that
#             straight to Invoke-BulkOnboard's new -Rows parameter, replacing
#             the old -CSVPath. This closes the gap where editing the preview
#             previously had no effect on what actually imported.
#             Tab-leave reset: Build-BulkTab registers a reset scriptblock
#             on its TabPage Tag['Resets'] that clears the CSV path, the
#             CSV Preview grid (rows AND columns, including the
#             CopyGroupsFrom dropdown column - Show-BulkCSV rebuilds them
#             on the next preview) and the Import Results log. Target OU
#             and Notification mode are kept. A plain scriptblock (no
#             .GetNewClosure()) because every control it touches is
#             $script:-scoped, exactly like this function's own Add_Click
#             handlers. Run by ADBulkOps.Register-BulkOpsTab whenever this
#             page is left (sub-tab switch or leaving the Bulk Operations
#             tab).
#endregion

#region -- Build-BulkTab ------------------------------------------------------
function Build-BulkTab {
    param([System.Windows.Forms.TabPage]$Tab)
    $PAD    = 8
    $F_UI   = New-Object System.Drawing.Font('Segoe UI', 9)
    $F_UI_B = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $F_MONO = New-Object System.Drawing.Font('Consolas', 9)
    $TW     = $script:_TW; $TH = $script:_TH

    # ---- Resolve this domain's saved default Bulk Onboard OU ---------------
    $defaultBulkOU = ''
    if ($script:ToolsCtx -and $script:ToolsCtx.Domain -and (Get-Command Get-DomainDefaults -ErrorAction SilentlyContinue)) {
        try { $defaultBulkOU = [string](Get-DomainDefaults -Domain $script:ToolsCtx.Domain).DefaultBulkOnboardOU } catch { }
    }
    # Tracks the last value auto-applied to $script:BulkTbOU, so
    # Update-BulkOnboardDomainDefaults can tell "still shows what we last
    # set" apart from "operator picked/typed something else" - see that
    # function's doc comment for why a plain "only if blank" check isn't
    # enough on its own.
    $script:UALastBulkOnboardOUDefault = $defaultBulkOU

    $lDesc           = New-Object System.Windows.Forms.Label
    $lDesc.Text      = 'Import users from CSV. Required columns: FirstName, LastName, LogonCustomText  |  Optional: DisplayCustomText, UpnSuffix, TargetOU, Phone, Email, CopyGroupsFrom, Password (blank = randomize)'
    $lDesc.Location  = New-Object System.Drawing.Point($PAD, ($PAD+2))
    $lDesc.Size      = New-Object System.Drawing.Size(($TW-($PAD*2)), 20)
    $lDesc.Font      = $F_UI; $lDesc.ForeColor = [System.Drawing.Color]::DimGray
    $Tab.Controls.Add($lDesc)

    $CTRL_Y = $PAD + 20 + $PAD
    $pCtrl  = New-SectionPanel -Parent $Tab -Title 'CSV Import Controls' `
        -X $PAD -Y $CTRL_Y -W ($TW-($PAD*2)) -ContentH 90

    $lbFile           = New-Object System.Windows.Forms.Label
    $lbFile.Text      = 'CSV File:'; $lbFile.Location = New-Object System.Drawing.Point(6, 6)
    $lbFile.Size      = New-Object System.Drawing.Size(60, 22); $lbFile.Font = $F_UI
    $pCtrl.Controls.Add($lbFile)

    $script:BulkTbFile           = New-Object System.Windows.Forms.TextBox
    $script:BulkTbFile.Location  = New-Object System.Drawing.Point(68, 4)
    $script:BulkTbFile.Size      = New-Object System.Drawing.Size(500, 24); $script:BulkTbFile.Font = $F_UI
    $script:BulkTbFile.ReadOnly  = $true; $script:BulkTbFile.BackColor = [System.Drawing.Color]::FromArgb(245,245,245)
    $pCtrl.Controls.Add($script:BulkTbFile)

    $btnBrowse   = New-StdButton -Text 'Browse...'         -X 576 -Y 4   -W 90  -H 26 -Parent $pCtrl
    $btnTemplate = New-StdButton -Text 'Download Template' -X 674 -Y 4   -W 140 -H 26 -Parent $pCtrl
    $btnPreview  = New-StdButton -Text 'Preview CSV'       -X 822 -Y 4   -W 100 -H 26 -Parent $pCtrl

    $lbOU              = New-Object System.Windows.Forms.Label
    $lbOU.Text         = 'Default OU (if not in CSV):'
    $lbOU.Location     = New-Object System.Drawing.Point(6, 36)
    $lbOU.Size         = New-Object System.Drawing.Size(180, 22); $lbOU.Font = $F_UI
    $pCtrl.Controls.Add($lbOU)

    $script:BulkTbOU           = New-Object System.Windows.Forms.TextBox
    $script:BulkTbOU.Location  = New-Object System.Drawing.Point(188, 34)
    $script:BulkTbOU.Size      = New-Object System.Drawing.Size(380, 24); $script:BulkTbOU.Font = $F_UI
    $script:BulkTbOU.ReadOnly  = $true; $script:BulkTbOU.BackColor = [System.Drawing.Color]::FromArgb(245,245,245)
    $script:BulkTbOU.Text      = $defaultBulkOU
    $pCtrl.Controls.Add($script:BulkTbOU)

    $btnPickOU  = New-StdButton -Text 'Browse...'    -X 576 -Y 34 -W 90  -H 26 -Parent $pCtrl
    $btnImport  = New-StdButton -Text 'Import Users' -X 674 -Y 34 -W 120 -H 26 -Parent $pCtrl
    $btnImport.Font = $F_UI_B

    # -- Notification mode - Admin Only (default) / Individual / Both / None.
    #    Individual sends each successfully-created user their OWN welcome
    #    email with their OWN temporary password only - see
    #    ADTools.BulkOnboard.Engine's header for the mail-attribute caveat
    #    (brand-new accounts often have no resolvable mail attribute yet
    #    unless the CSV's Email column was filled in).
    #    GUARDED: an earlier unguarded call here threw when Services.Mail.
    #    Batch was accidentally missing from the launcher's load order,
    #    which silently aborted the REST of this function - every button's
    #    Add_Click wiring below never ran, leaving every button on this tab
    #    visible but inert. Guarding this call (matching the soft-dependency
    #    pattern used everywhere else in this app) means a missing/failed
    #    module now just omits the notification row instead of breaking
    #    every other control on the tab.
    if (Get-Command New-MailModeSelector -ErrorAction SilentlyContinue) {
        $script:BulkMailModeSelector = New-MailModeSelector -Parent $pCtrl -X 6 -Y 64 -DefaultMode 'AdminOnly'
    } else {
        $script:BulkMailModeSelector = $null
        $lNoMailMode           = New-Object System.Windows.Forms.Label
        $lNoMailMode.Text      = 'Notification mode unavailable - Services_Mail_Batch module not loaded.'
        $lNoMailMode.Location  = New-Object System.Drawing.Point(6, 66)
        $lNoMailMode.Size      = New-Object System.Drawing.Size(500, 18)
        $lNoMailMode.Font      = $F_UI
        $lNoMailMode.ForeColor = [System.Drawing.Color]::FromArgb(156,0,6)
        $pCtrl.Controls.Add($lNoMailMode)
    }

    $CTRL_SEC_H = 90 + 24 + 1
    $PREV_Y     = $CTRL_Y + $CTRL_SEC_H + $PAD; $PREV_H = 180
    $prevSec    = New-SectionPanel -Parent $Tab -Title 'CSV Preview (editable - edit any cell before importing)' `
        -X $PAD -Y $PREV_Y -W ($TW-($PAD*2)) -H $PREV_H
    $script:BulkPreviewGrid = New-StdGrid -X 4 -Y 4 -W ($TW-($PAD*2)-10) -H ($PREV_H-30) -Parent $prevSec
    # LOCAL override only - New-StdGrid (Services.AD.Reporting) still
    # defaults every other grid in this app to ReadOnly=$true. This is the
    # one grid in the app the admin is meant to edit before acting on it.
    $script:BulkPreviewGrid.ReadOnly = $false

    $LOG_Y  = $PREV_Y + $PREV_H + $PAD; $LOG_H = $TH - $LOG_Y - ($PAD*2)
    $logSec = New-SectionPanel -Parent $Tab -Title 'Import Results' `
        -X $PAD -Y $LOG_Y -W ($TW-($PAD*2)) -H $LOG_H

    $script:BulkRtb              = New-Object System.Windows.Forms.RichTextBox
    $script:BulkRtb.Dock         = 'Fill'; $script:BulkRtb.Font = $F_MONO
    $script:BulkRtb.ReadOnly     = $true
    $script:BulkRtb.BackColor    = [System.Drawing.Color]::FromArgb(245,248,252)
    $script:BulkRtb.BorderStyle  = 'None'
    $logSec.Controls.Add($script:BulkRtb)

    $btnBrowse.Add_Click({
        $ofd        = New-Object System.Windows.Forms.OpenFileDialog
        $ofd.Filter = 'CSV Files (*.csv)|*.csv|All Files (*.*)|*.*'
        $ofd.Title  = 'Select User Import CSV'
        if ($ofd.ShowDialog() -eq 'OK') {
            $script:BulkTbFile.Text = $ofd.FileName
            Show-BulkCSV -Path $ofd.FileName
            Update-BulkGroupsComboColumn
        }
    })
    $btnTemplate.Add_Click({ Save-BulkTemplate })
    $btnPreview.Add_Click({
        if ($script:BulkTbFile.Text) {
            Show-BulkCSV -Path $script:BulkTbFile.Text
            Update-BulkGroupsComboColumn
        }
    })
    $btnPickOU.Add_Click({
        if (Get-Command Show-OUPicker -ErrorAction SilentlyContinue) {
            $dn = Show-OUPicker -Context $script:ToolsCtx
            if ($dn) { $script:BulkTbOU.Text = $dn }
        }
    })
    $btnImport.Add_Click({
        if (-not $script:BulkPreviewGrid -or $script:BulkPreviewGrid.Rows.Count -eq 0) {
            Write-BulkLog 'Preview a CSV first - nothing in the grid to import.' 'warn'
            return
        }
        $script:BulkPreviewGrid.EndEdit()
        $defaultOU = $script:BulkTbOU.Text.Trim()
        if (-not (Confirm-Action -Title 'Bulk User Import' `
            -Message "Import $($script:BulkPreviewGrid.Rows.Count) row(s) currently shown in the CSV Preview grid.`n`nThis will create AD accounts using whatever is currently in each cell - edits are included. All creations are logged." `
            -ActionLabel 'Import')) { return }
        $mailMode = if (Get-Command Get-MailModeSelection -ErrorAction SilentlyContinue) {
            Get-MailModeSelection -Selector $script:BulkMailModeSelector
        } else { 'AdminOnly' }
        $gridRows = Get-GridRowsAsObjects -Grid $script:BulkPreviewGrid
        Invoke-BulkOnboard -Rows $gridRows -DefaultOU $defaultOU -MailMode $mailMode
    })

    # Tab-leave reset (see module header).
    if (-not ($Tab.Tag -is [hashtable])) { $Tab.Tag = @{} }
    if (-not $Tab.Tag.ContainsKey('Resets')) {
        $Tab.Tag['Resets'] = New-Object System.Collections.Generic.List[scriptblock]
    }
    $Tab.Tag['Resets'].Add({
        if ($script:BulkTbFile) { $script:BulkTbFile.Text = '' }
        if ($script:BulkPreviewGrid) {
            $script:BulkPreviewGrid.Rows.Clear()
            $script:BulkPreviewGrid.Columns.Clear()
        }
        if ($script:BulkRtb) { $script:BulkRtb.Clear() }
    })
}
#endregion

#region -- Update-BulkGroupsComboColumn (private) -----------------------------
function Update-BulkGroupsComboColumn {
    <#
    .SYNOPSIS
        Converts the plain-text CopyGroupsFrom column (as built by
        Set-GridData inside Show-BulkCSV) into a real dropdown of this
        domain's cached users, preserving each row's current cell value
        where it still matches an available name. See module header for why
        Items are plain SamAccountName strings, not "Display (SAM)". Must be
        called again after every Show-BulkCSV call, since Set-GridData
        rebuilds every column as plain text on each reload.
        A real module function (NOT a scriptblock variable) so it resolves
        by ordinary command lookup from Build-BulkTab's plain, non-closure
        Add_Click handlers - see module header ("Changes") for the bug this
        avoids. Not exported - internal to this module only.
    #>
    if (-not $script:BulkPreviewGrid -or -not $script:BulkPreviewGrid.Columns.Contains('CopyGroupsFrom')) { return }
    $idx = $script:BulkPreviewGrid.Columns['CopyGroupsFrom'].Index

    $names = [System.Collections.Generic.List[string]]::new()
    [void]$names.Add('')
    if (Get-Command Get-CachedUsers -ErrorAction SilentlyContinue) {
        try {
            foreach ($u in (@(Get-CachedUsers) | Sort-Object SamAccountName)) {
                if ($u.SamAccountName) { [void]$names.Add([string]$u.SamAccountName) }
            }
        } catch { }
    }

    $existing = [System.Collections.Generic.List[string]]::new()
    foreach ($r in $script:BulkPreviewGrid.Rows) { [void]$existing.Add([string]$r.Cells[$idx].Value) }

    $script:BulkPreviewGrid.Columns.RemoveAt($idx)
    $comboCol            = New-Object System.Windows.Forms.DataGridViewComboBoxColumn
    $comboCol.Name       = 'CopyGroupsFrom'
    $comboCol.HeaderText = 'CopyGroupsFrom'
    $comboCol.FlatStyle  = 'Flat'
    foreach ($n in $names) { [void]$comboCol.Items.Add($n) }
    $script:BulkPreviewGrid.Columns.Insert($idx, $comboCol)

    for ($i = 0; $i -lt $script:BulkPreviewGrid.Rows.Count -and $i -lt $existing.Count; $i++) {
        $val = $existing[$i]
        $script:BulkPreviewGrid.Rows[$i].Cells[$idx].Value = if ($val -and $names.Contains($val)) { $val } else { '' }
    }
}
#endregion

#region -- Update-BulkOnboardDomainDefaults ------------------------------------
function Update-BulkOnboardDomainDefaults {
    <#
    .SYNOPSIS
        Re-applies this domain's saved Default Bulk Onboard OU (Tools >
        Domain Defaults) to the already-built Bulk Onboarding tab, without
        requiring the tab to be rebuilt or re-entered. Called by the Domain
        Defaults tab's Save button so a save takes effect immediately in the
        same running session.
    .DESCRIPTION
        Overwrites the field with the newly saved value if it is EITHER
        currently blank OR still holds exactly the value this function (or
        the build-time seed) last auto-applied - tracked via
        $script:UALastBulkOnboardOUDefault. If the operator has since picked
        a different OU via Browse (or typed one), it is left alone.
        A plain "only if blank" rule doesn't actually give a live refresh in
        the common case: once a domain has ANY saved Bulk Onboard OU, the
        field is never blank again, so a LATER change to that same OU would
        silently stop taking effect here even without an operator's edit -
        see the identical bug (and this same fix) in
        ADUserActions.CreateUser.Tab's Update-CreateUserDomainDefaults.
        Safe no-op if the tab hasn't been built yet, the domain isn't
        connected, or Services.DomainDefaults.Config isn't loaded.
    #>
    if (-not $script:BulkTbOU) { return }
    if (-not $script:ToolsCtx -or -not $script:ToolsCtx.Domain) { return }
    if (-not (Get-Command Get-DomainDefaults -ErrorAction SilentlyContinue)) { return }

    $ou = ''
    try { $ou = [string](Get-DomainDefaults -Domain $script:ToolsCtx.Domain).DefaultBulkOnboardOU } catch { }
    if ($ou) {
        if ($script:BulkTbOU.Text -eq '' -or $script:BulkTbOU.Text -eq $script:UALastBulkOnboardOUDefault) {
            $script:BulkTbOU.Text = $ou
        }
        $script:UALastBulkOnboardOUDefault = $ou
    }
}
#endregion

Export-ModuleMember -Function Build-BulkTab, Update-BulkOnboardDomainDefaults
