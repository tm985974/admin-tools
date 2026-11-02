#region -- ADAudit.Register-AuditTab.psm1 -------------------------------------
# Concern : Register-AuditTab - builds the Audit tab as a dashboard: a
#           scrollable grid of ten summary cards (Users x7, Computers x2,
#           Groups x1), each showing a live preview and a count, that opens
#           a full drill-in popup (New-AuditReportPopup) when clicked. A
#           "Refresh All" button re-runs every report and re-renders every
#           card.
# Load order: 90 - depends on ADAudit.ListReports.Tab (New-AuditReportPopup,
#                            Build-AuditCard) [89d],
#                            ADAudit.ListReports.Query.Users [89a],
#                            ADAudit.ListReports.Query.Computers [89b],
#                            ADAudit.ListReports.Query.Groups [89c]
# Split from: ADAudit.Register-AuditTab.psm1 (dashboard rewrite - previous
#             version built a sub-TabControl with ten permanent tab pages)
# Changes   : DASHBOARD REDESIGN. The ten-tab-page layout is replaced with a
#             card dashboard matching the requested wireframe: one card per
#             report, each showing a compact preview (its most actionable
#             1-2 columns, top 3 rows, worst-first where a meaningful sort
#             exists) and a count badge, click-through to the full grid.
#             Eager loading tradeoff: the previous tab-page design only ran
#             a report's query the first time an admin visited that
#             specific sub-tab (lazy, one at a time). A dashboard needs
#             every card's preview populated at once, so all ten reports
#             now run together on the Audit tab's first Enter - heavier per
#             visit, but only once per visit, and "Refresh All" re-runs
#             them together on demand rather than requiring the admin to
#             revisit each report individually.
#             $script:AudGrids (unchanged) / $script:AudPopups (new) are
#             initialised here, before any report - and therefore before
#             any Invoke-*Audit call - can exist.
#             Per-report preview sort: before extracting each card's top-3
#             preview, the report's OWN grid is sorted (via the grid's
#             native .Sort(), which now compares by each column's real type
#             thanks to the Set-GridData fix in Services.AD.Reporting) by
#             whichever column makes that report's preview "worst first" -
#             e.g. Stale Users by DaysSinceLogon descending, Password
#             Expiring by DaysRemaining ascending. Reports with no single
#             obviously-rankable column (Empty Groups, Never Logged In,
#             Locked Out) are left in query order.
#             Layout refinement: fixed 5-across, 2-row grid (was: however
#             many 250px cards fit the available width, which produced 7+3
#             on a wide screen) - card width now derives from the panel's
#             actual available width divided by 5, and cards are taller
#             (232px, was 190px) to comfortably fit a new column-header row
#             (via Build-AuditCard's PreviewHeaders) plus 4 preview rows
#             (was 3), now that there are only two rows of cards to fit
#             vertically instead of many.
#             ROW PATTERN CHANGED to 4/4/2 (was: uniform 5/5). $ROW_PATTERN
#             replaces the flat $COLS constant - card width is now derived
#             from the WIDEST row (4 cards), so every card across all three
#             rows is the same (now slightly wider) size; the wrap point
#             advances by whatever count the current row calls for instead
#             of a single fixed column count. Card height (232px) and every
#             other dimension are unchanged.
#endregion

