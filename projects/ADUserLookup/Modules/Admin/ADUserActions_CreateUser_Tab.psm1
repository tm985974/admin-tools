#region -- ADUserActions.CreateUser.Tab.psm1 ----------------------------------
# Concern : Builds the Create New User panel (left column of the Account
#           Management tab).
#           Wires display name auto-build, logon name auto-build, phone
#           numeric-strip/format, Regen/Clear/Create button events.
#           All field references are written to $script:UA* scope variables
#           defined in ADUserActions.Banner.psm1.
# Load order: 39 - depends on ADUserActions.Banner (script scope),
#                            ADUserActions.PasswordGenerator (New-GeneratedPassword),
#                            ADUserActions.CreateUser.Account (Invoke-CreateUser),
#                            Services.AD.Reporting (New-StdButton, Set-Placeholder),
#                            Services.DomainDefaults.Config (Get-DomainDefaults),
#                            ADDirectory.Users.Load (Get-CachedUsers).
#             Soft dependency on Services.Mail.Batch [4e] (New-MailModeSelector)
#             for the Notification row - guarded with Get-Command, see below.
# Split from: ADUserActions.psm1
#
# Layout - two columns:
#   Left  : Identity (First, Last, Display Prefix, Display Suffix,
#            Display Name RO/manual + "Use naming convention" checkbox,
#            Logon Prefix, Logon Suffix, Logon Name + "Use naming
#            convention" checkbox, UPN Suffix, Target OU RO)
#            Contact Mechanisms (Phone Number, Email)
#   Right : Job Details (Title, Dept, Company, Office, Manager)
#            Other (Description, Copy Groups From User [optional ComboBox])
#            Initial Password (pw box + Regen)
#            Status label, Create User + Clear buttons
#
# Contact Mechanisms:
#   Email is optional. When populated, ADUserActions.CreateUser.Account sets
#   it as the new account's EmailAddress (AD mail attribute) at creation time.
#   When left blank, Show-NotificationMailDialog itself now prompts for one
#   at send time and writes it back to AD (see Services.Mail.Dialog) - this
#   panel and Account.psm1 no longer need to special-case a blank Email
#   field.
#
# Notification selector ($script:UANewMailMode):
#   A New-MailModeSelector row (Admin Only / Individual / Both / None) sits
#   below both columns, full width, defaulted to 'Both' - Account.psm1 reads
#   it via Get-MailModeSelection when a user is created, so the admin always
#   gets a copy unless they actively pick something else (matches the old
#   implicit CC-the-admin behavior this replaces). Guarded with Get-Command
#   like every other optional cross-module control in this app - if
#   Services.Mail.Batch isn't loaded, $script:UANewMailMode simply stays
#   $null and Get-MailModeSelection's own $null-safe fallback applies.
#
# Display Name formula (7 patterns, selected per-domain on Tools > Domain
# Defaults - DisplayNamePattern):
#   AccountOnly            = Account Name
#   PrefixAccount          = Display Prefix + Account Name
#   PrefixAccountSuffix    = Display Prefix + Account Name + Display Suffix
#   AccountSuffix          = Account Name + Display Suffix
#   LastFirst              = Last, First
#   PrefixLastFirst        = Display Prefix + Last, First
#   PrefixLastFirstSuffix  = Display Prefix + Last, First + Display Suffix  (default)
#   "Account Name" in the first four patterns means the LIVE current text of
#   the Account/Logon Name field below - so Display Name always reflects
#   whatever that field currently holds, whether auto-built or manually
#   overridden. A trailing Display Suffix is always joined with a single
#   space; a leading Display Prefix is concatenated directly (the admin's
#   own Prefix text is expected to carry any trailing separator it needs,
#   e.g. "ADM-", the same way Display Suffix already carries its own
#   bracketing, e.g. "(IPCS)").
#
# Account Name formula (3 patterns, selected per-domain - AccountNamePattern):
#   LastInitial              = LastSlug + FirstInitial                (default)
#   PrefixLastInitial        = Logon Prefix + LastSlug + FirstInitial
#   PrefixLastInitialSuffix  = Logon Prefix + LastSlug + FirstInitial + Logon Suffix
#   Unlike the pre-existing behaviour, Logon Prefix/Suffix are baked directly
#   INTO this field's text when the selected pattern calls for them, rather
#   than being applied invisibly at account-creation time. This is why
#   Invoke-ValidateCreateUser no longer appends Logon Suffix itself, and
#   Invoke-CreateUser no longer prepends Logon Prefix itself (see those two
#   modules' own Changes notes) - the field is now the single source of
#   truth for the assembled SAM base, eliminating the risk of a pattern that
#   already includes the prefix/suffix getting it applied a second time.
#   The Logon Prefix / Logon Suffix textboxes remain independently editable
#   per-user overrides that feed the pattern builder - they are simply not
#   re-concatenated onto the field's own text a second time regardless of
#   which pattern is selected.
#
# UPN formula: (Account Name field's current text) + UPN Suffix
#
# Naming-convention checkboxes ("Use naming convention"):
#   Display Name and Account Name each have their own checkbox
#   ($script:UAChkDisplayAuto / $script:UAChkAccountAuto), default checked.
#   Checked  - the field rebuilds from the domain's configured pattern on
#              every relevant keystroke (First/Last/Display Prefix/Display
#              Suffix for Display Name; First/Last/Logon Prefix/Logon Suffix
#              for Account Name) and is shown read-only/greyed, matching the
#              existing Target OU field's visual treatment, so it's obvious
#              at a glance the value is machine-generated.
#   Unchecked - the field becomes a normal white editable textbox, stops
#              rebuilding on keystrokes, and the operator can type anything
#              (for the rare case the domain's convention doesn't fit a
#              particular account). Re-checking snaps the field straight
#              back to the pattern-derived value - this is a genuine
#              reversible toggle, not a one-way lock.
#   This replaces the old Logon Name-only behaviour, where typing directly
#   into the Logon Name field permanently latched it into manual mode for
#   the rest of the session ($script:UALogonManual, now retired) with no way
#   back to auto without clearing the whole form. Display Name previously
#   had NO manual-override path at all (hardcoded ReadOnly) - this is a new
#   capability for that field, not an extension of an existing one.
#
# Defaults seeded at build time, from Get-DomainDefaults at panel
# construction (Target OU is the one exception - see "Target OU wiring"
# below, it starts blank and is resolved on the first Add_Enter instead):
#   Display Prefix = this domain's saved DisplayPrefix (blank if unconfigured)
#   Display Suffix = this domain's saved DisplaySuffix (blank if unconfigured)
#   Logon Prefix   = this domain's saved LogonPrefix (blank if unconfigured)
#   Logon Suffix   = this domain's saved LogonSuffix (blank if unconfigured)
#   UPN Suffix     = this domain's saved UpnSuffix if set, else
#                     @<current AD domain FQDN> (Get-ADDomain .DNSRoot) as a
#                     last resort so the field is never blank on a
#                     reachable, unconfigured domain
#   $script:UADisplayPattern / $script:UAAccountPattern - plain (non-UI)
#     script variables holding this domain's saved DisplayNamePattern /
#     AccountNamePattern keys. There is no picker for these on THIS panel -
#     the convention itself is configured once per domain on Tools > Domain
#     Defaults; this panel only consumes it. Always re-read fresh (never
#     tracked against a "still matches" comparison, since there is no
#     textbox here the operator could have manually edited) on both the
#     initial build and every Update-CreateUserDomainDefaults / Add_Enter
#     refresh.
#
# Live refresh - "still matches last auto-applied default" tracking:
#   Each of Display Prefix / Display Suffix / Logon Prefix / Logon Suffix /
#   UPN Suffix has a companion $script:UALast*Default variable (set at
#   build time / first Add_Enter, and kept current by
#   Update-CreateUserDomainDefaults). On every refresh, a field is
#   overwritten with the newly saved value if it is EITHER blank OR still
#   equal to what that tracker says was last auto-applied; otherwise it is
#   left alone, on the assumption the operator typed something deliberate.
#   The trackers themselves are then updated to the new value regardless -
#   so a domain that already has a saved default (a common case, not just
#   the initially-unconfigured one) still picks up a later change instead of
#   silently getting stuck the moment it stops being blank. Clear/post-
#   Create restores each field from its tracker rather than the original
#   build-time value, for the same reason. $script:UADisplayPattern /
#   $script:UAAccountPattern have no such tracker (see above) - they are
#   simply always overwritten with the latest saved value, and if the
#   corresponding "Use naming convention" checkbox is currently checked, the
#   affected field is rebuilt immediately so the change is visible without
#   needing a keystroke in First/Last to trigger it.
#
# PS 5.1 closure fix:
#   All shared scriptblocks promoted to $script: scope so they resolve
#   correctly from inside Add_TextChanged / Add_KeyDown / Add_CheckedChanged
#   child scopes.
#
# Clear on success:
#   $script:UAClearCreateFields - shared scriptblock used by both the Clear
#   button and the post-Create-User success path. Clears all input fields,
#   restores defaults (including the domain's saved prefixes/suffixes), and
#   resets both naming-convention checkboxes back to checked (auto) so a
#   freshly cleared form always starts in the machine-generated state.
#   The Target OU field is intentionally preserved so the operator can
#   create multiple users into the same OU without re-picking.
#   Invoke-CreateUser sets $script:UACreateSucceeded = $true on success.
#   The Create button checks this flag on return and fires the shared clear.
#
# Paste Import hooks (ADUserActions.CreateUser.PasteQueue, soft dependency):
#   - $script:UABuildAccountName uses $script:UAPasteAccountBase (the
#     business-domain account name of the loaded queue record) in place of
#     LastSlug + FirstInitial when it is non-blank after normalisation. The
#     domain's AccountNamePattern still applies Logon Prefix/Suffix.
#   - $script:UAClearCreateFields resets $script:UAPasteAccountBase and
#     $script:UAPasteLoadedActive, so a cleared form never reuses a pasted
#     base and the queue can tell a manual create from a batch create.
#   - Create User success path: Get-PasteCarryOverValues BEFORE the shared
#     clear, Invoke-PasteQueueAdvance -Snapshot AFTER it. Both guarded with
#     Get-Command; no-op when the Paste Import module is not loaded.
#
# Reset on tab leave (Reset-CreateUserPanelState):
#   ADUserActions.Register-UserActionsTab calls Reset-CreateUserPanelState
#   whenever the operator switches away from the Account Management tab.
#   - $script:UACrStatus ("Created: <sam>" etc.) returns to the default
#     "Fields marked * are required." text.
#   - Copy Groups From is reloaded from the Directory tab's user cache
#     (Get-CachedUsers - already kept current by Add-CachedUser /
#     Remove-CachedUser), so deleted users drop out and newly created users
#     appear. Previously the list was filled once per session and never
#     refreshed. The current selection is kept when that user still exists,
#     otherwise it resets to blank. If the cache is empty the existing list
#     is left as-is (no repeat full-domain AD query on every tab switch).
#   - -ClearForm runs the shared clear first. The registrar passes it only
#     when a Paste Import record was loaded in the form; a user being typed
#     in by hand is kept.
#   Clone User is unaffected: Set-CloneUserSource runs after this tab has
#   already been left (the clone menu lives on the Users tab).
#endregion

