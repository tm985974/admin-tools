#region -- ADDirectory.Register-DirectoryTab.psm1 ----------------------------
# Concern : Builds the Users tab's three panes: Users, Groups (per-user
#           membership view), and Activity Log (live feed of Write-OperationLog
#           actions and Invoke-SetStatus messages via Add-ActivityLogLine,
#           Services.Logging). Wires all filter/sort/export events, then calls
#           the Menu register functions to attach context menus.
#           Sets $script:DirContext shared across all ADDirectory sub-modules.
#           Computers pane removed: computer management lives entirely on the
#           Computers tab now (ADComputers.Connectivity.Tab), which is
#           self-contained and whole-domain, independent of this tab's tree.
#           Groups pane shows per-user group membership, not all domain
#           groups; it starts empty (prompt shown) and is populated by
#           ADDirectory.Users.Menu's SelectionChanged handler. All domain
#           groups now live on their own standalone Groups tab
#           (ADDirectory.Register-GroupsTab), a separate main-level tab next
#           to this one.
# Load order: 26 - depends on ADDirectory.* modules (10-21, Computers.* removed),
#                            Services.AD.Reporting (New-SectionPanel, New-StdButton,
#                                                   New-StdGrid, Set-Placeholder,
#                                                   Get-PlaceholderValue,
#                                                   Export-ToCSV, Export-ToHTML,
#                                                   Show-ExportResult),
#                            Services.Logging (Get-OperationLog, for Activity
#                                              Log backfill on tab init)
# Split from: ADDirectory.Tab.psm1
# Changes   : Tab renamed from "Users and Groups" to "Users" (text set in
#             _AD-Admin.ps1's tab strip - no change needed here). All-domain
#             group management moved to the new standalone Groups tab
#             (ADDirectory.Register-GroupsTab); this tab's Groups pane keeps
#             only the per-user membership view.
#             The Groups pane's filter row (textbox + "Filter as I type"
#             checkbox) has been REMOVED entirely - a single selected user's
#             membership list is short enough that filtering added a control
#             for little value, and it never worked reliably as a second,
#             independent live-filter next to the Users pane's. The pane now
#             uses its own dedicated state ($script:UserGrpGrid/
#             $script:LblUserGrpCount/$script:LblUserGrpTitle, owned by
#             ADDirectory.Groups.Load) instead of the $script:GrpGrid/
#             $script:LblGrpCount/$script:LblGrpTitle now owned by the
#             standalone Groups tab, so the two no longer collide. Column-
#             click sorting is retained via Update-UserGroupGrid
#             (ADDirectory.Groups.Grid). Export CSV still works, exporting
#             $script:AllUserGroups directly (no filter to apply).
#             Calls Register-UserGroupGridMenu (ADDirectory.Groups.Menu)
#             instead of Register-GroupGridMenu, which now targets the
#             standalone Groups tab's grid instead.
#             Added a 'Filter as I type' checkbox to the Users pane, seeded
#             from this domain's saved FilterAsYouType default (Services.
#             DomainDefaults.Config, edited on the Tools > Domain Defaults
#             tab), falling back to $true if unset/unreadable. Read-only -
#             toggling it during normal use never writes back to the config
#             file; only the Domain Defaults tab's Save button does.
#             BUG FIX (confirmed via diagnostics log): a bare-name TextChanged
#             handler referencing a sibling control's variable ($chkUserLive)
#             read that variable as $null. Forcing .GetNewClosure() fixed
#             that, but then a bare function call (Update-UserGrid) became
#             unreachable by name from inside the closure - the other half of
#             the same documented issue elsewhere in this codebase (see
#             ADDirectory.Menus). Fixed by capturing Update-UserGrid as
#             ${function:Update-UserGrid} before the closure and invoking via
#             & inside it.
#             Added Update-UsersFilterDefault (exported) - called by the
#             Domain Defaults tab's Save button so a saved FilterAsYouType
#             change takes effect immediately in this running session, even
#             if the operator already toggled the checkbox manually. $chkUserLive
#             itself stays a local variable (still referenced by bare name
#             from inside the existing .GetNewClosure() TextChanged handler -
#             changing that to a $script: variable would reintroduce the
#             exact resolution failure this module already fixed once); it is
#             additionally exposed at $script:ChkUsersFilterLive purely so
#             this new function can reach it from outside Register-DirectoryTab.
#endregion

