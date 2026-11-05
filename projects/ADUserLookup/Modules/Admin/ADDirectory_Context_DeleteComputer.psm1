#region -- ADDirectory.Context.DeleteComputer.psm1 -----------------------------
# Concern : Invoke-DeleteComputers - permanently deletes one or more AD
#           computer objects selected in the Computers grid. Confirms once
#           for the whole batch, snapshots each computer's OU before
#           deleting it, deletes, patches the Computers cache, and opens a
#           single admin-only tracking mail summarising the batch.
# Load order: 27a - depends on ADDirectory.Computers.Load (Remove-CachedComputer),
#                            Services.AD.Reporting (Confirm-Action, Write-OperationLog),
#                            Services.AD.RecoverySnapshot (Get-ADRecoverySnapshot) [3a],
#                            Services.Mail.Send (ConvertTo-MailRecoveryBlock) [4b],
#                            Services.Mail.Dialog (Show-NotificationMailDialog) [4c]
# Split from: (new module)
# Notes     : Wired into the Computers grid's right-click menu from
#             ADDirectory.Menus (New-ComputerContextMenu), the same way
#             Test Connectivity / RDP / Radmin / Ping / MMC are wired there -
#             $TargetProvider already returns every selected row, so
#             multiselect needed no extra plumbing beyond looping over it.
#             Deletion is permanent and, unlike Disable, destroys the OU/DN
#             immediately - Get-ADRecoverySnapshot is therefore called BEFORE
#             Remove-ADComputer for every target, same ordering requirement
#             as Offboard's Move OU step and Batch Delete Groups.
#             Mail recipient is the current admin only (To = admin, no CC),
#             matching every other AdminOnly tracking mail in this suite.
# Changes   : Now returns a structured result object (OkCount / FailCount /
#             Results - a per-name Success/Message list). The Bulk
#             Operations tab's Batch Delete Computers page uses this to
#             render its own per-item OK/FAIL log without duplicating this
#             function's delete/snapshot/mail logic - purely additive,
#             existing callers are unaffected.
# v1.6.0    : Notification email trimmed to basic information: Action / DC /
#             rows repeated in the message text and the "administrative tracking
#             only" line removed.
#endregion

#region -- Invoke-DeleteComputers -----------------------------------------------
function Invoke-DeleteComputers {
    <#
    .SYNOPSIS
        Deletes the given computer object(s) from AD. Confirms once for the
        whole batch, snapshots each computer's OU before deleting it (the
        only recovery detail relevant to a computer object), removes each
        successfully-deleted computer from the Computers grid cache, and
        opens one admin-only tracking mail for the batch. Non-fatal mail -
        the AD deletion has already committed by the time it is composed.
    .PARAMETER Names
        One or more computer names (as shown in the Computers grid).
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
        if (Get-Command Invoke-SetStatus -ErrorAction SilentlyContinue) { Invoke-SetStatus 'No computer(s) selected to delete.' 'warn' }
        return $null
    }

    $preview = ($names | Select-Object -First 15) -join ', '
    if ($names.Count -gt 15) { $preview += ", ... ($($names.Count) total)" }
    $msg = "Permanently delete $($names.Count) computer object(s)?`n`n$preview`n`nThis cannot be undone."
    $code = New-ADCommandText -Cmdlet 'Remove-ADComputer' -Identity $names -Context $Context -Tail '-Confirm:$false -ErrorAction Stop' `
        -Comment 'Each computer is snapshotted first (OU, for the recovery details in the admin mail), then:'
    if (-not (Confirm-Action -Title 'Delete Computer(s)' -Message $msg -ActionLabel 'Delete' -Code $code)) { return $null }

    $srvParam = if ($Context -and $Context.TargetDC) { @{ Server = $Context.TargetDC } } else { @{} }
    $ok = 0; $fail = 0
    $deletedOk     = [System.Collections.Generic.List[string]]::new()
    $recoveryItems = [System.Collections.Generic.List[PSCustomObject]]::new()
    $itemResults   = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($name in $names) {
        # -- Recovery snapshot FIRST - Get-ADComputer only returns the DN/OU
        #    while the object still exists. Non-fatal: a missed snapshot
        #    never blocks the deletion below.
        if (Get-Command Get-ADRecoverySnapshot -ErrorAction SilentlyContinue) {
            $snap = Get-ADRecoverySnapshot -Identity $name -Type 'Computer' -SrvParam $srvParam
            if ($snap -and $snap.Found) {
                [void]$recoveryItems.Add([PSCustomObject]@{ Label = $name; OU = $snap.OU })
            }
        }

        try {
            Remove-ADComputer -Identity $name @srvParam -Confirm:$false -ErrorAction Stop
            Write-OperationLog -Context $Context -Action 'DELETE-COMPUTER' -Target $name -Result 'OK'
            [void]$deletedOk.Add($name)
            [void]$itemResults.Add([PSCustomObject]@{ Name = $name; Success = $true; Message = 'Deleted' })
            $ok++
            if (Get-Command Remove-CachedComputer -ErrorAction SilentlyContinue) {
                Remove-CachedComputer -Name $name
            }
        } catch {
            Write-OperationLog -Context $Context -Action 'DELETE-COMPUTER' -Target $name -Result 'FAIL' -Detail $_.Exception.Message
            [void]$itemResults.Add([PSCustomObject]@{ Name = $name; Success = $false; Message = $_.Exception.Message })
            $fail++
        }
    }

    $level = if ($fail -eq 0) { 'ok' } else { 'warn' }
    if (Get-Command Invoke-SetStatus -ErrorAction SilentlyContinue) {
        Invoke-SetStatus "Delete Computer(s): $ok deleted, $fail failed." $level
    }

    # -- Admin tracking mail (To admin, no CC) - one summary per batch ------
    if ($ok -gt 0 -and (Get-Command Show-NotificationMailDialog -ErrorAction SilentlyContinue)) {
        $details = [ordered]@{
            'Admin'     = if ($Context -and $Context.AdminAccount) { $Context.AdminAccount } else { "$env:USERDOMAIN\$env:USERNAME" }
            'Domain'    = if ($Context -and $Context.Domain)       { $Context.Domain }       else { $env:USERDNSDOMAIN }
            'Timestamp' = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        }

        $bodyText = "The following computer object(s) were permanently deleted:" + "`r`n`r`n" +
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
            -ActionTitle 'Computer(s) Deleted' `
            -Subject     "AD Delete Computer(s): $ok deleted, $fail failed" `
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

Export-ModuleMember -Function Invoke-DeleteComputers