#region -- Build-CreateUserPanel ----------------------------------------------
function Build-CreateUserPanel {
    <#
    .SYNOPSIS
        Constructs the Create New User panel inside the provided parent control.
        Returns the panel border control so the caller can size/position it.
    #>
    param(
        [System.Windows.Forms.Control]$Parent,
        [int]$X, [int]$Y, [int]$W, [int]$H
    )

    $F_UI   = New-Object System.Drawing.Font('Segoe UI', 9)
    $F_UI_B = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $F_SEC  = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $HDR_H  = 25

    # Column geometry
    $COL_GAP = 8
    $HALF_W  = [int](($W - 2 - $COL_GAP) / 2)
    $LW      = 128
    $PAD_F   = 6
    $FW      = $HALF_W - $LW - $PAD_F - 4

    # Left column x positions
    $L_LX = $PAD_F
    $L_FX = $PAD_F + $LW

    # Right column x positions
    $R_X  = $HALF_W + $COL_GAP
    $R_LX = $R_X + $PAD_F
    $R_FX = $R_X + $PAD_F + $LW

    # Column widths (for section header scoping)
    $L_COL_W = $HALF_W
    $R_COL_W = $W - 2 - $HALF_W - $COL_GAP

    # Row heights
    $ROW_H  = 28
    $CHK_H  = 20
    $SEC_H  = 26

    # ---- Resolve AD defaults ------------------------------------------------
    $defaultUPN = ''
    try {
        $adDomain   = Get-ADDomain -ErrorAction Stop
        $defaultUPN = '@' + $adDomain.DNSRoot
    } catch { }

    # ---- Resolve this domain's saved defaults (Tools > Domain Defaults) ----
    # Blank/zero-value object if unconfigured or the config module isn't
    # loaded - every field below already tolerates a blank string.
    $domDefaults = $null
    if ($script:UAContext -and $script:UAContext.Domain -and (Get-Command Get-DomainDefaults -ErrorAction SilentlyContinue)) {
        try { $domDefaults = Get-DomainDefaults -Domain $script:UAContext.Domain } catch { }
    }
    $defaultDisplayPrefix = if ($domDefaults) { [string]$domDefaults.DisplayPrefix } else { '' }
    $defaultDisplaySuffix = if ($domDefaults) { [string]$domDefaults.DisplaySuffix } else { '' }
    $defaultLogonPrefix   = if ($domDefaults) { [string]$domDefaults.LogonPrefix }   else { '' }
    $defaultLogonSuffix   = if ($domDefaults) { [string]$domDefaults.LogonSuffix }   else { '' }

    # Naming-convention pattern keys - plain script variables, no UI picker
    # on this panel (see module header). Defaults match
    # Services.DomainDefaults.Config's New-BlankDomainDefaults exactly, so a
    # domain with no config module loaded still behaves like the pre-
    # existing hardcoded formulas.
    $script:UADisplayPattern = if ($domDefaults -and [string]$domDefaults.DisplayNamePattern) { [string]$domDefaults.DisplayNamePattern } else { 'PrefixLastFirstSuffix' }
    $script:UAAccountPattern = if ($domDefaults -and [string]$domDefaults.AccountNamePattern) { [string]$domDefaults.AccountNamePattern } else { 'LastInitial' }

    # UPN Suffix: this domain's saved UpnSuffix wins if set; otherwise fall
    # back to the live AD domain lookup so the field still has a sensible
    # value on a reachable domain that hasn't been configured yet.
    if ($domDefaults -and [string]$domDefaults.UpnSuffix) {
        $defaultUPN = [string]$domDefaults.UpnSuffix
    }

    # "Last known auto-applied default" trackers, one per PLAIN TEXTBOX that
    # seeds from Domain Defaults. Used by Update-CreateUserDomainDefaults
    # (and the Target OU Add_Enter logic below) to tell "operator hasn't
    # touched this field since we last set it" apart from "operator
    # deliberately typed something else" - see the "Target OU wiring" note
    # and Update-CreateUserDomainDefaults's own doc comment for why a plain
    # "only overwrite if blank" check isn't enough on its own.
    # $script:UADisplayPattern / $script:UAAccountPattern have no tracker of
    # their own - there is no textbox for them on this panel, so they are
    # always simply overwritten with the latest saved value (see header).
    $script:UALastDisplayPrefixDefault = $defaultDisplayPrefix
    $script:UALastDisplaySuffixDefault = $defaultDisplaySuffix
    $script:UALastLogonPrefixDefault   = $defaultLogonPrefix
    $script:UALastLogonSuffixDefault   = $defaultLogonSuffix
    $script:UALastUpnSuffixDefault     = $defaultUPN
    $script:UALastTargetOUDefault      = ''

    # ---- Scriptblock helpers ------------------------------------------------

    $addSecHdr = {
        param([System.Windows.Forms.Control]$P, [string]$Text, [int]$Y2, [int]$ColX, [int]$ColW)
        $lbl           = New-Object System.Windows.Forms.Label
        $lbl.Text      = $Text
        $lbl.Location  = New-Object System.Drawing.Point(($ColX + 2), $Y2)
        $lbl.Size      = New-Object System.Drawing.Size(($ColW - 4), 18)
        $lbl.Font      = $F_SEC
        $lbl.ForeColor = [System.Drawing.Color]::FromArgb(0, 80, 160)
        $P.Controls.Add($lbl)
        $div           = New-Object System.Windows.Forms.Panel
        $div.Location  = New-Object System.Drawing.Point(($ColX + 2), ($Y2 + 20))
        $div.Size      = New-Object System.Drawing.Size(($ColW - 4), 1)
        $div.BackColor = [System.Drawing.Color]::FromArgb(180, 200, 230)
        $P.Controls.Add($div)
    }

    $addField = {
        param(
            [System.Windows.Forms.Control]$P,
            [string]$Label,
            [int]$LX, [int]$FX, [int]$FW2, [int]$Y2,
            [bool]$RO = $false,
            [string]$Val = ''
        )
        $lbl            = New-Object System.Windows.Forms.Label
        $lbl.Text       = $Label
        $lbl.Location   = New-Object System.Drawing.Point($LX, ($Y2 + 4))
        $lbl.Size       = New-Object System.Drawing.Size($LW, 20)
        $lbl.Font       = $F_UI
        $lbl.ForeColor  = [System.Drawing.Color]::FromArgb(60, 60, 60)
        $P.Controls.Add($lbl)
        $tb             = New-Object System.Windows.Forms.TextBox
        $tb.Location    = New-Object System.Drawing.Point($FX, $Y2)
        $tb.Size        = New-Object System.Drawing.Size($FW2, 24)
        $tb.Font        = $F_UI
        $tb.BorderStyle = 'FixedSingle'
        $tb.Text        = $Val
        if ($RO) {
            $tb.ReadOnly  = $true
            $tb.BackColor = [System.Drawing.Color]::FromArgb(245, 245, 245)
            $tb.ForeColor = [System.Drawing.Color]::FromArgb(80, 80, 80)
        } else {
            $tb.BackColor = [System.Drawing.Color]::White
        }
        $P.Controls.Add($tb)
        return $tb
    }

    # "Use naming convention" checkbox, placed under the field it governs.
    # Styling of the governed field itself (ReadOnly + grey vs. editable +
    # white) is applied separately at build time and again on
    # Add_CheckedChanged - this helper only creates the checkbox control.
    $addAutoCheckbox = {
        param([System.Windows.Forms.Control]$P, [int]$FX, [int]$FW2, [int]$Y2)
        $chk           = New-Object System.Windows.Forms.CheckBox
        $chk.Text      = 'Use naming convention'
        $chk.Location  = New-Object System.Drawing.Point($FX, $Y2)
        $chk.Size      = New-Object System.Drawing.Size($FW2, $CHK_H)
        $chk.Font      = $F_UI
        $chk.Checked   = $true
        $P.Controls.Add($chk)
        return $chk
    }

    # ---- Outer border panel -------------------------------------------------
    $border           = New-Object System.Windows.Forms.Panel
    $border.Location  = New-Object System.Drawing.Point($X, $Y)
    $border.Size      = New-Object System.Drawing.Size($W, $H)
    $border.BackColor = [System.Drawing.Color]::FromArgb(160, 160, 160)
    $Parent.Controls.Add($border)

    # ---- Panel header bar ---------------------------------------------------
    $hdr              = New-Object System.Windows.Forms.Panel
    $hdr.Location     = New-Object System.Drawing.Point(1, 1)
    $hdr.Size         = New-Object System.Drawing.Size(($W - 2), $HDR_H)
    $hdr.BackColor    = [System.Drawing.Color]::FromArgb(210, 225, 245)
    $border.Controls.Add($hdr)

    $hdrLbl           = New-Object System.Windows.Forms.Label
    $hdrLbl.Text      = 'Create New User'
    $hdrLbl.Location  = New-Object System.Drawing.Point(4, 0)
    $hdrLbl.Size      = New-Object System.Drawing.Size(($W - 10), $HDR_H)
    $hdrLbl.Font      = $F_UI_B
    $hdrLbl.ForeColor = [System.Drawing.Color]::FromArgb(0, 80, 160)
    $hdrLbl.TextAlign = 'MiddleLeft'
    $hdr.Controls.Add($hdrLbl)

    # ---- Content panel ------------------------------------------------------
    $sec              = New-Object System.Windows.Forms.Panel
    $sec.Location     = New-Object System.Drawing.Point(1, ($HDR_H + 1))
    $sec.Size         = New-Object System.Drawing.Size(($W - 2), ($H - $HDR_H - 2))
    $sec.BackColor    = [System.Drawing.Color]::White
    $border.Controls.Add($sec)

    # Vertical column divider - added FIRST so it sits behind all field controls
    $divV           = New-Object System.Windows.Forms.Panel
    $divV.Location  = New-Object System.Drawing.Point(($HALF_W + 3), 4)
    $divV.Size      = New-Object System.Drawing.Size(1, ($H - $HDR_H - 10))
    $divV.BackColor = [System.Drawing.Color]::FromArgb(210, 220, 235)
    $sec.Controls.Add($divV)

    # =========================================================================
    # LEFT COLUMN
    # =========================================================================
    $ly = 6

    & $addSecHdr $sec 'Identity' $ly 0 $L_COL_W
    $ly += $SEC_H

    $script:UANewFirst       = & $addField $sec 'First Name *'    $L_LX $L_FX $FW $ly
    $ly += $ROW_H

    $script:UANewLast        = & $addField $sec 'Last Name *'     $L_LX $L_FX $FW $ly
    $ly += $ROW_H

    $script:UANewDisplayPrefix = & $addField $sec 'Display Prefix' $L_LX $L_FX $FW $ly $false $defaultDisplayPrefix
    $ly += $ROW_H

    $script:UANewDnSuffix    = & $addField $sec 'Display Suffix'  $L_LX $L_FX $FW $ly $false $defaultDisplaySuffix
    $ly += $ROW_H

    $script:UANewDisplay     = & $addField $sec 'Display Name'    $L_LX $L_FX $FW $ly $true
    $ly += $ROW_H

    $script:UAChkDisplayAuto = & $addAutoCheckbox $sec $L_FX $FW $ly
    $ly += $CHK_H

    $script:UANewLogonPrefix = & $addField $sec 'Logon Prefix'    $L_LX $L_FX $FW $ly $false $defaultLogonPrefix
    $ly += $ROW_H

    $script:UANewLogonSuffix = & $addField $sec 'Logon Suffix'    $L_LX $L_FX $FW $ly $false $defaultLogonSuffix
    $ly += $ROW_H

    $script:UANewLogon       = & $addField $sec 'Logon Name *'    $L_LX $L_FX $FW $ly $true
    $ly += $ROW_H

    # v1.2.0 - Account Name Case (Domain Defaults). The field converts letters
    # as they are typed or pasted (CharacterCasing), the auto-builder below
    # applies the same rule, and the current text is converted whenever the
    # rule is (re)applied - so the name shown is the name created.
    # ADUserActions.CreateUser.Account enforces it again at creation.
    $script:UASetAccountCase = {
        param([string]$Case)
        $script:UAAccountCase = if (@('Upper', 'Lower') -contains $Case) { $Case } else { 'AsTyped' }
        if (-not $script:UANewLogon) { return }
        switch ($script:UAAccountCase) {
            'Upper' {
                $script:UANewLogon.CharacterCasing = [System.Windows.Forms.CharacterCasing]::Upper
                $script:UANewLogon.Text = $script:UANewLogon.Text.ToUpperInvariant()
            }
            'Lower' {
                $script:UANewLogon.CharacterCasing = [System.Windows.Forms.CharacterCasing]::Lower
                $script:UANewLogon.Text = $script:UANewLogon.Text.ToLowerInvariant()
            }
            default {
                $script:UANewLogon.CharacterCasing = [System.Windows.Forms.CharacterCasing]::Normal
            }
        }
    }
    & $script:UASetAccountCase $(if ($domDefaults) { [string]$domDefaults.AccountNameCase } else { '' })

    $script:UAChkAccountAuto = & $addAutoCheckbox $sec $L_FX $FW $ly
    $ly += $CHK_H

    # Logon hint - live full SAM / UPN preview
    $script:UALogonHint           = New-Object System.Windows.Forms.Label
    $script:UALogonHint.Text      = ''
    $script:UALogonHint.Location  = New-Object System.Drawing.Point($L_FX, $ly)
    $script:UALogonHint.Size      = New-Object System.Drawing.Size($FW, 16)
    $script:UALogonHint.Font      = New-Object System.Drawing.Font('Segoe UI', 7.5)
    $script:UALogonHint.ForeColor = [System.Drawing.Color]::FromArgb(0, 80, 160)
    $sec.Controls.Add($script:UALogonHint)
    $ly += 18

    $script:UANewUPN         = & $addField $sec 'UPN Suffix *'    $L_LX $L_FX $FW $ly $false $defaultUPN
    $ly += $ROW_H

    # Target OU - read-only textbox + Browse button.
    $BTN_BROWSE_W = 76
    $OU_BOX_W     = $FW - $BTN_BROWSE_W - 4

    $lOULbl           = New-Object System.Windows.Forms.Label
    $lOULbl.Text      = 'Target OU *'
    $lOULbl.Location  = New-Object System.Drawing.Point($L_LX, ($ly + 4))
    $lOULbl.Size      = New-Object System.Drawing.Size($LW, 20)
    $lOULbl.Font      = $F_UI
    $lOULbl.ForeColor = [System.Drawing.Color]::FromArgb(60, 60, 60)
    $sec.Controls.Add($lOULbl)

    $script:UANewOUBox             = New-Object System.Windows.Forms.TextBox
    $script:UANewOUBox.Location    = New-Object System.Drawing.Point($L_FX, $ly)
    $script:UANewOUBox.Size        = New-Object System.Drawing.Size($OU_BOX_W, 24)
    $script:UANewOUBox.Font        = $F_UI
    $script:UANewOUBox.BorderStyle = 'FixedSingle'
    $script:UANewOUBox.ReadOnly    = $true
    $script:UANewOUBox.BackColor   = [System.Drawing.Color]::FromArgb(245, 245, 245)
    $script:UANewOUBox.ForeColor   = [System.Drawing.Color]::FromArgb(80, 80, 80)
    $sec.Controls.Add($script:UANewOUBox)

    $btnBrowseOU = New-StdButton -Text 'Browse...' -X ($L_FX + $OU_BOX_W + 4) -Y $ly -W $BTN_BROWSE_W -H 24 -Parent $sec
    $btnBrowseOU.Add_Click({
        if (Get-Command Show-OUPicker -ErrorAction SilentlyContinue) {
            $picked = Show-OUPicker -Context $script:UAContext
            if ($picked) {
                $script:UANewOUBox.Text  = $picked
                $script:UAOUHint.Visible = $false
            }
        }
    })
    $ly += $ROW_H

    # OU hint label - shown when no OU is selected yet
    $script:UAOUHint           = New-Object System.Windows.Forms.Label
    $script:UAOUHint.Text      = 'Click Browse to select an OU'
    $script:UAOUHint.Location  = New-Object System.Drawing.Point($L_FX, $ly)
    $script:UAOUHint.Size      = New-Object System.Drawing.Size($FW, 14)
    $script:UAOUHint.Font      = New-Object System.Drawing.Font('Segoe UI', 7.5)
    $script:UAOUHint.ForeColor = [System.Drawing.Color]::FromArgb(180, 80, 0)
    $sec.Controls.Add($script:UAOUHint)
    $ly += 16

    & $addSecHdr $sec 'Contact Mechanisms' $ly 0 $L_COL_W
    $ly += $SEC_H

    $script:UANewPhone       = & $addField $sec 'Phone Number'    $L_LX $L_FX $FW $ly
    $ly += $ROW_H

    $script:UANewEmail       = & $addField $sec 'Email'           $L_LX $L_FX $FW $ly
    $ly += $ROW_H

    # =========================================================================
    # RIGHT COLUMN
    # =========================================================================
    $ry = 6

    & $addSecHdr $sec 'Job Details' $ry $R_X $R_COL_W
    $ry += $SEC_H

    $script:UANewTitle   = & $addField $sec 'Job Title'           $R_LX $R_FX $FW $ry
    $ry += $ROW_H

    $script:UANewDept    = & $addField $sec 'Department'          $R_LX $R_FX $FW $ry
    $ry += $ROW_H

    $script:UANewCompany = & $addField $sec 'Company'             $R_LX $R_FX $FW $ry
    $ry += $ROW_H

    $script:UANewOffice  = & $addField $sec 'Office'              $R_LX $R_FX $FW $ry
    $ry += $ROW_H

    $script:UANewManager = & $addField $sec 'Manager (SAM)'       $R_LX $R_FX $FW $ry
    $ry += $ROW_H

    & $addSecHdr $sec 'Other' $ry $R_X $R_COL_W
    $ry += $SEC_H

    $script:UANewDesc    = & $addField $sec 'Description'         $R_LX $R_FX $FW $ry
    $ry += $ROW_H

    # ---- Copy Groups From User (optional ComboBox) --------------------------
    $lCGFU           = New-Object System.Windows.Forms.Label
    $lCGFU.Text      = 'Copy Groups From'
    $lCGFU.Location  = New-Object System.Drawing.Point($R_LX, ($ry + 4))
    $lCGFU.Size      = New-Object System.Drawing.Size($LW, 20)
    $lCGFU.Font      = $F_UI
    $lCGFU.ForeColor = [System.Drawing.Color]::FromArgb(60, 60, 60)
    $sec.Controls.Add($lCGFU)

    $script:UANewCopyGroupsFrom                = New-Object System.Windows.Forms.ComboBox
    $script:UANewCopyGroupsFrom.Location       = New-Object System.Drawing.Point($R_FX, $ry)
    $script:UANewCopyGroupsFrom.Size           = New-Object System.Drawing.Size($FW, 24)
    $script:UANewCopyGroupsFrom.Font           = $F_UI
    $script:UANewCopyGroupsFrom.DropDownStyle  = 'DropDown'
    $script:UANewCopyGroupsFrom.AutoCompleteMode   = 'SuggestAppend'
    $script:UANewCopyGroupsFrom.AutoCompleteSource = 'ListItems'
    $script:UANewCopyGroupsFrom.DropDownWidth  = [int]($FW * 1.6)
    $sec.Controls.Add($script:UANewCopyGroupsFrom)
    $ry += $ROW_H

    # Hint label beneath the combobox
    $lCGFUHint           = New-Object System.Windows.Forms.Label
    $lCGFUHint.Text      = 'Optional. Type to filter, then select a user to copy their groups.'
    $lCGFUHint.Location  = New-Object System.Drawing.Point($R_FX, $ry)
    $lCGFUHint.Size      = New-Object System.Drawing.Size($FW, 14)
    $lCGFUHint.Font      = New-Object System.Drawing.Font('Segoe UI', 7.5)
    $lCGFUHint.ForeColor = [System.Drawing.Color]::DimGray
    $sec.Controls.Add($lCGFUHint)
    $ry += 16

    & $addSecHdr $sec 'Initial Password' $ry $R_X $R_COL_W
    $ry += $SEC_H

    $PW_W                          = $FW + $LW - 88
    $script:UACrPwBox              = New-Object System.Windows.Forms.TextBox
    $script:UACrPwBox.Location     = New-Object System.Drawing.Point($R_X, $ry)
    $script:UACrPwBox.Size         = New-Object System.Drawing.Size($PW_W, 28)
    $script:UACrPwBox.Font         = New-Object System.Drawing.Font('Consolas', 10, [System.Drawing.FontStyle]::Bold)
    $script:UACrPwBox.ReadOnly     = $true
    $script:UACrPwBox.TextAlign    = 'Center'
    $script:UACrPwBox.BackColor    = [System.Drawing.Color]::White
    $script:UACrPwBox.BorderStyle  = 'FixedSingle'
    $script:UACrPwBox.Text         = New-GeneratedPassword
    $sec.Controls.Add($script:UACrPwBox)

    $btnRegenPw = New-StdButton -Text 'Regen' -X ($R_X + $PW_W + 4) -Y $ry -W 80 -H 28 -Parent $sec
    $ry += 36

    $script:UACrStatus             = New-Object System.Windows.Forms.Label
    $script:UACrStatus.Text        = 'Fields marked * are required.'
    $script:UACrStatus.Location    = New-Object System.Drawing.Point($R_X, $ry)
    $script:UACrStatus.Size        = New-Object System.Drawing.Size(($HALF_W - 8), 20)
    $script:UACrStatus.Font        = New-Object System.Drawing.Font('Segoe UI', 8)
    $script:UACrStatus.ForeColor   = [System.Drawing.Color]::DimGray
    $sec.Controls.Add($script:UACrStatus)
    $ry += 24

    $btnCreateUser  = New-StdButton -Text 'Create User' -X $R_X -Y $ry -W 110 -H 28 -Parent $sec
    $btnCreateUser.Font      = $F_UI_B

    $btnClearCreate = New-StdButton -Text 'Clear' -X ($R_X + 118) -Y $ry -W 72 -H 28 -Parent $sec

    # ---- Notification: Admin Only / Individual / Both / None ---------------
    # Full-width row below BOTH columns - Identity/Contact (left) runs
    # longer than Job Details/Other/Password (right), so this is placed
    # beneath the taller of the two rather than squeezed into either
    # column's own width. See module header for the default-'Both'
    # rationale and the $null-safe degrade when Services.Mail.Batch isn't
    # loaded.
    $script:UANewMailMode = $null
    if (Get-Command New-MailModeSelector -ErrorAction SilentlyContinue) {
        $NOTIFY_Y = 480
        $script:UANewMailMode = New-MailModeSelector -Parent $sec -X $L_LX -Y $NOTIFY_Y -DefaultMode 'Both'
    }

    # =========================================================================
    # LIVE WIRING
    # PS 5.1: all shared scriptblocks at $script: scope so Add_TextChanged /
    # Add_CheckedChanged child scopes can resolve them.
    # =========================================================================

    # Target OU is intentionally independent of the global OU tree selection
    # (see module header, "Target OU wiring") - no AfterSelect hook here.
    #
    # Resolved FRESH from Get-DomainDefaults on every Add_Enter, rather than
    # reusing the $defaultNewUserOU value captured once when this panel was
    # built (typically at app startup). Domain Defaults can be edited and
    # saved at any point during a running session (Tools > Domain Defaults),
    # and the admin may switch domains after this panel was built - a
    # build-time-only snapshot would keep showing a stale (often blank)
    # value in either case even though the JSON on disk is current. The two
    # naming-convention PATTERN KEYS are refreshed the same way, since they
    # can differ per domain and this panel has no picker of its own for them
    # (see module header).
    $Parent.Add_Enter({
        $curDefaultOU = ''
        if ($script:UAContext -and $script:UAContext.Domain -and
            (Get-Command Get-DomainDefaults -ErrorAction SilentlyContinue)) {
            try {
                $d = Get-DomainDefaults -Domain $script:UAContext.Domain
                $curDefaultOU = [string]$d.DefaultNewUserOU
                if ([string]$d.DisplayNamePattern) { $script:UADisplayPattern = [string]$d.DisplayNamePattern }
                if ([string]$d.AccountNamePattern)  { $script:UAAccountPattern = [string]$d.AccountNamePattern }
                if ($script:UASetAccountCase) { & $script:UASetAccountCase ([string]$d.AccountNameCase) }
            } catch { }
        }
        if ($curDefaultOU -and
            ($script:UANewOUBox.Text -eq '' -or $script:UANewOUBox.Text -eq $script:UALastTargetOUDefault)) {
            $script:UANewOUBox.Text = $curDefaultOU
        }
        if ($curDefaultOU) { $script:UALastTargetOUDefault = $curDefaultOU }
        $script:UAOUHint.Visible = ($script:UANewOUBox.Text -eq '')
        if ($script:UAChkAccountAuto.Checked) { & $script:UABuildAccountName }
        if ($script:UAChkDisplayAuto.Checked) { & $script:UABuildDisplay }

        if ($script:UANewCopyGroupsFrom -and $script:UANewCopyGroupsFrom.Items.Count -eq 0) {
            # Prefer the Directory tab's already-loaded user cache over a
            # second, redundant full-domain AD query. Falls back to AD only
            # if the cache is empty (e.g. Directory tab hasn't loaded yet).
            $cached = if (Get-Command Get-CachedUsers -ErrorAction SilentlyContinue) { @(Get-CachedUsers) } else { @() }
            if ($cached.Count -gt 0) {
                [void]$script:UANewCopyGroupsFrom.Items.Add('')
                foreach ($u in ($cached | Sort-Object { if ($_.DisplayName) { $_.DisplayName } else { $_.SamAccountName } })) {
                    $display = if ($u.DisplayName) { $u.DisplayName } else { $u.SamAccountName }
                    [void]$script:UANewCopyGroupsFrom.Items.Add("$display ($($u.SamAccountName))")
                }
                $script:UANewCopyGroupsFrom.SelectedIndex = 0
            } else {
                $srvParam = if ($script:UAContext -and $script:UAContext.TargetDC) {
                    @{ Server = $script:UAContext.TargetDC }
                } else { @{} }
                try {
                    $users = Get-ADUser -Filter * -Properties DisplayName @srvParam -ErrorAction Stop |
                        Sort-Object DisplayName
                    [void]$script:UANewCopyGroupsFrom.Items.Add('')
                    foreach ($u in $users) {
                        $display = if ($u.DisplayName) { $u.DisplayName } else { $u.SamAccountName }
                        [void]$script:UANewCopyGroupsFrom.Items.Add("$display ($($u.SamAccountName))")
                    }
                    $script:UANewCopyGroupsFrom.SelectedIndex = 0
                } catch {
                    [void]$script:UANewCopyGroupsFrom.Items.Add('(Failed to load users)')
                    $script:UANewCopyGroupsFrom.SelectedIndex = 0
                }
            }
        }
    })

    $script:UAOUHint.Visible = ($script:UANewOUBox.Text -eq '')

    # -- Account Name: pattern-driven, gated by "Use naming convention" -------
    # Bakes Logon Prefix/Suffix directly into the field's own text whenever
    # the selected AccountNamePattern calls for them (see module header for
    # why this replaces the old separate-prepend/append design). No-ops
    # entirely while $script:UAChkAccountAuto is unchecked, leaving whatever
    # the operator typed alone.
    $script:UABuildAccountName = {
        if (-not ($script:UAChkAccountAuto -and $script:UAChkAccountAuto.Checked)) { return }
        $fRaw = $script:UANewFirst.Text.Trim()
        $lRaw = $script:UANewLast.Text.Trim()
        $f    = [System.Text.RegularExpressions.Regex]::Replace(
                    $fRaw.Normalize([System.Text.NormalizationForm]::FormD).ToLower(),
                    '[^a-z0-9.\-_]', '')
        $l    = [System.Text.RegularExpressions.Regex]::Replace(
                    $lRaw.Normalize([System.Text.NormalizationForm]::FormD).ToLower(),
                    '[^a-z0-9.\-_]', '')
        $fi   = if ($f.Length -gt 0) { $f[0] } else { '' }
        $base = ($l + $fi) -replace '[^a-z0-9.\-_]', ''
        # Paste Import override - business-domain account name as the base
        if ($script:UAPasteAccountBase) {
            $pasteBase = [System.Text.RegularExpressions.Regex]::Replace(
                             ([string]$script:UAPasteAccountBase).Normalize([System.Text.NormalizationForm]::FormD).ToLower(),
                             '[^a-z0-9.\-_]', '')
            if ($pasteBase) { $base = $pasteBase }
        }
        if ($base.Length -gt 20) { $base = $base.Substring(0, 20) }
        $base = $base.ToUpper()

        $prefix = $script:UANewLogonPrefix.Text.Trim()
        $suffix = $script:UANewLogonSuffix.Text.Trim()
        $acct = switch ($script:UAAccountPattern) {
            'PrefixLastInitial'       { $prefix + $base }
            'PrefixLastInitialSuffix' { $prefix + $base + $suffix }
            default                   { $base }   # LastInitial
        }
        $script:UANewLogon.Text = switch ($script:UAAccountCase) {
            'Upper' { $acct.ToUpperInvariant() }
            'Lower' { $acct.ToLowerInvariant() }
            default { $acct }
        }
    }
    $script:UANewFirst.Add_TextChanged({       & $script:UABuildAccountName })
    $script:UANewLast.Add_TextChanged({        & $script:UABuildAccountName })
    $script:UANewLogonPrefix.Add_TextChanged({ & $script:UABuildAccountName })
    $script:UANewLogonSuffix.Add_TextChanged({ & $script:UABuildAccountName })

    # -- Display Name: pattern-driven, gated by "Use naming convention" -------
    # The account-name-based patterns read the Account Name field's CURRENT
    # text live, whatever put it there (auto-build above, or a manual
    # override) - so Display Name always tracks what's actually on screen
    # rather than re-deriving First/Last itself for those patterns.
    $script:UABuildDisplay = {
        if (-not ($script:UAChkDisplayAuto -and $script:UAChkDisplayAuto.Checked)) { return }
        $f    = $script:UANewFirst.Text.Trim()
        $l    = $script:UANewLast.Text.Trim()
        $acct = $script:UANewLogon.Text.Trim()
        $dPfx = $script:UANewDisplayPrefix.Text.Trim()
        $dSfx = $script:UANewDnSuffix.Text.Trim()
        $lastFirst = if ($l -and $f) { "$l, $f" } elseif ($l) { $l } elseif ($f) { $f } else { '' }
        $dn = switch ($script:UADisplayPattern) {
            'AccountOnly'           { $acct }
            'PrefixAccount'         { $dPfx + $acct }
            'PrefixAccountSuffix'   { $dPfx + $acct + $(if ($dSfx) { " $dSfx" } else { '' }) }
            'AccountSuffix'         { $acct + $(if ($dSfx) { " $dSfx" } else { '' }) }
            'LastFirst'             { $lastFirst }
            'PrefixLastFirst'       { $dPfx + $lastFirst }
            'PrefixLastFirstSuffix' { $dPfx + $lastFirst + $(if ($dSfx) { " $dSfx" } else { '' }) }
            default                 { $lastFirst }
        }
        $script:UANewDisplay.Text = $dn
    }
    $script:UANewFirst.Add_TextChanged({          & $script:UABuildDisplay })
    $script:UANewLast.Add_TextChanged({           & $script:UABuildDisplay })
    $script:UANewDisplayPrefix.Add_TextChanged({  & $script:UABuildDisplay })
    $script:UANewDnSuffix.Add_TextChanged({       & $script:UABuildDisplay })
    # Cascades automatically whenever Account Name's text actually changes
    # (auto-build above, or a manual edit while its own checkbox is
    # unchecked) - covers the account-name-based Display patterns without
    # needing a second direct hook on Logon Prefix/Suffix here.
    $script:UANewLogon.Add_TextChanged({          & $script:UABuildDisplay })

    & $script:UABuildAccountName
    & $script:UABuildDisplay

    # -- Naming-convention checkboxes: toggle style + rebuild on check -------
    $applyAccountAutoStyle = {
        if ($script:UAChkAccountAuto.Checked) {
            $script:UANewLogon.ReadOnly  = $true
            $script:UANewLogon.BackColor = [System.Drawing.Color]::FromArgb(245, 245, 245)
            $script:UANewLogon.ForeColor = [System.Drawing.Color]::FromArgb(80, 80, 80)
        } else {
            $script:UANewLogon.ReadOnly  = $false
            $script:UANewLogon.BackColor = [System.Drawing.Color]::White
            $script:UANewLogon.ForeColor = [System.Drawing.Color]::Black
        }
    }
    $applyDisplayAutoStyle = {
        if ($script:UAChkDisplayAuto.Checked) {
            $script:UANewDisplay.ReadOnly  = $true
            $script:UANewDisplay.BackColor = [System.Drawing.Color]::FromArgb(245, 245, 245)
            $script:UANewDisplay.ForeColor = [System.Drawing.Color]::FromArgb(80, 80, 80)
        } else {
            $script:UANewDisplay.ReadOnly  = $false
            $script:UANewDisplay.BackColor = [System.Drawing.Color]::White
            $script:UANewDisplay.ForeColor = [System.Drawing.Color]::Black
        }
    }
    & $applyAccountAutoStyle
    & $applyDisplayAutoStyle

    $script:UAChkAccountAuto.Add_CheckedChanged({
        & $applyAccountAutoStyle
        if ($script:UAChkAccountAuto.Checked) { & $script:UABuildAccountName }
    }.GetNewClosure())
    $script:UAChkDisplayAuto.Add_CheckedChanged({
        & $applyDisplayAutoStyle
        if ($script:UAChkDisplayAuto.Checked) { & $script:UABuildDisplay }
    }.GetNewClosure())

    # -- Logon hint: SAM = Account Name field as-is; UPN = SAM + UPNSuffix ---
    # Account Name's own text already includes Logon Prefix/Suffix whenever
    # the selected pattern calls for them (see UABuildAccountName above), so
    # this hint no longer re-concatenates them itself.
    $script:UABuildLogonHint = {
        $sam = $script:UANewLogon.Text.Trim()
        $upn = $script:UANewUPN.Text.Trim()
        $script:UALogonHint.Text = if ($sam) {
            "SAM: $sam    UPN: $sam$upn"
        } else { '' }
    }
    $script:UANewLogon.Add_TextChanged({ & $script:UABuildLogonHint })
    $script:UANewUPN.Add_TextChanged({   & $script:UABuildLogonHint })
    & $script:UABuildLogonHint

    # -- Phone: strip non-digits, format, re-entry guard ---------------------
    $script:UAPhoneUpdating = $false
    $script:UAFormatPhone = {
        param([string]$digits)
        if ($digits.Length -eq 10) {
            return "($($digits.Substring(0,3))) $($digits.Substring(3,3))-$($digits.Substring(6,4))"
        }
        if ($digits.Length -eq 11 -and $digits[0] -eq '1') {
            return "+1 ($($digits.Substring(1,3))) $($digits.Substring(4,3))-$($digits.Substring(7,4))"
        }
        return $digits
    }
    $script:UANewPhone.Add_TextChanged({
        if ($script:UAPhoneUpdating) { return }
        $script:UAPhoneUpdating = $true
        $raw   = $script:UANewPhone.Text
        $clean = $raw -replace '[^\d]', ''
        $fmt   = if ($clean.Length -gt 0) { & $script:UAFormatPhone $clean } else { '' }
        if ($script:UANewPhone.Text -ne $fmt) {
            $script:UANewPhone.Text          = $fmt
            $script:UANewPhone.SelectionStart = $fmt.Length
        }
        $script:UAPhoneUpdating = $false
    })

    # -- Shared clear scriptblock ---------------------------------------------
    $script:UAClearCreateFields = {
        foreach ($tb in @(
            $script:UANewFirst,          $script:UANewLast,
            $script:UANewDisplayPrefix,  $script:UANewDnSuffix,
            $script:UANewDisplay,        $script:UANewLogonPrefix,
            $script:UANewLogonSuffix,    $script:UANewLogon,
            $script:UANewUPN,            $script:UANewPhone,
            $script:UANewEmail,
            $script:UANewTitle,          $script:UANewDept,         $script:UANewCompany,
            $script:UANewOffice,         $script:UANewManager,      $script:UANewDesc
        )) {
            if ($tb) { $tb.Text = '' }
        }
        if ($script:UANewCopyGroupsFrom -and $script:UANewCopyGroupsFrom.Items.Count -gt 0) {
            $script:UANewCopyGroupsFrom.SelectedIndex = 0
        }
        # Drop any Paste Import logon base / loaded-record flag BEFORE the
        # rebuild calls below, so a cleared form uses the plain convention.
        $script:UAPasteAccountBase  = ''
        $script:UAPasteLoadedActive = $false
        # Reset both naming-convention checkboxes to checked (auto) BEFORE
        # restoring the seed textboxes, so the two rebuild calls below run
        # in auto mode and populate Display/Logon Name from the restored
        # prefixes/suffixes rather than leaving them blank.
        $script:UAChkAccountAuto.Checked = $true
        $script:UAChkDisplayAuto.Checked = $true
        $script:UANewDisplayPrefix.Text  = $script:UALastDisplayPrefixDefault
        $script:UANewDnSuffix.Text       = $script:UALastDisplaySuffixDefault
        $script:UANewLogonPrefix.Text    = $script:UALastLogonPrefixDefault
        $script:UANewLogonSuffix.Text    = $script:UALastLogonSuffixDefault
        $script:UANewUPN.Text            = $script:UALastUpnSuffixDefault
        & $script:UABuildAccountName
        & $script:UABuildDisplay
        $script:UALogonHint.Text      = ''
        $script:UACrPwBox.Text        = New-GeneratedPassword
        $script:UACrStatus.Text       = 'Fields marked * are required.'
        $script:UACrStatus.ForeColor  = [System.Drawing.Color]::DimGray
    }

    # -- Button wiring --------------------------------------------------------
    $btnRegenPw.Add_Click({ $script:UACrPwBox.Text = New-GeneratedPassword })

    $btnClearCreate.Add_Click({ & $script:UAClearCreateFields })

    $btnCreateUser.Add_Click({
        $script:UACreateSucceeded = $false
        Invoke-CreateUser
        if ($script:UACreateSucceeded) {
            # Paste Import: snapshot BEFORE the clear, advance AFTER it
            $pasteSnap = $null
            if (Get-Command Get-PasteCarryOverValues -ErrorAction SilentlyContinue) {
                $pasteSnap = Get-PasteCarryOverValues
            }
            & $script:UAClearCreateFields
            $script:UACreateSucceeded = $false
            if ($pasteSnap -and (Get-Command Invoke-PasteQueueAdvance -ErrorAction SilentlyContinue)) {
                Invoke-PasteQueueAdvance -Snapshot $pasteSnap
            }
        }
    })

    return $border
}
#endregion

