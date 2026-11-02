#region -- ADAudit.Naming.Query.psm1 -------------------------------------------
# Concern : Get-Violations       - pure naming-convention check against a
#                                   single ADUser object (no AD writes).
#           Invoke-NamingScan    - Subtree scan of the selected OU, populates
#                                   $script:NamingGrid, applies row styling.
#           Update-NamingRow     - re-pulls one user by SAM and refreshes its
#                                   grid row + violation columns + styling.
#                                   Shared by ADAudit.Naming.Repair (called
#                                   after every fix / inline edit) and by
#                                   Invoke-NamingScan's own row styling pass.
#           Get-NamingGridData   - extracts current grid rows for CSV/HTML
#                                   export.
#           Get-NamingSuffixValue- reads the manual Display Suffix textbox
#                                   (placeholder-aware). Internal helper,
#                                   reused by ADAudit.Naming.Repair.
#           Set-NamingRowStyle   - internal helper, applies disabled/ok/fail
#                                   row coloring. Not intended for use outside
#                                   this module and ADAudit.Naming.Repair.
# Load order: depends on Services.AD.Reporting (Set-GridData,
#                        Get-PlaceholderValue), Services.Logging
#                        (Write-OperationLog). Reads script-scope UI refs
#                        ($script:NamingCtx, $script:NamingGrid,
#                        $script:NamingOUBox, $script:NamingSuffixBox,
#                        $script:NamingSummaryLbl) set by
#                        ADAudit.Naming.Tab (Build-NamingTab).
# Scope decisions (per plan): manual Display Suffix textbox only (no source-
#                        file auto-detection); OU scan is SearchScope Subtree
#                        (not OneLevel); no MessageBox anywhere in this module,
#                        only Set-Status / Write-OperationLog.
#endregion

#region -- Get-NamingSuffixValue ------------------------------------------------
function Get-NamingSuffixValue {
    <#
    .SYNOPSIS
        Returns the current Display Suffix textbox value, trimmed. Returns ''
        if the box is showing its placeholder hint or hasn't been built yet.
    #>
    if (-not $script:NamingSuffixBox) { return '' }
    return (Get-PlaceholderValue -TextBox $script:NamingSuffixBox).Trim()
}
#endregion

#region -- Get-Violations --------------------------------------------------------
function Get-Violations {
    <#
    .SYNOPSIS
        Checks one ADUser against the naming convention:
          Display Name : Last, First [optional suffix]
          Canonical    : leaf must match Display Name
          SAM          : must be all uppercase
        Returns a hashtable with DNViolation/CNViolation/SAMViolation/
        ExpectedDN. Empty string on a violation key = compliant for that
        field. Pure function - no AD reads or writes.
    #>
    param(
        [Microsoft.ActiveDirectory.Management.ADUser]$User,
        [string]$DisplaySuffix
    )

    $first = $User.GivenName
    $last  = $User.Surname
    $dn    = $User.DisplayName
    $sam   = $User.SamAccountName
    $cn    = $User.CanonicalName

    $expectedDN = ''
    if ($last -and $first) {
        $expectedDN = if ($DisplaySuffix) { "$last, $first $DisplaySuffix" } else { "$last, $first" }
    } elseif ($last) {
        $expectedDN = $last
    }

    $dnViol = ''
    if (-not $dn) {
        $dnViol = "Not set  (expected: $expectedDN)"
    } elseif ($expectedDN -and $dn -ne $expectedDN) {
        $dnViol = "Expected: $expectedDN"
    }

    $cnViol = ''
    if ($cn) {
        $cnLeaf = $cn -replace '^.*/+', ''
        if ($dn -and $cnLeaf -ne $dn) {
            $cnViol = "CN ends: $cnLeaf"
        }
    }

    $samViol = ''
    if (-not $sam) {
        $samViol = 'Not set'
    } elseif ($sam -cmatch '[a-z]') {
        $samViol = "Has lowercase  (fix: $($sam.ToUpper()))"
    }

    return @{
        DNViolation  = $dnViol
        CNViolation  = $cnViol
        SAMViolation = $samViol
        ExpectedDN   = $expectedDN
    }
}
#endregion

#region -- Set-NamingRowStyle ----------------------------------------------------
function Set-NamingRowStyle {
    param([System.Windows.Forms.DataGridViewRow]$Row)
    if (-not $Row) { return }

    $isDisabled = ($Row.Cells['Disabled'].Value -eq 'Yes')
    $isOK       = ($Row.Cells['DNViolation'].Value  -eq '' -and
                   $Row.Cells['CNViolation'].Value  -eq '' -and
                   $Row.Cells['SAMViolation'].Value -eq '')

    if ($isDisabled) {
        $Row.DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(240,240,240)
        $Row.DefaultCellStyle.ForeColor = [System.Drawing.Color]::FromArgb(140,140,140)
    } elseif ($isOK) {
        $Row.DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(198,239,206)
        $Row.DefaultCellStyle.ForeColor = [System.Drawing.Color]::FromArgb(0,97,0)
    } else {
        $Row.DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(255,213,213)
        $Row.DefaultCellStyle.ForeColor = [System.Drawing.Color]::FromArgb(156,0,6)
    }
}
#endregion

