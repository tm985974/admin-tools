#region -- ADDirectory.Computers.Filter.psm1 ----------------------------------
# Concern : Get-FilteredComputers - applies text filter, dropdown mode filter,
#           OU scope filter, stale threshold, and sort to $script:AllComputers.
# Load order: 19 - depends on ADDirectory.Computers.Load (script scope),
#                            ADDirectory.Tree.Filter (Get-DirOUFilter),
#                            Services.AD.Reporting (Get-PlaceholderValue)
# Split from: ADDirectory.Tab.psm1
#endregion

#region -- Get-FilteredComputers ----------------------------------------------
function Get-FilteredComputers {
    $text   = if ($script:CompFilter) { (Get-PlaceholderValue -TextBox $script:CompFilter).Trim().ToLower() } else { '' }
    $mode   = if ($script:CompCmbFilter) { [string]$script:CompCmbFilter.SelectedItem } else { 'All Computers' }
    $ouDN   = if (Get-Command Get-DirOUFilter -ErrorAction SilentlyContinue) { Get-DirOUFilter } else { '' }
    $cutoff = (Get-Date).AddDays(-90)
    $filtered = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($c in $script:AllComputers) {
        if ($ouDN -and -not $c.DistinguishedName.ToLower().EndsWith($ouDN.ToLower())) { continue }
        if ($mode -eq 'Enabled Only'      -and $c.Enabled -ne 'True')                 { continue }
        if ($mode -eq 'Disabled Only'     -and $c.Enabled -ne 'False')                { continue }
        if ($mode -eq 'Servers Only'      -and $c.OperatingSystem -notmatch 'Server') { continue }
        if ($mode -eq 'Workstations Only' -and $c.OperatingSystem -match 'Server')    { continue }
        if ($mode -eq 'Stale (90+ days)') {
            if ($c.LastLogon -ne 'Never') {
                try { if ([datetime]$c.LastLogon -gt $cutoff) { continue } } catch { }
            }
        }
        if ($text) {
            $hit = ($c.Name.ToLower()            -like "*$text*") -or
                   ($c.OperatingSystem.ToLower() -like "*$text*") -or
                   ($c.Description.ToLower()     -like "*$text*") -or
                   ($c.IPv4Address.ToLower()     -like "*$text*")
            if (-not $hit) { continue }
        }
        [void]$filtered.Add($c)
    }
    $col  = @('Name','Enabled','OperatingSystem','OSVersion','LastLogon','IPv4Address','Created','Description','OU')
    $prop = $col[$script:CompSortCol % $col.Count]
    if ($script:CompSortAsc) { return @($filtered | Sort-Object $prop) }
    else                     { return @($filtered | Sort-Object $prop -Descending) }
}
#endregion

Export-ModuleMember -Function Get-FilteredComputers
