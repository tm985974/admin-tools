#region -- Services.DomainDefaults.Config.psm1 --------------------------------
# Concern : Single source of truth for per-domain default settings, backed by
#           a JSON config file under .\Config\DomainDefaults.json, keyed by
#           domain name. Mirrors the Services.PasswordWordLists pattern
#           (Get-PwConfigPath / Get-PasswordWordLists / Set-PasswordWordLists)
#           for a config file that lives outside AD itself.
#           Get-DomainDefaults          - returns the settings for one domain
#             (all-blank defaults if that domain has no saved entry yet).
#           Set-DomainDefaults          - saves/overwrites one domain's entry.
#           Get-DomainDefaultConfigNames - lists every domain currently saved,
#             for populating the Domain Defaults tab's combo box.
# Load order: 4d - no dependencies on other AD-Admin modules beyond
#             $script:ConfigDir/$script:RootDir (set in _AD-Admin.ps1's
#             bootstrap region, which runs before module dot-sourcing). Must
#             load before ADTools.DomainDefaults.Tab (#125a), which calls
#             all three exported functions.
# New module: created to move several settings that were previously hardcoded
#             directly in _AD-Admin.ps1's $script:Context block (SmtpServer,
#             MailFrom) or in ADUserActions.CreateUser.Tab (the '(IPCS)' /
#             '_IPCS' suffix defaults) into a per-domain, editable, persisted
#             config - so switching domains (or handing this off to someone
#             else's domain) no longer means editing code. Consumed by
#             _AD-Admin.ps1 (mail settings), ADUserActions.CreateUser.Tab
#             (suffixes/home drive/default OU), ADUserActions.Offboard.Tab
#             (Disabled OU), ADTools.BulkOnboard.Tab (default OU), and the
#             Users/Groups/Computers filter "as I type" toggles
#             (ADDirectory.Register-DirectoryTab, ADComputers.Connectivity.Tab)
#             for their initial checked state. All consumers only READ via
#             Get-DomainDefaults; Set-DomainDefaults is called exclusively
#             from the Domain Defaults tab's Save button - normal use of the
#             app (toggling a filter checkbox, editing a Create User OU,
#             etc.) never writes back to this file.
# Changes   : v1.2.1 - Added SavedUtc (ISO 8601 UTC, e.g. 2026-10-10T04:12:00Z),
#             stamped by Set-DomainDefaults on every save. Settings travel
#             inside the EXE (ADUserLookup.cs "Portable settings"): when an
#             EXE carrying DomainDefaults.json opens on another machine, each
#             domain entry is compared by SavedUtc and the newer one wins, so
#             edits to different domains on different machines both survive.
#             Not shown or edited on the Domain Defaults tab.
#             v1.2.0 - Added LogMaxKB (int, default 5120, clamped 64 KB..1 GB)
#             - per-domain size limit for that domain's action log
#             (Logs\<DOMAIN>.log, Services.Logging - oldest entries are
#             dropped when it is exceeded). Added AccountNameCase ('AsTyped'
#             default, 'Upper', 'Lower') - letter case every NEW account name
#             in this domain must use. Added Convert-AccountNameCase, the one
#             helper every account-creation path calls (Create User, Bulk
#             Onboard) so the rule is enforced at creation, not only in the UI.
#             'AsTyped' leaves names exactly as built/typed (previous
#             behaviour). Existing accounts are never changed.
#             Added FilterAsYouType (bool, default $true) - per-domain
#             initial state for the "Filter as I type" checkboxes on the
#             Users, Groups, and Computers list filters.
#             Added LogonPrefix and UpnSuffix (both string, default '') -
#             per-domain seed values for the Create New User panel's Logon
#             Prefix and UPN Suffix fields (ADUserActions.CreateUser.Tab),
#             editable on the Domain Defaults tab (ADTools.DomainDefaults.Tab)
#             alongside the existing DisplaySuffix/LogonSuffix. Consistent
#             with those two: blank/unconfigured means the consumer falls
#             back to its own prior default rather than forcing an empty
#             value.
#             Added DisplayPrefix (string, default '') - per-domain seed for
#             a new Display Prefix field on the Create New User panel,
#             alongside the existing DisplaySuffix. Same blank-means-
#             unconfigured convention as every other string default here.
#             Added DisplayNamePattern and AccountNamePattern (both string
#             "pattern key" enums, NOT the literal example text - see the
#             key lists below) - per-domain naming-convention selection that
#             ADUserActions.CreateUser.Tab uses to decide how to assemble the
#             Display Name and Account/Logon Name fields from their
#             component parts (First/Last/DisplayPrefix/DisplaySuffix for
#             Display Name; Last/First/LogonPrefix/LogonSuffix for Account
#             Name) on every keystroke. Storing a short stable key rather
#             than the friendly combo-box label means relabeling the option
#             text later (ADTools.DomainDefaults.Tab) never invalidates
#             already-saved JSON.
#
#             DisplayNamePattern keys (7):
#               AccountOnly             - Account Name only
#               PrefixAccount           - DisplayPrefix + Account Name
#               PrefixAccountSuffix     - DisplayPrefix + Account Name + DisplaySuffix
#               AccountSuffix           - Account Name + DisplaySuffix
#               LastFirst               - Last, First
#               PrefixLastFirst         - DisplayPrefix + Last, First
#               PrefixLastFirstSuffix   - DisplayPrefix + Last, First + DisplaySuffix
#             Default: PrefixLastFirstSuffix - with DisplayPrefix blank (the
#             default for every domain that predates this field) this
#             reproduces the exact pre-existing hardcoded formula ("Last,
#             First" plus an optional trailing " DisplaySuffix"), so no
#             existing domain's Display Name output changes on upgrade.
#
#             AccountNamePattern keys (3):
#               LastInitial             - Last Name + First Initial
#               PrefixLastInitial       - LogonPrefix + Last Name + First Initial
#               PrefixLastInitialSuffix - LogonPrefix + Last Name + First Initial + LogonSuffix
#             Default: LastInitial - reproduces the exact pre-existing
#             hardcoded formula (LastSlug + FirstInitial, with LogonPrefix/
#             LogonSuffix applied separately at assembly time rather than
#             baked into the field), so no existing domain's Account Name
#             field content changes on upgrade. LogonPrefix/LogonSuffix
#             remain valid, editable fields regardless of which pattern is
#             selected - they are simply not concatenated into the Account
#             Name field's own text unless the selected pattern calls for it.
#
#             Added AdditionalInfo1 / AdditionalInfo2 / AdditionalInfo3 /
#             AdditionalInfo4 (all string, default '') - four free-text,
#             per-domain "reusable snippet" fields (e.g. a support contact
#             line, a password-policy reminder, an offboarding notice), each
#             editable on the Domain Defaults tab via a combo box that also
#             lists every non-blank value already saved for that SAME slot
#             number across every OTHER domain, so a snippet written once
#             can be reused/selected rather than retyped. NOT read by any
#             action module directly - Services.Mail.Dialog reads all four
#             for the connected domain at popup-build time and offers them
#             as optional, independently-checkable blocks the admin can
#             append to ANY outgoing action email's body before sending.
#             This is deliberately generic (four blank slots, no fixed
#             semantic meaning per slot) rather than per-action-message
#             overrides - the ~13 hardcoded action-opener strings scattered
#             across the various ADUserActions.*/ADDirectory.Context.* mail
#             call sites remain hardcoded by design (factual event
#             descriptions, not organisation-voice content, and already
#             editable per-send in the mail dialog's own Message box).
#
#             Added Get-DomainDefaultsAdditionalInfoOptions (see below) - the
#             read function backing each of the four combo boxes' pick-lists.
#
#             Added AdditionalInfo1Label / 2Label / 3Label / 4Label (all
#             string, default '') - a short, admin-defined title per slot
#             (e.g. "Support Contact") shown in the email as a bold heading
#             above that slot's content, and used as the checkbox's own
#             label text on the Send Notification popup (Services.Mail.
#             Dialog) instead of the generic "Additional Info N" - so the
#             admin is choosing by meaning, not by slot number. Left blank,
#             behavior is unchanged: no bold heading is added, and the
#             checkbox falls back to "Additional Info N". No new read
#             function needed - Get-DomainDefaults already returns these
#             alongside the content fields.
#
#             Added BulkDisplayNamePattern / BulkAccountNamePattern (both
#             string "pattern key" enums, default 'PrefixCustomSuffix') -
#             separate, Bulk-Onboard-only naming conventions, edited in a new
#             "Bulk Addition" section on ADTools.DomainDefaults.Tab. These are
#             DELIBERATELY independent of DisplayNamePattern/AccountNamePattern
#             above (which remain single-Create-User-only, unchanged) because
#             a bulk CSV row has no First/Last-derived "Last, First" or
#             "LastInitial" base to plug into those 7/3 patterns - instead
#             each row supplies its own DisplayCustomText / LogonCustomText
#             column, and these two patterns say how that text combines with
#             this domain's EXISTING DisplayPrefix/DisplaySuffix/LogonPrefix/
#             LogonSuffix (same fields New User Defaults already has - not
#             duplicated). Four keys, shared by both fields (the "base" is
#             always Custom Text, so there is no separate LastFirst-style
#             variant to include):
#               CustomOnly           - Custom Text alone, no prefix/suffix
#               PrefixCustom         - Prefix + Custom Text
#               CustomSuffix         - Custom Text + Suffix
#               PrefixCustomSuffix   - Prefix + Custom Text + Suffix (default)
#             Validated the same way as DisplayNamePattern/AccountNamePattern -
#             an unrecognised key falls back to the default rather than
#             breaking the Bulk Onboard preview builder at read time.
#
#             Added BulkDisplayNamePattern / BulkAccountNamePattern (both
#             string "pattern key" enums, default 'PrefixCustomSuffix') -
#             separate, Bulk-Onboard-only naming conventions, edited in a new
#             "Bulk Addition" section on ADTools.DomainDefaults.Tab. Each
#             offers the FULL superset of options: BulkDisplayNamePattern
#             accepts every DisplayNamePattern key (AccountOnly,
#             PrefixAccount, PrefixAccountSuffix, AccountSuffix, LastFirst,
#             PrefixLastFirst, PrefixLastFirstSuffix) PLUS 4 Bulk-only Custom
#             Text keys (CustomOnly, PrefixCustom, CustomSuffix,
#             PrefixCustomSuffix); BulkAccountNamePattern accepts every
#             AccountNamePattern key (LastInitial, PrefixLastInitial,
#             PrefixLastInitialSuffix) PLUS the same 4 Custom Text keys.
#             The classic keys are built from that CSV row's FirstName/
#             LastName columns using the EXACT SAME math as the single-
#             Create-User builders (see below); the 4 Custom keys are built
#             from that row's own DisplayCustomText/LogonCustomText column
#             instead - there is no per-row equivalent of First/Last for
#             those 4, by design (a bulk row may have no natural "base" that
#             fits any classic pattern, e.g. a shared/role account). All 11/7
#             keys still combine with this domain's EXISTING DisplayPrefix/
#             DisplaySuffix/LogonPrefix/LogonSuffix (same fields New User
#             Defaults already has - not duplicated).
#
#             Added Build-BulkAccountName and Build-BulkDisplayName (see
#             below) - the shared, pure functions behind these two patterns.
#             Two functions, not one, because the two builders need
#             genuinely different inputs and join rules (Account/Logon's
#             Suffix concatenates with NO separator; Display's Suffix gets a
#             leading space) - this exactly mirrors ADUserActions.
#             CreateUser.Tab's own two separate closures
#             ($script:UABuildAccountName / $script:UABuildDisplay), just as
#             pure functions instead of WinForms-control-reading closures.
#             Build-BulkDisplayName's AccountOnly-family patterns take the
#             row's ALREADY-COMPUTED Logon Name as an explicit -AccountBase
#             parameter (ADTools.BulkOnboard.Engine calls Build-
#             BulkAccountName first, then passes its result in) - this
#             mirrors the single-user flow exactly, where Display Name's
#             account-based patterns read the Account Name field's CURRENT
#             text rather than re-deriving First/Last themselves. Exported so
#             ADTools.BulkOnboard.Engine can call them when building each CSV
#             row's Display Name / Logon Name preview columns, without any
#             WinForms coupling (unlike DisplayNamePattern/AccountNamePattern's
#             equivalent math, which remains inline inside ADUserActions.
#             CreateUser.Tab's closures - that one stays exactly as it is,
#             the single-Create-User flow and its "Use naming convention"
#             checkboxes are intentionally untouched by this change).
#             v1.6.0 - added NewAccountWelcome / NewAccountWelcomeHtml (string,
#             default ''): the per-domain formatted welcome message added
#             to the top of every new-account email sent to the person
#             (Create User and Bulk Onboard), below a "Welcome <first
#             name>!" line. Edited on the Domain Defaults tab's New Account
#             Welcome button (ADTools.DomainDefaults.InfoEditor). Its
#             pictures share AdditionalInfoImages and count as referenced
#             when Set-DomainDefaults prunes that store.
#endregion

