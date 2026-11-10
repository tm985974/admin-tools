#region -- ADAudit.Naming.Tab.psm1 -----------------------------------------------
# Concern : Build-NamingTab - constructs the Naming Convention tab: OU picker
#           + manual Display Suffix textbox + Scan button, Fix Display Name /
#           Fix Canonical Name / Fix SAM Uppercase / Export CSV / Export HTML
#           buttons, and the results grid (DataGridView, First/Last/
#           Description columns inline-editable). Right-click on the grid
#           offers bulk Set/Clear Description.
#           Show-NamingDescriptionPrompt - private themed input dialog (same
#           chrome as Confirm-Action) used by the bulk "Set Description"
#           context menu action. Not a MessageBox; the project's own free-
#           text prompt, keeping the "no MessageBox outside confirmation"
#           rule while still allowing bulk text entry.
#           Sets $script:NamingGrid, $script:NamingOUBox, $script:NamingSuffixBox,
#           $script:NamingSummaryLbl (read by ADAudit.Naming.Query and
#           ADAudit.Naming.Repair).
# Load order: depends on ADAudit.Naming.Query (Invoke-NamingScan,
#                        Get-NamingGridData), ADAudit.Naming.Repair
#                        (Invoke-NamingFix*, Invoke-NamingCellCommit,
#                        Invoke-NamingBulkDescription), ADUserActions.OUPicker.Dialog
#                        (Show-OUPicker), ADDirectory.Context.Common
#                        (New-MenuItem), Services.AD.Reporting
#                        (New-SectionPanel, New-StdButton, New-StdGrid,
#                        Set-Placeholder, Get-PlaceholderValue, Export-ToCSV,
#                        Export-ToHTML, Show-ExportResult).
# Scan scope: SearchScope Subtree (set in ADAudit.Naming.Query). Display
#             Suffix is a manual textbox only - no source-file auto-detection.
# Changes  : Fix button enable logic rebuilt (2nd pass). First pass replaced
#            the old "any row selected enables all three" logic with a
#            nested Update-NamingFixButtonStates function referencing local
#            $btnFixDN/$btnFixCN/$btnFixSAM - this reproduced the exact same
#            symptom (buttons never enable) because both the update function
#            and the button variables were scoped to a single call of
#            Build-NamingTab, unlike every other control in this file that
#            needs to be reached from an event handler after the function
#            returns ($script:NamingGrid, $script:NamingOUBox,
#            $script:NamingSuffixBox, $script:NamingSummaryLbl - all
#            script-scoped). Fixed by following that same established
#            pattern: $script:NamingBtnFixDN/CN/SAM (script-scoped, like the
#            grid and textboxes above) and Update-NamingFixButtonStates
#            promoted to a top-level module function (like Invoke-NamingScan,
#            Invoke-NamingCellCommit, etc. - all proven to resolve correctly
#            from inline event handlers elsewhere in this file). Each button
#            enables only if a currently selected row has that specific
#            violation (DNViolation/CNViolation/SAMViolation), and state is
#            recomputed on SelectionChanged, CellClick, and RowEnter.
#            RELOCATED from being its own main-level tab to a sub-tab of
#            Tools (ADTools.Register-ToolsTab). Build-NamingTab's sizing
#            source changed from $Context.TabW/$Context.TabH (correct for a
#            main-level tab, its old home) to $script:_TW/$script:_TH - the
#            same pattern every other Tools/Infrastructure sub-tab already
#            uses, set by whichever registrar hosts it. Hosted directly
#            against $Context.TabW/TabH (the FULL main-tab dimensions)
#            would have made this page think it had more room than its
#            actual sub-tab page really gives it, clipping content - the
#            same $TAB_STRIP_H bug class already fixed in
#            ADBulkOps.Register-BulkOpsTab/ADInfrastructure.Register-
#            InfrastructureTab/ADTools.Register-ToolsTab. -Context is still
#            accepted and still stored as $script:NamingCtx unchanged - it's
#            only the TW/TH SOURCE that changed, not what's read from
#            Context otherwise.
#endregion

