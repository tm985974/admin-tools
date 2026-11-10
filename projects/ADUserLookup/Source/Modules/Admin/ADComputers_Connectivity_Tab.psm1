#region -- ADComputers.Connectivity.Tab.psm1 ----------------------------------
# Concern : Build-ConnectivityTab - constructs the Computers tab: status
#           cards, AD details RTB, and the whole-domain computers grid.
#           Loads the full domain computer list on tab Enter (now cached -
#           see Changes below). Cards reset to their blank dash state on
#           every tab Enter (not just the first).
#           Selecting a grid row updates Set-SelectedComputer (for RDP/
#           Radmin/Ping/MMC/etc on the right-click menu) but no longer
#           auto-runs the connectivity check - that is now a deliberate
#           "Test Connectivity" right-click action (New-ComputerContextMenu,
#           ADDirectory.Menus), since auto-checking on every selection made
#           the cards update from incidental clicks rather than intent.
#           Right-click on a row reuses New-ComputerContextMenu (Test
#           Connectivity, RDP, Radmin, Ping, MMC, BitLocker Recovery Key,
#           LAPS Password, Copy) - the same menu factory used elsewhere in
#           the app.
# Load order: 80 - depends on ADComputers.Connectivity.Scan (Invoke-ComputerCheck,
#                                                             Read-ConnComputers,
#                                                             script:AllConnComputers),
#                            ADComputers.Connectivity.TestPort (script scope),
#                            ADComputers.StatusCards.UI (Build-StatusCards),
#                            ADDirectory.Menus (New-ComputerContextMenu),
#                            Services.AD.Reporting (New-SectionPanel, New-StdGrid,
#                                                   New-StdButton, Set-GridData,
#                                                   Set-Placeholder, Get-PlaceholderValue)
# Split from: ADComputers.Tab.psm1
# Changes   : Removed the 'Target Computer' action-bar section (Computer
#             name textbox, Use Selected/Check/RDP/Radmin/Ping/Comp Mgmt/
#             Copy Name buttons, Extra ports box) - all of these actions now
#             live on the grid's right-click menu. Cards/AD-details/grid
#             shifted up to fill the reclaimed vertical space. Sub-tab
#             container removed by Register-ComputersTab; this is now the
#             only content built for the Computers tab.
#             Reverted: grid SelectionChanged no longer auto-runs the
#             connectivity check (was added, then found to update cards on
#             incidental selection rather than intent). 'Test Connectivity'
#             is back as an explicit right-click menu item instead. Cards
#             now reset to blank on every Add_Enter, including the first
#             time the tab is opened in a session.
#             Tab.Add_Enter now calls Read-ConnComputers without -Force -
#             the function itself (ADComputers.Connectivity.Scan) tracks
#             $script:ConnCompLoaded and only re-queries AD on first visit,
#             re-rendering the cached grid on subsequent visits. The
#             Refresh button still forces a real reload via -Force.
#             Added a 'Filter as I type' checkbox next to the list filter
#             box. Checked (default): filtering runs on every keystroke as
#             before. Unchecked: filtering only runs on Enter, for domains
#             where re-filtering a large whole-domain list on every letter
#             is noticeably slow. Toggling the checkbox back on immediately
#             re-applies whatever text is currently in the box.
#             Added Update-ComputersFilterDefault (exported) - called by the
#             Domain Defaults tab's Save button so a saved FilterAsYouType
#             change takes effect immediately in this running session.
#             $chkConnLive stays a local variable for the existing closures
#             (see inline comment) and is additionally exposed at
#             $script:ChkConnFilterLive for the new function to reach it.
#             Build-ConnectivityTab now takes a -Context parameter (was
#             Tab-only before) and passes it to New-ComputerContextMenu -
#             needed so this grid's Delete Computer(s) menu item can address
#             its admin tracking mail correctly. Register-ComputersTab
#             (ADComputers.Register-ComputersTab) updated to pass its own
#             -Context straight through.
#endregion

#region -- Shared script-scope state (Connectivity computers list) -----------
$script:ConnCompGrid       = $null
$script:ConnCompFilter     = $null
$script:ConnCompCmbFilter  = $null
$script:LblConnCompCount   = $null
$script:ConnCompSortCol    = 0
$script:ConnCompSortAsc    = $true
# Real initial value is set in Build-ConnectivityTab from the domain's saved
# FilterAsYouType default ($script:CompCtx isn't populated yet at module load
# time, so this module-scope default is just a safe fallback).
$script:ConnCompFilterLive = $true
#endregion