# Gray hint text the Domain Defaults tab's old Title boxes showed. Before
# v1.5.0 an untouched box could save this literal as the title; reads and
# saves treat it as blank.
$script:DDInfoTitleHint = 'Title (e.g. Support Contact)'

#region -- Get-DomainDefaultsConfigPath (private helper) -----------------------
function Get-DomainDefaultsConfigPath {
    # ADUserLookup v1.2.7: the settings live in the environment records
    # (Environment tab), not in a DomainDefaults.json of their own.
    if ($script:ADApp) { return [string]$script:ADApp.EnvironmentStorePath }
    return 'Settings\Environments.json'
}

function New-BlankDomainDefaults {
    [PSCustomObject]@{
        SmtpServer           = ''
        SmtpPort             = 25
        MailFrom             = ''
        DisplayPrefix        = ''
        DisplaySuffix        = ''
        DisplayNamePattern   = 'PrefixLastFirstSuffix'
        LogonPrefix          = ''
        LogonSuffix          = ''
        AccountNamePattern   = 'LastInitial'
        BulkDisplayNamePattern = 'PrefixCustomSuffix'
        BulkAccountNamePattern = 'PrefixCustomSuffix'
        UpnSuffix            = ''
        HomeDrive            = ''
        DefaultNewUserOU     = ''
        DefaultDisabledOU    = ''
        DefaultBulkOnboardOU = ''
        FilterAsYouType      = $true
        AdditionalInfo1      = ''
        AdditionalInfo2      = ''
        AdditionalInfo3      = ''
        AdditionalInfo4      = ''
        AdditionalInfo1Label = ''
        AdditionalInfo2Label = ''
        AdditionalInfo3Label = ''
        AdditionalInfo4Label = ''
        AdditionalInfo1Html  = ''
        AdditionalInfo2Html  = ''
        AdditionalInfo3Html  = ''
        AdditionalInfo4Html  = ''
        NewAccountWelcome     = ''
        NewAccountWelcomeHtml = ''
        LogMaxKB             = 5120
        AccountNameCase      = 'AsTyped'
        AdditionalInfoImages = [PSCustomObject]@{}
        SavedUtc             = ''
    }
}
#endregion

