#region -- Services.Mail.Send.psm1 -------------------------------------------
# Concern : Send-ADNotificationMail - single responsibility: compose a
#           formatted HTML notification email and send it through the fixed
#           SMTP relay defined on the shared Context. Pure transport + format.
#           No WinForms UI (the popup lives in Services.Mail.Dialog).
#
#           Formatting:
#             The email body is assembled from three caller-supplied parts:
#               ActionTitle - short banner subtitle (e.g. 'Password Reset')
#               Details     - ordered label/value pairs rendered as a table
#                             (Account, Admin, Domain, DC, Timestamp, etc.)
#               BodyText    - the admin-editable free-text message; line
#                             breaks are preserved as <br>.
#             All values are HTML-escaped and constrained to ASCII.
#
#             Bold heading marker (Services.Mail.Dialog's Additional Info
#             feature): after BodyText is escaped and CRLF converted to
#             <br>, a literal [[B]]...[[/B]] wrapper is swapped for <b>...
#             </b> as the LAST step of free-text rendering. The marker uses
#             only plain ASCII brackets - no HTML-significant characters -
#             so it passes through the escaping step untouched, meaning the
#             text inside it was already escaped exactly like the rest of
#             the body before the tags are added; only the wrapping tags
#             are ever injected structurally, never raw input. This is a
#             narrow, single-purpose convention (Services.Mail.Dialog is the
#             only producer of this marker today) rather than a general
#             admin-facing bold syntax - if an admin happened to type the
#             literal marker text into the Message box by hand, it would
#             render bold too, which is harmless.
#
#           Recovery detail blocks (ConvertTo-MailRecoveryBlock):
#             For actions that remove/disable/delete an AD object, callers
#             build a plain-text "AD Item N: <label> / OU: ... / Groups (n):
#             ..." block via ConvertTo-MailRecoveryBlock and append it into
#             BodyText before calling Send-ADNotificationMail. Each group or
#             member name is rendered on its own "- <name>" line rather than
#             joined into a single comma/semicolon-separated string - a
#             single dash-prefixed line has no LEADING whitespace, so it
#             survives the HTML body's CRLF-to-<br> conversion below intact;
#             only actual leading indentation (2+ spaces) collapses in real
#             mail clients, which is why nested sub-bullets are still
#             avoided. Copy/paste-safe, and needs no change to the HTML body
#             builder below.
#
#           Transport:
#             Uses [System.Net.Mail.SmtpClient] (fully supported on .NET 4.8)
#             rather than the deprecated Send-MailMessage, so a connection
#             timeout can be enforced. This prevents a slow or unreachable
#             relay from freezing the WinForms UI thread on the RDS host.
#             Anonymous relay (no credentials, no SSL) per environment.
#
#           Runtime diagnostics:
#             Test-MailContext inspects a Context object and reports the
#             state of every mail-config field (Missing property / Blank
#             value / OK) plus a timed TCP reachability probe of the relay.
#             Send-ADNotificationMail calls it on any config-guard failure
#             so the returned Message is a full field-by-field report rather
#             than a single collapsed line. This makes an empty SmtpServer
#             at runtime self-explanatory: the operator sees exactly which
#             field is absent vs present-but-blank and what the others hold.
#
#           Non-fatal contract:
#             Send-ADNotificationMail NEVER throws. Every failure path
#             returns Success=$false with a Message. Callers invoke it AFTER
#             the AD action has already committed, so a mail failure must
#             never affect the account operation. Test-MailContext likewise
#             never throws.
#
# Load order: 4b - depends only on Services.Logging (Write-OperationLog,
#                  optional - guarded). No AD-Admin UI dependencies.
# Config    : Context.MailEnabled / Context.SmtpServer / Context.SmtpPort /
#             Context.MailFrom  (all populated in _AD-Admin.ps1).
# Changes   : Added ConvertTo-MailRecoveryBlock (see above). Footer line no
#             longer names the suite/script - generic "Automated message. Do
#             not reply." wording so no internal file/product name is ever
#             visible in a sent email.
#             v1.5.0 - Send-ADNotificationMail gained two optional
#             parameters for formatted Additional Info blocks (Services.
#             Mail.Dialog):
#               -AppendHtml   formatted HTML rendered after the free-text
#                             message. ALWAYS passed through
#                             ConvertTo-SafeMailHtml (Services.Mail.RichHtml)
#                             here, whatever the caller did - the one choke
#                             point that guarantees only allowlisted tags,
#                             styles and http/https/mailto links reach a
#                             recipient. If that module is not loaded the
#                             block is sent as escaped plain text instead.
#               -InlineImages hashtable Id -> @{ Type; Data(base64) }.
#                             Every picture the sanitized HTML references as
#                             cid:Id is attached as an inline (related)
#                             LinkedResource of an HTML AlternateView, so it
#                             shows without "download pictures" prompts.
#                             Unreferenced entries are ignored; references
#                             with no picture are removed from the HTML.
#             Callers that pass neither parameter get exactly the previous
#             message (plain Body, no AlternateView).
#             v1.6.0 - plain layout: the blue banner, the shaded detail
#             table and the bordered boxes are gone. Detail rows render as
#             plain "Label: value" lines, then the message, then the
#             Additional Info blocks, then the footer line. New optional
#             -IntroHtml (sanitized, pictures embedded like AppendHtml)
#             renders first - Services.Mail.Dialog passes the new-account
#             welcome through it. ActionTitle is no longer shown in the
#             body (it stays a parameter for callers and logging).
#             Load order: now also uses Services.Mail.RichHtml (4a1) and
#             Services.Mail.Images (4a2, New-MailLinkedResource) - both load
#             before this module; both optional (guarded).
#endregion

