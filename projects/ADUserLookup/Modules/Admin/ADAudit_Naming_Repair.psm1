#region -- ADAudit.Naming.Repair.psm1 --------------------------------------------
# Concern : Invoke-NamingFixDisplayName   - sets DisplayName to Last, First
#                                            [suffix] for selected rows.
#           Invoke-NamingFixCanonicalName - Rename-ADObject so the CN leaf
#                                            matches DisplayName for selected
#                                            rows.
#           Invoke-NamingFixSamUppercase  - uppercases SamAccountName (+ UPN
#                                            prefix if it matched) for selected
#                                            rows that have a SAM violation.
#           Invoke-NamingCellCommit       - handles inline DataGridView edits
#                                            to FirstName/LastName/Description.
#           Invoke-NamingBulkDescription  - right-click bulk set/clear of
#                                            Description across selected rows.
#           All AD writes are wrapped try/catch and logged via
#           Write-OperationLog (OK or FAIL per account); no MessageBox is
#           used anywhere in this module. Confirm-Action (themed Yes/No form)
#           gates the three Fix actions and the bulk Clear action, per plan.
# Load order: depends on ADAudit.Naming.Query (Get-NamingSuffixValue,
#                        Update-NamingRow), Services.AD.Reporting
#                        (Confirm-Action), Services.Logging
#                        (Write-OperationLog). Reads $script:NamingCtx set by
#                        ADAudit.Naming.Tab (Build-NamingTab).
#endregion

#region -- Invoke-NamingFixDisplayName -------------------------------------------
function Invoke-NamingFixDisplayName {
    param([System.Windows.Forms.DataGridViewRow[]]$Rows)
    if (-not $Rows -or $Rows.Count -eq 0 -or -not $script:NamingCtx) { return }

    $suffix = Get-NamingSuffixValue
    $msg    = "Fix Display Name for $($Rows.Count) selected account(s)?`n`n" +
              "Sets DisplayName to: Last, First$(if ($suffix) { " $suffix" })"
    if (-not (Confirm-Action -Title 'Fix Display Name' -Message $msg -ActionLabel 'Fix Display Name')) { return }

    $srvParam = if ($script:NamingCtx.TargetDC) { @{ Server = $script:NamingCtx.TargetDC } } else { @{} }
    $fixed = 0 ; $errors = 0

    foreach ($row in $Rows) {
        $sam = [string]$row.Cells['SamAccountName'].Value
        try {
            $u     = Get-ADUser -Identity $sam -Properties GivenName,Surname @srvParam -ErrorAction Stop
            $first = $u.GivenName ; $last = $u.Surname
            $newDN = if ($last -and $first) {
                if ($suffix) { "$last, $first $suffix" } else { "$last, $first" }
            } elseif ($last) { $last } else { $null }
            if (-not $newDN) { throw 'No Surname on file; cannot compute Display Name.' }

            Set-ADUser -Identity $sam -DisplayName $newDN @srvParam -ErrorAction Stop
            Write-OperationLog -Context $script:NamingCtx -Action 'NAMING-FIX-DN' -Target $sam -Result 'OK' -Detail $newDN
            Update-NamingRow -Row $row
            $fixed++
        } catch {
            Write-OperationLog -Context $script:NamingCtx -Action 'NAMING-FIX-DN' -Target $sam `
                -Result 'FAIL' -Detail $_.Exception.Message
            $errors++
        }
    }

    $level = if ($errors -gt 0) { 'warn' } else { 'ok' }
    if (Get-Command Set-Status -ErrorAction SilentlyContinue) {
        Set-Status "Display Name fix: $fixed updated, $errors error(s)." $level
    }
}
#endregion

#region -- Invoke-NamingFixCanonicalName -----------------------------------------
function Invoke-NamingFixCanonicalName {
    param([System.Windows.Forms.DataGridViewRow[]]$Rows)
    if (-not $Rows -or $Rows.Count -eq 0 -or -not $script:NamingCtx) { return }

    $msg = "Fix Canonical Name for $($Rows.Count) selected account(s)?`n`n" +
           "Renames the AD object so its CN path matches the Display Name."
    if (-not (Confirm-Action -Title 'Fix Canonical Name' -Message $msg -ActionLabel 'Fix Canonical Name')) { return }

    $srvParam = if ($script:NamingCtx.TargetDC) { @{ Server = $script:NamingCtx.TargetDC } } else { @{} }
    $fixed = 0 ; $errors = 0

    foreach ($row in $Rows) {
        $sam = [string]$row.Cells['SamAccountName'].Value
        try {
            $u = Get-ADUser -Identity $sam -Properties DisplayName,DistinguishedName @srvParam -ErrorAction Stop
            if (-not $u.DisplayName) { throw 'No Display Name set; cannot rename.' }

            Rename-ADObject -Identity $u.DistinguishedName -NewName $u.DisplayName @srvParam -ErrorAction Stop
            Write-OperationLog -Context $script:NamingCtx -Action 'NAMING-FIX-CN' -Target $sam -Result 'OK' -Detail $u.DisplayName
            Update-NamingRow -Row $row
            $fixed++
        } catch {
            Write-OperationLog -Context $script:NamingCtx -Action 'NAMING-FIX-CN' -Target $sam `
                -Result 'FAIL' -Detail $_.Exception.Message
            $errors++
        }
    }

    $level = if ($errors -gt 0) { 'warn' } else { 'ok' }
    if (Get-Command Set-Status -ErrorAction SilentlyContinue) {
        Set-Status "Canonical Name fix: $fixed renamed, $errors error(s)." $level
    }
}
#endregion

