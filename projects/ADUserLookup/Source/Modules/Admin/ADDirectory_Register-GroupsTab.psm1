#region -- ADDirectory.Register-GroupsTab.psm1 --------------------------------
# Concern : Builds the standalone Groups tab - a full-width single pane
#           listing every group in the current OU scope, with filter
#           ("Filter as I type" toggle seeded from this domain's saved
#           default, same as the Users/Computers filters), sort-by-column,
#           and CSV export. Lazy-loaded on first visit (Add_Enter), same
#           pattern as the Computers tab and Infrastructure sub-tabs.
#           Separate from the Users tab's per-user "Groups" pane - this tab
#           shows ALL domain groups; that pane shows one user's membership.
#           Right-click menu has no "Remove User from Group(s)" here (no
#           selected-user concept on this tab) - Edit Members / Copy Group
#           Name(s) only.
# Load order: 28a - depends on ADDirectory.Groups.Load (Read-DirectoryGroups,
#                                                        script:AllGroups/GrpGrid),
#                            ADDirectory.Groups.Filter (Get-FilteredGroups),
#                            ADDirectory.Groups.Grid (Update-GroupGrid),
#                            ADDirectory.Groups.Menu (Register-GroupGridMenu),
#                            Services.DomainDefaults.Config (Get-DomainDefaults),
#                            Services.AD.Reporting (New-SectionPanel, New-StdButton,
#                                                   New-StdGrid, Set-Placeholder,
#                                                   Export-ToCSV, Show-ExportResult)
# Split from: (new module) - Read-DirectoryGroups/Get-FilteredGroups/
#             Update-GroupGrid/Register-GroupGridMenu already existed
#             (previously unused/legacy, now this tab's actual consumer).
# Changes   : Removed the "Batch Add..." and "Batch Delete..." buttons -
#             both actions moved to the new Bulk Operations tab
#             (ADBulkOps.Register-BulkOpsTab, pages "Bulk Add Groups" and
#             "Batch Delete Groups") as part of consolidating every bulk
#             action into one place. This tab no longer depends on
#             ADDirectory.Groups.BatchAdd / ADDirectory.Groups.BatchDelete at
#             all - both modules are still loaded (their Build-*Page
#             functions are now called from the new tab instead), just no
#             longer referenced here.
#             Added Update-GroupsFilterDefault (exported) - called by the
#             Domain Defaults tab's Save button so a saved FilterAsYouType
#             change takes effect immediately in this running session.
#             $Context is now also stored at $script:GroupsCtx purely so
#             this new function can read the connected domain from outside
#             Register-GroupsTab; $chkGroupsLive stays a local variable for
#             the existing closures (see inline comment) and is additionally
#             exposed at $script:ChkGroupsFilterLive for the same reason.
#endregion

