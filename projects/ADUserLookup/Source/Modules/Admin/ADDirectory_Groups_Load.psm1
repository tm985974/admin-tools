#region -- ADDirectory.Groups.Load.psm1 ---------------------------------------
# Concern : Loads group data for TWO independent consumers that used to share
#           one cache/grid:
#             1. The standalone Groups tab (Register-GroupsTab) - all domain
#                groups in OU scope. Read-DirectoryGroups populates
#                $script:AllGroups / $script:GrpGrid.
#             2. The Users tab's "Groups" pane - the currently selected
#                user's membership. Read-SelectedUserGroups populates
#                $script:AllUserGroups / $script:UserGrpGrid.
# Load order: 14 - depends on Services.AD.Connection.Query (Get-DomainGroups, Get-OUFromDN),
#                            ADDirectory.Tree.Register (Invoke-SetStatus),
#                            ADDirectory.Users.Load (script:DirContext shared scope)
# Split from: ADDirectory.Tab.psm1
# Changes   : Previously Read-DirectoryGroups was legacy/unused and
#             Read-SelectedUserGroups shared the SAME $script:AllGroups/
#             $script:GrpGrid/$script:LblGrpCount/$script:LblGrpTitle as
#             whatever consumed them - fine when only one consumer existed.
#             Now that both a standalone Groups tab (all domain groups) and
#             the Users tab's per-user membership pane exist at the same
#             time, they need separate state so switching tabs or selecting
#             a user doesn't clobber the other's grid. Read-DirectoryGroups
#             is unchanged (still owns $script:AllGroups/$script:GrpGrid).
#             Read-SelectedUserGroups now owns its own
#             $script:AllUserGroups/$script:UserGrpGrid/$script:LblUserGrpCount/
#             $script:LblUserGrpTitle and calls the new Update-UserGroupGrid
#             (ADDirectory.Groups.Grid) instead of Update-GroupGrid.
#             Added Add-CachedGroup / Remove-CachedGroup - no-AD-round-trip
#             helpers for the Batch Add/Delete Groups dialogs (ADDirectory.
#             Groups.BatchAdd / ADDirectory.Groups.BatchDelete), matching the
#             same pattern already used for users (Add-CachedUser,
#             ADDirectory.Users.Load): patch $script:AllGroups in place and
#             re-render the grid, instead of a full Read-DirectoryGroups
#             requery after every batch operation.
#endregion

#region -- Shared script-scope state (standalone Groups tab) -----------------
$script:AllGroups    = [System.Collections.Generic.List[PSCustomObject]]::new()
$script:GrpSortCol   = 0
$script:GrpSortAsc   = $true
$script:GrpGrid      = $null
$script:GrpFilter    = $null
$script:LblGrpCount  = $null
#endregion

#region -- Shared script-scope state (Users tab's per-user Groups pane) ------
$script:AllUserGroups    = [System.Collections.Generic.List[PSCustomObject]]::new()
$script:UserGrpSortCol   = 0
$script:UserGrpSortAsc   = $true
$script:UserGrpGrid      = $null
$script:LblUserGrpCount  = $null
$script:LblUserGrpTitle  = $null
#endregion

#region -- Read-DirectoryGroups -----------------------------------------------
function Read-DirectoryGroups {
    <#
    .SYNOPSIS
        Loads every group in the current OU scope into $script:AllGroups and
        refreshes the standalone Groups tab's grid. Independent of the Users
        tab's per-user membership pane.
    #>
    if (-not $script:DirContext) { return }
    $script:GroupsFirstLoaded = $true                 # any load counts (Refresh, environment change, first view)
    $ouDN = $script:DirContext.SelectedOUDN
    if (Get-Command Invoke-SetStatus -ErrorAction SilentlyContinue) { Invoke-SetStatus 'Loading groups...' }
    $script:AllGroups.Clear()
    $srvParam = if ($script:DirContext.TargetDC) { @{ Server = $script:DirContext.TargetDC } } else { @{} }
    try {
        $raw = Get-DomainGroups -SearchBase $ouDN @srvParam
        foreach ($g in $raw) {
            $managedBy = ''
            if ($g.ManagedBy) {
                if ($g.ManagedBy -match '^CN=([^,]+)') { $managedBy = $Matches[1] }
                else { $managedBy = [string]$g.ManagedBy }
            }
            [void]$script:AllGroups.Add([PSCustomObject]@{
                Name              = [string]$g.Name
                GroupType         = [string]$g.GroupCategory
                Scope             = [string]$g.GroupScope
                Description       = [string]$g.Description
                ManagedBy         = $managedBy
                MemberCount       = if ($g.Members) { [int]$g.Members.Count } else { 0 }
                Created           = if ($g.whenCreated) { $g.whenCreated.ToString('yyyy-MM-dd') } else { '' }
                OU                = Get-OUFromDN -DN ([string]$g.DistinguishedName)
                DistinguishedName = [string]$g.DistinguishedName
            })
        }
        Update-GroupGrid
        if (Get-Command Invoke-SetStatus -ErrorAction SilentlyContinue) { Invoke-SetStatus "$($script:AllGroups.Count) groups loaded." 'ok' }
    } catch {
        if (Get-Command Invoke-SetStatus -ErrorAction SilentlyContinue) { Invoke-SetStatus "Group load failed: $($_.Exception.Message)" 'err' }
    }
}
#endregion

