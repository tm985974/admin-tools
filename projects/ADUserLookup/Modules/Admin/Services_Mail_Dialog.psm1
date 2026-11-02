#region -- Services.Mail.Dialog.psm1 -----------------------------------------
# Concern : Show-NotificationMailDialog - fixed-size WinForms popup that
#           presents a pre-populated, fully editable email notification for
#           a completed AD account action and sends it on confirmation.
#
#           Callers pass a MailParams hashtable assembled at the action site
#           (create, reset, unlock, group add). The dialog pre-fills all
#           fields. The admin may edit To, CC, Subject, and body text before
#           sending. Send is always non-fatal; the AD action is already
#           committed before this dialog opens.
#
#           Admin CC resolution:
#           AdminAccount on Context is DOMAIN\sam. At open time the function
#           resolves the admin's mail attribute from AD and caches it on
#           Context.AdminMail so subsequent popups skip the lookup. If the
#           AD attribute is missing the CC field is left blank for manual
#           entry.
#
#           Recipient (To) resolution:
#           Callers supply Sam. The dialog resolves the affected user's AD
#           mail attribute. If the attribute is missing, Show-
#           RecipientEmailPrompt (below, private to this module) opens a
#           small fixed-size prompt asking the admin for an address before
#           the notification dialog itself is built. A supplied address is
#           written back to the user's AD mail attribute (Set-ADUser, best-
#           effort - a failed write is silently ignored so this one send
#           still goes out with the typed address) so future notifications
#           for this user resolve automatically without prompting again. If
#           the admin skips the prompt, To is left blank exactly as before
#           this feature - editable, admin must supply an address to send.
#
#           AdminOnly mode (-AdminOnly switch):
#           For documentation / tracking notifications the popup is addressed
#           to the admin (current user) only, with no CC. In this mode the To
#           field is pre-filled with the resolved admin mail and the CC field
#           is left blank; the affected-user lookup is skipped. Every field is
#           still editable and the send path is identical.
#
#           Runtime diagnostics:
#           On any config failure Send-ADNotificationMail returns a full
#           field-by-field Test-MailContext report (which mail field is
#           missing vs blank, what the others hold, relay reachability). The
#           status area is a read-only multiline box that expands inline to
#           show that dump, so an empty SmtpServer at runtime is diagnosable
#           without a console.
#
#           Window lifecycle:
#           All three actions close the dialog - Send (on a SUCCESSFUL send
#           only), Skip, and Close. A failed send leaves the dialog open
#           (Send re-enabled, status shows the error/diagnostic) so the
#           admin can correct something and retry rather than losing the
#           already-composed message. There is no state where the dialog is
#           left open after a completed, successful action with nothing
#           further for the admin to do.
#
# Load order: 4c - depends on Services.Mail.Send (Send-ADNotificationMail).
#             Must load after 4b. Soft dependency on Services.DomainDefaults.
#             Config (Get-DomainDefaults) for the Additional Info checkboxes
#             below - if that module isn't loaded, the four checkboxes are
#             still shown but simply have nothing to append (never an error).
#             No other AD-Admin dependencies.
#
#           Additional Info checkboxes:
#           Four checkboxes let the admin optionally append the connected
#           domain's four AdditionalInfo snippets (configured on the Domain
#           Defaults tab - Services.DomainDefaults.Config) onto the message
#           body before sending. Each checkbox's own TEXT is the domain's
#           AdditionalInfo{N}Label if one is set (e.g. "Support Contact"),
#           falling back to the generic "Additional Info N" when that slot
#           has no configured title - so the admin picks by meaning once a
#           domain has titled its slots. Looked up ONCE at dialog-open time
#           via Get-DomainDefaults -Domain $Context.Domain (same read
#           pattern used throughout the app), so this works for every
#           caller unchanged - none of the ~12 action modules that call
#           Show-NotificationMailDialog need to pass anything new. Info 1
#           defaults to checked; Info 2-4 default to unchecked. A checkbox
#           whose corresponding domain field is blank is left enabled (not
#           disabled) but simply appends nothing if checked - checking it is
#           harmless, not an error. When a slot has a title, the appended
#           block is that title wrapped as a bold heading (via a plain-
#           ASCII [[B]]...[[/B]] marker only Services.Mail.Send's renderer
#           understands - see that module's header) on its own line above
#           the content; with no title, only the content is appended,
#           unchanged from before this feature. Checked blocks are appended
#           to the editable Message box's CURRENT text at Send time, each
#           as its own paragraph, so any edits the admin already made to
#           the body are preserved and the appended blocks are the last
#           thing added before the mail is composed.
#
#           v1.5.0 - formatted Additional Info: checked blocks are no longer
#           appended to the plain-text Message. Each checked slot becomes an
#           HTML block (bold Title heading + the slot's formatted
#           AdditionalInfo{N}Html, or its plain AdditionalInfo{N} text for
#           snippets saved before v1.5.0) passed to Send-ADNotificationMail
#           as -AppendHtml, with the domain's AdditionalInfoImages as
#           -InlineImages. Services.Mail.Send sanitizes the HTML and embeds
#           the referenced pictures, so links stay clickable and pictures
#           display in the sent email. The admin's own Message text is sent
#           exactly as typed, above the blocks. Soft dependencies (captured
#           below): ConvertTo-MailHtmlFromText (Services.Mail.RichHtml) and
#           ConvertTo-MailImageTable (Services.Mail.Images); without them
#           plain-text snippets are still sent, escaped, and pictures are
#           skipped. The [[B]] marker is no longer produced here.
#
#           v1.6.0 - two new switches. -NoCc leaves CC blank (individual
#           sends from Services.Mail.Batch - the admin gets a separate
#           summary). -Welcome (new-account emails) adds an "Include
#           welcome message" checkbox, checked, beside the Message label;
#           when checked the email starts with "Welcome <first name>!"
#           followed by the domain's NewAccountWelcomeHtml (placeholders
#           {FirstName} {DisplayName} {Username} filled in), passed to
#           Send-ADNotificationMail as -IntroHtml. First and display name
#           come from the same Get-ADUser lookup that resolves To. Single-
#           person sends without -NoCc (Unlock, Add to Groups from the
#           Users list) still CC the admin, as before.
#
# WinForms standard:
#   Fixed size. Segoe UI. Explicit positioning. No Dock. No Anchor.
#   No TableLayoutPanel. No GroupBox.
#endregion