#region -- Register-DirectoryTab ----------------------------------------------
function Register-DirectoryTab {
    <#
    .SYNOPSIS
        Builds the Users, Groups (per-user membership), and Activity Log
        panes spanning the full Users tab width. The OU tree has moved to the
        launcher left column; per-pane Load/Refresh replaced by the tree
        column's Reload button.
    #>
    param(
        [System.Windows.Forms.TabPage]$Tab,
        [PSCustomObject]$Context
    )
    $script:DirContext = $Context
    $script:DirTab     = $Tab

    # Initial checked state for the Users pane's "Filter as I type" checkbox,
    # from this domain's saved default (Tools > Domain Defaults). Read-only
    # here - toggling the checkbox during normal use never saves back.
    $script:UserFilterLive = $true
    if ($Context.Domain -and (Get-Command Get-DomainDefaults -ErrorAction SilentlyContinue)) {
        try { $script:UserFilterLive = [bool](Get-DomainDefaults -Domain $Context.Domain).FilterAsYouType }
        catch { }
    }

    $PAD  = 6
    $TW   = $Context.TabW
    $TH   = $Context.TabH

    $paneX = $PAD
    $paneW = $TW - ($PAD * 2)

    $TOTAL_H = $TH - ($PAD * 4)
    $USER_H  = [int]($TOTAL_H * 0.35)
    $GRP_H   = [int]($TOTAL_H * 0.30)
    $LOG_H   = $TOTAL_H - $USER_H - $GRP_H

    $USER_Y  = $PAD
    $GRP_Y   = $PAD + $USER_H + $PAD
    $LOG_Y   = $GRP_Y + $GRP_H + $PAD

    $HDR_H   = 25
    $CTRL_H  = 36

    $F_UI    = New-Object System.Drawing.Font('Segoe UI', 9)
    $F_UI_B  = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $F_MONO  = New-Object System.Drawing.Font('Consolas', 9)

    $innerW  = $paneW - 2
    $COUNT_W = 160; $BTN_W = 86; $GAP = 8; $RPAD = 8
    $countX  = $innerW - $RPAD - $COUNT_W
    $htmlX   = $countX - $GAP - $BTN_W
    $csvX    = $htmlX  - $GAP - $BTN_W

    # -------------------------------------------------------------------------
    # Users pane
    # -------------------------------------------------------------------------
    $USER_GRID_H = $USER_H - $HDR_H - $CTRL_H - 6
    $userSec = New-SectionPanel -Parent $Tab -Title 'Users' -X $paneX -Y $USER_Y -W $paneW -H $USER_H

    $lbUF = New-Object System.Windows.Forms.Label
    $lbUF.Text = 'Filter:'; $lbUF.Location = New-Object System.Drawing.Point(6,6)
    $lbUF.Size = New-Object System.Drawing.Size(38,24); $lbUF.TextAlign = 'MiddleLeft'; $lbUF.Font = $F_UI
    $userSec.Controls.Add($lbUF)

    $script:UserFilter = New-Object System.Windows.Forms.TextBox
    $script:UserFilter.Location = New-Object System.Drawing.Point(46,6)
    $script:UserFilter.Size     = New-Object System.Drawing.Size(200,24); $script:UserFilter.Font = $F_UI
    Set-Placeholder -TextBox $script:UserFilter -Text 'Name / username / UPN...'
    $userSec.Controls.Add($script:UserFilter)

    $lbUC = New-Object System.Windows.Forms.Label
    $lbUC.Text = 'Show:'; $lbUC.Location = New-Object System.Drawing.Point(254,6)
    $lbUC.Size = New-Object System.Drawing.Size(38,24); $lbUC.TextAlign = 'MiddleLeft'; $lbUC.Font = $F_UI
    $userSec.Controls.Add($lbUC)

    $script:UserCmbFilter = New-Object System.Windows.Forms.ComboBox
    $script:UserCmbFilter.Location = New-Object System.Drawing.Point(294,6)
    $script:UserCmbFilter.Size     = New-Object System.Drawing.Size(160,24)
    $script:UserCmbFilter.DropDownStyle = 'DropDownList'; $script:UserCmbFilter.Font = $F_UI
    @('All Users','Enabled Only','Disabled Only','Never Logged In','Password Expired') |
        ForEach-Object { [void]$script:UserCmbFilter.Items.Add($_) }
    $script:UserCmbFilter.SelectedIndex = 0
    $userSec.Controls.Add($script:UserCmbFilter)

    $chkUserLive          = New-Object System.Windows.Forms.CheckBox
    $chkUserLive.Text     = 'Filter as I type'
    $chkUserLive.Location = New-Object System.Drawing.Point(470, 8)
    $chkUserLive.Size     = New-Object System.Drawing.Size(130, 20)
    $chkUserLive.Font     = $F_UI
    $chkUserLive.Checked  = $script:UserFilterLive
    $userSec.Controls.Add($chkUserLive)
    # Also exposed at $script: scope so Update-UsersFilterDefault (called by
    # the Domain Defaults tab's Save button) can reach this control from
    # outside this function. Internal wiring below still uses the LOCAL
    # $chkUserLive by bare name inside .GetNewClosure() - that is the
    # proven-reliable pattern already fixed once in this exact module (see
    # module header BUG FIX note); reading $script:ChkUsersFilterLive by bare
    # name from inside a .GetNewClosure() block would reintroduce the same
    # class of resolution failure documented throughout this codebase.
    $script:ChkUsersFilterLive = $chkUserLive

    $btnExportUsersCSV  = New-StdButton -Text 'Export CSV'  -X $csvX  -Y 6 -W $BTN_W -H 26 -Parent $userSec
    $btnExportUsersHTML = New-StdButton -Text 'Export HTML' -X $htmlX -Y 6 -W $BTN_W -H 26 -Parent $userSec

    $script:LblUserCount = New-Object System.Windows.Forms.Label
    $script:LblUserCount.Location  = New-Object System.Drawing.Point($countX,6)
    $script:LblUserCount.Size      = New-Object System.Drawing.Size($COUNT_W,24)
    $script:LblUserCount.Font      = $F_UI
    $script:LblUserCount.ForeColor = [System.Drawing.Color]::DimGray
    $script:LblUserCount.TextAlign = 'MiddleRight'
    $userSec.Controls.Add($script:LblUserCount)

    $script:UserGrid = New-StdGrid -X 6 -Y $CTRL_H -W ($paneW-14) -H $USER_GRID_H -Parent $userSec
    $script:UserGrid.MultiSelect   = $true
    $script:UserGrid.SelectionMode = 'FullRowSelect'

    # -------------------------------------------------------------------------
    # Groups pane (per-user membership view only - no filter row). All-domain
    # group management lives on the standalone Groups tab now
    # (ADDirectory.Register-GroupsTab), a separate main-level tab.
    # -------------------------------------------------------------------------
    $GRP_GRID_H = $GRP_H - $HDR_H - 6
    $grpSec = New-SectionPanel -Parent $Tab -Title 'Groups' -X $paneX -Y $GRP_Y -W $paneW -H $GRP_H

    # Capture the section header label so Read-SelectedUserGroups can retitle the
    # Groups pane with the selected user. New-SectionPanel returns the inner
    # content panel; its Parent (the border) holds the header panel plus this
    # inner panel, and the header panel's first child is the title Label.
    $script:LblUserGrpTitle = $null
    if ($grpSec -and $grpSec.Parent) {
        $grpHdr = @($grpSec.Parent.Controls | Where-Object { $_ -ne $grpSec }) | Select-Object -First 1
        if ($grpHdr -and $grpHdr.Controls.Count -gt 0) { $script:LblUserGrpTitle = $grpHdr.Controls[0] }
    }

    $script:LblUserGrpCount = New-Object System.Windows.Forms.Label
    $script:LblUserGrpCount.Location  = New-Object System.Drawing.Point(6,6)
    $script:LblUserGrpCount.Size      = New-Object System.Drawing.Size(($csvX-14),24)
    $script:LblUserGrpCount.Font      = $F_UI
    $script:LblUserGrpCount.ForeColor = [System.Drawing.Color]::DimGray
    $script:LblUserGrpCount.TextAlign = 'MiddleLeft'
    $grpSec.Controls.Add($script:LblUserGrpCount)

    $btnExportUserGrpsCSV = New-StdButton -Text 'Export CSV' -X $csvX -Y 6 -W $BTN_W -H 26 -Parent $grpSec

    $script:UserGrpGrid = New-StdGrid -X 6 -Y $CTRL_H -W ($paneW-14) -H $GRP_GRID_H -Parent $grpSec
    $script:UserGrpGrid.MultiSelect   = $true
    $script:UserGrpGrid.SelectionMode = 'FullRowSelect'

    # -------------------------------------------------------------------------
    # Activity Log pane (replaces the former Computers pane)
    # Black background, Consolas, bright green (ok) / bright yellow (fail) /
    # dim gray (info) text. Fed live by Write-OperationLog and Invoke-SetStatus
    # via Add-ActivityLogLine (Services.Logging). Backfilled from today's
    # operation log on tab init.
    # -------------------------------------------------------------------------
    $LOG_GRID_H = $LOG_H - $HDR_H - 6
    $logSec = New-SectionPanel -Parent $Tab -Title 'Activity Log' -X $paneX -Y $LOG_Y -W $paneW -H $LOG_H

    $script:ActivityLogRtb             = New-Object System.Windows.Forms.RichTextBox
    $script:ActivityLogRtb.Location    = New-Object System.Drawing.Point(6, 0)
    $script:ActivityLogRtb.Size        = New-Object System.Drawing.Size(($paneW-14), $LOG_GRID_H)
    $script:ActivityLogRtb.Font        = $F_MONO
    $script:ActivityLogRtb.ReadOnly    = $true
    $script:ActivityLogRtb.BackColor   = [System.Drawing.Color]::Black
    $script:ActivityLogRtb.ForeColor   = [System.Drawing.Color]::FromArgb(150,150,150)
    $script:ActivityLogRtb.BorderStyle = 'None'
    $script:ActivityLogRtb.WordWrap    = $false
    $script:ActivityLogRtb.ScrollBars  = 'Vertical'
    $logSec.Controls.Add($script:ActivityLogRtb)

    # -------------------------------------------------------------------------
    # Attach context menus via sub-module register functions
    # -------------------------------------------------------------------------
    if (Get-Command Register-UserGridMenu      -ErrorAction SilentlyContinue) { Register-UserGridMenu      -Context $Context }
    if (Get-Command Register-UserGroupGridMenu -ErrorAction SilentlyContinue) { Register-UserGroupGridMenu -Context $Context }

    # -------------------------------------------------------------------------
    # Filter / sort events
    # -------------------------------------------------------------------------
    # "Filter as I type" checked (default): TextChanged re-filters on every
    # keystroke, same as before. Unchecked: only Enter (KeyDown below) or the
    # Show dropdown re-filters.
    # BUG FIX (confirmed via diagnostics log): $chkUserLive read as $null
    # inside $script:UserFilter's plain (non-GetNewClosure) TextChanged
    # handler, even though it is a plain local variable in this same
    # function - the same class of cross-variable closure-resolution issue
    # documented throughout ADDirectory.Menus (bare-name functions/$script:
    # vars unreachable from certain closures), just showing up here between
    # two sibling controls' event handlers with no .GetNewClosure() at all.
    # Forcing .GetNewClosure() fixed the $chkUserLive read, but then hit the
    # OTHER half of that same documented issue: a bare function call
    # (Update-UserGrid) is unreachable by name from inside a .GetNewClosure()
    # block. Fixed the standard way used throughout this codebase - capture
    # the function as ${function:Name} BEFORE the closure, invoke it via &
    # inside.
    $updateUserGridFn = ${function:Update-UserGrid}

    $script:UserFilter.Add_TextChanged({
        if ($chkUserLive.Checked -and $updateUserGridFn) { & $updateUserGridFn }
    }.GetNewClosure())
    $script:UserFilter.Add_KeyDown({
        param($s,$e)
        if ($e.KeyCode -eq 'Return') { Update-UserGrid }
    })
    $chkUserLive.Add_CheckedChanged({
        $script:UserFilterLive = $chkUserLive.Checked
        if ($chkUserLive.Checked) { Update-UserGrid }
    })
    $script:UserCmbFilter.Add_SelectedIndexChanged({ Update-UserGrid })

    $script:UserGrid.Add_ColumnHeaderMouseClick({
        param($s,$e)
        if ($script:UserSortCol -eq $e.ColumnIndex) { $script:UserSortAsc = -not $script:UserSortAsc }
        else { $script:UserSortCol = $e.ColumnIndex; $script:UserSortAsc = $true }
        Update-UserGrid
    })
    $script:UserGrpGrid.Add_ColumnHeaderMouseClick({
        param($s,$e)
        if ($script:UserGrpSortCol -eq $e.ColumnIndex) { $script:UserGrpSortAsc = -not $script:UserGrpSortAsc }
        else { $script:UserGrpSortCol = $e.ColumnIndex; $script:UserGrpSortAsc = $true }
        Update-UserGroupGrid
    })

    # -------------------------------------------------------------------------
    # Export events
    # -------------------------------------------------------------------------
    $btnExportUsersCSV.Add_Click({
        $data = Get-FilteredUsers
        if ($data.Count -eq 0) { [System.Windows.Forms.MessageBox]::Show('No data to export.','Export','OK','Information'); return }
        Show-ExportResult -FilePath (Export-ToCSV -Context $script:DirContext -Data $data -BaseName 'Users')
    })
    $btnExportUsersHTML.Add_Click({
        $data = Get-FilteredUsers
        if ($data.Count -eq 0) { [System.Windows.Forms.MessageBox]::Show('No data to export.','Export','OK','Information'); return }
        Show-ExportResult -FilePath (Export-ToHTML -Context $script:DirContext -Title 'AD User Report' `
            -Subtitle "OU: $($script:DirContext.SelectedOU)" -Data $data -BaseName 'Users')
    })
    $btnExportUserGrpsCSV.Add_Click({
        $data = @($script:AllUserGroups)
        if ($data.Count -eq 0) { [System.Windows.Forms.MessageBox]::Show('No data to export.','Export','OK','Information'); return }
        Show-ExportResult -FilePath (Export-ToCSV -Context $script:DirContext -Data $data -BaseName 'UserGroups')
    })

    # v1.2.20: the list loads when the Users tab is first shown (UI_Directory:
    # Register-ADTabFirstShow -> Invoke-UsersFirstLoad), not while this tab is
    # built in the background right after connecting.
    # Groups pane is membership-driven (see ADDirectory.Users.Menu's
    # SelectionChanged handler) and starts empty with a prompt rather than
    # loading all domain groups.
    if (Get-Command Read-SelectedUserGroups -ErrorAction SilentlyContinue) { Read-SelectedUserGroups -Sam '' }

    # Backfill Activity Log with today's entries so the panel isn't empty
    # on launch. Live entries append on top of this from here on.
    if (Get-Command Get-OperationLog -ErrorAction SilentlyContinue) {
        $todayEntries = @(Get-OperationLog -Context $Context -LastNDays 1)
        foreach ($entry in $todayEntries) {
            $lvl = if ($entry.Result -eq 'OK') { 'ok' } else { 'fail' }
            $txt = "$($entry.Action) | $($entry.Target) | $($entry.Result)$(if ($entry.Detail) { " | $($entry.Detail)" })"
            if (Get-Command Add-ActivityLogLine -ErrorAction SilentlyContinue) { Add-ActivityLogLine -Text $txt -Level $lvl }
        }
        if ($script:ActivityLogRtb -and $todayEntries.Count -eq 0) {
            Add-ActivityLogLine -Text 'No activity logged yet today.' -Level ''
        }
    }
}
#endregion

#region -- Update-UsersFilterDefault -------------------------------------------
function Update-UsersFilterDefault {
    <#
    .SYNOPSIS
        Re-applies this domain's saved FilterAsYouType default (Tools >
        Domain Defaults) to the Users pane's "Filter as I type" checkbox.
        Called by the Domain Defaults tab's Save button so a save takes
        effect immediately in the same running session.
    .DESCRIPTION
        Unlike the OU/suffix refresh functions elsewhere in this app, this
        ALWAYS force-sets the checkbox to match the newly saved value, even
        if an operator already manually toggled it this session - per
        design, Filter as I type is a per-domain admin default the operator
        is expected to see updated immediately, not a value the operator
        "owns" the way a Target OU or suffix field is.
        Setting .Checked fires the existing CheckedChanged handler, which
        already re-filters the grid when turning the filter on - no extra
        work needed here for that.
        Safe no-op if this pane hasn't been built yet, the domain isn't
        connected, or Services.DomainDefaults.Config isn't loaded.
    #>
    if (-not $script:ChkUsersFilterLive) { return }
    if (-not $script:DirContext -or -not $script:DirContext.Domain) { return }
    if (-not (Get-Command Get-DomainDefaults -ErrorAction SilentlyContinue)) { return }

    $val = $true
    try { $val = [bool](Get-DomainDefaults -Domain $script:DirContext.Domain).FilterAsYouType } catch { }
    $script:UserFilterLive         = $val
    $script:ChkUsersFilterLive.Checked = $val
}
#endregion

Export-ModuleMember -Function Register-DirectoryTab, Update-UsersFilterDefault
