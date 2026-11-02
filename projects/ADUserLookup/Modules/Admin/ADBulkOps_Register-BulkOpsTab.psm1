#region -- ADBulkOps.Register-BulkOpsTab.psm1 ---------------------------------
# Concern : Register-BulkOpsTab - builds the "Bulk Operations" main-level
#           tab: a sub-TabControl with five pages consolidating every bulk
#           action in the app into one place with consistent behavior:
#             Batch Delete          - Build-BatchDeletePage - ONE page, three
#                                     independent side-by-side columns
#                                     (Users/Computers/Groups), each with its
#                                     own paste list and Delete button
#             Bulk Add Users        - Build-BulkTab (relocated from the
#                                     Tools tab, unmodified)
#             Bulk Add Groups       - Build-BatchAddGroupsPage (relocated
#                                     from a Groups-tab popup dialog)
#             Add Users to Groups   - Build-AddUsersToGroupsPage
#             Offboard              - Build-OffboardPanel (relocated from
#                                     the Account Management tab - see
#                                     Changes below)
# Load order: 91 - depends on ADBulkOps.AddUsersToGroups.Tab (Build-AddUsersToGroupsPage),
#                            ADBulkOps.BatchDelete.Tab (Build-BatchDeletePage),
#                            ADDirectory.Groups.BatchAdd (Build-BatchAddGroupsPage),
#                            ADTools.BulkOnboard.Tab (Build-BulkTab),
#                            ADUserActions.Offboard.Tab (Build-OffboardPanel) [44]
# Split from: (new module)
# Changes   : CONSOLIDATED the three separate "Batch Delete Users" /
#             "Batch Delete Computers" / "Batch Delete Groups" pages into
#             ONE "Batch Delete" page with three independent columns side
#             by side (Build-BatchDeletePage, ADBulkOps.BatchDelete.Tab) -
#             not a single merged list with automatic type detection; each
#             column still only deletes what's pasted into it, via the same
#             unchanged Invoke-DeleteUsers / Invoke-DeleteComputers /
#             Invoke-DeleteGroups functions the old three pages already
#             called. This drops the sub-tab count from 6 to 4, matching a
#             requested layout. The three superseded functions/files -
#             Build-BatchDeleteUsersPage (ADBulkOps.BatchDeleteUsers.Tab),
#             Build-BatchDeleteComputersPage (ADBulkOps.BatchDeleteComputers.Tab),
#             and Build-BatchDeleteGroupsPage (ADDirectory.Groups.BatchDelete)
#             - are no longer called from anywhere and are candidates for
#             removal from the project; they were not deleted here (only
#             edited/created files are ever touched in this workflow).
# Notes     : Build-BulkTab (moved in from ADTools.BulkOnboard.Tab, otherwise
#             completely unmodified per the "move as-is" decision) reads
#             $script:ToolsCtx directly rather than accepting a -Context
#             parameter, and Update-BulkOnboardDomainDefaults (same file,
#             called by the Domain Defaults tab's live-refresh) depends on
#             that same variable. $script:ToolsCtx is set here too - to the
#             SAME shared $Context every Register-*Tab function already
#             receives - purely so that pre-existing coupling keeps
#             resolving correctly now that Build-BulkTab is hosted under
#             this tab instead of Tools. Register-ToolsTab (still loaded,
#             still builds its own remaining sub-tabs) also sets
#             $script:ToolsCtx to the same effective value - harmless,
#             since both registrars run once at startup against the same
#             $Context object.
#             $script:_TW / $script:_TH are set to the sub-TabControl's own
#             usable size (RAW $Context.TabW / $Context.TabH, minus the
#             Activity Log strip reserved at the bottom - see next note) -
#             matching Register-ToolsTab's and Register-InfrastructureTab's
#             own convention of not pre-reducing by padding beyond what's
#             actually being carved out, since Build-BulkTab (and every
#             Build-*Page function on this tab) already does its own
#             internal PAD subtraction from whatever $script:_TW / $script:_TH
#             holds.
#             ADDED a shared Activity Log strip at the bottom of the WHOLE
#             Bulk Operations tab (below/outside the sub-TabControl, so it's
#             visible no matter which of the five sub-tabs is active,
#             without needing to duplicate it five times). Built the same
#             way the Directory tab's own Activity Log is (black background,
#             Consolas, color-coded by result), registered as an additional
#             broadcast target via Register-ActivityLogTarget
#             (Services.Logging) rather than a replacement for the Directory
#             tab's own panel - every Write-OperationLog call (which
#             Invoke-DeleteUsers/Computers/Groups and the Add Users to
#             Groups page already make internally, one per item) now
#             appears in BOTH places automatically. Backfilled with today's
#             entries via Backfill-ActivityLogTarget (writes only to this
#             one control - using Add-ActivityLogLine for the backfill
#             would have re-broadcast those same historical lines into the
#             Directory tab's Activity Log too, duplicating them there).
#             OFFBOARD RELOCATED HERE from Account Management (ADUserActions.
#             Register-UserActionsTab) - it already operates on a
#             multiselect target list, making it a bulk action in every
#             sense that just hadn't been moved yet. Build-OffboardPanel's
#             signature (-Parent -X -Y -W -H, sizing a section panel to fit
#             inside a caller-provided space) doesn't match the -Tab/
#             -Context signature every other page on this tab uses, so it
#             is NOT added to the $pages array below - it gets its own
#             TabPage and a direct call, sized to fill that whole page
#             (more room than its old half-column in Account Management
#             ever gave it). Build-OffboardPanel reads $script:UAContext
#             internally rather than accepting -Context as a parameter;
#             that variable is normally set by Register-UserActionsTab
#             (still true - Create User, which stayed there, still needs
#             it), but is now ALSO set here, directly, before the call -
#             the exact same harmless-redundant-assignment pattern already
#             used for $script:ToolsCtx above, so this page works correctly
#             regardless of which registrar happens to run first.
#             Page reset / activate hooks: a page builder may register
#             scriptblocks on its own TabPage's Tag (a hashtable):
#               Tag['Resets']    - run when that page is LEFT: either a
#                                  sub-tab switch inside Bulk Operations
#                                  (sub-TabControl Deselected) or the whole
#                                  Bulk Operations main tab being left (main
#                                  TabControl Deselected - the currently
#                                  selected sub-page is reset).
#               Tag['Activates'] - run when that page becomes visible again
#                                  (sub-TabControl Selected, or main
#                                  TabControl Selected for this tab). Used by
#                                  Offboard to reload its target list from
#                                  AD after a reset; TabPage.Add_Enter alone
#                                  does not fire until focus enters the page.
#             Clears stale paste boxes, results and "Done..." status labels
#             so they never survive a tab switch. The shared Activity Log is
#             a history and is never reset. The handlers use only their
#             event args and $script:BulkOpsTab (no captured locals) so they
#             resolve correctly at event time; each hook runs in its own
#             try/catch so one failing page cannot block the others.
#             Register-BulkOpsTab runs once per session, so the main
#             TabControl handlers are wired exactly once.
#endregion