#region -- Update-CreateUserDomainDefaults -------------------------------------
function Update-CreateUserDomainDefaults {
    <#
    .SYNOPSIS
        Re-applies this domain's saved Domain Defaults (Tools > Domain
        Defaults) to the already-built Create New User panel, without
        requiring the panel to be rebuilt or the tab to be re-entered.
        Called by the Domain Defaults tab's Save button so a save takes
        effect immediately in the same running session.
    .DESCRIPTION
        Display Prefix, Display Suffix, Logon Prefix, Logon Suffix, UPN
        Suffix, and Target OU are each overwritten with the newly saved
        value if the field is EITHER currently blank OR still holds exactly
        the value this function (or the build-time seed, or Add_Enter for
        Target OU) last auto-applied - tracked per field via
        $script:UALast*Default. If the operator has typed something else
        into the field since then, it is left alone.
        A plain "only overwrite if blank" rule (the original implementation)
        does not actually achieve a live refresh in the common case: once a
        domain has ANY saved default, the field is never blank again, so a
        later change to that same default would silently stop taking effect
        here even though nothing was manually edited. Tracking the last
        auto-applied value fixes that while still never clobbering a
        deliberate manual edit.
        $script:UADisplayPattern / $script:UAAccountPattern have no tracker
        (there is no textbox for them on this panel - see module header) and
        are always overwritten with the newly saved key. If the
        corresponding "Use naming convention" checkbox is currently checked,
        the affected field (Display Name and/or Account Name) is rebuilt
        immediately afterward so a pattern change is visible without
        needing a keystroke in First/Last to trigger it.
        UPN Suffix falls back to the live AD domain lookup if the domain
        still has no saved UpnSuffix, same as the build-time seed logic.
        Safe no-op if the panel hasn't been built yet, or
        Services.DomainDefaults.Config isn't loaded.
    #>
    if (-not $script:UANewDnSuffix) { return }
    if (-not $script:UAContext -or -not $script:UAContext.Domain) { return }
    if (-not (Get-Command Get-DomainDefaults -ErrorAction SilentlyContinue)) { return }

    $d = $null
    try { $d = Get-DomainDefaults -Domain $script:UAContext.Domain } catch { }
    if (-not $d) { return }

    $newDisplayPrefix = [string]$d.DisplayPrefix
    if ($script:UANewDisplayPrefix.Text -eq '' -or $script:UANewDisplayPrefix.Text -eq $script:UALastDisplayPrefixDefault) {
        $script:UANewDisplayPrefix.Text = $newDisplayPrefix
    }
    $script:UALastDisplayPrefixDefault = $newDisplayPrefix

    $newDisplaySuffix = [string]$d.DisplaySuffix
    if ($script:UANewDnSuffix.Text -eq '' -or $script:UANewDnSuffix.Text -eq $script:UALastDisplaySuffixDefault) {
        $script:UANewDnSuffix.Text = $newDisplaySuffix
    }
    $script:UALastDisplaySuffixDefault = $newDisplaySuffix

    $newLogonPrefix = [string]$d.LogonPrefix
    if ($script:UANewLogonPrefix.Text -eq '' -or $script:UANewLogonPrefix.Text -eq $script:UALastLogonPrefixDefault) {
        $script:UANewLogonPrefix.Text = $newLogonPrefix
    }
    $script:UALastLogonPrefixDefault = $newLogonPrefix

    $newLogonSuffix = [string]$d.LogonSuffix
    if ($script:UANewLogonSuffix.Text -eq '' -or $script:UANewLogonSuffix.Text -eq $script:UALastLogonSuffixDefault) {
        $script:UANewLogonSuffix.Text = $newLogonSuffix
    }
    $script:UALastLogonSuffixDefault = $newLogonSuffix

    if ([string]$d.DisplayNamePattern) { $script:UADisplayPattern = [string]$d.DisplayNamePattern }
    if ([string]$d.AccountNamePattern) { $script:UAAccountPattern = [string]$d.AccountNamePattern }
    if ($script:UASetAccountCase) { & $script:UASetAccountCase ([string]$d.AccountNameCase) }

    $newUpn = $null
    if ($d.UpnSuffix) {
        $newUpn = [string]$d.UpnSuffix
    } else {
        try {
            $adDomain = Get-ADDomain -ErrorAction Stop
            $newUpn   = '@' + $adDomain.DNSRoot
        } catch { }
    }
    if ($newUpn) {
        if ($script:UANewUPN.Text -eq '' -or $script:UANewUPN.Text -eq $script:UALastUpnSuffixDefault) {
            $script:UANewUPN.Text = $newUpn
        }
        $script:UALastUpnSuffixDefault = $newUpn
    }

    $newOU = [string]$d.DefaultNewUserOU
    if ($newOU) {
        if ($script:UANewOUBox.Text -eq '' -or $script:UANewOUBox.Text -eq $script:UALastTargetOUDefault) {
            $script:UANewOUBox.Text  = $newOU
            if ($script:UAOUHint) { $script:UAOUHint.Visible = $false }
        }
        $script:UALastTargetOUDefault = $newOU
    }

    # Rebuild the derived fields now, so a pattern change (or a
    # prefix/suffix change that a tracked textbox just picked up above) is
    # visible immediately rather than waiting for the next keystroke -
    # only while each field's own checkbox is still in auto mode.
    if ($script:UAChkAccountAuto -and $script:UAChkAccountAuto.Checked) { & $script:UABuildAccountName }
    if ($script:UAChkDisplayAuto -and $script:UAChkDisplayAuto.Checked) { & $script:UABuildDisplay }
}
#endregion

