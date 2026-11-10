#region -- ADDirectory.Computers.Load.psm1 ------------------------------------
# Concern : Loads all domain computers into $script:AllComputers cache and
#           triggers grid refresh. Owns $script:AllComputers and Computers
#           pane sort state.
# Load order: 18 - depends on Services.AD.Connection.Query (Get-DomainComputers, Get-OUFromDN),
#                            ADDirectory.Tree.Register (Invoke-SetStatus),
#                            ADDirectory.Users.Load (script:DirContext shared scope)
# Split from: ADDirectory.Tab.psm1
# Changes   : Added Remove-CachedComputer - no-AD-round-trip helper for
#             Invoke-DeleteComputers (ADDirectory.Context.DeleteComputer),
#             matching the same pattern already used for groups
#             (Remove-CachedGroup, ADDirectory.Groups.Load): patch
#             $script:AllComputers in place and re-render the grid, instead
#             of a full Read-DirectoryComputers requery after every deletion.
#endregion

#region -- Shared script-scope state (Computers pane) ------------------------
$script:AllComputers  = [System.Collections.Generic.List[PSCustomObject]]::new()
$script:CompSortCol   = 0
$script:CompSortAsc   = $true
$script:CompGrid      = $null
$script:CompFilter    = $null
$script:CompCmbFilter = $null
$script:LblCompCount  = $null
#endregion

#region -- Read-DirectoryComputers --------------------------------------------
function Read-DirectoryComputers {
    # v1.2.20: nothing in the app creates this list's grid ($script:CompGrid) or
    # reads $script:AllComputers, yet every Users-tab Reload and environment change
    # queried every computer in the OU (with a DNS lookup each) for it. Skip it.
    if (-not $script:CompGrid) { return }
    if (-not $script:DirContext) { return }
    $ouDN = $script:DirContext.SelectedOUDN
    if (Get-Command Invoke-SetStatus -ErrorAction SilentlyContinue) { Invoke-SetStatus 'Loading computers...' }
    $script:AllComputers.Clear()
    $srvParam = if ($script:DirContext.TargetDC) { @{ Server = $script:DirContext.TargetDC } } else { @{} }
    try {
        $raw = Get-DomainComputers -SearchBase $ouDN @srvParam -IncludeDisabled
        foreach ($c in $raw) {
            [void]$script:AllComputers.Add([PSCustomObject]@{
                Name              = [string]$c.Name
                Enabled           = [string]$c.Enabled
                OperatingSystem   = [string]$c.OperatingSystem
                OSVersion         = [string]$c.OperatingSystemVersion
                LastLogon         = if ($c.LastLogonDate) { $c.LastLogonDate.ToString('yyyy-MM-dd') } else { 'Never' }
                IPv4Address       = [string]$c.IPv4Address
                Created           = if ($c.whenCreated) { $c.whenCreated.ToString('yyyy-MM-dd') } else { '' }
                Description       = [string]$c.Description
                OU                = Get-OUFromDN -DN ([string]$c.DistinguishedName)
                DistinguishedName = [string]$c.DistinguishedName
            })
        }
        Update-CompGrid
        if (Get-Command Invoke-SetStatus -ErrorAction SilentlyContinue) { Invoke-SetStatus "$($script:AllComputers.Count) computers loaded." 'ok' }
    } catch {
        if (Get-Command Invoke-SetStatus -ErrorAction SilentlyContinue) { Invoke-SetStatus "Computer load failed: $($_.Exception.Message)" 'err' }
    }
}
#endregion

#region -- Remove-CachedComputer -----------------------------------------------
function Remove-CachedComputer {
    <#
    .SYNOPSIS
        Removes a computer by Name from $script:AllComputers (the Computers
        tab's cache) and re-renders the grid - no AD round trip. Used by
        Invoke-DeleteComputers after a successful deletion. No-op if that
        name isn't currently cached (e.g. it was outside the loaded OU scope).
    #>
    param([Parameter(Mandatory)][string]$Name)
    if (-not $script:AllComputers -or -not $Name) { return }
    $matches = @($script:AllComputers | Where-Object { $_.Name -eq $Name })
    foreach ($m in $matches) { [void]$script:AllComputers.Remove($m) }
    if (Get-Command Update-CompGrid -ErrorAction SilentlyContinue) { Update-CompGrid }
}
#endregion

Export-ModuleMember -Function Read-DirectoryComputers, Remove-CachedComputer