#region -- Register-AuditTab --------------------------------------------------
function Register-AuditTab {
    param(
        [System.Windows.Forms.TabPage]$Tab,
        [PSCustomObject]$Context
    )
    $script:AudContext = $Context
    $script:AudCtx     = $Context
    $script:AudTab     = $Tab
    $script:AudGrids   = @{}
    $script:AudPopups  = @{}

    $PAD     = 8
    $F_TITLE = New-Object System.Drawing.Font('Segoe UI', 14, [System.Drawing.FontStyle]::Bold)
    $F_UI_B  = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $F_HINT  = New-Object System.Drawing.Font('Segoe UI', 8)
    $TW      = $Context.TabW
    $TH      = $Context.TabH

    $lHeader           = New-Object System.Windows.Forms.Label
    $lHeader.Text      = 'Audit Dashboard'
    $lHeader.Location  = New-Object System.Drawing.Point($PAD, $PAD)
    $lHeader.Size      = New-Object System.Drawing.Size(400, 30)
    $lHeader.Font      = $F_TITLE
    $lHeader.ForeColor = [System.Drawing.Color]::FromArgb(0,60,120)
    $Tab.Controls.Add($lHeader)

    # Wider right-edge margin than the usual $PAD (8px) - see
    # ADBulkOps.AddUsersToGroups.Tab's identical fix for the same
    # flush-against-the-estimated-edge pattern (confirmed clipped there in
    # testing; this button uses the same formula and carries the same risk).
    $btnRefreshAll           = New-StdButton -Text 'Refresh All' -X ($TW-$PAD-140-32) -Y ($PAD+2) -W 140 -H 30 -Parent $Tab
    $btnRefreshAll.Font      = $F_UI_B

    $lLastRefresh           = New-Object System.Windows.Forms.Label
    $lLastRefresh.Text      = ''
    $lLastRefresh.Location  = New-Object System.Drawing.Point(($TW-$PAD-360-32), ($PAD+8))
    $lLastRefresh.Size      = New-Object System.Drawing.Size(210, 20)
    $lLastRefresh.Font      = $F_HINT
    $lLastRefresh.ForeColor = [System.Drawing.Color]::DimGray
    $lLastRefresh.TextAlign = 'MiddleRight'
    $Tab.Controls.Add($lLastRefresh)

    $CARDS_Y             = $PAD + 44
    $cardsPanel          = New-Object System.Windows.Forms.Panel
    $cardsPanel.Location = New-Object System.Drawing.Point($PAD, $CARDS_Y)
    $cardsPanel.Size     = New-Object System.Drawing.Size(($TW-$PAD*2), ($TH-$CARDS_Y-$PAD))
    $cardsPanel.AutoScroll = $true
    $cardsPanel.BackColor  = [System.Drawing.Color]::FromArgb(245,247,250)
    $Tab.Controls.Add($cardsPanel)

    # Each entry's Fn is a captured function reference
    # (${function:Invoke-XyzAudit}), not a bare scriptblock literal - see
    # ADAudit.ListReports.Tab's header for why that distinction matters for
    # reliable resolution from inside closures. SortCol/SortDesc pick the
    # "worst first" ordering for each card's preview (see module header) -
    # $null means leave in query order.
    $reports = @(
        @{ Key='stale';      Title='Stale Users';        PopupTitle='Stale User Accounts';               Base='AuditStaleUsers';         Entity='User';     Info='Enabled users who have logged in before, but not in the last 90 days.'; Fn=${function:Invoke-StaleUsersAudit};            PreviewCols=@('SamAccountName','DaysSinceLogon'); PreviewHeaders=@('User','Days');       SortCol='DaysSinceLogon'; SortDesc=$true }
        @{ Key='stalecomp';  Title='Stale Computers';    PopupTitle='Stale Computer Accounts';           Base='AuditStaleComputers';     Entity='Computer'; Info='Enabled computers not logged in for 90+ days, or never logged in at all.'; Fn=${function:Invoke-StaleComputersAudit};      PreviewCols=@('Name','DaysSinceLogon');           PreviewHeaders=@('Computer','Days');   SortCol='DaysSinceLogon'; SortDesc=$true }
        @{ Key='neverli';    Title='Never Logged In';    PopupTitle='Never Logged In';                    Base='AuditNeverLoggedIn';      Entity='User';     Info='Enabled users with no recorded logon since account creation.'; Fn=${function:Invoke-NeverLoggedInUsersAudit};  PreviewCols=@('SamAccountName');                  PreviewHeaders=@('User');               SortCol=$null;             SortDesc=$false }
        @{ Key='lockedout';  Title='Locked Out';         PopupTitle='Locked Out Accounts';                Base='AuditLockedOut';          Entity='User';     Info='Every currently locked-out user account, domain-wide.'; Fn=${function:Invoke-LockedOutUsersAudit};       PreviewCols=@('SamAccountName');                  PreviewHeaders=@('User');               SortCol=$null;             SortDesc=$false }
        @{ Key='pwexpiring'; Title='Expiring PW';        PopupTitle='Passwords Expiring Soon';           Base='AuditPwExpiring';         Entity='User';     Info='Enabled users whose password expires within 7 days (Fine-Grained Password Policies are accounted for).'; Fn=${function:Invoke-PwExpiringUsersAudit}; PreviewCols=@('SamAccountName','DaysRemaining'); PreviewHeaders=@('User','Days');   SortCol='DaysRemaining';  SortDesc=$false }
        @{ Key='pwneverexp'; Title='PW Never Expires';   PopupTitle='Password Never Expires';            Base='AuditPwNeverExpires';     Entity='User';     Info='Enabled users with Password Never Expires set - a standing security exception list worth periodic review.'; Fn=${function:Invoke-PwNeverExpiresAudit}; PreviewCols=@('SamAccountName','PasswordLastSet'); PreviewHeaders=@('User','Last Set'); SortCol='PasswordLastSet'; SortDesc=$false }
        @{ Key='emptygrp';   Title='Empty Groups';       PopupTitle='Empty Groups';                       Base='AuditEmptyGroups';        Entity='Group';    Info='Groups with zero members, domain-wide.'; Fn=${function:Invoke-EmptyGroupsAudit};          PreviewCols=@('Name');                            PreviewHeaders=@('Group');              SortCol=$null;             SortDesc=$false }
        @{ Key='disgrp';     Title='Disabled w/Groups';  PopupTitle='Disabled Accounts Still in Groups'; Base='AuditDisabledWithGroups'; Entity='User';     Info='Disabled users who still hold one or more explicit group memberships - offboarding cleanup candidates.'; Fn=${function:Invoke-DisabledWithGroupsAudit}; PreviewCols=@('SamAccountName','GroupCount');  PreviewHeaders=@('User','Groups'); SortCol='GroupCount';     SortDesc=$true }
        @{ Key='svcacct';    Title='Service Accounts';   PopupTitle='Service Accounts (SPNs)';           Base='AuditServiceAccounts';    Entity='User';     Info='Any account with a Service Principal Name - a Kerberoasting target regardless of enabled state.'; Fn=${function:Invoke-ServiceAccountsAudit}; PreviewCols=@('SamAccountName');                 PreviewHeaders=@('User');               SortCol='Enabled';         SortDesc=$true }
        @{ Key='discomp';    Title='Disabled Computers'; PopupTitle='Disabled Computer Accounts';        Base='AuditDisabledComputers';  Entity='Computer'; Info='Disabled computer objects that were never actually deleted.'; Fn=${function:Invoke-DisabledComputersAudit}; PreviewCols=@('Name');                            PreviewHeaders=@('Computer');           SortCol='LastChanged';     SortDesc=$false }
    )

    # Cross-module function calls / $script: variable reads from inside the
    # .GetNewClosure() render-dashboard closure below are unreliable by
    # bare name in this codebase (see ADAudit.ListReports.Tab's header) -
    # capture here, invoke via & or the local reference inside.
    $newPopupFn          = ${function:New-AuditReportPopup}
    $buildCardFn         = ${function:Build-AuditCard}
    $getGridRowsFn       = ${function:Get-GridRowsAsObjects}
    $capturedContext     = $Context
    $capturedCardsPanel  = $cardsPanel
    $capturedLastRefresh = $lLastRefresh
    $capturedReports     = $reports
    # Hashtables are reference types, so capturing them here and mutating
    # via these local names still updates the SAME underlying objects
    # $script:AudGrids / $script:AudPopups point to - this is the fix, not
    # a workaround: bare $script: reads from inside a .GetNewClosure()
    # block resolve to $null in this codebase (see module header and the
    # near-identical fix in ADAudit.ListReports.Tab / ADDirectory.Menus),
    # which is exactly what produced "Cannot index into a null array" here.
    $capturedAudGrids    = $script:AudGrids
    $capturedAudPopups   = $script:AudPopups

    $renderDashboard = {
        $capturedCardsPanel.Controls.Clear()
        # Row pattern (was: uniform $COLS = 5, giving 5+5). Card width is
        # derived from the WIDEST row so every card is the same size
        # regardless of which row it's in; the wrap point below advances by
        # whatever count the CURRENT row calls for, not a flat column count.
        $ROW_PATTERN = @(4, 4, 2)
        $MAX_COLS    = ($ROW_PATTERN | Measure-Object -Maximum).Maximum
        $GAP  = 14
        $availW = $capturedCardsPanel.ClientSize.Width
        if ($availW -le 0) { $availW = 1300 }   # fallback if not yet sized
        $CARD_W = [int](($availW - ($GAP * ($MAX_COLS + 1))) / $MAX_COLS)
        $CARD_H = 232
        $cx = $GAP; $cy = $GAP
        $rowIdx = 0; $colInRow = 0
        $rowCols = $ROW_PATTERN[0]

        foreach ($r in $capturedReports) {
            if (-not $capturedAudPopups[$r.Key]) {
                $capturedAudPopups[$r.Key] = & $newPopupFn -GridKey $r.Key -PopupTitle $r.PopupTitle `
                    -InfoText $r.Info -ExportBaseName $r.Base -QueryFn $r.Fn `
                    -EntityType $r.Entity -Context $capturedContext
            }

            # (Re)run this report's query into its persistent grid.
            & $r.Fn

            # Sort the grid natively (real-type comparison, thanks to the
            # Set-GridData fix) before extracting the "worst first" preview
            # - sorting the FORMATTED string output instead would
            # reintroduce the exact lexicographic-sort bug this whole
            # change exists to fix.
            if ($r.SortCol -and $capturedAudGrids[$r.Key].Columns.Contains($r.SortCol)) {
                try {
                    $dir = if ($r.SortDesc) { [System.ComponentModel.ListSortDirection]::Descending } else { [System.ComponentModel.ListSortDirection]::Ascending }
                    $capturedAudGrids[$r.Key].Sort($capturedAudGrids[$r.Key].Columns[$r.SortCol], $dir)
                } catch { }
            }

            $rowsAll = & $getGridRowsFn -Grid $capturedAudGrids[$r.Key]
            $preview = @($rowsAll | Select-Object -First 4)

            & $buildCardFn -Parent $capturedCardsPanel -X $cx -Y $cy -W $CARD_W -H $CARD_H `
                -Title $r.Title -PreviewColumns $r.PreviewCols -PreviewHeaders $r.PreviewHeaders `
                -PreviewRows $preview -Count $rowsAll.Count -Popup $capturedAudPopups[$r.Key]

            $colInRow++
            if ($colInRow -ge $rowCols) {
                $colInRow = 0
                $cx = $GAP
                $cy += $CARD_H + $GAP
                $rowIdx++
                if ($rowIdx -lt $ROW_PATTERN.Count) { $rowCols = $ROW_PATTERN[$rowIdx] }
            } else {
                $cx += $CARD_W + $GAP
            }
        }
        $capturedLastRefresh.Text = "Last refreshed: $(Get-Date -Format 'HH:mm:ss')"
    }.GetNewClosure()

    $btnRefreshAll.Add_Click({ & $renderDashboard }.GetNewClosure())

    $loaded = $false
    $Tab.Add_Enter({
        if (-not $loaded) {
            $loaded = $true
            & $renderDashboard
        }
    }.GetNewClosure())
}
#endregion

Export-ModuleMember -Function Register-AuditTab
