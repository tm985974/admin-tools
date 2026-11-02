#region -- ADUserActions.CreateUser.Account.psm1 -----------------------------
# Concern : Invoke-CreateUser - orchestrates the full new-user creation
#           workflow: validate, confirm, call New-ADUser with all optional
#           fields, copy credentials to clipboard, log result, offer
#           notification email.
# Load order: 33 - depends on ADUserActions.Banner (script scope, UA-Log),
#                            ADUserActions.CreateUser.Validate (Invoke-ValidateCreateUser),
#                            ADUserActions.CreateUser.Password (Get-CreateUserPassword),
#                            ADUserActions.CreateUser.Groups (Add-NewUserToGroups),
#                            Services.AD.Reporting (Confirm-Action, Write-OperationLog),
#                            Services.Mail.Batch (Get-MailModeSelection,
#                              Send-ADBatchNotificationMail) [4e],
#                            ADDirectory.Users.Load (Add-CachedUser, Get-OUFromDN)
# Split from: ADUserActions.psm1
#
# SAM assembly:
#   The Account/Logon Name field on the Create User panel is now the single
#   source of truth for the SAM base - ADUserActions.CreateUser.Tab's
#   account-name builder already bakes Logon Prefix/Logon Suffix directly
#   into that field's own text whenever the domain's selected
#   AccountNamePattern calls for them (e.g. PrefixLastInitialSuffix ->
#   ADM_SMITHJ_IPCS is already what's in the field). Invoke-ValidateCreateUser
#   passes that text through unchanged as .Sam; DO NOT prepend/append
#   prefix or suffix again here - doing so would double them for any
#   pattern that already includes them.
#
# UPN = Sam (as validated) + UPN suffix
#
# Copy Groups From User:
#   If $script:UANewCopyGroupsFrom has a selected item that is not blank,
#   the SAM is extracted from the trailing (SAM) token, the source user's
#   MemberOf is resolved, and Add-NewUserToGroups is called after account
#   creation. Failures are logged per-group but never abort the creation.
#
# Notes field removed from UI - null-guarded for forward compatibility.
#
# Description date-stamp:
#   A "Created MM/DD/YYYY" stamp is always appended to the Description field
#   before calling New-ADUser. If the user typed a description, the stamp is
#   appended in parentheses: "their text (Created MM/DD/YYYY)". If the field
#   is blank, the stamp is set as the full description value. Description is
#   therefore always populated on every created account.
#
# Success flag:
#   $script:UACreateSucceeded is set to $true on the success path so
#   ADUserActions.CreateUser.Tab can clear fields on return.
#
# Mail notification - split admin/user emails:
#   Send-ADBatchNotificationMail is called on the success path, right after
#   UACreateSucceeded is set, using the Notification mode selected on the
#   Create User panel ($script:UANewMailMode, read via Get-MailModeSelection
#   - defaults to 'Both' if the selector or Services.Mail.Batch is
#   unavailable for any reason). Guarded with Get-Command so the module
#   degrades cleanly if Services.Mail.Batch is absent. The AD action is
#   always committed first; a mail failure or skip never affects the
#   created account.
#
#   This used to be a single Show-NotificationMailDialog call - normal
#   (-Sam) mode when the Email field was filled (To the user, Cc'd to the
#   admin, BOTH of them seeing the plaintext password), or -AdminOnly when
#   it was blank (To the admin, no user copy at all). Both branches are
#   gone. Every successful creation now goes through
#   Send-ADBatchNotificationMail exactly once with:
#     - AdminDetails/AdminBodyText: tracking fields for the admin's copy -
#       Username/UPN/OU/Title/Department/Company/Office/Phone/Email/Groups
#       From/Admin/Domain/DC/Timestamp - deliberately WITHOUT Password.
#     - Recipients: a single entry (the new user) whose OWN Details table
#       carries 'Password' - only that user's own email (Individual/Both
#       modes) ever contains it.
#   A blank Email field on the form is no longer special-cased here -
#   Show-NotificationMailDialog itself (called internally by Send-
#   ADBatchNotificationMail for the recipient send) now prompts for an
#   address and writes it back to AD if the mail attribute is still blank
#   at send time. See Services.Mail.Dialog for that behavior.
#
#   Login credentials and group memberships:
#   The admin's Details table gets a compact 'Groups From' summary (source
#   SAM + count) but never the password. The recipient's Details table gets
#   the password. The full copied-group list itself is NOT put in either
#   Details table - an HTML table cell doesn't preserve line breaks, so a
#   real list would either collapse to one line or need extra markup. It
#   goes in the editable BodyText instead (see below), which already
#   converts CRLF to <br> before sending.
#
# Removed success popup:
#   The old "User Created" MessageBox (Username/Password/Groups copied from)
#   is gone - the notification mail below already surfaces the same
#   information (and more) without a blocking modal, and the admin's own
#   copy of it is already covered by $script:UACrStatus's status label, the
#   Action Results log entries just above, and the clipboard copy.
#
# BodyText narrative + one-group-per-line listing:
#   The recipient's BodyText opens with an explicit "User '<sam>' created
#   successfully and is enabled..." statement rather than a generic "a new
#   account has been created" line. When a Copy-Groups-From source was
#   used, every copied group name is appended on its OWN line ("-
#   GroupName"), not joined into a single comma/semicolon-separated string -
#   matching the one-item-per-line convention ConvertTo-MailRecoveryBlock
#   (Services.Mail.Send) already uses for group/member lists in every other
#   notification email in this suite. The admin's own BodyText carries the
#   same narrative and group listing, minus any password reference.
#
# Cache update:
#   A successful creation also adds the new user into the Directory tab's
#   cached Users list (via Add-CachedUser) and re-renders the grid, so the
#   new account is visible immediately without a manual Reload Directory
#   Data. No AD round trip beyond the creation itself. The cached
#   DistinguishedName is approximated as "CN=<display>,<ouDN>" (AD's actual
#   escaping of special characters in the CN may differ in rare cases) -
#   this is only used for OU-scope filtering/display in the grid, not for
#   any further AD write, so an approximation is acceptable here.
#
# AD object name (CN) collision:
#   New-ADUser -Name (the CN) must be unique within the target OU, but
#   DisplayName need not be. Two people with the same first/last name build
#   the same convention Display Name, which previously failed with "an
#   attempt was made to add an object to the directory with a name that is
#   already in use" even though their SAMs differed. Before the confirm
#   prompt, the target OU is checked (one level, LDAP-escaped) for an object
#   already named $display; if found, the CN becomes "$display [$sam]"
#   (SAM is unique, so this cannot collide), capped at AD's 64-character CN
#   limit. DisplayName is never altered. The confirm prompt shows the
#   adjusted AD Name and the Action Results log records it.
# v1.6.0    : New-account emails trimmed to basic information. The person's
#             email carries Account / Username / Password only and Welcome =
#             $true (the domain's New Account Welcome opens it); the admin
#             summary drops Title, Department, Company, Office, Phone, Groups
#             From, DC and the password/tracking sentences.
#endregion