#region -- Shared script-scope state (Naming tab) --------------------------------
$script:NamingCtx        = $null
$script:NamingTab        = $null
$script:NamingGrid       = $null
$script:NamingOUBox      = $null
$script:NamingSuffixBox  = $null
$script:NamingSummaryLbl = $null
$script:NamingEditOldVal = $null
$script:NamingBtnFixDN   = $null
$script:NamingBtnFixCN   = $null
$script:NamingBtnFixSAM  = $null
#endregion

#region -- Update-NamingFixButtonStates ------------------------------------------
function Update-NamingFixButtonStates {
    <#
    .SYNOPSIS
        Enables each Fix button only if at least one currently selected row
        in $script:NamingGrid has that specific violation (DNViolation /
        CNViolation / SAMViolation non-empty). No-ops safely before the grid
        has been scanned (columns not yet present) or before the tab has
        been built ($script:NamingBtnFixDN etc. still $null).
    #>
    if (-not $script:NamingGrid -or -not $script:NamingBtnFixDN) { return }

    $hasDN  = $false
    $hasCN  = $false
    $hasSAM = $false
    $cols   = $script:NamingGrid.Columns
    if ($cols.Contains('DNViolation') -and $cols.Contains('CNViolation') -and $cols.Contains('SAMViolation')) {
        foreach ($row in $script:NamingGrid.SelectedRows) {
            if (-not $hasDN  -and [string]$row.Cells['DNViolation'].Value  -ne '') { $hasDN  = $true }
            if (-not $hasCN  -and [string]$row.Cells['CNViolation'].Value  -ne '') { $hasCN  = $true }
            if (-not $hasSAM -and [string]$row.Cells['SAMViolation'].Value -ne '') { $hasSAM = $true }
            if ($hasDN -and $hasCN -and $hasSAM) { break }
        }
    }
    $script:NamingBtnFixDN.Enabled  = $hasDN
    $script:NamingBtnFixCN.Enabled  = $hasCN
    $script:NamingBtnFixSAM.Enabled = $hasSAM
}
#endregion

#region -- Show-NamingDescriptionPrompt (private) ---------------------------------
function Show-NamingDescriptionPrompt {
    param([string]$DefaultValue = '', [int]$Count = 1)

    $F_UI   = New-Object System.Drawing.Font('Segoe UI', 9)
    $F_UI_B = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $F_13B  = New-Object System.Drawing.Font('Segoe UI', 13, [System.Drawing.FontStyle]::Bold)

    $dlg                 = New-Object System.Windows.Forms.Form
    $dlg.Text            = 'Set Description'
    $dlg.ClientSize      = New-Object System.Drawing.Size(460, 180)
    $dlg.FormBorderStyle = 'FixedSingle'
    $dlg.MaximizeBox     = $false
    $dlg.StartPosition   = 'CenterParent'
    $dlg.BackColor       = [System.Drawing.Color]::FromArgb(235,238,242)

    $pTitle           = New-Object System.Windows.Forms.Panel
    $pTitle.Dock      = 'Top'; $pTitle.Height = 48
    $pTitle.BackColor = [System.Drawing.Color]::FromArgb(0,99,177)
    $dlg.Controls.Add($pTitle)

    $lT           = New-Object System.Windows.Forms.Label
    $lT.Text      = '   Set Description'
    $lT.Dock      = 'Fill'; $lT.Font = $F_13B
    $lT.ForeColor = [System.Drawing.Color]::White
    $lT.TextAlign = 'MiddleLeft'
    $pTitle.Controls.Add($lT)

    $lMsg           = New-Object System.Windows.Forms.Label
    $lMsg.Text      = "Enter Description to apply to $Count selected account(s):`n(leave blank to clear)"
    $lMsg.Location  = New-Object System.Drawing.Point(16, 58)
    $lMsg.Size      = New-Object System.Drawing.Size(428, 36)
    $lMsg.Font      = $F_UI
    $lMsg.ForeColor = [System.Drawing.Color]::FromArgb(40,40,40)
    $dlg.Controls.Add($lMsg)

    $tb          = New-Object System.Windows.Forms.TextBox
    $tb.Location = New-Object System.Drawing.Point(16, 98)
    $tb.Size     = New-Object System.Drawing.Size(428, 24)
    $tb.Font     = $F_UI
    $tb.Text     = $DefaultValue
    $dlg.Controls.Add($tb)

    $btnOK              = New-Object System.Windows.Forms.Button
    $btnOK.Text         = 'OK'
    $btnOK.Location     = New-Object System.Drawing.Point(268, 138)
    $btnOK.Size         = New-Object System.Drawing.Size(90, 30)
    $btnOK.FlatStyle    = 'Standard'
    $btnOK.Font         = $F_UI_B
    $btnOK.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $dlg.Controls.Add($btnOK)

    $btnCancel              = New-Object System.Windows.Forms.Button
    $btnCancel.Text         = 'Cancel'
    $btnCancel.Location     = New-Object System.Drawing.Point(364, 138)
    $btnCancel.Size         = New-Object System.Drawing.Size(80, 30)
    $btnCancel.FlatStyle    = 'Standard'
    $btnCancel.Font         = $F_UI
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $dlg.Controls.Add($btnCancel)

    $dlg.AcceptButton = $btnOK
    $dlg.CancelButton = $btnCancel

    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $tb.Text }
    return $null
}
#endregion