#region -- Get-FilteredConnComputers ------------------------------------------
function Get-FilteredConnComputers {
    <#
    .SYNOPSIS
        Filters/sorts $script:AllConnComputers for the Computers tab grid.
    #>
    $text = if ($script:ConnCompFilter) { (Get-PlaceholderValue -TextBox $script:ConnCompFilter).Trim().ToLower() } else { '' }
    $mode = if ($script:ConnCompCmbFilter) { [string]$script:ConnCompCmbFilter.SelectedItem } else { 'All Computers' }
    $filtered = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($c in $script:AllConnComputers) {
        if ($mode -eq 'Enabled Only'  -and $c.Enabled -ne 'True')  { continue }
        if ($mode -eq 'Disabled Only' -and $c.Enabled -ne 'False') { continue }
        if ($mode -eq 'Servers Only'       -and $c.OperatingSystem -notlike '*Server*') { continue }
        if ($mode -eq 'Workstations Only'  -and $c.OperatingSystem -like '*Server*')    { continue }
        if ($mode -eq 'Stale (90+ days)') {
            $stale = $false
            if ($c.LastLogon -and $c.LastLogon -ne 'Never') {
                try { if (([datetime]::Now - [datetime]$c.LastLogon).TotalDays -ge 90) { $stale = $true } } catch { }
            } elseif ($c.LastLogon -eq 'Never') { $stale = $true }
            if (-not $stale) { continue }
        }
        if ($text) {
            $hit = ($c.Name.ToLower()            -like "*$text*") -or
                   ($c.OperatingSystem.ToLower()  -like "*$text*") -or
                   ($c.Description.ToLower()      -like "*$text*")
            if (-not $hit) { continue }
        }
        [void]$filtered.Add($c)
    }
    $col  = @('Name','Enabled','OperatingSystem','OSVersion','LastLogon','IPv4Address',
              'Created','Description','OU','DistinguishedName')
    $prop = $col[$script:ConnCompSortCol % $col.Count]
    if ($script:ConnCompSortAsc) { return @($filtered | Sort-Object $prop) }
    else                         { return @($filtered | Sort-Object $prop -Descending) }
}
#endregion

#region -- Update-ConnCompGrid ------------------------------------------------
function Update-ConnCompGrid {
    if (-not $script:ConnCompGrid) { return }
    $data = Get-FilteredConnComputers
    $cols = @('Name','Enabled','OperatingSystem','OSVersion','LastLogon','IPv4Address',
              'Created','Description','OU','DistinguishedName')
    Set-GridData -Grid $script:ConnCompGrid -Data $data -Columns $cols
    if ($script:ConnCompGrid.Columns['DistinguishedName']) {
        $script:ConnCompGrid.Columns['DistinguishedName'].Visible = $false
    }
    foreach ($row in $script:ConnCompGrid.Rows) {
        if ($row.Cells['Enabled'].Value -eq 'False') {
            $row.DefaultCellStyle.ForeColor = [System.Drawing.Color]::FromArgb(160,160,160)
        }
    }
    if ($script:LblConnCompCount) {
        $script:LblConnCompCount.Text = "$($data.Count) of $($script:AllConnComputers.Count)"
    }
}
#endregion

#region -- Reset-ConnCompCards ------------------------------------------------
function Reset-ConnCompCards {
    <#
    .SYNOPSIS
        Resets the status cards to their default dash state. Called on every
        tab Add_Enter (so cards are always blank when the Computers tab is
        opened) and is also available for any caller that wants to clear
        stale results without running a new check.
    #>
    if (-not $script:CompCards) { return }
    $C_UNKN = [System.Drawing.Color]::FromArgb(230,240,255)
    $C_DIM  = [System.Drawing.Color]::DimGray
    foreach ($key in $script:CompCards.Keys) {
        $script:CompCards[$key].Panel.BackColor = $C_UNKN
        $script:CompCards[$key].Value.Text      = '-'
        $script:CompCards[$key].Value.ForeColor = $C_DIM
        $script:CompCards[$key].Ms.Text         = ''
    }
    if ($script:CompRtbDetails) { $script:CompRtbDetails.Clear() }
}
#endregion

