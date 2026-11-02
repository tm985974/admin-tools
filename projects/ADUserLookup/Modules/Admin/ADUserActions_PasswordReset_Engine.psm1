#region -- ADUserActions.PasswordReset.Engine.psm1 ---------------------------
# Concern : Invoke-ResetUserPassword - performs the AD password reset operation.
#           Called from Show-ResetPasswordDialog button handler.
# Load order: 43 - depends on ADUserActions.PasswordGenerator (New-GeneratedPassword),
#                            Services.AD.Reporting (Confirm-Action, Write-OperationLog)
# Split from: ADUserActions.psm1
# v1.6.0    : ChangePasswordAtLogon is now always written (= -MustChange, which
#             the dialog passes as $false), so a reset also clears a flag left
#             from before.
#endregion

#region -- Invoke-ResetUserPassword -------------------------------------------
function Invoke-ResetUserPassword {
    <#
    .SYNOPSIS
        Resets the AD password for the given SAM. Returns a result object.
    .OUTPUTS
        PSCustomObject: Success=$bool, Message=$string
    #>
    param(
        [string]$Sam,
        [string]$NewPassword,
        [bool]$MustChange,
        [bool]$NeverExpires,
        [PSCustomObject]$Context
    )
    if (-not $Sam -or -not $NewPassword) {
        return [PSCustomObject]@{ Success=$false; Message='SAM and password are required.' }
    }
    $srvParam = if ($Context -and $Context.TargetDC) { @{ Server = $Context.TargetDC } } else { @{} }
    try {
        $secPw = ConvertTo-SecureString $NewPassword -AsPlainText -Force
        Set-ADAccountPassword -Identity $Sam -NewPassword $secPw -Reset @srvParam -ErrorAction Stop
        # v1.6.0: always written, so a reset also clears a "must change at
        # next logon" flag left on the account from before.
        Set-ADUser -Identity $Sam -ChangePasswordAtLogon ([bool]$MustChange) @srvParam -ErrorAction Stop
        if ($NeverExpires) { Set-ADUser -Identity $Sam -PasswordNeverExpires   $true  @srvParam -ErrorAction Stop }
        Write-OperationLog -Context $Context -Action 'PASSWORD-RESET' -Target $Sam -Result 'OK' `
            -Detail "MustChange=$MustChange NeverExpires=$NeverExpires"
        return [PSCustomObject]@{ Success=$true; Message="Password reset for $Sam." }
    } catch {
        Write-OperationLog -Context $Context -Action 'PASSWORD-RESET' -Target $Sam -Result 'FAIL' -Detail $_.Exception.Message
        return [PSCustomObject]@{ Success=$false; Message="Failed: $($_.Exception.Message)" }
    }
}
#endregion

Export-ModuleMember -Function Invoke-ResetUserPassword