#region -- Build-NamingTab ---------------------------------------------------------
function Build-NamingTab {
    param(
        [System.Windows.Forms.TabPage]$Tab,
        [PSCustomObject]$Context
    )
    $script:NamingCtx = $Context
    $script:NamingTab = $Tab

    $PAD  = 8
    $F_UI = New-Object System.Drawing.Font('Segoe UI', 9)
    $F_UI_B = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $TW   = $script:_TW
    $TH   = $script:_TH

    $SEC_H = $TH - ($PAD * 2)
    $sec   = New-SectionPanel -Parent $Tab -Title 'Naming Convention Scan' `
        -X $PAD -Y $PAD -W ($TW - ($PAD * 2)) -H $SEC_H
    $innerW = ($TW - ($PAD * 2)) - 2

    # -- Row 1: OU picker, display suffix, scan, summary ---------------------
    $lblOU          = New-Object System.Windows.Forms.Label
    $lblOU.Text     = 'OU:'
    $lblOU.Location = New-Object System.Drawing.Point(6, 8)
    $lblOU.Size     = New-Object System.Drawing.Size(24, 20)
    $lblOU.Font     = $F_UI
    $sec.Controls.Add($lblOU)

    $script:NamingOUBox           = New-Object System.Windows.Forms.TextBox
    $script:NamingOUBox.Location  = New-Object System.Drawing.Point(32, 6)
    $script:NamingOUBox.Size      = New-Object System.Drawing.Size(430, 24)
    $script:NamingOUBox.Font      = $F_UI
    $script:NamingOUBox.ReadOnly  = $true
    $script:NamingOUBox.BackColor = [System.Drawing.Color]::FromArgb(245,245,245)
    $sec.Controls.Add($script:NamingOUBox)

    $btnPickOU = New-StdButton -Text 'Browse...' -X 468 -Y 6 -W 76 -H 26 -Parent $sec

    $lblSfx          = New-Object System.Windows.Forms.Label
    $lblSfx.Text     = 'Display suffix:'
    $lblSfx.Location = New-Object System.Drawing.Point(552, 8)
    $lblSfx.Size     = New-Object System.Drawing.Size(90, 20)
    $lblSfx.Font     = $F_UI
    $sec.Controls.Add($lblSfx)

    $script:NamingSuffixBox          = New-Object System.Windows.Forms.TextBox
    $script:NamingSuffixBox.Location = New-Object System.Drawing.Point(646, 6)
    $script:NamingSuffixBox.Size     = New-Object System.Drawing.Size(140, 24)
    $script:NamingSuffixBox.Font     = $F_UI
    Set-Placeholder -TextBox $script:NamingSuffixBox -Text 'e.g. IT'
    $sec.Controls.Add($script:NamingSuffixBox)

    $btnScan         = New-StdButton -Text 'Scan' -X 794 -Y 6 -W 100 -H 26 -Parent $sec
    $btnScan.Font    = $F_UI_B

    $script:NamingSummaryLbl           = New-Object System.Windows.Forms.Label
    $script:NamingSummaryLbl.Text      = 'No scan yet.'
    $script:NamingSummaryLbl.Location  = New-Object System.Drawing.Point(($innerW - 428), 8)
    $script:NamingSummaryLbl.Size      = New-Object System.Drawing.Size(420, 20)
    $script:NamingSummaryLbl.Font      = $F_UI_B
    $script:NamingSummaryLbl.ForeColor = [System.Drawing.Color]::DimGray
    $script:NamingSummaryLbl.TextAlign = 'MiddleRight'
    $sec.Controls.Add($script:NamingSummaryLbl)

    # -- Row 2: fix / export buttons ------------------------------------------
    # Script-scoped (not local) so Update-NamingFixButtonStates - a top-level
    # function, not nested in this one - can reach them after this function
    # returns. Matches the existing pattern used for $script:NamingGrid etc.
    $script:NamingBtnFixDN            = New-StdButton -Text 'Fix Display Name' -X 6 -Y 38 -W 140 -H 26 -Parent $sec
    $script:NamingBtnFixDN.Font       = $F_UI_B
    $script:NamingBtnFixDN.ForeColor  = [System.Drawing.Color]::FromArgb(0,80,160)
    $script:NamingBtnFixDN.Enabled    = $false

    $script:NamingBtnFixCN            = New-StdButton -Text 'Fix Canonical Name' -X 154 -Y 38 -W 150 -H 26 -Parent $sec
    $script:NamingBtnFixCN.Font       = $F_UI_B
    $script:NamingBtnFixCN.ForeColor  = [System.Drawing.Color]::FromArgb(0,80,160)
    $script:NamingBtnFixCN.Enabled    = $false

    $script:NamingBtnFixSAM           = New-StdButton -Text 'Fix SAM Uppercase' -X 312 -Y 38 -W 148 -H 26 -Parent $sec
    $script:NamingBtnFixSAM.Font      = $F_UI_B
    $script:NamingBtnFixSAM.ForeColor = [System.Drawing.Color]::FromArgb(0,80,160)
    $script:NamingBtnFixSAM.Enabled   = $false

    $btnExportCSV  = New-StdButton -Text 'Export CSV'  -X 468 -Y 38 -W 100 -H 26 -Parent $sec
    $btnExportHTML = New-StdButton -Text 'Export HTML' -X 576 -Y 38 -W 100 -H 26 -Parent $sec

    # -- Results grid ----------------------------------------------------------
    $GRID_Y = 70
    $GRID_H = $SEC_H - $GRID_Y - 10
    $script:NamingGrid = New-StdGrid -X 6 -Y $GRID_Y -W ($innerW - 12) -H $GRID_H -Parent $sec
    $script:NamingGrid.MultiSelect   = $true
    $script:NamingGrid.SelectionMode = 'FullRowSelect'

    # -- Right-click context menu: bulk Description set/clear ------------------
    $ctxMenu      = New-Object System.Windows.Forms.ContextMenuStrip
    $ctxMenu.Font = $F_UI

    [void]$ctxMenu.Items.Add((New-MenuItem -Text 'Set Description for selected...' -Action {
        $rows = @($script:NamingGrid.SelectedRows)
        if ($rows.Count -eq 0) { return }
        $existing = [string]$rows[0].Cells['Description'].Value
        $val = Show-NamingDescriptionPrompt -DefaultValue $existing -Count $rows.Count
        if ($null -eq $val) { return }
        Invoke-NamingBulkDescription -Rows $rows -Value $val
    }))
    [void]$ctxMenu.Items.Add((New-MenuItem -Text 'Clear Description for selected' -Action {
        $rows = @($script:NamingGrid.SelectedRows)
        if ($rows.Count -eq 0) { return }
        Invoke-NamingBulkDescription -Rows $rows -Clear
    }))
    $ctxMenu.Add_Opening({
        param($s2, $e2)
        if ($script:NamingGrid.SelectedRows.Count -eq 0) { $e2.Cancel = $true }
    })
    $script:NamingGrid.ContextMenuStrip = $ctxMenu

    $script:NamingGrid.Add_MouseDown({
        param($s, $e)
        if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Right) { return }
        $hit = $script:NamingGrid.HitTest($e.X, $e.Y)
        if ($hit.RowIndex -ge 0 -and -not $script:NamingGrid.Rows[$hit.RowIndex].Selected) {
            $script:NamingGrid.ClearSelection()
            $script:NamingGrid.Rows[$hit.RowIndex].Selected = $true
        }
    })

    # -- Inline edit commit (FirstName / LastName / Description) ---------------
    $script:NamingGrid.Add_CellBeginEdit({
        param($s, $e)
        $script:NamingEditOldVal = $script:NamingGrid.Rows[$e.RowIndex].Cells[$e.ColumnIndex].Value
    })
    $script:NamingGrid.Add_CellEndEdit({
        param($s, $e)
        if ($e.RowIndex -lt 0 -or $e.ColumnIndex -lt 0) { return }
        $row     = $script:NamingGrid.Rows[$e.RowIndex]
        $colName = $script:NamingGrid.Columns[$e.ColumnIndex].Name
        Invoke-NamingCellCommit -Row $row -ColumnName $colName -OldValue $script:NamingEditOldVal
    })

    # -- Fix button enable/disable - per-violation-type gating ------------------
    # Update-NamingFixButtonStates is a top-level function (see top of this
    # file) - not nested here - so it resolves reliably from these inline
    # event handlers the same way Invoke-NamingScan and Invoke-NamingCellCommit
    # do elsewhere in this file. Wired to SelectionChanged, CellClick, and
    # RowEnter together so state updates on an ordinary row click regardless
    # of which event actually fires first for that click.
    $script:NamingGrid.Add_SelectionChanged({ Update-NamingFixButtonStates })
    $script:NamingGrid.Add_CellClick({ Update-NamingFixButtonStates })
    $script:NamingGrid.Add_RowEnter({ Update-NamingFixButtonStates })

    # -- Button click wiring -----------------------------------------------------
    $btnPickOU.Add_Click({
        $dn = Show-OUPicker -Context $script:NamingCtx
        if ($dn) {
            $script:NamingOUBox.Text = $dn
            if (Get-Command Set-Status -ErrorAction SilentlyContinue) {
                Set-Status 'OU selected - click Scan to check naming.'
            }
        }
    })

    $btnScan.Add_Click({ Invoke-NamingScan })

    $script:NamingBtnFixDN.Add_Click({ Invoke-NamingFixDisplayName -Rows @($script:NamingGrid.SelectedRows) })
    $script:NamingBtnFixCN.Add_Click({ Invoke-NamingFixCanonicalName -Rows @($script:NamingGrid.SelectedRows) })
    $script:NamingBtnFixSAM.Add_Click({ Invoke-NamingFixSamUppercase -Rows @($script:NamingGrid.SelectedRows) })

    $btnExportCSV.Add_Click({
        if ($script:NamingGrid.Rows.Count -eq 0) { return }
        $data = Get-NamingGridData
        $path = Export-ToCSV -Context $script:NamingCtx -Data $data -BaseName 'NamingViolations'
        Show-ExportResult -FilePath $path
    })
    $btnExportHTML.Add_Click({
        if ($script:NamingGrid.Rows.Count -eq 0) { return }
        $data = Get-NamingGridData
        $sub  = "Domain: $($script:NamingCtx.Domain)  |  OU: $($script:NamingOUBox.Text)"
        $path = Export-ToHTML -Context $script:NamingCtx -Title 'Naming Convention Violations' `
            -Subtitle $sub -Data $data -BaseName 'NamingViolations'
        Show-ExportResult -FilePath $path
    })
}
#endregion

Export-ModuleMember -Function `
    Build-NamingTab, `
    Show-NamingDescriptionPrompt, `
    Update-NamingFixButtonStates
