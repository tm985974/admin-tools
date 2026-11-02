#region -- ADAudit.ListReports.Tab.psm1 ----------------------------------------
# Concern : Building blocks for the Audit tab's dashboard redesign:
#           New-AuditReportPopup - builds ONE report's full drill-in window:
#             Refresh + Export HTML buttons, an info label, and the full
#             sortable/actionable results grid - what used to be a
#             permanent tab page (Build-AuditListPage) is now a reusable
#             popup Form, built once per report and shown/hidden (never
#             disposed) for the rest of the session so its grid - and
#             therefore $script:AudGrids[$GridKey] - stays the SAME object
#             throughout, no matter how many times the admin opens and
#             closes it.
#           Build-AuditCard - builds ONE dashboard summary card: title,
#             a colored count badge, a lightweight label-based preview of
#             the top few rows (not a real grid - the sortable/actionable
#             one is one click away in the popup), and a click handler
#             (wired on the card AND every child label, since a click on a
#             child control does not bubble up to its parent Panel's own
#             Click event in WinForms) that shows the report's popup.
#           Add-AuditGridActions - unchanged from the tab-page version:
#             wires the right-click context menu and row-select-on-right-
#             click MouseDown handler onto one grid, generalizing
#             ADDirectory.Users.Menu's Register-UserGridMenu pattern to
#             work with any of the three existing menu factories against an
#             arbitrary grid, not just the Directory tab's own grids.
# Load order: 89d - depends on ADAudit.ListReports.Query.Users/Computers/Groups
#                   (the Invoke-*Audit functions passed in as -QueryFn),
#                   ADDirectory.Menus (New-UserContextMenu, New-ComputerContextMenu,
#                                      New-GroupContextMenu),
#                   Services.AD.Reporting (New-SectionPanel, New-StdButton,
#                                          New-StdGrid, Get-GridRowsAsObjects,
#                                          Export-ToHTML, Show-ExportResult)
#                   Must load before ADAudit.Register-AuditTab (90), which
#                   calls New-AuditReportPopup and Build-AuditCard once per
#                   report.
# Split from: ADAudit.ListReports.Tab.psm1 (dashboard rewrite - previous
#             version built ten permanent TabPage sub-pages; see Changes)
#
# Shared script-scope state (declared here, read/written by every
# ADAudit.ListReports.Query.* module and by ADAudit.Register-AuditTab):
#   $script:AudGrids  - hashtable, ReportKey -> DataGridView. Each
#                        Invoke-*Audit function looks up its own grid by key
#                        (e.g. $script:AudGrids['stale']) rather than a
#                        dedicated $script:XyzGrid variable per report. This
#                        is UNCHANGED from the tab-page version - the ten
#                        Invoke-*Audit query functions needed zero code
#                        changes for the dashboard redesign, since they only
#                        ever cared about finding "the current grid for my
#                        key", never about what container that grid lives
#                        in.
#   $script:AudPopups - hashtable, ReportKey -> Form. The report's popup,
#                        built once (lazily, on first dashboard render) and
#                        cached here for the rest of the session.
#   Both are initialised (= @{}) in ADAudit.Register-AuditTab.
#
# Changes (dashboard redesign):
#   Build-AuditListPage (permanent TabPage per report) is retired, replaced
#   by New-AuditReportPopup (a reusable popup Form) + Build-AuditCard (the
#   dashboard tile that opens it). The full grid's Refresh/Export/right-
#   click-action behavior is unchanged - only its container changed, from a
#   permanent tab page to an on-demand popup.
#   Popup reuse mechanic: a popup is shown via .Show() (non-modal), not
#   .ShowDialog(). This is a technical necessity, not a style choice -
#   WinForms does not support calling .ShowDialog() more than once on the
#   same Form instance, and building a fresh Form on every single card
#   click would mean either re-registering $script:AudGrids[$GridKey] to a
#   throwaway grid each time (harmless on its own, but see next point) or
#   accepting that closing the popup disposes it, breaking the SAME-OBJECT
#   guarantee Get-GridRowsAsObjects/Add-AuditGridActions were built against.
#   The popup's own FormClosing handler cancels the close and Hides instead,
#   so the underlying grid and its data survive being closed and reopened
#   any number of times in one session.
#endregion

