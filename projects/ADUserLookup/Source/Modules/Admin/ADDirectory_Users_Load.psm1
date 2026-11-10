#region -- ADDirectory.Users.Load.psm1 ----------------------------------------
# Concern : Loads all domain users into $script:AllUsers cache and triggers
#           grid refresh. Owns $script:AllUsers, $script:DirContext reference,
#           and the sort-state variables for the Users pane. Also owns the
#           targeted cache-mutation helpers (Get-CachedUsers, Update-CachedUser,
#           Add-CachedUser, Remove-CachedUser) that let other action modules
#           reflect a write result in the Users grid without a full
#           Read-DirectoryUsers requery.
# Load order: 10 - depends on Services.AD.Connection.Query (Get-DomainUsers, Get-OUFromDN),
#                            ADDirectory.Tree.Register (Invoke-SetStatus)
# Split from: ADDirectory.Tab.psm1
# Changes   : Added Remove-CachedUser, mirroring Remove-CachedComputer /
#             Remove-CachedGroup - used by the new Invoke-DeleteUsers
#             (ADDirectory.Context.DeleteUser) so a deleted account
#             disappears from the grid immediately, no AD round trip.
# Changes   : Added Email / Pager / Mobile to each cached user object (from the
#             mail(EmailAddress) / pager / mobile AD attributes) for the new
#             Users-grid columns. UPN / Department / Title / OU /
#             DistinguishedName are retained on the object even though they are
#             no longer shown as columns - Get-FilteredUsers still filters on
#             UPN, Department, and DistinguishedName.
#             Added three exported helpers so single-user write actions
#             (password reset, unlock/enable/disable, contact edit, create
#             user, bulk onboard) can update the grid without re-querying
#             every user in the current OU scope:
#               Get-CachedUsers    - read-only accessor for $script:AllUsers,
#                                     so other modules can reuse already-
#                                     loaded data instead of a fresh AD query
#                                     (e.g. Create User's "Copy Groups From").
#               Update-CachedUser  - patches one cached user's fields in place
#                                     by SamAccountName and re-renders the
#                                     grid. No-op if the user isn't currently
#                                     cached (e.g. outside the loaded OU scope).
#               Add-CachedUser     - appends a newly-created user to the cache
#                                     and re-renders the grid. No-op if that
#                                     SamAccountName is already cached.
#             None of these hit AD - they only mutate the in-memory list and
#             call Update-UserGrid, which is a pure client-side re-render.
#endregion

#region -- Shared script-scope state (Users pane) ----------------------------
$script:DirContext   = $null
$script:AllUsers     = [System.Collections.Generic.List[PSCustomObject]]::new()
$script:UserSortCol  = 0
$script:UserSortAsc  = $true
$script:UserGrid     = $null
$script:UserFilter   = $null
$script:UserCmbFilter = $null
$script:LblUserCount = $null
#endregion

