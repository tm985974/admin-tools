#region -- ADBulkOps.BatchDelete.Tab.psm1 -------------------------------------
# Concern : Build-BatchDeletePage - builds the consolidated "Batch Delete"
#           page of the Bulk Operations tab: three independent columns
#           (Users, Computers, Groups) side by side on one page, each with
#           its own paste list, its own Delete button, and its own results
#           log - NOT a single merged list with type auto-detection. Each
#           column deletes only what's pasted into it; the three columns
#           never interact.
#           Build-BatchDeleteColumn - private helper (not exported) that
#           builds ONE such column. Called three times by Build-
#           BatchDeletePage, once per object type.
# Load order: depends on ADDirectory.Context.DeleteUser (Invoke-DeleteUsers),
#                        ADDirectory.Context.DeleteComputer (Invoke-DeleteComputers),
#                        ADDirectory.Context.DeleteGroup (Invoke-DeleteGroups),
#                        Services.AD.Reporting (New-StdButton)
# Split from: (new module) - REPLACES three separate tab pages:
#             ADBulkOps.BatchDeleteUsers.Tab (Build-BatchDeleteUsersPage),
#             ADBulkOps.BatchDeleteComputers.Tab (Build-BatchDeleteComputersPage),
#             ADDirectory.Groups.BatchDelete (Build-BatchDeleteGroupsPage).
#             Those three functions/files are now UNUSED - nothing else in
#             the project calls them - and are candidates for removal from
#             the project. They were not deleted here (only edited/created
#             files are ever touched) - this is a call-out, not a claim
#             that they've been cleaned up.
# Notes     : Deliberately NOT a single merged list with automatic type
#             detection (paste anything, one button, auto-detect
#             User/Computer/Group per row) - that would need an extra AD
#             lookup per pasted identity just to find out what it is before
#             dispatching to the right Remove-AD* cmdlet, plus a decision
#             for the rare but real case of an ambiguous name matching more
#             than one object type. Three independent columns avoid both
#             problems entirely: the admin already knows which list they're
#             pasting into, so no detection or ambiguity handling is
#             needed - this was a deliberate design choice, not a
#             simplification for its own sake.
#             All three columns still fully delegate their actual delete
#             logic to the existing, unchanged Invoke-DeleteUsers /
#             Invoke-DeleteComputers / Invoke-DeleteGroups (confirmation,
#             recovery snapshot, cache patch, admin tracking mail all
#             happen there, identical to the grid/tree right-click actions)
#             - this page only parses each column's pasted list and renders
#             the returned OkCount/FailCount/Results into that column's own
#             log.
# BUG FIX (first version of this file): the shared column-builder was
#             originally a scriptblock stored in a local variable
#             ($buildColumn = { ... }.GetNewClosure()), invoked three times
#             via "& $buildColumn ...", with a SECOND closure built inside
#             it for each column's own Delete button
#             ($btnDelete.Add_Click({...}.GetNewClosure())). That is a
#             closure built from inside another closure that was itself
#             created from a stored scriptblock variable rather than a
#             plain function body - a combination not used anywhere else in
#             this project, and it broke: the page rendered only as far as
#             the Users column's label and textbox, then stopped entirely
#             (no status label, no button, no results box, no second or
#             third column, and - since the exception propagated all the
#             way up through Register-BulkOpsTab's foreach loop - none of
#             the OTHER THREE tabs on this page ever got built either).
#             Fixed by making the column builder a genuine top-level
#             function (Build-BatchDeleteColumn, below) instead of a stored
#             scriptblock - this matches the proven-safe pattern used by
#             every other "build one of several similar things" helper in
#             this project (Build-AuditCard, Add-AuditGridActions, etc.):
#             one ordinary function, one level of .GetNewClosure() inside
#             it for its own button handler, nothing nested inside a
#             closure that was itself built from a variable.
# Changes   : Delete buttons no longer use a custom pink BackColor - that
#             was never an actual app convention, just something applied
#             consistently across this page's own three buttons so it
#             looked intentional. Matches the app's real "emphasized
#             button" pattern instead (plain button, bold text, colored
#             ForeColor - e.g. Bulk Add Groups' "Create Groups" button uses
#             bold blue text with no background fill) - red ForeColor here
#             instead of the usual blue, to keep some visual distinction
#             for a destructive action without introducing a new styling
#             convention.
#             REMOVED the per-column results RichTextBox entirely. Every
#             OK/FAIL line these functions produced was always ALSO being
#             written to the app's shared Activity Log automatically (each
#             Invoke-Delete* function calls Write-OperationLog once per
#             item, which Services.Logging's Add-ActivityLogLine already
#             broadcasts everywhere it's registered - see
#             ADBulkOps.Register-BulkOpsTab, which now shows that log
#             directly below these three columns) - so the per-column box
#             was a redundant second copy of the same information, not a
#             distinct one. Each column's paste textbox now fills the space
#             that box used to occupy; $lStatus (a one-line "Done: X
#             deleted, Y failed" summary, or the "paste at least one ___"
#             validation message) stays, since that's inline form
#             validation/summary, not a results log, and has no equivalent
#             in the Activity Log.
#             Tab-leave reset: each Build-BatchDeleteColumn call registers a
#             reset scriptblock on the hosting TabPage's Tag['Resets'] that
#             clears that column's paste box and status label. Run by
#             ADBulkOps.Register-BulkOpsTab whenever this page is left
#             (sub-tab switch or leaving the Bulk Operations tab). Built
#             with .GetNewClosure() in this function's own body - the same
#             proven-safe single-level pattern as the Delete handler - and
#             touches only captured control locals.
#endregion