#region -- Show-RecipientEmailPrompt (private) ---------------------------------
function Show-RecipientEmailPrompt {
    <#
    .SYNOPSIS
        Small fixed-size modal shown by Show-NotificationMailDialog when a
        recipient has no AD mail attribute on file. Not exported - internal
        helper for this module only.
    .PARAMETER Sam
        SamAccountName of the recipient with no mail attribute, shown in the
        prompt so the admin knows who they're entering an address for.
    .OUTPUTS
        [string] The trimmed address the admin typed and clicked OK on, or
        '' if they clicked Skip / closed the window without typing one.
    #>
    param([string]$Sam)

    $F_UI    = New-Object System.Drawing.Font('Segoe UI', 9)
    $F_UI_B  = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $F_HINT  = New-Object System.Drawing.Font('Segoe UI', 8)
    $C_BG    = [System.Drawing.Color]::FromArgb(235, 238, 242)
    $C_LABEL = [System.Drawing.Color]::FromArgb(0, 60, 130)

    $p                 = New-Object System.Windows.Forms.Form
    $p.Text            = 'Email Address Required'
    $p.ClientSize      = New-Object System.Drawing.Size(380, 168)
    $p.FormBorderStyle = 'FixedDialog'
    $p.MaximizeBox     = $false
    $p.MinimizeBox     = $false
    $p.StartPosition   = 'CenterParent'
    $p.BackColor       = $C_BG

    $lMsg              = New-Object System.Windows.Forms.Label
    $lMsg.Text         = "No email address is on file for '$Sam'.`r`nEnter one to use for this notification:"
    $lMsg.Location     = New-Object System.Drawing.Point(16, 16)
    $lMsg.Size         = New-Object System.Drawing.Size(348, 40)
    $lMsg.Font         = $F_UI
    $lMsg.ForeColor    = $C_LABEL
    $p.Controls.Add($lMsg)

    $tb                = New-Object System.Windows.Forms.TextBox
    $tb.Location       = New-Object System.Drawing.Point(16, 62)
    $tb.Size           = New-Object System.Drawing.Size(348, 24)
    $tb.Font           = $F_UI
    $p.Controls.Add($tb)

    $lHint             = New-Object System.Windows.Forms.Label
    $lHint.Text        = 'Saved to this account (mail attribute) for future notifications.'
    $lHint.Location    = New-Object System.Drawing.Point(16, 92)
    $lHint.Size        = New-Object System.Drawing.Size(348, 16)
    $lHint.Font        = $F_HINT
    $lHint.ForeColor   = [System.Drawing.Color]::DimGray
    $p.Controls.Add($lHint)

    $btnOK             = New-Object System.Windows.Forms.Button
    $btnOK.Text        = 'OK'
    $btnOK.FlatStyle   = 'Standard'
    $btnOK.Location    = New-Object System.Drawing.Point(196, 124)
    $btnOK.Size        = New-Object System.Drawing.Size(80, 30)
    $btnOK.Font        = $F_UI_B
    $btnOK.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $p.Controls.Add($btnOK)
    $p.AcceptButton    = $btnOK

    $btnSkip           = New-Object System.Windows.Forms.Button
    $btnSkip.Text      = 'Skip'
    $btnSkip.FlatStyle = 'Standard'
    $btnSkip.Location  = New-Object System.Drawing.Point(284, 124)
    $btnSkip.Size      = New-Object System.Drawing.Size(80, 30)
    $btnSkip.Font      = $F_UI
    $btnSkip.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $p.Controls.Add($btnSkip)
    $p.CancelButton    = $btnSkip

    [void]$tb.Focus()
    $dr = $p.ShowDialog()

    if ($dr -eq [System.Windows.Forms.DialogResult]::OK) {
        return $tb.Text.Trim()
    }
    return ''
}
#endregion