#region -- Test-MailContext ---------------------------------------------------
function Test-MailContext {
    <#
    .SYNOPSIS
        Inspects a Context object and reports the runtime state of every mail
        configuration field, plus an optional timed TCP reachability probe of
        the SMTP relay. Never throws. Returns a structured result and a
        formatted multi-line ASCII report suitable for a status label or log.
    .PARAMETER Context
        Shared context object. Reads MailEnabled, SmtpServer, SmtpPort,
        MailFrom. A $null Context is reported explicitly rather than throwing.
    .PARAMETER TestConnection
        When set, attempts a timed TCP connect to SmtpServer:SmtpPort using
        [System.Net.Sockets.TcpClient] with a hard timeout. Skipped when the
        server field is missing or blank.
    .PARAMETER ConnectTimeoutMs
        TCP connect timeout in milliseconds (default 3000). Kept short so the
        diagnostic never freezes the WinForms UI thread.
    .OUTPUTS
        PSCustomObject:
            ConfigOk     [bool]   - all required config fields present + set
            Reachable    [bool]   - TCP probe succeeded (only meaningful when
                                    TestConnection used and ConfigOk true)
            Tested       [bool]   - whether a TCP probe was actually run
            Server       [string] - resolved server value ('' if none)
            Port         [int]    - resolved port value
            From         [string] - resolved from value ('' if none)
            Enabled      [bool]   - MailEnabled state
            Report       [string] - formatted multi-line ASCII report
    #>
    param(
        [PSCustomObject]$Context,
        [switch]$TestConnection,
        [int]$ConnectTimeoutMs = 3000
    )

    $lines = [System.Collections.Generic.List[string]]::new()

    # -- Null context guard -------------------------------------------------
    if (-not $Context) {
        $lines.Add('Mail configuration diagnostic')
        $lines.Add('-----------------------------')
        $lines.Add('Context      : NULL - no context object was passed to the mail path.')
        $lines.Add('')
        $lines.Add('The dialog received no Context. Verify the caller passes -Context')
        $lines.Add('and that the launcher shared context object exists.')
        return [PSCustomObject]@{
            ConfigOk  = $false
            Reachable = $false
            Tested    = $false
            Server    = ''
            Port      = 0
            From      = ''
            Enabled   = $false
            Report    = ($lines -join "`r`n")
        }
    }

    $propNames = @($Context.PSObject.Properties.Name)

    # -- Per-field state helper (returns a formatted status token) ----------
    #    Reports three distinct states so 'property absent' is never confused
    #    with 'property present but blank' - the exact ambiguity that made the
    #    original single-line error impossible to diagnose.
    $describeField = {
        param([string]$Name)
        if ($propNames -notcontains $Name) {
            return @{ State = 'MISSING'; Value = ''; Text = ("MISSING  - property '" + $Name + "' is not defined on Context") }
        }
        $raw = $Context.$Name
        $val = if ($null -eq $raw) { '' } else { [string]$raw }
        if (-not $val.Trim()) {
            return @{ State = 'BLANK'; Value = ''; Text = ("BLANK    - property '" + $Name + "' exists but is empty") }
        }
        return @{ State = 'OK'; Value = $val.Trim(); Text = ("OK       - " + $val.Trim()) }
    }

    $srvField  = & $describeField 'SmtpServer'
    $fromField = & $describeField 'MailFrom'

    # -- Port (numeric, distinct handling) ----------------------------------
    $portVal   = 25
    $portState = 'DEFAULT'
    $portText  = 'DEFAULT  - not set on Context, using 25'
    if ($propNames -contains 'SmtpPort') {
        $rawPort = $Context.SmtpPort
        if ($null -eq $rawPort -or -not ([string]$rawPort).Trim()) {
            $portState = 'BLANK'; $portText = 'BLANK    - property exists but is empty, using 25'; $portVal = 25
        } else {
            $parsed = 0
            if ([int]::TryParse(([string]$rawPort).Trim(), [ref]$parsed) -and $parsed -gt 0) {
                $portVal = $parsed; $portState = 'OK'; $portText = ("OK       - " + $parsed)
            } else {
                $portState = 'INVALID'; $portText = ("INVALID  - '" + [string]$rawPort + "' is not a valid port, using 25"); $portVal = 25
            }
        }
    }

    # -- MailEnabled kill switch --------------------------------------------
    $enabled = $true
    $enabledText = 'OK       - notifications enabled (default)'
    if ($propNames -contains 'MailEnabled') {
        $enabled = [bool]$Context.MailEnabled
        $enabledText = if ($enabled) { 'OK       - notifications enabled' } `
                       else { 'OFF      - Context.MailEnabled is $false (kill switch active)' }
    }

    $serverValue = $srvField.Value
    $fromValue   = $fromField.Value

    $configOk = ($srvField.State -eq 'OK') -and ($fromField.State -eq 'OK') -and $enabled

    # -- TCP reachability probe (timed, non-blocking) -----------------------
    $tested    = $false
    $reachable = $false
    $probeText = ''
    if ($TestConnection -and $serverValue) {
        $tested = $true
        $tcp = $null
        try {
            $tcp   = New-Object System.Net.Sockets.TcpClient
            $async = $tcp.BeginConnect($serverValue, $portVal, $null, $null)
            $wait  = $async.AsyncWaitHandle.WaitOne($ConnectTimeoutMs, $false)
            if ($wait -and $tcp.Connected) {
                $tcp.EndConnect($async)
                $reachable = $true
                $probeText = ("REACHABLE - TCP connect to " + $serverValue + ":" + $portVal + " succeeded")
            } elseif ($wait) {
                # Handle signalled but not connected - EndConnect surfaces the error
                try { $tcp.EndConnect($async) } catch { }
                $probeText = ("REFUSED   - " + $serverValue + ":" + $portVal + " did not accept the connection")
            } else {
                $probeText = ("TIMEOUT   - no response from " + $serverValue + ":" + $portVal + " within " + $ConnectTimeoutMs + " ms")
            }
        } catch {
            $probeText = ("ERROR     - " + $serverValue + ":" + $portVal + " probe failed: " + $_.Exception.Message)
        } finally {
            if ($tcp) { try { $tcp.Close() } catch { } }
        }
    } elseif ($TestConnection) {
        $probeText = 'SKIPPED   - no server value to probe'
    }

    # -- Assemble report ----------------------------------------------------
    $lines.Add('Mail configuration diagnostic')
    $lines.Add('-----------------------------')
    $lines.Add('MailEnabled  : ' + $enabledText)
    $lines.Add('SmtpServer   : ' + $srvField.Text)
    $lines.Add('SmtpPort     : ' + $portText)
    $lines.Add('MailFrom     : ' + $fromField.Text)
    if ($tested -or $TestConnection) {
        $lines.Add('Relay probe  : ' + $probeText)
    }
    $lines.Add('')
    if ($configOk) {
        $lines.Add('Config state : OK - all required fields are set.')
    } else {
        $missing = [System.Collections.Generic.List[string]]::new()
        if ($srvField.State  -ne 'OK') { $missing.Add('SmtpServer') }
        if ($fromField.State -ne 'OK') { $missing.Add('MailFrom') }
        if (-not $enabled)             { $missing.Add('MailEnabled(off)') }
        $lines.Add('Config state : INCOMPLETE - resolve: ' + ($missing -join ', '))
    }

    return [PSCustomObject]@{
        ConfigOk  = $configOk
        Reachable = $reachable
        Tested    = $tested
        Server    = $serverValue
        Port      = $portVal
        From      = $fromValue
        Enabled   = $enabled
        Report    = ($lines -join "`r`n")
    }
}
#endregion

#region -- Send-ADNotificationMail --------------------------------------------
function Send-ADNotificationMail {
    <#
    .SYNOPSIS
        Sends a formatted HTML account-action notification via the fixed SMTP
        relay on Context. Never throws; returns a result object. On any config
        failure the Message carries a full Test-MailContext diagnostic report.
    .PARAMETER Context
        Shared context object. Reads MailEnabled, SmtpServer, SmtpPort, MailFrom.
    .PARAMETER To
        Primary recipient (the affected account's mail address).
    .PARAMETER Cc
        Zero or more CC addresses (the admin's mail address).
    .PARAMETER Subject
        Email subject line.
    .PARAMETER ActionTitle
        Short banner subtitle describing the action (e.g. 'Account Created').
    .PARAMETER Details
        Ordered dictionary or hashtable of label -> value rows for the detail
        table. Rendered in insertion order when an ordered dictionary is used.
    .PARAMETER BodyText
        Admin-editable free-text message. Line breaks preserved. Callers that
        need to report recovery detail (OU / groups / members of an item that
        was removed, disabled, or deleted) append the output of
        ConvertTo-MailRecoveryBlock into this string before calling.
    .PARAMETER AppendHtml
        Optional formatted HTML (Additional Info blocks) rendered after
        BodyText. Sanitized here with ConvertTo-SafeMailHtml.
    .PARAMETER InlineImages
        Optional hashtable Id -> @{ Type; Data } of pictures referenced by
        AppendHtml / IntroHtml as cid:Id - embedded in the message.
    .PARAMETER IntroHtml
        Optional formatted HTML shown first, above the detail lines (the
        new-account welcome). Sanitized here like AppendHtml.
    .OUTPUTS
        PSCustomObject: Success=[bool], Message=[string], Diagnostic=[string]
        Diagnostic is populated (full field-by-field report) on config
        failures and empty on transport success/failure.
    #>
    param(
        [PSCustomObject]$Context,
        [string]$To,
        [string[]]$Cc = @(),
        [string]$Subject = 'AD Account Notification',
        [string]$ActionTitle = 'Account Action',
        $Details = $null,
        [string]$BodyText = '',
        [string]$AppendHtml = '',
        [hashtable]$InlineImages = $null,
        [string]$IntroHtml = ''
    )

    # -- Config-guard block: one diagnostic pass covers every field --------
    #    Test-MailContext replaces the previous single-line guards so the
    #    caller sees the complete picture (which field is missing vs blank,
    #    what the others hold, and whether the relay is reachable) instead of
    #    just the first field that failed.
    $diag = Test-MailContext -Context $Context -TestConnection

    # Kill switch is reported by the diagnostic but kept as its own return
    # so callers can distinguish 'disabled on purpose' from 'misconfigured'.
    if ($Context -and ($Context.PSObject.Properties.Name -contains 'MailEnabled') -and (-not $Context.MailEnabled)) {
        return [PSCustomObject]@{
            Success    = $false
            Message    = 'Mail notifications are disabled (Context.MailEnabled = $false).'
            Diagnostic = $diag.Report
        }
    }

    if (-not $diag.ConfigOk) {
        # Lead line names the first problem; full report follows for the label.
        $lead = if (-not $diag.Server) { 'No SMTP server configured (Context.SmtpServer is empty).' } `
                elseif (-not $diag.From) { 'No From address configured (Context.MailFrom is empty).' } `
                else { 'Mail configuration is incomplete.' }
        return [PSCustomObject]@{
            Success    = $false
            Message    = ($lead + "`r`n`r`n" + $diag.Report)
            Diagnostic = $diag.Report
        }
    }

    if (-not $To) {
        return [PSCustomObject]@{
            Success    = $false
            Message    = 'No recipient address (affected account has no mail attribute). Enter a To address.'
            Diagnostic = ''
        }
    }

    $server = $diag.Server
    $from   = $diag.From
    $port   = $diag.Port

    # Non-fatal advisory: config is valid but the relay did not answer the
    # probe. We still attempt the send (the probe is a hint, not a gate) but
    # note it so a later transport timeout is easier to interpret.
    $probeNote = ''
    if ($diag.Tested -and -not $diag.Reachable) {
        $probeNote = ' (note: relay did not answer the pre-send reachability probe)'
    }

    # -- Build HTML body ----------------------------------------------------
    # v1.6.0: plain layout - no banner, no shaded detail table, no boxes.
    # One white page in the mail client's normal text style:
    #   [IntroHtml]      formatted welcome block (new-account emails)
    #   Label: value     one plain line per detail row
    #   BodyText         the admin-editable message, line breaks kept
    #   [AppendHtml]     formatted Additional Info blocks
    #   footer           "Automated message. Do not reply."
    # IntroHtml and AppendHtml are both sanitized here, whatever the caller
    # did; the pictures they reference are collected for embedding below.
    $usedImages = [System.Collections.Generic.List[string]]::new()
    $renderRich = {
        param([string]$Rich)
        if (-not $Rich -or -not $Rich.Trim()) { return '' }
        if (Get-Command ConvertTo-SafeMailHtml -ErrorAction SilentlyContinue) {
            $safe = ConvertTo-SafeMailHtml -Html $Rich
            # Keep only pictures we can actually attach; drop dangling refs.
            foreach ($m in [regex]::Matches($safe, 'cid:([0-9a-f]{16})')) {
                $id = $m.Groups[1].Value
                if ($InlineImages -and $InlineImages.ContainsKey($id) -and -not $usedImages.Contains($id)) { $usedImages.Add($id) }
            }
            foreach ($m in [regex]::Matches($safe, '<img src="cid:([0-9a-f]{16})"[^>]*>')) {
                if (-not $usedImages.Contains($m.Groups[1].Value)) { $safe = $safe.Replace($m.Value, '') }
            }
            return $safe
        }
        $plain = ($Rich -replace '(?i)<br\s*/?>', "`n" -replace '(?i)</(p|div|li)>', "`n" -replace '<[^>]*>', '')
        return ((ConvertTo-MailAsciiHtml ([System.Net.WebUtility]::HtmlDecode($plain))) -replace "`r?`n", '<br>')
    }

    $BLOCK = '<div style="margin:0 0 14px 0;">'
    $html = New-Object System.Text.StringBuilder
    [void]$html.Append('<html><body style="margin:0;padding:12px;background:#ffffff;">')
    [void]$html.Append('<div style="font-family:Segoe UI,Arial,sans-serif;font-size:13px;color:#1a1a1a;line-height:1.5;max-width:640px;">')

    # Welcome / intro (formatted)
    $safeIntro = & $renderRich $IntroHtml
    if ($safeIntro) { [void]$html.Append($BLOCK + $safeIntro + '</div>') }

    # Detail rows as plain "Label: value" lines
    $rows = ConvertTo-MailDetailRows $Details
    if ($rows.Count -gt 0) {
        $lines = [System.Collections.Generic.List[string]]::new()
        foreach ($r in $rows) {
            $lines.Add((ConvertTo-MailAsciiHtml $r.Label) + ': ' + (ConvertTo-MailAsciiHtml $r.Value))
        }
        [void]$html.Append($BLOCK + ($lines -join '<br>') + '</div>')
    }

    # Free-text message
    $bodyEsc = ConvertTo-MailAsciiHtml $BodyText
    $bodyEsc = $bodyEsc -replace "`r`n", '<br>' -replace "`n", '<br>' -replace "`r", '<br>'
    # Bold-heading marker [[B]]...[[/B]] (pre-v1.5.0 Additional Info
    # convention, no longer produced by Services.Mail.Dialog but still
    # honoured): the text inside is already escaped, only <b></b> is added.
    $bodyEsc = $bodyEsc -replace '\[\[B\]\](.*?)\[\[/B\]\]', '<b>$1</b>'
    if ($BodyText.Trim()) { [void]$html.Append($BLOCK + $bodyEsc + '</div>') }

    # Formatted Additional Info blocks
    $safeAppend = & $renderRich $AppendHtml
    if ($safeAppend) { [void]$html.Append($BLOCK + $safeAppend + '</div>') }

    # Footer
    [void]$html.Append('<div style="font-size:11px;color:#8a8a8a;">Automated message. Do not reply.</div>')
    [void]$html.Append('</div></body></html>')

    # -- Send ---------------------------------------------------------------
    $smtp = $null
    $msg  = $null
    try {
        $smtp = New-Object System.Net.Mail.SmtpClient($server, $port)
        $smtp.Timeout   = 10000
        $smtp.EnableSsl = $false
        $smtp.DeliveryMethod = [System.Net.Mail.SmtpDeliveryMethod]::Network

        $msg = New-Object System.Net.Mail.MailMessage
        $msg.From = New-Object System.Net.Mail.MailAddress($from)
        $msg.To.Add($To)

        $ccAdded = 0
        foreach ($c in $Cc) {
            if ($c -and $c.Trim()) {
                try { $msg.CC.Add($c.Trim()); $ccAdded++ } catch { }
            }
        }

        $msg.Subject    = $Subject
        if ($usedImages.Count -gt 0 -and (Get-Command New-MailLinkedResource -ErrorAction SilentlyContinue)) {
            # HTML view with its pictures as related inline parts.
            $view = [System.Net.Mail.AlternateView]::CreateAlternateViewFromString(
                        $html.ToString(), [System.Text.Encoding]::UTF8, 'text/html')
            foreach ($id in $usedImages) {
                $img = $InlineImages[$id]
                $lr  = New-MailLinkedResource -Id $id -Type ([string]$img.Type) -Data ([string]$img.Data)
                if ($lr) { $view.LinkedResources.Add($lr) }
            }
            $msg.AlternateViews.Add($view)
        } else {
            $msg.IsBodyHtml = $true
            $msg.Body       = $html.ToString()
        }

        $smtp.Send($msg)

        $ccNote = if ($ccAdded -gt 0) { "CC=$ccAdded" } else { 'CC=none' }
        if (Get-Command Write-OperationLog -ErrorAction SilentlyContinue) {
            Write-OperationLog -Context $Context -Action 'MAIL-NOTIFY' -Target $To -Result 'OK' `
                -Detail ("Subject='" + $Subject + "' " + $ccNote)
        }
        return [PSCustomObject]@{
            Success    = $true
            Message    = ("Notification sent to " + $To + ".")
            Diagnostic = ''
        }
    }
    catch {
        $err = $_.Exception.Message
        if (Get-Command Write-OperationLog -ErrorAction SilentlyContinue) {
            Write-OperationLog -Context $Context -Action 'MAIL-NOTIFY' -Target $To -Result 'FAIL' -Detail $err
        }
        return [PSCustomObject]@{
            Success    = $false
            Message    = ("Send failed: " + $err + $probeNote)
            Diagnostic = $diag.Report
        }
    }
    finally {
        if ($msg)  { try { $msg.Dispose() }  catch { } }
        if ($smtp) { try { $smtp.Dispose() } catch { } }
    }
}
#endregion

