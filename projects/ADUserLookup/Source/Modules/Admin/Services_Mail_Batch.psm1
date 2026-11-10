#region -- Services.Mail.Batch.psm1 --------------------------------------------
# Concern : Shared plumbing for bulk-capable actions that need to choose HOW
#           their notification mail goes out, not just whether it does:
#             New-MailModeSelector    - builds a row of 4 mutually-exclusive
#               radio buttons (Admin Only / Individual / Both / None) that
#               any bulk action's tab/dialog can drop in.
#             Get-MailModeSelection   - reads which of the 4 is currently
#               checked, as a plain string.
#             Send-ADBatchNotificationMail - the orchestrator. Given a mode
#               plus an admin-summary body and a list of per-recipient
#               bodies, fires whichever of the two sends the mode calls for.
#
#           Why this exists as its OWN module rather than growing
#           Services.Mail.Send or Services.Mail.Dialog: those two own
#           single-recipient transport and the single-popup UI respectively.
#           Multi-recipient MODE branching (admin-only vs individual vs both
#           vs none, across an arbitrary number of recipients) is a distinct
#           responsibility, so it gets its own file per this project's "one
#           clear responsibility per module" rule.
#
#           The core safety rule this module exists to enforce: the ADMIN
#           summary and the INDIVIDUAL recipient sends are ALWAYS built from
#           two separate bodies, supplied separately by the caller
#           (AdminBodyText vs each Recipient's own BodyText). This module
#           never merges them, never derives one from the other, and never
#           lets a recipient's send see another recipient's Details/BodyText
#           - each -Recipients entry is sent in total isolation via its own
#           Show-NotificationMailDialog call. Callers are responsible for
#           actually keeping the two bodies scoped correctly (i.e. an
#           individual recipient's BodyText must describe only THAT
#           recipient's own outcome, never the whole batch's) - this module
#           only enforces that the SEND paths never cross-contaminate what
#           it's given.
#
#           Send-ADBatchNotificationMail reuses Show-NotificationMailDialog
#           for BOTH the admin summary (-AdminOnly, unchanged from every
#           existing caller) and each individual recipient (normal -Sam
#           mode, one popup per recipient, sequentially) - this preserves
#           the existing "nothing goes out without a human reviewing/editing
#           it first" property that every other mail path in this app
#           already has, at the cost of one modal per recipient for large
#           batches. A scalable non-modal batch-send path (a single review
#           grid, one call to Send-ADNotificationMail per row) is a
#           reasonable future addition if batch sizes make this tedious in
#           practice, but is NOT this module's job today.
#
# Load order: 4e - depends on Services.Mail.Dialog (Show-NotificationMailDialog)
#             [4c]. Soft dependency, guarded with Get-Command like every other
#             optional cross-module call in this app - Send-ADBatchNotification
#             Mail simply sends nothing if that module isn't loaded, same
#             non-fatal contract as Services.Mail.Send/Dialog themselves.
#             None of the functions in this module build any WinForms UI of
#             their own beyond the 4 RadioButton controls New-MailModeSelector
#             creates, so - unlike the tab-builder modules that call INTO this
#             one - nothing here runs inside a .GetNewClosure() block, and the
#             documented cross-module bare-name-in-a-closure bug (see
#             ADTools.DomainDefaults.Tab / ADDirectory.Menus for the extensive
#             write-up) does not apply to any call made FROM inside this
#             module. It DOES still apply to callers of this module's own
#             functions from inside their own closures - every bulk-action tab
#             that uses New-MailModeSelector / Get-MailModeSelection /
#             Send-ADBatchNotificationMail from inside a button-click closure
#             must still capture them via ${function:Name} first, same as any
#             other cross-module function used that way.
# New module: created alongside the first two consumers (Add Users to Groups,
#             Bulk Onboard) to let a bulk action's notification mail go to the
#             admin only (today's default and behavior for every existing
#             caller), to each affected user individually, to both, or to
#             neither - admin's choice, per run, defaulting to Admin Only so
#             no existing behavior changes unless the admin actively picks
#             something else.
# Changes   : v1.6.0 - individual recipient sends pass -NoCc (the admin is
#             no longer CC'd on emails carrying a password - the admin
#             summary is their copy) and -Welcome when the recipient entry
#             has Welcome = $true (new-account emails).
#endregion

