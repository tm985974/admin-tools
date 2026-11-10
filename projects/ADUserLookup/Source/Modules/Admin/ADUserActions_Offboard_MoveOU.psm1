#region -- ADUserActions.Offboard.MoveOU.psm1 ---------------------------------
# Concern : Step 3 of the offboarding workflow - moves the target account to
#           the configured Disabled Accounts OU.
# Load order: 40 - depends on ADUserActions.Banner (script scope, UA-Log),
#                            Services.AD.Reporting (Write-OperationLog)
# Split from: ADUserActions.psm1
#endregion

#region -- Invoke-OffboardMoveOU ----------------------------------------------
function Invoke-OffboardMoveOU {
    <#
    .SYNOPSIS
        Moves the AD account to the target Disabled OU. Returns $true on success.
    #>
    param([string]$Sam, [string]$TargetOU, [PSCustomObject]$Context, [hashtable]$SrvParam)
    try {
        $uObj = Get-ADUser -Identity $Sam @SrvParam -ErrorAction Stop
        Move-ADObject -Identity $uObj.DistinguishedName -TargetPath $TargetOU @SrvParam -ErrorAction Stop
        Write-OperationLog -Context $Context -Action 'OFFBOARD-MOVE' -Target $Sam `
            -Result 'OK' -Detail "TargetOU=$TargetOU"
        UA-Log "  [3/5] Moved to $TargetOU" 'ok'
        return $true
    } catch {
        Write-OperationLog -Context $Context -Action 'OFFBOARD-MOVE' -Target $Sam `
            -Result 'FAIL' -Detail $_.Exception.Message
        UA-Log "  [3/5] Move failed: $($_.Exception.Message)" 'err'
        return $false
    }
}
#endregion

Export-ModuleMember -Function Invoke-OffboardMoveOU
