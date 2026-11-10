#region -- ADAudit.ListReports.Query.Users.psm1 -------------------------------
# Concern : Seven independent, read-only audit queries against AD user
#           objects, each populating one grid on the Audit tab's sub-tab
#           pages: Stale, Locked Out, Password Expiring, Never Logged In,
#           Service Accounts, Password Never Expires, Disabled with Groups.
#           Each Invoke-*Audit function is entirely self-contained (its own
#           AD query, its own grid population via Set-GridData) so any one
#           report failing never affects the others - there is no shared
#           mutable state between them beyond the read-only $script:AudCtx /
#           $script:AudGrids set by ADAudit.Register-AuditTab.
# Load order: depends on ADAudit.Register-AuditTab (script scope: $script:AudCtx,
#                        $script:AudGrids),
#                        Services.AD.Connection.Query (Get-OUFromDN),
#                        Services.AD.Reporting (Set-GridData, Write-OperationLog)
# Split from: (new module)
#
# Thresholds:
#   $script:AudStaleDays    = 90  (Stale users AND stale computers, see
#                                  ADAudit.ListReports.Query.Computers)
#   $script:AudPwExpireDays = 7   (Password Expiring)
#   Both are plain module-scope constants set once below, not wired into
#   Domain Defaults - change the numbers here if a different threshold is
#   ever needed; every report that uses them reads the same variable, so
#   there is exactly one place to edit per threshold.
#
# LastLogonDate accuracy:
#   Get-ADUser's LastLogonDate property is Microsoft's own friendly
#   conversion of the REPLICATED lastLogonTimestamp attribute (not the
#   non-replicated lastLogon attribute), so querying a single DC gives a
#   reasonably accurate answer domain-wide without needing to query every
#   DC - same assumption ADInfrastructure.PrivAudit.Query already makes for
#   its own LastLogon column. lastLogonTimestamp updates on a randomized
#   ~9-14 day cycle per DC to limit replication traffic, so a "stale 90+
#   days" cutoff has comfortable margin over that lag; a 1-2 day cutoff
#   would not.
#
# Password expiry (msDS-UserPasswordExpiryTimeComputed):
#   This constructed attribute is used instead of manually computing
#   PasswordLastSet + domain max password age, because it already accounts
#   for Fine-Grained Password Policies (FGPP) that may override the domain
#   default for a specific user or group - a manual computation would be
#   silently wrong for any account covered by an FGPP. Accounts with
#   PasswordNeverExpires most commonly report the int64 "never" sentinel
#   here, which overflows [datetime]::FromFileTime - guarded below.
#
# Disabled-with-Groups scope:
#   "Groups" here means MemberOf (secondary/explicit group memberships
#   only) - a disabled user's primary group (Domain Users, almost always)
#   is a separate AD attribute and is never included in MemberOf, so this
#   report already naturally excludes it without extra filtering.
#endregion

#region -- Shared thresholds ----------------------------------------------------
$script:AudStaleDays    = 90
$script:AudPwExpireDays = 7
#endregion

#region -- Invoke-StaleUsersAudit -----------------------------------------------
function Invoke-StaleUsersAudit {
    <#
    .SYNOPSIS
        Enabled users whose last logon (replicated lastLogonTimestamp) is
        older than $script:AudStaleDays. Excludes users who have NEVER
        logged on - see Invoke-NeverLoggedInUsersAudit for those, so an
        account appears on exactly one of the two lists, never both.
    #>
    if (-not $script:AudGrids -or -not $script:AudGrids['stale']) { return }
    $srvParam = if ($script:AudCtx -and $script:AudCtx.TargetDC) { @{ Server = $script:AudCtx.TargetDC } } else { @{} }
    $cutoff   = (Get-Date).AddDays(-$script:AudStaleDays)
    $rows     = [System.Collections.Generic.List[PSCustomObject]]::new()

    try {
        $users = Get-ADUser -Filter { Enabled -eq $true } `
                    -Properties DisplayName, LastLogonDate, DistinguishedName `
                    @srvParam -ErrorAction Stop |
                 Where-Object { $_.LastLogonDate -and $_.LastLogonDate -lt $cutoff }

        foreach ($u in $users) {
            $days = [math]::Round(((Get-Date) - $u.LastLogonDate).TotalDays)
            $rows.Add([PSCustomObject]@{
                DisplayName    = $u.Name
                SamAccountName = $u.SamAccountName
                LastLogon      = $u.LastLogonDate
                DaysSinceLogon = $days
                OU             = Get-OUFromDN -DN $u.DistinguishedName
            })
        }
        if (Get-Command Set-Status -ErrorAction SilentlyContinue) {
            Set-Status "Stale users audit: $($rows.Count) account(s) found." 'ok'
        }
        Write-OperationLog -Context $script:AudCtx -Action 'AUDIT-STALE-USERS' -Target 'Domain' -Result 'OK' -Detail "$($rows.Count) found"
    } catch {
        if (Get-Command Set-Status -ErrorAction SilentlyContinue) { Set-Status "Stale users audit failed: $($_.Exception.Message)" 'err' }
        Write-OperationLog -Context $script:AudCtx -Action 'AUDIT-STALE-USERS' -Target 'Domain' -Result 'FAIL' -Detail $_.Exception.Message
    }

    $cols = @('DisplayName','SamAccountName','LastLogon','DaysSinceLogon','OU')
    Set-GridData -Grid $script:AudGrids['stale'] -Data $rows -Columns $cols
}
#endregion