#region -- Get-AllDomainDefaultsRaw (private helper) ----------------------------
function Get-AllDomainDefaultsRaw {
    <#
    .SYNOPSIS
        Every environment's settings as one PSCustomObject whose property names
        are domain names - the shape every 1.6.1 caller expects.
    .DESCRIPTION
        ADUserLookup v1.2.7: read from the environment records (Environment
        tab) instead of DomainDefaults.json. The ACTIVE environment comes first
        and answers to its Domain AND to the connected domain, so whatever is
        selected on the Environment tab is what Create User, Offboard, Bulk
        Onboard, mail and the list filters use. Other environments answer to
        their Domain field. Never throws.
    #>
    $o = [ordered]@{}
    $app = $script:ADApp
    if (-not $app -or -not (Get-Command Read-AppEnvironmentStore -ErrorAction SilentlyContinue)) { return [PSCustomObject]@{} }
    try {
        $store  = Read-AppEnvironmentStore -App $app
        $active = [string]$app.ActiveName
        foreach ($r in $store.Environments) {
            if ([string]$r['Name'] -ine $active) { continue }
            $keys = @()
            if (Get-Command Get-ADSettingsKey -ErrorAction SilentlyContinue) { $keys += (Get-ADSettingsKey -App $app) }
            if ($script:ADContext -and $script:ADContext.Domain) { $keys += [string]$script:ADContext.Domain }
            foreach ($k in $keys) { if ($k -and -not $o.Contains($k)) { $o[$k] = [PSCustomObject]$r } }
        }
        foreach ($r in $store.Environments) {
            $d = ([string]$r['Domain']).Trim()
            if ($d -and -not $o.Contains($d)) { $o[$d] = [PSCustomObject]$r }
        }
    } catch { }
    return [PSCustomObject]$o
}