#region -- Add-AuditGridActions -------------------------------------------------
function Add-AuditGridActions {
    <#
    .SYNOPSIS
        Wires the appropriate right-click context menu (User/Computer/Group)
        onto an Audit report's grid, plus the same "right-click selects the
        row under the cursor first" MouseDown handler the Directory tab's
        own grids use. A no-op if $Grid is $null or $EntityType is blank
        (some report might reasonably have no applicable quick actions).
    .PARAMETER Grid
        The populated DataGridView to attach the menu to.
    .PARAMETER EntityType
        'User', 'Computer', or 'Group' - selects which of the three existing
        menu factories in ADDirectory.Menus to use.
    .PARAMETER Context
        Shared context object, passed straight through to the menu factory.
    #>
    param(
        [System.Windows.Forms.DataGridView]$Grid,
        [ValidateSet('User','Computer','Group','')]
        [string]$EntityType = '',
        [PSCustomObject]$Context
    )
    if (-not $Grid -or -not $EntityType) { return }

    # Cross-module function calls from inside the .GetNewClosure() provider
    # blocks below are unreliable by bare name in this codebase (see
    # ADDirectory.Register-DirectoryTab) - capture here, invoke via & inside.
    $newUserMenuFn     = ${function:New-UserContextMenu}
    $newComputerMenuFn = ${function:New-ComputerContextMenu}
    $newGroupMenuFn    = ${function:New-GroupContextMenu}
    $localGrid         = $Grid
    $capturedContext   = $Context

    $provider = switch ($EntityType) {
        'User' {
            {
                $out = @()
                foreach ($row in $localGrid.SelectedRows) {
                    $v = $row.Cells['SamAccountName'].Value
                    if ($v) { $out += [PSCustomObject]@{ Sam = [string]$v; Display = [string]$row.Cells['DisplayName'].Value } }
                }
                $out
            }.GetNewClosure()
        }
        'Computer' {
            {
                $out = @()
                foreach ($row in $localGrid.SelectedRows) {
                    $v = $row.Cells['Name'].Value
                    if ($v) { $out += [PSCustomObject]@{ Name = [string]$v } }
                }
                $out
            }.GetNewClosure()
        }
        'Group' {
            {
                $out = @()
                foreach ($row in $localGrid.SelectedRows) {
                    $v = $row.Cells['Name'].Value
                    if ($v) { $out += [PSCustomObject]@{ Name = [string]$v; DN = '' } }
                }
                $out
            }.GetNewClosure()
        }
    }

    $Grid.ContextMenuStrip = switch ($EntityType) {
        'User'     { & $newUserMenuFn     -TargetProvider $provider -Context $capturedContext }
        'Computer' { & $newComputerMenuFn -TargetProvider $provider -Context $capturedContext }
        'Group'    { & $newGroupMenuFn    -TargetProvider $provider -Context $capturedContext }
    }

    $Grid.Add_MouseDown({
        param($s, $e)
        if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Right) { return }
        $hit = $localGrid.HitTest($e.X, $e.Y)
        if ($hit.RowIndex -ge 0 -and -not $localGrid.Rows[$hit.RowIndex].Selected) {
            $localGrid.ClearSelection()
            $localGrid.Rows[$hit.RowIndex].Selected = $true
        }
    }.GetNewClosure())
}
#endregion

