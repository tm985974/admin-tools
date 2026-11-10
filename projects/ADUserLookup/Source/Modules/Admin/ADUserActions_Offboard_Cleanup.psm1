#region -- ADUserActions.Offboard.Cleanup.psm1 --------------------------------
# Concern : Steps 4 and 5 of the offboarding workflow, plus the orchestrator.
#           Invoke-OffboardStamp    - sets description with date/admin/note stamp.
#           Invoke-OffboardPwReset  - randomises the account password.
#           Invoke-Offboard         - orchestrates all 5 steps across every
#                                     selected row in the target grid,
#                                     running only the steps whose checkbox
#                                     is checked.
# Load order: 41 - depends on ADUserActions.Banner (script scope, UA-Log),
#                            ADUserActions.PasswordGenerator (New-GeneratedPassword),
#                            ADUserActions.Offboard.Disable (Invoke-OffboardDisable),
#                            ADUserActions.Offboard.Groups (Invoke-OffboardStripGroups),
#                            ADUserActions.Offboard.MoveOU (Invoke-OffboardMoveOU),
#                            ADUserActions.Offboard.TargetList (Read-OffboardTargetUsers),
#                            Services.AD.Reporting (Confirm-Action, Write-OperationLog),
#                            Services.AD.RecoverySnapshot (Get-ADRecoverySnapshot) [3a],
#                            Services.Mail.Send (ConvertTo-MailRecoveryBlock) [4b],
#                            Services.Mail.Dialog (Show-NotificationMailDialog) [4c]
# Split from: ADUserActions.psm1
# Changes   : Invoke-Offboard rewritten. Previously operated on a single
#             $script:UAContext.SelectedUser (set via the Directory tab) and
#             ran all 5 steps unconditionally. Now reads every selected row
#             from $script:UAOffTargetGrid (the tab's own multiselect AD user
#             list, built by ADUserActions.Offboard.Tab) and runs only the
#             steps whose checkbox ($script:UAOffChkDisable/ChkGroups/
#             ChkMoveOU/ChkStamp/ChkPwReset, also set by the Tab module) is
#             checked, for every selected account. Per-account error counts
#             roll up into a batch OK/fail summary. Refreshes the target list
#             after a run so processed accounts drop out of view.
#             Admin tracking mail added: after the batch completes, opens
#             Show-NotificationMailDialog -AdminOnly (To = admin, no CC) with
#             a documentation summary listing every processed account (with
#             per-account OK / error outcome) and a full 5-step checklist
#             marking which steps were selected/performed. Fires once per run
#             (whenever at least one account was processed), guarded by
#             Get-Command. Non-fatal.
#             Recovery snapshot added: each account's OU and current group
#             memberships are captured via Get-ADRecoverySnapshot at the TOP
#             of the per-account loop, BEFORE any of the 5 steps run - this
#             is the only point at which that data still reflects the
#             pre-offboarding state, since Strip Groups and Move OU steps
#             (when checked) destroy it. Captured unconditionally regardless
#             of which steps are checked, since even a Disable-only run
#             benefits from having the account's OU/groups on record. The
#             per-account recovery blocks (via ConvertTo-MailRecoveryBlock)
#             are appended to the existing tracking mail's BodyText, after
#             the checklist and result lines. A snapshot failure for one
#             account (Get-Command guarded, and the snapshot function itself
#             never throws) never blocks that account's actual offboarding
#             steps or the batch as a whole - it just omits that account's
#             recovery block.
# v1.6.0    : Notification email trimmed to basic information: Action / DC /
#             rows repeated in the message text and the "administrative tracking
#             only" line removed.
#endregion