function Get-DomainDefaultConfigNames {
    <#
    .SYNOPSIS
        Returns every domain name currently saved in DomainDefaults.json,
        sorted. Used to populate the Domain Defaults tab's combo box.
    #>
    $all = Get-AllDomainDefaultsRaw
    return @($all.PSObject.Properties.Name | Sort-Object)
}
#endregion

#region -- Get-DomainDefaultsAdditionalInfoOptions ------------------------------
function Get-DomainDefaultsAdditionalInfoOptions {
    <#
    .SYNOPSIS
        Returns every distinct, non-blank AdditionalInfo<Slot> value saved
        for ANY domain in DomainDefaults.json, trimmed and sorted
        (case-insensitive). Used to populate the pick-list of the matching
        "Additional Info N" combo box on the Domain Defaults tab, so a
        snippet written once for one domain can be reused/selected on
        another rather than retyped. Deliberately scoped to a single slot
        number - AdditionalInfo1's saved values never appear in the
        AdditionalInfo2 combo's list, and vice versa, since the four slots
        are independent free-text fields with no shared meaning across
        slots.
    .PARAMETER Slot
        Which of the four fields to read: 1, 2, 3, or 4.
    .OUTPUTS
        [string[]] Distinct, trimmed, non-blank values. Empty array if none
        saved yet (or if the config file is empty/unreadable - never
        throws, matching every other read function in this module).
    #>
    param(
        [Parameter(Mandatory)]
        [ValidateSet(1, 2, 3, 4)]
        [int]$Slot
    )

    $propName = "AdditionalInfo$Slot"
    $all      = Get-AllDomainDefaultsRaw
    $values   = [System.Collections.Generic.List[string]]::new()

    foreach ($p in $all.PSObject.Properties) {
        $entry = $p.Value
        if (-not $entry) { continue }
        if ($entry.PSObject.Properties.Match($propName).Count -eq 0) { continue }
        $val = [string]$entry.$propName
        if ($val -and $val.Trim()) { $values.Add($val.Trim()) }
    }

    return @($values | Select-Object -Unique | Sort-Object -CaseSensitive:$false)
}
#endregion

#region -- Get-DomainDefaultsAdditionalInfoLibrary -----------------------------
function Get-DomainDefaultsAdditionalInfoLibrary {
    <#
    .SYNOPSIS
        Every titled Additional Info snippet saved on ANY domain, in ANY of
        the four slots, one entry per Title (case-insensitive). When two
        domains use the same Title with different content, the most
        recently saved domain's version wins. Feeds the Title dropdown on
        the Domain Defaults tab: picking a Title copies that snippet
        (text, formatting and pictures) into the slot being edited - a
        copy, so later edits never affect the domain it came from.
    .OUTPUTS
        PSCustomObject[] sorted by Title: Title, Html (formatted, may be ''
        for snippets saved before v1.5.0), Text (plain), Images (hashtable
        Id -> @{Type;Data} of the pictures this snippet uses), Domain, Slot.
        Never throws.
    #>
    $all    = Get-AllDomainDefaultsRaw
    $byKey  = @{}
    foreach ($p in $all.PSObject.Properties) {
        $entry = $p.Value
        if (-not $entry) { continue }
        $saved = [DateTime]::MinValue
        if ($entry.PSObject.Properties.Match('SavedUtc').Count -gt 0) {
            $tmp = [DateTime]::MinValue
            if ([DateTime]::TryParse([string]$entry.SavedUtc, [System.Globalization.CultureInfo]::InvariantCulture,
                    [System.Globalization.DateTimeStyles]::AdjustToUniversal, [ref]$tmp)) { $saved = $tmp }
        }
        $imgStore = $null
        if ($entry.PSObject.Properties.Match('AdditionalInfoImages').Count -gt 0) { $imgStore = $entry.AdditionalInfoImages }

        foreach ($n in 1..4) {
            $title = ''
            if ($entry.PSObject.Properties.Match("AdditionalInfo${n}Label").Count -gt 0) { $title = ([string]$entry."AdditionalInfo${n}Label").Trim() }
            if (-not $title -or $title -eq $script:DDInfoTitleHint) { continue }
            $html = ''
            if ($entry.PSObject.Properties.Match("AdditionalInfo${n}Html").Count -gt 0) { $html = [string]$entry."AdditionalInfo${n}Html" }
            $text = ''
            if ($entry.PSObject.Properties.Match("AdditionalInfo$n").Count -gt 0) { $text = [string]$entry."AdditionalInfo$n" }
            if (-not $html.Trim() -and -not $text.Trim()) { continue }

            $images = @{}
            if ($imgStore -and $html) {
                foreach ($m in [regex]::Matches($html, '(?i)cid:([0-9a-f]{16})')) {
                    $id = $m.Groups[1].Value.ToLowerInvariant()
                    if ($images.ContainsKey($id)) { continue }
                    $val = $null
                    if ($imgStore.PSObject.Properties.Match($id).Count -gt 0) { $val = $imgStore.$id }
                    if ($val -and $val.Type -and $val.Data) { $images[$id] = @{ Type = [string]$val.Type; Data = [string]$val.Data } }
                }
            }

            $key = $title.ToLowerInvariant()
            if ($byKey.ContainsKey($key) -and $byKey[$key].Saved -ge $saved) { continue }
            $byKey[$key] = [PSCustomObject]@{
                Title  = $title
                Html   = $html
                Text   = $text
                Images = $images
                Domain = $p.Name
                Slot   = $n
                Saved  = $saved
            }
        }
    }
    return @($byKey.Values | Sort-Object -Property Title)
}
#endregion