#region -- Invoke-NamingFixSamUppercase ------------------------------------------
function Invoke-NamingFixSamUppercase {
    param([System.Windows.Forms.DataGridViewRow[]]$Rows)
    if (-not $Rows -or $Rows.Count -eq 0 -or -not $script:NamingCtx) { return }

    $toFix = @($Rows | Where-Object { [string]$_.Cells['SAMViolation'].Value -ne '' })
    if ($toFix.Count -eq 0) {
        if (Get-Command Set-Status -ErrorAction SilentlyContinue) {
            Set-Status 'No SAM uppercase violations in the selected rows.' 'warn'
        }
        return
    }

    $msg = "Fix SAM uppercase for $($toFix.Count) account(s)?`n`n" +
           "Each SAM account name will be converted to uppercase."
    if (-not (Confirm-Action -Title 'Fix SAM Uppercase' -Message $msg -ActionLabel 'Fix SAM Uppercase')) { return }

    $srvParam = if ($script:NamingCtx.TargetDC) { @{ Server = $script:NamingCtx.TargetDC } } else { @{} }
    $fixed = 0 ; $errors = 0

    foreach ($row in $toFix) {
        $sam    = [string]$row.Cells['SamAccountName'].Value
        $newSam = $sam.ToUpper()
        try {
            Set-ADUser -Identity $sam -SamAccountName $newSam @srvParam -ErrorAction Stop

            $u = Get-ADUser -Identity $newSam -Properties UserPrincipalName @srvParam -ErrorAction SilentlyContinue
            if ($u -and $u.UserPrincipalName -imatch "^$([regex]::Escape($sam))@") {
                $newUPN = $u.UserPrincipalName -replace "^$([regex]::Escape($sam))@", "$newSam@"
                Set-ADUser -Identity $newSam -UserPrincipalName $newUPN @srvParam -ErrorAction SilentlyContinue
            }

            Write-OperationLog -Context $script:NamingCtx -Action 'NAMING-FIX-SAM' -Target $sam -Result 'OK' -Detail "-> $newSam"
            $row.Cells['SamAccountName'].Value = $newSam
            Update-NamingRow -Row $row
            $fixed++
        } catch {
            Write-OperationLog -Context $script:NamingCtx -Action 'NAMING-FIX-SAM' -Target $sam `
                -Result 'FAIL' -Detail $_.Exception.Message
            $errors++
        }
    }

    $level = if ($errors -gt 0) { 'warn' } else { 'ok' }
    if (Get-Command Set-Status -ErrorAction SilentlyContinue) {
        Set-Status "SAM uppercase fix: $fixed updated, $errors error(s)." $level
    }
}
#endregion

#region -- Invoke-NamingCellCommit -----------------------------------------------
function Invoke-NamingCellCommit {
    <#
    .SYNOPSIS
        Called from Build-NamingTab's grid CellEndEdit handler after an
        inline edit to FirstName, LastName, or Description commits. Skips
        the AD write (and the log entry) if the value is unchanged.
    #>
    param(
        [System.Windows.Forms.DataGridViewRow]$Row,
        [string]$ColumnName,
        [object]$OldValue
    )
    if (-not $Row -or -not $script:NamingCtx) { return }
    if ($ColumnName -notin @('FirstName','LastName','Description')) { return }

    $sam    = [string]$Row.Cells['SamAccountName'].Value
    $newVal = [string]$Row.Cells[$ColumnName].Value
    $oldVal = [string]$OldValue
    if ($newVal -ceq $oldVal) { return }

    $srvParam = if ($script:NamingCtx.TargetDC) { @{ Server = $script:NamingCtx.TargetDC } } else { @{} }

    try {
        switch ($ColumnName) {
            'FirstName' { Set-ADUser -Identity $sam -GivenName $newVal @srvParam -ErrorAction Stop }
            'LastName'  { Set-ADUser -Identity $sam -Surname   $newVal @srvParam -ErrorAction Stop }
            'Description' {
                if ($newVal -eq '') { Set-ADUser -Identity $sam -Clear Description @srvParam -ErrorAction Stop }
                else                { Set-ADUser -Identity $sam -Description $newVal @srvParam -ErrorAction Stop }
            }
        }

        $dispVal = if ($newVal -eq '') { '(cleared)' } else { $newVal }
        Write-OperationLog -Context $script:NamingCtx -Action 'NAMING-EDIT' -Target $sam `
            -Result 'OK' -Detail "$ColumnName = $dispVal"

        if ($ColumnName -in @('FirstName','LastName')) { Update-NamingRow -Row $Row }

        if (Get-Command Set-Status -ErrorAction SilentlyContinue) {
            Set-Status "Updated $sam  [$ColumnName] = $dispVal" 'ok'
        }
    } catch {
        Write-OperationLog -Context $script:NamingCtx -Action 'NAMING-EDIT' -Target $sam `
            -Result 'FAIL' -Detail $_.Exception.Message
        if (Get-Command Set-Status -ErrorAction SilentlyContinue) {
            Set-Status "ERROR updating $sam : $($_.Exception.Message)" 'err'
        }
    }
}
#endregion

#region -- Invoke-NamingBulkDescription ------------------------------------------
function Invoke-NamingBulkDescription {
    <#
    .SYNOPSIS
        Right-click bulk action: sets (or clears) Description across all
        selected rows. Clear is gated by Confirm-Action; Set is not (the
        InputBox that collects the value already requires an explicit OK).
    #>
    param(
        [System.Windows.Forms.DataGridViewRow[]]$Rows,
        [string]$Value = '',
        [switch]$Clear
    )
    if (-not $Rows -or $Rows.Count -eq 0 -or -not $script:NamingCtx) { return }

    if ($Clear) {
        $msg = "Clear description for $($Rows.Count) selected account(s)?"
        if (-not (Confirm-Action -Title 'Clear Description' -Message $msg -ActionLabel 'Clear Description')) { return }
    }

    $srvParam = if ($script:NamingCtx.TargetDC) { @{ Server = $script:NamingCtx.TargetDC } } else { @{} }
    $fixed = 0 ; $errors = 0

    foreach ($row in $Rows) {
        $sam = [string]$row.Cells['SamAccountName'].Value
        try {
            if ($Clear -or $Value -eq '') {
                Set-ADUser -Identity $sam -Clear Description @srvParam -ErrorAction Stop
                $row.Cells['Description'].Value = ''
            } else {
                Set-ADUser -Identity $sam -Description $Value @srvParam -ErrorAction Stop
                $row.Cells['Description'].Value = $Value
            }
            Write-OperationLog -Context $script:NamingCtx -Action 'NAMING-BULK-DESC' -Target $sam -Result 'OK' -Detail $Value
            $fixed++
        } catch {
            Write-OperationLog -Context $script:NamingCtx -Action 'NAMING-BULK-DESC' -Target $sam `
                -Result 'FAIL' -Detail $_.Exception.Message
            $errors++
        }
    }

    $level = if ($errors -gt 0) { 'warn' } else { 'ok' }
    if (Get-Command Set-Status -ErrorAction SilentlyContinue) {
        Set-Status "Description bulk update: $fixed updated, $errors error(s)." $level
    }
}
#endregion

Export-ModuleMember -Function `
    Invoke-NamingFixDisplayName, `
    Invoke-NamingFixCanonicalName, `
    Invoke-NamingFixSamUppercase, `
    Invoke-NamingCellCommit, `
    Invoke-NamingBulkDescription
