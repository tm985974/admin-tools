#region -- ADUserActions.Offboard.Groups.psm1 ---------------------------------
# Concern : Step 2 of the offboarding workflow - removes all group memberships
#           except Domain Users from the target account.
# Load order: 39 - depends on ADUserActions.Banner (script scope, UA-Log),
#                            Services.AD.Reporting (Write-OperationLog)
# Split from: ADUserActions.psm1
#endregion

#region -- Invoke-OffboardStripGroups -----------------------------------------
function Invoke-OffboardStripGroups {
    <#
    .SYNOPSIS
        Removes all AD group memberships (except Domain Users) from the given SAM.
        Returns $true on success.
    #>
    param([string]$Sam, [PSCustomObject]$Context, [hashtable]$SrvParam)
    try {
        $groups  = Get-ADPrincipalGroupMembership -Identity $Sam @SrvParam -ErrorAction Stop |
                   Where-Object { $_.Name -ne 'Domain Users' }
        $removed = 0
        foreach ($g in $groups) {
            try {
                Remove-ADGroupMember -Identity $g.DistinguishedName -Members $Sam -Confirm:$false @SrvParam -ErrorAction Stop
                $removed++
            } catch { UA-Log "    Could not remove from $($g.Name)" 'warn' }
        }
        Write-OperationLog -Context $Context -Action 'OFFBOARD-STRIP-GROUPS' -Target $Sam `
            -Result 'OK' -Detail "Removed from $removed group(s)"
        UA-Log "  [2/5] Removed from $removed group(s)." 'ok'
        return $true
    } catch {
        Write-OperationLog -Context $Context -Action 'OFFBOARD-STRIP-GROUPS' -Target $Sam `
            -Result 'FAIL' -Detail $_.Exception.Message
        UA-Log "  [2/5] Group strip failed: $($_.Exception.Message)" 'err'
        return $false
    }
}
#endregion

Export-ModuleMember -Function Invoke-OffboardStripGroups