#region -- Get-DomainDefaults ---------------------------------------------------
function Get-DomainDefaults {
    <#
    .SYNOPSIS
        Returns the saved settings for $Domain (case-insensitive match), or
        an all-blank defaults object (SmtpPort=25, DisplayNamePattern=
        PrefixLastFirstSuffix, AccountNamePattern=LastInitial, everything
        else '') if that domain has no saved entry yet. Never throws.
    #>
    param([string]$Domain)
    $blank = New-BlankDomainDefaults
    if (-not $Domain) { return $blank }

    $all   = Get-AllDomainDefaultsRaw
    $match = $all.PSObject.Properties | Where-Object { $_.Name -ieq $Domain } | Select-Object -First 1
    if (-not $match) { return $blank }

    $src    = $match.Value
    $result = New-BlankDomainDefaults
    foreach ($p in $result.PSObject.Properties.Name) {
        if ($src.PSObject.Properties.Match($p).Count -gt 0 -and $null -ne $src.$p) {
            $result.$p = $src.$p
        }
    }
    # v1.5.0: a Title box that was never typed in used to save its gray
    # hint text as the real title - treat that literal as blank.
    foreach ($n in 1..4) {
        $lp = "AdditionalInfo${n}Label"
        if ([string]$result.$lp -eq $script:DDInfoTitleHint) { $result.$lp = '' }
    }
    return $result
}
#endregion

