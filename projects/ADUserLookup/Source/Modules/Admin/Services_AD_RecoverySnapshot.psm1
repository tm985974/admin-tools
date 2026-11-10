#region -- Services.AD.RecoverySnapshot.psm1 ----------------------------------
# Concern : Get-ADRecoverySnapshot - single responsibility: capture the
#           "what would I need to put this back" facts for one AD object
#           (User / Group / Computer) BEFORE a caller runs a destructive or
#           state-changing operation against it (disable, strip groups, move
#           OU, delete group, delete computer, remove group member).
#
#           This function must always be called BEFORE the mutating AD call,
#           never after - once a group is deleted or a user's groups are
#           stripped, the membership/OU data is gone from AD and can only be
#           reported if it was captured first. Callers are responsible for
#           the ordering; this module only does the read.
#
#           User    -> DistinguishedName, friendly OU path, and current
#                      group memberships (excluding Domain Users) in .Groups.
#           Group   -> DistinguishedName, friendly OU path, and current
#                      member names in .Members.
#           Computer-> DistinguishedName and friendly OU path only.
#
#           Non-fatal contract:
#           Get-ADRecoverySnapshot NEVER throws. Any lookup failure (object
#           already gone, AD unreachable, insufficient rights on a nested
#           query) is captured in .Error and .Found stays $false. Callers
#           must proceed with the caller's own action regardless of whether
#           the snapshot succeeded - a missing recovery snapshot must never
#           block or fail the actual AD operation it is documenting.
#
# Load order: 3a - depends only on Services.AD.Connection.Query
#                  (Get-OUFromDN). Must load after Get-OUFromDN's module (3)
#                  and before any Context/UserActions module that captures a
#                  snapshot (Disable, Offboard, Batch Delete Groups, Delete
#                  Computer, Group Members).
# Split from: (new module)
#endregion

#region -- Get-ADRecoverySnapshot ----------------------------------------------
function Get-ADRecoverySnapshot {
    <#
    .SYNOPSIS
        Captures OU + (group memberships | group members) for one AD object,
        for use in a "before this was changed/deleted" notification email.
        Never throws. Call this BEFORE the destructive AD operation runs.
    .PARAMETER Identity
        SamAccountName (User), group Name/Identity (Group), or computer Name
        (Computer). Passed straight through to the matching Get-AD* cmdlet.
    .PARAMETER Type
        One of 'User', 'Group', 'Computer'.
    .PARAMETER SrvParam
        Hashtable such as @{ Server = $Context.TargetDC } or @{}. Same
        pattern used at every other AD call site in this project.
    .OUTPUTS
        PSCustomObject:
            Identity          [string] - the identity passed in
            Type              [string] - 'User' / 'Group' / 'Computer'
            Found             [bool]   - the base object lookup succeeded
            DistinguishedName [string] - '' if not found
            OU                [string] - friendly "Parent > Child" OU path
                                          from Get-OUFromDN, '' if not found
            Groups            [string[]] - (User only) current group names,
                                          excluding Domain Users
            Members           [string[]] - (Group only) current member names
            Error             [string] - lookup failure message, '' if none
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Identity,
        [Parameter(Mandatory)]
        [ValidateSet('User','Group','Computer')]
        [string]$Type,
        [hashtable]$SrvParam = @{}
    )

    $result = [PSCustomObject]@{
        Identity          = $Identity
        Type              = $Type
        Found             = $false
        DistinguishedName = ''
        OU                = ''
        Groups            = @()
        Members           = @()
        Error             = ''
    }

    if (-not $Identity) {
        $result.Error = 'No identity supplied.'
        return $result
    }

    try {
        switch ($Type) {
            'User' {
                $obj = Get-ADUser -Identity $Identity -Properties DistinguishedName @SrvParam -ErrorAction Stop
                $result.DistinguishedName = [string]$obj.DistinguishedName
                if (Get-Command Get-OUFromDN -ErrorAction SilentlyContinue) {
                    $result.OU = Get-OUFromDN -DN $result.DistinguishedName
                }
                $result.Found = $true

                # Group membership is a secondary, best-effort query - a
                # failure here must not blank out the OU/DN we already have.
                try {
                    $grp = Get-ADPrincipalGroupMembership -Identity $Identity @SrvParam -ErrorAction Stop |
                           Where-Object { $_.Name -ne 'Domain Users' } | Sort-Object Name
                    $result.Groups = @($grp | ForEach-Object { [string]$_.Name })
                } catch { }
            }
            'Group' {
                $obj = Get-ADGroup -Identity $Identity -Properties DistinguishedName @SrvParam -ErrorAction Stop
                $result.DistinguishedName = [string]$obj.DistinguishedName
                if (Get-Command Get-OUFromDN -ErrorAction SilentlyContinue) {
                    $result.OU = Get-OUFromDN -DN $result.DistinguishedName
                }
                $result.Found = $true

                try {
                    $mem = Get-ADGroupMember -Identity $Identity @SrvParam -ErrorAction Stop | Sort-Object Name
                    $result.Members = @($mem | ForEach-Object { [string]$_.Name })
                } catch { }
            }
            'Computer' {
                $obj = Get-ADComputer -Identity $Identity -Properties DistinguishedName @SrvParam -ErrorAction Stop
                $result.DistinguishedName = [string]$obj.DistinguishedName
                if (Get-Command Get-OUFromDN -ErrorAction SilentlyContinue) {
                    $result.OU = Get-OUFromDN -DN $result.DistinguishedName
                }
                $result.Found = $true
            }
        }
    } catch {
        $result.Error = $_.Exception.Message
    }

    return $result
}
#endregion

Export-ModuleMember -Function Get-ADRecoverySnapshot
