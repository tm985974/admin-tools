#region -- ADUserActions.Offboard.TargetList.psm1 ------------------------------
# Concern : Loads/caches the full AD user candidate list for the Offboard
#           target grid and applies the single-select inactivity filter.
#           Read-OffboardTargetUsers - loads (or reloads with -Force) the
#             full user list via Get-DomainUsers, caches it in
#             $script:UAOffAllUsers, then renders through the current filter.
#           Update-OffboardTargetGrid - re-applies the current filter
#             selection to the cached list and repopulates
#             $script:UAOffTargetGrid. Called directly by the filter
#             dropdown's SelectedIndexChanged - no AD round-trip needed to
#             switch filters, only to refresh the underlying data.
# Load order: 43a - depends on Services.AD.Connection.Query (Get-DomainUsers),
#                             Services.AD.Reporting (Set-GridData). Reads/
#                             writes $script:UAOffTargetGrid and
#                             $script:UAOffFilterCombo, set by
#                             ADUserActions.Offboard.Tab (Build-OffboardPanel).
# Split from: kept separate from ADUserActions.Offboard.Tab.psm1 - grid
#             population/filtering is a distinct responsibility from tab
#             construction, matching the ADAudit.Naming.Query / Naming.Tab
#             split already used elsewhere in this project.
#endregion

#region -- Shared script-scope state -------------------------------------------
# Cached full candidate list (all AD users, enabled + disabled). Populated by
# Read-OffboardTargetUsers, re-filtered client-side by Update-OffboardTargetGrid
# on every filter change - avoids a fresh AD query per filter click.
$script:UAOffAllUsers = $null
#endregion

#region -- Read-OffboardTargetUsers ---------------------------------------------
function Read-OffboardTargetUsers {
    <#
    .SYNOPSIS
        Loads the full AD user list (enabled + disabled) for the Offboard
        target grid. Uses the cached list unless -Force is passed (first
        load, manual refresh, or after a completed offboarding run so
        processed accounts drop out of the visible set).
    #>
    param([switch]$Force)

    if (-not $script:UAOffTargetGrid) { return }

    if ($script:UAOffAllUsers -and -not $Force) {
        Update-OffboardTargetGrid
        return
    }

    if (Get-Command Set-Status -ErrorAction SilentlyContinue) {
        Set-Status 'Loading AD user list for offboarding...'
    }

    $srv = if ($script:UAContext -and $script:UAContext.TargetDC) { $script:UAContext.TargetDC } else { '' }

    try {
        $script:UAOffAllUsers = @(Get-DomainUsers -Server $srv -IncludeDisabled)
        Update-OffboardTargetGrid
        if (Get-Command Set-Status -ErrorAction SilentlyContinue) {
            Set-Status "Offboarding target list: $($script:UAOffAllUsers.Count) user(s) loaded." 'ok'
        }
    } catch {
        $script:UAOffAllUsers = @()
        Update-OffboardTargetGrid
        if (Get-Command Set-Status -ErrorAction SilentlyContinue) {
            Set-Status "Failed to load AD users: $($_.Exception.Message)" 'err'
        }
    }
}
#endregion

#region -- Update-OffboardTargetGrid --------------------------------------------
function Update-OffboardTargetGrid {
    <#
    .SYNOPSIS
        Applies the current filter dropdown selection (All / Inactive 90+
        days / Inactive 180+ days / Never logged in) to the cached user list
        and repopulates $script:UAOffTargetGrid. Purely client-side - no AD
        query. Safe to call before any data has loaded (renders empty).
    #>
    if (-not $script:UAOffTargetGrid) { return }

    $all    = @($script:UAOffAllUsers)
    $filter = if ($script:UAOffFilterCombo -and $script:UAOffFilterCombo.SelectedItem) {
        [string]$script:UAOffFilterCombo.SelectedItem
    } else { 'All' }

    $cutoff90  = (Get-Date).AddDays(-90)
    $cutoff180 = (Get-Date).AddDays(-180)

    $filtered = switch ($filter) {
        'Inactive 90+ days'  { @($all | Where-Object { $_.LastLogonDate -and $_.LastLogonDate -le $cutoff90 }) }
        'Inactive 180+ days' { @($all | Where-Object { $_.LastLogonDate -and $_.LastLogonDate -le $cutoff180 }) }
        'Never logged in'    { @($all | Where-Object { -not $_.LastLogonDate }) }
        default              { $all }
    }

    $data = @($filtered | ForEach-Object {
        [PSCustomObject]@{
            SamAccountName = [string]$_.SamAccountName
            DisplayName    = [string]$_.DisplayName
            Enabled        = if ($_.Enabled) { 'Yes' } else { 'No' }
            LastLogon      = if ($_.LastLogonDate) { $_.LastLogonDate.ToString('yyyy-MM-dd') } else { 'Never' }
        }
    })

    $cols = @('SamAccountName','DisplayName','Enabled','LastLogon')
    Set-GridData -Grid $script:UAOffTargetGrid -Data $data -Columns $cols

    if (Get-Command Set-Status -ErrorAction SilentlyContinue) {
        Set-Status "Offboarding target list: $($filtered.Count) of $($all.Count) user(s) shown." 'info'
    }
}
#endregion

Export-ModuleMember -Function `
    Read-OffboardTargetUsers, `
    Update-OffboardTargetGrid