#region -- Invoke-OffboardStamp -----------------------------------------------
function Invoke-OffboardStamp {
    param([string]$Sam, [string]$Stamp, [PSCustomObject]$Context, [hashtable]$SrvParam)
    try {
        Set-ADUser -Identity $Sam -Description $Stamp @SrvParam -ErrorAction Stop
        Write-OperationLog -Context $Context -Action 'OFFBOARD-STAMP' -Target $Sam -Result 'OK' -Detail $Stamp
        UA-Log "  Description stamped: $Stamp" 'ok'
        return $true
    } catch {
        Write-OperationLog -Context $Context -Action 'OFFBOARD-STAMP' -Target $Sam `
            -Result 'FAIL' -Detail $_.Exception.Message
        UA-Log "  Stamp failed: $($_.Exception.Message)" 'err'
        return $false
    }
}
#endregion

#region -- Invoke-OffboardPwReset ---------------------------------------------
function Invoke-OffboardPwReset {
    param([string]$Sam, [PSCustomObject]$Context, [hashtable]$SrvParam)
    try {
        $rndPw = New-GeneratedPassword
        $secPw = ConvertTo-SecureString $rndPw -AsPlainText -Force
        Set-ADAccountPassword -Identity $Sam -NewPassword $secPw -Reset @SrvParam -ErrorAction Stop
        Write-OperationLog -Context $Context -Action 'OFFBOARD-PWRESET' -Target $Sam -Result 'OK'
        UA-Log "  Password randomized." 'ok'
        return $true
    } catch {
        Write-OperationLog -Context $Context -Action 'OFFBOARD-PWRESET' -Target $Sam `
            -Result 'FAIL' -Detail $_.Exception.Message
        UA-Log "  Password reset failed: $($_.Exception.Message)" 'err'
        return $false
    }
}
#endregion