#region -- New-AuditReportPopup -------------------------------------------------
function New-AuditReportPopup {
    <#
    .SYNOPSIS
        Builds one report's full drill-in popup: Refresh + Export HTML
        buttons, an info label, the full results grid (registered as
        $script:AudGrids[$GridKey]) with its right-click menu (if
        -EntityType is given), and a Close button. Built ONCE per report
        (see module header for why) - call this once at dashboard-render
        time and cache the returned Form; do not call it again for the same
        report.
    .PARAMETER GridKey
        Short unique key for this report (e.g. 'stale') - the grid is
        registered as $script:AudGrids[$GridKey] for the matching
        Invoke-*Audit query function to find.
    .PARAMETER PopupTitle
        Window title and Export HTML title for this report.
    .PARAMETER InfoText
        One-line description shown beside the buttons.
    .PARAMETER ExportBaseName
        Base filename for the HTML export (timestamp is appended by
        Export-ToHTML).
    .PARAMETER QueryFn
        A captured function reference (${function:Invoke-XyzAudit}) - NOT a
        bare scriptblock literal - for the query that populates this
        report's grid. See ADBulkOps.Register-BulkOpsTab for the fuller
        rationale on preferring a true function reference here.
    .PARAMETER EntityType
        'User', 'Computer', 'Group', or '' (no context menu) - passed
        straight through to Add-AuditGridActions.
    .PARAMETER Context
        Shared context object (TargetDC, AdminAccount, Domain).
    .OUTPUTS
        The built Form. Show it with .Show() (non-modal) - see module
        header for why .ShowDialog() cannot be used for a reused popup.
    #>
    param(
        [string]$GridKey,
        [string]$PopupTitle,
        [string]$InfoText,
        [string]$ExportBaseName,
        $QueryFn,
        [ValidateSet('User','Computer','Group','')]
        [string]$EntityType = '',
        [PSCustomObject]$Context
    )
    $F_UI = New-Object System.Drawing.Font('Segoe UI', 9)
    $PAD  = 10
    $PW   = 940
    $PH   = 640

    $dlg                 = New-Object System.Windows.Forms.Form
    $dlg.Text            = $PopupTitle
    $dlg.ClientSize      = New-Object System.Drawing.Size($PW, $PH)
    $dlg.FormBorderStyle = 'FixedSingle'
    $dlg.MaximizeBox     = $false
    $dlg.MinimizeBox     = $true
    $dlg.StartPosition   = 'CenterScreen'
    $dlg.BackColor       = [System.Drawing.Color]::FromArgb(235,238,242)
    $dlg.ShowInTaskbar   = $false

    $btnRefresh = New-StdButton -Text 'Refresh'     -X $PAD      -Y $PAD -W 90  -H 26 -Parent $dlg
    $btnExport  = New-StdButton -Text 'Export HTML' -X ($PAD+98) -Y $PAD -W 100 -H 26 -Parent $dlg

    $lInfo           = New-Object System.Windows.Forms.Label
    $lInfo.Text      = $InfoText
    $lInfo.Location  = New-Object System.Drawing.Point(($PAD+206), ($PAD+2))
    $lInfo.Size      = New-Object System.Drawing.Size(($PW-$PAD*2-216), 24)
    $lInfo.Font      = New-Object System.Drawing.Font('Segoe UI', 8)
    $lInfo.ForeColor = [System.Drawing.Color]::DimGray
    $dlg.Controls.Add($lInfo)

    $GRID_Y  = $PAD + 34
    $GRID_H  = $PH - $GRID_Y - $PAD - 40
    $gridSec = New-SectionPanel -Parent $dlg -Title 'Results' `
        -X $PAD -Y $GRID_Y -W ($PW-$PAD*2) -H $GRID_H
    $grid    = New-StdGrid -X 4 -Y 4 -W ($PW-$PAD*2-10) -H ($GRID_H-30) -Parent $gridSec

    $script:AudGrids[$GridKey] = $grid

    if ($EntityType) {
        Add-AuditGridActions -Grid $grid -EntityType $EntityType -Context $Context
    }

    $btnClose = New-StdButton -Text 'Close' -X ($PW-$PAD-90) -Y ($PH-$PAD-30) -W 90 -H 28 -Parent $dlg

    # Cross-module function calls / $script: variable reads from inside the
    # .GetNewClosure() blocks below are unreliable by bare name in this
    # codebase (see module header) - capture here, invoke via & or the
    # local reference inside.
    $getGridRowsFn      = ${function:Get-GridRowsAsObjects}
    $exportToHtmlFn     = ${function:Export-ToHTML}
    $showExportResultFn = ${function:Show-ExportResult}
    $capturedContext    = $Context
    $localGrid          = $grid
    $localQueryFn       = $QueryFn
    $localExportTitle   = $PopupTitle
    $localExportBase    = $ExportBaseName
    $localDlg           = $dlg

    $btnRefresh.Add_Click({ & $localQueryFn }.GetNewClosure())

    $btnExport.Add_Click({
        if ($localGrid.Rows.Count -eq 0) { return }
        $data = & $getGridRowsFn -Grid $localGrid
        $path = & $exportToHtmlFn -Context $capturedContext -Title $localExportTitle `
            -Subtitle "Domain: $($capturedContext.Domain)" -Data $data -BaseName $localExportBase
        & $showExportResultFn -FilePath $path
    }.GetNewClosure())

    $btnClose.Add_Click({ $localDlg.Hide() }.GetNewClosure())

    # Hide instead of actually closing - see module header for why this
    # popup must survive being "closed" any number of times.
    $dlg.Add_FormClosing({
        param($s, $e)
        if ($e.CloseReason -eq [System.Windows.Forms.CloseReason]::UserClosing) {
            $e.Cancel = $true
            $localDlg.Hide()
        }
    }.GetNewClosure())

    return $dlg
}
#endregion