#region -- Set-DomainDefaults ---------------------------------------------------
function Set-DomainDefaults {
    <#
    .SYNOPSIS
        Saves/overwrites the settings entry for $Domain. If a domain already
        exists under a different letter case, that existing key is reused
        (re-saving 'Contoso.com' when 'contoso.com' is already saved updates
        the existing entry rather than creating a case-duplicate). SmtpPort
        is coerced to an integer, falling back to 25 if not parseable.
        DisplayNamePattern/AccountNamePattern are validated against their
        known key lists and fall back to their defaults if an unrecognised
        value is supplied (defends against a hand-edited or corrupt JSON
        entry silently breaking the Create User panel's builder logic).
    .PARAMETER Settings
        Hashtable of any subset of: SmtpServer, SmtpPort, MailFrom,
        DisplayPrefix, DisplaySuffix, DisplayNamePattern, LogonPrefix,
        LogonSuffix, AccountNamePattern, BulkDisplayNamePattern,
        BulkAccountNamePattern, UpnSuffix, HomeDrive,
        DefaultNewUserOU, DefaultDisabledOU, DefaultBulkOnboardOU,
        FilterAsYouType, AdditionalInfo1, AdditionalInfo2, AdditionalInfo3,
        AdditionalInfo4, AdditionalInfo1Label, AdditionalInfo2Label,
        AdditionalInfo3Label, AdditionalInfo4Label, AdditionalInfo1Html-
        AdditionalInfo4Html, AdditionalInfoImages, NewAccountWelcome,
        NewAccountWelcomeHtml, LogMaxKB, AccountNameCase.
        Unrecognised keys are ignored; omitted keys are saved as blank (or,
        for FilterAsYouType, $true; for DisplayNamePattern/AccountNamePattern,
        their defaults).
    .OUTPUTS
        PSCustomObject with Success (bool) and Message (string).
    #>
    param(
        [Parameter(Mandatory)][string]$Domain,
        [Parameter(Mandatory)][hashtable]$Settings
    )
    if (-not $Domain.Trim()) { return [PSCustomObject]@{ Success = $false; Message = 'Domain name is required.' } }
    $clean = Get-CleanDomainDefaults -Settings $Settings
    try {
        $name = Save-ADSettingsToEnvironment -Domain $Domain.Trim() -Clean $clean
        return [PSCustomObject]@{ Success = $true; Message = "Saved settings for '$name'." }
    } catch {
        return [PSCustomObject]@{ Success = $false; Message = "Save failed: $($_.Exception.Message)" }
    }
}

function Get-CleanDomainDefaults {
    <#
    .SYNOPSIS
        The validation / clean-up half of 1.6.1's Set-DomainDefaults: a full
        settings object with every value coerced and checked (port and log
        size numbers, known pattern keys, case rule, message titles, only the
        pictures the messages still reference). Keys not in -Settings get
        their blank defaults.
    #>
    param([Parameter(Mandatory)][hashtable]$Settings)
    $clean = New-BlankDomainDefaults
    foreach ($k in $Settings.Keys) {
        if ($clean.PSObject.Properties.Match($k).Count -gt 0) { $clean.$k = $Settings[$k] }
    }
    $portVal = 25
    if (-not [int]::TryParse([string]$clean.SmtpPort, [ref]$portVal)) { $portVal = 25 }
    $clean.SmtpPort = $portVal

    # FilterAsYouType may arrive as a real bool (checkbox.Checked) or a
    # string ('True'/'False') - coerce either way, defaulting to $true.
    $filterVal = $true
    if ($clean.FilterAsYouType -is [bool]) {
        $filterVal = $clean.FilterAsYouType
    } elseif (-not [bool]::TryParse([string]$clean.FilterAsYouType, [ref]$filterVal)) {
        $filterVal = $true
    }
    $clean.FilterAsYouType = $filterVal

    # Validate pattern keys - an unrecognised key (hand-edited JSON, older
    # partial save, typo from a future UI change) falls back to the safe
    # default rather than silently breaking Update-CreateUserDomainDefaults'
    # switch statement at read time.
    $validDisplayPatterns = @(
        'AccountOnly', 'PrefixAccount', 'PrefixAccountSuffix', 'AccountSuffix',
        'LastFirst', 'PrefixLastFirst', 'PrefixLastFirstSuffix'
    )
    if ($validDisplayPatterns -notcontains $clean.DisplayNamePattern) {
        $clean.DisplayNamePattern = 'PrefixLastFirstSuffix'
    }
    $validAccountPatterns = @('LastInitial', 'PrefixLastInitial', 'PrefixLastInitialSuffix')
    if ($validAccountPatterns -notcontains $clean.AccountNamePattern) {
        $clean.AccountNamePattern = 'LastInitial'
    }
    $validBulkDisplayPatterns = @(
        'AccountOnly', 'PrefixAccount', 'PrefixAccountSuffix', 'AccountSuffix',
        'LastFirst', 'PrefixLastFirst', 'PrefixLastFirstSuffix',
        'CustomOnly', 'PrefixCustom', 'CustomSuffix', 'PrefixCustomSuffix'
    )
    $validBulkAccountPatterns = @(
        'LastInitial', 'PrefixLastInitial', 'PrefixLastInitialSuffix',
        'CustomOnly', 'PrefixCustom', 'CustomSuffix', 'PrefixCustomSuffix'
    )
    if ($validBulkDisplayPatterns -notcontains $clean.BulkDisplayNamePattern) {
        $clean.BulkDisplayNamePattern = 'PrefixCustomSuffix'
    }
    if ($validBulkAccountPatterns -notcontains $clean.BulkAccountNamePattern) {
        $clean.BulkAccountNamePattern = 'PrefixCustomSuffix'
    }

    # Log size limit (KB): integer, clamped 64 KB .. 1 GB, default 5120.
    $logMax = 5120
    if (-not [int]::TryParse([string]$clean.LogMaxKB, [ref]$logMax)) { $logMax = 5120 }
    if ($logMax -lt 64)      { $logMax = 64 }
    if ($logMax -gt 1048576) { $logMax = 1048576 }
    $clean.LogMaxKB = $logMax

    if (@('AsTyped', 'Upper', 'Lower') -notcontains [string]$clean.AccountNameCase) {
        $clean.AccountNameCase = 'AsTyped'
    }

    # When this entry was saved (UTC) - used to pick the newer copy when
    # settings carried in the EXE meet this machine's settings.
    # v1.5.0 Additional Info: titles (drop the old placeholder literal),
    # formatted HTML (sanitized by the editor before it gets here, and again
    # at send time), and this domain's picture store - only pictures that
    # one of the four snippets still references are kept, so removing a
    # picture from a snippet frees its space on the next save.
    $refIds = [System.Collections.Generic.List[string]]::new()
    foreach ($n in 1..4) {
        $lp = "AdditionalInfo${n}Label"
        $hp = "AdditionalInfo${n}Html"
        $tp = "AdditionalInfo$n"
        $clean.$lp = ([string]$clean.$lp).Trim()
        if ($clean.$lp -eq $script:DDInfoTitleHint) { $clean.$lp = '' }
        $clean.$tp = [string]$clean.$tp
        $clean.$hp = [string]$clean.$hp
        foreach ($m in [regex]::Matches($clean.$hp, '(?i)cid:([0-9a-f]{16})')) {
            $id = $m.Groups[1].Value.ToLowerInvariant()
            if (-not $refIds.Contains($id)) { $refIds.Add($id) }
        }
    }
    # v1.6.0 New Account welcome message - same handling as a slot.
    $clean.NewAccountWelcome     = [string]$clean.NewAccountWelcome
    $clean.NewAccountWelcomeHtml = [string]$clean.NewAccountWelcomeHtml
    foreach ($m in [regex]::Matches($clean.NewAccountWelcomeHtml, '(?i)cid:([0-9a-f]{16})')) {
        $id = $m.Groups[1].Value.ToLowerInvariant()
        if (-not $refIds.Contains($id)) { $refIds.Add($id) }
    }
    $imgIn  = $clean.AdditionalInfoImages
    $imgOut = [ordered]@{}
    if ($imgIn) {
        $pairs = @()
        if ($imgIn -is [System.Collections.IDictionary]) {
            foreach ($k in $imgIn.Keys) { $pairs += ,@([string]$k, $imgIn[$k]) }
        } else {
            foreach ($p in $imgIn.PSObject.Properties) { $pairs += ,@([string]$p.Name, $p.Value) }
        }
        foreach ($pair in $pairs) {
            $id  = $pair[0].ToLowerInvariant()
            $val = $pair[1]
            if (-not $refIds.Contains($id) -or -not $val) { continue }
            $type = ''; $data = ''
            if ($val -is [System.Collections.IDictionary]) { $type = [string]$val['Type']; $data = [string]$val['Data'] }
            else { $type = [string]$val.Type; $data = [string]$val.Data }
            if (@('image/png', 'image/jpeg', 'image/gif') -notcontains $type) { continue }
            if (-not $data -or $data -notmatch '^[A-Za-z0-9+/]+={0,2}$') { continue }
            $imgOut[$id] = [ordered]@{ Type = $type; Data = $data }
        }
    }
    $clean.AdditionalInfoImages = $imgOut

    $clean.SavedUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture)
    return $clean
}

