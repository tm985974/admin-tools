#region -- ADBulkOps.AddUsersToGroups.Tab.psm1 --------------------------------
# Concern : Build-AddUsersToGroupsPage - builds the "Add Users to Groups"
#           page of the Bulk Operations tab: paste a list of usernames and a
#           list of group names, add every listed user to every listed group
#           (a full cross-join - N users x M groups membership adds), with a
#           per-pair OK/FAIL result.
# Load order: depends on Services.AD.Reporting (Confirm-Action, New-StdButton,
#                        Write-OperationLog),
#                        Services.Mail.Dialog (Show-NotificationMailDialog) [4c],
#                        Services.Mail.Batch (New-MailModeSelector,
#                          Get-MailModeSelection, Send-ADBatchNotificationMail) [4e]
# Split from: (new module)
# Notes     : Unlike the three Batch Delete pages on this tab, there is no
#             pre-existing shared "add a user to N groups" action to
#             delegate to - Add-ADPrincipalGroupMembership is called
#             directly here, one call per (user, group) pair. Not
#             destructive in the same sense as a delete (group membership is
#             trivially reversible), but still confirmed once for the whole
#             batch.
#             A user already in a listed group is reported as a FAIL with
#             AD's own error message (e.g. "already a member") rather than
#             silently skipped or treated as a separate case - keeps the
#             per-pair result honest about what AD actually did, and keeps
#             this page's logic simple (one uniform try/catch, no
#             pre-check-then-act race).
# Changes   : Notification mail is now mode-selectable (Services.Mail.Batch)
#             instead of always being a single admin-only summary. A
#             "Notification:" radio row (Admin Only / Individual / Both /
#             None) sits above the Results box, defaulting to Admin Only -
#             identical behavior to before unless the admin actively picks
#             something else. Admin Only sends the same whole-batch summary
#             as always (every user, every group, unchanged). Individual
#             sends ONE popup per user who had at least one successful add,
#             listing ONLY that user's own successfully-added groups - never
#             another user's. This requires tracking successes per-user
#             (not just per-pair) during the add loop, via $successByUser.
#             Tab-leave reset: registers a reset scriptblock on this page's
#             TabPage Tag['Resets'] that clears the Usernames and Group
#             names boxes, the Results log and the status label. The
#             Notification mode selection is kept. Run by
#             ADBulkOps.Register-BulkOpsTab whenever this page is left
#             (sub-tab switch or leaving the Bulk Operations tab).
# v1.6.0    : Notification email trimmed to basic information: Action / DC /
#             rows repeated in the message text and the "administrative tracking
#             only" line removed.
#endregion