#region -- Build-AuditCard ------------------------------------------------------
function Build-AuditCard {
    <#
    .SYNOPSIS
        Builds one dashboard summary card: title, a count badge, a
        lightweight preview of the top few rows (plain labels, not a real
        grid - the full sortable grid is one click away), and a click
        handler that shows the report's already-built popup.
    .PARAMETER Parent
        Container to add the card to (the dashboard's scrollable cards panel).
    .PARAMETER X
    .PARAMETER Y
    .PARAMETER W
    .PARAMETER H
        Card position/size.
    .PARAMETER Title
        Card heading (e.g. "Stale Users").
    .PARAMETER PreviewColumns
        1-2 property names to show per preview row - first column left-
        aligned (the identity, e.g. SamAccountName/Name), second column (if
        given) right-aligned (the "why it's here" value, e.g. Days).
    .PARAMETER PreviewHeaders
        Friendly column header(s) matching PreviewColumns 1-for-1 (e.g.
        'User'/'Days' for SamAccountName/DaysSinceLogon) - shown as a small
        bold header row above the preview data, same alignment as the data
        below it.
    .PARAMETER PreviewRows
        Already-limited (e.g. top 4) rows to render - this function does no
        filtering or sorting of its own.
    .PARAMETER Count
        Total row count for this report (may exceed PreviewRows.Count) -
        drives the badge color (red when > 0, green when 0) and the
        "+N more..." line.
    .PARAMETER Popup
        The report's already-built popup Form (from New-AuditReportPopup) -
        shown via .Show() when the card is clicked.
    #>
    param(
        [System.Windows.Forms.Control]$Parent,
        [int]$X, [int]$Y, [int]$W, [int]$H,
        [string]$Title,
        [string[]]$PreviewColumns,
        [string[]]$PreviewHeaders,
        [object[]]$PreviewRows,
        [int]$Count,
        [System.Windows.Forms.Form]$Popup
    )
    $F_TITLE = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
    $F_HDR   = New-Object System.Drawing.Font('Segoe UI', 8, [System.Drawing.FontStyle]::Bold)
    $F_ROW   = New-Object System.Drawing.Font('Consolas', 8.5)
    $F_HINT  = New-Object System.Drawing.Font('Segoe UI', 7.5)
    $F_NONE  = New-Object System.Drawing.Font('Segoe UI', 9)

    $card             = New-Object System.Windows.Forms.Panel
    $card.Location    = New-Object System.Drawing.Point($X, $Y)
    $card.Size        = New-Object System.Drawing.Size($W, $H)
    $card.BackColor   = [System.Drawing.Color]::White
    $card.Cursor      = [System.Windows.Forms.Cursors]::Hand
    $card.BorderStyle = 'FixedSingle'
    $Parent.Controls.Add($card)

    $lTitle           = New-Object System.Windows.Forms.Label
    $lTitle.Text      = $Title
    $lTitle.Location  = New-Object System.Drawing.Point(10, 8)
    $lTitle.Size      = New-Object System.Drawing.Size(($W-70), 22)
    $lTitle.Font      = $F_TITLE
    $lTitle.ForeColor = [System.Drawing.Color]::FromArgb(0,80,160)
    $lTitle.Cursor    = [System.Windows.Forms.Cursors]::Hand
    $card.Controls.Add($lTitle)

    $badgeColor          = if ($Count -gt 0) { [System.Drawing.Color]::FromArgb(200,60,60) } else { [System.Drawing.Color]::FromArgb(0,140,90) }
    $lCount              = New-Object System.Windows.Forms.Label
    $lCount.Text         = "$Count"
    $lCount.Location     = New-Object System.Drawing.Point(($W-54), 6)
    $lCount.Size         = New-Object System.Drawing.Size(44, 26)
    $lCount.Font         = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
    $lCount.ForeColor    = [System.Drawing.Color]::White
    $lCount.BackColor    = $badgeColor
    $lCount.TextAlign    = 'MiddleCenter'
    $lCount.Cursor       = [System.Windows.Forms.Cursors]::Hand
    $card.Controls.Add($lCount)

    $div           = New-Object System.Windows.Forms.Panel
    $div.Location  = New-Object System.Drawing.Point(10, 34)
    $div.Size      = New-Object System.Drawing.Size(($W-20), 1)
    $div.BackColor = [System.Drawing.Color]::FromArgb(220,225,235)
    $card.Controls.Add($div)

    $col1W = [int](($W-20) * 0.62)
    $col2W = ($W-20) - $col1W

    # Column header row - same left/right alignment as the data rows below,
    # shown even when there are no rows to preview (Count = 0) so the card's
    # shape stays consistent across every report.
    $hdrY = 40
    if ($PreviewHeaders.Count -gt 0) {
        $h1           = New-Object System.Windows.Forms.Label
        $h1.Text      = $PreviewHeaders[0]
        $h1.Location  = New-Object System.Drawing.Point(10, $hdrY)
        $h1.Size      = New-Object System.Drawing.Size($col1W, 16)
        $h1.Font      = $F_HDR
        $h1.ForeColor = [System.Drawing.Color]::FromArgb(120,130,145)
        $h1.Cursor    = [System.Windows.Forms.Cursors]::Hand
        $card.Controls.Add($h1)

        if ($PreviewHeaders.Count -gt 1) {
            $h2            = New-Object System.Windows.Forms.Label
            $h2.Text       = $PreviewHeaders[1]
            $h2.Location   = New-Object System.Drawing.Point((10+$col1W), $hdrY)
            $h2.Size       = New-Object System.Drawing.Size($col2W, 16)
            $h2.Font       = $F_HDR
            $h2.ForeColor  = [System.Drawing.Color]::FromArgb(120,130,145)
            $h2.TextAlign  = 'MiddleRight'
            $h2.Cursor     = [System.Windows.Forms.Cursors]::Hand
            $card.Controls.Add($h2)
        }
    }

    $rowY = $hdrY + 18
    if ($PreviewRows.Count -eq 0) {
        $lNone           = New-Object System.Windows.Forms.Label
        $lNone.Text      = 'None found'
        $lNone.Location  = New-Object System.Drawing.Point(10, $rowY)
        $lNone.Size      = New-Object System.Drawing.Size(($W-20), 20)
        $lNone.Font      = $F_NONE
        $lNone.ForeColor = [System.Drawing.Color]::FromArgb(0,140,90)
        $lNone.Cursor    = [System.Windows.Forms.Cursors]::Hand
        $card.Controls.Add($lNone)
    } else {
        foreach ($row in $PreviewRows) {
            $v1 = [string]$row.($PreviewColumns[0])
            if ($v1.Length -gt 26) { $v1 = $v1.Substring(0,24) + '...' }
            $l1          = New-Object System.Windows.Forms.Label
            $l1.Text     = $v1
            $l1.Location = New-Object System.Drawing.Point(10, $rowY)
            $l1.Size     = New-Object System.Drawing.Size($col1W, 18)
            $l1.Font     = $F_ROW
            $l1.Cursor   = [System.Windows.Forms.Cursors]::Hand
            $card.Controls.Add($l1)

            if ($PreviewColumns.Count -gt 1) {
                $v2          = [string]$row.($PreviewColumns[1])
                $l2          = New-Object System.Windows.Forms.Label
                $l2.Text     = $v2
                $l2.Location = New-Object System.Drawing.Point((10+$col1W), $rowY)
                $l2.Size     = New-Object System.Drawing.Size($col2W, 18)
                $l2.Font     = $F_ROW
                $l2.TextAlign = 'MiddleRight'
                $l2.Cursor   = [System.Windows.Forms.Cursors]::Hand
                $card.Controls.Add($l2)
            }
            $rowY += 19
        }
        if ($Count -gt $PreviewRows.Count) {
            $lMore           = New-Object System.Windows.Forms.Label
            $lMore.Text      = "+ $($Count - $PreviewRows.Count) more..."
            $lMore.Location  = New-Object System.Drawing.Point(10, $rowY)
            $lMore.Size      = New-Object System.Drawing.Size(($W-20), 16)
            $lMore.Font      = New-Object System.Drawing.Font('Segoe UI', 7.5, [System.Drawing.FontStyle]::Italic)
            $lMore.ForeColor = [System.Drawing.Color]::DimGray
            $lMore.Cursor    = [System.Windows.Forms.Cursors]::Hand
            $card.Controls.Add($lMore)
        }
    }

    $lHint           = New-Object System.Windows.Forms.Label
    $lHint.Text      = 'Click for details ->'
    $lHint.Location  = New-Object System.Drawing.Point(10, ($H-22))
    $lHint.Size      = New-Object System.Drawing.Size(($W-20), 16)
    $lHint.Font      = $F_HINT
    $lHint.ForeColor = [System.Drawing.Color]::FromArgb(0,80,160)
    $lHint.TextAlign = 'MiddleRight'
    $lHint.Cursor    = [System.Windows.Forms.Cursors]::Hand
    $card.Controls.Add($lHint)

    # Wire click on the panel AND every child control it currently holds -
    # a click on a child Label does not bubble up to the parent Panel's own
    # Click event in WinForms, so each child needs the same handler
    # explicitly wired, not just the panel itself.
    $capturedPopup = $Popup
    $clickHandler = {
        if ($capturedPopup) {
            $capturedPopup.Show()
            if ($capturedPopup.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized) {
                $capturedPopup.WindowState = [System.Windows.Forms.FormWindowState]::Normal
            }
            $capturedPopup.BringToFront()
            $capturedPopup.Activate()
        }
    }.GetNewClosure()
    $card.Add_Click($clickHandler)
    foreach ($ctl in @($card.Controls)) { $ctl.Add_Click($clickHandler) }
}
#endregion

Export-ModuleMember -Function New-AuditReportPopup, Build-AuditCard, Add-AuditGridActions