#region -- Read-DirectoryUsers ------------------------------------------------
function Read-DirectoryUsers {
    if (Get-Command Write-ModuleDebugLog -ErrorAction SilentlyContinue) {
        Write-ModuleDebugLog "[Users] Read-DirectoryUsers: entered. script:DirContext present = $([bool]$script:DirContext)"
    }
    if (-not $script:DirContext) { return }
    $script:UsersFirstLoaded = $true                  # any load counts (Reload, environment change, first view)
    $ouDN = $script:DirContext.SelectedOUDN
    if (Get-Command Invoke-SetStatus -ErrorAction SilentlyContinue) { Invoke-SetStatus 'Loading users...' }
    $script:AllUsers.Clear()
    $srvParam = if ($script:DirContext.TargetDC) { @{ Server = $script:DirContext.TargetDC } } else { @{} }
    if (Get-Command Write-ModuleDebugLog -ErrorAction SilentlyContinue) {
        Write-ModuleDebugLog "[Users] Read-DirectoryUsers: SelectedOUDN='$ouDN' TargetDC='$($script:DirContext.TargetDC)'"
    }
    try {
        $raw = Get-DomainUsers -SearchBase $ouDN @srvParam -IncludeDisabled
        if (Get-Command Write-ModuleDebugLog -ErrorAction SilentlyContinue) {
            Write-ModuleDebugLog "[Users] Read-DirectoryUsers: Get-DomainUsers returned $(@($raw).Count) raw user(s)"
        }
        foreach ($u in $raw) {
            [void]$script:AllUsers.Add([PSCustomObject]@{
                DisplayName       = [string]$u.DisplayName
                SamAccountName    = [string]$u.SamAccountName
                UPN               = [string]$u.UserPrincipalName
                Enabled           = [string]$u.Enabled
                LastLogon         = if ($u.LastLogonDate) { $u.LastLogonDate.ToString('yyyy-MM-dd') } else { 'Never' }
                PasswordLastSet   = if ($u.PasswordLastSet) { $u.PasswordLastSet.ToString('yyyy-MM-dd') } else { '' }
                PwNeverExpires    = [string]$u.PasswordNeverExpires
                LockedOut         = [string]$u.LockedOut
                Created           = if ($u.whenCreated) { $u.whenCreated.ToString('yyyy-MM-dd') } else { '' }
                Description       = [string]$u.Description
                Email             = [string]$u.EmailAddress
                Pager             = [string]$u.pager
                Mobile            = [string]$u.mobile
                Department        = [string]$u.Department
                Title             = [string]$u.Title
                OU                = Get-OUFromDN -DN ([string]$u.DistinguishedName)
                DistinguishedName = [string]$u.DistinguishedName
            })
        }
        Update-UserGrid
        if (Get-Command Invoke-SetStatus -ErrorAction SilentlyContinue) { Invoke-SetStatus "$($script:AllUsers.Count) users loaded." 'ok' }
        if (Get-Command Write-ModuleDebugLog -ErrorAction SilentlyContinue) {
            Write-ModuleDebugLog "[Users] Read-DirectoryUsers: finished - $($script:AllUsers.Count) user(s) in script:AllUsers after grid update"
        }
    } catch {
        if (Get-Command Invoke-SetStatus -ErrorAction SilentlyContinue) { Invoke-SetStatus "User load failed: $($_.Exception.Message)" 'err' }
        if (Get-Command Write-ModuleDebugLog -ErrorAction SilentlyContinue) {
            Write-ModuleDebugLog "[Users] Read-DirectoryUsers: THREW [$($_.Exception.GetType().FullName)] $($_.Exception.Message)"
        }
    }
}
#endregion

#region -- Invoke-UsersFirstLoad -----------------------------------------------
# v1.2.20: the user list loads when the Users tab is first shown (or when another
# tab first asks for it through Get-CachedUsers) - not while the tab is built in
# the background right after connecting, when it froze the window.
$script:UsersFirstLoaded = $false
function Invoke-UsersFirstLoad {
    if ($script:UsersFirstLoaded) { return }
    if (-not $script:DirContext -or -not $script:DirContext.DomainDN) { return }    # not connected: try again on the next view
    Read-DirectoryUsers
}
#endregion