#region -- New-MailModeSelector -------------------------------------------------
function New-MailModeSelector {
    <#
    .SYNOPSIS
        Builds a "Notification:" label plus 4 mutually-exclusive radio
        buttons - Admin Only (summary) / Individual / Both / None - on
        $Parent at ($X, $Y). Mutual exclusivity is WinForms' native behavior
        for RadioButtons sharing an immediate parent container - no
        GroupBox needed (this project doesn't use GroupBox).
    .PARAMETER Parent
        Control to add the label and radio buttons to.
    .PARAMETER X
        Left edge of the "Notification:" label.
    .PARAMETER Y
        Top edge of the whole row (label and all 4 radio buttons share this Y).
    .PARAMETER DefaultMode
        Which radio starts checked: 'AdminOnly' (default - matches every
        existing caller's prior hardcoded behavior), 'Individual', 'Both',
        or 'None'.
    .OUTPUTS
        PSCustomObject with the 4 RadioButton controls (RbAdminOnly /
        RbIndividual / RbBoth / RbNone). Pass this to Get-MailModeSelection
        at send time to read which one is checked. The row occupies
        approximately 502px of horizontal space from $X (92px label + 410px
        of radio buttons) - callers should reserve at least that much width.
    #>
    param(
        [System.Windows.Forms.Control]$Parent,
        [int]$X,
        [int]$Y,
        [ValidateSet('AdminOnly', 'Individual', 'Both', 'None')]
        [string]$DefaultMode = 'AdminOnly'
    )

    $F_UI = New-Object System.Drawing.Font('Segoe UI', 9)
    $RB_H = 22

    $lbl           = New-Object System.Windows.Forms.Label
    $lbl.Text      = 'Notification:'
    $lbl.Location  = New-Object System.Drawing.Point($X, ($Y + 2))
    $lbl.Size      = New-Object System.Drawing.Size(88, 20)
    $lbl.Font      = $F_UI
    $lbl.ForeColor = [System.Drawing.Color]::FromArgb(60, 60, 60)
    $Parent.Controls.Add($lbl)

    $rowX = $X + 90

    $rbAdmin           = New-Object System.Windows.Forms.RadioButton
    $rbAdmin.Text      = 'Admin Only (summary)'
    $rbAdmin.Location  = New-Object System.Drawing.Point($rowX, $Y)
    $rbAdmin.Size      = New-Object System.Drawing.Size(170, $RB_H)
    $rbAdmin.Font      = $F_UI
    $Parent.Controls.Add($rbAdmin)

    $rbIndiv           = New-Object System.Windows.Forms.RadioButton
    $rbIndiv.Text      = 'Individual'
    $rbIndiv.Location  = New-Object System.Drawing.Point(($rowX + 170), $Y)
    $rbIndiv.Size      = New-Object System.Drawing.Size(90, $RB_H)
    $rbIndiv.Font      = $F_UI
    $Parent.Controls.Add($rbIndiv)

    $rbBoth           = New-Object System.Windows.Forms.RadioButton
    $rbBoth.Text      = 'Both'
    $rbBoth.Location  = New-Object System.Drawing.Point(($rowX + 260), $Y)
    $rbBoth.Size      = New-Object System.Drawing.Size(75, $RB_H)
    $rbBoth.Font      = $F_UI
    $Parent.Controls.Add($rbBoth)

    $rbNone           = New-Object System.Windows.Forms.RadioButton
    $rbNone.Text      = 'None'
    $rbNone.Location  = New-Object System.Drawing.Point(($rowX + 335), $Y)
    $rbNone.Size      = New-Object System.Drawing.Size(75, $RB_H)
    $rbNone.Font      = $F_UI
    $Parent.Controls.Add($rbNone)

    switch ($DefaultMode) {
        'Individual' { $rbIndiv.Checked = $true }
        'Both'       { $rbBoth.Checked  = $true }
        'None'       { $rbNone.Checked  = $true }
        default      { $rbAdmin.Checked = $true }
    }

    return [PSCustomObject]@{
        RbAdminOnly  = $rbAdmin
        RbIndividual = $rbIndiv
        RbBoth       = $rbBoth
        RbNone       = $rbNone
    }
}
#endregion

#region -- Get-MailModeSelection -------------------------------------------------
function Get-MailModeSelection {
    <#
    .SYNOPSIS
        Reads which of the 4 radio buttons on a New-MailModeSelector result
        is currently checked. Never throws - a $null or malformed Selector
        falls back to 'AdminOnly' (the safe default), same as if the
        selector had never been shown at all.
    .OUTPUTS
        [string] One of: 'AdminOnly', 'Individual', 'Both', 'None'.
    #>
    param([PSCustomObject]$Selector)

    if (-not $Selector) { return 'AdminOnly' }
    if ($Selector.PSObject.Properties.Name -contains 'RbIndividual' -and $Selector.RbIndividual -and $Selector.RbIndividual.Checked) { return 'Individual' }
    if ($Selector.PSObject.Properties.Name -contains 'RbBoth'       -and $Selector.RbBoth       -and $Selector.RbBoth.Checked)       { return 'Both' }
    if ($Selector.PSObject.Properties.Name -contains 'RbNone'       -and $Selector.RbNone       -and $Selector.RbNone.Checked)       { return 'None' }
    return 'AdminOnly'
}
#endregion

#region -- Send-ADBatchNotificationMail ------------------------------------------
function Send-ADBatchNotificationMail {
    <#
    .SYNOPSIS
        Orchestrates a bulk action's notification mail according to $Mode:
            AdminOnly  - one summary popup to the admin only (unchanged
                         behavior from every existing bulk-action caller).
            Individual - one popup per entry in -Recipients, addressed to
                         that recipient (Show-NotificationMailDialog's
                         normal -Sam mode - resolves that user's own mail
                         attribute, CCs the admin, same as a single-item
                         action already does today).
            Both       - both of the above.
            None       - nothing. No popups at all.
        Never throws - a missing Services.Mail.Dialog module, a $null
        Context, or an empty -Recipients list are all handled by simply
        sending less, never by erroring.
    .PARAMETER Mode
        'AdminOnly', 'Individual', 'Both', or 'None' - typically the output
        of Get-MailModeSelection.
    .PARAMETER Context
        Shared context object, passed through unchanged to every
        Show-NotificationMailDialog call this function makes.
    .PARAMETER ActionTitle
        Short banner subtitle used for every popup this call opens (both
        the admin summary and every individual recipient popup).
    .PARAMETER AdminSubject
        Subject line for the admin summary popup only. Ignored if Mode is
        'Individual' or 'None'.
    .PARAMETER AdminDetails
        Ordered dictionary for the admin summary popup's detail table.
        Ignored if Mode is 'Individual' or 'None'. This is the FULL batch's
        detail - never trimmed or reused for individual sends.
    .PARAMETER AdminBodyText
        Full admin summary body text (whole-batch detail, recovery blocks,
        etc.) - exactly what every bulk caller already builds today.
        Ignored if Mode is 'Individual' or 'None'.
    .PARAMETER Recipients
        Array of PSCustomObject, one per person who should get their OWN
        individual popup. Each entry needs:
            Sam      [string] - SamAccountName; resolves that recipient's
                     mail attribute the same way a normal Show-
                     NotificationMailDialog call already does.
            Subject  [string] - that recipient's own subject line.
            Details  - that recipient's OWN detail table only - must not
                     include any other recipient's information.
            BodyText [string] - that recipient's OWN message body only -
                     must not include any other recipient's information.
            Welcome  [bool]   - optional (v1.6.0): new-account email, adds
                     the domain's welcome message (Show-NotificationMail
                     Dialog -Welcome).
        Individual emails never CC the admin (v1.6.0, -NoCc) - the admin
        summary above is the admin's copy, without the sensitive details.
        Entries missing a Sam are skipped. Ignored if Mode is 'AdminOnly'
        or 'None'.
    #>
    param(
        [Parameter(Mandatory)]
        [ValidateSet('AdminOnly', 'Individual', 'Both', 'None')]
        [string]$Mode,
        [PSCustomObject]$Context,
        [string]$ActionTitle = 'Account Action',
        [string]$AdminSubject = 'AD Batch Notification',
        $AdminDetails = $null,
        [string]$AdminBodyText = '',
        [PSCustomObject[]]$Recipients = @()
    )

    if ($Mode -eq 'None') { return }
    if (-not (Get-Command Show-NotificationMailDialog -ErrorAction SilentlyContinue)) { return }

    if ($Mode -eq 'AdminOnly' -or $Mode -eq 'Both') {
        Show-NotificationMailDialog `
            -Context     $Context `
            -Sam         '' `
            -ActionTitle $ActionTitle `
            -Subject     $AdminSubject `
            -Details     $AdminDetails `
            -BodyText    $AdminBodyText `
            -AdminOnly
    }

    if ($Mode -eq 'Individual' -or $Mode -eq 'Both') {
        foreach ($r in @($Recipients)) {
            if (-not $r) { continue }
            if ($r.PSObject.Properties.Name -notcontains 'Sam' -or -not $r.Sam) { continue }
            $recipSubject  = if ($r.PSObject.Properties.Name -contains 'Subject'  -and $r.Subject)  { $r.Subject }  else { $ActionTitle }
            $recipDetails  = if ($r.PSObject.Properties.Name -contains 'Details') { $r.Details } else { $null }
            $recipBodyText = if ($r.PSObject.Properties.Name -contains 'BodyText' -and $r.BodyText) { $r.BodyText } else { '' }
            $recipWelcome  = ($r.PSObject.Properties.Name -contains 'Welcome' -and [bool]$r.Welcome)

            Show-NotificationMailDialog `
                -Context     $Context `
                -Sam         $r.Sam `
                -ActionTitle $ActionTitle `
                -Subject     $recipSubject `
                -Details     $recipDetails `
                -BodyText    $recipBodyText `
                -NoCc `
                -Welcome:$recipWelcome
        }
    }
}
#endregion

Export-ModuleMember -Function New-MailModeSelector, Get-MailModeSelection, Send-ADBatchNotificationMail