#region -- Invoke-CreateUser --------------------------------------------------
function Invoke-CreateUser {
    $C_ERR = [System.Drawing.Color]::FromArgb(156,0,6)
    $C_OK  = [System.Drawing.Color]::FromArgb(0,97,0)

    $validation = Invoke-ValidateCreateUser
    if (-not $validation.Valid) {
        $script:UACrStatus.ForeColor = $C_ERR
        $script:UACrStatus.Text      = $validation.Message
        return
    }

    # Validate.Sam is the Logon Name field's text as-is - Logon Prefix/Suffix
    # are already baked in when the domain's AccountNamePattern calls for
    # them (see module header). No further assembly needed here.
    $sam = $validation.Sam

    # v1.2.0 - Account Name Case (Domain Defaults) is enforced here, at
    # creation, whatever the field showed. The UPN is built from $sam below,
    # so it follows the same case.
    if ($script:UAContext -and $script:UAContext.Domain -and
        (Get-Command Get-DomainDefaults -ErrorAction SilentlyContinue) -and
        (Get-Command Convert-AccountNameCase -ErrorAction SilentlyContinue)) {
        try {
            $caseRule = [string](Get-DomainDefaults -Domain $script:UAContext.Domain).AccountNameCase
            $sam      = Convert-AccountNameCase -Name $sam -Case $caseRule
        } catch { }
    }

    $upnSuffix = $script:UANewUPN.Text.Trim()
    $upn       = $sam + $upnSuffix

    $first   = $script:UANewFirst.Text.Trim()
    $last    = $script:UANewLast.Text.Trim()
    $display = $script:UANewDisplay.Text.Trim()
    $ouDN    = $script:UANewOUBox.Text.Trim()
    $pw      = Get-CreateUserPassword

    $script:UACrStatus.ForeColor = [System.Drawing.Color]::DimGray

    $srvParam = if ($script:UAContext.TargetDC) { @{ Server = $script:UAContext.TargetDC } } else { @{} }

    # Validate assembled SAM - prefix may push it over 20 chars or introduce bad chars
    if ($sam.Length -gt 20) {
        $script:UACrStatus.ForeColor = $C_ERR
        $script:UACrStatus.Text      = "SAM '$sam' exceeds 20 characters ($($sam.Length))."
        return
    }
    if ($sam -match '[^a-zA-Z0-9.\-_]') {
        $script:UACrStatus.ForeColor = $C_ERR
        $script:UACrStatus.Text      = "SAM '$sam' contains invalid characters. Use a-z 0-9 . - _ only."
        return
    }

    # Check for duplicate SAM
    try {
        if (Get-ADUser -Identity $sam @srvParam -ErrorAction SilentlyContinue) {
            $script:UACrStatus.ForeColor = $C_ERR
            $script:UACrStatus.Text      = "Logon name '$sam' already exists in AD."
            return
        }
    } catch { }

    # Resolve the AD object name (CN). New-ADUser -Name must be unique within
    # the target OU; DisplayName does not have to be. Two users with the same
    # first/last name build the same convention Display Name, so on a
    # collision the CN gets the (unique) SAM appended. DisplayName itself is
    # left exactly as entered. CN is capped at 64 characters (AD limit).
    $cn         = $display
    $cnAdjusted = $false
    try {
        $ldapName = $display.Replace('\', '\5c').Replace('*', '\2a').Replace('(', '\28').Replace(')', '\29')
        $clash    = Get-ADObject -SearchBase $ouDN -SearchScope OneLevel -LDAPFilter "(name=$ldapName)" @srvParam -ErrorAction Stop
        if ($clash) {
            $tag      = " [$sam]"
            $baseName = $display
            if ($baseName.Length -gt (64 - $tag.Length)) { $baseName = $baseName.Substring(0, (64 - $tag.Length)).TrimEnd() }
            $cn         = $baseName + $tag
            $cnAdjusted = $true
        }
    } catch { }
    if ($cn.Length -gt 64) { $cn = $cn.Substring(0, 64).TrimEnd() }

    # Resolve manager DN
    $managerDN  = $null
    $managerVal = $script:UANewManager.Text.Trim()
    if ($managerVal) {
        try { $managerDN = (Get-ADUser -Identity $managerVal @srvParam -ErrorAction Stop).DistinguishedName }
        catch {
            $script:UACrStatus.ForeColor = $C_ERR
            $script:UACrStatus.Text      = "Manager '$managerVal' not found in AD."
            return
        }
    }

    # Resolve Copy Groups From selection
    # ComboBox is editable (DropDown style) - user may type to filter then
    # select, or may type freeform text. Only proceed when SelectedItem is
    # non-null AND the box Text exactly matches the selected item, confirming
    # the user deliberately chose a list entry rather than typing free text.
    # Items are formatted "DisplayName (SAM)" - SAM is the trailing token.
    $copyGroupsSam    = ''
    $copyGroupNames   = @()
    if ($script:UANewCopyGroupsFrom) {
        $selItem  = $script:UANewCopyGroupsFrom.SelectedItem
        $boxText  = $script:UANewCopyGroupsFrom.Text
        if ($selItem -and ([string]$selItem) -eq $boxText -and $boxText -ne '') {
            if ($boxText -match '\(([^)]+)\)\s*$') {
                $copyGroupsSam = $Matches[1].Trim()
            }
        }
    }
    if ($copyGroupsSam) {
        try {
            $srcUser = Get-ADUser -Identity $copyGroupsSam -Properties MemberOf @srvParam -ErrorAction Stop
            if ($srcUser.MemberOf -and $srcUser.MemberOf.Count -gt 0) {
                $copyGroupNames = @($srcUser.MemberOf | ForEach-Object {
                    # MemberOf returns DNs; extract the CN to use with Add-ADGroupMember
                    if ($_ -match '^CN=([^,]+)') { $Matches[1] } else { $_ }
                })
            }
        } catch {
            UA-Log "Could not resolve groups for '$copyGroupsSam': $($_.Exception.Message)" 'warn'
        }
    }

    $rawPhone = $script:UANewPhone.Text -replace '\D',''
    $email    = $script:UANewEmail.Text.Trim()

    # Build description: stamp "Created MM/DD/YYYY" always.
    # If the user typed a description, append in parentheses; otherwise use the
    # stamp as the full description value.
    $dateStamp  = 'Created ' + (Get-Date -Format 'MM/dd/yyyy')
    $optDescRaw = $script:UANewDesc.Text.Trim()
    $optDesc    = if ($optDescRaw -ne '') { "$optDescRaw ($dateStamp)" } else { $dateStamp }

    $copyGroupsLine = if ($copyGroupsSam) { "`nCopy groups from: $copyGroupsSam ($($copyGroupNames.Count) group(s))" } else { '' }
    $confirmMsg = "Create new user?`n`n" +
                  "Name:     $first $last`n" +
                  "Display:  $display`n" +
                  $(if ($cnAdjusted) { "AD Name:  $cn  (display name already used in this OU)`n" } else { '' }) +
                  "SAM:      $sam`n" +
                  "UPN:      $upn`n" +
                  "OU:       $ouDN`n" +
                  "Phone:    $(if ($rawPhone) { $rawPhone } else { '(none)' })`n" +
                  "Email:    $(if ($email) { $email } else { '(none)' })`n" +
                  "Password: $pw$copyGroupsLine"

    if (-not (Confirm-Action -Title 'Create User' -Message $confirmMsg -ActionLabel 'Create User')) { return }

    $script:UACrStatus.Text = 'Creating user...'

    try {
        $params = @{
            Name                  = $cn
            GivenName             = $first
            Surname               = $last
            DisplayName           = $display
            SamAccountName        = $sam
            UserPrincipalName     = $upn
            Path                  = $ouDN
            AccountPassword       = (ConvertTo-SecureString $pw -AsPlainText -Force)
            Enabled               = $true
            ChangePasswordAtLogon = $false
            Description           = $optDesc
            ErrorAction           = 'Stop'
        }
        if ($script:UAContext.TargetDC) { $params.Server = $script:UAContext.TargetDC }

        $optTitle  = $script:UANewTitle.Text.Trim()
        $optDept   = $script:UANewDept.Text.Trim()
        $optComp   = $script:UANewCompany.Text.Trim()
        $optOffice = $script:UANewOffice.Text.Trim()
        if ($optTitle)  { $params['Title']      = $optTitle }
        if ($optDept)   { $params['Department'] = $optDept }
        if ($optComp)   { $params['Company']    = $optComp }
        if ($optOffice) { $params['Office']     = $optOffice }
        if ($managerDN) { $params['Manager']    = $managerDN }
        if ($email)     { $params['EmailAddress'] = $email }
        if ($rawPhone) {
            $params['OtherAttributes'] = @{
                telephoneNumber = $rawPhone
                homePhone       = $rawPhone
                pager           = $rawPhone
                mobile          = $rawPhone
            }
        }

        New-ADUser @params

        # Notes field removed from UI - guard retained for forward compatibility
        if ($script:UANewNotes -and $script:UANewNotes.Text.Trim()) {
            try { Set-ADUser -Identity $sam @srvParam -Replace @{ info = $script:UANewNotes.Text.Trim() } -ErrorAction Stop } catch { }
        }

        # Copy group memberships from the selected source user (optional)
        if ($copyGroupNames.Count -gt 0) {
            $script:UACrStatus.Text = 'Adding group memberships...'
            Add-NewUserToGroups -Sam $sam -GroupNames $copyGroupNames -Context $script:UAContext
            Write-OperationLog -Context $script:UAContext -Action 'CREATE-USER-COPY-GROUPS' -Target $sam `
                -Result 'OK' -Detail "CopiedFrom=$copyGroupsSam Groups=$($copyGroupNames.Count)"
        }

        [System.Windows.Forms.Clipboard]::SetText("Username: $sam`r`nPassword: $pw`r`nUPN: $upn")

        Write-OperationLog -Context $script:UAContext -Action 'CREATE-USER' -Target $sam -Result 'OK' `
            -Detail "Display=$display OU=$ouDN UPN=$upn Desc=$optDesc"
        UA-Log "User created: $display ($sam)" 'ok'
        if ($cnAdjusted) {
            UA-Log "  AD object name set to '$cn' - '$display' already exists in this OU." 'warn'
        }
        UA-Log "  Password: $pw  |  Credentials copied to clipboard." 'info'
        if ($copyGroupsSam) {
            UA-Log "  Groups copied from: $copyGroupsSam ($($copyGroupNames.Count) group(s))" 'info'
        }

        $script:UACrStatus.ForeColor = $C_OK
        $script:UACrStatus.Text      = "Created: $sam"

        # Signal success to the Tab module so it can clear fields on return.
        $script:UACreateSucceeded = $true

        # -- Add the new user to the cached Users list (no AD round trip) ----
        # No-op-safe: Add-CachedUser itself skips duplicates and no-ops if the
        # Directory tab's cache isn't initialised. DistinguishedName is
        # approximated - see module header note.
        if (Get-Command Add-CachedUser -ErrorAction SilentlyContinue) {
            $newOU = if (Get-Command Get-OUFromDN -ErrorAction SilentlyContinue) { Get-OUFromDN -DN $ouDN } else { '' }
            Add-CachedUser -User ([PSCustomObject]@{
                DisplayName       = $display
                SamAccountName    = $sam
                UPN               = $upn
                Enabled           = 'True'
                LastLogon         = 'Never'
                PasswordLastSet   = (Get-Date -Format 'yyyy-MM-dd')
                PwNeverExpires    = 'False'
                LockedOut         = 'False'
                Created           = (Get-Date -Format 'yyyy-MM-dd')
                Description       = $optDesc
                Email             = $email
                Pager             = $rawPhone
                Mobile            = $rawPhone
                Department        = $optDept
                Title             = $optTitle
                OU                = $newOU
                DistinguishedName = "CN=$cn,$ouDN"
            })
        }

        # -- Mail notification (non-fatal) - split admin/user emails --------
        # AdminDetails/AdminBodyText below deliberately omit the password -
        # only the Recipients entry (this user's own email) carries it. See
        # module header for the full explanation.
        if (Get-Command Send-ADBatchNotificationMail -ErrorAction SilentlyContinue) {
            $acctLabel    = "$display ($sam)"

            $groupLines = ''
            if ($copyGroupsSam) {
                $groupLines = "`r`n`r`nGroups copied from $copyGroupsSam ($($copyGroupNames.Count) group(s)):"
                if ($copyGroupNames.Count -gt 0) {
                    $groupLines += "`r`n" + (($copyGroupNames | ForEach-Object { "- $_" }) -join "`r`n")
                } else {
                    $groupLines += "`r`nNone"
                }
            }

            $adminDetails = [ordered]@{
                'Account'      = $acctLabel
                'Username'     = $sam
                'UPN'          = $upn
                'OU'           = $ouDN
                'Email'        = if ($email)        { $email }        else { '-' }
                'Admin'        = $script:UAContext.AdminAccount
                'Domain'       = $script:UAContext.Domain
                'Timestamp'    = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
            }
            $adminBodyText = "User '$sam' created successfully and is enabled and ready for use." + $groupLines

            $recipDetails = [ordered]@{
                'Account'    = $acctLabel
                'Username'   = $sam
                'Password'   = $pw
            }
            # v1.6.0: no body text for the person - the welcome message
            # (Domain Defaults > New Account Welcome) opens the email instead.
            $recipBodyText = ''

            $mode = if (Get-Command Get-MailModeSelection -ErrorAction SilentlyContinue) {
                Get-MailModeSelection -Selector $script:UANewMailMode
            } else { 'AdminOnly' }

            Send-ADBatchNotificationMail `
                -Mode          $mode `
                -Context       $script:UAContext `
                -ActionTitle   'Account Created' `
                -AdminSubject  "AD Account Created: $acctLabel" `
                -AdminDetails  $adminDetails `
                -AdminBodyText $adminBodyText `
                -Recipients    @([PSCustomObject]@{
                    Sam      = $sam
                    Subject  = "AD Account Created: $acctLabel"
                    Details  = $recipDetails
                    BodyText = $recipBodyText
                    Welcome  = $true
                })
        }

    } catch {
        Write-OperationLog -Context $script:UAContext -Action 'CREATE-USER' -Target $sam -Result 'FAIL' `
            -Detail $_.Exception.Message
        UA-Log "Create user failed: $($_.Exception.Message)" 'err'
        $script:UACrStatus.ForeColor = $C_ERR
        $script:UACrStatus.Text      = "Failed: $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show(
            "Failed to create user:`n`n$($_.Exception.Message)", 'Creation Failed', 'OK', 'Error')
    }
}
#endregion

Export-ModuleMember -Function Invoke-CreateUser
