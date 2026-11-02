#region -- ADUserActions.CreateUser.Groups.psm1 ------------------------------
# Concern : Post-creation group assignment for new users.
#           In the current implementation, group membership is not part of the
#           Create User form UI - assignment happens via the Directory tab
#           context menu after account creation. This module owns that boundary
#           and provides Add-NewUserToGroups for future extension without
#           modifying the creation account engine.
# Load order: 34 - depends on ADUserActions.Banner (script scope),
#                            Services.AD.Reporting (Write-OperationLog)
# Split from: ADUserActions.psm1
#endregion

#region -- Add-NewUserToGroups ------------------------------------------------
function Add-NewUserToGroups {
    <#
    .SYNOPSIS
        Adds a newly created user to one or more AD groups by SAM name.
        Called after Invoke-CreateUser when groups are specified.
        No-ops silently if GroupNames is empty.
    .PARAMETER Sam
        SamAccountName of the newly created user.
    .PARAMETER GroupNames
        Array of group SAM/CN names to add the user to.
    .PARAMETER Context
        Shared PSCustomObject context (TargetDC, AdminAccount, etc.)
    #>
    param(
        [string]$Sam,
        [string[]]$GroupNames,
        [PSCustomObject]$Context
    )
    if (-not $Sam -or -not $GroupNames -or $GroupNames.Count -eq 0) { return }
    $srvParam = if ($Context -and $Context.TargetDC) { @{ Server = $Context.TargetDC } } else { @{} }
    foreach ($grp in $GroupNames) {
        if (-not $grp.Trim()) { continue }
        try {
            Add-ADGroupMember -Identity $grp -Members $Sam @srvParam -ErrorAction Stop
            Write-OperationLog -Context $Context -Action 'ADD-USER-TO-GROUP' -Target $Sam `
                -Result 'OK' -Detail "Group=$grp"
            UA-Log "  Added to group: $grp" 'ok'
        } catch {
            Write-OperationLog -Context $Context -Action 'ADD-USER-TO-GROUP' -Target $Sam `
                -Result 'FAIL' -Detail $_.Exception.Message
            UA-Log "  Failed to add to group $grp`: $($_.Exception.Message)" 'warn'
        }
    }
}
#endregion

Export-ModuleMember -Function Add-NewUserToGroups