#region -- Register-BulkOpsTab --------------------------------------------------
function Register-BulkOpsTab {
    param(
        [System.Windows.Forms.TabPage]$Tab,
        [PSCustomObject]$Context
    )
    $script:BulkOpsCtx = $Context
    $script:BulkOpsTab = $Tab
    # See module header - Build-BulkTab / Update-BulkOnboardDomainDefaults
    # (ADTools.BulkOnboard.Tab) read this directly.
    $script:ToolsCtx   = $Context
    # See module header ("OFFBOARD RELOCATED HERE") - Build-OffboardPanel
    # (ADUserActions.Offboard.Tab) reads this directly rather than taking
    # -Context as a parameter.
    $script:UAContext  = $Context

    $PAD    = 8
    $F_UI_B = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $TW     = $Context.TabW
    $TH     = $Context.TabH

    # Reserve a strip at the bottom of the WHOLE tab (outside/below the
    # sub-TabControl) for a shared Activity Log, visible regardless of
    # which of the five sub-tabs is active - see module header. $script:_TW
    # / $script:_TH (read by every Build-*Page function on this tab) are set
    # to the REDUCED usable size, so every sub-page's own layout
    # automatically leaves room for it with no changes needed to those
    # functions.
    #
    # BUG FIX: $script:_TH was originally set to the sub-TabControl's own
    # OUTER height ($SUBTAB_OUTER_H below) - but every Build-*Page function
    # lays out controls INSIDE one of that TabControl's CHILD TabPages, not
    # inside the TabControl itself, and a WinForms TabControl's own tab
    # strip consumes real vertical space (~25px) that its child TabPages'
    # client area does not include. Every page's bottom-most controls (most
    # visibly, each Batch Delete column's own Delete button) were
    # positioned assuming ~25px more usable height than actually existed
    # inside the TabPage, landing them below the true visible boundary -
    # in this case, directly behind/under the Activity Log strip added
    # below the sub-TabControl. $TAB_STRIP_H is subtracted here, once, so
    # every one of the five pages on this tab is corrected at the same
    # time - they all read the same $script:_TH.
    $TAB_STRIP_H   = 25
    $LOG_CONTENT_H = 130
    $LOG_OUTER_H   = $LOG_CONTENT_H + 25
    $LOG_Y         = $TH - $LOG_OUTER_H - $PAD
    $SUBTAB_OUTER_H = $LOG_Y - ($PAD * 2)

    $subTab          = New-Object System.Windows.Forms.TabControl
    $subTab.Location = New-Object System.Drawing.Point($PAD, $PAD)
    $subTab.Size     = New-Object System.Drawing.Size(($TW-($PAD*2)), $SUBTAB_OUTER_H)
    $subTab.Font     = $F_UI_B
    $Tab.Controls.Add($subTab)
    $script:_TW = $TW; $script:_TH = $SUBTAB_OUTER_H - $TAB_STRIP_H

    $pages = @(
        @{ Key='batchdelete'; Text='  Batch Delete  ';         Fn=${function:Build-BatchDeletePage};       NeedsContext = $true  }
        @{ Key='bulkusers';   Text='  Bulk Add Users  ';        Fn=${function:Build-BulkTab};                NeedsContext = $false }
        @{ Key='bulkgroups';  Text='  Bulk Add Groups  ';       Fn=${function:Build-BatchAddGroupsPage};     NeedsContext = $true  }
        @{ Key='addtogroups'; Text='  Add Users to Groups  ';   Fn=${function:Build-AddUsersToGroupsPage};   NeedsContext = $true  }
    )

    foreach ($p in $pages) {
        $tp           = New-Object System.Windows.Forms.TabPage
        $tp.Text      = $p.Text
        $tp.BackColor = [System.Drawing.Color]::FromArgb(235,238,242)
        $subTab.TabPages.Add($tp)

        if ($p.Fn) {
            if ($p.NeedsContext) {
                & $p.Fn -Tab $tp -Context $Context
            } else {
                & $p.Fn -Tab $tp
            }
        } else {
            $lErr           = New-Object System.Windows.Forms.Label
            $lErr.Text      = "Module for '$($p.Text.Trim())' not loaded - check Modules folder."
            $lErr.Location  = New-Object System.Drawing.Point(16, 16)
            $lErr.Size      = New-Object System.Drawing.Size(($TW-($PAD*2)-32), 24)
            $lErr.ForeColor = [System.Drawing.Color]::FromArgb(156,0,6)
            $tp.Controls.Add($lErr)
        }
    }

    # -------------------------------------------------------------------
    # Offboard - special-cased, not in $pages above, since Build-
    # OffboardPanel's signature (-Parent -X -Y -W -H) doesn't match the
    # -Tab/-Context signature every other page function here uses - see
    # module header ("OFFBOARD RELOCATED HERE"). Sized to fill the whole
    # page (minus the same $PAD every other page's own content uses).
    # -------------------------------------------------------------------
    $tpOffboard           = New-Object System.Windows.Forms.TabPage
    $tpOffboard.Text      = '  Offboard  '
    $tpOffboard.BackColor = [System.Drawing.Color]::FromArgb(235,238,242)
    $subTab.TabPages.Add($tpOffboard)

    if (Get-Command Build-OffboardPanel -ErrorAction SilentlyContinue) {
        Build-OffboardPanel -Parent $tpOffboard -X $PAD -Y $PAD `
            -W ($script:_TW - ($PAD * 2)) -H ($script:_TH - ($PAD * 2)) | Out-Null
    } else {
        $lErrOff           = New-Object System.Windows.Forms.Label
        $lErrOff.Text      = "Module for 'Offboard' not loaded - check Modules folder."
        $lErrOff.Location  = New-Object System.Drawing.Point(16, 16)
        $lErrOff.Size      = New-Object System.Drawing.Size(($TW-($PAD*2)-32), 24)
        $lErrOff.ForeColor = [System.Drawing.Color]::FromArgb(156,0,6)
        $tpOffboard.Controls.Add($lErrOff)
    }

    # -------------------------------------------------------------------
    # Page reset / activate hooks - see module header.
    # -------------------------------------------------------------------
    $subTab.Add_Deselected({
        param($s, $e)
        $tag = $e.TabPage.Tag
        if ($tag -is [hashtable] -and $tag.ContainsKey('Resets')) {
            foreach ($hook in $tag['Resets']) { try { & $hook } catch { } }
        }
    })
    $subTab.Add_Selected({
        param($s, $e)
        $tag = $e.TabPage.Tag
        if ($tag -is [hashtable] -and $tag.ContainsKey('Activates')) {
            foreach ($hook in $tag['Activates']) { try { & $hook } catch { } }
        }
    })

    $mainTabCtl = $Tab.Parent
    if ($mainTabCtl -is [System.Windows.Forms.TabControl]) {
        $mainTabCtl.Add_Deselected({
            param($s, $e)
            if (-not $script:BulkOpsTab -or $e.TabPage -ne $script:BulkOpsTab) { return }
            foreach ($c in $script:BulkOpsTab.Controls) {
                if ($c -is [System.Windows.Forms.TabControl] -and $c.SelectedTab) {
                    $tag = $c.SelectedTab.Tag
                    if ($tag -is [hashtable] -and $tag.ContainsKey('Resets')) {
                        foreach ($hook in $tag['Resets']) { try { & $hook } catch { } }
                    }
                    break
                }
            }
        })
        $mainTabCtl.Add_Selected({
            param($s, $e)
            if (-not $script:BulkOpsTab -or $e.TabPage -ne $script:BulkOpsTab) { return }
            foreach ($c in $script:BulkOpsTab.Controls) {
                if ($c -is [System.Windows.Forms.TabControl] -and $c.SelectedTab) {
                    $tag = $c.SelectedTab.Tag
                    if ($tag -is [hashtable] -and $tag.ContainsKey('Activates')) {
                        foreach ($hook in $tag['Activates']) { try { & $hook } catch { } }
                    }
                    break
                }
            }
        })
    }

    # -------------------------------------------------------------------
    # Shared Activity Log strip - visible across all five sub-tabs above.
    # See module header for why this registers as an ADDITIONAL broadcast
    # target rather than replacing the Directory tab's own Activity Log.
    # -------------------------------------------------------------------
    $logSec = New-SectionPanel -Parent $Tab -Title 'Activity Log' `
        -X $PAD -Y $LOG_Y -W ($TW-($PAD*2)) -ContentH $LOG_CONTENT_H

    $logRtb             = New-Object System.Windows.Forms.RichTextBox
    $logRtb.Location    = New-Object System.Drawing.Point(6, 0)
    $logRtb.Size        = New-Object System.Drawing.Size((($TW-($PAD*2))-14), $LOG_CONTENT_H)
    $logRtb.Font        = New-Object System.Drawing.Font('Consolas', 8.5)
    $logRtb.ReadOnly    = $true
    $logRtb.BackColor   = [System.Drawing.Color]::Black
    $logRtb.ForeColor   = [System.Drawing.Color]::FromArgb(150,150,150)
    $logRtb.BorderStyle = 'None'
    $logRtb.WordWrap    = $false
    $logRtb.ScrollBars  = 'Vertical'
    $logSec.Controls.Add($logRtb)

    if (Get-Command Register-ActivityLogTarget -ErrorAction SilentlyContinue) {
        Register-ActivityLogTarget -RichTextBox $logRtb
    }
    if (Get-Command Backfill-ActivityLogTarget -ErrorAction SilentlyContinue) {
        Backfill-ActivityLogTarget -RichTextBox $logRtb -Context $Context
    }
}
#endregion

Export-ModuleMember -Function Register-BulkOpsTab