#region -- Set-CloneUserSource ------------------------------------------------
# Prefills the Create User form for a "Clone User" action invoked from the
# Directory user right-click menu. Sets only the Target OU and the Copy Groups
# From selection - all identity/logon/password fields are intentionally left
# blank for the operator to fill in. The downstream create routine
# (Build-CreateUserPanel submit -> New-CreateUserAccount) already extracts the
# SAM from the trailing "(SAM)" token of the combobox and copies that user's
# group memberships, so no further wiring is required here.
#
# Call order from the menu handler: switch to the Account Management tab first
# (its Add_Enter lazily loads the combobox on first visit), THEN call this.
function Set-CloneUserSource {
    param(
        [string]$Sam,
        [string]$Display = '',
        [string]$SourceOU = ''
    )

    # Target OU - override whatever the tab's Add_Enter seeded from the
    # domain's saved default (or whatever was left over from a prior use).
    if ($script:UANewOUBox -and $SourceOU) {
        $script:UANewOUBox.Text = $SourceOU
        if ($script:UAOUHint) { $script:UAOUHint.Visible = $false }
    }

    # Copy Groups From - ensure the source-user list is loaded (so the dropdown
    # works and the correct entry can be selected by index). Relying on the
    # tab's Add_Enter to load it is unreliable here because the prefill can run
    # before the tab is shown; and leaving the box as free text with AutoComplete
    # enabled leaves a non-functional dropdown. Loading here is idempotent - the
    # tab's Add_Enter guards on Items.Count -eq 0 and will skip if already loaded.
    # Prefers the Directory tab's cached user list over a redundant full-domain
    # AD query, same as the tab's own Add_Enter above.
    if ($script:UANewCopyGroupsFrom -and $Sam) {
        if ($script:UANewCopyGroupsFrom.Items.Count -eq 0) {
            $cached = if (Get-Command Get-CachedUsers -ErrorAction SilentlyContinue) { @(Get-CachedUsers) } else { @() }
            if ($cached.Count -gt 0) {
                [void]$script:UANewCopyGroupsFrom.Items.Add('')
                foreach ($u in ($cached | Sort-Object { if ($_.DisplayName) { $_.DisplayName } else { $_.SamAccountName } })) {
                    $d = if ($u.DisplayName) { $u.DisplayName } else { $u.SamAccountName }
                    [void]$script:UANewCopyGroupsFrom.Items.Add("$d ($($u.SamAccountName))")
                }
            } else {
                $srvParam = if ($script:UAContext -and $script:UAContext.TargetDC) {
                    @{ Server = $script:UAContext.TargetDC }
                } else { @{} }
                try {
                    $users = Get-ADUser -Filter * -Properties DisplayName @srvParam -ErrorAction Stop |
                        Sort-Object DisplayName
                    [void]$script:UANewCopyGroupsFrom.Items.Add('')
                    foreach ($u in $users) {
                        $d = if ($u.DisplayName) { $u.DisplayName } else { $u.SamAccountName }
                        [void]$script:UANewCopyGroupsFrom.Items.Add("$d ($($u.SamAccountName))")
                    }
                } catch { }
            }
        }

        $idx = -1
        for ($i = 0; $i -lt $script:UANewCopyGroupsFrom.Items.Count; $i++) {
            $item = [string]$script:UANewCopyGroupsFrom.Items[$i]
            if ($item -match '\(([^)]+)\)\s*$' -and $Matches[1].Trim() -eq $Sam) {
                $idx = $i; break
            }
        }
        if ($idx -ge 0) {
            $script:UANewCopyGroupsFrom.SelectedIndex = $idx
        } else {
            $disp = if ($Display) { $Display } else { $Sam }
            $script:UANewCopyGroupsFrom.Text = "$disp ($Sam)"
        }
    }
}
#endregion

