#region -- ADAudit.ListReports.Query.Computers.psm1 ---------------------------
# Concern : Two independent, read-only audit queries against AD computer
#           objects, each populating one grid on the Audit tab's sub-tab
#           pages: Stale Computers, Disabled Computers. Self-contained the
#           same way as ADAudit.ListReports.Query.Users - see that module's
#           header for the shared design notes (thresholds, LastLogonDate
#           accuracy) that apply equally here.
# Load order: depends on ADAudit.Register-AuditTab (script scope: $script:AudCtx,
#                        $script:AudGrids),
#                        ADAudit.ListReports.Query.Users ($script:AudStaleDays -
#                        the SAME 90-day threshold is reused here rather than
#                        a second copy of the constant, so the two "stale"
#                        reports can never silently drift apart),
#                        Services.AD.Connection.Query (Get-OUFromDN),
#                        Services.AD.Reporting (Set-GridData, Write-OperationLog)
# Split from: (new module)
#endregion

#region -- Invoke-StaleComputersAudit --------------------------------------------
function Invoke-StaleComputersAudit {
    <#
    .SYNOPSIS
        Enabled computers whose last logon (replicated lastLogonTimestamp)
        is older than $script:AudStaleDays, OR that have never logged on at
        all. Unlike the Users side, "never logged on" is folded into this
        one list rather than split out separately - a computer object that
        has genuinely never authenticated (as opposed to a user who simply
        hasn't started yet) is itself already a stale/orphaned-object
        signal, not a "give it time" one.
    #>
    if (-not $script:AudGrids -or -not $script:AudGrids['stalecomp']) { return }
    $srvParam  = if ($script:AudCtx -and $script:AudCtx.TargetDC) { @{ Server = $script:AudCtx.TargetDC } } else { @{} }
    $staleDays = if ($script:AudStaleDays) { $script:AudStaleDays } else { 90 }
    $cutoff    = (Get-Date).AddDays(-$staleDays)
    $rows      = [System.Collections.Generic.List[PSCustomObject]]::new()

    try {
        $comps = Get-ADComputer -Filter { Enabled -eq $true } `
                    -Properties LastLogonDate, OperatingSystem, DistinguishedName `
                    @srvParam -ErrorAction Stop |
                 Where-Object { -not $_.LastLogonDate -or $_.LastLogonDate -lt $cutoff }

        foreach ($c in $comps) {
            $rows.Add([PSCustomObject]@{
                Name            = $c.Name
                LastLogon       = if ($c.LastLogonDate) { $c.LastLogonDate } else { $null }
                DaysSinceLogon  = if ($c.LastLogonDate) { [math]::Round(((Get-Date) - $c.LastLogonDate).TotalDays) } else { $null }
                OperatingSystem = if ($c.OperatingSystem) { $c.OperatingSystem } else { '-' }
                OU              = if (Get-Command Get-OUFromDN -ErrorAction SilentlyContinue) { Get-OUFromDN -DN $c.DistinguishedName } else { '' }
            })
        }
        if (Get-Command Set-Status -ErrorAction SilentlyContinue) {
            Set-Status "Stale computers audit: $($rows.Count) computer(s) found." 'ok'
        }
        Write-OperationLog -Context $script:AudCtx -Action 'AUDIT-STALE-COMPUTERS' -Target 'Domain' -Result 'OK' -Detail "$($rows.Count) found"
    } catch {
        if (Get-Command Set-Status -ErrorAction SilentlyContinue) { Set-Status "Stale computers audit failed: $($_.Exception.Message)" 'err' }
        Write-OperationLog -Context $script:AudCtx -Action 'AUDIT-STALE-COMPUTERS' -Target 'Domain' -Result 'FAIL' -Detail $_.Exception.Message
    }

    $cols = @('Name','LastLogon','DaysSinceLogon','OperatingSystem','OU')
    Set-GridData -Grid $script:AudGrids['stalecomp'] -Data $rows -Columns $cols
}
#endregion

#region -- Invoke-DisabledComputersAudit ------------------------------------------
function Invoke-DisabledComputersAudit {
    <#
    .SYNOPSIS
        Disabled computer objects that were never actually deleted -
        cleanup candidates parallel to the Users "Disabled but Still in
        Groups" report, though computers are flagged here simply for being
        disabled-and-lingering rather than for any group membership.
    #>
    if (-not $script:AudGrids -or -not $script:AudGrids['discomp']) { return }
    $srvParam = if ($script:AudCtx -and $script:AudCtx.TargetDC) { @{ Server = $script:AudCtx.TargetDC } } else { @{} }
    $rows     = [System.Collections.Generic.List[PSCustomObject]]::new()

    try {
        $comps = Get-ADComputer -Filter { Enabled -eq $false } `
                    -Properties OperatingSystem, whenChanged, DistinguishedName `
                    @srvParam -ErrorAction Stop

        foreach ($c in $comps) {
            $rows.Add([PSCustomObject]@{
                Name            = $c.Name
                OperatingSystem = if ($c.OperatingSystem) { $c.OperatingSystem } else { '-' }
                LastChanged     = if ($c.whenChanged) { $c.whenChanged } else { $null }
                OU              = if (Get-Command Get-OUFromDN -ErrorAction SilentlyContinue) { Get-OUFromDN -DN $c.DistinguishedName } else { '' }
            })
        }
        if (Get-Command Set-Status -ErrorAction SilentlyContinue) {
            Set-Status "Disabled computers audit: $($rows.Count) computer(s) found." 'ok'
        }
        Write-OperationLog -Context $script:AudCtx -Action 'AUDIT-DISABLED-COMPUTERS' -Target 'Domain' -Result 'OK' -Detail "$($rows.Count) found"
    } catch {
        if (Get-Command Set-Status -ErrorAction SilentlyContinue) { Set-Status "Disabled computers audit failed: $($_.Exception.Message)" 'err' }
        Write-OperationLog -Context $script:AudCtx -Action 'AUDIT-DISABLED-COMPUTERS' -Target 'Domain' -Result 'FAIL' -Detail $_.Exception.Message
    }

    $cols = @('Name','OperatingSystem','LastChanged','OU')
    Set-GridData -Grid $script:AudGrids['discomp'] -Data $rows -Columns $cols
}
#endregion

Export-ModuleMember -Function Invoke-StaleComputersAudit, Invoke-DisabledComputersAudit