#region -- ConvertTo-MailDetailRows -------------------------------------------
function ConvertTo-MailDetailRows {
    <#
    .SYNOPSIS
        Normalizes a hashtable / ordered dictionary of detail pairs into an
        ordered list of [Label,Value] rows. Preserves insertion order for
        ordered dictionaries; blank values are kept as '-'.
    #>
    param($Details)

    $rows = [System.Collections.Generic.List[PSCustomObject]]::new()
    if (-not $Details) { return $rows }

    if ($Details -is [System.Collections.Specialized.OrderedDictionary]) {
        foreach ($key in $Details.Keys) {
            $val = [string]$Details[$key]
            if (-not $val) { $val = '-' }
            $rows.Add([PSCustomObject]@{ Label=[string]$key; Value=$val })
        }
    }
    elseif ($Details -is [System.Collections.IDictionary]) {
        foreach ($key in $Details.Keys) {
            $val = [string]$Details[$key]
            if (-not $val) { $val = '-' }
            $rows.Add([PSCustomObject]@{ Label=[string]$key; Value=$val })
        }
    }
    return $rows
}
#endregion

#region -- ConvertTo-MailRecoveryBlock -----------------------------------------
function ConvertTo-MailRecoveryBlock {
    <#
    .SYNOPSIS
        Builds a plain-text "recovery detail" block for one or more AD items
        that were removed, disabled, or deleted, for appending into
        Send-ADNotificationMail's BodyText. One paragraph per item:
            AD Item <n>: <Label>
            OU: <OU path>
            <ListLabel> (<count>):
            - <item1>
            - <item2>
        with a blank line between items. Every list entry gets its own
        dash-prefixed line rather than being joined into a single comma or
        semicolon-separated string - deliberately flat (no nested/indented
        sub-bullets) because HTML collapses runs of LEADING whitespace,
        which would silently misrender an indented sub-list in a real mail
        client; a single leading dash has no such whitespace and survives
        intact. This needs no change to Send-ADNotificationMail's HTML body
        builder - it is plain text that flows through the existing
        BodyText -> <br> conversion.
    .PARAMETER Items
        Array of PSCustomObject, each with:
            Label     [string]   - e.g. 'jdoe (John Doe)', a group name, or a
                                    computer name.
            OU        [string]   - friendly OU path (Get-OUFromDN output).
                                    Blank/omitted renders as 'Unknown'.
            ListLabel [string]   - optional, e.g. 'Groups' or 'Members'. Omit
                                    or leave blank to skip the list line
                                    entirely (e.g. for a deleted computer).
            List      [string[]] - optional, the group or member names for
                                    ListLabel. An empty/omitted list with a
                                    ListLabel present renders 'None'.
    .PARAMETER Heading
        Optional single line placed once above every item, e.g.
        'Recovery details (for reference only):'.
    .OUTPUTS
        [string] Ready to append into BodyText, e.g.:
            $bodyText += "`r`n`r`n" + (ConvertTo-MailRecoveryBlock -Items $items)
    #>
    param(
        [PSCustomObject[]]$Items,
        [string]$Heading = ''
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    if (-not $Items -or @($Items).Count -eq 0) { return '' }

    if ($Heading) {
        [void]$lines.Add($Heading)
        [void]$lines.Add('')
    }

    $idx = 0
    foreach ($item in @($Items)) {
        $idx++
        $label = if ($item.PSObject.Properties.Name -contains 'Label' -and $item.Label) { [string]$item.Label } else { '(unknown)' }
        [void]$lines.Add("AD Item ${idx}: $label")

        $ouVal = if ($item.PSObject.Properties.Name -contains 'OU' -and $item.OU) { [string]$item.OU } else { 'Unknown' }
        [void]$lines.Add("OU: $ouVal")

        $hasListLabel = ($item.PSObject.Properties.Name -contains 'ListLabel') -and $item.ListLabel
        if ($hasListLabel) {
            $listArr = if ($item.PSObject.Properties.Name -contains 'List' -and $item.List) { @($item.List) } else { @() }
            [void]$lines.Add("$($item.ListLabel) ($($listArr.Count)):")
            if ($listArr.Count -gt 0) {
                foreach ($entry in $listArr) { [void]$lines.Add("- $entry") }
            } else {
                [void]$lines.Add('None')
            }
        }

        [void]$lines.Add('')
    }

    # Drop the single trailing blank line so callers can append more text
    # (or nothing) after this block without a double gap.
    if ($lines.Count -gt 0 -and -not $lines[$lines.Count - 1]) {
        $lines.RemoveAt($lines.Count - 1)
    }

    return ($lines -join "`r`n")
}
#endregion

#region -- ConvertTo-MailAsciiHtml --------------------------------------------
function ConvertTo-MailAsciiHtml {
    <#
    .SYNOPSIS
        HTML-escapes a string and strips it to printable ASCII. Non-ASCII
        characters are replaced with '?'. Avoids a System.Web dependency by
        escaping the five significant characters manually (& first).
    #>
    param([string]$Text)

    if (-not $Text) { return '' }

    # Strip to printable ASCII (0x20-0x7E), tab, CR, LF preserved.
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $Text.ToCharArray()) {
        $code = [int][char]$ch
        if ($code -eq 9 -or $code -eq 10 -or $code -eq 13 -or ($code -ge 32 -and $code -le 126)) {
            [void]$sb.Append($ch)
        } else {
            [void]$sb.Append('?')
        }
    }
    $s = $sb.ToString()

    $s = $s -replace '&', '&amp;'
    $s = $s -replace '<', '&lt;'
    $s = $s -replace '>', '&gt;'
    $s = $s -replace '"', '&quot;'
    $s = $s -replace "'", '&#39;'
    return $s
}
#endregion

Export-ModuleMember -Function Send-ADNotificationMail, Test-MailContext, ConvertTo-MailDetailRows, ConvertTo-MailRecoveryBlock, ConvertTo-MailAsciiHtml