#region -- Read-SelectedUserGroups ---------------------------------------------
function Read-SelectedUserGroups {
    <#
    .SYNOPSIS
        Populates the Users tab's Groups pane with the group membership of a
        single selected user. Pass an empty/blank -Sam to clear the pane back
        to the "select a user" prompt (used for zero- or multi-selection).
        Independent of the standalone Groups tab's $script:AllGroups/
        $script:GrpGrid.
    #>
    param([string]$Sam = '')

    $script:AllUserGroups.Clear()

    # Section header reflects the selected user; blank Sam restores 'Groups'.
    if ($script:LblUserGrpTitle) {
        if (-not $Sam) {
            $script:LblUserGrpTitle.Text = '  Groups'
        } else {
            $titleDisp = $Sam
            $srvT = if ($script:DirContext -and $script:DirContext.TargetDC) { @{ Server = $script:DirContext.TargetDC } } else { @{} }
            try {
                $uT = Get-ADUser -Identity $Sam -Properties DisplayName @srvT -ErrorAction Stop
                if ($uT.DisplayName) { $titleDisp = "$($uT.DisplayName) ($Sam)" }
            } catch { }
            $script:LblUserGrpTitle.Text = "  Groups - $titleDisp"
        }
    }

    if (-not $Sam) {
        Update-UserGroupGrid
        if ($script:LblUserGrpCount) { $script:LblUserGrpCount.Text = 'Select a single user to view group membership' }
        return
    }

    if (-not $script:DirContext) { return }
    if (Get-Command Invoke-SetStatus -ErrorAction SilentlyContinue) { Invoke-SetStatus "Loading group membership for $Sam..." }
    $srvParam = if ($script:DirContext.TargetDC) { @{ Server = $script:DirContext.TargetDC } } else { @{} }
    try {
        $memberOf = Get-ADPrincipalGroupMembership -Identity $Sam @srvParam -ErrorAction Stop
        foreach ($m in $memberOf) {
            $g = $null
            try {
                $g = Get-ADGroup -Identity $m.DistinguishedName -Properties Description,ManagedBy,whenCreated `
                     @srvParam -ErrorAction Stop
            } catch { continue }
            $managedBy = ''
            if ($g.ManagedBy) {
                if ($g.ManagedBy -match '^CN=([^,]+)') { $managedBy = $Matches[1] }
                else { $managedBy = [string]$g.ManagedBy }
            }
            [void]$script:AllUserGroups.Add([PSCustomObject]@{
                Name              = [string]$g.Name
                GroupType         = [string]$g.GroupCategory
                Scope             = [string]$g.GroupScope
                Description       = [string]$g.Description
                ManagedBy         = $managedBy
                Created           = if ($g.whenCreated) { $g.whenCreated.ToString('yyyy-MM-dd') } else { '' }
                OU                = Get-OUFromDN -DN ([string]$g.DistinguishedName)
                DistinguishedName = [string]$g.DistinguishedName
            })
        }
        Update-UserGroupGrid
        if (Get-Command Invoke-SetStatus -ErrorAction SilentlyContinue) { Invoke-SetStatus "$($script:AllUserGroups.Count) group(s) for $Sam." 'ok' }
    } catch {
        Update-UserGroupGrid
        if ($script:LblUserGrpCount) { $script:LblUserGrpCount.Text = "Could not load membership for $Sam" }
        if (Get-Command Invoke-SetStatus -ErrorAction SilentlyContinue) { Invoke-SetStatus "Membership load failed: $($_.Exception.Message)" 'err' }
    }
}
#endregion

#region -- Add-CachedGroup -----------------------------------------------------
function Add-CachedGroup {
    <#
    .SYNOPSIS
        Appends a newly-created group to $script:AllGroups (the standalone
        Groups tab's cache) and re-renders the grid - no AD round trip. Used
        by Show-BatchAddGroupsDialog so newly-created groups appear
        immediately. No-op if a group with the same Name is already cached.
    .PARAMETER Group
        PSCustomObject with any of: Name, GroupType, Scope, Description,
        ManagedBy, Created, OU, DistinguishedName. Missing fields default to
        blank/today so the grid never errors on a missing column.
    #>
    param([Parameter(Mandatory)][PSCustomObject]$Group)
    if (-not $script:AllGroups) { return }
    if ($Group.Name) {
        $existing = @($script:AllGroups | Where-Object { $_.Name -eq $Group.Name })
        if ($existing.Count -gt 0) { return }
    }
    $row = [PSCustomObject]@{
        Name              = ''
        GroupType         = ''
        Scope             = ''
        Description       = ''
        ManagedBy         = ''
        MemberCount       = 0
        Created           = (Get-Date -Format 'yyyy-MM-dd')
        OU                = ''
        DistinguishedName = ''
    }
    foreach ($p in $Group.PSObject.Properties) {
        if ($row.PSObject.Properties.Match($p.Name).Count -gt 0) { $row.($p.Name) = $p.Value }
    }
    [void]$script:AllGroups.Add($row)
    if (Get-Command Update-GroupGrid -ErrorAction SilentlyContinue) { Update-GroupGrid }
}
#endregion

#region -- Remove-CachedGroup ---------------------------------------------------
function Remove-CachedGroup {
    <#
    .SYNOPSIS
        Removes a group by Name from $script:AllGroups (the standalone
        Groups tab's cache) and re-renders the grid - no AD round trip. Used
        by Show-BatchDeleteGroupsDialog after a successful deletion. No-op if
        that name isn't currently cached.
    #>
    param([Parameter(Mandatory)][string]$Name)
    if (-not $script:AllGroups -or -not $Name) { return }
    $matches = @($script:AllGroups | Where-Object { $_.Name -eq $Name })
    foreach ($m in $matches) { [void]$script:AllGroups.Remove($m) }
    if (Get-Command Update-GroupGrid -ErrorAction SilentlyContinue) { Update-GroupGrid }
}
#endregion

Export-ModuleMember -Function `
    Read-DirectoryGroups, `
    Read-SelectedUserGroups, `
    Add-CachedGroup, `
    Remove-CachedGroup