#region -- Build-ConnectivityTab ----------------------------------------------
function Build-ConnectivityTab {
    param([System.Windows.Forms.TabPage]$Tab, [PSCustomObject]$Context)
    $PAD    = 8
    $F_UI   = New-Object System.Drawing.Font('Segoe UI', 9)
    $F_MONO = New-Object System.Drawing.Font('Consolas', 9)
    $TW     = $script:_TW
    $TH     = $script:_TH

    $CARD_Y = $PAD
    $CARD_H = 84
    $script:CompCards = Build-StatusCards -Tab $Tab -Y $CARD_Y

    $DETAIL_Y  = $CARD_Y + $CARD_H + $PAD
    $DETAIL_H  = 120
    $detailSec = New-SectionPanel -Parent $Tab -Title 'AD Computer Details' `
        -X $PAD -Y $DETAIL_Y -W ($TW-($PAD*2)) -H $DETAIL_H

    $script:CompRtbDetails              = New-Object System.Windows.Forms.RichTextBox
    $script:CompRtbDetails.Dock         = 'Fill'
    $script:CompRtbDetails.Font         = $F_MONO
    $script:CompRtbDetails.ReadOnly     = $true
    $script:CompRtbDetails.BackColor    = [System.Drawing.Color]::FromArgb(245,248,252)
    $script:CompRtbDetails.BorderStyle  = 'None'
    $detailSec.Controls.Add($script:CompRtbDetails)

    # Initial checked state for the list's "Filter as I type" checkbox, from
    # this domain's saved default (Tools > Domain Defaults). Read-only here -
    # toggling the checkbox during normal use never saves back.
    if ($script:CompCtx -and $script:CompCtx.Domain -and (Get-Command Get-DomainDefaults -ErrorAction SilentlyContinue)) {
        try { $script:ConnCompFilterLive = [bool](Get-DomainDefaults -Domain $script:CompCtx.Domain).FilterAsYouType }
        catch { }
    }

    # -------------------------------------------------------------------------
    # Computers list. Self-contained: whole domain, no OU scoping. Loads on
    # tab Enter (cached after first load - see Read-ConnComputers); selecting
    # exactly one row auto-runs the connectivity check.
    # -------------------------------------------------------------------------
    $LIST_Y  = $DETAIL_Y + $DETAIL_H + $PAD
    $LIST_H  = $TH - $LIST_Y - ($PAD*2)
    $listSec = New-SectionPanel -Parent $Tab -Title 'Computers (whole domain)' `
        -X $PAD -Y $LIST_Y -W ($TW-($PAD*2)) -H $LIST_H

    $innerW  = ($TW-($PAD*2)) - 2
    $COUNT_W = 160; $GAP = 8; $RPAD = 8
    $countX  = $innerW - $RPAD - $COUNT_W

    $lbLF             = New-Object System.Windows.Forms.Label
    $lbLF.Text        = 'Filter:'
    $lbLF.Location    = New-Object System.Drawing.Point(6, 6)
    $lbLF.Size        = New-Object System.Drawing.Size(38, 24)
    $lbLF.TextAlign   = 'MiddleLeft'
    $lbLF.Font        = $F_UI
    $listSec.Controls.Add($lbLF)

    $script:ConnCompFilter          = New-Object System.Windows.Forms.TextBox
    $script:ConnCompFilter.Location = New-Object System.Drawing.Point(46, 6)
    $script:ConnCompFilter.Size     = New-Object System.Drawing.Size(200, 24)
    $script:ConnCompFilter.Font     = $F_UI
    Set-Placeholder -TextBox $script:ConnCompFilter -Text 'Computer name / OS...'
    $listSec.Controls.Add($script:ConnCompFilter)

    $lbLS             = New-Object System.Windows.Forms.Label
    $lbLS.Text        = 'Show:'
    $lbLS.Location    = New-Object System.Drawing.Point(254, 6)
    $lbLS.Size        = New-Object System.Drawing.Size(38, 24)
    $lbLS.TextAlign   = 'MiddleLeft'
    $lbLS.Font        = $F_UI
    $listSec.Controls.Add($lbLS)

    $script:ConnCompCmbFilter = New-Object System.Windows.Forms.ComboBox
    $script:ConnCompCmbFilter.Location = New-Object System.Drawing.Point(294, 6)
    $script:ConnCompCmbFilter.Size     = New-Object System.Drawing.Size(160, 24)
    $script:ConnCompCmbFilter.DropDownStyle = 'DropDownList'
    $script:ConnCompCmbFilter.Font     = $F_UI
    @('All Computers','Enabled Only','Disabled Only','Servers Only','Workstations Only','Stale (90+ days)') |
        ForEach-Object { [void]$script:ConnCompCmbFilter.Items.Add($_) }
    $script:ConnCompCmbFilter.SelectedIndex = 0
    $listSec.Controls.Add($script:ConnCompCmbFilter)

    $chkConnLive              = New-Object System.Windows.Forms.CheckBox
    $chkConnLive.Text         = 'Filter as I type'
    $chkConnLive.Location     = New-Object System.Drawing.Point(466, 8)
    $chkConnLive.Size         = New-Object System.Drawing.Size(130, 20)
    $chkConnLive.Font         = $F_UI
    $chkConnLive.Checked      = $script:ConnCompFilterLive
    $listSec.Controls.Add($chkConnLive)
    # Also exposed at $script: scope so Update-ComputersFilterDefault can
    # reach this control from outside this function - the LOCAL $chkConnLive
    # is still what the closures below reference by bare name inside
    # .GetNewClosure(), which is this module's own proven-reliable pattern.
    $script:ChkConnFilterLive = $chkConnLive

    $btnRefreshList = New-StdButton -Text 'Refresh' -X ($countX-$GAP-86) -Y 6 -W 86 -H 26 -Parent $listSec

    $script:LblConnCompCount = New-Object System.Windows.Forms.Label
    $script:LblConnCompCount.Location  = New-Object System.Drawing.Point($countX, 6)
    $script:LblConnCompCount.Size      = New-Object System.Drawing.Size($COUNT_W, 24)
    $script:LblConnCompCount.Font      = $F_UI
    $script:LblConnCompCount.ForeColor = [System.Drawing.Color]::DimGray
    $script:LblConnCompCount.TextAlign = 'MiddleRight'
    $listSec.Controls.Add($script:LblConnCompCount)

    $LIST_GRID_H = $LIST_H - 25 - 36 - 6
    $script:ConnCompGrid = New-StdGrid -X 6 -Y 36 -W ($innerW-8) -H $LIST_GRID_H -Parent $listSec
    $script:ConnCompGrid.MultiSelect   = $true
    $script:ConnCompGrid.SelectionMode = 'FullRowSelect'

    $connCompGridProvider = {
        $out = @()
        if ($script:ConnCompGrid) {
            foreach ($row in $script:ConnCompGrid.SelectedRows) {
                $v = $row.Cells['Name'].Value
                if ($v) { $out += [PSCustomObject]@{ Name=[string]$v } }
            }
        }
        $out
    }
    if (Get-Command New-ComputerContextMenu -ErrorAction SilentlyContinue) {
        $script:ConnCompGrid.ContextMenuStrip = New-ComputerContextMenu -TargetProvider $connCompGridProvider -Context $Context -ShowPing
    }

    $script:ConnCompGrid.Add_MouseDown({
        param($s,$e)
        if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Right) { return }
        $hit = $script:ConnCompGrid.HitTest($e.X, $e.Y)
        if ($hit.RowIndex -ge 0 -and -not $script:ConnCompGrid.Rows[$hit.RowIndex].Selected) {
            $script:ConnCompGrid.ClearSelection()
            $script:ConnCompGrid.Rows[$hit.RowIndex].Selected = $true
        }
    })

    $script:ConnCompGrid.Add_SelectionChanged({
        $selected = $script:ConnCompGrid.SelectedRows
        if ($selected.Count -ne 1) { return }
        $name = $selected[0].Cells['Name'].Value
        if (-not $name) { return }
        if (Get-Command Set-SelectedComputer -ErrorAction SilentlyContinue) {
            Set-SelectedComputer -Comp ([PSCustomObject]@{ Name=[string]$name })
        }
    })

    $script:ConnCompGrid.Add_ColumnHeaderMouseClick({
        param($s,$e)
        if ($script:ConnCompSortCol -eq $e.ColumnIndex) { $script:ConnCompSortAsc = -not $script:ConnCompSortAsc }
        else { $script:ConnCompSortCol = $e.ColumnIndex; $script:ConnCompSortAsc = $true }
        Update-ConnCompGrid
    })

    # -- Filter events ---------------------------------------------------------
    # "Filter as I type" checked (default): TextChanged re-filters on every
    # keystroke, same as before. Unchecked: only Enter (KeyDown below) or the
    # Show dropdown re-filters, for domains where re-filtering a large
    # whole-domain list on every letter is noticeably slow. Reads
    # $chkConnLive.Checked directly (not a separately-tracked
    # $script:ConnCompFilterLive) so there is no possibility of the two
    # drifting out of sync.
    # BUG FIX (confirmed via diagnostics log on the Users pane's identical
    # pattern): a plain (non-GetNewClosure) TextChanged handler referencing a
    # sibling control's variable read that variable as $null. Forcing
    # .GetNewClosure() fixed that, but then a bare function call
    # (Update-ConnCompGrid) became unreachable by name from inside the
    # closure - same documented issue, other half. Fixed by capturing the
    # function as ${function:Name} before the closure and invoking via &
    # inside it - see ADDirectory.Register-DirectoryTab for the full
    # explanation.
    $updateConnCompGridFn = ${function:Update-ConnCompGrid}

    $script:ConnCompFilter.Add_TextChanged({
        if ($chkConnLive.Checked -and $updateConnCompGridFn) { & $updateConnCompGridFn }
    }.GetNewClosure())
    $script:ConnCompFilter.Add_KeyDown({
        param($s,$e)
        if ($e.KeyCode -eq 'Return') { Update-ConnCompGrid }
    })
    $chkConnLive.Add_CheckedChanged({
        $script:ConnCompFilterLive = $chkConnLive.Checked
        if ($chkConnLive.Checked) { Update-ConnCompGrid }
    })
    $script:ConnCompCmbFilter.Add_SelectedIndexChanged({ Update-ConnCompGrid })
    $btnRefreshList.Add_Click({
        if (Get-Command Read-ConnComputers -ErrorAction SilentlyContinue) { Read-ConnComputers -Force }
    })

    Reset-ConnCompCards

    $Tab.Add_Enter({
        Reset-ConnCompCards
        if (Get-Command Read-ConnComputers -ErrorAction SilentlyContinue) {
            Read-ConnComputers
        } else {
            Update-ConnCompGrid
        }
    })
}
#endregion

