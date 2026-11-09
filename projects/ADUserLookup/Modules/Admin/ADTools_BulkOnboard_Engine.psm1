#region -- ADTools.BulkOnboard.Engine.psm1 ------------------------------------
# Concern : Show-BulkCSV     - loads a CSV into BulkPreviewGrid, computing each
#                               row's Display Name / Logon Name from this
#                               domain's Bulk Addition naming convention.
#           Invoke-BulkOnboard - CSV-driven bulk New-ADUser with optional
#                               template group copy, driven by the PREVIEW
#                               GRID's current (possibly edited) rows.
# Load order: 118 - depends on ADTools.BulkOnboard.Log (Write-BulkLog),
#                            ADTools.PasswordGenerator.Engine (New-CustomPassword, script scope),
#                            Services.AD.Reporting (Set-GridData, Get-GridRowsAsObjects,
#                                                   Write-OperationLog),
#                            Services.DomainDefaults.Config (Get-DomainDefaults,
#                                                            Build-BulkAccountName,
#                                                            Build-BulkDisplayName) [4d] - soft, guarded,
#                            ADDirectory.Users.Load (Add-CachedUser, Get-OUFromDN),
#                            Services.Mail.Batch (Send-ADBatchNotificationMail) [4e]
# Split from: ADTools.Actions.psm1
# Changes   : Full column/pipeline redesign to support editable, full-CSV bulk
#             import (see ADTools.BulkOnboard.Template's header for the new
#             column set: FirstName, LastName, DisplayCustomText,
#             LogonCustomText, UpnSuffix, TargetOU, Phone, Email,
#             CopyGroupsFrom, Password).
#
#             Show-BulkCSV no longer caps the preview at 20 rows - the full
#             CSV loads, since the grid is now the actual import source (see
#             Invoke-BulkOnboard below), not just a display sample. It also
#             computes two NEW columns per row, DisplayName and LogonName,
#             using this domain's Bulk Addition naming convention
#             (Services.DomainDefaults.Config's BulkDisplayNamePattern /
#             BulkAccountNamePattern, edited on Tools > Domain Defaults).
#             Both fields offer the FULL superset of the single-Create-User
#             patterns PLUS 4 Bulk-only Custom Text patterns (see
#             Services.DomainDefaults.Config.psm1's header) - LogonName is
#             built FIRST, via Build-BulkAccountName (classic keys use that
#             row's FirstName/LastName with the exact same sanitize/
#             upper-case slug math as the single-user flow; the 4 Custom
#             keys use LogonCustomText instead), THEN DisplayName is built
#             via Build-BulkDisplayName, whose Account-family keys are
#             passed the just-computed LogonName as their base (mirroring
#             the single-user flow, where Display Name's account-based
#             patterns read the Account Name field's live text) - order
#             matters here, Logon must be computed before Display. Both
#             pull Prefix/Suffix from that SAME domain's existing
#             DisplayPrefix/DisplaySuffix/LogonPrefix/LogonSuffix (New User
#             Defaults). Soft dependency: if no domain is connected or
#             Services.DomainDefaults.Config isn't loaded, DisplayName/
#             LogonName fall back to the raw Custom Text columns unmodified,
#             and a warning is logged once - never throws, matching the rest
#             of this app's soft-dependency contract. Both computed columns
#             land in the SAME editable grid as everything else, so an
#             admin can freely overwrite either on any row before importing.
#
#             Invoke-BulkOnboard's -CSVPath parameter is REPLACED by -Rows
#             (an object array) - it now creates accounts from whatever
#             ADTools.BulkOnboard.Tab's Import button reads off the LIVE grid
#             via Get-GridRowsAsObjects (Services.AD.Reporting), not a second,
#             independent read of the original file. This closes the gap
#             where editing the preview grid previously had zero effect on
#             what actually got imported - the grid IS the import source now.
#             Each row's already-computed DisplayName/LogonName (built by
#             Show-BulkCSV, and editable since) are used directly as
#             New-ADUser's Name/DisplayName/SamAccountName - this function
#             does not re-run the naming convention itself.
#
#             Field mapping now mirrors ADUserActions.CreateUser.Account.psm1
#             (the single-user flow) for full parity, per that flow's
#             existing pattern: Phone (10-digit-stripped, like the single
#             form) is written via -OtherAttributes to telephoneNumber,
#             homePhone, pager, AND mobile (all four, same as single-user
#             creation) rather than left unmapped; Email is passed directly as
#             -EmailAddress. UPN is now built here (LogonName + UpnSuffix,
#             normalized to include a leading '@') rather than requiring a
#             pre-assembled UPN column. Company/Office/Manager/Title/
#             Department/Description remain UNMAPPED - this environment never
#             populates them on user creation (explicit product decision),
#             so no columns or params exist for them.
#             TemplateUser column renamed to CopyGroupsFrom (functionally
#             identical - group-membership mirroring logic unchanged).
#             Password column added: a row with a non-blank Password uses
#             that literal value; blank (the default) still randomizes via
#             New-CustomPassword exactly as before.
# v1.6.0    : New accounts are created with ChangePasswordAtLogon = $false
#             (passwords are permanent). Welcome email: Display Name, Username,
#             Password, Welcome = $true. Admin summary: Admin / Domain /
#             Timestamp, created list and batch result only.
#endregion