#region -- Show-NotificationMailDialog ----------------------------------------
function Show-NotificationMailDialog {
    <#
    .SYNOPSIS
        Opens a fixed-size mail notification popup pre-populated with account
        action details. Admin may edit fields and send, or close to skip.
    .PARAMETER Context
        Shared context object (SmtpServer, MailFrom, AdminAccount, AdminMail).
    .PARAMETER Sam
        SamAccountName of the affected user. Used to resolve the AD mail
        attribute for the To field. Ignored when -AdminOnly is set.
    .PARAMETER ActionTitle
        Short banner subtitle, e.g. 'Account Created'.
    .PARAMETER Subject
        Pre-populated subject line. Editable.
    .PARAMETER Details
        Ordered dictionary of label -> value pairs for the detail table.
    .PARAMETER BodyText
        Pre-populated body text. Editable by the admin before sending.
    .PARAMETER NoCc
        Do not CC the admin (v1.6.0). Services.Mail.Batch passes it for
        every individual recipient - the admin gets their own separate
        summary copy, without the sensitive details, instead.
    .PARAMETER Welcome
        New-account email (v1.6.0): adds "Welcome <first name>!" plus the
        domain's NewAccountWelcome message at the top, with an "Include
        welcome message" checkbox (checked) on the window.
    .PARAMETER AdminOnly
        Tracking/documentation mode: address the popup To the admin (current
        user) with no CC. Skips the affected-user To lookup and leaves CC
        blank. All fields remain editable.
    #>
    param(
        [PSCustomObject]$Context,
        [string]$Sam,
        [string]$ActionTitle  = 'Account Action',
        [string]$Subject      = 'AD Account Notification',
        $Details              = $null,
        [string]$BodyText     = '',
        [switch]$AdminOnly,
        [switch]$NoCc,
        [switch]$Welcome
    )

    # -- Resolve admin mail (CC in normal mode, To in AdminOnly mode) -------
    $adminMail = ''
    if ($Context -and $Context.PSObject.Properties.Name -contains 'AdminMail' -and $Context.AdminMail) {
        $adminMail = $Context.AdminMail
    } else {
        # Extract SAM from DOMAIN\sam or just use as-is for local accounts
        $adminSam = if ($Context -and $Context.AdminAccount) {
            ($Context.AdminAccount -split '\\')[-1]
        } else { '' }
        if ($adminSam) {
            try {
                $srvP   = if ($Context -and $Context.TargetDC) { @{ Server = $Context.TargetDC } } else { @{} }
                $adAdmin = Get-ADUser -Identity $adminSam -Properties mail @srvP -ErrorAction Stop
                if ($adAdmin.mail) {
                    $adminMail = $adAdmin.mail.Trim()
                    if ($Context -and $Context.PSObject.Properties.Name -contains 'AdminMail') {
                        $Context.AdminMail = $adminMail
                    }
                }
            } catch { }
        }
    }

    # -- Resolve To ---------------------------------------------------------
    # AdminOnly mode (tracking/documentation): To is the admin, no affected-
    # user lookup. Normal mode: To is the affected user's mail attribute -
    # if that attribute is blank, Show-RecipientEmailPrompt asks the admin
    # for one (and writes it back to AD) before the notification dialog
    # itself opens. See module header for the full explanation.
    $toAddress    = ''
    $recipFirst   = ''     # welcome-message placeholders (v1.6.0)
    $recipDisplay = ''
    if ($AdminOnly) {
        $toAddress = $adminMail
    } elseif ($Sam) {
        $srvParam  = if ($Context -and $Context.TargetDC) { @{ Server = $Context.TargetDC } } else { @{} }
        $adUserMail = ''
        try {
            $adUser = Get-ADUser -Identity $Sam -Properties mail, givenName, displayName @srvParam -ErrorAction Stop
            if ($adUser.mail) { $adUserMail = $adUser.mail.Trim() }
            if ($adUser.GivenName)   { $recipFirst   = ([string]$adUser.GivenName).Trim() }
            if ($adUser.DisplayName) { $recipDisplay = ([string]$adUser.DisplayName).Trim() }
        } catch { }

        if ($adUserMail) {
            $toAddress = $adUserMail
        } else {
            $entered = Show-RecipientEmailPrompt -Sam $Sam
            if ($entered) {
                $toAddress = $entered
                try {
                    Set-ADUser -Identity $Sam -EmailAddress $entered @srvParam -ErrorAction Stop
                } catch { }
            }
        }
    }

    # -- Resolve CC ---------------------------------------------------------
    # AdminOnly mode: no CC. Normal mode: CC the admin.
    $ccAddress = if ($AdminOnly -or $NoCc) { '' } else { $adminMail }

    # -- Resolve Additional Info values for the connected domain ------------
    # Looked up once, here, outside any closure - bare-name calls work fine
    # in this function's main body (see the Get-ADUser calls above); the
    # documented GetNewClosure bare-name bug only affects code INSIDE a
    # .GetNewClosure() block, which this lookup is not. Soft dependency: if
    # Services.DomainDefaults.Config isn't loaded, or Context has no Domain
    # yet, $dd stays $null and the four checkboxes simply have nothing to
    # append (never an error - see module header).
    $dd = $null
    if ($Context -and $Context.Domain -and (Get-Command Get-DomainDefaults -ErrorAction SilentlyContinue)) {
        try { $dd = Get-DomainDefaults -Domain $Context.Domain } catch { $dd = $null }
    }

    # -- Build detail table text for read-only preview ----------------------
    $detailLines = [System.Collections.Generic.List[string]]::new()
    if ($Details -is [System.Collections.Specialized.OrderedDictionary] -or
        $Details -is [System.Collections.IDictionary]) {
        foreach ($key in $Details.Keys) {
            $val = [string]$Details[$key]
            if (-not $val) { $val = '-' }
            $detailLines.Add(($key.PadRight(18) + ': ' + $val))
        }
    }
    $detailPreview = $detailLines -join "`r`n"

    # -----------------------------------------------------------------------
    # Fonts
    # -----------------------------------------------------------------------
    $F_UI    = New-Object System.Drawing.Font('Segoe UI',  9)
    $F_UI_B  = New-Object System.Drawing.Font('Segoe UI',  9, [System.Drawing.FontStyle]::Bold)
    $F_13B   = New-Object System.Drawing.Font('Segoe UI', 13, [System.Drawing.FontStyle]::Bold)
    $F_MONO  = New-Object System.Drawing.Font('Consolas',  9)

    # -----------------------------------------------------------------------
    # Colors
    # -----------------------------------------------------------------------
    $C_BANNER   = [System.Drawing.Color]::FromArgb(0,   99,  177)
    $C_BG       = [System.Drawing.Color]::FromArgb(235, 238, 242)
    $C_LABEL    = [System.Drawing.Color]::FromArgb(0,   60,  130)
    $C_OK       = [System.Drawing.Color]::FromArgb(0,   97,    0)
    $C_ERR      = [System.Drawing.Color]::FromArgb(156,   0,    6)
    $C_GRAY     = [System.Drawing.Color]::DimGray
    $C_DIAG_BG  = [System.Drawing.Color]::FromArgb(252, 246, 246)
    $C_STAT_BG  = [System.Drawing.Color]::FromArgb(245, 247, 252)

    # -----------------------------------------------------------------------
    # Form  580 x 768  (grown from 580 x 710 to fit the Additional Info
    # checkbox rows added below the Message box - see module header)
    # -----------------------------------------------------------------------
    $dlg                  = New-Object System.Windows.Forms.Form
    $dlg.Text             = "Send Notification  -  $ActionTitle"
    $dlg.ClientSize       = New-Object System.Drawing.Size(580, 768)
    $dlg.FormBorderStyle  = 'FixedSingle'
    $dlg.MaximizeBox      = $false
    $dlg.MinimizeBox      = $false
    $dlg.StartPosition    = 'CenterParent'
    $dlg.BackColor        = $C_BG
    $dlg.Font             = $F_UI

    # -----------------------------------------------------------------------
    # Banner panel  (0,0) 580 x 48
    # -----------------------------------------------------------------------
    $pBanner              = New-Object System.Windows.Forms.Panel
    $pBanner.Location     = New-Object System.Drawing.Point(0, 0)
    $pBanner.Size         = New-Object System.Drawing.Size(580, 48)
    $pBanner.BackColor    = $C_BANNER
    $dlg.Controls.Add($pBanner)

    $lBanner              = New-Object System.Windows.Forms.Label
    $lBanner.Text         = 'Send Notification Email'
    $lBanner.Location     = New-Object System.Drawing.Point(12, 0)
    $lBanner.Size         = New-Object System.Drawing.Size(420, 48)
    $lBanner.Font         = $F_13B
    $lBanner.ForeColor    = [System.Drawing.Color]::White
    $lBanner.TextAlign    = 'MiddleLeft'
    $pBanner.Controls.Add($lBanner)

    $lAction              = New-Object System.Windows.Forms.Label
    $lAction.Text         = $ActionTitle
    $lAction.Location     = New-Object System.Drawing.Point(432, 0)
    $lAction.Size         = New-Object System.Drawing.Size(136, 48)
    $lAction.Font         = $F_UI_B
    $lAction.ForeColor    = [System.Drawing.Color]::FromArgb(180, 210, 255)
    $lAction.TextAlign    = 'MiddleRight'
    $pBanner.Controls.Add($lAction)

    # -----------------------------------------------------------------------
    # To row  y=64
    # -----------------------------------------------------------------------
    $lTo              = New-Object System.Windows.Forms.Label
    $lTo.Text         = 'To:'
    $lTo.Location     = New-Object System.Drawing.Point(16, 64)
    $lTo.Size         = New-Object System.Drawing.Size(46, 20)
    $lTo.Font         = $F_UI_B
    $lTo.ForeColor    = $C_LABEL
    $lTo.TextAlign    = 'MiddleRight'
    $dlg.Controls.Add($lTo)

    $tbTo             = New-Object System.Windows.Forms.TextBox
    $tbTo.Location    = New-Object System.Drawing.Point(68, 64)
    $tbTo.Size        = New-Object System.Drawing.Size(494, 22)
    $tbTo.Font        = $F_UI
    $tbTo.Text        = $toAddress
    $dlg.Controls.Add($tbTo)

    # -----------------------------------------------------------------------
    # CC row  y=94
    # -----------------------------------------------------------------------
    $lCc              = New-Object System.Windows.Forms.Label
    $lCc.Text         = 'CC:'
    $lCc.Location     = New-Object System.Drawing.Point(16, 94)
    $lCc.Size         = New-Object System.Drawing.Size(46, 20)
    $lCc.Font         = $F_UI_B
    $lCc.ForeColor    = $C_LABEL
    $lCc.TextAlign    = 'MiddleRight'
    $dlg.Controls.Add($lCc)

    $tbCc             = New-Object System.Windows.Forms.TextBox
    $tbCc.Location    = New-Object System.Drawing.Point(68, 94)
    $tbCc.Size        = New-Object System.Drawing.Size(494, 22)
    $tbCc.Font        = $F_UI
    $tbCc.Text        = $ccAddress
    $dlg.Controls.Add($tbCc)

    # -----------------------------------------------------------------------
    # Subject row  y=124
    # -----------------------------------------------------------------------
    $lSub             = New-Object System.Windows.Forms.Label
    $lSub.Text        = 'Subject:'
    $lSub.Location    = New-Object System.Drawing.Point(16, 124)
    $lSub.Size        = New-Object System.Drawing.Size(46, 20)
    $lSub.Font        = $F_UI_B
    $lSub.ForeColor   = $C_LABEL
    $lSub.TextAlign   = 'MiddleRight'
    $dlg.Controls.Add($lSub)

    $tbSubject        = New-Object System.Windows.Forms.TextBox
    $tbSubject.Location = New-Object System.Drawing.Point(68, 124)
    $tbSubject.Size   = New-Object System.Drawing.Size(494, 22)
    $tbSubject.Font   = $F_UI
    $tbSubject.Text   = $Subject
    $dlg.Controls.Add($tbSubject)

    # -----------------------------------------------------------------------
    # Detail preview (read-only)  y=158  h=110
    # -----------------------------------------------------------------------
    $lDetail          = New-Object System.Windows.Forms.Label
    $lDetail.Text     = 'Action Details (read only):'
    $lDetail.Location = New-Object System.Drawing.Point(16, 158)
    $lDetail.Size     = New-Object System.Drawing.Size(546, 18)
    $lDetail.Font     = $F_UI_B
    $lDetail.ForeColor = $C_LABEL
    $dlg.Controls.Add($lDetail)

    $tbDetail         = New-Object System.Windows.Forms.TextBox
    $tbDetail.Location = New-Object System.Drawing.Point(16, 178)
    $tbDetail.Size    = New-Object System.Drawing.Size(546, 220)
    $tbDetail.Font    = $F_MONO
    $tbDetail.Multiline = $true
    $tbDetail.ScrollBars = 'Vertical'
    $tbDetail.ReadOnly = $true
    $tbDetail.BackColor = $C_STAT_BG
    $tbDetail.Text    = $detailPreview
    $dlg.Controls.Add($tbDetail)

    # -----------------------------------------------------------------------
    # Body message (editable)  y=302  h=180  (ends y=502)
    # -----------------------------------------------------------------------
    $lBody            = New-Object System.Windows.Forms.Label
    $lBody.Text       = 'Message (editable):'
    $lBody.Location   = New-Object System.Drawing.Point(16, 412)
    $lBody.Size       = New-Object System.Drawing.Size(270, 18)
    $lBody.Font       = $F_UI_B
    $lBody.ForeColor  = $C_LABEL
    $dlg.Controls.Add($lBody)

    $tbBody           = New-Object System.Windows.Forms.TextBox
    $tbBody.Location  = New-Object System.Drawing.Point(16, 432)
    $tbBody.Size      = New-Object System.Drawing.Size(546, 180)
    $tbBody.Font      = $F_UI
    $tbBody.Multiline = $true
    $tbBody.ScrollBars = 'Vertical'
    $tbBody.AcceptsReturn = $true
    $tbBody.Text      = $BodyText
    $dlg.Controls.Add($tbBody)

    # Welcome checkbox (v1.6.0) - new-account emails only, on the Message
    # label's row so the rest of the layout is unchanged.
    $chkWelcome          = New-Object System.Windows.Forms.CheckBox
    $chkWelcome.Text     = 'Include welcome message'
    $chkWelcome.Location = New-Object System.Drawing.Point(296, 410)
    $chkWelcome.Size     = New-Object System.Drawing.Size(266, 22)
    $chkWelcome.Font     = $F_UI
    $chkWelcome.Checked  = $true
    $chkWelcome.Visible  = [bool]$Welcome
    $dlg.Controls.Add($chkWelcome)

    # -----------------------------------------------------------------------
    # Additional Info checkboxes  y=616-662 (2x2 grid)
    # Optional blocks, sourced from the connected domain's Domain Defaults
    # (AdditionalInfo1-4, resolved into $dd above). Info 1 defaults checked;
    # Info 2-4 default unchecked. Left enabled even when $dd is $null or a
    # given slot is blank for this domain - checking an empty one is
    # harmless (the Send handler below just appends nothing for it).
    # -----------------------------------------------------------------------
    $INFO_CHK_Y1 = 616
    $INFO_CHK_Y2 = 640
    $INFO_CHK_X1 = 16
    $INFO_CHK_X2 = 296
    $INFO_CHK_W  = 260

    $chkInfo1          = New-Object System.Windows.Forms.CheckBox
    $chkInfo1.Text     = if ($dd -and $dd.AdditionalInfo1Label -and ([string]$dd.AdditionalInfo1Label).Trim()) { ([string]$dd.AdditionalInfo1Label).Trim() } else { 'Additional Info 1' }
    $chkInfo1.Location = New-Object System.Drawing.Point($INFO_CHK_X1, $INFO_CHK_Y1)
    $chkInfo1.Size     = New-Object System.Drawing.Size($INFO_CHK_W, 22)
    $chkInfo1.Font     = $F_UI
    $chkInfo1.Checked  = $true
    $dlg.Controls.Add($chkInfo1)

    $chkInfo2          = New-Object System.Windows.Forms.CheckBox
    $chkInfo2.Text     = if ($dd -and $dd.AdditionalInfo2Label -and ([string]$dd.AdditionalInfo2Label).Trim()) { ([string]$dd.AdditionalInfo2Label).Trim() } else { 'Additional Info 2' }
    $chkInfo2.Location = New-Object System.Drawing.Point($INFO_CHK_X2, $INFO_CHK_Y1)
    $chkInfo2.Size     = New-Object System.Drawing.Size($INFO_CHK_W, 22)
    $chkInfo2.Font     = $F_UI
    $chkInfo2.Checked  = $false
    $dlg.Controls.Add($chkInfo2)

    $chkInfo3          = New-Object System.Windows.Forms.CheckBox
    $chkInfo3.Text     = if ($dd -and $dd.AdditionalInfo3Label -and ([string]$dd.AdditionalInfo3Label).Trim()) { ([string]$dd.AdditionalInfo3Label).Trim() } else { 'Additional Info 3' }
    $chkInfo3.Location = New-Object System.Drawing.Point($INFO_CHK_X1, $INFO_CHK_Y2)
    $chkInfo3.Size     = New-Object System.Drawing.Size($INFO_CHK_W, 22)
    $chkInfo3.Font     = $F_UI
    $chkInfo3.Checked  = $false
    $dlg.Controls.Add($chkInfo3)

    $chkInfo4          = New-Object System.Windows.Forms.CheckBox
    $chkInfo4.Text     = if ($dd -and $dd.AdditionalInfo4Label -and ([string]$dd.AdditionalInfo4Label).Trim()) { ([string]$dd.AdditionalInfo4Label).Trim() } else { 'Additional Info 4' }
    $chkInfo4.Location = New-Object System.Drawing.Point($INFO_CHK_X2, $INFO_CHK_Y2)
    $chkInfo4.Size     = New-Object System.Drawing.Size($INFO_CHK_W, 22)
    $chkInfo4.Font     = $F_UI
    $chkInfo4.Checked  = $false
    $dlg.Controls.Add($chkInfo4)

    # -----------------------------------------------------------------------
    # Status area  y=670  (read-only, single line by default; expands to a
    # multiline diagnostic dump on config failure). Compact geometry is
    # (16,670) 546 x 44 sitting in the slack between the Additional Info
    # checkboxes (end 662) and the buttons (722). On a diagnostic failure
    # the box is grown upward to (16,178) 546 x 536 so the full
    # Test-MailContext report is readable inline, overlaying the
    # detail/body/checkbox region while it is shown - height is kept equal
    # to (small-mode Y + small-mode H) - big-mode Y, so big mode still
    # covers exactly from the Details box's top down to the small status
    # box's own bottom, same invariant as before the checkbox rows were
    # added.
    # -----------------------------------------------------------------------
    $STAT_X       = 16
    $STAT_W       = 546
    $STAT_Y_SMALL = 670
    $STAT_H_SMALL = 44
    $STAT_Y_BIG   = 178
    $STAT_H_BIG   = 536

    $tbStatus          = New-Object System.Windows.Forms.TextBox
    $tbStatus.Location = New-Object System.Drawing.Point($STAT_X, $STAT_Y_SMALL)
    $tbStatus.Size     = New-Object System.Drawing.Size($STAT_W, $STAT_H_SMALL)
    $tbStatus.Font     = $F_UI
    $tbStatus.Multiline = $true
    $tbStatus.ScrollBars = 'Vertical'
    $tbStatus.ReadOnly = $true
    $tbStatus.BorderStyle = 'None'
    $tbStatus.BackColor = $C_BG
    $tbStatus.ForeColor = $C_GRAY
    $tbStatus.Text     = 'Review and edit the fields above, then click Send.'
    $dlg.Controls.Add($tbStatus)

    # -----------------------------------------------------------------------
    # Buttons  y=722
    # -----------------------------------------------------------------------
    $btnSend          = New-Object System.Windows.Forms.Button
    $btnSend.Text     = 'Send'
    $btnSend.FlatStyle = 'Standard'
    $btnSend.Location = New-Object System.Drawing.Point(16, 722)
    $btnSend.Size     = New-Object System.Drawing.Size(100, 30)
    $btnSend.Font     = $F_UI_B
    $dlg.Controls.Add($btnSend)

    $btnSkip          = New-Object System.Windows.Forms.Button
    $btnSkip.Text     = 'Skip'
    $btnSkip.FlatStyle = 'Standard'
    $btnSkip.Location = New-Object System.Drawing.Point(126, 722)
    $btnSkip.Size     = New-Object System.Drawing.Size(80, 30)
    $btnSkip.Font     = $F_UI
    $dlg.Controls.Add($btnSkip)

    $btnClose         = New-Object System.Windows.Forms.Button
    $btnClose.Text    = 'Close'
    $btnClose.FlatStyle = 'Standard'
    $btnClose.Location = New-Object System.Drawing.Point(482, 722)
    $btnClose.Size    = New-Object System.Drawing.Size(80, 30)
    $btnClose.Font    = $F_UI
    $dlg.Controls.Add($btnClose)

    # -----------------------------------------------------------------------
    # Capture locals for closures
    # Send-ADNotificationMail lives in Services.Mail.Send (dot-sourced).
    # Bare-name calls from inside .GetNewClosure() blocks cannot resolve
    # dot-sourced functions - same bug class documented throughout this
    # codebase. Capture via ${function:} here, invoke with & inside.
    # -----------------------------------------------------------------------
    $capturedContext  = $Context
    $capturedDetails  = $Details
    $capturedTitle    = $ActionTitle
    $sendMailFn       = ${function:Send-ADNotificationMail}
    $escFn            = ${function:ConvertTo-MailAsciiHtml}
    if (-not $escFn) { $escFn = { param($t) [System.Net.WebUtility]::HtmlEncode([string]$t) } }
    $fromTextFn       = ${function:ConvertTo-MailHtmlFromText}
    $imgTableFn       = ${function:ConvertTo-MailImageTable}
    $capturedWelcome  = [bool]$Welcome
    $capturedFirst    = $recipFirst
    $capturedDisplay  = $recipDisplay
    $capturedSam      = $Sam

    # -----------------------------------------------------------------------
    # Status helpers captured for the closures. setStatusSmall restores the
    # compact single-line status; setStatusDiag grows the box to show the
    # full field-by-field diagnostic dump in monospace.
    # -----------------------------------------------------------------------
    $setStatusSmall = {
        param($msg, $color)
        $tbStatus.Font      = $F_UI
        $tbStatus.BackColor = $C_BG
        $tbStatus.ForeColor = $color
        $tbStatus.Location  = New-Object System.Drawing.Point($STAT_X, $STAT_Y_SMALL)
        $tbStatus.Size      = New-Object System.Drawing.Size($STAT_W, $STAT_H_SMALL)
        $tbStatus.Text      = [string]$msg
        $tbStatus.Select(0, 0)
        $tbStatus.BringToFront()
    }.GetNewClosure()

    $setStatusDiag = {
        param($msg)
        $tbStatus.Font      = $F_MONO
        $tbStatus.BackColor = $C_DIAG_BG
        $tbStatus.ForeColor = $C_ERR
        $tbStatus.Location  = New-Object System.Drawing.Point($STAT_X, $STAT_Y_BIG)
        $tbStatus.Size      = New-Object System.Drawing.Size($STAT_W, $STAT_H_BIG)
        $tbStatus.Text      = [string]$msg
        $tbStatus.Select(0, 0)
        $tbStatus.BringToFront()
    }.GetNewClosure()

    # -----------------------------------------------------------------------
    # Send handler
    # -----------------------------------------------------------------------
    $btnSend.Add_Click({
        $toVal      = $tbTo.Text.Trim()
        $ccVal      = $tbCc.Text.Trim()
        $subjectVal = $tbSubject.Text.Trim()
        $bodyVal    = $tbBody.Text

        # Build the formatted Additional Info blocks for whichever slots are
        # checked, in slot order (see module header, v1.5.0). $dd is the
        # connected domain's Domain Defaults (resolved once, above) -
        # $null-safe and blank-safe throughout, so an unconfigured slot or a
        # missing Domain Defaults module simply contributes nothing.
        $appendHtml   = ''
        $inlineImages = $null
        if ($dd) {
            $blocks = [System.Collections.Generic.List[string]]::new()
            foreach ($slot in @(
                @{ Chk = $chkInfo1; N = 1 },
                @{ Chk = $chkInfo2; N = 2 },
                @{ Chk = $chkInfo3; N = 3 },
                @{ Chk = $chkInfo4; N = 4 }
            )) {
                if (-not $slot.Chk.Checked) { continue }
                $n         = $slot.N
                $labelVal  = ([string]$dd."AdditionalInfo${n}Label").Trim()
                $htmlVal   = [string]$dd."AdditionalInfo${n}Html"
                $textVal   = ([string]$dd."AdditionalInfo$n").Trim()
                if (-not $htmlVal.Trim()) {
                    if (-not $textVal) { continue }
                    if ($fromTextFn) { $htmlVal = & $fromTextFn -Text $textVal }
                    else { $htmlVal = (& $escFn $textVal) -replace "`r?`n", '<br>' }
                }
                $block = '<div style="margin-top:12px;">'
                if ($labelVal) { $block += '<div style="font-weight:bold;">' + (& $escFn $labelVal) + '</div>' }
                $block += '<div>' + $htmlVal + '</div></div>'
                $blocks.Add($block)
            }
            if ($blocks.Count -gt 0) { $appendHtml = ($blocks -join '') }
        }

        # New-account welcome (v1.6.0): "Welcome <first name>!" then the
        # domain's formatted NewAccountWelcome message, with {FirstName},
        # {DisplayName} and {Username} filled in for this person.
        $introHtml = ''
        if ($capturedWelcome -and $chkWelcome.Checked) {
            $first = $capturedFirst
            if (-not $first -and $capturedDisplay) { $first = ($capturedDisplay -split '[ ,]')[0] }
            $greet = if ($first) { 'Welcome ' + $first + '!' } else { 'Welcome!' }
            $introHtml = '<p style="margin-top:0;margin-bottom:8px;"><b>' + (& $escFn $greet) + '</b></p>'
            if ($dd) {
                $wHtml = [string]$dd.NewAccountWelcomeHtml
                if (-not $wHtml.Trim()) {
                    $wText = ([string]$dd.NewAccountWelcome).Trim()
                    if ($wText) {
                        if ($fromTextFn) { $wHtml = & $fromTextFn -Text $wText }
                        else { $wHtml = (& $escFn $wText) -replace "`r?`n", '<br>' }
                    }
                }
                if ($wHtml.Trim()) {
                    foreach ($ph in @(
                        @{ Key = 'FirstName';   Val = $capturedFirst },
                        @{ Key = 'DisplayName'; Val = $capturedDisplay },
                        @{ Key = 'Username';    Val = $capturedSam }
                    )) {
                        $v = (& $escFn ([string]$ph.Val)).Replace('$', '$$')
                        $wHtml = $wHtml -ireplace ('\{' + $ph.Key + '\}'), $v
                    }
                    $introHtml += $wHtml
                }
            }
        }

        if (($appendHtml -or $introHtml) -and $dd -and $imgTableFn -and
            $dd.PSObject.Properties.Match('AdditionalInfoImages').Count -gt 0) {
            $inlineImages = & $imgTableFn $dd.AdditionalInfoImages
        }

        # Any prior diagnostic dump collapses back to compact on a new attempt.
        & $setStatusSmall '' $C_GRAY

        if (-not $toVal) {
            & $setStatusSmall 'To address is required. Enter the recipient email address.' $C_ERR
            return
        }
        if (-not $subjectVal) {
            & $setStatusSmall 'Subject is required.' $C_ERR
            return
        }

        $btnSend.Enabled = $false
        & $setStatusSmall 'Sending...' $C_GRAY
        $dlg.Refresh()

        $ccList = @()
        if ($ccVal) {
            $ccList = @($ccVal -split '[;,]' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        }

        if (-not $sendMailFn) {
            & $setStatusSmall 'Send-ADNotificationMail not loaded. Check Services_Mail_Send.psm1 is in Modules.' $C_ERR
            $btnSend.Enabled = $true
            return
        }

        $sendResult = & $sendMailFn `
            -Context     $capturedContext `
            -To          $toVal `
            -Cc          $ccList `
            -Subject     $subjectVal `
            -ActionTitle $capturedTitle `
            -Details     $capturedDetails `
            -BodyText    $bodyVal `
            -AppendHtml  $appendHtml `
            -InlineImages $inlineImages `
            -IntroHtml   $introHtml

        if ($sendResult.Success) {
            & $setStatusSmall $sendResult.Message $C_OK
            $dlg.Close()
        } else {
            # When the send function supplies a diagnostic report (config
            # failures), render the full field-by-field dump inline so the
            # operator sees exactly which mail field is missing vs blank and
            # whether the relay answered. Otherwise show the compact message.
            $hasDiag = ($sendResult.PSObject.Properties.Name -contains 'Diagnostic') -and $sendResult.Diagnostic
            if ($hasDiag) {
                $dump = "Send failed - configuration diagnostic:`r`n`r`n" + $sendResult.Diagnostic +
                        "`r`n`r`nYou may close or retry after correcting the launcher Context."
                & $setStatusDiag $dump
            } else {
                & $setStatusSmall ("Send failed: " + $sendResult.Message + "  (You may close or retry.)") $C_ERR
            }
            $btnSend.Enabled = $true
        }
    }.GetNewClosure())

    $btnSkip.Add_Click({  $dlg.Close() }.GetNewClosure())
    $btnClose.Add_Click({ $dlg.Close() }.GetNewClosure())

    [void]$dlg.ShowDialog()
}
#endregion

Export-ModuleMember -Function Show-NotificationMailDialog
