#region -- ADTools.DomainDefaults.InfoEditor.psm1 ------------------------------
# Concern : New-AdditionalInfoEditor - the "Additional Info (for emails)"
#           panel on the Domain Defaults tab: four slot buttons (one per
#           Additional Info snippet), a Title dropdown, a formatting toolbar
#           and a WYSIWYG editor. UI only - all HTML / picture logic lives in
#           Services.Mail.RichHtml and Services.Mail.Images; reading and
#           writing settings stays with ADTools.DomainDefaults.Tab
#           (Get-/Set-DomainDefaults), which calls this panel's Load /
#           Collect / RefreshLibrary members.
#
#           Editor engine: System.Windows.Forms.WebBrowser (MSHTML, ships
#           with Windows / .NET 4.8) showing a temp page with an editable
#           body. Formatting uses the browser's own commands (ExecCommand:
#           FontName, FontSize, Bold, Italic, Underline, ForeColor,
#           BackColor, InsertUnorderedList, InsertOrderedList, CreateLink,
#           Unlink, InsertImage, RemoveFormat). The page is loaded from a
#           temp FILE (%TEMP%\ADAdminMailEdit\edit_<guid>.htm), not from
#           DocumentText, because a DocumentText page (about:blank) is not
#           allowed to show local picture files.
#
#           Content flow:
#             Load    : saved HTML (cid:ID pictures) -> pictures written to
#                       the temp folder -> src rewritten to file:/// URLs ->
#                       shown in the editor.
#             Harvest : editor innerHTML -> ConvertTo-SafeMailHtml with a
#                       resolver that maps the temp picture files back to
#                       cid:ID (and imports any other local picture file,
#                       e.g. Word's clipboard images) -> canonical HTML.
#                       Runs on slot switch, Title pick and Collect (Save).
#             Collect : per slot Title, HTML and a plain-text copy, plus the
#                       domain's picture store (only referenced pictures).
#
#           Title dropdown: lists every titled snippet saved on any domain
#           (Get-DomainDefaultsAdditionalInfoLibrary). Picking one COPIES
#           its content and pictures into the current slot (asks first when
#           the slot already has different content). Typing a new Title
#           just names the slot.
#
#           Paste: Ctrl+V (and the right-click Paste) with a picture-only
#           clipboard (screenshot, "Copy image") or copied picture files
#           inserts the picture; anything containing text uses the
#           browser's normal paste, cleaned up by the sanitizer at harvest.
#           Limits: 600 px wide / 200 KB per picture (Services.Mail.Images),
#           30 pictures / about 1.5 MB per domain (here).
#
#           Closures: every handler is built with .GetNewClosure() and
#           invokes CAPTURED function references (& $fn) - bare-name calls
#           to dot-sourced functions inside .GetNewClosure() blocks are
#           unreliable in this codebase (see ADTools.DomainDefaults.Tab's
#           header). Mutable state lives in one hashtable ($st), shared by
#           reference between closures.
#           v1.6.0 - New Account Welcome: a fifth editor slot (button row
#           above the four Additional Info slots, index 4 internally). No
#           Title / dropdown for it - in its place a note explains it is
#           added to the top of every new-account email to the person,
#           below "Welcome <first name>!", and that {FirstName},
#           {DisplayName} and {Username} are filled in per person. Loaded
#           from / collected to NewAccountWelcomeHtml (+ NewAccountWelcome
#           plain copy); its pictures share the domain's picture store.
# Load order: 125a0 - depends on Services.Mail.RichHtml, Services.Mail.Images,
#             Services.DomainDefaults.Config (Get-DomainDefaultsAdditional-
#             InfoLibrary, soft). Loads before ADTools.DomainDefaults.Tab.
# New module: v1.5.0 (rich Additional Info).
#
# WinForms standard: fixed sizes, explicit positions, no Dock (the toolbar's
# Dock is explicitly None), no Anchor, no TableLayoutPanel, no GroupBox.
#endregion

#region -- New-InfoEditorSwatch (private helper) -------------------------------
function New-InfoEditorSwatch {
    <#
    .SYNOPSIS
        14x14 colour swatch bitmap for the Color / Highlight menu items.
    #>
    param([string]$Hex)
    $bmp = New-Object System.Drawing.Bitmap(14, 14)
    $g   = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $c = [System.Drawing.ColorTranslator]::FromHtml($Hex)
        $b = New-Object System.Drawing.SolidBrush($c)
        $g.FillRectangle($b, 0, 0, 14, 14)
        $b.Dispose()
        $g.DrawRectangle([System.Drawing.Pens]::Gray, 0, 0, 13, 13)
    } finally { $g.Dispose() }
    return $bmp
}
#endregion