#region -- Invoke-LockedOutUsersAudit -------------------------------------------
function Invoke-LockedOutUsersAudit {
    <#
    .SYNOPSIS
        Every currently locked-out user account. BadPwdCount/LockoutTime are
        fetched with a secondary per-account Get-ADUser call (Search-
        ADAccount's own return type does not include either), same two-step
        pattern ADInfrastructure.PrivAudit.Query already uses for its
        per-member detail lookups - a single failed secondary lookup is
        skipped (try/catch), never aborts the whole report.
    #>
    if (-not $script:AudGrids -or -not $script:AudGrids['lockedout']) { return }
    $srvParam = if ($script:AudCtx -and $script:AudCtx.TargetDC) { @{ Server = $script:AudCtx.TargetDC } } else { @{} }
    $rows     = [System.Collections.Generic.List[PSCustomObject]]::new()

    try {
        $locked = Search-ADAccount -LockedOut @srvParam -ErrorAction Stop |
                  Where-Object { $_.ObjectClass -eq 'user' }

        foreach ($l in $locked) {
            $badPwd = $null; $lockoutTime = 'Unknown'; $dn = $l.DistinguishedName
            try {
                $u = Get-ADUser -Identity $l.SamAccountName -Properties BadPwdCount, LockoutTime, DistinguishedName `
                        @srvParam -ErrorAction Stop
                $badPwd      = $u.BadPwdCount
                $lockoutTime = if ($u.LockoutTime -and $u.LockoutTime -gt 0) { [datetime]::FromFileTime($u.LockoutTime) } else { 'Unknown' }
                $dn          = $u.DistinguishedName
            } catch { }

            $rows.Add([PSCustomObject]@{
                DisplayName    = $l.Name
                SamAccountName = $l.SamAccountName
                LockoutTime    = $lockoutTime
                BadPwdCount    = $badPwd
                OU             = Get-OUFromDN -DN $dn
            })
        }
        if (Get-Command Set-Status -ErrorAction SilentlyContinue) {
            Set-Status "Locked out users audit: $($rows.Count) account(s) found." 'ok'
        }
        Write-OperationLog -Context $script:AudCtx -Action 'AUDIT-LOCKEDOUT-USERS' -Target 'Domain' -Result 'OK' -Detail "$($rows.Count) found"
    } catch {
        if (Get-Command Set-Status -ErrorAction SilentlyContinue) { Set-Status "Locked out users audit failed: $($_.Exception.Message)" 'err' }
        Write-OperationLog -Context $script:AudCtx -Action 'AUDIT-LOCKEDOUT-USERS' -Target 'Domain' -Result 'FAIL' -Detail $_.Exception.Message
    }

    $cols = @('DisplayName','SamAccountName','LockoutTime','BadPwdCount','OU')
    Set-GridData -Grid $script:AudGrids['lockedout'] -Data $rows -Columns $cols
}
#endregion

#region -- Invoke-PwExpiringUsersAudit ------------------------------------------
function Invoke-PwExpiringUsersAudit {
    <#
    .SYNOPSIS
        Enabled users (PasswordNeverExpires = $false) whose computed
        password expiry falls within the next $script:AudPwExpireDays days.
        Uses msDS-UserPasswordExpiryTimeComputed so Fine-Grained Password
        Policies are already accounted for - see module header. Accounts
        already past their expiry are NOT included here (that is a "should
        already be forced to change" state, not an upcoming-in-N-days one) -
        only 0 <= days-remaining <= threshold.
    #>
    if (-not $script:AudGrids -or -not $script:AudGrids['pwexpiring']) { return }
    $srvParam = if ($script:AudCtx -and $script:AudCtx.TargetDC) { @{ Server = $script:AudCtx.TargetDC } } else { @{} }
    $now      = Get-Date
    $cutoff   = $now.AddDays($script:AudPwExpireDays)
    $rows     = [System.Collections.Generic.List[PSCustomObject]]::new()

    try {
        $users = Get-ADUser -Filter { Enabled -eq $true -and PasswordNeverExpires -eq $false } `
                    -Properties DisplayName, 'msDS-UserPasswordExpiryTimeComputed', DistinguishedName `
                    @srvParam -ErrorAction Stop

        foreach ($u in $users) {
            $raw = $u.'msDS-UserPasswordExpiryTimeComputed'
            # 0 = "not computed" (e.g. password never set); a value at or
            # near [long]::MaxValue is the "never expires" sentinel that
            # still surfaces here in rare edge cases despite the filter
            # above. [datetime]::FromFileTime throws on that magnitude -
            # skip rather than let one bad account abort the whole report.
            if (-not $raw -or $raw -le 0 -or $raw -ge [long]::MaxValue) { continue }
            try { $expiry = [datetime]::FromFileTime([int64]$raw) } catch { continue }
            if ($expiry -lt $now -or $expiry -gt $cutoff) { continue }

            $rows.Add([PSCustomObject]@{
                DisplayName       = $u.Name
                SamAccountName    = $u.SamAccountName
                PasswordExpiresOn = $expiry.ToString('yyyy-MM-dd HH:mm')
                DaysRemaining     = [math]::Ceiling(($expiry - $now).TotalDays)
                OU                = Get-OUFromDN -DN $u.DistinguishedName
            })
        }
        if (Get-Command Set-Status -ErrorAction SilentlyContinue) {
            Set-Status "Password expiring audit: $($rows.Count) account(s) found." 'ok'
        }
        Write-OperationLog -Context $script:AudCtx -Action 'AUDIT-PWEXPIRING-USERS' -Target 'Domain' -Result 'OK' -Detail "$($rows.Count) found"
    } catch {
        if (Get-Command Set-Status -ErrorAction SilentlyContinue) { Set-Status "Password expiring audit failed: $($_.Exception.Message)" 'err' }
        Write-OperationLog -Context $script:AudCtx -Action 'AUDIT-PWEXPIRING-USERS' -Target 'Domain' -Result 'FAIL' -Detail $_.Exception.Message
    }

    $cols = @('DisplayName','SamAccountName','PasswordExpiresOn','DaysRemaining','OU')
    if ($rows.Count -gt 0) {
        Set-GridData -Grid $script:AudGrids['pwexpiring'] -Data ($rows | Sort-Object DaysRemaining) -Columns $cols
    } else {
        Set-GridData -Grid $script:AudGrids['pwexpiring'] -Data $rows -Columns $cols
    }
}
#endregion

#region -- Invoke-NeverLoggedInUsersAudit ---------------------------------------
function Invoke-NeverLoggedInUsersAudit {
    <#
    .SYNOPSIS
        Enabled users with no recorded logon at all (LastLogonDate is
        never/null), excluding accounts created within the last day so a
        just-onboarded account isn't flagged before its first workday.
        Distinct from Invoke-StaleUsersAudit, which only covers accounts
        that HAVE logged on before but not recently.
    #>
    if (-not $script:AudGrids -or -not $script:AudGrids['neverli']) { return }
    $srvParam = if ($script:AudCtx -and $script:AudCtx.TargetDC) { @{ Server = $script:AudCtx.TargetDC } } else { @{} }
    $minAge   = (Get-Date).AddDays(-1)
    $rows     = [System.Collections.Generic.List[PSCustomObject]]::new()

    try {
        $users = Get-ADUser -Filter { Enabled -eq $true } `
                    -Properties DisplayName, LastLogonDate, whenCreated, DistinguishedName `
                    @srvParam -ErrorAction Stop |
                 Where-Object { -not $_.LastLogonDate -and $_.whenCreated -lt $minAge }

        foreach ($u in $users) {
            $rows.Add([PSCustomObject]@{
                DisplayName    = $u.Name
                SamAccountName = $u.SamAccountName
                Created        = $u.whenCreated
                OU             = Get-OUFromDN -DN $u.DistinguishedName
            })
        }
        if (Get-Command Set-Status -ErrorAction SilentlyContinue) {
            Set-Status "Never logged in audit: $($rows.Count) account(s) found." 'ok'
        }
        Write-OperationLog -Context $script:AudCtx -Action 'AUDIT-NEVERLOGGEDIN-USERS' -Target 'Domain' -Result 'OK' -Detail "$($rows.Count) found"
    } catch {
        if (Get-Command Set-Status -ErrorAction SilentlyContinue) { Set-Status "Never logged in audit failed: $($_.Exception.Message)" 'err' }
        Write-OperationLog -Context $script:AudCtx -Action 'AUDIT-NEVERLOGGEDIN-USERS' -Target 'Domain' -Result 'FAIL' -Detail $_.Exception.Message
    }

    $cols = @('DisplayName','SamAccountName','Created','OU')
    Set-GridData -Grid $script:AudGrids['neverli'] -Data $rows -Columns $cols
}
#endregion

#region -- Invoke-ServiceAccountsAudit -------------------------------------------
function Invoke-ServiceAccountsAudit {
    <#
    .SYNOPSIS
        Every user account (enabled or disabled) with at least one
        Service Principal Name registered - i.e. every account that is a
        Kerberoasting target, since any authenticated user can request a
        service ticket for any SPN-bearing account and attempt to crack the
        returned ticket offline. Multiple SPNs on one account are joined
        with ', ' for display - a grid cell has no line-break rendering
        regardless of separator choice, so a joined single line is the
        practical format here (unlike a mail body, which DOES render CRLF
        as <br> - that one-item-per-line rule applies there, not to grid
        cells; see Services.Mail.Send).
    #>
    if (-not $script:AudGrids -or -not $script:AudGrids['svcacct']) { return }
    $srvParam = if ($script:AudCtx -and $script:AudCtx.TargetDC) { @{ Server = $script:AudCtx.TargetDC } } else { @{} }
    $rows     = [System.Collections.Generic.List[PSCustomObject]]::new()

    try {
        $users = Get-ADUser -Filter * `
                    -Properties DisplayName, Enabled, ServicePrincipalName, DistinguishedName `
                    @srvParam -ErrorAction Stop |
                 Where-Object { $_.ServicePrincipalName -and $_.ServicePrincipalName.Count -gt 0 }

        foreach ($u in $users) {
            $rows.Add([PSCustomObject]@{
                DisplayName    = $u.Name
                SamAccountName = $u.SamAccountName
                Enabled        = [string]$u.Enabled
                SPNCount       = $u.ServicePrincipalName.Count
                SPNs           = ($u.ServicePrincipalName -join ', ')
                OU             = Get-OUFromDN -DN $u.DistinguishedName
            })
        }
        if (Get-Command Set-Status -ErrorAction SilentlyContinue) {
            Set-Status "Service accounts audit: $($rows.Count) account(s) found." 'ok'
        }
        Write-OperationLog -Context $script:AudCtx -Action 'AUDIT-SVC-ACCOUNTS' -Target 'Domain' -Result 'OK' -Detail "$($rows.Count) found"
    } catch {
        if (Get-Command Set-Status -ErrorAction SilentlyContinue) { Set-Status "Service accounts audit failed: $($_.Exception.Message)" 'err' }
        Write-OperationLog -Context $script:AudCtx -Action 'AUDIT-SVC-ACCOUNTS' -Target 'Domain' -Result 'FAIL' -Detail $_.Exception.Message
    }

    $cols = @('DisplayName','SamAccountName','Enabled','SPNCount','SPNs','OU')
    Set-GridData -Grid $script:AudGrids['svcacct'] -Data $rows -Columns $cols

    foreach ($row in $script:AudGrids['svcacct'].Rows) {
        if ($row.Cells['Enabled'].Value -eq 'True') {
            $row.DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(255,235,156)
        }
    }
}
#endregion

#region -- Invoke-PwNeverExpiresAudit --------------------------------------------
function Invoke-PwNeverExpiresAudit {
    <#
    .SYNOPSIS
        Enabled users with PasswordNeverExpires set - a standing security
        exception list worth periodic review (legitimate for some service/
        break-glass accounts, but easy for the flag to persist long after
        the reason for it is gone).
    #>
    if (-not $script:AudGrids -or -not $script:AudGrids['pwneverexp']) { return }
    $srvParam = if ($script:AudCtx -and $script:AudCtx.TargetDC) { @{ Server = $script:AudCtx.TargetDC } } else { @{} }
    $rows     = [System.Collections.Generic.List[PSCustomObject]]::new()

    try {
        $users = Get-ADUser -Filter { Enabled -eq $true -and PasswordNeverExpires -eq $true } `
                    -Properties DisplayName, PasswordLastSet, DistinguishedName `
                    @srvParam -ErrorAction Stop

        foreach ($u in $users) {
            $rows.Add([PSCustomObject]@{
                DisplayName     = $u.Name
                SamAccountName  = $u.SamAccountName
                PasswordLastSet = if ($u.PasswordLastSet) { $u.PasswordLastSet } else { 'Never set' }
                OU              = Get-OUFromDN -DN $u.DistinguishedName
            })
        }
        if (Get-Command Set-Status -ErrorAction SilentlyContinue) {
            Set-Status "Password never expires audit: $($rows.Count) account(s) found." 'ok'
        }
        Write-OperationLog -Context $script:AudCtx -Action 'AUDIT-PWNEVEREXPIRES-USERS' -Target 'Domain' -Result 'OK' -Detail "$($rows.Count) found"
    } catch {
        if (Get-Command Set-Status -ErrorAction SilentlyContinue) { Set-Status "Password never expires audit failed: $($_.Exception.Message)" 'err' }
        Write-OperationLog -Context $script:AudCtx -Action 'AUDIT-PWNEVEREXPIRES-USERS' -Target 'Domain' -Result 'FAIL' -Detail $_.Exception.Message
    }

    $cols = @('DisplayName','SamAccountName','PasswordLastSet','OU')
    Set-GridData -Grid $script:AudGrids['pwneverexp'] -Data $rows -Columns $cols
}
#endregion

#region -- Invoke-DisabledWithGroupsAudit ----------------------------------------
function Invoke-DisabledWithGroupsAudit {
    <#
    .SYNOPSIS
        Disabled users who still hold one or more explicit (non-primary)
        group memberships - offboarding cleanup candidates. GroupCount only
        is shown in the grid to keep it compact; use the right-click "Edit
        Groups..." action (New-UserContextMenu, already wired on this grid)
        to see and remove the specific memberships.
    #>
    if (-not $script:AudGrids -or -not $script:AudGrids['disgrp']) { return }
    $srvParam = if ($script:AudCtx -and $script:AudCtx.TargetDC) { @{ Server = $script:AudCtx.TargetDC } } else { @{} }
    $rows     = [System.Collections.Generic.List[PSCustomObject]]::new()

    try {
        $users = Get-ADUser -Filter { Enabled -eq $false } `
                    -Properties DisplayName, MemberOf, DistinguishedName `
                    @srvParam -ErrorAction Stop |
                 Where-Object { $_.MemberOf -and $_.MemberOf.Count -gt 0 }

        foreach ($u in $users) {
            $rows.Add([PSCustomObject]@{
                DisplayName    = $u.Name
                SamAccountName = $u.SamAccountName
                GroupCount     = $u.MemberOf.Count
                OU             = Get-OUFromDN -DN $u.DistinguishedName
            })
        }
        if (Get-Command Set-Status -ErrorAction SilentlyContinue) {
            Set-Status "Disabled-with-groups audit: $($rows.Count) account(s) found." 'ok'
        }
        Write-OperationLog -Context $script:AudCtx -Action 'AUDIT-DISABLED-WITH-GROUPS' -Target 'Domain' -Result 'OK' -Detail "$($rows.Count) found"
    } catch {
        if (Get-Command Set-Status -ErrorAction SilentlyContinue) { Set-Status "Disabled-with-groups audit failed: $($_.Exception.Message)" 'err' }
        Write-OperationLog -Context $script:AudCtx -Action 'AUDIT-DISABLED-WITH-GROUPS' -Target 'Domain' -Result 'FAIL' -Detail $_.Exception.Message
    }

    $cols = @('DisplayName','SamAccountName','GroupCount','OU')
    Set-GridData -Grid $script:AudGrids['disgrp'] -Data $rows -Columns $cols
}
#endregion

Export-ModuleMember -Function `
    Invoke-StaleUsersAudit, `
    Invoke-LockedOutUsersAudit, `
    Invoke-PwExpiringUsersAudit, `
    Invoke-NeverLoggedInUsersAudit, `
    Invoke-ServiceAccountsAudit, `
    Invoke-PwNeverExpiresAudit, `
    Invoke-DisabledWithGroupsAudit
