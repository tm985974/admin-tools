#region -- ADDirectory.Context.DeleteUser.psm1 --------------------------------
# Concern : Invoke-DeleteUsers - permanently deletes one or more AD user
#           objects selected in the Directory Users grid or the OU tree.
#           Confirms once for the whole batch, snapshots each user's OU and
#           current group memberships before deleting, deletes, patches the
#           Users cache, and opens a single admin-only tracking mail
#           summarising the batch. Mirrors
#           ADDirectory.Context.DeleteComputer.psm1's Invoke-DeleteComputers
#           exactly - same shape, same ordering guarantees, same non-fatal
#           mail contract - so the two most destructive object-deletion
#           paths in this app behave identically from an operator's
#           perspective.
# Load order: depends on ADDirectory.Users.Load (Remove-CachedUser),
#                        Services.AD.Reporting (Confirm-Action, Write-OperationLog),
#                        Services.AD.RecoverySnapshot (Get-ADRecoverySnapshot) [3a],
#                        Services.Mail.Send (ConvertTo-MailRecoveryBlock) [4b],
#                        Services.Mail.Dialog (Show-NotificationMailDialog) [4c]
# Split from: (new module)
# Notes     : This does NOT run the Offboard workflow's cleanup steps first
#             (no group-strip, no OU move, no home-folder handling) - it is
#             a direct Remove-ADUser, exactly like Invoke-DeleteComputers is
#             a direct Remove-ADComputer. AD cascades the removal itself
#             (group memberships are automatically cleaned up by AD when the
#             user object is deleted). If a "clean up first, then delete"
#             workflow is ever wanted for users, that is the existing
#             Offboard tab's job, not this quick right-click action -
#             deliberately kept as simple and predictable as Delete
#             Computer(s) rather than silently doing extra work a computer
#             deletion doesn't also do.
#             The recovery snapshot (OU + group memberships) is still taken
#             BEFORE the delete, same as every other destructive action in
#             this suite, purely so the tracking mail can tell the admin
#             what the account's memberships were at the moment of deletion,
#             even though AD itself doesn't preserve that information once
#             the object is gone.
# Changes   : Now returns a structured result object (OkCount / FailCount /
#             Results - a per-SAM Success/Message list), so a caller that
#             wants to show its own per-item OK/FAIL log (the new Bulk
#             Operations tab's Batch Delete Users page) can do so without
#             duplicating this function's delete/snapshot/mail logic. Purely
#             additive - existing callers (ADDirectory.Menus' right-click
#             "Delete User(s)...") already invoke this via & without
#             capturing output, so they are unaffected.
# v1.6.0    : Notification email trimmed to basic information: Action / DC /
#             rows repeated in the message text and the "administrative tracking
#             only" line removed.
#endregion