#region -- Show-BulkCSV -------------------------------------------------------
function Show-BulkCSV {
    param([string]$Path)
    try {
        $rows = Import-Csv -Path $Path -ErrorAction Stop
        if ($rows.Count -eq 0) { Write-BulkLog 'CSV is empty.' 'warn'; return }

        # Resolve this domain's Bulk Addition naming convention (Tools >
        # Domain Defaults) once, up front - soft dependency, never throws.
        # The preview grid is the actual import source once loaded (see
        # Invoke-BulkOnboard below), so whatever is computed/edited here is
        # exactly what gets created.
        $dd = $null
        if ($script:ToolsCtx -and $script:ToolsCtx.Domain -and (Get-Command Get-DomainDefaults -ErrorAction SilentlyContinue)) {
            try { $dd = Get-DomainDefaults -Domain $script:ToolsCtx.Domain } catch { }
        }
        $canBuild = [bool]($dd -and (Get-Command Build-BulkAccountName -ErrorAction SilentlyContinue) -and (Get-Command Build-BulkDisplayName -ErrorAction SilentlyContinue))
        if (-not $canBuild) {
            Write-BulkLog 'Domain Defaults naming convention unavailable - Display Name/Logon Name default to the raw Custom Text columns unmodified. Connect to a domain and configure Tools > Domain Defaults > Bulk Addition for pattern-built names.' 'warn'
        }

        # v1.2.0 - Account Name Case (Domain Defaults) applied to the preview's
        # Logon Name, so the grid shows the name that will be created.
        $hasCaseFn = [bool](Get-Command Convert-AccountNameCase -ErrorAction SilentlyContinue)

        $data = [System.Collections.Generic.List[PSCustomObject]]::new()
        foreach ($r in $rows) {
            $first         = if ($r.PSObject.Properties['FirstName'])         { [string]$r.FirstName }         else { '' }
            $last          = if ($r.PSObject.Properties['LastName'])          { [string]$r.LastName }          else { '' }
            $displayCustom = if ($r.PSObject.Properties['DisplayCustomText']) { [string]$r.DisplayCustomText } else { '' }
            $logonCustom   = if ($r.PSObject.Properties['LogonCustomText'])   { [string]$r.LogonCustomText }   else { '' }

            # Logon Name FIRST - the Display builder's Account-family
            # patterns need it as their base (see module header).
            $logonName = if ($canBuild) {
                Build-BulkAccountName -Pattern $dd.BulkAccountNamePattern -FirstName $first -LastName $last `
                    -CustomText $logonCustom -Prefix $dd.LogonPrefix -Suffix $dd.LogonSuffix
            } else { $logonCustom }
            if ($dd -and $hasCaseFn) {
                $logonName = Convert-AccountNameCase -Name $logonName -Case ([string]$dd.AccountNameCase)
            }

            $displayName = if ($canBuild) {
                Build-BulkDisplayName -Pattern $dd.BulkDisplayNamePattern -FirstName $first -LastName $last `
                    -AccountBase $logonName -CustomText $displayCustom -Prefix $dd.DisplayPrefix -Suffix $dd.DisplaySuffix
            } else { $displayCustom }

            $data.Add([PSCustomObject]@{
                FirstName         = $first
                LastName          = $last
                DisplayCustomText = $displayCustom
                DisplayName       = $displayName
                LogonCustomText   = $logonCustom
                LogonName         = $logonName
                UpnSuffix         = if ($r.PSObject.Properties['UpnSuffix'])      { [string]$r.UpnSuffix }      else { '' }
                TargetOU          = if ($r.PSObject.Properties['TargetOU'])       { [string]$r.TargetOU }       else { '' }
                Phone             = if ($r.PSObject.Properties['Phone'])          { [string]$r.Phone }          else { '' }
                Email             = if ($r.PSObject.Properties['Email'])          { [string]$r.Email }          else { '' }
                CopyGroupsFrom    = if ($r.PSObject.Properties['CopyGroupsFrom']) { [string]$r.CopyGroupsFrom } else { '' }
                Password          = if ($r.PSObject.Properties['Password'])       { [string]$r.Password }       else { '' }
            })
        }

        $cols = @('FirstName','LastName','DisplayCustomText','DisplayName','LogonCustomText','LogonName',
                  'UpnSuffix','TargetOU','Phone','Email','CopyGroupsFrom','Password')
        Set-GridData -Grid $script:BulkPreviewGrid -Data $data -Columns $cols
        Write-BulkLog "Loaded preview: $($rows.Count) row(s). Display Name/Logon Name were built from this domain's Bulk Addition naming convention - edit any cell (including those) before importing." 'ok'
    } catch {
        Write-BulkLog "CSV preview failed: $($_.Exception.Message)" 'err'
    }
}
#endregion