function Save-ADSettingsToEnvironment {
    <#
    .SYNOPSIS
        Writes a cleaned settings object into the environment record for
        $Domain: the active environment when it answers to $Domain, else the
        environment whose Domain is $Domain, else a new environment named
        after the domain. Returns the environment's Label.
    #>
    param([Parameter(Mandatory)][string]$Domain, [Parameter(Mandatory)]$Clean)
    $app = $script:ADApp
    if (-not $app) { throw 'The app context is not ready.' }
    $store = Read-AppEnvironmentStore -App $app
    $rec = $null
    $activeKeys = @((Get-ADSettingsKey -App $app))
    if ($script:ADContext -and $script:ADContext.Domain) { $activeKeys += [string]$script:ADContext.Domain }
    if (@($activeKeys | Where-Object { $_ -and $_ -ieq $Domain }).Count -gt 0) {
        foreach ($r in $store.Environments) { if ([string]$r['Name'] -ieq [string]$app.ActiveName) { $rec = $r; break } }
    }
    if (-not $rec) { foreach ($r in $store.Environments) { if (([string]$r['Domain']).Trim() -ieq $Domain) { $rec = $r; break } } }
    if (-not $rec) {
        $rec = [ordered]@{ Name = ($Domain -replace '[^A-Za-z0-9_.-]+', '-'); Label = $Domain; Domain = $Domain; Server = ''; SharedPath = ''; IsDefault = $false }
    }
    foreach ($p in $Clean.PSObject.Properties) { $rec[$p.Name] = $p.Value }
    [void](Save-AppEnvironmentRecord -App $app -Record $rec)
    return [string]$rec['Label']
}
#endregion

#region -- Convert-AccountNameCase ----------------------------------------------
function Convert-AccountNameCase {
    <#
    .SYNOPSIS
        Applies a domain's AccountNameCase rule to an account (logon) name.
        Called by every account-creation path immediately before the account
        is created, and by the previews, so the rule always holds.
    .PARAMETER Name
        The account name as built or typed.
    .PARAMETER Case
        'Upper', 'Lower', or 'AsTyped' (anything else is treated as AsTyped:
        the name is returned unchanged).
    .OUTPUTS
        [string]
    #>
    param([string]$Name, [string]$Case)
    if (-not $Name) { return $Name }
    switch ($Case) {
        'Upper' { return $Name.ToUpperInvariant() }
        'Lower' { return $Name.ToLowerInvariant() }
        default { return $Name }
    }
}
#endregion

#region -- Build-BulkAccountName / Build-BulkDisplayName -----------------------
function Build-BulkAccountName {
    <#
    .SYNOPSIS
        Assembles a Bulk-Onboard Logon Name. Mirrors ADUserActions.
        CreateUser.Tab's single-user Account Name builder
        ($script:UABuildAccountName) exactly for the 3 classic patterns, as
        a pure function taking First/Last/Custom Text/Prefix/Suffix
        explicitly instead of reading WinForms .Text properties - so
        ADTools.BulkOnboard.Engine can call it per CSV row.
    .PARAMETER Pattern
        LastInitial / PrefixLastInitial / PrefixLastInitialSuffix (built
        from FirstName/LastName - same sanitize/upper-case/20-char-cap slug
        as the single-user flow) OR CustomOnly / PrefixCustom / CustomSuffix
        / PrefixCustomSuffix (built from CustomText instead). Unrecognised
        falls back to LastInitial.
    .PARAMETER FirstName / LastName
        Used only by the 3 classic patterns.
    .PARAMETER CustomText
        The row's LogonCustomText column - used only by the 4 Custom
        patterns. Sanitized to sAMAccountName-safe characters and
        upper-cased (accents folded, [^a-z0-9.\-_] stripped, 20-char cap) -
        the same safety net the classic patterns' First/Last slug already
        gets, since LogonCustomText is free text.
    .PARAMETER Prefix / Suffix
        This domain's LogonPrefix/LogonSuffix. BOTH concatenate directly
        with no inserted separator on either side - matches the single-user
        Account Name pattern's own join rule exactly (unlike Display Name's
        Suffix, which gets a leading space - see Build-BulkDisplayName).
    .OUTPUTS
        [string]
    #>
    param(
        [string]$Pattern,
        [string]$FirstName,
        [string]$LastName,
        [string]$CustomText,
        [string]$Prefix,
        [string]$Suffix
    )
    $pf = if ($Prefix) { $Prefix.Trim() } else { '' }
    $sf = if ($Suffix) { $Suffix.Trim() } else { '' }

    $sanitize = {
        param([string]$s)
        if (-not $s) { return '' }
        $t = [System.Text.RegularExpressions.Regex]::Replace(
                 $s.Normalize([System.Text.NormalizationForm]::FormD).ToLower(),
                 '[^a-z0-9.\-_]', '')
        if ($t.Length -gt 20) { $t = $t.Substring(0, 20) }
        return $t.ToUpper()
    }
    $lastInitialBase = {
        $f  = & $sanitize $FirstName
        $l  = & $sanitize $LastName
        $fi = if ($f.Length -gt 0) { $f[0] } else { '' }
        return ($l + $fi)
    }

    switch ($Pattern) {
        'PrefixLastInitial'       { return ($pf + (& $lastInitialBase)) }
        'PrefixLastInitialSuffix' { return ($pf + (& $lastInitialBase) + $sf) }
        'CustomOnly'              { return (& $sanitize $CustomText) }
        'PrefixCustom'            { return ($pf + (& $sanitize $CustomText)) }
        'CustomSuffix'            { return ((& $sanitize $CustomText) + $sf) }
        'PrefixCustomSuffix'      { return ($pf + (& $sanitize $CustomText) + $sf) }
        default                   { return (& $lastInitialBase) }   # LastInitial
    }
}

