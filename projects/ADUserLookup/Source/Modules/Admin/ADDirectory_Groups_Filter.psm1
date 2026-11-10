#region -- ADDirectory.Groups.Filter.psm1 -------------------------------------
# Concern : Get-FilteredGroups - applies text filter, OU scope filter, and sort
#           to $script:AllGroups. (Dropdown mode filter removed.)
# Load order: 15 - depends on ADDirectory.Groups.Load (script scope),
#                            ADDirectory.Tree.Filter (Get-DirOUFilter),
#                            Services.AD.Reporting (Get-PlaceholderValue)
# Split from: ADDirectory.Tab.psm1
#endregion

#region -- Get-FilteredGroups -------------------------------------------------
function Get-FilteredGroups {
    $text = if ($script:GrpFilter) { (Get-PlaceholderValue -TextBox $script:GrpFilter).Trim().ToLower() } else { '' }
    $ouDN = if (Get-Command Get-DirOUFilter -ErrorAction SilentlyContinue) { Get-DirOUFilter } else { '' }
    $filtered = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($g in $script:AllGroups) {
        if ($ouDN -and -not $g.DistinguishedName.ToLower().EndsWith($ouDN.ToLower())) { continue }
        if ($text) {
            $hit = ($g.Name.ToLower()        -like "*$text*") -or
                   ($g.Description.ToLower() -like "*$text*") -or
                   ($g.OU.ToLower()          -like "*$text*")
            if (-not $hit) { continue }
        }
        [void]$filtered.Add($g)
    }
    $col  = @('Name','GroupType','Scope','Description','MemberCount','Created','OU','DistinguishedName')
    $prop = $col[$script:GrpSortCol % $col.Count]
    if ($script:GrpSortAsc) { return @($filtered | Sort-Object $prop) }
    else                    { return @($filtered | Sort-Object $prop -Descending) }
}
#endregion

Export-ModuleMember -Function Get-FilteredGroups
