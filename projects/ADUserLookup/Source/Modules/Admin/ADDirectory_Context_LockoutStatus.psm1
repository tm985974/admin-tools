#region -- ADDirectory.Context.LockoutStatus.psm1 ------------------------------
# Concern : Show-LockoutStatusDialog - fixed-size popup launched from the
#           Directory tab Users grid right-click menu ("Check Lockout
#           Status..."). Shows live account status (Enabled / LockedOut /
#           BadLogonCount / Threshold / Remaining attempts) queried directly
#           against the PDC Emulator (NOT $Context.TargetDC - that may be a
#           non-PDC DC if the operator picked one manually via
#           Show-DomainPicker, and BadLogonCount/LockedOut are only reliably
#           current on the PDC). Below that, a checklist of every domain
#           controller lets the operator pick which DC(s) to scan for the
#           actual lockout source.
#
#           Two-stage correlation (NOT a per-DC independent 4740+4771/4625
#           lookup - that design was tried and does not work, see below):
#             Stage 1 - Get-LockoutEvent queries ONLY the PDC Emulator for
#                       the most recent 4740 (lockout notice) for the
#                       account. 4740 is logged almost exclusively on the
#                       PDC, because that is the DC that owns the
#                       authoritative bad-password counter and applies the
#                       lockout - a non-PDC DC will essentially never have
#                       one, so it is pointless to search for 4740 anywhere
#                       else.
#             Stage 2 - the 10-minute-before/5-second-after window around
#                       that single confirmed 4740 timestamp is then fanned
#                       out, via the runspace pool, to EVERY selected DC
#                       (PDC included) to search for 4771 (Kerberos
#                       pre-auth failure, gives source IP) or, failing
#                       that, 4625 (NTLM failed logon, gives source
#                       workstation + IP). This matters because the actual
#                       failed authentication is normally logged on the
#                       client's site-local DC, not the PDC, so searching
#                       only the DC that logged the 4740 (the earlier,
#                       broken design) almost never finds a match.
#             Diagnostic mode - if Stage 1 finds no 4740 for the account
#                       within the search window (log rollover, PDC role
#                       recently moved, audit gap, etc.), Stage 2 still
#                       runs, widened to the full $DAYS_BACK window instead
#                       of the tight post-lockout window, and every result
#                       row is tagged so the operator knows it is NOT
#                       confirmed to be the actual lockout cause, just the
#                       most recent failed-logon evidence available.
#             Resolved Host column - 4625's WorkstationName field is
#                       unreliable under NTLM pass-through authentication
#                       (a member server/RDS host/appliance forwards the
#                       credential to the DC for validation, and the DC
#                       often ends up logging itself as the workstation,
#                       not the true origin), and 4771 (Kerberos) never has
#                       a workstation field at all. IpAddress does not have
#                       that blind spot - it is captured at the network
#                       layer - so Stage 2 reverse-DNS-resolves it (inside
#                       the same per-DC runspace, so it stays parallelized)
#                       and shows the result alongside the raw claimed
#                       Source Computer rather than replacing it, since
#                       "it claimed to be the DC" is itself a useful signal
#                       that pass-through auth occurred.
# Load order: 24 - depends on ADDirectory.Context.Common (script scope only;
#                            -Context is also passed explicitly, same as
#                            ADDirectory.UserSessions.Dialog)
#             No other ADDirectory module dependencies; self-contained
#             dialog, same shape as ADDirectory.UserSessions.Dialog.
# Notes     : Event data is read by XML Data/@Name lookup, not positional
#             Properties[n] indexing (except where positional indexing is
#             well-documented and stable, namely Properties[0]=TargetUserName
#             for 4740/4771, and Properties[5]=TargetUserName for 4625 -
#             used only for the initial Where-Object match).
#             Name-based lookup avoids index-drift risk across Windows
#             versions/event schema revisions for 4771/4625, which carry
#             far more fields than 4740.
#             Runspace pool capped at 15 threads per RDS dual-role
#             constraint (NetworkEnvironment.txt [RDS_Constraint] Tier =
#             LIMITED), same cap as ADDirectory.UserSessions.Dialog. Stage 1
#             (PDC 4740 lookup) is a single synchronous call, not part of
#             the pool - one target, no benefit to threading it, and it
#             must complete before Stage 2's window can be computed anyway.
#             Stage 2's 4771/4625 queries use -FilterXPath, NOT
#             -FilterHashtable, to bound the time window. FilterHashtable
#             with BOTH StartTime and EndTime present is a documented
#             Get-WinEvent bug against remote computers - it throws "The
#             parameter is incorrect" instead of querying. Stage 1's 4740
#             lookup only needs a StartTime lower bound, so it is
#             unaffected and stays on FilterHashtable.
#             No ternary operators, no ??= operator, no -Parallel foreach.
#             PS 5.1 compatible throughout.
#             Get-EvtData (XML Data/@Name lookup helper) is defined ONLY
#             inline inside $script:LockEventBlock below, not at module
#             scope - a module-scope copy would be unreachable from inside
#             the runspace anyway (runspaces don't inherit the caller's
#             function table) and would also be dead code at this scope, so
#             it isn't duplicated here.
#endregion