function Build-BulkDisplayName {
    <#
    .SYNOPSIS
        Assembles a Bulk-Onboard Display Name. Mirrors ADUserActions.
        CreateUser.Tab's single-user Display Name builder
        ($script:UABuildDisplay) exactly for the 7 classic patterns, as a
        pure function - so ADTools.BulkOnboard.Engine can call it per CSV
        row.
    .PARAMETER Pattern
        AccountOnly / PrefixAccount / PrefixAccountSuffix / AccountSuffix /
        LastFirst / PrefixLastFirst / PrefixLastFirstSuffix (the 7 classic
        keys) OR CustomOnly / PrefixCustom / CustomSuffix /
        PrefixCustomSuffix (the 4 Bulk-only Custom Text keys). Unrecognised
        falls back to AccountOnly.
    .PARAMETER FirstName / LastName
        Used by the LastFirst-family patterns ("Last, First" - same
        fallback rules as the single-user builder: Last alone, First alone,
        or blank if both are blank).
    .PARAMETER AccountBase
        This row's ALREADY-COMPUTED Logon Name (see Build-BulkAccountName,
        which must run FIRST) - used by the AccountOnly-family patterns.
        Mirrors the single-user flow exactly: Display Name's account-based
        patterns read the Account Name field's CURRENT text rather than
        re-deriving First/Last themselves.
    .PARAMETER CustomText
        The row's DisplayCustomText column - used only by the 4 Custom
        patterns. NOT sanitized (unlike Build-BulkAccountName's CustomText) -
        Display Name allows normal punctuation/spacing.
    .PARAMETER Prefix / Suffix
        This domain's DisplayPrefix/DisplaySuffix. Prefix concatenates
        directly; Suffix is joined with a single leading space when
        non-blank - matches the single-user Display Name pattern's own join
        rule exactly (unlike Account/Logon Name's Suffix, which has no
        inserted separator - see Build-BulkAccountName).
    .OUTPUTS
        [string]
    #>
    param(
        [string]$Pattern,
        [string]$FirstName,
        [string]$LastName,
        [string]$AccountBase,
        [string]$CustomText,
        [string]$Prefix,
        [string]$Suffix
    )
    $pf   = if ($Prefix)     { $Prefix.Trim() }     else { '' }
    $sf   = if ($Suffix)     { $Suffix.Trim() }     else { '' }
    $ct   = if ($CustomText) { $CustomText.Trim() } else { '' }
    $acct = if ($AccountBase){ $AccountBase.Trim() }else { '' }
    $f    = if ($FirstName)  { $FirstName.Trim() }  else { '' }
    $l    = if ($LastName)   { $LastName.Trim() }   else { '' }
    $lastFirst = if ($l -and $f) { "$l, $f" } elseif ($l) { $l } elseif ($f) { $f } else { '' }
    $sfx  = { if ($sf) { " $sf" } else { '' } }

    switch ($Pattern) {
        'PrefixAccount'         { return ($pf + $acct) }
        'PrefixAccountSuffix'   { return ($pf + $acct + (& $sfx)) }
        'AccountSuffix'         { return ($acct + (& $sfx)) }
        'LastFirst'             { return $lastFirst }
        'PrefixLastFirst'       { return ($pf + $lastFirst) }
        'PrefixLastFirstSuffix' { return ($pf + $lastFirst + (& $sfx)) }
        'CustomOnly'            { return $ct }
        'PrefixCustom'          { return ($pf + $ct) }
        'CustomSuffix'          { return ($ct + (& $sfx)) }
        'PrefixCustomSuffix'    { return ($pf + $ct + (& $sfx)) }
        default                 { return $acct }   # AccountOnly
    }
}
#endregion

Export-ModuleMember -Function `
    Get-DomainDefaults, `
    Set-DomainDefaults, `
    Get-CleanDomainDefaults, `
    Save-ADSettingsToEnvironment, `
    Get-DomainDefaultConfigNames, `
    Get-DomainDefaultsAdditionalInfoOptions, `
    Get-DomainDefaultsAdditionalInfoLibrary, `
    Convert-AccountNameCase, `
    Build-BulkAccountName, `
    Build-BulkDisplayName