#region -- Invoke-Offboard ----------------------------------------------------
function Invoke-Offboard {
    <#
    .SYNOPSIS
        Runs the checked offboarding step(s) against every row currently
        selected in $script:UAOffTargetGrid. Confirms once for the whole
        batch (listing steps and up to 10 account names), then processes
        each account in turn, logging per-account and rolling up a batch
        OK/fail summary. Refreshes the target list on completion. Opens an
        admin-only tracking mail popup summarising the run, including a
        recovery block (OU + prior group memberships) per account captured
        before that account's steps ran.
    #>
    if (-not $script:UAOffTargetGrid) { UA-Log 'Offboard target list not initialised.' 'warn'; return }

    $rows = @($script:UAOffTargetGrid.SelectedRows)
    if ($rows.Count -eq 0) {
        UA-Log 'No target users selected for offboarding.' 'warn'
        return
    }

    $disabledOU = if ($script:UAOffOUBox) { $script:UAOffOUBox.Text.Trim() } else { '' }

    $doDisable = [bool]($script:UAOffChkDisable -and $script:UAOffChkDisable.Checked)
    $doGroups  = [bool]($script:UAOffChkGroups  -and $script:UAOffChkGroups.Checked)
    $doMoveOU  = [bool]($script:UAOffChkMoveOU  -and $script:UAOffChkMoveOU.Checked)
    $doStamp   = [bool]($script:UAOffChkStamp   -and $script:UAOffChkStamp.Checked)
    $doPwReset = [bool]($script:UAOffChkPwReset -and $script:UAOffChkPwReset.Checked)

    if (-not ($doDisable -or $doGroups -or $doMoveOU -or $doStamp -or $doPwReset)) {
        UA-Log 'No offboarding steps are checked - nothing to do.' 'warn'
        return
    }

    # The Disabled OU is only required when step 3 (Move to Disabled OU) is
    # actually checked - previously this was checked unconditionally, which
    # blocked every run (including Disable/Stamp/Reset-only runs) whenever
    # the OU field was empty, even though Move to Disabled OU defaults off.
    if ($doMoveOU -and -not $disabledOU) {
        UA-Log 'Select a Disabled Accounts OU before running offboarding (Move to Disabled OU is checked).' 'warn'
        return
    }

    $note = if ($script:UAOffNote) { $script:UAOffNote.Text.Trim() } else { '' }

    $stepLines = @()
    if ($doDisable) { $stepLines += '1. Disable the account' }
    if ($doGroups)  { $stepLines += '2. Remove all group memberships' }
    if ($doMoveOU)  { $stepLines += "3. Move to $disabledOU" }
    if ($doStamp)   { $stepLines += '4. Stamp description' }
    if ($doPwReset) { $stepLines += '5. Reset password to random value' }

    $names = @($rows | ForEach-Object {
        $d = [string]$_.Cells['DisplayName'].Value
        $s = [string]$_.Cells['SamAccountName'].Value
        if ($d) { "$d ($s)" } else { $s }
    })
    $nameList = ($names | Select-Object -First 10) -join "`n  "
    $moreLine = if ($names.Count -gt 10) { "`n  ...and $($names.Count - 10) more" } else { '' }

    $offboardMsg = "Run offboarding for $($rows.Count) selected account(s)?`n`n" +
                   "Steps:`n  $($stepLines -join "`n  ")`n`n" +
                   "Accounts:`n  $nameList$moreLine`n`n" +
                   "THIS CANNOT BE EASILY UNDONE."
    $srvParam = if ($script:UAContext.TargetDC) { @{ Server = $script:UAContext.TargetDC } } else { @{} }
    $admin    = $script:UAContext.AdminAccount
    $ts       = Get-Date -Format 'yyyy-MM-dd'
    $stamp    = "DISABLED $ts by $admin$(if ($note) { " | $note" })"

    # The command window shows the exact steps (template rule). The random password
    # is made per account at run time, so it shows as a generated value.
    $srvText = $(if ($script:UAContext.TargetDC) { ' -Server ' + (Format-AppCommandValue ([string]$script:UAContext.TargetDC)) } else { '' })
    $sams = [string[]]@($rows | ForEach-Object { [string]$_.Cells['SamAccountName'].Value } | Where-Object { $_ })
    $body = @()
    if ($doDisable) { $body += "    Disable-ADAccount -Identity `$sam$srvText" }
    if ($doGroups)  { $body += "    Get-ADPrincipalGroupMembership -Identity `$sam$srvText | Where-Object { `$_.Name -ne 'Domain Users' } | ForEach-Object { Remove-ADGroupMember -Identity `$_.DistinguishedName -Members `$sam -Confirm:`$false$srvText }" }
    if ($doMoveOU)  { $body += "    Move-ADObject -Identity (Get-ADUser -Identity `$sam$srvText).DistinguishedName -TargetPath " + (Format-AppCommandValue $disabledOU) + $srvText }
    if ($doStamp)   { $body += "    Set-ADUser -Identity `$sam -Description " + (Format-AppCommandValue $stamp) + $srvText }
    if ($doPwReset) { $body += "    Set-ADAccountPassword -Identity `$sam -Reset -NewPassword (ConvertTo-SecureString (New-GeneratedPassword) -AsPlainText -Force)$srvText" }
    $code = "# Each account's OU and groups are saved first (recovery block in the tracking mail).`r`n" +
            'foreach ($sam in ' + (Format-AppCommandValue $sams) + ") {`r`n" + ($body -join "`r`n") + "`r`n}"

    if (-not (Confirm-Action -Title 'Run Offboarding' -Message $offboardMsg -ActionLabel 'Run Offboarding' -Code $code)) { return }

    $okCount   = 0
    $failCount = 0
    # Per-account outcome lines for the tracking mail body.
    $resultLines = [System.Collections.Generic.List[string]]::new()
    # Per-account recovery snapshots (OU + prior groups), captured before that
    # account's steps run - see module header. One entry per account that was
    # successfully snapshotted; a snapshot miss just omits that account here.
    $recoveryItems = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($row in $rows) {
        $sam = [string]$row.Cells['SamAccountName'].Value
        if (-not $sam) { continue }
        $disp   = [string]$row.Cells['DisplayName'].Value
        $label  = if ($disp) { "$disp ($sam)" } else { $sam }
        $errors = 0

        # -- Recovery snapshot FIRST - before any step below can move the
        #    account or strip its groups. Non-fatal: a failed/missing
        #    snapshot never blocks the actual offboarding steps.
        if (Get-Command Get-ADRecoverySnapshot -ErrorAction SilentlyContinue) {
            $snap = Get-ADRecoverySnapshot -Identity $sam -Type User -SrvParam $srvParam
            if ($snap -and $snap.Found) {
                [void]$recoveryItems.Add([PSCustomObject]@{
                    Label     = $label
                    OU        = $snap.OU
                    ListLabel = 'Groups'
                    List      = $snap.Groups
                })
            }
        }

        UA-Log "Starting offboarding for $sam ..." 'info'

        if ($doDisable -and -not (Invoke-OffboardDisable      -Sam $sam -Context $script:UAContext -SrvParam $srvParam)) { $errors++ }
        if ($doGroups  -and -not (Invoke-OffboardStripGroups  -Sam $sam -Context $script:UAContext -SrvParam $srvParam)) { $errors++ }
        if ($doMoveOU  -and -not (Invoke-OffboardMoveOU       -Sam $sam -TargetOU $disabledOU -Context $script:UAContext -SrvParam $srvParam)) { $errors++ }
        if ($doStamp   -and -not (Invoke-OffboardStamp        -Sam $sam -Stamp $stamp -Context $script:UAContext -SrvParam $srvParam)) { $errors++ }
        if ($doPwReset -and -not (Invoke-OffboardPwReset      -Sam $sam -Context $script:UAContext -SrvParam $srvParam)) { $errors++ }

        if ($errors -eq 0) {
            $okCount++
            [void]$resultLines.Add("- $label : OK")
            UA-Log "Offboarding complete for $sam. No errors." 'ok'
        } else {
            $failCount++
            [void]$resultLines.Add("- $label : $errors error(s)")
            UA-Log "Offboarding complete for $sam with $errors error(s). Review log." 'warn'
        }
    }

    $level = if ($failCount -eq 0) { 'ok' } else { 'warn' }
    UA-Log "Offboarding batch complete: $okCount account(s) OK, $failCount with errors." $level
    if (Get-Command Set-Status -ErrorAction SilentlyContinue) {
        Set-Status "Offboarding: $okCount OK, $failCount with errors." $level
    }

    # -- Admin tracking mail (To admin, no CC) - one summary per run --------
    # Documentation record of the offboarding batch: every processed account
    # with its OK/error outcome, plus a full 5-step checklist showing which
    # steps were selected/performed, plus a recovery block per account (OU +
    # prior group memberships, captured before this run touched the account).
    # Non-fatal - the AD work is already done.
    if (($okCount + $failCount) -gt 0 -and (Get-Command Show-NotificationMailDialog -ErrorAction SilentlyContinue)) {
        $ctx = $script:UAContext

        # Full 5-step checklist: [X] selected/performed, [ ] skipped.
        $mk = { param($on, $text) ($(if ($on) { '[X] ' } else { '[ ] ' }) + $text) }
        $checklist = @(
            (& $mk $doDisable '1. Disable the account'),
            (& $mk $doGroups  '2. Remove all group memberships'),
            (& $mk $doMoveOU  "3. Move to Disabled OU$(if ($doMoveOU -and $disabledOU) { " ($disabledOU)" })"),
            (& $mk $doStamp   '4. Stamp Description with date + admin'),
            (& $mk $doPwReset '5. Reset password to random value')
        ) -join "`r`n"

        $stepsInline = @()
        if ($doDisable) { $stepsInline += 'Disable' }
        if ($doGroups)  { $stepsInline += 'Remove groups' }
        if ($doMoveOU)  { $stepsInline += 'Move OU' }
        if ($doStamp)   { $stepsInline += 'Stamp' }
        if ($doPwReset) { $stepsInline += 'Reset password' }

        $details = [ordered]@{
            'Note'      = if ($note) { $note } else { '-' }
            'Admin'     = if ($ctx -and $ctx.AdminAccount) { $ctx.AdminAccount } else { "$env:USERDOMAIN\$env:USERNAME" }
            'Domain'    = if ($ctx -and $ctx.Domain)       { $ctx.Domain }       else { $env:USERDNSDOMAIN }
            'Timestamp' = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        }

        $bodyText = "Steps performed (checklist):" + "`r`n" +
                    $checklist + "`r`n`r`n" +
                    "Accounts offboarded ($($rows.Count)):" + "`r`n" +
                    ($resultLines -join "`r`n") + "`r`n`r`n" +
                    "Batch result: $okCount OK, $failCount with errors."

        # Recovery block: OU + prior group memberships per account, as of
        # immediately before this run - appended after the standard summary
        # above so the existing report format is unchanged for anyone
        # scanning past it.
        if ($recoveryItems.Count -gt 0 -and (Get-Command ConvertTo-MailRecoveryBlock -ErrorAction SilentlyContinue)) {
            $recoveryBlock = ConvertTo-MailRecoveryBlock -Items $recoveryItems `
                -Heading 'Recovery details (state immediately before this run):'
            if ($recoveryBlock) {
                $bodyText += "`r`n`r`n" + $recoveryBlock
            }
        }

        Show-NotificationMailDialog `
            -Context     $ctx `
            -Sam         '' `
            -ActionTitle 'Offboarding' `
            -Subject     "AD Offboarding: $($rows.Count) account(s), $okCount OK / $failCount errors" `
            -Details     $details `
            -BodyText    $bodyText `
            -AdminOnly
    }

    # Refresh the target list so processed accounts drop out of the current view.
    if (Get-Command Read-OffboardTargetUsers -ErrorAction SilentlyContinue) {
        Read-OffboardTargetUsers -Force
    }
}
#endregion

Export-ModuleMember -Function `
    Invoke-OffboardStamp, `
    Invoke-OffboardPwReset, `
    Invoke-Offboard
