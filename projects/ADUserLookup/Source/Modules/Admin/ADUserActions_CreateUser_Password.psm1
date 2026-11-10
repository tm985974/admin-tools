#region -- ADUserActions.CreateUser.Password.psm1 ----------------------------
# Concern : Password-related helpers used during user creation.
#           Get-CreateUserPassword - returns the current password from the
#           create-user form's password box.
# Load order: 32 - depends on ADUserActions.Banner (script scope),
#                            ADUserActions.PasswordGenerator (New-GeneratedPassword)
# Split from: ADUserActions.psm1
#endregion

#region -- Get-CreateUserPassword ---------------------------------------------
function Get-CreateUserPassword {
    <#
    .SYNOPSIS
        Returns the current password displayed in the Create User password box.
        Generates a new one if the box is empty.
    #>
    $pw = if ($script:UACrPwBox) { $script:UACrPwBox.Text.Trim() } else { '' }
    if (-not $pw) { $pw = New-GeneratedPassword }
    return $pw
}
#endregion

Export-ModuleMember -Function Get-CreateUserPassword
