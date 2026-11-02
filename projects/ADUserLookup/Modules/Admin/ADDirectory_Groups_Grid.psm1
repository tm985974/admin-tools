#region -- ADDirectory.Groups.Grid.psm1 ---------------------------------------
# Concern : Update-GroupGrid     - pushes filtered/sorted $script:AllGroups
#                                   into the standalone Groups tab's grid.
#           Update-UserGroupGrid - pushes $script:AllUserGroups (the Users
#                                   tab's per-user membership pane) into its
#                                   own grid, sorted but not filtered.
#           Both hide the DistinguishedName column after population.
# Load order: 16 - depends on ADDirectory.Groups.Filter (Get-FilteredGroups),
#                            ADDirectory.Groups.Load (script scope),
#                            Services.AD.Reporting (Set-GridData)
# Split from: ADDirectory.Tab.psm1
# Changes   : Added Update-UserGroupGrid. The Users tab's Groups pane no
#             longer has a filter box (removed per request - a single user's
#             membership list is short enough that filtering added a control
#             for little benefit), so this renders $script:AllUserGroups
#             directly rather than going through Get-FilteredGroups. Column-
#             click sorting is still supported via $script:UserGrpSortCol/Asc,
#             wired in ADDirectory.Register-DirectoryTab.
#endregion

#region -- Update-GroupGrid ---------------------------------------------------
function Update-GroupGrid {
    if (-not $script:GrpGrid) { return }
    $data = Get-FilteredGroups
    $cols = @('Name','GroupType','Scope','Description','MemberCount','Created','OU','DistinguishedName')
    Set-GridData -Grid $script:GrpGrid -Data $data -Columns $cols
    if ($script:GrpGrid.Columns['DistinguishedName']) {
        $script:GrpGrid.Columns['DistinguishedName'].Visible = $false
    }
    if ($script:GrpGrid.Columns['MemberCount']) {
        $script:GrpGrid.Columns['MemberCount'].HeaderText = 'Member Count'
    }
    if ($script:LblGrpCount) { $script:LblGrpCount.Text = "$($data.Count) of $($script:AllGroups.Count)" }
}
#endregion

#region -- Update-UserGroupGrid -----------------------------------------------
function Update-UserGroupGrid {
    <#
    .SYNOPSIS
        Renders $script:AllUserGroups (the Users tab's per-user Groups pane)
        into $script:UserGrpGrid, sorted by $script:UserGrpSortCol/Asc. No
        text filter - this pane always shows the full membership list for
        whichever single user is currently selected.
    #>
    if (-not $script:UserGrpGrid) { return }
    $cols = @('Name','GroupType','Scope','Description','ManagedBy','Created','OU','DistinguishedName')
    $prop = $cols[$script:UserGrpSortCol % $cols.Count]
    $data = if ($script:UserGrpSortAsc) { @($script:AllUserGroups | Sort-Object $prop) }
            else                        { @($script:AllUserGroups | Sort-Object $prop -Descending) }
    Set-GridData -Grid $script:UserGrpGrid -Data $data -Columns $cols
    if ($script:UserGrpGrid.Columns['DistinguishedName']) {
        $script:UserGrpGrid.Columns['DistinguishedName'].Visible = $false
    }
    if ($script:LblUserGrpCount -and $data.Count -gt 0) {
        $script:LblUserGrpCount.Text = "$($data.Count) group(s)"
    }
}
#endregion

Export-ModuleMember -Function Update-GroupGrid, Update-UserGroupGrid
