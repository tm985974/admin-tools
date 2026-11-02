#region -- ADDirectory.Users.Filter.psm1 --------------------------------------
# Concern : Get-FilteredUsers - applies text filter, dropdown mode filter,
#           OU scope filter, and sort to $script:AllUsers.
# Load order: 11 - depends on ADDirectory.Users.Load (script scope),
#                            ADDirectory.Tree.Filter (Get-DirOUFilter),
#                            Services.AD.Reporting (Get-PlaceholderValue)
# Split from: ADDirectory.Tab.psm1
# Changes   : Sort-column array ($col) re-ordered to match the new Users grid
#             column order (Update-UserGrid) so header-click sorting maps to
#             the correct property by column index. Text filter still matches
#             on DisplayName, SamAccountName, UPN, Description, and Department
#             (UPN/Department remain on the cached object even though they are
#             no longer shown as columns).
#endregion

#region -- Get-FilteredUsers --------------------------------------------------
function Get-FilteredUsers {
    $text   = if ($script:UserFilter) { (Get-PlaceholderValue -TextBox $script:UserFilter).Trim().ToLower() } else { '' }
    $mode   = if ($script:UserCmbFilter) { [string]$script:UserCmbFilter.SelectedItem } else { 'All Users' }
    $ouDN   = if (Get-Command Get-DirOUFilter -ErrorAction SilentlyContinue) { Get-DirOUFilter } else { '' }
    $cutoff = (Get-Date).AddDays(-90)
    $filtered = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($u in $script:AllUsers) {
        if ($ouDN -and -not $u.DistinguishedName.ToLower().EndsWith($ouDN.ToLower())) { continue }
        if ($mode -eq 'Enabled Only'    -and $u.Enabled -ne 'True')  { continue }
        if ($mode -eq 'Disabled Only'   -and $u.Enabled -ne 'False') { continue }
        if ($mode -eq 'Never Logged In' -and $u.LastLogon -ne 'Never') { continue }
        if ($mode -eq 'Password Expired') {
            if ($u.PasswordLastSet -eq '' -or $u.PasswordLastSet -eq 'Never') { continue }
            try { if ([datetime]$u.PasswordLastSet -gt $cutoff) { continue } } catch { continue }
        }
        if ($text) {
            $hit = ($u.DisplayName.ToLower()    -like "*$text*") -or
                   ($u.SamAccountName.ToLower() -like "*$text*") -or
                   ($u.UPN.ToLower()            -like "*$text*") -or
                   ($u.Description.ToLower()    -like "*$text*") -or
                   ($u.Department.ToLower()     -like "*$text*")
            if (-not $hit) { continue }
        }
        [void]$filtered.Add($u)
    }
    # Must stay identical in order to the display columns in Update-UserGrid -
    # the header-click handler stores the clicked column index in
    # $script:UserSortCol, which is mapped to a property name here by index.
    $col  = @('DisplayName','SamAccountName','Created','Enabled','LockedOut',
              'PwNeverExpires','PasswordLastSet','LastLogon','Email','Pager','Mobile','Description')
    $prop = $col[$script:UserSortCol % $col.Count]
    if ($script:UserSortAsc) { return @($filtered | Sort-Object $prop) }
    else                     { return @($filtered | Sort-Object $prop -Descending) }
}
#endregion

Export-ModuleMember -Function Get-FilteredUsers
