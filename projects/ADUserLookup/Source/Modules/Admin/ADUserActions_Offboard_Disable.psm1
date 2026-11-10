#region -- ADUserActions.Offboard.Disable.psm1 --------------------------------
# Concern : Step 1 of the offboarding workflow - disables the target AD account.
#           Invoke-OffboardDisable is called by Invoke-Offboard.
# Load order: 38 - depends on ADUserActions.Banner (script scope, UA-Log),
#                            Services.AD.Reporting (Write-OperationLog)
# Split from: ADUserActions.psm1
#endregion

#region -- Invoke-OffboardDisable ---------------------------------------------
function Invoke-OffboardDisable {
    <#
    .SYNOPSIS
        Disables the AD account for the given SAM. Returns $true on success.
    #>
    param([string]$Sam, [PSCustomObject]$Context, [hashtable]$SrvParam)
    try {
        Disable-ADAccount -Identity $Sam @SrvParam -ErrorAction Stop
        Write-OperationLog -Context $Context -Action 'OFFBOARD-DISABLE' -Target $Sam -Result 'OK'
        UA-Log "  [1/5] Account disabled." 'ok'
        return $true
    } catch {
        Write-OperationLog -Context $Context -Action 'OFFBOARD-DISABLE' -Target $Sam -Result 'FAIL' -Detail $_.Exception.Message
        UA-Log "  [1/5] Disable failed: $($_.Exception.Message)" 'err'
        return $false
    }
}
#endregion

Export-ModuleMember -Function Invoke-OffboardDisable