#region -- Get-CachedUsers -----------------------------------------------------
function Get-CachedUsers {
    <#
    .SYNOPSIS
        Read-only accessor for $script:AllUsers, the Directory tab's cached,
        OU-scoped user list. Lets other modules reuse already-loaded data
        instead of issuing a redundant full-domain AD query (e.g. Create
        User's "Copy Groups From" dropdown). Returns the live list reference;
        callers should not mutate it directly - use Update-CachedUser /
        Add-CachedUser instead so the grid stays in sync.
        v1.2.20: loads the list first if it has not been loaded yet, so a
        caller never has to run its own full-domain query.
    #>
    Invoke-UsersFirstLoad
    return $script:AllUsers
}
#endregion

#region -- Update-CachedUser ---------------------------------------------------
function Update-CachedUser {
    <#
    .SYNOPSIS
        Patches the cached user record matching $Sam in place with the given
        property values and re-renders the Users grid - no AD round trip.
        Used after a write action (password reset, unlock, enable, disable,
        contact edit, etc.) affecting a single already-loaded user, so the
        grid reflects the change immediately without a full
        Read-DirectoryUsers requery of every user in the OU scope.
        No-op if $Sam isn't currently cached (e.g. outside the loaded OU
        scope, or the Users pane hasn't loaded yet).
    .PARAMETER Sam
        SamAccountName of the user to patch.
    .PARAMETER Properties
        Hashtable of PropertyName = Value. Only keys that already exist on
        the cached object (DisplayName, SamAccountName, UPN, Enabled,
        LastLogon, PasswordLastSet, PwNeverExpires, LockedOut, Created,
        Description, Email, Pager, Mobile, Department, Title, OU,
        DistinguishedName) are applied; unrecognised keys are ignored.
    #>
    param(
        [Parameter(Mandatory)][string]$Sam,
        [Parameter(Mandatory)][hashtable]$Properties
    )
    if (-not $Sam -or -not $script:AllUsers -or $script:AllUsers.Count -eq 0) { return }
    $target = $script:AllUsers | Where-Object { $_.SamAccountName -eq $Sam } | Select-Object -First 1
    if (-not $target) { return }
    foreach ($key in $Properties.Keys) {
        if ($target.PSObject.Properties.Match($key).Count -gt 0) {
            $target.$key = $Properties[$key]
        }
    }
    if (Get-Command Update-UserGrid -ErrorAction SilentlyContinue) { Update-UserGrid }
}
#endregion

#region -- Add-CachedUser -------------------------------------------------------
function Add-CachedUser {
    <#
    .SYNOPSIS
        Appends a newly-created user to the cached Users list and re-renders
        the grid - no AD round trip. Used after Create User / Bulk Onboard so
        new accounts appear immediately without a manual Reload Directory
        Data. No-op if that SamAccountName is already cached (avoids
        duplicate rows on a retried/duplicate call).
    .PARAMETER User
        PSCustomObject describing the new user. Any of the cached-object's
        fields (DisplayName, SamAccountName, UPN, Enabled, LastLogon,
        PasswordLastSet, PwNeverExpires, LockedOut, Created, Description,
        Email, Pager, Mobile, Department, Title, OU, DistinguishedName) may
        be supplied; anything omitted defaults to a safe blank value so the
        grid never errors on a missing column.
    #>
    param([Parameter(Mandatory)][PSCustomObject]$User)
    if (-not $script:AllUsers) { return }
    if ($User.SamAccountName) {
        $existing = @($script:AllUsers | Where-Object { $_.SamAccountName -eq $User.SamAccountName })
        if ($existing.Count -gt 0) { return }
    }
    $row = [PSCustomObject]@{
        DisplayName       = ''
        SamAccountName    = ''
        UPN               = ''
        Enabled           = 'True'
        LastLogon         = 'Never'
        PasswordLastSet   = ''
        PwNeverExpires    = 'False'
        LockedOut         = 'False'
        Created           = (Get-Date -Format 'yyyy-MM-dd')
        Description       = ''
        Email             = ''
        Pager             = ''
        Mobile            = ''
        Department        = ''
        Title             = ''
        OU                = ''
        DistinguishedName = ''
    }
    foreach ($p in $User.PSObject.Properties) {
        if ($row.PSObject.Properties.Match($p.Name).Count -gt 0) { $row.($p.Name) = $p.Value }
    }
    [void]$script:AllUsers.Add($row)
    if (Get-Command Update-UserGrid -ErrorAction SilentlyContinue) { Update-UserGrid }
}
#endregion

#region -- Remove-CachedUser ---------------------------------------------------
function Remove-CachedUser {
    <#
    .SYNOPSIS
        Removes a user by SamAccountName from $script:AllUsers (the
        Directory tab's cache) and re-renders the grid - no AD round trip.
        Used by Invoke-DeleteUsers (ADDirectory.Context.DeleteUser) after a
        successful deletion, same pattern as Remove-CachedComputer
        (ADDirectory.Computers.Load) and Remove-CachedGroup
        (ADDirectory.Groups.Load). No-op if that SAM isn't currently cached
        (e.g. it was outside the loaded OU scope).
    #>
    param([Parameter(Mandatory)][string]$Sam)
    if (-not $script:AllUsers -or -not $Sam) { return }
    $matches = @($script:AllUsers | Where-Object { $_.SamAccountName -eq $Sam })
    foreach ($m in $matches) { [void]$script:AllUsers.Remove($m) }
    if (Get-Command Update-UserGrid -ErrorAction SilentlyContinue) { Update-UserGrid }
}
#endregion

Export-ModuleMember -Function `
    Read-DirectoryUsers, `
    Get-CachedUsers, `
    Update-CachedUser, `
    Add-CachedUser, `
    Remove-CachedUser