#region -- Register-GroupsTab --------------------------------------------------
function Register-GroupsTab {
    param(
        [System.Windows.Forms.TabPage]$Tab,
        [PSCustomObject]$Context
    )

    $PAD  = 8
    $TW   = $Context.TabW
    $TH   = $Context.TabH

    # Stored at script scope purely so Update-GroupsFilterDefault (called by
    # the Domain Defaults tab's Save button) can read the currently-connected
    # domain from outside this function - $capturedContext below remains the
    # one actually used by this function's own .GetNewClosure() blocks.
    $script:GroupsCtx = $Context

    $F_UI = New-Object System.Drawing.Font('Segoe UI', 9)

    # Capture everything a .GetNewClosure() block below will need, BEFORE any
    # closure is created - bare function calls and $script:/param variable
    # reads from inside .GetNewClosure() blocks are unreliable in this
    # codebase (see ADDirectory.Register-DirectoryTab for the fuller
    # explanation); this is what silently kept the Groups tab from loading.
    $capturedContext      = $Context
    $getFilteredGroupsFn  = ${function:Get-FilteredGroups}
    $exportToCsvFn        = ${function:Export-ToCSV}
    $showExportResultFn   = ${function:Show-ExportResult}

    # Initial checked state for "Filter as I type", from this domain's saved
    # default (Tools > Domain Defaults). Read-only here - toggling the
    # checkbox during normal use never saves back.
    $script:GroupsFilterLive = $true
    if ($Context.Domain -and (Get-Command Get-DomainDefaults -ErrorAction SilentlyContinue)) {
        try { $script:GroupsFilterLive = [bool](Get-DomainDefaults -Domain $Context.Domain).FilterAsYouType }
        catch { }
    }

    $sec = New-SectionPanel -Parent $Tab -Title 'Groups' `
        -X $PAD -Y $PAD -W ($TW-($PAD*2)) -H ($TH-($PAD*2))

    $innerW  = ($TW-($PAD*2)) - 2
    $COUNT_W = 160; $BTN_W = 86; $GAP = 8; $RPAD = 8
    $countX  = $innerW - $RPAD - $COUNT_W
    $csvX    = $countX - $GAP - $BTN_W

    $lbF             = New-Object System.Windows.Forms.Label
    $lbF.Text        = 'Filter:'
    $lbF.Location    = New-Object System.Drawing.Point(6, 6)
    $lbF.Size        = New-Object System.Drawing.Size(38, 24)
    $lbF.TextAlign   = 'MiddleLeft'; $lbF.Font = $F_UI
    $sec.Controls.Add($lbF)

    $script:GrpFilter          = New-Object System.Windows.Forms.TextBox
    $script:GrpFilter.Location = New-Object System.Drawing.Point(46, 6)
    $script:GrpFilter.Size     = New-Object System.Drawing.Size(280, 24)
    $script:GrpFilter.Font     = $F_UI
    Set-Placeholder -TextBox $script:GrpFilter -Text 'Group name / description / OU...'
    $sec.Controls.Add($script:GrpFilter)

    $chkGroupsLive          = New-Object System.Windows.Forms.CheckBox
    $chkGroupsLive.Text     = 'Filter as I type'
    $chkGroupsLive.Location = New-Object System.Drawing.Point(334, 8)
    $chkGroupsLive.Size     = New-Object System.Drawing.Size(130, 20)
    $chkGroupsLive.Font     = $F_UI
    $chkGroupsLive.Checked  = $script:GroupsFilterLive
    $sec.Controls.Add($chkGroupsLive)
    # Also exposed at $script: scope so Update-GroupsFilterDefault can reach
    # this control from outside this function - the LOCAL $chkGroupsLive is
    # still what the closures below reference by bare name inside
    # .GetNewClosure(), which is this module's own proven-reliable pattern.
    $script:ChkGroupsFilterLive = $chkGroupsLive

    $btnExportGroupsCSV = New-StdButton -Text 'Export CSV' -X $csvX -Y 6 -W $BTN_W -H 26 -Parent $sec

    $script:LblGrpCount = New-Object System.Windows.Forms.Label
    $script:LblGrpCount.Location  = New-Object System.Drawing.Point($countX, 6)
    $script:LblGrpCount.Size      = New-Object System.Drawing.Size($COUNT_W, 24)
    $script:LblGrpCount.Font      = $F_UI
    $script:LblGrpCount.ForeColor = [System.Drawing.Color]::DimGray
    $script:LblGrpCount.TextAlign = 'MiddleRight'
    $sec.Controls.Add($script:LblGrpCount)

    $GRID_H = ($TH-($PAD*2)) - 36 - 10
    $script:GrpGrid = New-StdGrid -X 6 -Y 36 -W ($innerW-8) -H $GRID_H -Parent $sec
    $script:GrpGrid.MultiSelect   = $true
    $script:GrpGrid.SelectionMode = 'FullRowSelect'

    Register-GroupGridMenu -Context $Context

    # -- Filter events (same keystroke/Enter pattern as Users/Computers) -----
    # Bare function call (Update-GroupGrid) captured before the closure and
    # invoked via & - a bare-name call from inside a control's TextChanged
    # handler that also references a sibling control's variable
    # ($chkGroupsLive) is unreliable in this codebase; see
    # ADDirectory.Register-DirectoryTab for the full explanation of this
    # pattern and why both the capture and the .GetNewClosure() are needed.
    $updateGroupGridFn = ${function:Update-GroupGrid}

    $script:GrpFilter.Add_TextChanged({
        if ($chkGroupsLive.Checked -and $updateGroupGridFn) { & $updateGroupGridFn }
    }.GetNewClosure())
    $script:GrpFilter.Add_KeyDown({
        param($s,$e)
        if ($e.KeyCode -eq 'Return') { Update-GroupGrid }
    })
    $chkGroupsLive.Add_CheckedChanged({
        if ($chkGroupsLive.Checked) { Update-GroupGrid }
    })

    $script:GrpGrid.Add_ColumnHeaderMouseClick({
        param($s,$e)
        if ($script:GrpSortCol -eq $e.ColumnIndex) { $script:GrpSortAsc = -not $script:GrpSortAsc }
        else { $script:GrpSortCol = $e.ColumnIndex; $script:GrpSortAsc = $true }
        Update-GroupGrid
    })

    $btnExportGroupsCSV.Add_Click({
        $data = if ($getFilteredGroupsFn) { @(& $getFilteredGroupsFn) } else { @() }
        if ($data.Count -eq 0) { [System.Windows.Forms.MessageBox]::Show('No data to export.','Export','OK','Information'); return }
        if ($exportToCsvFn -and $showExportResultFn) {
            & $showExportResultFn -FilePath (& $exportToCsvFn -Context $capturedContext -Data $data -BaseName 'Groups')
        }
    }.GetNewClosure())

    # Lazy-load on first visit, same pattern as the Computers tab. Both
    # Read-DirectoryGroups here and Get-FilteredGroups/Export-ToCSV/
    # Show-ExportResult above are captured as function references BEFORE
    # their closures and invoked via & - a bare-name call from inside a
    # .GetNewClosure() block is unreliable in this codebase (see
    # ADDirectory.Register-DirectoryTab for the fuller explanation); this was
    # the actual cause of the Groups tab never populating.
    # v1.2.20: the load-once flag lives at module level (Invoke-GroupsFirstLoad).
    # It used to be a variable assigned INSIDE this .GetNewClosure() block, which
    # only sets a copy that is gone when the handler returns - so every focus
    # change into the tab re-read every group from AD. UI_Groups also calls the
    # same function on the tab's first view (Register-ADTabFirstShow), so the
    # list loads without having to click into it.
    $firstLoadFn = ${function:Invoke-GroupsFirstLoad}
    $Tab.Add_Enter({ & $firstLoadFn }.GetNewClosure())
}
#endregion

#region -- Invoke-GroupsFirstLoad ----------------------------------------------
# Loads the Groups tab's list the first time it is needed; later calls do
# nothing (Refresh and a domain change call Read-DirectoryGroups directly).
$script:GroupsFirstLoaded = $false
function Invoke-GroupsFirstLoad {
    if ($script:GroupsFirstLoaded) { return }
    $script:GroupsFirstLoaded = $true
    Read-DirectoryGroups
}
#endregion

#region -- Update-GroupsFilterDefault -------------------------------------------
function Update-GroupsFilterDefault {
    <#
    .SYNOPSIS
        Re-applies this domain's saved FilterAsYouType default (Tools >
        Domain Defaults) to the Groups tab's "Filter as I type" checkbox.
        Called by the Domain Defaults tab's Save button so a save takes
        effect immediately in the same running session.
    .DESCRIPTION
        ALWAYS force-sets the checkbox to match the newly saved value, even
        if an operator already manually toggled it this session - same
        design as Update-UsersFilterDefault (ADDirectory.Register-
        DirectoryTab): Filter as I type is a per-domain admin default, not a
        value the operator "owns".
        Setting .Checked fires the existing CheckedChanged handler, which
        already re-filters the grid when turning the filter on.
        Safe no-op if this tab hasn't been built yet, the domain isn't
        connected, or Services.DomainDefaults.Config isn't loaded.
    #>
    if (-not $script:ChkGroupsFilterLive) { return }
    if (-not $script:GroupsCtx -or -not $script:GroupsCtx.Domain) { return }
    if (-not (Get-Command Get-DomainDefaults -ErrorAction SilentlyContinue)) { return }

    $val = $true
    try { $val = [bool](Get-DomainDefaults -Domain $script:GroupsCtx.Domain).FilterAsYouType } catch { }
    $script:GroupsFilterLive           = $val
    $script:ChkGroupsFilterLive.Checked = $val
}
#endregion

Export-ModuleMember -Function Register-GroupsTab, Update-GroupsFilterDefault