#region -- Build-BatchDeleteColumn (private - not exported) --------------------
function Build-BatchDeleteColumn {
    <#
    .SYNOPSIS
        Builds one Batch Delete column: header label, paste textbox, status
        label, Delete button, and results log. Not exported - only
        Build-BatchDeletePage (same file) calls this.
    .PARAMETER Parent
        Container to add the column's controls to (the Batch Delete TabPage).
    .PARAMETER X
    .PARAMETER Y
    .PARAMETER W
    .PARAMETER H
        Column position/size.
    .PARAMETER HeaderText
        Column heading (e.g. "Users").
    .PARAMETER ButtonText
        Delete button label (e.g. "Delete Users").
    .PARAMETER PlaceholderNoun
        Used in the "paste at least one ___" validation message (e.g.
        "username", "computer name", "group name").
    .PARAMETER InvokeAction
        A pre-wrapped scriptblock: param($ids) -> the Invoke-Delete*
        result object (OkCount/FailCount/Results) or $null. Wrapping the
        call this way (rather than passing a bare Invoke-Delete* function
        reference plus a parameter-name string) sidesteps the one real
        difference between the three delete functions that matters here:
        Invoke-DeleteUsers takes -Sams while Invoke-DeleteComputers /
        Invoke-DeleteGroups take -Names. Build this with .GetNewClosure()
        at the call site (see Build-BatchDeletePage) so it carries its own
        captured function reference and Context.
    #>
    param(
        [System.Windows.Forms.Control]$Parent,
        [int]$X, [int]$Y, [int]$W, [int]$H,
        [string]$HeaderText,
        [string]$ButtonText,
        [string]$PlaceholderNoun,
        [scriptblock]$InvokeAction
    )
    $F_UI_B = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $F_MONO = New-Object System.Drawing.Font('Consolas', 9)

    $lHeader           = New-Object System.Windows.Forms.Label
    $lHeader.Text      = $HeaderText
    $lHeader.Location  = New-Object System.Drawing.Point($X, $Y)
    $lHeader.Size      = New-Object System.Drawing.Size($W, 20)
    $lHeader.Font      = $F_UI_B
    $lHeader.ForeColor = [System.Drawing.Color]::FromArgb(0,80,160)
    $Parent.Controls.Add($lHeader)

    # No per-column results log - every OK/FAIL line from the wrapped
    # Invoke-Delete* function already reaches the shared Activity Log
    # (Services.Logging, via Write-OperationLog) automatically, so the
    # paste box fills essentially the whole column height instead of
    # sharing it with a second, redundant results box.
    $BOTTOM_H  = 18 + 4 + 30   # status label + gap + button
    $tbNamesH  = $H - 22 - 8 - $BOTTOM_H

    $tbNames               = New-Object System.Windows.Forms.TextBox
    $tbNames.Location      = New-Object System.Drawing.Point($X, ($Y + 22))
    $tbNames.Size          = New-Object System.Drawing.Size($W, $tbNamesH)
    $tbNames.Font          = $F_MONO
    $tbNames.Multiline     = $true
    $tbNames.ScrollBars    = 'Vertical'
    $tbNames.AcceptsReturn = $true
    $Parent.Controls.Add($tbNames)

    $STATUS_Y          = $Y + 22 + $tbNamesH + 8
    $lStatus           = New-Object System.Windows.Forms.Label
    $lStatus.Location  = New-Object System.Drawing.Point($X, $STATUS_Y)
    $lStatus.Size      = New-Object System.Drawing.Size($W, 18)
    $lStatus.Font      = New-Object System.Drawing.Font('Segoe UI', 8)
    $lStatus.ForeColor = [System.Drawing.Color]::DimGray
    $Parent.Controls.Add($lStatus)

    $btnDelete           = New-StdButton -Text $ButtonText -X $X -Y ($STATUS_Y + 18 + 4) -W $W -H 30 -Parent $Parent
    $btnDelete.Font      = $F_UI_B

    # Single level of closure, built directly inside this ordinary
    # function's own body - the proven-safe pattern (see module header for
    # what went wrong with the previous, nested-in-a-stored-scriptblock
    # version). $tbNames/$lStatus/$InvokeAction/$PlaceholderNoun are all
    # genuine locals/parameters of THIS function, captured reliably.
    $btnDelete.Add_Click({
        $ids = @(
            $tbNames.Text -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique
        )
        if ($ids.Count -eq 0) {
            $lStatus.ForeColor = [System.Drawing.Color]::FromArgb(156,0,6)
            $lStatus.Text      = "Paste at least one $PlaceholderNoun."
            return
        }

        # The wrapped Invoke-Delete* function shows its own confirmation,
        # recovery snapshot, delete, cache patch, and admin tracking mail -
        # identical to the grid/tree right-click action for that object
        # type - and writes one Write-OperationLog line per item, which the
        # shared Activity Log picks up automatically. Returns $null if the
        # confirmation was declined.
        $result = & $InvokeAction $ids
        if (-not $result) {
            $lStatus.ForeColor = [System.Drawing.Color]::DimGray
            $lStatus.Text      = 'Cancelled.'
            return
        }

        $lStatus.ForeColor = if ($result.FailCount -gt 0) { [System.Drawing.Color]::FromArgb(156,0,6) } else { [System.Drawing.Color]::FromArgb(0,97,0) }
        $lStatus.Text      = "Done. Deleted: $($result.OkCount)  Failed: $($result.FailCount) - see Activity Log below for detail."
    }.GetNewClosure())

    # Tab-leave reset (see module header) - registered on the hosting
    # TabPage's Tag, run by ADBulkOps.Register-BulkOpsTab.
    if (-not ($Parent.Tag -is [hashtable])) { $Parent.Tag = @{} }
    if (-not $Parent.Tag.ContainsKey('Resets')) {
        $Parent.Tag['Resets'] = New-Object System.Collections.Generic.List[scriptblock]
    }
    $Parent.Tag['Resets'].Add({
        $tbNames.Text      = ''
        $lStatus.Text      = ''
        $lStatus.ForeColor = [System.Drawing.Color]::DimGray
    }.GetNewClosure())
}
#endregion