#region -- Show-InfoEditorLinkDialog (private helper) ---------------------------
function Show-InfoEditorLinkDialog {
    <#
    .SYNOPSIS
        Small fixed-size dialog asking for link text and address.
    .PARAMETER Text
        Selected text in the editor ('' when nothing is selected).
    .OUTPUTS
        Hashtable @{ Text; Url } (Url normalised: bare email -> mailto:,
        www. -> https://) or $null when cancelled.
    #>
    param([string]$Text = '')

    $F_UI   = New-Object System.Drawing.Font('Segoe UI', 9)
    $F_UI_B = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $F_HINT = New-Object System.Drawing.Font('Segoe UI', 8)
    $hasSel = [bool]($Text -and $Text.Trim())

    $dlg                 = New-Object System.Windows.Forms.Form
    $dlg.Text            = 'Insert Link'
    $dlg.ClientSize      = New-Object System.Drawing.Size(440, 196)
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox     = $false
    $dlg.MinimizeBox     = $false
    $dlg.StartPosition   = 'CenterParent'
    $dlg.BackColor       = [System.Drawing.Color]::FromArgb(235, 238, 242)
    $dlg.Font            = $F_UI

    $l1           = New-Object System.Windows.Forms.Label
    $l1.Text      = if ($hasSel) { 'Text to display (the selected text):' } else { 'Text to display:' }
    $l1.Location  = New-Object System.Drawing.Point(16, 14)
    $l1.Size      = New-Object System.Drawing.Size(408, 18)
    $dlg.Controls.Add($l1)

    $tbText           = New-Object System.Windows.Forms.TextBox
    $tbText.Location  = New-Object System.Drawing.Point(16, 34)
    $tbText.Size      = New-Object System.Drawing.Size(408, 24)
    $tbText.Text      = if ($hasSel) { $Text.Trim() } else { '' }
    $tbText.ReadOnly  = $hasSel
    $dlg.Controls.Add($tbText)

    $l2           = New-Object System.Windows.Forms.Label
    $l2.Text      = 'Web address or email address:'
    $l2.Location  = New-Object System.Drawing.Point(16, 66)
    $l2.Size      = New-Object System.Drawing.Size(408, 18)
    $dlg.Controls.Add($l2)

    $tbUrl           = New-Object System.Windows.Forms.TextBox
    $tbUrl.Location  = New-Object System.Drawing.Point(16, 86)
    $tbUrl.Size      = New-Object System.Drawing.Size(408, 24)
    $dlg.Controls.Add($tbUrl)

    $lHint           = New-Object System.Windows.Forms.Label
    $lHint.Text      = 'Examples: https://intranet/support   www.contoso.com   help@contoso.com'
    $lHint.Location  = New-Object System.Drawing.Point(16, 114)
    $lHint.Size      = New-Object System.Drawing.Size(408, 30)
    $lHint.Font      = $F_HINT
    $lHint.ForeColor = [System.Drawing.Color]::DimGray
    $dlg.Controls.Add($lHint)

    $btnOK           = New-Object System.Windows.Forms.Button
    $btnOK.Text      = 'OK'
    $btnOK.Location  = New-Object System.Drawing.Point(256, 152)
    $btnOK.Size      = New-Object System.Drawing.Size(80, 30)
    $btnOK.Font      = $F_UI_B
    $dlg.Controls.Add($btnOK)
    $dlg.AcceptButton = $btnOK

    $btnCancel              = New-Object System.Windows.Forms.Button
    $btnCancel.Text         = 'Cancel'
    $btnCancel.Location     = New-Object System.Drawing.Point(344, 152)
    $btnCancel.Size         = New-Object System.Drawing.Size(80, 30)
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $dlg.Controls.Add($btnCancel)
    $dlg.CancelButton = $btnCancel

    $res = @{ Url = ''; Text = '' }
    $btnOK.Add_Click({
        $u = $tbUrl.Text.Trim()
        if ($u -match '^[^@\s/:]+@[^@\s]+\.[^@\s]+$') { $u = 'mailto:' + $u }
        elseif ($u -match '^(?i)www\.')             { $u = 'https://' + $u }
        if ($u -notmatch '^(?i)(https?://[^\s"''<>]+|mailto:[^\s"''<>]+)$') {
            $lHint.ForeColor = [System.Drawing.Color]::FromArgb(156, 0, 6)
            $lHint.Text      = 'Enter a full address starting with http://, https://, www. or an email address (no spaces).'
            return
        }
        $t = $tbText.Text.Trim()
        if (-not $t) { $t = ($u -replace '^(?i)mailto:', '') }
        $res.Url  = $u
        $res.Text = $t
        $dlg.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $dlg.Close()
    }.GetNewClosure())

    if ($hasSel) { [void]$tbUrl.Select() } else { [void]$tbText.Select() }
    $dr = $dlg.ShowDialog()
    $dlg.Dispose()
    if ($dr -eq [System.Windows.Forms.DialogResult]::OK -and $res.Url) { return $res }
    return $null
}
#endregion

#region -- New-AdditionalInfoEditor --------------------------------------------
function New-AdditionalInfoEditor {
    <#
    .SYNOPSIS
        Builds the Additional Info editor inside $Parent and returns its
        API, or $null (with an explanatory label shown) when a required
        service module did not load.
    .PARAMETER Parent
        Container (the section panel's white inner panel).
    .PARAMETER W / H
        Usable size of $Parent.
    .OUTPUTS
        PSCustomObject:
          Load           - scriptblock param($Defaults): show one domain's
                           four snippets (Get-DomainDefaults object).
          Collect        - scriptblock: returns a hashtable of the
                           AdditionalInfo* and NewAccountWelcome* settings
                           for Set-DomainDefaults.
          RefreshLibrary - scriptblock: reload the Title dropdown list.
          SetStatus      - scriptblock param([string]$Msg, [bool]$IsError).
          ButtonX/ButtonY - free spot (130 x 28) at the bottom right for
                           the caller's own Save button.
    #>
    param(
        [System.Windows.Forms.Control]$Parent,
        [int]$W,
        [int]$H
    )

    $F_UI   = New-Object System.Drawing.Font('Segoe UI', 9)
    $F_UI_B = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $F_HINT = New-Object System.Drawing.Font('Segoe UI', 8)
    $C_BLUE = [System.Drawing.Color]::FromArgb(0, 99, 177)
    $C_HDR  = [System.Drawing.Color]::FromArgb(0, 80, 160)
    $C_ERR  = [System.Drawing.Color]::FromArgb(156, 0, 6)
    $C_OK   = [System.Drawing.Color]::FromArgb(0, 97, 0)

    $LX = 10
    $CW = $W - 20

    # -- Captured function references (see module header) ---------------------
    $sanitizeFn  = ${function:ConvertTo-SafeMailHtml}
    $toTextFn    = ${function:ConvertFrom-MailHtmlToText}
    $fromTextFn  = ${function:ConvertTo-MailHtmlFromText}
    $imageIdsFn  = ${function:Get-MailHtmlImageIds}
    $safeFontsFn = ${function:Get-MailSafeFonts}
    $imgFileFn   = ${function:Import-MailImageFile}
    $imgObjFn    = ${function:Import-MailImageObject}
    $imgTableFn  = ${function:ConvertTo-MailImageTable}
    $imgTempFn   = ${function:Save-MailImageTempFile}
    $editDirFn   = ${function:Get-MailImageEditDir}
    $libraryFn   = ${function:Get-DomainDefaultsAdditionalInfoLibrary}
    $linkDlgFn   = ${function:Show-InfoEditorLinkDialog}
    $swatchFn    = ${function:New-InfoEditorSwatch}

    if (-not $sanitizeFn -or -not $imgTableFn -or -not $imgTempFn) {
        $lMissing           = New-Object System.Windows.Forms.Label
        $lMissing.Text      = 'The formatted Additional Info editor is unavailable: Services_Mail_RichHtml / Services_Mail_Images did not load (see Logs\ModuleLoad). Existing Additional Info settings are kept unchanged when you save.'
        $lMissing.Location  = New-Object System.Drawing.Point($LX, 12)
        $lMissing.Size      = New-Object System.Drawing.Size($CW, 60)
        $lMissing.Font      = $F_UI
        $lMissing.ForeColor = $C_ERR
        $Parent.Controls.Add($lMissing)
        return $null
    }

    # -- Shared state ----------------------------------------------------------
    $st = @{
        Slots    = @(
            @{ Title = ''; Html = '' }, @{ Title = ''; Html = '' },
            @{ Title = ''; Html = '' }, @{ Title = ''; Html = '' },
            @{ Title = ''; Html = '' }      # [4] New Account Welcome
        )
        Images   = @{}       # Id -> @{ Type; Data } for this domain
        Current  = 0
        Ready    = $false    # editor page loaded and safe to read
        AllowNav = $false    # only our own page loads may navigate
        Suppress = $false    # programmatic Title changes
        Library  = @()
        EditFile = ''
        Fn       = @{}       # late-bound handlers (KeyDown, Paste)
    }

    # =========================================================================
    # Controls
    # =========================================================================
    $lHint           = New-Object System.Windows.Forms.Label
    $lHint.Text      = 'Formatted text for notification emails. New Account Welcome is added automatically to new-account emails; the four Additional Info slots are checkboxes on the Send Notification window (slot 1 is pre-checked). Paste text, links or screenshots with Ctrl+V. Changes are saved with Save Defaults.'
    $lHint.Location  = New-Object System.Drawing.Point($LX, 8)
    $lHint.Size      = New-Object System.Drawing.Size($CW, 44)
    $lHint.Font      = $F_HINT
    $lHint.ForeColor = [System.Drawing.Color]::DimGray
    $Parent.Controls.Add($lHint)

    # Slot buttons (act as tabs)
    $SLOT_GAP = 6
    $SLOT_W   = [int](($CW - (3 * $SLOT_GAP)) / 4)
    # Index 0-3 = Additional Info slots (row 2); index 4 = New Account
    # Welcome (row 1, its own row so more automatic messages can join it).
    $slotButtons = New-Object 'System.Windows.Forms.Button[]' 5
    for ($i = 0; $i -lt 4; $i++) {
        $b                           = New-Object System.Windows.Forms.Button
        $b.Location                  = New-Object System.Drawing.Point(($LX + $i * ($SLOT_W + $SLOT_GAP)), 92)
        $b.Size                      = New-Object System.Drawing.Size($SLOT_W, 30)
        $b.Font                      = $F_UI_B
        $b.FlatStyle                 = 'Flat'
        $b.FlatAppearance.BorderColor = $C_BLUE
        $b.FlatAppearance.BorderSize = 1
        $b.Tag                       = $i
        $b.Text                      = 'Additional Info ' + ($i + 1)
        $Parent.Controls.Add($b)
        $slotButtons[$i] = $b
    }
    $bw                            = New-Object System.Windows.Forms.Button
    $bw.Location                   = New-Object System.Drawing.Point($LX, 56)
    $bw.Size                       = New-Object System.Drawing.Size($SLOT_W, 30)
    $bw.Font                       = $F_UI_B
    $bw.FlatStyle                  = 'Flat'
    $bw.FlatAppearance.BorderColor = $C_BLUE
    $bw.FlatAppearance.BorderSize  = 1
    $bw.Tag                        = 4
    $bw.Text                       = 'New Account Welcome'
    $Parent.Controls.Add($bw)
    $slotButtons[4] = $bw

    $lAutoHint           = New-Object System.Windows.Forms.Label
    $lAutoHint.Text      = 'Sent automatically'
    $lAutoHint.Location  = New-Object System.Drawing.Point(($LX + $SLOT_W + $SLOT_GAP), 63)
    $lAutoHint.Size      = New-Object System.Drawing.Size(200, 18)
    $lAutoHint.Font      = $F_HINT
    $lAutoHint.ForeColor = [System.Drawing.Color]::DimGray
    $Parent.Controls.Add($lAutoHint)

    # Title row
    $lTitle           = New-Object System.Windows.Forms.Label
    $lTitle.Text      = 'Title:'
    $lTitle.Location  = New-Object System.Drawing.Point($LX, 138)
    $lTitle.Size      = New-Object System.Drawing.Size(40, 20)
    $lTitle.Font      = $F_UI
    $lTitle.ForeColor = [System.Drawing.Color]::FromArgb(60, 60, 60)
    $Parent.Controls.Add($lTitle)

    $cmbTitle                    = New-Object System.Windows.Forms.ComboBox
    $cmbTitle.Location           = New-Object System.Drawing.Point(($LX + 44), 134)
    $cmbTitle.Size               = New-Object System.Drawing.Size(380, 24)
    $cmbTitle.Font               = $F_UI
    $cmbTitle.DropDownStyle      = 'DropDown'
    $cmbTitle.MaxLength          = 60
    $cmbTitle.MaxDropDownItems   = 20
    $cmbTitle.AutoCompleteMode   = 'SuggestAppend'
    $cmbTitle.AutoCompleteSource = 'ListItems'
    $Parent.Controls.Add($cmbTitle)

    $lTitleHint           = New-Object System.Windows.Forms.Label
    $lTitleHint.Text      = 'Bold heading in the email and the checkbox name.'
    $lTitleHint.Location  = New-Object System.Drawing.Point(($LX + 432), 138)
    $lTitleHint.Size      = New-Object System.Drawing.Size(($CW - 432 - 108), 20)
    $lTitleHint.Font      = $F_HINT
    $lTitleHint.ForeColor = [System.Drawing.Color]::DimGray
    $Parent.Controls.Add($lTitleHint)

    $btnClearSlot          = New-Object System.Windows.Forms.Button
    $btnClearSlot.Text     = 'Clear Slot'
    $btnClearSlot.Location = New-Object System.Drawing.Point(($LX + $CW - 100), 133)
    $btnClearSlot.Size     = New-Object System.Drawing.Size(100, 26)
    $btnClearSlot.Font     = $F_UI
    $Parent.Controls.Add($btnClearSlot)

    # Shown instead of the Title row while New Account Welcome is selected.
    $lWelcomeNote           = New-Object System.Windows.Forms.Label
    $lWelcomeNote.Text      = 'Added to the top of every new-account email sent to the person (Create User and Bulk Onboard), right below the line "Welcome <first name>!". {FirstName}, {DisplayName} and {Username} are filled in per person.'
    $lWelcomeNote.Location  = New-Object System.Drawing.Point($LX, 132)
    $lWelcomeNote.Size      = New-Object System.Drawing.Size(($CW - 110), 32)
    $lWelcomeNote.Font      = $F_HINT
    $lWelcomeNote.ForeColor = [System.Drawing.Color]::FromArgb(60, 60, 60)
    $lWelcomeNote.Visible   = $false
    $Parent.Controls.Add($lWelcomeNote)

    # Toolbar
    $ts            = New-Object System.Windows.Forms.ToolStrip
    $ts.Dock       = 'None'
    $ts.GripStyle  = 'Hidden'
    $ts.AutoSize   = $false
    $ts.Location   = New-Object System.Drawing.Point($LX, 170)
    $ts.Size       = New-Object System.Drawing.Size($CW, 28)
    $ts.RenderMode = 'System'
    $ts.BackColor  = [System.Drawing.Color]::FromArgb(245, 247, 252)
    $ts.Font       = $F_UI
    $ts.TabStop    = $false
    $Parent.Controls.Add($ts)

    $cboFont               = New-Object System.Windows.Forms.ToolStripComboBox
    $cboFont.DropDownStyle = 'DropDownList'
    $cboFont.AutoSize      = $false
    $cboFont.Size          = New-Object System.Drawing.Size(130, 23)
    $cboFont.ToolTipText   = 'Font (email-safe fonts)'
    [void]$cboFont.Items.Add('Font')
    foreach ($f in (& $safeFontsFn)) { [void]$cboFont.Items.Add($f) }
    $cboFont.SelectedIndex = 0
    [void]$ts.Items.Add($cboFont)

    # Browser font sizes 1..7 shown as their point sizes.
    $sizeLabels = @('Size', '8 pt', '10 pt', '12 pt', '14 pt', '18 pt', '24 pt', '36 pt')
    $cboSize               = New-Object System.Windows.Forms.ToolStripComboBox
    $cboSize.DropDownStyle = 'DropDownList'
    $cboSize.AutoSize      = $false
    $cboSize.Size          = New-Object System.Drawing.Size(66, 23)
    $cboSize.ToolTipText   = 'Font size'
    foreach ($s in $sizeLabels) { [void]$cboSize.Items.Add($s) }
    $cboSize.SelectedIndex = 0
    [void]$ts.Items.Add($cboSize)

    [void]$ts.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

    $newTsButton = {
        param([string]$Text, [string]$Tip, $Font)
        $tb              = New-Object System.Windows.Forms.ToolStripButton
        $tb.Text         = $Text
        $tb.ToolTipText  = $Tip
        $tb.DisplayStyle = 'Text'
        if ($Font) { $tb.Font = $Font }
        return $tb
    }
    $tbBold      = & $newTsButton 'B' 'Bold (Ctrl+B)' (New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold))
    $tbItalic    = & $newTsButton 'I' 'Italic (Ctrl+I)' (New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Italic))
    $tbUnderline = & $newTsButton 'U' 'Underline (Ctrl+U)' (New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Underline))
    [void]$ts.Items.Add($tbBold)
    [void]$ts.Items.Add($tbItalic)
    [void]$ts.Items.Add($tbUnderline)
    [void]$ts.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

    $ddColor              = New-Object System.Windows.Forms.ToolStripDropDownButton
    $ddColor.Text         = 'Color'
    $ddColor.ToolTipText  = 'Text color'
    $ddColor.DisplayStyle = 'Text'
    [void]$ts.Items.Add($ddColor)

    $ddHigh               = New-Object System.Windows.Forms.ToolStripDropDownButton
    $ddHigh.Text          = 'Highlight'
    $ddHigh.ToolTipText   = 'Highlight (background) color'
    $ddHigh.DisplayStyle  = 'Text'
    [void]$ts.Items.Add($ddHigh)
    [void]$ts.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

    $tbBullets  = & $newTsButton 'Bullets' 'Bulleted list' $null
    $tbNumbers  = & $newTsButton 'Numbers' 'Numbered list' $null
    [void]$ts.Items.Add($tbBullets)
    [void]$ts.Items.Add($tbNumbers)
    [void]$ts.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

    $tbLink     = & $newTsButton 'Link...' 'Insert or change a link (select text first to link it)' $null
    $tbUnlink   = & $newTsButton 'Unlink' 'Remove the link from the selection' $null
    $tbPicture  = & $newTsButton 'Picture...' 'Insert a picture from a file (PNG, JPG, GIF) - or paste one with Ctrl+V' $null
    [void]$ts.Items.Add($tbLink)
    [void]$ts.Items.Add($tbUnlink)
    [void]$ts.Items.Add($tbPicture)
    [void]$ts.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

    $tbClear    = & $newTsButton 'Clear' 'Clear formatting from the selection' $null
    [void]$ts.Items.Add($tbClear)

    # Editor (WebBrowser inside a 1px grey border panel)
    $EDIT_Y = 204
    $EDIT_H = $H - $EDIT_Y - 50
    $pnlEdit           = New-Object System.Windows.Forms.Panel
    $pnlEdit.Location  = New-Object System.Drawing.Point($LX, $EDIT_Y)
    $pnlEdit.Size      = New-Object System.Drawing.Size($CW, $EDIT_H)
    $pnlEdit.BackColor = [System.Drawing.Color]::FromArgb(160, 160, 160)
    $Parent.Controls.Add($pnlEdit)

    $wb                                = New-Object System.Windows.Forms.WebBrowser
    $wb.Location                       = New-Object System.Drawing.Point(1, 1)
    $wb.Size                           = New-Object System.Drawing.Size(($CW - 2), ($EDIT_H - 2))
    $wb.ScriptErrorsSuppressed         = $true
    $wb.AllowWebBrowserDrop            = $false
    $wb.IsWebBrowserContextMenuEnabled = $false
    $wb.WebBrowserShortcutsEnabled     = $true
    $pnlEdit.Controls.Add($wb)

    $ctx = New-Object System.Windows.Forms.ContextMenuStrip
    $miCut   = $ctx.Items.Add('Cut')
    $miCopy  = $ctx.Items.Add('Copy')
    $miPaste = $ctx.Items.Add('Paste')
    [void]$ctx.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    $miAll   = $ctx.Items.Add('Select All')
    $wb.ContextMenuStrip = $ctx

    # Status line (bottom left; the caller's Save button goes bottom right)
    $lStatus           = New-Object System.Windows.Forms.Label
    $lStatus.Location  = New-Object System.Drawing.Point($LX, ($H - 42))
    $lStatus.Size      = New-Object System.Drawing.Size(($CW - 150), 34)
    $lStatus.Font      = $F_HINT
    $lStatus.ForeColor = [System.Drawing.Color]::DimGray
    $lStatus.Text      = ''
    $Parent.Controls.Add($lStatus)

    $btnX = $LX + $CW - 130
    $btnY = $H - 40

    # =========================================================================
    # Behaviour (closures - order matters: each one captures those above it)
    # =========================================================================
    $setStatus = {
        param([string]$Msg, [bool]$IsError)
        $lStatus.ForeColor = if ($IsError) { $C_ERR } else { $C_OK }
        $lStatus.Text      = $Msg
    }.GetNewClosure()

    $paintButtons = {
        for ($i = 0; $i -lt 5; $i++) {
            if ($i -eq 4) {
                $cap = 'New Account Welcome'
            } else {
                $t   = [string]$st.Slots[$i].Title
                $cap = if ($t) { [string]($i + 1) + ': ' + $t } else { 'Additional Info ' + ($i + 1) }
                if ($cap.Length -gt 34) { $cap = $cap.Substring(0, 32) + '...' }
            }
            $b = $slotButtons[$i]
            $b.Text = $cap
            if ($i -eq $st.Current) {
                $b.BackColor = $C_BLUE
                $b.ForeColor = [System.Drawing.Color]::White
            } else {
                $b.BackColor = [System.Drawing.Color]::White
                $b.ForeColor = $C_HDR
            }
        }
    }.GetNewClosure()

    # Saved HTML (cid:ID) -> editor HTML (file:/// temp picture URLs).
    $toEditorHtml = {
        param([string]$Html)
        if (-not $Html) { return '' }
        $out = $Html
        foreach ($id in (& $imageIdsFn -Html $Html)) {
            if (-not $st.Images.ContainsKey($id)) { continue }
            $img  = $st.Images[$id]
            $path = & $imgTempFn -Id $id -Type $img.Type -Data $img.Data
            if ($path) { $out = $out.Replace('cid:' + $id, ([System.Uri]$path).AbsoluteUri) }
        }
        return $out
    }.GetNewClosure()

    # Sanitizer callback: editor picture src -> picture ID (or $null = drop).
    $resolver = {
        param([string]$Src)
        if ($Src -match '(?i)(?:^|[/\\])([0-9a-f]{16})\.(png|jpe?g|gif)$') {
            $id = $matches[1].ToLowerInvariant()
            if ($st.Images.ContainsKey($id)) { return $id }
        }
        if ($Src -match '^(?i)file:') {
            $local = ''
            try { $local = ([System.Uri]$Src).LocalPath } catch { return $null }
            $r = & $imgFileFn -Path $local
            if ($r.Success) {
                $st.Images[$r.Id] = @{ Type = $r.Type; Data = $r.Data }
                return $r.Id
            }
        }
        return $null
    }.GetNewClosure()

    # Editor -> canonical HTML of the current slot.
    $harvest = {
        if (-not $st.Ready) { return }
        try {
            $doc = $wb.Document
            if (-not $doc -or -not $doc.Body) { return }
            $raw = [string]$doc.Body.InnerHtml
            $st.Slots[$st.Current].Html = & $sanitizeFn -Html $raw -ImageResolver $resolver
        } catch {
            & $setStatus ('Could not read the editor: ' + $_.Exception.Message) $true
        }
    }.GetNewClosure()

    $loadEditor = {
        param([string]$Canonical)
        $st.Ready = $false
        try {
            $body = & $toEditorHtml $Canonical
            $page = '<html><head><meta http-equiv="Content-Type" content="text/html; charset=us-ascii">' +
                    '<style type="text/css">' +
                    'body{font-family:''Segoe UI'',Arial,sans-serif;font-size:13px;color:#1a1a1a;line-height:1.5;margin:8px;background:#ffffff;}' +
                    'p{margin:0;} ul,ol{margin-top:0;margin-bottom:0;} img{border:0;}' +
                    '</style></head><body contenteditable="true">' + $body + '</body></html>'
            $dir = & $editDirFn
            try {
                Get-ChildItem -LiteralPath $dir -Filter 'edit_*.htm' -ErrorAction SilentlyContinue |
                    Remove-Item -Force -ErrorAction SilentlyContinue
            } catch { }
            $file = Join-Path $dir ('edit_' + [guid]::NewGuid().ToString('N') + '.htm')
            [System.IO.File]::WriteAllText($file, $page, [System.Text.Encoding]::ASCII)
            $st.EditFile = $file
            $st.AllowNav = $true
            $wb.Navigate($file)
        } catch {
            $st.AllowNav = $false
            & $setStatus ('Could not open the editor: ' + $_.Exception.Message) $true
        }
    }.GetNewClosure()

    $showSlot = {
        param([int]$Index)
        & $harvest
        $st.Current  = $Index
        $isWelcome   = ($Index -eq 4)
        $lTitle.Visible       = -not $isWelcome
        $cmbTitle.Visible     = -not $isWelcome
        $lTitleHint.Visible   = -not $isWelcome
        $lWelcomeNote.Visible = $isWelcome
        $st.Suppress = $true
        $cmbTitle.Text = if ($isWelcome) { '' } else { [string]$st.Slots[$Index].Title }
        $st.Suppress = $false
        & $paintButtons
        & $loadEditor ([string]$st.Slots[$Index].Html)
    }.GetNewClosure()

    $exec = {
        param([string]$Cmd, $Val)
        if (-not $st.Ready) { return }
        try {
            [void]$wb.Focus()
            [void]$wb.Document.ExecCommand($Cmd, $false, $Val)
        } catch {
            & $setStatus ($Cmd + ' failed: ' + $_.Exception.Message) $true
        }
    }.GetNewClosure()

    # Adds a processed picture (Services.Mail.Images result) at the caret.
    $insertImage = {
        param($Rec)
        if (-not $Rec -or -not $Rec.Success) {
            $m = if ($Rec) { $Rec.Message } else { 'No picture.' }
            & $setStatus $m $true
            return
        }
        if (-not $st.Ready) { return }
        if (-not $st.Images.ContainsKey($Rec.Id)) {
            $total = 0
            foreach ($v in $st.Images.Values) { $total += ([string]$v.Data).Length }
            if ($st.Images.Count -ge 30 -or ($total + $Rec.Data.Length) -gt 2000000) {
                & $setStatus 'Picture limit reached for this domain (30 pictures / about 1.5 MB). Remove pictures you no longer use and click Save Defaults first.' $true
                return
            }
            $st.Images[$Rec.Id] = @{ Type = $Rec.Type; Data = $Rec.Data }
        }
        $path = & $imgTempFn -Id $Rec.Id -Type $Rec.Type -Data $Rec.Data
        if (-not $path) { & $setStatus 'Could not write the picture to the temp folder.' $true; return }
        $url = ([System.Uri]$path).AbsoluteUri

        $before = 0
        try { $before = $wb.Document.Images.Count } catch { }
        try {
            [void]$wb.Focus()
            [void]$wb.Document.ExecCommand('InsertImage', $false, $url)
        } catch { }
        $after = 0
        try { $after = $wb.Document.Images.Count } catch { }
        if ($after -le $before) {
            # No caret in the editor yet - append at the end instead.
            try { $wb.Document.Body.InnerHtml = [string]$wb.Document.Body.InnerHtml + '<img src="' + $url + '">' } catch { }
        }
        $kb = [int][Math]::Ceiling(($Rec.Data.Length * 3 / 4) / 1024)
        & $setStatus ('Picture added (' + $Rec.Width + ' x ' + $Rec.Height + ' px, ' + $kb + ' KB).') $false
    }.GetNewClosure()

    # Picture-aware paste. Returns $true when it handled the paste itself.
    $pastePicture = {
        try {
            if ([System.Windows.Forms.Clipboard]::ContainsText()) { return $false }
            if ([System.Windows.Forms.Clipboard]::ContainsImage()) {
                $img = [System.Windows.Forms.Clipboard]::GetImage()
                $rec = & $imgObjFn -Image $img
                if ($img) { $img.Dispose() }
                & $insertImage $rec
                return $true
            }
            if ([System.Windows.Forms.Clipboard]::ContainsFileDropList()) {
                $handled = $false
                foreach ($f in [System.Windows.Forms.Clipboard]::GetFileDropList()) {
                    if ([string]$f -match '(?i)\.(png|jpe?g|gif|bmp)$') {
                        & $insertImage (& $imgFileFn -Path ([string]$f))
                        $handled = $true
                    }
                }
                return $handled
            }
        } catch {
            & $setStatus ('Paste failed: ' + $_.Exception.Message) $true
            return $true
        }
        return $false
    }.GetNewClosure()

    $keyDown = {
        param($sender, $e)
        if ($e.CtrlKeyPressed -and $e.KeyPressedCode -eq 86) {
            if (& $pastePicture) { $e.ReturnValue = $false }
        }
    }.GetNewClosure()
    $st.Fn.KeyDown = $keyDown

    # -- Browser events --------------------------------------------------------
    $wb.Add_Navigating({
        param($sender, $e)
        if (-not $st.AllowNav) { $e.Cancel = $true }
    }.GetNewClosure())
    $wb.Add_NewWindow({
        param($sender, $e)
        $e.Cancel = $true
    }.GetNewClosure())
    $wb.Add_DocumentCompleted({
        param($sender, $e)
        # Ignore a late "completed" from a page we already replaced. Compare
        # file names only - the browser may report a long path where TEMP
        # holds a short (8.3) one.
        if ($st.EditFile -and $e.Url -and $e.Url.IsFile -and
            ([System.IO.Path]::GetFileName($e.Url.LocalPath) -ine [System.IO.Path]::GetFileName($st.EditFile))) { return }
        $st.AllowNav = $false
        $st.Ready    = $true
        try { $wb.Document.Add_KeyDown($st.Fn.KeyDown) } catch { }
    }.GetNewClosure())

    # -- Context menu ----------------------------------------------------------
    $miCut.Add_Click({ & $exec 'Cut' $null }.GetNewClosure())
    $miCopy.Add_Click({ & $exec 'Copy' $null }.GetNewClosure())
    $miPaste.Add_Click({
        if (-not (& $pastePicture)) { & $exec 'Paste' $null }
    }.GetNewClosure())
    $miAll.Add_Click({ & $exec 'SelectAll' $null }.GetNewClosure())

    # -- Toolbar ---------------------------------------------------------------
    $cboFont.Add_SelectedIndexChanged({
        if ($st.Suppress -or $cboFont.SelectedIndex -le 0) { return }
        & $exec 'FontName' ([string]$cboFont.SelectedItem)
        $st.Suppress = $true; $cboFont.SelectedIndex = 0; $st.Suppress = $false
    }.GetNewClosure())
    $cboSize.Add_SelectedIndexChanged({
        if ($st.Suppress -or $cboSize.SelectedIndex -le 0) { return }
        & $exec 'FontSize' ([string]$cboSize.SelectedIndex)
        $st.Suppress = $true; $cboSize.SelectedIndex = 0; $st.Suppress = $false
    }.GetNewClosure())
    $tbBold.Add_Click({ & $exec 'Bold' $null }.GetNewClosure())
    $tbItalic.Add_Click({ & $exec 'Italic' $null }.GetNewClosure())
    $tbUnderline.Add_Click({ & $exec 'Underline' $null }.GetNewClosure())
    $tbBullets.Add_Click({ & $exec 'InsertUnorderedList' $null }.GetNewClosure())
    $tbNumbers.Add_Click({ & $exec 'InsertOrderedList' $null }.GetNewClosure())
    $tbUnlink.Add_Click({ & $exec 'Unlink' $null }.GetNewClosure())
    $tbClear.Add_Click({ & $exec 'RemoveFormat' $null }.GetNewClosure())

    $pickColor = {
        $cd = New-Object System.Windows.Forms.ColorDialog
        $cd.FullOpen = $true
        $hex = ''
        if ($cd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $hex = ('#{0:x2}{1:x2}{2:x2}' -f $cd.Color.R, $cd.Color.G, $cd.Color.B)
        }
        $cd.Dispose()
        return $hex
    }

    $textColors = [ordered]@{
        'Black' = '#000000'; 'Dark Gray' = '#595959'; 'Red' = '#c00000'; 'Orange' = '#e46c0a'
        'Green' = '#00843d'; 'Blue' = '#0063b1'; 'Dark Blue' = '#1f3864'; 'Purple' = '#7030a0'
    }
    foreach ($name in $textColors.Keys) {
        $mi       = New-Object System.Windows.Forms.ToolStripMenuItem($name)
        $mi.Image = & $swatchFn $textColors[$name]
        $mi.Tag   = $textColors[$name]
        $mi.Add_Click({ & $exec 'ForeColor' ([string]$this.Tag) }.GetNewClosure())
        [void]$ddColor.DropDownItems.Add($mi)
    }
    [void]$ddColor.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    $miMoreColor = New-Object System.Windows.Forms.ToolStripMenuItem('More colors...')
    $miMoreColor.Add_Click({
        $hex = & $pickColor
        if ($hex) { & $exec 'ForeColor' $hex }
    }.GetNewClosure())
    [void]$ddColor.DropDownItems.Add($miMoreColor)

    $highColors = [ordered]@{
        'Yellow' = '#ffff00'; 'Light Green' = '#c6efce'; 'Light Blue' = '#ddebf7'
        'Pink' = '#fce4ec'; 'Light Gray' = '#ededed'
    }
    foreach ($name in $highColors.Keys) {
        $mi       = New-Object System.Windows.Forms.ToolStripMenuItem($name)
        $mi.Image = & $swatchFn $highColors[$name]
        $mi.Tag   = $highColors[$name]
        $mi.Add_Click({ & $exec 'BackColor' ([string]$this.Tag) }.GetNewClosure())
        [void]$ddHigh.DropDownItems.Add($mi)
    }
    $miNoHigh = New-Object System.Windows.Forms.ToolStripMenuItem('No highlight')
    $miNoHigh.Add_Click({ & $exec 'BackColor' '#ffffff' }.GetNewClosure())
    [void]$ddHigh.DropDownItems.Add($miNoHigh)
    [void]$ddHigh.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    $miMoreHigh = New-Object System.Windows.Forms.ToolStripMenuItem('More colors...')
    $miMoreHigh.Add_Click({
        $hex = & $pickColor
        if ($hex) { & $exec 'BackColor' $hex }
    }.GetNewClosure())
    [void]$ddHigh.DropDownItems.Add($miMoreHigh)

    $tbLink.Add_Click({
        if (-not $st.Ready) { return }
        $rng = $null; $selText = ''
        try {
            $rng     = $wb.Document.DomDocument.selection.createRange()
            $selText = [string]$rng.text
        } catch { $rng = $null; $selText = '' }
        $res = & $linkDlgFn -Text $selText
        if (-not $res) { return }
        [void]$wb.Focus()
        if ($selText -and $selText.Trim()) {
            try { [void]$rng.select() } catch { }
            & $exec 'CreateLink' $res.Url
        } else {
            $html = '<a href="' + [System.Net.WebUtility]::HtmlEncode($res.Url) + '">' +
                    [System.Net.WebUtility]::HtmlEncode($res.Text) + '</a>'
            $done = $false
            if ($rng) { try { [void]$rng.pasteHTML($html); $done = $true } catch { } }
            if (-not $done) {
                try { $wb.Document.Body.InnerHtml = [string]$wb.Document.Body.InnerHtml + ' ' + $html } catch { }
            }
        }
    }.GetNewClosure())

    $tbPicture.Add_Click({
        if (-not $st.Ready) { return }
        $ofd = New-Object System.Windows.Forms.OpenFileDialog
        $ofd.Title  = 'Insert Picture'
        $ofd.Filter = 'Pictures (*.png;*.jpg;*.jpeg;*.gif;*.bmp)|*.png;*.jpg;*.jpeg;*.gif;*.bmp'
        $ok = ($ofd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK)
        $path = $ofd.FileName
        $ofd.Dispose()
        if ($ok -and $path) { & $insertImage (& $imgFileFn -Path $path) }
    }.GetNewClosure())

    # -- Slot buttons, Title, Clear --------------------------------------------
    foreach ($b in $slotButtons) {
        $b.Add_Click({
            $idx = [int]$this.Tag
            if ($idx -ne $st.Current) { & $showSlot $idx }
        }.GetNewClosure())
    }

    $cmbTitle.Add_TextChanged({
        if ($st.Suppress -or $st.Current -eq 4) { return }
        $st.Slots[$st.Current].Title = $cmbTitle.Text.Trim()
        & $paintButtons
    }.GetNewClosure())

    $cmbTitle.Add_SelectionChangeCommitted({
        if ($st.Suppress -or $st.Current -eq 4) { return }
        $picked = [string]$cmbTitle.SelectedItem
        if (-not $picked) { return }
        $entry = $null
        foreach ($e in $st.Library) { if ($e.Title -eq $picked) { $entry = $e; break } }
        if (-not $entry) { return }

        & $harvest
        $slot = $st.Slots[$st.Current]
        $newHtml = if ($entry.Html -and $entry.Html.Trim()) { [string]$entry.Html } else { & $fromTextFn -Text ([string]$entry.Text) }
        $newHtml = & $sanitizeFn -Html $newHtml
        if ($slot.Html -and $slot.Html -ne $newHtml) {
            $ans = [System.Windows.Forms.MessageBox]::Show(
                ("Replace the text in this slot with the saved '" + $entry.Title + "' (from " + $entry.Domain + ")?"),
                'Additional Info', [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Question)
            if ($ans -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        }
        if ($entry.Images) {
            foreach ($k in $entry.Images.Keys) {
                if (-not $st.Images.ContainsKey($k)) { $st.Images[$k] = @{ Type = $entry.Images[$k].Type; Data = $entry.Images[$k].Data } }
            }
        }
        $slot.Title = $entry.Title
        $slot.Html  = $newHtml
        & $paintButtons
        & $loadEditor $newHtml
        & $setStatus ("Copied '" + $entry.Title + "' from " + $entry.Domain + ' (slot ' + $entry.Slot + '). Click Save Defaults to keep it.') $false
    }.GetNewClosure())

    $btnClearSlot.Add_Click({
        $slot = $st.Slots[$st.Current]
        & $harvest
        if ($slot.Title -or $slot.Html) {
            $what = if ($st.Current -eq 4) { 'the New Account welcome message' } else { 'the Title and text of Additional Info ' + ($st.Current + 1) }
            $ans = [System.Windows.Forms.MessageBox]::Show(
                ('Clear ' + $what + '?'),
                'Additional Info', [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Question)
            if ($ans -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        }
        $slot.Title = ''
        $slot.Html  = ''
        $st.Suppress = $true; $cmbTitle.Text = ''; $st.Suppress = $false
        & $paintButtons
        & $loadEditor ''
    }.GetNewClosure())

    # =========================================================================
    # API
    # =========================================================================
    $refreshLibrary = {
        $st.Library = @()
        if ($libraryFn) {
            try { $st.Library = @(& $libraryFn) } catch { $st.Library = @() }
        }
        $keep = $cmbTitle.Text
        $st.Suppress = $true
        $cmbTitle.Items.Clear()
        foreach ($e in $st.Library) { [void]$cmbTitle.Items.Add([string]$e.Title) }
        $cmbTitle.Text = $keep
        $st.Suppress = $false
    }.GetNewClosure()

    $load = {
        param($Defaults)
        $st.Ready  = $false          # never harvest the previous domain's page into this one
        $st.Images = @{}
        if ($Defaults -and $Defaults.PSObject.Properties.Match('AdditionalInfoImages').Count -gt 0) {
            $st.Images = & $imgTableFn $Defaults.AdditionalInfoImages
        }
        for ($n = 1; $n -le 4; $n++) {
            $title = ''; $html = ''; $text = ''
            if ($Defaults) {
                $title = ([string]$Defaults."AdditionalInfo${n}Label").Trim()
                $html  = [string]$Defaults."AdditionalInfo${n}Html"
                $text  = [string]$Defaults."AdditionalInfo$n"
            }
            if ($html.Trim()) { $html = & $sanitizeFn -Html $html }
            elseif ($text.Trim()) { $html = & $fromTextFn -Text $text }
            else { $html = '' }
            $st.Slots[$n - 1].Title = $title
            $st.Slots[$n - 1].Html  = $html
        }
        $wHtml = ''; $wText = ''
        if ($Defaults) {
            $wHtml = [string]$Defaults.NewAccountWelcomeHtml
            $wText = [string]$Defaults.NewAccountWelcome
        }
        if ($wHtml.Trim()) { $wHtml = & $sanitizeFn -Html $wHtml }
        elseif ($wText.Trim()) { $wHtml = & $fromTextFn -Text $wText }
        else { $wHtml = '' }
        $st.Slots[4].Title = ''
        $st.Slots[4].Html  = $wHtml
        & $showSlot $st.Current
        & $setStatus '' $false
    }.GetNewClosure()

    $collect = {
        & $harvest
        $result = @{}
        $html = @()
        for ($n = 1; $n -le 4; $n++) {
            $slot = $st.Slots[$n - 1]
            $h    = [string]$slot.Html
            $result["AdditionalInfo${n}Label"] = [string]$slot.Title
            $result["AdditionalInfo${n}Html"]  = $h
            $result["AdditionalInfo$n"]        = if ($h) { & $toTextFn -Html $h } else { '' }
            $html += $h
        }
        $wh = [string]$st.Slots[4].Html
        $result['NewAccountWelcomeHtml'] = $wh
        $result['NewAccountWelcome']     = if ($wh) { & $toTextFn -Html $wh } else { '' }
        $html += $wh
        $imgs = @{}
        foreach ($id in (& $imageIdsFn -Html $html)) {
            if ($st.Images.ContainsKey($id)) { $imgs[$id] = $st.Images[$id] }
        }
        $result['AdditionalInfoImages'] = $imgs
        return $result
    }.GetNewClosure()

    & $paintButtons

    return [PSCustomObject]@{
        Load           = $load
        Collect        = $collect
        RefreshLibrary = $refreshLibrary
        SetStatus      = $setStatus
        ButtonX        = $btnX
        ButtonY        = $btnY
    }
}
#endregion

Export-ModuleMember -Function New-AdditionalInfoEditor