#region -- Invoke-NamingScan -----------------------------------------------------
function Invoke-NamingScan {
    <#
    .SYNOPSIS
        Scans the selected OU (Subtree) for user naming-convention violations
        and populates $script:NamingGrid. Re-applies the editable-column
        override (FirstName/LastName/Description) since Set-GridData rebuilds
        columns from scratch on every call.
    #>
    if (-not $script:NamingCtx -or -not $script:NamingGrid) { return }

    $ouDN = if ($script:NamingOUBox) { $script:NamingOUBox.Text.Trim() } else { '' }
    if (-not $ouDN) {
        if (Get-Command Set-Status -ErrorAction SilentlyContinue) {
            Set-Status 'Select an OU before scanning.' 'warn'
        }
        return
    }

    $suffix   = Get-NamingSuffixValue
    $srvParam = if ($script:NamingCtx.TargetDC) { @{ Server = $script:NamingCtx.TargetDC } } else { @{} }

    if (Get-Command Set-Status -ErrorAction SilentlyContinue) {
        Set-Status 'Loading users for naming scan...'
    }

    try {
        $users = Get-ADUser -Filter '*' -SearchBase $ouDN -SearchScope Subtree `
                     -Properties GivenName,Surname,DisplayName,SamAccountName,CanonicalName,
                                 whenCreated,lastLogonDate,Enabled,LockedOut,Description `
                     @srvParam -ErrorAction Stop | Sort-Object SamAccountName
    } catch {
        if (Get-Command Set-Status -ErrorAction SilentlyContinue) {
            Set-Status "Naming scan failed: $($_.Exception.Message)" 'err'
        }
        Write-OperationLog -Context $script:NamingCtx -Action 'NAMING-SCAN' -Target $ouDN `
            -Result 'FAIL' -Detail $_.Exception.Message
        return
    }

    $results   = [System.Collections.Generic.List[PSCustomObject]]::new()
    $totalFail = 0

    foreach ($u in $users) {
        $viols = Get-Violations -User $u -DisplaySuffix $suffix
        $isOK  = ($viols.DNViolation -eq '' -and $viols.CNViolation -eq '' -and $viols.SAMViolation -eq '')
        if ($u.Enabled -and -not $isOK) { $totalFail++ }

        $cnLeaf = if ($u.CanonicalName) { $u.CanonicalName -replace '^.*/+', '' } else { '-' }

        [void]$results.Add([PSCustomObject]@{
            SamAccountName = [string]$u.SamAccountName
            DisplayName    = [string]$u.DisplayName
            CanonicalName  = $cnLeaf
            Created        = if ($u.whenCreated)   { $u.whenCreated.ToString('yyyy-MM-dd  HH:mm') }   else { '-' }
            LastLogon      = if ($u.lastLogonDate) { $u.lastLogonDate.ToString('yyyy-MM-dd  HH:mm') } else { 'Never' }
            Disabled       = if (-not $u.Enabled)  { 'Yes' } else { '' }
            LockedOut      = if ($u.LockedOut)     { 'Yes' } else { '' }
            DNViolation    = $viols.DNViolation
            CNViolation    = $viols.CNViolation
            SAMViolation   = $viols.SAMViolation
            FirstName      = [string]$u.GivenName
            LastName       = [string]$u.Surname
            Description    = [string]$u.Description
        })
    }

    $cols = @('SamAccountName','DisplayName','CanonicalName','Created','LastLogon','Disabled','LockedOut',
              'DNViolation','CNViolation','SAMViolation','FirstName','LastName','Description')
    Set-GridData -Grid $script:NamingGrid -Data $results -Columns $cols

    # Set-GridData clears and rebuilds $Grid.Columns every call, so the
    # editable-column override must be re-applied here each scan.
    $script:NamingGrid.ReadOnly = $false
    foreach ($col in $script:NamingGrid.Columns) {
        if ($col.Name -in @('FirstName','LastName','Description')) { $col.ReadOnly = $false }
        else { $col.ReadOnly = $true }
    }

    foreach ($row in $script:NamingGrid.Rows) { Set-NamingRowStyle -Row $row }

    $totalOK = $users.Count - $totalFail
    if ($script:NamingSummaryLbl) {
        $script:NamingSummaryLbl.Text      = "$totalFail violation(s)  |  $totalOK compliant"
        $script:NamingSummaryLbl.ForeColor = if ($totalFail -gt 0) {
            [System.Drawing.Color]::FromArgb(180,0,0)
        } else {
            [System.Drawing.Color]::FromArgb(0,120,0)
        }
    }

    if (Get-Command Set-Status -ErrorAction SilentlyContinue) {
        Set-Status "Naming scan: $($users.Count) user(s) checked, $totalFail violation(s)." 'ok'
    }
    Write-OperationLog -Context $script:NamingCtx -Action 'NAMING-SCAN' -Target $ouDN `
        -Result 'OK' -Detail "$($users.Count) users, $totalFail violations"
}
#endregion

#region -- Update-NamingRow ------------------------------------------------------
function Update-NamingRow {
    <#
    .SYNOPSIS
        Re-pulls a single user (identified by the row's current SAM cell) and
        refreshes every display/violation column plus row styling. Callers
        that change the SAM value itself (SAM-uppercase fix) must update
        Row.Cells['SamAccountName'] BEFORE calling this, since the SAM is
        re-read from the cell to perform the lookup.
    #>
    param([System.Windows.Forms.DataGridViewRow]$Row)
    if (-not $Row -or -not $script:NamingCtx) { return }

    $sam      = [string]$Row.Cells['SamAccountName'].Value
    $srvParam = if ($script:NamingCtx.TargetDC) { @{ Server = $script:NamingCtx.TargetDC } } else { @{} }

    try {
        $u = Get-ADUser -Identity $sam `
                 -Properties GivenName,Surname,DisplayName,CanonicalName,
                             whenCreated,lastLogonDate,Enabled,LockedOut,Description `
                 @srvParam -ErrorAction Stop
    } catch { return }

    $suffix = Get-NamingSuffixValue
    $viols  = Get-Violations -User $u -DisplaySuffix $suffix
    $cnLeaf = if ($u.CanonicalName) { $u.CanonicalName -replace '^.*/+', '' } else { '-' }

    $Row.Cells['DisplayName'].Value   = [string]$u.DisplayName
    $Row.Cells['CanonicalName'].Value = $cnLeaf
    $Row.Cells['LastLogon'].Value     = if ($u.lastLogonDate) { $u.lastLogonDate.ToString('yyyy-MM-dd  HH:mm') } else { 'Never' }
    $Row.Cells['Disabled'].Value      = if (-not $u.Enabled)  { 'Yes' } else { '' }
    $Row.Cells['LockedOut'].Value     = if ($u.LockedOut)     { 'Yes' } else { '' }
    $Row.Cells['DNViolation'].Value   = $viols.DNViolation
    $Row.Cells['CNViolation'].Value   = $viols.CNViolation
    $Row.Cells['SAMViolation'].Value  = $viols.SAMViolation
    $Row.Cells['FirstName'].Value     = [string]$u.GivenName
    $Row.Cells['LastName'].Value      = [string]$u.Surname
    $Row.Cells['Description'].Value   = [string]$u.Description

    Set-NamingRowStyle -Row $Row
}
#endregion

#region -- Get-NamingGridData ----------------------------------------------------
function Get-NamingGridData {
    <#
    .SYNOPSIS
        Extracts the current NamingGrid rows as a list of PSCustomObjects.
        Used by the Export CSV/HTML buttons in Build-NamingTab.
    #>
    $data = [System.Collections.Generic.List[PSCustomObject]]::new()
    if (-not $script:NamingGrid) { return $data }
    foreach ($row in $script:NamingGrid.Rows) {
        [void]$data.Add([PSCustomObject]@{
            SamAccountName = $row.Cells['SamAccountName'].Value
            DisplayName    = $row.Cells['DisplayName'].Value
            CanonicalName  = $row.Cells['CanonicalName'].Value
            Created        = $row.Cells['Created'].Value
            LastLogon      = $row.Cells['LastLogon'].Value
            Disabled       = $row.Cells['Disabled'].Value
            LockedOut      = $row.Cells['LockedOut'].Value
            DNViolation    = $row.Cells['DNViolation'].Value
            CNViolation    = $row.Cells['CNViolation'].Value
            SAMViolation   = $row.Cells['SAMViolation'].Value
            FirstName      = $row.Cells['FirstName'].Value
            LastName       = $row.Cells['LastName'].Value
            Description    = $row.Cells['Description'].Value
        })
    }
    return $data
}
#endregion

Export-ModuleMember -Function `
    Get-NamingSuffixValue, `
    Get-Violations, `
    Set-NamingRowStyle, `
    Invoke-NamingScan, `
    Update-NamingRow, `
    Get-NamingGridData