#region -- Build-BatchDeletePage ------------------------------------------------
function Build-BatchDeletePage {
    <#
    .SYNOPSIS
        Builds the consolidated Batch Delete page: three independent
        columns (Users, Computers, Groups), each with its own paste list,
        Delete button, and results log.
    .PARAMETER Tab
        The TabPage to build into (a page of the Bulk Operations sub-tab).
    .PARAMETER Context
        Shared context object (TargetDC, AdminAccount, Domain, mail config).
    #>
    param(
        [System.Windows.Forms.TabPage]$Tab,
        [PSCustomObject]$Context
    )

    $PAD = 8
    $GAP = 20
    $TW  = $script:_TW
    $TH  = $script:_TH

    $lWarn           = New-Object System.Windows.Forms.Label
    $lWarn.Text      = 'Deletions are permanent and cannot be undone. Each column deletes independently - only the list you click Delete under is affected.'
    $lWarn.Location  = New-Object System.Drawing.Point($PAD, $PAD)
    $lWarn.Size      = New-Object System.Drawing.Size(($TW-$PAD*2), 18)
    $lWarn.Font      = New-Object System.Drawing.Font('Segoe UI', 8)
    $lWarn.ForeColor = [System.Drawing.Color]::FromArgb(156,0,6)
    $Tab.Controls.Add($lWarn)

    $COL_Y = $PAD + 26
    $COL_H = $TH - $COL_Y - $PAD
    $COL_W = [int](($TW - ($PAD * 2) - ($GAP * 2)) / 3)
    $col1X = $PAD
    $col2X = $PAD + $COL_W + $GAP
    $col3X = $PAD + (2 * ($COL_W + $GAP))

    # Cross-module function calls / $Context reads from inside the
    # .GetNewClosure() InvokeAction blocks below are unreliable by bare
    # name in this codebase (see ADDirectory.Register-DirectoryTab) -
    # captured here, invoked via & or the local reference inside.
    $invDeleteUserFn     = ${function:Invoke-DeleteUsers}
    $invDeleteComputerFn = ${function:Invoke-DeleteComputers}
    $invDeleteGroupFn    = ${function:Invoke-DeleteGroups}
    $capturedContext     = $Context

    $usersAction = {
        param($ids)
        if ($invDeleteUserFn) { & $invDeleteUserFn -Sams $ids -Context $capturedContext }
    }.GetNewClosure()

    $computersAction = {
        param($ids)
        if ($invDeleteComputerFn) { & $invDeleteComputerFn -Names $ids -Context $capturedContext }
    }.GetNewClosure()

    $groupsAction = {
        param($ids)
        if ($invDeleteGroupFn) { & $invDeleteGroupFn -Names $ids -Context $capturedContext }
    }.GetNewClosure()

    Build-BatchDeleteColumn -Parent $Tab -X $col1X -Y $COL_Y -W $COL_W -H $COL_H `
        -HeaderText 'Users' -ButtonText 'Delete Users' -PlaceholderNoun 'username' `
        -InvokeAction $usersAction

    Build-BatchDeleteColumn -Parent $Tab -X $col2X -Y $COL_Y -W $COL_W -H $COL_H `
        -HeaderText 'Computers' -ButtonText 'Delete Computers' -PlaceholderNoun 'computer name' `
        -InvokeAction $computersAction

    Build-BatchDeleteColumn -Parent $Tab -X $col3X -Y $COL_Y -W $COL_W -H $COL_H `
        -HeaderText 'Groups' -ButtonText 'Delete Groups' -PlaceholderNoun 'group name' `
        -InvokeAction $groupsAction
}
#endregion

Export-ModuleMember -Function Build-BatchDeletePage
