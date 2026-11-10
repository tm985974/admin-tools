#region -- ADDirectory.Context.DeleteGroup.psm1 -------------------------------
# Concern : Invoke-DeleteGroups - permanently deletes one or more AD group
#           objects selected in the Directory Groups grid or the OU tree.
#           Confirms once for the whole batch, snapshots each group's OU and
#           current member list before deleting, deletes, patches the
#           Groups cache, and opens a single admin-only tracking mail
#           summarising the batch. Same shape as
#           ADDirectory.Context.DeleteUser.psm1 / DeleteComputer.psm1.
# Load order: depends on ADDirectory.Groups.Load (Remove-CachedGroup),
#                        Services.AD.Reporting (Confirm-Action, Write-OperationLog),
#                        Services.AD.RecoverySnapshot (Get-ADRecoverySnapshot) [3a],
#                        Services.Mail.Send (ConvertTo-MailRecoveryBlock) [4b],
#                        Services.Mail.Dialog (Show-NotificationMailDialog) [4c]
# Split from: (new module)
# Notes     : This is the quick single/multi right-click "Delete Group"
#             action (New-GroupContextMenu, used by both the Directory
#             Groups grid and the OU tree's group leaves) - distinct from
#             the standalone Batch Delete Groups dialog
#             (ADDirectory.Groups.BatchDelete), which is a separate,
#             paste-a-list-of-names workflow with its own results log.
#             The two do not share code, but they DO follow the identical
#             recovery-snapshot + tracking-mail pattern deliberately, so an
#             admin sees the same shape of confirmation/notification
#             regardless of which path they used to delete a group.
# Changes   : Now returns a structured result object (OkCount / FailCount /
#             Results - a per-name Success/Message list). The Bulk
#             Operations tab's Batch Delete Groups page uses this to render
#             its own per-item OK/FAIL log without duplicating this
#             function's delete/snapshot/mail logic - purely additive,
#             existing callers are unaffected.
# v1.6.0    : Notification email trimmed to basic information: Action / DC /
#             rows repeated in the message text and the "administrative tracking
#             only" line removed.
#endregion

#region -- Invoke-DeleteGroups ---------------------------------------------------
function Invoke-DeleteGroups {
    <#
    .SYNOPSIS
        Deletes the given group(s) from AD. Confirms once for the whole
        batch, snapshots each group's OU and member list before deleting it,
        removes each successfully-deleted group from the Groups grid cache,
        and opens one admin-only tracking mail for the batch. Non-fatal
        mail - the AD deletion has already committed by the time it is
        composed.
    .PARAMETER Names
        One or more group names (as shown in the Directory Groups grid or
        resolved from an OU tree leaf).
    .PARAMETER Context
        Shared context object (TargetDC, AdminAccount, Domain, mail config).
    .OUTPUTS
        PSCustomObject: OkCount [int], FailCount [int], Results
        [PSCustomObject[]] - one entry per requested name with Name/Success/
        Message. $null if the batch never ran (no names given, or the
        confirmation was declined).
    #>
    param(
        [Parameter(Mandatory)]
        [string[]]$Names,
        [PSCustomObject]$Context
    )

    $names = @($Names | Where-Object { $_ } | Select-Object -Unique)
    if ($names.Count -eq 0) {
        if (Get-Command Invoke-SetStatus -ErrorAction SilentlyContinue) { Invoke-SetStatus 'No group(s) selected to delete.' 'warn' }
        return $null
    }

    $preview = ($names | Select-Object -First 15) -join ', '
    if ($names.Count -gt 15) { $preview += ", ... ($($names.Count) total)" }
    $msg = "Permanently delete $($names.Count) group(s)?`n`n$preview`n`nThis cannot be undone."
    $code = New-ADCommandText -Cmdlet 'Remove-ADGroup' -Identity $names -Context $Context -Tail '-Confirm:$false -ErrorAction Stop' `
        -Comment 'Each group is snapshotted first (OU and members, for the recovery details in the admin mail), then:'
    if (-not (Confirm-Action -Title 'Delete Group(s)' -Message $msg -ActionLabel 'Delete' -Code $code)) { return $null }

    $srvParam = if ($Context -and $Context.TargetDC) { @{ Server = $Context.TargetDC } } else { @{} }
    $ok = 0; $fail = 0
    $deletedOk     = [System.Collections.Generic.List[string]]::new()
    $recoveryItems = [System.Collections.Generic.List[PSCustomObject]]::new()
    $itemResults   = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($name in $names) {
        # -- Recovery snapshot FIRST - Get-ADGroup/Get-ADGroupMember only
        #    return data while the group still exists. Non-fatal: a missed
        #    snapshot never blocks the deletion below.
        if (Get-Command Get-ADRecoverySnapshot -ErrorAction SilentlyContinue) {
            $snap = Get-ADRecoverySnapshot -Identity $name -Type 'Group' -SrvParam $srvParam
            if ($snap -and $snap.Found) {
                [void]$recoveryItems.Add([PSCustomObject]@{
                    Label     = $name
                    OU        = $snap.OU
                    ListLabel = 'Members'
                    List      = $snap.Members
                })
            }
        }

        try {
            Remove-ADGroup -Identity $name @srvParam -Confirm:$false -ErrorAction Stop
            Write-OperationLog -Context $Context -Action 'DELETE-GROUP' -Target $name -Result 'OK'
            [void]$deletedOk.Add($name)
            [void]$itemResults.Add([PSCustomObject]@{ Name = $name; Success = $true; Message = 'Deleted' })
            $ok++
            if (Get-Command Remove-CachedGroup -ErrorAction SilentlyContinue) {
                Remove-CachedGroup -Name $name
            }
        } catch {
            Write-OperationLog -Context $Context -Action 'DELETE-GROUP' -Target $name -Result 'FAIL' -Detail $_.Exception.Message
            [void]$itemResults.Add([PSCustomObject]@{ Name = $name; Success = $false; Message = $_.Exception.Message })
            $fail++
        }
    }

    $level = if ($fail -eq 0) { 'ok' } else { 'warn' }
    if (Get-Command Invoke-SetStatus -ErrorAction SilentlyContinue) {
        Invoke-SetStatus "Delete Group(s): $ok deleted, $fail failed." $level
    }

    # -- Admin tracking mail (To admin, no CC) - one summary per batch ------
    if ($ok -gt 0 -and (Get-Command Show-NotificationMailDialog -ErrorAction SilentlyContinue)) {
        $details = [ordered]@{
            'Admin'     = if ($Context -and $Context.AdminAccount) { $Context.AdminAccount } else { "$env:USERDOMAIN\$env:USERNAME" }
            'Domain'    = if ($Context -and $Context.Domain)       { $Context.Domain }       else { $env:USERDNSDOMAIN }
            'Timestamp' = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        }

        $bodyText = "The following group(s) were permanently deleted:" + "`r`n`r`n" +
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
            -ActionTitle 'Group(s) Deleted' `
            -Subject     "AD Delete Group(s): $ok deleted, $fail failed" `
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

Export-ModuleMember -Function Invoke-DeleteGroups
