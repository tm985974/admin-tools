#region -- ADUserActions.CreateUser.Validate.psm1 ----------------------------
# Concern : Invoke-ValidateCreateUser - validates all required Create User
#           fields and returns a validation result object. Called by
#           Invoke-CreateUser before any AD operations are attempted.
# Load order: 31 - depends on ADUserActions.Banner (script scope)
# Split from: ADUserActions.psm1
# Changes   : Sam is now taken directly from the Logon Name field
#             ($script:UANewLogon.Text) with no separate Logon Suffix
#             append. ADUserActions.CreateUser.Tab's account-name builder
#             now bakes Logon Prefix/Suffix directly into that field's own
#             text whenever the domain's selected AccountNamePattern calls
#             for them (see that module's header) - appending Logon Suffix
#             here a second time would double it for any pattern that
#             already includes it. The field is the single source of truth
#             for the SAM base; this function no longer assembles it from
#             parts.
#endregion

#region -- Invoke-ValidateCreateUser ------------------------------------------
function Invoke-ValidateCreateUser {
    <#
    .SYNOPSIS
        Validates the Create User form fields.
        Returns [PSCustomObject]@{ Valid=$bool; Message=$string; Sam=$string; UPN=$string }
    #>
    $first     = $script:UANewFirst.Text.Trim()
    $last      = $script:UANewLast.Text.Trim()
    $sam       = $script:UANewLogon.Text.Trim()
    $upnSuffix = $script:UANewUPN.Text.Trim()
    $ouDN      = $script:UANewOUBox.Text.Trim()

    $fail = [PSCustomObject]@{ Valid=$false; Message=''; Sam=$sam; UPN="$sam$upnSuffix" }

    if (-not $first)     { $fail.Message = 'First Name is required.';  return $fail }
    if (-not $last)      { $fail.Message = 'Last Name is required.';   return $fail }
    if (-not $sam)       { $fail.Message = 'Logon Name is required.';  return $fail }
    if (-not $upnSuffix) { $fail.Message = 'UPN Suffix is required.';  return $fail }
    if (-not $ouDN)      { $fail.Message = 'Target OU is required.';   return $fail }
    if ($sam.Length -gt 20) {
        $fail.Message = "SAM must be 20 chars or fewer (currently $($sam.Length))."
        return $fail
    }
    if ($sam -match '[^a-zA-Z0-9.\-_]') {
        $fail.Message = 'Logon Name: only a-z A-Z 0-9 . - _ allowed.'
        return $fail
    }

    return [PSCustomObject]@{ Valid=$true; Message=''; Sam=$sam; UPN="$sam$upnSuffix" }
}
#endregion

Export-ModuleMember -Function Invoke-ValidateCreateUser