#region -- Invoke-BulkOnboard -------------------------------------------------
function Invoke-BulkOnboard {
    <#
    .SYNOPSIS
        Grid-driven bulk New-ADUser with optional template group copy.
    .PARAMETER Rows
        The CURRENT contents of the preview grid (see ADTools.BulkOnboard.Tab's
        Import button, which reads it via Services.AD.Reporting's
        Get-GridRowsAsObjects immediately before calling this function) - one
        object per row, with the same properties Show-BulkCSV wrote into the
        grid: FirstName, LastName, DisplayCustomText, DisplayName,
        LogonCustomText, LogonName, UpnSuffix, TargetOU, Phone, Email,
        CopyGroupsFrom, Password. DisplayName/LogonName are used AS GIVEN -
        this function does not re-run the naming convention, so any manual
        edit made in the grid is exactly what gets created.
    .PARAMETER MailMode
        'AdminOnly' (default), 'Individual', 'Both', or 'None' - see
        Services.Mail.Batch. AdminOnly sends one no-passwords summary to the
        admin. Individual sends each successfully-created user their OWN
        welcome email (username + password, plus the domain welcome message) - see module header
        for the mail-attribute caveat.
    #>
    param(
        [object[]]$Rows,
        [string]$DefaultOU,
        [ValidateSet('AdminOnly', 'Individual', 'Both', 'None')]
        [string]$MailMode = 'AdminOnly'
    )
    $srv  = $script:ToolsCtx.TargetDC
    $ok   = 0; $fail = 0; $skip = 0

    # v1.2.0 - Account Name Case (Domain Defaults) enforced at creation, so a
    # name edited by hand in the preview grid still follows the domain's rule.
    $caseRule = ''
    if ($script:ToolsCtx -and $script:ToolsCtx.Domain -and
        (Get-Command Get-DomainDefaults -ErrorAction SilentlyContinue)) {
        try { $caseRule = [string](Get-DomainDefaults -Domain $script:ToolsCtx.Domain).AccountNameCase } catch { }
    }
    $hasCaseFn = [bool](Get-Command Convert-AccountNameCase -ErrorAction SilentlyContinue)

    if (-not $Rows -or $Rows.Count -eq 0) {
        Write-BulkLog 'Nothing to import - preview a CSV first.' 'warn'
        return
    }

    Write-BulkLog "Starting bulk import: $($Rows.Count) row(s) from the preview grid" 'info'

    # Admin summary (no passwords - see module header) and per-user welcome
    # emails (Individual mode) are built up here as the loop runs, each
    # entry scoped to that ONE row's own data at the moment it's added.
    $createdRows = [System.Collections.Generic.List[PSCustomObject]]::new()
    $recipients  = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($row in $Rows) {
        $first    = [string]($row.FirstName).Trim()
        $last     = [string]($row.LastName).Trim()
        $logon    = [string]($row.LogonName).Trim()
        if ($hasCaseFn -and $caseRule) { $logon = Convert-AccountNameCase -Name $logon -Case $caseRule }
        $display  = [string]($row.DisplayName).Trim()
        $upnSfx   = [string]($row.UpnSuffix).Trim()
        $email    = [string]($row.Email).Trim()
        $rawPhone = [string]($row.Phone) -replace '\D',''
        $tmpl     = [string]($row.CopyGroupsFrom).Trim()
        $ouDN     = if ([string]$row.TargetOU -and [string]($row.TargetOU).Trim()) { [string]($row.TargetOU).Trim() } else { $DefaultOU }

        if (-not $first -or -not $last -or -not $logon) {
            Write-BulkLog "  SKIP row - missing First Name, Last Name, or Logon Name. Row: $($row | ConvertTo-Json -Compress)" 'warn'
            $skip++; continue
        }
        if (-not $ouDN) {
            Write-BulkLog "  SKIP $logon - no Target OU specified and no default OU set." 'warn'
            $skip++; continue
        }
        try { Get-ADUser -Identity $logon -Server $srv -ErrorAction Stop | Out-Null
              Write-BulkLog "  SKIP $logon - account already exists." 'warn'; $skip++; continue
        } catch { }

        if (-not $display) { $display = $logon }

        $upn = ''
        if ($upnSfx) {
            $suffix = if ($upnSfx.StartsWith('@')) { $upnSfx } else { "@$upnSfx" }
            $upn    = "$logon$suffix"
        }

        # Password: a value the admin typed/edited in the grid is used
        # as-is; blank (the default) randomizes exactly as before.
        $pwSupplied = [string]($row.Password).Trim()
        $pw         = if ($pwSupplied) { $pwSupplied } else { New-CustomPassword }
        $secPw      = ConvertTo-SecureString $pw -AsPlainText -Force

        try {
            $params = @{
                Name                  = $display; GivenName = $first; Surname = $last
                SamAccountName        = $logon; DisplayName = $display; Path = $ouDN
                AccountPassword       = $secPw; Enabled = $true; ChangePasswordAtLogon = $false
                Server = $srv; ErrorAction = 'Stop'
            }
            if ($upn)   { $params.UserPrincipalName = $upn }
            if ($email) { $params.EmailAddress       = $email }
            # Phone parity with the single-user Create User flow
            # (ADUserActions.CreateUser.Account.psm1) - written to all 4
            # attributes, not just telephoneNumber.
            if ($rawPhone) {
                $params.OtherAttributes = @{
                    telephoneNumber = $rawPhone
                    homePhone       = $rawPhone
                    pager           = $rawPhone
                    mobile          = $rawPhone
                }
            }
            New-ADUser @params

            if ($tmpl) {
                try {
                    $groups = Get-ADPrincipalGroupMembership -Identity $tmpl -Server $srv -ErrorAction Stop |
                              Where-Object { $_.Name -ne 'Domain Users' }
                    foreach ($g in $groups) {
                        try { Add-ADGroupMember -Identity $g.DistinguishedName -Members $logon -Server $srv -ErrorAction Stop }
                        catch { }
                    }
                    Write-BulkLog "    Copied $($groups.Count) group(s) from template $tmpl" 'info'
                } catch { Write-BulkLog "    Group copy from $tmpl failed" 'warn' }
            }

            Write-OperationLog -Context $script:ToolsCtx -Action 'BULK-CREATE-USER' -Target $logon `
                -Result 'OK' -Detail "DisplayName=$display OU=$ouDN"
            Write-BulkLog "  OK  $logon  ($display)  pw: $pw" 'ok'
            $ok++

            # -- Add the new user to the cached Users list (no AD round trip) --
            # No-op-safe: Add-CachedUser skips duplicates and no-ops if the
            # Directory tab's cache isn't initialised.
            if (Get-Command Add-CachedUser -ErrorAction SilentlyContinue) {
                $newOU = if (Get-Command Get-OUFromDN -ErrorAction SilentlyContinue) { Get-OUFromDN -DN $ouDN } else { '' }
                Add-CachedUser -User ([PSCustomObject]@{
                    DisplayName       = $display
                    SamAccountName    = $logon
                    UPN               = $upn
                    Enabled           = 'True'
                    LastLogon         = 'Never'
                    PasswordLastSet   = (Get-Date -Format 'yyyy-MM-dd')
                    PwNeverExpires    = 'False'
                    LockedOut         = 'False'
                    Created           = (Get-Date -Format 'yyyy-MM-dd')
                    Description       = ''
                    Department        = ''
                    Title             = ''
                    OU                = $newOU
                    DistinguishedName = "CN=$display,$ouDN"
                })
            }

            # -- Mail bookkeeping - admin summary row (no password) + this
            #    user's own welcome email (Individual mode only reads this
            #    entry, never anything from a different row's iteration).
            [void]$createdRows.Add([PSCustomObject]@{
                Sam         = $logon
                DisplayName = $display
                OU          = $ouDN
            })
            $welcomeDetails = [ordered]@{
                'Display Name' = $display
            }
            # v1.6.0: password is permanent (no change at first logon); the
            # welcome message (Domain Defaults) opens the email.
            $welcomeBody = "Username: $logon" + "`r`n" +
                           "Password: $pw"
            [void]$recipients.Add([PSCustomObject]@{
                Sam      = $logon
                Subject  = "Your new AD account: $logon"
                Details  = $welcomeDetails
                BodyText = $welcomeBody
                Welcome  = $true
            })
        } catch {
            Write-OperationLog -Context $script:ToolsCtx -Action 'BULK-CREATE-USER' -Target $logon `
                -Result 'FAIL' -Detail $_.Exception.Message
            Write-BulkLog "  FAIL $logon : $($_.Exception.Message)" 'err'
            $fail++
        }
    }

    Write-BulkLog "Bulk import complete. Created: $ok  Failed: $fail  Skipped: $skip" `
        $(if ($fail -eq 0) {'ok'} else {'warn'})
    Set-Status "Bulk import: $ok created, $fail failed, $skip skipped." `
        $(if ($fail -eq 0) {'ok'} else {'warn'})

    # -- Notification mail - Admin Only / Individual / Both / None ----------
    if ($ok -gt 0 -and $MailMode -ne 'None' -and (Get-Command Send-ADBatchNotificationMail -ErrorAction SilentlyContinue)) {
        $adminDetails = [ordered]@{
            'Admin'     = if ($script:ToolsCtx -and $script:ToolsCtx.AdminAccount) { $script:ToolsCtx.AdminAccount } else { "$env:USERDOMAIN\$env:USERNAME" }
            'Domain'    = if ($script:ToolsCtx -and $script:ToolsCtx.Domain)       { $script:ToolsCtx.Domain }       else { $env:USERDNSDOMAIN }
            'Timestamp' = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        }
        $adminBody = "Accounts created (" + $createdRows.Count + "):" + "`r`n" +
                     (($createdRows | ForEach-Object { "- $($_.Sam)  ($($_.DisplayName))  OU: $($_.OU)" }) -join "`r`n") + "`r`n`r`n" +
                     "Batch result: $ok created, $fail failed, $skip skipped (of $($Rows.Count) row(s))."

        Send-ADBatchNotificationMail `
            -Mode          $MailMode `
            -Context       $script:ToolsCtx `
            -ActionTitle   'Bulk Onboard' `
            -AdminSubject  "AD Bulk Onboard: $ok created, $fail failed, $skip skipped" `
            -AdminDetails  $adminDetails `
            -AdminBodyText $adminBody `
            -Recipients    $recipients
    }
}
#endregion

#region -- Get-BulkOnboardCode ----------------------------------------------------
# The command window text for Invoke-BulkOnboard (template rule: every action shows
# its code): one New-ADUser per grid row with the values as they are now. Passwords
# never appear: a typed one shows as a Read-Host prompt, a blank one as generated.
# Rows the engine skips (missing names / OU, account exists) are marked here too.
function Get-BulkOnboardCode {
    param($Rows, [string]$DefaultOU)
    $srv = [string]$script:ToolsCtx.TargetDC
    $srvText = $(if ($srv) { ' -Server ' + (Format-AppCommandValue $srv) } else { '' })
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('# One account per row of the CSV Preview grid. Account Name Case (Domain Defaults) is applied to the logon name;')
    $lines.Add('# rows whose account already exists are skipped. Passwords: typed in the grid, or generated (New-CustomPassword).')
    foreach ($row in @($Rows)) {
        $first = [string]($row.FirstName).Trim(); $last = [string]($row.LastName).Trim(); $logon = [string]($row.LogonName).Trim()
        $display = [string]($row.DisplayName).Trim(); if (-not $display) { $display = $logon }
        $ouDN = $(if ([string]$row.TargetOU -and [string]($row.TargetOU).Trim()) { [string]($row.TargetOU).Trim() } else { $DefaultOU })
        if (-not $first -or -not $last -or -not $logon -or -not $ouDN) { $lines.Add("# skipped: '$logon' - missing First / Last / Logon name or OU"); continue }
        $p = [ordered]@{ Name = $display; GivenName = $first; Surname = $last; SamAccountName = $logon; DisplayName = $display; Path = $ouDN }
        $upnSfx = [string]($row.UpnSuffix).Trim()
        if ($upnSfx) { $p['UserPrincipalName'] = $logon + $(if ($upnSfx.StartsWith('@')) { $upnSfx } else { "@$upnSfx" }) }
        $email = [string]($row.Email).Trim(); if ($email) { $p['EmailAddress'] = $email }
        $phone = [string]($row.Phone) -replace '\D', ''
        $line = 'New-ADUser'
        foreach ($k in $p.Keys) { $line += " -$k " + (Format-AppCommandValue ([string]$p[$k])) }
        if ($phone) { $line += ' -OtherAttributes @{ telephoneNumber = ' + (Format-AppCommandValue $phone) + '; homePhone = ' + (Format-AppCommandValue $phone) + '; pager = ' + (Format-AppCommandValue $phone) + '; mobile = ' + (Format-AppCommandValue $phone) + ' }' }
        $pwText = $(if ([string]($row.Password).Trim()) { "(Read-Host -AsSecureString -Prompt 'Password for $logon')" } else { '(ConvertTo-SecureString (New-CustomPassword) -AsPlainText -Force)' })
        $line += " -AccountPassword $pwText -Enabled `$true -ChangePasswordAtLogon `$false$srvText"
        $lines.Add($line)
        $tmpl = [string]($row.CopyGroupsFrom).Trim()
        if ($tmpl) {
            $lines.Add('Get-ADPrincipalGroupMembership -Identity ' + (Format-AppCommandValue $tmpl) + "$srvText | Where-Object { `$_.Name -ne 'Domain Users' } | ForEach-Object { Add-ADGroupMember -Identity `$_.DistinguishedName -Members " + (Format-AppCommandValue $logon) + "$srvText }")
        }
    }
    return ($lines -join "`r`n")
}
#endregion

Export-ModuleMember -Function Show-BulkCSV, Invoke-BulkOnboard, Get-BulkOnboardCode