#region -- Reset-CreateUserPanelState ------------------------------------------
function Reset-CreateUserPanelState {
    <#
    .SYNOPSIS
        Clears transient state on the Create New User panel when the operator
        leaves the Account Management tab. See module header.
    .PARAMETER ClearForm
        Also run the shared clear (all input fields, defaults restored, new
        password). Passed only when a Paste Import record was loaded.
    #>
    param([switch]$ClearForm)

    if (-not $script:UACrStatus) { return }

    if ($ClearForm -and $script:UAClearCreateFields) { & $script:UAClearCreateFields }

    $script:UACrStatus.Text      = 'Fields marked * are required.'
    $script:UACrStatus.ForeColor = [System.Drawing.Color]::DimGray

    # Reload Copy Groups From from the current user cache, keeping the
    # selection only if that user still exists.
    if ($script:UANewCopyGroupsFrom -and (Get-Command Get-CachedUsers -ErrorAction SilentlyContinue)) {
        $cached = @(Get-CachedUsers)
        if ($cached.Count -gt 0) {
            $prevText = [string]$script:UANewCopyGroupsFrom.Text
            $script:UANewCopyGroupsFrom.BeginUpdate()
            $script:UANewCopyGroupsFrom.Items.Clear()
            [void]$script:UANewCopyGroupsFrom.Items.Add('')
            foreach ($u in ($cached | Sort-Object { if ($_.DisplayName) { $_.DisplayName } else { $_.SamAccountName } })) {
                $display = if ($u.DisplayName) { $u.DisplayName } else { $u.SamAccountName }
                [void]$script:UANewCopyGroupsFrom.Items.Add("$display ($($u.SamAccountName))")
            }
            $script:UANewCopyGroupsFrom.EndUpdate()
            $idx = -1
            if ($prevText) { $idx = $script:UANewCopyGroupsFrom.Items.IndexOf($prevText) }
            if ($idx -ge 0) {
                $script:UANewCopyGroupsFrom.SelectedIndex = $idx
            } else {
                $script:UANewCopyGroupsFrom.SelectedIndex = 0
            }
        }
    }
}
#endregion

Export-ModuleMember -Function Build-CreateUserPanel, Set-CloneUserSource, Update-CreateUserDomainDefaults, Reset-CreateUserPanelState