#region -- Invoke-DeleteUsers ---------------------------------------------------
function Invoke-DeleteUsers {
    <#
    .SYNOPSIS
        Deletes the given user account(s) from AD. Confirms once for the
        whole batch, snapshots each user's OU and group memberships before
        deleting it, removes each successfully-deleted user from the Users
        grid cache, and opens one admin-only tracking mail for the batch.
        Non-fatal mail - the AD deletion has already committed by the time
        it is composed.
    .PARAMETER Sams
        One or more SamAccountNames (as shown in the Directory Users grid or
        resolved from an OU tree leaf).
    .PARAMETER Context
        Shared context object (TargetDC, AdminAccount, Domain, mail config).
    .OUTPUTS
        PSCustomObject: OkCount [int], FailCount [int], Results
        [PSCustomObject[]] - one entry per requested SAM with Name/Success/
        Message. $null if the batch never ran (no SAMs given, or the
        confirmation was declined).
    #>
    param(
        [Parameter(Mandatory)]
        [string[]]$Sams,
        [PSCustomObject]$Context
    )

    $sams = @($Sams | Where-Object { $_ } | Select-Object -Unique)
    if ($sams.Count -eq 0) {
        if (Get-Command Invoke-SetStatus -ErrorAction SilentlyContinue) { Invoke-SetStatus 'No user(s) selected to delete.' 'warn' }
        return $null
    }

    $preview = ($sams | Select-Object -First 15) -join ', '
    if ($sams.Count -gt 15) { $preview += ", ... ($($sams.Count) total)" }
    $msg = "Permanently delete $($sams.Count) user account(s)?`n`n$preview`n`nThis cannot be undone."
    if (-not (Confirm-Action -Title 'Delete User(s)' -Message $msg -ActionLabel 'Delete')) { return $null }

    $srvParam = if ($Context -and $Context.TargetDC) { @{ Server = $Context.TargetDC } } else { @{} }
    $ok = 0; $fail = 0
    $deletedOk     = [System.Collections.Generic.List[string]]::new()
    $recoveryItems = [System.Collections.Generic.List[PSCustomObject]]::new()
    $itemResults   = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($sam in $sams) {
        # -- Recovery snapshot FIRST - Get-ADUser/Get-ADPrincipalGroupMembership
        #    only return data while the object still exists. Non-fatal: a
        #    missed snapshot never blocks the deletion below.
        if (Get-Command Get-ADRecoverySnapshot -ErrorAction SilentlyContinue) {
            $snap = Get-ADRecoverySnapshot -Identity $sam -Type 'User' -SrvParam $srvParam
            if ($snap -and $snap.Found) {
                [void]$recoveryItems.Add([PSCustomObject]@{
                    Label     = $sam
                    OU        = $snap.OU
                    ListLabel = 'Groups'
                    List      = $snap.Groups
                })
            }
        }

        try {
            Remove-ADUser -Identity $sam @srvParam -Confirm:$false -ErrorAction Stop
            Write-OperationLog -Context $Context -Action 'DELETE-USER' -Target $sam -Result 'OK'
            [void]$deletedOk.Add($sam)
            [void]$itemResults.Add([PSCustomObject]@{ Name = $sam; Success = $true; Message = 'Deleted' })
            $ok++
            if (Get-Command Remove-CachedUser -ErrorAction SilentlyContinue) {
                Remove-CachedUser -Sam $sam
            }
        } catch {
            Write-OperationLog -Context $Context -Action 'DELETE-USER' -Target $sam -Result 'FAIL' -Detail $_.Exception.Message
            [void]$itemResults.Add([PSCustomObject]@{ Name = $sam; Success = $false; Message = $_.Exception.Message })
            $fail++
        }
    }

    $level = if ($fail -eq 0) { 'ok' } else { 'warn' }
    if (Get-Command Invoke-SetStatus -ErrorAction SilentlyContinue) {
        Invoke-SetStatus "Delete User(s): $ok deleted, $fail failed." $level
    }

    # -- Admin tracking mail (To admin, no CC) - one summary per batch ------
    if ($ok -gt 0 -and (Get-Command Show-NotificationMailDialog -ErrorAction SilentlyContinue)) {
        $details = [ordered]@{
            'Admin'     = if ($Context -and $Context.AdminAccount) { $Context.AdminAccount } else { "$env:USERDOMAIN\$env:USERNAME" }
            'Domain'    = if ($Context -and $Context.Domain)       { $Context.Domain }       else { $env:USERDNSDOMAIN }
            'Timestamp' = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        }

        $bodyText = "The following user account(s) were permanently deleted:" + "`r`n`r`n" +
                    (($deletedOk | ForEach-Object { "- " + $_ }) -join "`r`n") + "`r`n`r`n" +
                    "Batch result: $ok deleted, $fail failed."

        $recoverySubset = @($recoveryItems | Where-Object { $deletedOk -contains $_.Label })
        if ($recoverySubset.Count -gt 0 -and (Get-Command ConvertTo-MailRecoveryBlock -ErrorAction SilentlyContinue)) {
            $recoveryBlock = ConvertTo-MailRecoveryBlock -Items $recoverySubset `
                -Heading 'Recovery details (state immediately before deletion):'
            if ($recoveryBlock) {
                $bodyText += "`r`n`r`n" + $recoveryBlock
            }
        }

        Show-NotificationMailDialog `
            -Context     $Context `
            -Sam         '' `
            -ActionTitle 'User(s) Deleted' `
            -Subject     "AD Delete User(s): $ok deleted, $fail failed" `
            -Details     $details `
            -BodyText    $bodyText `
            -AdminOnly
    }

    return [PSCustomObject]@{
        OkCount   = $ok
        FailCount = $fail
        Results   = $itemResults
    }
}
#endregion

Export-ModuleMember -Function Invoke-DeleteUsers