#region -- Get-LockoutSummary (private) -----------------------------------------
function Get-LockoutSummary {
    <#
    .SYNOPSIS
        Queries Enabled / LockedOut / BadLogonCount / LockoutThreshold for one
        user directly against the PDC Emulator (resolved fresh, independent
        of whatever DC $Context happens to be pointed at).
    #>
    param([string]$Sam, [PSCustomObject]$Context)

    $summary = [PSCustomObject]@{
        Success       = $false
        DisplayName   = ''
        Enabled       = $false
        LockedOut     = $false
        BadLogonCount = 0
        Threshold     = 0
        Remaining     = 0
        PDC           = ''
        ErrorMsg      = ''
    }

    try {
        $baseSrv = ''
        if ($Context -and $Context.TargetDC) { $baseSrv = $Context.TargetDC }

        $domP = @{ ErrorAction = 'Stop' }
        if ($baseSrv) { $domP.Server = $baseSrv }
        $domain = Get-ADDomain @domP
        $pdc    = $domain.PDCEmulator
        $summary.PDC = $pdc

        $user = Get-ADUser -Identity $Sam -Server $pdc `
                -Properties BadLogonCount, LockedOut, DisplayName, Enabled -ErrorAction Stop
        $pol  = Get-ADDefaultDomainPasswordPolicy -Server $pdc -ErrorAction Stop

        if ($user.DisplayName) { $summary.DisplayName = $user.DisplayName } else { $summary.DisplayName = $user.SamAccountName }
        $summary.Enabled       = [bool]$user.Enabled
        $summary.LockedOut     = [bool]$user.LockedOut
        $summary.BadLogonCount = [int]$user.BadLogonCount
        $summary.Threshold     = [int]$pol.LockoutThreshold
        $summary.Remaining     = $summary.Threshold - $summary.BadLogonCount
        $summary.Success       = $true
    } catch {
        $summary.ErrorMsg = $_.Exception.Message
    }

    return $summary
}
#endregion

#region -- Get-LockoutEvent (private) --------------------------------------------
function Get-LockoutEvent {
    <#
    .SYNOPSIS
        Stage 1 of the lockout-source scan. Queries ONLY the PDC Emulator
        for the most recent 4740 (account lockout) matching $Sam within
        $DaysBack. 4740 is logged almost exclusively on the PDC (it owns
        the authoritative bad-password counter and applies the lockout),
        so this is intentionally a single synchronous call against one
        server, not a per-DC search.
    .PARAMETER Sam
        SamAccountName of the locked-out user.
    .PARAMETER PDCServer
        Hostname of the PDC Emulator (already resolved by
        Get-LockoutSummary earlier in the dialog's Shown handler).
    .PARAMETER DaysBack
        Search window in days.
    #>
    param([string]$Sam, [string]$PDCServer, [int]$DaysBack)

    $result = [PSCustomObject]@{
        Found          = $false
        LockoutTime    = $null
        CallerComputer = ''
        ErrorMsg       = ''
    }

    if (-not $PDCServer) {
        $result.ErrorMsg = 'PDC Emulator was not resolved - cannot locate the 4740 event.'
        return $result
    }

    try {
        $start = (Get-Date).AddDays(0 - $DaysBack)
        $f4740 = @{ LogName = 'Security'; Id = 4740; StartTime = $start }
        $lockEvt = Get-WinEvent -ComputerName $PDCServer -FilterHashtable $f4740 -ErrorAction Stop |
                   Where-Object { $_.Properties[0].Value -eq $Sam } |
                   Sort-Object TimeCreated -Descending |
                   Select-Object -First 1

        if ($lockEvt) {
            $result.Found       = $true
            $result.LockoutTime = $lockEvt.TimeCreated

            try {
                $xml  = [xml]$lockEvt.ToXml()
                $node = $xml.Event.EventData.Data | Where-Object { $_.Name -eq 'CallerComputerName' }
                if ($node -and $node.'#text' -and $node.'#text' -ne '-') {
                    $result.CallerComputer = [string]$node.'#text'
                }
            } catch { }
        }
    } catch {
        # Covers both real connectivity/permission failures AND
        # Get-WinEvent's own terminating "no events found" case - either
        # way, Found stays false and the caller falls back to diagnostic
        # mode. ErrorMsg is still captured so a genuine connectivity
        # problem to the PDC is visible rather than silently treated the
        # same as "no lockout occurred".
        $result.ErrorMsg = $_.Exception.Message
    }

    return $result
}
#endregion

#region -- LockEventBlock (runs inside each runspace) ---------------------------
# Stage 2 - runs once per selected DC. Searches ONLY for 4771 (Kerberos
# pre-auth failure - source IP) or, failing that, 4625 (NTLM failed logon -
# source workstation + IP) within the window handed to it by the caller.
# Does NOT look for 4740 itself - that is Stage 1 (Get-LockoutEvent),
# resolved once against the PDC before this block is ever dispatched, so
# every selected DC is searched with the same confirmed window instead of
# each DC only being checked against its own (usually nonexistent) 4740.
$script:LockEventBlock = {
    param([string]$DCName, [string]$SamAccount, [datetime]$CorrStart, [datetime]$CorrEnd, [bool]$Diagnostic)

    function Get-EvtData {
        param($Event, [string]$Name)
        try {
            $xml  = [xml]$Event.ToXml()
            $node = $xml.Event.EventData.Data | Where-Object { $_.Name -eq $Name }
            if ($node) { return [string]$node.'#text' }
        } catch { }
        return ''
    }

    $result = [PSCustomObject]@{
        DCName         = $DCName
        EventFound     = $false
        EventTime      = $null
        CorrelatedType = ''
        SourceComputer = ''
        SourceIP       = ''
        SourceHostName = ''
        FailureCode    = ''
        Detail         = ''
        ErrorMsg       = ''
    }

    # FilterHashtable with BOTH StartTime and EndTime present is a known
    # Get-WinEvent bug against remote computers - it throws "The parameter
    # is incorrect" instead of querying. FilterXPath bounds the same time
    # range without hitting that translation path, so it is used here
    # instead. (Stage 1's 4740 lookup only supplies StartTime, so it is not
    # affected and is left on FilterHashtable.)
    #
    # Get-WinEvent throws a terminating error BOTH when a query is
    # malformed/unreachable AND when it is perfectly valid but zero events
    # match - the exact same "No events were found that match the
    # specified selection criteria." message in the second case. Get-
    # CorrelationEvents below distinguishes the two by matching on that
    # message text, so a real query/connectivity problem on a given DC
    # surfaces as an error row instead of being silently reported as "no
    # source event found" - those are not the same thing to an operator
    # deciding whether the DC's audit policy is the gap or the query is.
    function Get-CorrelationEvents {
        param([string]$DCName, [int]$EventId, [string]$StartUtc, [string]$EndUtc)
        $out = [PSCustomObject]@{ Events = @(); ErrorMsg = '' }
        $xpath = "*[System[(EventID=$EventId) and TimeCreated[@SystemTime>='$StartUtc' and @SystemTime<='$EndUtc']]]"
        try {
            $out.Events = @(Get-WinEvent -ComputerName $DCName -LogName 'Security' -FilterXPath $xpath -ErrorAction Stop)
        } catch {
            if ($_.Exception.Message -notmatch 'No events were found') {
                $out.ErrorMsg = $_.Exception.Message
            }
        }
        return $out
    }

    $startUtc = $CorrStart.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    $endUtc   = $CorrEnd.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')

    try {
        # 4771 - Kerberos pre-auth failure (most common real cause; gives source IP)
        $kerbQuery = Get-CorrelationEvents -DCName $DCName -EventId 4771 -StartUtc $startUtc -EndUtc $endUtc
        $kerb      = $null
        if ($kerbQuery.ErrorMsg) {
            $result.ErrorMsg = "4771 query failed: $($kerbQuery.ErrorMsg)"
        } else {
            $kerb = $kerbQuery.Events |
                    Where-Object { $_.Properties[0].Value -eq $SamAccount } |
                    Sort-Object TimeCreated -Descending |
                    Select-Object -First 1
        }

        if ($kerb) {
            $result.EventFound     = $true
            $result.EventTime      = $kerb.TimeCreated
            $result.CorrelatedType = '4771 Kerberos Pre-Auth Failure'
            $result.SourceIP       = Get-EvtData -Event $kerb -Name 'IpAddress'
            $result.FailureCode    = Get-EvtData -Event $kerb -Name 'Status'
        } elseif (-not $result.ErrorMsg) {
            # 4625 - NTLM / other failed logon (gives source workstation name + IP)
            $ntlmQuery = Get-CorrelationEvents -DCName $DCName -EventId 4625 -StartUtc $startUtc -EndUtc $endUtc
            $ntlm      = $null
            if ($ntlmQuery.ErrorMsg) {
                $result.ErrorMsg = "4625 query failed: $($ntlmQuery.ErrorMsg)"
            } else {
                $ntlm = $ntlmQuery.Events |
                        Where-Object { $_.Properties[5].Value -eq $SamAccount } |
                        Sort-Object TimeCreated -Descending |
                        Select-Object -First 1
            }

            if ($ntlm) {
                $result.EventFound     = $true
                $result.EventTime      = $ntlm.TimeCreated
                $result.CorrelatedType = '4625 Failed Logon (NTLM)'
                $result.SourceComputer = Get-EvtData -Event $ntlm -Name 'WorkstationName'
                $result.SourceIP       = Get-EvtData -Event $ntlm -Name 'IpAddress'
                $result.FailureCode    = Get-EvtData -Event $ntlm -Name 'SubStatus'
            }
        }

        # Reverse-DNS the source IP once a correlation event is found. This
        # matters even when SourceComputer looks populated: 4625's
        # WorkstationName is unreliable under NTLM pass-through
        # authentication (a member server/RDS host/appliance forwards the
        # credential to the DC for validation, and the DC ends up logging
        # itself, not the true origin) - IpAddress is captured at the
        # network layer instead and does not have that blind spot. 4771
        # (Kerberos) never has a WorkstationName field at all, so this is
        # also the only way those rows get a device name.
        if ($result.SourceIP -and $result.SourceIP -ne '-') {
            try {
                $hostEntry = [System.Net.Dns]::GetHostEntry($result.SourceIP)
                if ($hostEntry.HostName) {
                    $result.SourceHostName = ($hostEntry.HostName -split '\.')[0]
                }
            } catch {
                # No PTR record, timeout, or unreachable DNS - leave blank,
                # this is expected for many devices and not a query failure.
            }
        }

        if (-not $result.EventFound -and -not $result.ErrorMsg) {
            if ($Diagnostic) {
                $result.Detail = 'No 4771/4625 event for this account on this DC in the diagnostic window.'
            } else {
                $result.Detail = 'No 4771/4625 event for this account on this DC in the correlation window.'
            }
        } elseif ($result.EventFound -and $Diagnostic) {
            $result.Detail = 'Diagnostic mode - no confirmed 4740; not necessarily the lockout cause.'
        }

    } catch {
        $result.ErrorMsg = $_.Exception.Message
    }

    return $result
}
#endregion

#region -- Show-LockoutRowDetail (private) --------------------------------------
function Show-LockoutRowDetail {
    <#
    .SYNOPSIS
        Small fixed-size popup showing one results-grid row's full detail
        cleanly - the grid truncates long computer/IP/notes text at column
        width, this does not. Opened via double-click or right-click ->
        View Details on a row in the Lockout Source Results grid.
    .PARAMETER DCName
        DC the row is for (from the ListViewItem's stashed Tag, not
        re-parsed from grid text).
    .PARAMETER Diagnostic
        Whether this row came from a diagnostic-mode scan (no confirmed
        4740) - drives the amber "not necessarily the lockout cause" banner.
    .PARAMETER Result
        The raw per-DC result object produced by $script:LockEventBlock,
        stashed on the ListViewItem.Tag when the row was created. May be
        $null (the "scan failed, no result returned" case).
    .NOTES
        Fully self-contained (own fonts/colors) rather than relying on the
        parent dialog's - it is invoked via a captured function reference
        from inside .GetNewClosure() event handlers (same pattern as
        Get-LockoutSummary/Get-LockoutEvent), and defining its own locals
        avoids any dependency on that closure's variable-capture timing.
    #>
    param([string]$DCName, [bool]$Diagnostic, [PSCustomObject]$Result)

    $fD  = New-Object System.Drawing.Font('Segoe UI', 9)
    $fDB = New-Object System.Drawing.Font('Segoe UI', 9,  [System.Drawing.FontStyle]::Bold)
    $fDT = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
    $cTitle = [System.Drawing.Color]::FromArgb(0, 99, 177)
    $cBg    = [System.Drawing.Color]::FromArgb(235, 238, 242)
    $cRed   = [System.Drawing.Color]::FromArgb(200, 40, 40)
    $cAmber = [System.Drawing.Color]::FromArgb(190, 120, 0)
    $cDim   = [System.Drawing.Color]::DimGray

    # ---- Resolve display values up front (Result may be $null) ------------
    $evtTimeText = '-'
    $corrText    = '-'
    $srcCompText = '-'
    $srcIPText   = '-'
    $srcHostText = '-'
    $failText    = '-'
    $notesText   = '(none)'
    $bannerText  = ''
    $bannerColor = $cDim

    if (-not $Result) {
        $notesText  = 'Scan failed (no result returned).'
        $bannerText = 'SCAN FAILED on this DC'
        $bannerColor = $cRed
    } elseif ($Result.ErrorMsg) {
        $notesText   = $Result.ErrorMsg
        $bannerText  = 'QUERY ERROR on this DC'
        $bannerColor = $cRed
    } else {
        if ($Result.EventTime)      { $evtTimeText = $Result.EventTime.ToString('MM/dd/yyyy hh:mm:ss tt') }
        if ($Result.CorrelatedType) { $corrText    = $Result.CorrelatedType }
        if ($Result.SourceComputer) { $srcCompText = $Result.SourceComputer }
        if ($Result.SourceIP)       { $srcIPText   = $Result.SourceIP }
        if ($Result.SourceHostName) { $srcHostText = $Result.SourceHostName }
        if ($Result.FailureCode)    { $failText    = $Result.FailureCode }
        if ($Result.Detail)         { $notesText   = $Result.Detail }

        if (-not $Result.EventFound) {
            $bannerText  = 'No 4771/4625 source event found on this DC'
            $bannerColor = $cDim
        } elseif ($Diagnostic) {
            $bannerText  = 'DIAGNOSTIC MODE - no confirmed 4740; not necessarily the lockout cause'
            $bannerColor = $cAmber
        } else {
            $bannerText  = 'Correlated to the confirmed 4740 lockout window'
            $bannerColor = [System.Drawing.Color]::FromArgb(0, 130, 60)
        }
    }

    # ---- Form ---------------------------------------------------------------
    $rd                 = New-Object System.Windows.Forms.Form
    $rd.Text            = "Lockout Source Detail - $DCName"
    $rd.ClientSize      = New-Object System.Drawing.Size(560, 460)
    $rd.FormBorderStyle = 'FixedDialog'
    $rd.MaximizeBox     = $false
    $rd.MinimizeBox     = $false
    $rd.StartPosition   = 'CenterParent'
    $rd.BackColor       = $cBg
    $rd.Font            = $fD

    $pTitle           = New-Object System.Windows.Forms.Panel
    $pTitle.Location  = New-Object System.Drawing.Point(0, 0)
    $pTitle.Size      = New-Object System.Drawing.Size(560, 44)
    $pTitle.BackColor = $cTitle
    $rd.Controls.Add($pTitle)

    $lTitle           = New-Object System.Windows.Forms.Label
    $lTitle.Text      = "   Lockout Source Detail  -  $DCName"
    $lTitle.Location  = New-Object System.Drawing.Point(0, 0)
    $lTitle.Size      = New-Object System.Drawing.Size(560, 44)
    $lTitle.Font      = $fDT
    $lTitle.ForeColor = [System.Drawing.Color]::White
    $lTitle.TextAlign = 'MiddleLeft'
    $pTitle.Controls.Add($lTitle)

    $pBanner           = New-Object System.Windows.Forms.Panel
    $pBanner.Location  = New-Object System.Drawing.Point(12, 52)
    $pBanner.Size      = New-Object System.Drawing.Size(536, 26)
    $pBanner.BackColor = [System.Drawing.Color]::FromArgb(245, 246, 248)
    $rd.Controls.Add($pBanner)

    $lBanner           = New-Object System.Windows.Forms.Label
    $lBanner.Text      = $bannerText
    $lBanner.Location  = New-Object System.Drawing.Point(6, 0)
    $lBanner.Size      = New-Object System.Drawing.Size(524, 26)
    $lBanner.Font      = $fDB
    $lBanner.ForeColor = $bannerColor
    $lBanner.TextAlign = 'MiddleLeft'
    $pBanner.Controls.Add($lBanner)

    $body           = New-Object System.Windows.Forms.Panel
    $body.Location  = New-Object System.Drawing.Point(12, 86)
    $body.Size      = New-Object System.Drawing.Size(536, 288)
    $body.BackColor = [System.Drawing.Color]::White
    $body.BorderStyle = 'FixedSingle'
    $rd.Controls.Add($body)

    function Add-DetailRow {
        param($Panel, [string]$Label, [string]$Value, [int]$Top)
        $l           = New-Object System.Windows.Forms.Label
        $l.Text      = $Label
        $l.ForeColor = [System.Drawing.Color]::DimGray
        $l.Location  = New-Object System.Drawing.Point(10, $Top)
        $l.Size      = New-Object System.Drawing.Size(140, 22)
        $l.Font      = $fD
        $Panel.Controls.Add($l)

        $v           = New-Object System.Windows.Forms.Label
        $v.Text      = $Value
        $v.ForeColor = [System.Drawing.Color]::Black
        $v.Location  = New-Object System.Drawing.Point(154, $Top)
        $v.Size      = New-Object System.Drawing.Size(370, 22)
        $v.Font      = $fDB
        $Panel.Controls.Add($v)
    }

    Add-DetailRow -Panel $body -Label 'Domain Controller:' -Value $DCName        -Top 10
    Add-DetailRow -Panel $body -Label 'Event Time:'        -Value $evtTimeText   -Top 36
    Add-DetailRow -Panel $body -Label 'Correlated Event:'  -Value $corrText      -Top 62
    Add-DetailRow -Panel $body -Label 'Source Computer:'   -Value $srcCompText   -Top 88
    Add-DetailRow -Panel $body -Label 'Source IP:'         -Value $srcIPText     -Top 114
    Add-DetailRow -Panel $body -Label 'Resolved Host:'     -Value $srcHostText   -Top 140
    Add-DetailRow -Panel $body -Label 'Failure Code:'      -Value $failText      -Top 166

    $lNotesHdr           = New-Object System.Windows.Forms.Label
    $lNotesHdr.Text      = 'Notes:'
    $lNotesHdr.ForeColor = [System.Drawing.Color]::DimGray
    $lNotesHdr.Location  = New-Object System.Drawing.Point(10, 198)
    $lNotesHdr.Size      = New-Object System.Drawing.Size(140, 20)
    $lNotesHdr.Font      = $fD
    $body.Controls.Add($lNotesHdr)

    $txtNotes             = New-Object System.Windows.Forms.TextBox
    $txtNotes.Text        = $notesText
    $txtNotes.Multiline   = $true
    $txtNotes.ReadOnly    = $true
    $txtNotes.ScrollBars  = 'Vertical'
    $txtNotes.BorderStyle = 'FixedSingle'
    $txtNotes.BackColor   = [System.Drawing.Color]::White
    $txtNotes.Font        = $fD
    $txtNotes.Location    = New-Object System.Drawing.Point(10, 220)
    $txtNotes.Size        = New-Object System.Drawing.Size(514, 58)
    $body.Controls.Add($txtNotes)

    $pBtn             = New-Object System.Windows.Forms.Panel
    $pBtn.Location    = New-Object System.Drawing.Point(12, 384)
    $pBtn.Size        = New-Object System.Drawing.Size(536, 34)
    $pBtn.BackColor   = $cBg
    $rd.Controls.Add($pBtn)

    $btnCopy          = New-Object System.Windows.Forms.Button
    $btnCopy.Text     = 'Copy to Clipboard'
    $btnCopy.Location = New-Object System.Drawing.Point(0, 3)
    $btnCopy.Size     = New-Object System.Drawing.Size(140, 28)
    $btnCopy.Font     = $fD
    $pBtn.Controls.Add($btnCopy)

    $btnClose          = New-Object System.Windows.Forms.Button
    $btnClose.Text     = 'Close'
    $btnClose.Location = New-Object System.Drawing.Point(436, 3)
    $btnClose.Size     = New-Object System.Drawing.Size(100, 28)
    $btnClose.Font     = $fD
    $pBtn.Controls.Add($btnClose)

    $btnClose.Add_Click({ $rd.Close() }.GetNewClosure())

    $btnCopy.Add_Click({
        $lines = @(
            "Domain Controller:  $DCName",
            "Event Time:         $evtTimeText",
            "Correlated Event:   $corrText",
            "Source Computer:    $srcCompText",
            "Source IP:          $srcIPText",
            "Resolved Host:      $srcHostText",
            "Failure Code:       $failText",
            "Notes:              $notesText"
        )
        [System.Windows.Forms.Clipboard]::SetText($lines -join "`r`n")
    }.GetNewClosure())

    [void]$rd.ShowDialog()
}
#endregion

#region -- Show-LockoutStatusDialog ---------------------------------------------
function Show-LockoutStatusDialog {
    <#
    .SYNOPSIS
        Opens a fixed-size popup showing live lockout/bad-logon status for one
        user (queried against the PDC Emulator) plus an operator-selectable
        multi-DC scan that correlates 4740/4771/4625 to find the real lockout
        source - far more reliable on a WAN/multi-DC domain than checking the
        PDC's 4740 log alone.
    .PARAMETER Sam
        SamAccountName of the user to check.
    .PARAMETER DisplayName
        Display name shown in the dialog title (optional).
    .PARAMETER Context
        Shared PSCustomObject context (TargetDC used only as a fallback
        server for DC enumeration if PDC resolution fails).
    #>
    param(
        [string]$Sam,
        [string]$DisplayName = '',
        [PSCustomObject]$Context
    )

    if (-not $Sam) { return }

    $THREAD_CAP  = 15   # RDS dual-role throttle
    $DAYS_BACK   = 3     # search window, matches prior single-DC tool's default
    $F_UI        = New-Object System.Drawing.Font('Segoe UI', 9)
    $F_UI_B      = New-Object System.Drawing.Font('Segoe UI', 9,  [System.Drawing.FontStyle]::Bold)
    $F_UI_T      = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
    $F_MONO      = New-Object System.Drawing.Font('Consolas', 8)
    $C_TITLE     = [System.Drawing.Color]::FromArgb(0, 99, 177)
    $C_BG        = [System.Drawing.Color]::FromArgb(235, 238, 242)
    $C_RED       = [System.Drawing.Color]::FromArgb(200, 40, 40)
    $C_GREEN     = [System.Drawing.Color]::FromArgb(0, 130, 60)
    $C_AMBER     = [System.Drawing.Color]::FromArgb(190, 120, 0)
    $C_DIM       = [System.Drawing.Color]::DimGray
    $C_ROW_OK    = [System.Drawing.Color]::FromArgb(198, 239, 206)
    $C_ROW_OK_F  = [System.Drawing.Color]::FromArgb(0, 97, 0)
    $C_ROW_WARN  = [System.Drawing.Color]::FromArgb(255, 235, 156)
    $C_ROW_WARN_F = [System.Drawing.Color]::FromArgb(156, 101, 0)
    $C_ROW_ERR   = [System.Drawing.Color]::FromArgb(255, 199, 206)
    $C_ROW_ERR_F = [System.Drawing.Color]::FromArgb(156, 0, 6)

    $titleText = $Sam
    if ($DisplayName) { $titleText = "$Sam  ($DisplayName)" }

    # ---- Form -------------------------------------------------------------
    $dlg                 = New-Object System.Windows.Forms.Form
    $dlg.Text            = "Check Lockout Status - $Sam"
    $dlg.ClientSize      = New-Object System.Drawing.Size(970, 766)
    $dlg.FormBorderStyle = 'FixedSingle'
    $dlg.MaximizeBox     = $false
    $dlg.MinimizeBox     = $false
    $dlg.StartPosition   = 'CenterParent'
    $dlg.BackColor       = $C_BG
    $dlg.Font            = $F_UI

    # Title bar
    $pTitle           = New-Object System.Windows.Forms.Panel
    $pTitle.Location  = New-Object System.Drawing.Point(0, 0)
    $pTitle.Size      = New-Object System.Drawing.Size(970, 48)
    $pTitle.BackColor = $C_TITLE
    $dlg.Controls.Add($pTitle)

    $lTitle           = New-Object System.Windows.Forms.Label
    $lTitle.Text      = "   Check Lockout Status  -  $titleText"
    $lTitle.Location  = New-Object System.Drawing.Point(0, 0)
    $lTitle.Size      = New-Object System.Drawing.Size(970, 48)
    $lTitle.Font      = $F_UI_T
    $lTitle.ForeColor = [System.Drawing.Color]::White
    $lTitle.TextAlign = 'MiddleLeft'
    $pTitle.Controls.Add($lTitle)

    # ---- Section 1: Account Status (PDC) -----------------------------------
    function New-Section {
        param([string]$Title, [int]$X, [int]$Y, [int]$W, [int]$ContentH)
        $HDR_H = 24
        $H     = $ContentH + $HDR_H + 1
        $border           = New-Object System.Windows.Forms.Panel
        $border.Location  = New-Object System.Drawing.Point($X, $Y)
        $border.Size      = New-Object System.Drawing.Size($W, $H)
        $border.BackColor = [System.Drawing.Color]::FromArgb(160, 160, 160)
        $dlg.Controls.Add($border)
        $hdr           = New-Object System.Windows.Forms.Panel
        $hdr.Location  = New-Object System.Drawing.Point(1, 0)
        $hdr.Size      = New-Object System.Drawing.Size(($W - 2), $HDR_H)
        $hdr.BackColor = [System.Drawing.Color]::FromArgb(210, 225, 245)
        $border.Controls.Add($hdr)
        $lbl           = New-Object System.Windows.Forms.Label
        $lbl.Text      = "  $Title"
        $lbl.Location  = New-Object System.Drawing.Point(0, 0)
        $lbl.Size      = New-Object System.Drawing.Size(($W - 2), $HDR_H)
        $lbl.Font      = $F_UI_B
        $lbl.ForeColor = [System.Drawing.Color]::FromArgb(0, 80, 160)
        $lbl.TextAlign = 'MiddleLeft'
        $hdr.Controls.Add($lbl)
        $inner           = New-Object System.Windows.Forms.Panel
        $inner.Location  = New-Object System.Drawing.Point(1, $HDR_H)
        $inner.Size      = New-Object System.Drawing.Size(($W - 2), ($H - $HDR_H - 1))
        $inner.BackColor = [System.Drawing.Color]::White
        $border.Controls.Add($inner)
        return $inner
    }

    function New-Row {
        param($Panel, [string]$Label, [int]$Top)
        $lbl           = New-Object System.Windows.Forms.Label
        $lbl.Text      = $Label
        $lbl.ForeColor = $C_DIM
        $lbl.Size      = New-Object System.Drawing.Size(190, 22)
        $lbl.Location  = New-Object System.Drawing.Point(10, $Top)
        $lbl.Font      = $F_UI
        $val           = New-Object System.Windows.Forms.Label
        $val.Text      = 'Loading...'
        $val.ForeColor = [System.Drawing.Color]::Black
        $val.Size      = New-Object System.Drawing.Size(560, 22)
        $val.Location  = New-Object System.Drawing.Point(204, $Top)
        $val.Font      = $F_UI_B
        $Panel.Controls.Add($lbl)
        $Panel.Controls.Add($val)
        return $val
    }

    $pSummary = New-Section -Title 'Account Status (queried against PDC Emulator)' -X 12 -Y 56 -W 946 -ContentH 195

    $valDisplay   = New-Row $pSummary 'Display Name:'        10
    $valEnabled   = New-Row $pSummary 'Account Enabled:'     36
    $valLocked    = New-Row $pSummary 'Locked Out:'          62
    $valBadCount  = New-Row $pSummary 'Bad Logon Count:'     88
    $valThreshold = New-Row $pSummary 'Lockout Threshold:'  114
    $valRemaining = New-Row $pSummary 'Attempts Remaining:' 140
    $valPDC       = New-Row $pSummary 'Queried DC (PDC):'   166

    # ---- Section 2: DC picker ----------------------------------------------
    $pDCs = New-Section -Title 'Select Domain Controllers to Scan for Lockout Source' -X 12 -Y 284 -W 946 -ContentH 150

    $clbDCs               = New-Object System.Windows.Forms.CheckedListBox
    $clbDCs.Location      = New-Object System.Drawing.Point(8, 8)
    $clbDCs.Size          = New-Object System.Drawing.Size(780, 90)
    $clbDCs.Font          = $F_MONO
    $clbDCs.CheckOnClick  = $true
    $pDCs.Controls.Add($clbDCs)

    $btnSelectAll          = New-Object System.Windows.Forms.Button
    $btnSelectAll.Text     = 'Select All'
    $btnSelectAll.Location = New-Object System.Drawing.Point(8, 104)
    $btnSelectAll.Size     = New-Object System.Drawing.Size(90, 26)
    $btnSelectAll.Font     = $F_UI
    $pDCs.Controls.Add($btnSelectAll)

    $btnSelectNone          = New-Object System.Windows.Forms.Button
    $btnSelectNone.Text     = 'Select None'
    $btnSelectNone.Location = New-Object System.Drawing.Point(104, 104)
    $btnSelectNone.Size     = New-Object System.Drawing.Size(90, 26)
    $btnSelectNone.Font     = $F_UI
    $pDCs.Controls.Add($btnSelectNone)

    $lblWindow           = New-Object System.Windows.Forms.Label
    $lblWindow.Text      = "Search window: last $DAYS_BACK days  |  4740 (PDC), then 4771/4625 per DC"
    $lblWindow.Location  = New-Object System.Drawing.Point(210, 109)
    $lblWindow.Size      = New-Object System.Drawing.Size(345, 20)
    $lblWindow.Font      = $F_UI
    $lblWindow.ForeColor = $C_DIM
    $pDCs.Controls.Add($lblWindow)

    $btnScan          = New-Object System.Windows.Forms.Button
    $btnScan.Text     = 'Scan Selected DCs'
    $btnScan.Location = New-Object System.Drawing.Point(560, 104)
    $btnScan.Size     = New-Object System.Drawing.Size(130, 26)
    $btnScan.Font     = $F_UI_B
    $pDCs.Controls.Add($btnScan)

    $btnStop          = New-Object System.Windows.Forms.Button
    $btnStop.Text     = 'Stop'
    $btnStop.Location = New-Object System.Drawing.Point(696, 104)
    $btnStop.Size     = New-Object System.Drawing.Size(84, 26)
    $btnStop.Font     = $F_UI_B
    $btnStop.Enabled  = $false
    $pDCs.Controls.Add($btnStop)

    # ---- Section 3: Results -------------------------------------------------
    $pResults = New-Section -Title 'Lockout Source Results' -X 12 -Y 442 -W 946 -ContentH 190

    $lv               = New-Object System.Windows.Forms.ListView
    $lv.Location      = New-Object System.Drawing.Point(7, 7)
    $lv.Size          = New-Object System.Drawing.Size(930, 176)
    $lv.View          = 'Details'
    $lv.FullRowSelect = $true
    $lv.MultiSelect   = $false
    $lv.GridLines     = $true
    $lv.Font          = $F_MONO
    $lv.BorderStyle   = 'FixedSingle'
    $lv.Columns.Add('DC',                 85)  | Out-Null
    $lv.Columns.Add('Event Time',        115)  | Out-Null
    $lv.Columns.Add('Correlated Event',  150)  | Out-Null
    $lv.Columns.Add('Source Computer',   110)  | Out-Null
    $lv.Columns.Add('Source IP',         100)  | Out-Null
    $lv.Columns.Add('Resolved Host',     130)  | Out-Null
    $lv.Columns.Add('Failure Code',       75)  | Out-Null
    $lv.Columns.Add('Notes',             165)  | Out-Null
    $pResults.Controls.Add($lv)

    # Context menu object itself can be built here safely (plain object
    # construction, not an event delegate). Its Click handler - and the
    # grid's DoubleClick/MouseUp handlers - are wired later in "Button
    # events", AFTER $showRowDetailFn is captured: .GetNewClosure()
    # snapshots referenced variables at the moment it is called, so wiring
    # these here (before that capture exists) would bind them to a
    # not-yet-assigned $showRowDetailFn permanently, exactly like the
    # $script:LockPDC timing bug fixed earlier in this file.
    $cmsResults   = New-Object System.Windows.Forms.ContextMenuStrip
    $miViewDetail = New-Object System.Windows.Forms.ToolStripMenuItem('View Details...')
    [void]$cmsResults.Items.Add($miViewDetail)
    $lv.ContextMenuStrip = $cmsResults

    # ---- Bottom buttons -------------------------------------------------------
    $pBtn             = New-Object System.Windows.Forms.Panel
    $pBtn.Location    = New-Object System.Drawing.Point(12, 658)
    $pBtn.Size        = New-Object System.Drawing.Size(946, 40)
    $pBtn.BackColor   = $C_BG
    $dlg.Controls.Add($pBtn)

    $btnCopy             = New-Object System.Windows.Forms.Button
    $btnCopy.Text        = 'Copy to Clipboard'
    $btnCopy.Location    = New-Object System.Drawing.Point(0, 6)
    $btnCopy.Size        = New-Object System.Drawing.Size(140, 28)
    $btnCopy.Font        = $F_UI
    $btnCopy.Enabled     = $false
    $pBtn.Controls.Add($btnCopy)

    $btnExport           = New-Object System.Windows.Forms.Button
    $btnExport.Text      = 'Export CSV'
    $btnExport.Location  = New-Object System.Drawing.Point(148, 6)
    $btnExport.Size      = New-Object System.Drawing.Size(110, 28)
    $btnExport.Font      = $F_UI
    $btnExport.Enabled   = $false
    $pBtn.Controls.Add($btnExport)

    $lThreads            = New-Object System.Windows.Forms.Label
    $lThreads.Text       = "Threads: $THREAD_CAP"
    $lThreads.Location   = New-Object System.Drawing.Point(420, 11)
    $lThreads.Size       = New-Object System.Drawing.Size(150, 18)
    $lThreads.Font       = $F_UI
    $lThreads.ForeColor  = $C_DIM
    $lThreads.TextAlign  = 'MiddleRight'
    $pBtn.Controls.Add($lThreads)

    $btnClose            = New-Object System.Windows.Forms.Button
    $btnClose.Text       = 'Close'
    $btnClose.Location   = New-Object System.Drawing.Point(846, 6)
    $btnClose.Size       = New-Object System.Drawing.Size(100, 28)
    $btnClose.Font       = $F_UI
    $pBtn.Controls.Add($btnClose)

    # Status bar
    $lStatus            = New-Object System.Windows.Forms.Label
    $lStatus.Text       = 'Loading account status...'
    $lStatus.Location   = New-Object System.Drawing.Point(12, 706)
    $lStatus.Size       = New-Object System.Drawing.Size(946, 40)
    $lStatus.Font       = $F_UI
    $lStatus.ForeColor  = $C_DIM
    $dlg.Controls.Add($lStatus)

    # ---- Scan state ---------------------------------------------------------
    # Shared mutable state lives on $dlg.Tag (a hashtable), NOT on bare
    # $script: scalars. $script:LockPDC / $script:LockScanStop were tried
    # first and proved unreliable: .GetNewClosure() snapshots the value of
    # every variable referenced in a block - including $script:-prefixed
    # ones - at the moment GetNewClosure() is called (dialog construction,
    # before Add_Shown has run), not live at click-time. A later write from
    # a DIFFERENT closure (e.g. Add_Shown resolving the PDC, or the Stop
    # button setting the stop flag) never reaches a scalar already
    # snapshotted elsewhere. $dlg.Tag is a property on a shared .NET object
    # reference, exactly like $lv.Items or $btnCopy.Enabled elsewhere in
    # this file - mutating a property on the SAME object is always visible
    # across every closure that captured $dlg, regardless of when each
    # closure was created.
    $dlg.Tag = @{ PDC = ''; ScanStop = $false }   # PDC set in Add_Shown once Get-LockoutSummary resolves it
    $lockEventBlock       = $script:LockEventBlock

    # Get-LockoutSummary / Get-LockoutEvent / Show-LockoutRowDetail are
    # unreachable by bare name from inside the Add_Shown / btnScan /
    # results-grid .GetNewClosure() blocks below (same closure-scope
    # resolution bug documented and worked around throughout
    # ADDirectory_Menus.psm1 for Confirm-Action / Write-OperationLog /
    # Show-DisableAccountDialog etc.), so all three are captured here once
    # and invoked via & inside the closures.
    $getLockoutSummaryFn  = ${function:Get-LockoutSummary}
    $getLockoutEventFn    = ${function:Get-LockoutEvent}
    $showRowDetailFn      = ${function:Show-LockoutRowDetail}

    # ---- Button events ------------------------------------------------------
    $btnClose.Add_Click({ $dlg.Close() })

    # Double-click or right-click -> View Details opens Show-LockoutRowDetail
    # for the selected row, reading the raw result object stashed on
    # ListViewItem.Tag when the row was created (not re-parsed from the
    # grid's truncated column text). A ListView with a ContextMenuStrip
    # assigned does NOT auto-select the item under the cursor on right-click
    # in WinForms - that has to be done explicitly in MouseUp, or "View
    # Details" would act on whatever was already selected (or nothing).
    $lv.Add_MouseUp({
        param($senderObj, $e)
        if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Right) {
            $hit = $lv.HitTest($e.X, $e.Y).Item
            if ($hit) {
                $lv.SelectedItems.Clear()
                $hit.Selected = $true
                $hit.Focused  = $true
            }
        }
    }.GetNewClosure())

    $miViewDetail.Add_Click({
        if ($lv.SelectedItems.Count -gt 0) {
            $tag = $lv.SelectedItems[0].Tag
            if ($tag) {
                & $showRowDetailFn -DCName $tag.DC -Diagnostic $tag.Diagnostic -Result $tag.Result
            }
        }
    }.GetNewClosure())

    $lv.Add_DoubleClick({
        if ($lv.SelectedItems.Count -gt 0) {
            $tag = $lv.SelectedItems[0].Tag
            if ($tag) {
                & $showRowDetailFn -DCName $tag.DC -Diagnostic $tag.Diagnostic -Result $tag.Result
            }
        }
    }.GetNewClosure())

    $btnSelectAll.Add_Click({
        for ($i = 0; $i -lt $clbDCs.Items.Count; $i++) { $clbDCs.SetItemChecked($i, $true) }
    }.GetNewClosure())

    $btnSelectNone.Add_Click({
        for ($i = 0; $i -lt $clbDCs.Items.Count; $i++) { $clbDCs.SetItemChecked($i, $false) }
    }.GetNewClosure())

    $btnStop.Add_Click({ $dlg.Tag.ScanStop = $true }.GetNewClosure())

    $btnCopy.Add_Click({
        $lines = [System.Collections.Generic.List[string]]::new()
        foreach ($item in $lv.Items) {
            $cols = [System.Collections.Generic.List[string]]::new()
            [void]$cols.Add($item.Text)
            foreach ($sub in $item.SubItems) {
                if ($sub.Text -ne $item.Text) { [void]$cols.Add($sub.Text) }
            }
            [void]$lines.Add($cols -join "`t")
        }
        if ($lines.Count -gt 0) {
            [System.Windows.Forms.Clipboard]::SetText($lines -join "`r`n")
            $lStatus.Text = 'Results copied to clipboard.'
        }
    }.GetNewClosure())

    $btnExport.Add_Click({
        $sfd          = New-Object System.Windows.Forms.SaveFileDialog
        $sfd.Filter   = 'CSV Files (*.csv)|*.csv|All Files (*.*)|*.*'
        $stamp        = Get-Date -Format 'yyyyMMdd_HHmm'
        $sfd.FileName = "LockoutStatus_${Sam}_$stamp.csv"
        if ($sfd.ShowDialog() -eq 'OK') {
            $rows = [System.Collections.Generic.List[PSCustomObject]]::new()
            foreach ($item in $lv.Items) {
                [void]$rows.Add([PSCustomObject]@{
                    DC               = $item.Text
                    EventTime        = $item.SubItems[1].Text
                    CorrelatedEvent  = $item.SubItems[2].Text
                    SourceComputer   = $item.SubItems[3].Text
                    SourceIP         = $item.SubItems[4].Text
                    ResolvedHost     = $item.SubItems[5].Text
                    FailureCode      = $item.SubItems[6].Text
                    Notes            = $item.SubItems[7].Text
                })
            }
            $rows | Export-Csv -Path $sfd.FileName -NoTypeInformation
            $lStatus.Text = "Exported to: $($sfd.FileName)"
        }
    }.GetNewClosure())

    $btnScan.Add_Click({
        $checked = [System.Collections.Generic.List[string]]::new()
        for ($i = 0; $i -lt $clbDCs.Items.Count; $i++) {
            if ($clbDCs.GetItemChecked($i)) { [void]$checked.Add([string]$clbDCs.Items[$i]) }
        }
        if ($checked.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show(
                'Select at least one domain controller to scan.',
                'Check Lockout Status', 'OK', 'Information')
            return
        }

        $lv.Items.Clear()
        $btnCopy.Enabled    = $false
        $btnExport.Enabled  = $false
        $btnScan.Enabled    = $false
        $btnStop.Enabled    = $true
        $dlg.Tag.ScanStop   = $false

        # ---- Stage 1: locate the confirmed 4740 on the PDC only ----------
        $lStatus.Text = 'Locating 4740 lockout event on PDC...'
        [System.Windows.Forms.Application]::DoEvents()

        $lockEvt    = & $getLockoutEventFn -Sam $Sam -PDCServer $dlg.Tag.PDC -DaysBack $DAYS_BACK
        $diagnostic = $false

        if ($lockEvt.Found) {
            $corrStart = $lockEvt.LockoutTime.AddMinutes(-10)
            $corrEnd   = $lockEvt.LockoutTime.AddSeconds(5)
            $callerTxt = 'not recorded'
            if ($lockEvt.CallerComputer) { $callerTxt = $lockEvt.CallerComputer }
            $lStatus.Text = "Lockout confirmed $($lockEvt.LockoutTime.ToString('MM/dd/yyyy hh:mm:ss tt')) on PDC ($($dlg.Tag.PDC)). 4740 Caller Computer: $callerTxt. Scanning selected DC(s)..."
        } else {
            $diagnostic = $true
            $corrStart  = (Get-Date).AddDays(0 - $DAYS_BACK)
            $corrEnd    = Get-Date
            if ($lockEvt.ErrorMsg) {
                $lStatus.Text = "Could not confirm 4740 on PDC ($($dlg.Tag.PDC)): $($lockEvt.ErrorMsg). DIAGNOSTIC MODE - scanning selected DC(s) over the last $DAYS_BACK days..."
            } else {
                $lStatus.Text = "No 4740 lockout event found on PDC ($($dlg.Tag.PDC)) in the last $DAYS_BACK days. DIAGNOSTIC MODE - scanning selected DC(s) over the full window..."
            }
        }
        [System.Windows.Forms.Application]::DoEvents()

        # ---- Stage 2: fan the 4771/4625 search out to every selected DC ---
        $total = $checked.Count

        $pool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(1, $THREAD_CAP)
        $pool.Open()

        $jobs = [System.Collections.Generic.List[hashtable]]::new()
        foreach ($dcName in $checked) {
            $ps = [System.Management.Automation.PowerShell]::Create()
            $ps.RunspacePool = $pool
            [void]$ps.AddScript($lockEventBlock).AddArgument($dcName).AddArgument($Sam).AddArgument($corrStart).AddArgument($corrEnd).AddArgument($diagnostic)
            [void]$jobs.Add(@{ PS = $ps; Handle = $ps.BeginInvoke(); DC = $dcName })
        }

        $remaining   = [System.Collections.Generic.List[hashtable]]::new($jobs)
        $scanned     = 0
        $sourceFound = 0
        $wasStopped  = $false

        while ($remaining.Count -gt 0) {
            if ($dlg.Tag.ScanStop) {
                # Do not call PS.Dispose()/Stop() or pool.Close() here - those
                # block until every in-flight pipeline finishes, and a
                # slow/offline DC over a WAN link can hang for 20-30s+. Drop
                # the references instead and let GC reclaim them.
                $wasStopped = $true
                $remaining.Clear()
                break
            }

            $done = @($remaining | Where-Object { $_.Handle.IsCompleted })
            foreach ($job in $done) {
                $result = $null
                try { $result = $job.PS.EndInvoke($job.Handle) } catch { }
                $job.PS.Dispose()
                [void]$remaining.Remove($job)
                $scanned++

                $item = New-Object System.Windows.Forms.ListViewItem($job.DC)
                $item.Tag = [PSCustomObject]@{ DC = $job.DC; Diagnostic = $diagnostic; Result = $result }

                if (-not $result) {
                    $item.BackColor = $C_ROW_ERR
                    $item.ForeColor = $C_ROW_ERR_F
                    [void]$item.SubItems.Add('-')
                    [void]$item.SubItems.Add('-')
                    [void]$item.SubItems.Add('-')
                    [void]$item.SubItems.Add('-')
                    [void]$item.SubItems.Add('-')
                    [void]$item.SubItems.Add('-')
                    [void]$item.SubItems.Add('Scan failed (no result returned).')
                } elseif ($result.ErrorMsg) {
                    $item.BackColor = $C_ROW_ERR
                    $item.ForeColor = $C_ROW_ERR_F
                    [void]$item.SubItems.Add('-')
                    [void]$item.SubItems.Add('-')
                    [void]$item.SubItems.Add('-')
                    [void]$item.SubItems.Add('-')
                    [void]$item.SubItems.Add('-')
                    [void]$item.SubItems.Add('-')
                    [void]$item.SubItems.Add($result.ErrorMsg)
                } elseif (-not $result.EventFound) {
                    [void]$item.SubItems.Add('-')
                    [void]$item.SubItems.Add('-')
                    [void]$item.SubItems.Add('-')
                    [void]$item.SubItems.Add('-')
                    [void]$item.SubItems.Add('-')
                    [void]$item.SubItems.Add('-')
                    [void]$item.SubItems.Add($result.Detail)
                } else {
                    $sourceFound++
                    $corrText = '-'
                    if ($result.CorrelatedType) { $corrText = $result.CorrelatedType }
                    $srcCompText = '-'
                    if ($result.SourceComputer) { $srcCompText = $result.SourceComputer }
                    $srcIPText = '-'
                    if ($result.SourceIP) { $srcIPText = $result.SourceIP }
                    $srcHostText = '-'
                    if ($result.SourceHostName) { $srcHostText = $result.SourceHostName }
                    $failText = '-'
                    if ($result.FailureCode) { $failText = $result.FailureCode }
                    $eventTimeText = '-'
                    if ($result.EventTime) { $eventTimeText = $result.EventTime.ToString('MM/dd/yyyy hh:mm:ss tt') }

                    if ($diagnostic) {
                        # Not a confirmed lockout-cause match - amber, same
                        # as the "found but uncorrelated" case used to be.
                        $item.BackColor = $C_ROW_WARN
                        $item.ForeColor = $C_ROW_WARN_F
                    } else {
                        $item.BackColor = $C_ROW_OK
                        $item.ForeColor = $C_ROW_OK_F
                    }

                    [void]$item.SubItems.Add($eventTimeText)
                    [void]$item.SubItems.Add($corrText)
                    [void]$item.SubItems.Add($srcCompText)
                    [void]$item.SubItems.Add($srcIPText)
                    [void]$item.SubItems.Add($srcHostText)
                    [void]$item.SubItems.Add($failText)
                    [void]$item.SubItems.Add($result.Detail)
                }

                $lv.Items.Add($item) | Out-Null
                $modeSuffix = ''
                if ($diagnostic) { $modeSuffix = '  (diagnostic mode)' }
                $lStatus.Text = "Scanning $scanned / $total  |  Source events found: $sourceFound$modeSuffix"
                [System.Windows.Forms.Application]::DoEvents()
            }

            if ($remaining.Count -gt 0) { [System.Windows.Forms.Application]::DoEvents() }
        }

        if (-not $wasStopped) {
            $pool.Close()
            $pool.Dispose()
        }

        $btnScan.Enabled = $true
        $btnStop.Enabled = $false

        if ($wasStopped) {
            $modeSuffix = ''
            if ($diagnostic) { $modeSuffix = ' (diagnostic mode - no confirmed 4740)' }
            $lStatus.Text = "Scan stopped at $scanned / $total  |  Source events found: $sourceFound$modeSuffix"
        } else {
            $modeSuffix = ''
            if ($diagnostic) { $modeSuffix = ' (diagnostic mode - no confirmed 4740)' }
            $lStatus.Text = "Scan complete  |  $total DC(s) checked  |  Source events found: $sourceFound$modeSuffix"
        }

        if ($lv.Items.Count -gt 0) {
            $btnCopy.Enabled   = $true
            $btnExport.Enabled = $true
        }
    }.GetNewClosure())

    # ---- Load summary + DC list on Shown -----------------------------------
    $dlg.Add_Shown({
        [System.Windows.Forms.Application]::DoEvents()

        $summary = & $getLockoutSummaryFn -Sam $Sam -Context $Context

        if ($summary.Success) {
            $valDisplay.Text = $summary.DisplayName

            if ($summary.Enabled) {
                $valEnabled.Text      = 'Yes'
                $valEnabled.ForeColor = $C_GREEN
            } else {
                $valEnabled.Text      = 'No (Disabled)'
                $valEnabled.ForeColor = $C_AMBER
            }

            if ($summary.LockedOut) {
                $valLocked.Text      = 'YES'
                $valLocked.ForeColor = $C_RED
            } else {
                $valLocked.Text      = 'No'
                $valLocked.ForeColor = $C_GREEN
            }

            $valBadCount.Text  = "$($summary.BadLogonCount)"
            $valThreshold.Text = "$($summary.Threshold)"

            if ($summary.Threshold -eq 0) {
                $valRemaining.Text      = 'No lockout policy set'
                $valRemaining.ForeColor = $C_DIM
            } elseif ($summary.Remaining -le 1) {
                $valRemaining.Text      = "$($summary.Remaining)  !! WARNING"
                $valRemaining.ForeColor = $C_RED
            } elseif ($summary.Remaining -le 3) {
                $valRemaining.Text      = "$($summary.Remaining)"
                $valRemaining.ForeColor = $C_AMBER
            } else {
                $valRemaining.Text      = "$($summary.Remaining)"
                $valRemaining.ForeColor = $C_GREEN
            }

            $valPDC.Text     = $summary.PDC
            $dlg.Tag.PDC     = $summary.PDC
            $lStatus.Text    = 'Account status loaded. Select DC(s) below and click Scan.'
        } else {
            $valDisplay.Text   = 'N/A'
            $valEnabled.Text   = 'N/A'
            $valLocked.Text    = 'N/A'
            $valBadCount.Text  = 'N/A'
            $valThreshold.Text = 'N/A'
            $valRemaining.Text = 'N/A'
            $valPDC.Text       = 'N/A'
            $dlg.Tag.PDC       = ''
            $lStatus.Text      = "Error loading account status: $($summary.ErrorMsg)"
            $lStatus.ForeColor = $C_RED
        }

        # Populate DC checklist (independent of summary success - a user
        # lookup failure shouldn't block scanning the event logs directly).
        try {
            $dcSrv = ''
            if ($summary.PDC) { $dcSrv = $summary.PDC } elseif ($Context -and $Context.TargetDC) { $dcSrv = $Context.TargetDC }

            $dcP = @{ Filter = '*'; ErrorAction = 'Stop' }
            if ($dcSrv) { $dcP.Server = $dcSrv }
            $dcs = Get-ADDomainController @dcP | Sort-Object Name

            foreach ($dc in $dcs) {
                $idx = $clbDCs.Items.Add($dc.HostName)
                if ($summary.PDC -and $dc.HostName -eq $summary.PDC) {
                    $clbDCs.SetItemChecked($idx, $true)
                }
            }

            if ($clbDCs.Items.Count -eq 0) {
                $lblWindow.Text = 'No domain controllers found.'
            }
        } catch {
            $lblWindow.Text = "DC enumeration failed: $($_.Exception.Message)"
        }
    }.GetNewClosure())

    [void]$dlg.ShowDialog()
}
#endregion

Export-ModuleMember -Function Show-LockoutStatusDialog
