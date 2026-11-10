#region -- ADUserActions.Expiry.Engine.psm1 -----------------------------------
# Concern : Invoke-SetAccountExpiry / Invoke-ClearAccountExpiry - AD operations
#           for setting and clearing account expiration date.
#           Called from Show-SetExpiryDialog button handlers.
# Load order: 45 - depends on Services.AD.Reporting (Confirm-Action, Write-OperationLog)
# Split from: ADUserActions.psm1
#endregion

#region -- Invoke-SetAccountExpiry --------------------------------------------
function Invoke-SetAccountExpiry {
    <#
    .SYNOPSIS
        Sets an account expiration date in AD. Returns result object.
    #>
    param([string]$Sam, [datetime]$ExpiryDate, [PSCustomObject]$Context)
    $srvParam = if ($Context -and $Context.TargetDC) { @{ Server = $Context.TargetDC } } else { @{} }
    try {
        Set-ADAccountExpiration -Identity $Sam -DateTime $ExpiryDate @srvParam -ErrorAction Stop
        Write-OperationLog -Context $Context -Action 'SET-EXPIRY' -Target $Sam -Result 'OK' `
            -Detail "Expiry=$($ExpiryDate.ToString('yyyy-MM-dd'))"
        return [PSCustomObject]@{ Success=$true; Message="Expiry set to $($ExpiryDate.ToString('yyyy-MM-dd'))." }
    } catch {
        Write-OperationLog -Context $Context -Action 'SET-EXPIRY' -Target $Sam -Result 'FAIL' -Detail $_.Exception.Message
        return [PSCustomObject]@{ Success=$false; Message="Failed: $($_.Exception.Message)" }
    }
}
#endregion

#region -- Invoke-ClearAccountExpiry ------------------------------------------
function Invoke-ClearAccountExpiry {
    <#
    .SYNOPSIS
        Removes the account expiration date in AD. Returns result object.
    #>
    param([string]$Sam, [PSCustomObject]$Context)
    $srvParam = if ($Context -and $Context.TargetDC) { @{ Server = $Context.TargetDC } } else { @{} }
    try {
        Clear-ADAccountExpiration -Identity $Sam @srvParam -ErrorAction Stop
        Write-OperationLog -Context $Context -Action 'CLEAR-EXPIRY' -Target $Sam -Result 'OK'
        return [PSCustomObject]@{ Success=$true; Message='Expiry cleared.' }
    } catch {
        Write-OperationLog -Context $Context -Action 'CLEAR-EXPIRY' -Target $Sam -Result 'FAIL' -Detail $_.Exception.Message
        return [PSCustomObject]@{ Success=$false; Message="Failed: $($_.Exception.Message)" }
    }
}
#endregion

Export-ModuleMember -Function `
    Invoke-SetAccountExpiry, `
    Invoke-ClearAccountExpiry