#region -- Build-AddUsersToGroupsPage --------------------------------------------
function Build-AddUsersToGroupsPage {
    <#
    .SYNOPSIS
        Builds the Add Users to Groups page: paste usernames and group names
        into two separate lists, add every user to every group (cross-join),
        and show a per-pair OK/FAIL results log.
    .PARAMETER Tab
        The TabPage to build into (a page of the Bulk Operations sub-tab).
    .PARAMETER Context
        Shared context object (TargetDC, AdminAccount, Domain, mail config).
    #>
    param(
        [System.Windows.Forms.TabPage]$Tab,
        [PSCustomObject]$Context
    )

    $F_UI   = New-Object System.Drawing.Font('Segoe UI', 9)
    $F_UI_B = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $F_MONO = New-Object System.Drawing.Font('Consolas', 9)
    $PAD    = 8
    $GAP    = 16
    $TW     = $script:_TW
    $TH     = $script:_TH
    $CW     = $TW - ($PAD * 2)
    $HALF_W = [int](($CW - $GAP) / 2)

    # Cross-module function calls from inside a .GetNewClosure() block are
    # unreliable by bare name in this codebase (see
    # ADDirectory.Register-DirectoryTab) - captured here, invoked via &.
    $capturedContext  = $Context
    $confirmActionFn  = ${function:Confirm-Action}
    $writeOpLogFn     = ${function:Write-OperationLog}
    $getMailModeFn    = ${function:Get-MailModeSelection}
    $sendBatchMailFn  = ${function:Send-ADBatchNotificationMail}

    $lInfo            = New-Object System.Windows.Forms.Label
    $lInfo.Text       = 'Adds every listed user to every listed group (all combinations). Not destructive, but still confirmed as one batch.'
    $lInfo.Location   = New-Object System.Drawing.Point($PAD, $PAD)
    $lInfo.Size       = New-Object System.Drawing.Size($CW, 18)
    $lInfo.Font       = New-Object System.Drawing.Font('Segoe UI', 8)
    $lInfo.ForeColor  = [System.Drawing.Color]::DimGray
    $Tab.Controls.Add($lInfo)

    $LIST_Y = $PAD + 22

    # -- Left: Usernames --------------------------------------------------
    $lUsers           = New-Object System.Windows.Forms.Label
    $lUsers.Text      = 'Usernames (SamAccountName, one per line):'
    $lUsers.Location  = New-Object System.Drawing.Point($PAD, $LIST_Y)
    $lUsers.Size      = New-Object System.Drawing.Size($HALF_W, 20)
    $lUsers.Font      = $F_UI
    $Tab.Controls.Add($lUsers)

    $tbUsers               = New-Object System.Windows.Forms.TextBox
    $tbUsers.Location      = New-Object System.Drawing.Point($PAD, ($LIST_Y + 22))
    $tbUsers.Size          = New-Object System.Drawing.Size($HALF_W, 170)
    $tbUsers.Font          = $F_MONO
    $tbUsers.Multiline     = $true
    $tbUsers.ScrollBars    = 'Vertical'
    $tbUsers.AcceptsReturn = $true
    $Tab.Controls.Add($tbUsers)

    # -- Right: Group names -------------------------------------------------
    $GROUPS_X = $PAD + $HALF_W + $GAP

    $lGroups           = New-Object System.Windows.Forms.Label
    $lGroups.Text      = 'Group names (one per line):'
    $lGroups.Location  = New-Object System.Drawing.Point($GROUPS_X, $LIST_Y)
    $lGroups.Size      = New-Object System.Drawing.Size($HALF_W, 20)
    $lGroups.Font      = $F_UI
    $Tab.Controls.Add($lGroups)

    $tbGroups               = New-Object System.Windows.Forms.TextBox
    $tbGroups.Location      = New-Object System.Drawing.Point($GROUPS_X, ($LIST_Y + 22))
    $tbGroups.Size          = New-Object System.Drawing.Size($HALF_W, 170)
    $tbGroups.Font          = $F_MONO
    $tbGroups.Multiline     = $true
    $tbGroups.ScrollBars    = 'Vertical'
    $tbGroups.AcceptsReturn = $true
    $Tab.Controls.Add($tbGroups)

    $RESULTS_LBL_Y = $LIST_Y + 22 + 170 + 12

    # -- Notification mode - defaults to Admin Only, identical to the prior
    #    hardcoded behavior unless the admin picks something else.
    #    GUARDED: see ADTools.BulkOnboard.Tab's identical fix - an earlier
    #    unguarded call here would throw and abort the rest of this
    #    function (including the Add/results wiring below) if Services.
    #    Mail.Batch ever failed to load. Guarding it means a missing module
    #    just omits the notification row instead of breaking the page.
    if (Get-Command New-MailModeSelector -ErrorAction SilentlyContinue) {
        $modeSelector = New-MailModeSelector -Parent $Tab -X $PAD -Y $RESULTS_LBL_Y -DefaultMode 'AdminOnly'
        $RESULTS_LBL_Y += 30
    } else {
        $modeSelector    = $null
        $lNoMailMode           = New-Object System.Windows.Forms.Label
        $lNoMailMode.Text      = 'Notification mode unavailable - Services_Mail_Batch module not loaded.'
        $lNoMailMode.Location  = New-Object System.Drawing.Point($PAD, $RESULTS_LBL_Y)
        $lNoMailMode.Size      = New-Object System.Drawing.Size(500, 18)
        $lNoMailMode.Font      = $F_UI
        $lNoMailMode.ForeColor = [System.Drawing.Color]::FromArgb(156,0,6)
        $Tab.Controls.Add($lNoMailMode)
        $RESULTS_LBL_Y += 22
    }

    $lResults           = New-Object System.Windows.Forms.Label
    $lResults.Text      = 'Results:'
    $lResults.Location  = New-Object System.Drawing.Point($PAD, $RESULTS_LBL_Y)
    $lResults.Size      = New-Object System.Drawing.Size(300, 18)
    $lResults.Font      = $F_UI_B
    $Tab.Controls.Add($lResults)

    $RESULTS_Y = $RESULTS_LBL_Y + 20
    $RESULTS_H = $TH - $RESULTS_Y - $PAD - 44

    $tbResults              = New-Object System.Windows.Forms.RichTextBox
    $tbResults.Location     = New-Object System.Drawing.Point($PAD, $RESULTS_Y)
    $tbResults.Size         = New-Object System.Drawing.Size($CW, $RESULTS_H)
    $tbResults.Font         = $F_MONO
    $tbResults.ReadOnly     = $true
    $tbResults.BackColor    = [System.Drawing.Color]::White
    $tbResults.BorderStyle  = 'FixedSingle'
    $Tab.Controls.Add($tbResults)

    $BTN_Y = $RESULTS_Y + $RESULTS_H + 8

    $lStatus            = New-Object System.Windows.Forms.Label
    $lStatus.Location   = New-Object System.Drawing.Point($PAD, ($BTN_Y + 6))
    $lStatus.Size       = New-Object System.Drawing.Size(($CW - 160), 24)
    $lStatus.Font       = $F_UI
    $lStatus.ForeColor  = [System.Drawing.Color]::DimGray
    $Tab.Controls.Add($lStatus)

    # Wider right-edge margin than the usual $PAD (8px) - a button flush
    # against $CW's assumed right edge left no tolerance for the actual
    # available width being even slightly less than estimated (confirmed:
    # this exact button was visibly clipped at the tab's right edge in
    # testing). $script:_TW is a computed estimate (ultimately derived from
    # $Context.TabW), not a Form's own exact ClientSize, so edge-hugging
    # controls need real buffer, not just the standard content padding.
    $btnAdd           = New-StdButton -Text 'Add to Groups' -X ($CW - 150 - 32) -Y $BTN_Y -W 150 -H 30 -Parent $Tab
    $btnAdd.Font      = $F_UI_B

    $btnAdd.Add_Click({
        $users = @(
            $tbUsers.Text -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique
        )
        $groups = @(
            $tbGroups.Text -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique
        )
        if ($users.Count -eq 0) {
            $lStatus.ForeColor = [System.Drawing.Color]::FromArgb(156,0,6)
            $lStatus.Text      = 'Paste at least one username.'
            return
        }
        if ($groups.Count -eq 0) {
            $lStatus.ForeColor = [System.Drawing.Color]::FromArgb(156,0,6)
            $lStatus.Text      = 'Paste at least one group name.'
            return
        }

        $totalPairs = $users.Count * $groups.Count
        $msg = "Add $($users.Count) user(s) to $($groups.Count) group(s)?`n`n" +
               "That's $totalPairs membership add(s) total. This is reversible (Directory tab > Edit Groups) but not undone automatically."
        # The command window shows the exact code (template rule).
        $q = { param($v) "'" + ([string]$v).Replace("'", "''") + "'" }   # PowerShell literal, local so the closure needs no lookup
        $srvText = if ($capturedContext -and $capturedContext.TargetDC) { ' -Server ' + (& $q $capturedContext.TargetDC) } else { '' }
        $code = 'foreach ($user in @(' + ((@($users) | ForEach-Object { & $q $_ }) -join ', ') + ")) {`r`n" +
                '    foreach ($group in @(' + ((@($groups) | ForEach-Object { & $q $_ }) -join ', ') + ")) {`r`n" +
                "        Add-ADPrincipalGroupMembership -Identity `$user -MemberOf `$group$srvText`r`n    }`r`n}"
        $confirmed = if ($confirmActionFn) { & $confirmActionFn -Title 'Add Users to Groups' -Message $msg -ActionLabel 'Add' -Code $code } else { $true }
        if (-not $confirmed) { return }

        $srvParam = if ($capturedContext -and $capturedContext.TargetDC) { @{ Server = $capturedContext.TargetDC } } else { @{} }
        $ok = 0; $fail = 0
        $tbResults.Clear()
        $successPairs  = [System.Collections.Generic.List[string]]::new()

        # Tracks successes PER USER (not just per pair) - the group(s) each
        # individual user was actually, successfully added to. This is what
        # an Individual-mode send reads from, so one user's popup only ever
        # lists their OWN groups, never another user's.
        $successByUser = [ordered]@{}

        foreach ($user in $users) {
            foreach ($group in $groups) {
                try {
                    Add-ADPrincipalGroupMembership -Identity $user -MemberOf $group @srvParam -ErrorAction Stop
                    if ($writeOpLogFn) { & $writeOpLogFn -Context $capturedContext -Action 'ADD-USER-TO-GROUP' -Target "$user -> $group" -Result 'OK' }
                    $tbResults.SelectionColor = [System.Drawing.Color]::FromArgb(0,97,0)
                    $tbResults.AppendText("OK    $user  ->  $group`r`n")
                    [void]$successPairs.Add("$user -> $group")
                    if (-not $successByUser.Contains($user)) { $successByUser[$user] = [System.Collections.Generic.List[string]]::new() }
                    [void]$successByUser[$user].Add($group)
                    $ok++
                } catch {
                    if ($writeOpLogFn) { & $writeOpLogFn -Context $capturedContext -Action 'ADD-USER-TO-GROUP' -Target "$user -> $group" -Result 'FAIL' -Detail $_.Exception.Message }
                    $tbResults.SelectionColor = [System.Drawing.Color]::FromArgb(156,0,6)
                    $tbResults.AppendText("FAIL  $user  ->  $group : $($_.Exception.Message)`r`n")
                    $fail++
                }
            }
        }
        $lStatus.ForeColor = if ($fail -gt 0) { [System.Drawing.Color]::FromArgb(156,0,6) } else { [System.Drawing.Color]::FromArgb(0,97,0) }
        $lStatus.Text      = "Done. Added: $ok  Failed: $fail  (of $totalPairs total)"

        # -- Notification mail - Admin Only / Individual / Both / None, per
        #    the radio row above. Admin summary (whole batch) is unchanged
        #    from before; Individual sends are built fresh per user below,
        #    from that user's OWN successByUser entry only.
        $mailMode = if ($getMailModeFn) { & $getMailModeFn $modeSelector } else { 'AdminOnly' }
        if ($ok -gt 0 -and $sendBatchMailFn -and $mailMode -ne 'None') {
            $details = [ordered]@{
                'Admin'     = if ($capturedContext -and $capturedContext.AdminAccount) { $capturedContext.AdminAccount } else { "$env:USERDOMAIN\$env:USERNAME" }
                'Domain'    = if ($capturedContext -and $capturedContext.Domain)       { $capturedContext.Domain }       else { $env:USERDNSDOMAIN }
                'Timestamp' = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
            }
            $bodyText = "The following user(s) were added to the following group(s):" + "`r`n`r`n" +
                        "Users (" + $users.Count + "):" + "`r`n" + (($users | ForEach-Object { "- $_" }) -join "`r`n") + "`r`n`r`n" +
                        "Groups (" + $groups.Count + "):" + "`r`n" + (($groups | ForEach-Object { "- $_" }) -join "`r`n") + "`r`n`r`n" +
                        "Batch result: $ok added, $fail failed (of $totalPairs total)."

            # One recipient entry per user with at least one successful add,
            # each scoped to ONLY that user's own successfully-added groups.
            $recipients = [System.Collections.Generic.List[PSCustomObject]]::new()
            foreach ($u in $successByUser.Keys) {
                $uGroups = @($successByUser[$u])
                if ($uGroups.Count -eq 0) { continue }
                $recipDetails = [ordered]@{
                }
                $recipBody = "Your Active Directory account was added to the following group(s):" + "`r`n`r`n" +
                             (($uGroups | ForEach-Object { "- $_" }) -join "`r`n")
                [void]$recipients.Add([PSCustomObject]@{
                    Sam      = $u
                    Subject  = "Your AD account: added to $($uGroups.Count) group(s)"
                    Details  = $recipDetails
                    BodyText = $recipBody
                })
            }

            & $sendBatchMailFn `
                -Mode          $mailMode `
                -Context       $capturedContext `
                -ActionTitle   'Users Added to Groups' `
                -AdminSubject  "AD Add Users to Groups: $ok added, $fail failed" `
                -AdminDetails  $details `
                -AdminBodyText $bodyText `
                -Recipients    $recipients
        }
    }.GetNewClosure())

    # Tab-leave reset (see module header) - captured control locals only.
    if (-not ($Tab.Tag -is [hashtable])) { $Tab.Tag = @{} }
    if (-not $Tab.Tag.ContainsKey('Resets')) {
        $Tab.Tag['Resets'] = New-Object System.Collections.Generic.List[scriptblock]
    }
    $Tab.Tag['Resets'].Add({
        $tbUsers.Text      = ''
        $tbGroups.Text     = ''
        $tbResults.Clear()
        $lStatus.Text      = ''
        $lStatus.ForeColor = [System.Drawing.Color]::DimGray
    }.GetNewClosure())
}
#endregion

Export-ModuleMember -Function Build-AddUsersToGroupsPage