#region -- Update-ComputersFilterDefault ---------------------------------------
function Update-ComputersFilterDefault {
    <#
    .SYNOPSIS
        Re-applies this domain's saved FilterAsYouType default (Tools >
        Domain Defaults) to the Computers tab's "Filter as I type" checkbox.
        Called by the Domain Defaults tab's Save button so a save takes
        effect immediately in the same running session.
    .DESCRIPTION
        ALWAYS force-sets the checkbox to match the newly saved value, even
        if an operator already manually toggled it this session - same
        design as Update-UsersFilterDefault / Update-GroupsFilterDefault:
        Filter as I type is a per-domain admin default, not a value the
        operator "owns".
        Setting .Checked fires the existing CheckedChanged handler, which
        already re-filters the grid when turning the filter on.
        Safe no-op if this tab hasn't been built yet, the domain isn't
        connected, or Services.DomainDefaults.Config isn't loaded.
    #>
    if (-not $script:ChkConnFilterLive) { return }
    if (-not $script:CompCtx -or -not $script:CompCtx.Domain) { return }
    if (-not (Get-Command Get-DomainDefaults -ErrorAction SilentlyContinue)) { return }

    $val = $true
    try { $val = [bool](Get-DomainDefaults -Domain $script:CompCtx.Domain).FilterAsYouType } catch { }
    $script:ConnCompFilterLive        = $val
    $script:ChkConnFilterLive.Checked = $val
}
#endregion

Export-ModuleMember -Function `
    Build-ConnectivityTab, `
    Get-FilteredConnComputers, `
    Update-ConnCompGrid, `
    Reset-ConnCompCards, `
    Update-ComputersFilterDefault
