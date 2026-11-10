#region -- ADComputers.BitLocker.Lookup.psm1 ----------------------------------
# Concern : Invoke-BitLockerLookup - retrieves BitLocker recovery keys stored
#           in AD DS under the computer object (msFVE-RecoveryInformation).
# Load order: 82 - depends on ADComputers.Connectivity.TestPort (script scope),
#                            Services.AD.Reporting (Set-GridData, Write-OperationLog)
# Split from: ADComputers.Actions.psm1
# Changes   : Added -Grid param so callers (now the BitLocker right-click
#             dialog, ADComputers.BitLocker.Dialog) can supply their own
#             DataGridView instead of the removed BitLocker sub-tab's
#             $script:BitGrid. Falls back to $script:BitGrid if -Grid is
#             not supplied, for backward compatibility.
#endregion

#region -- Invoke-BitLockerLookup ---------------------------------------------
function Invoke-BitLockerLookup {
    param(
        [string]$ComputerName,
        [System.Windows.Forms.DataGridView]$Grid = $null
    )
    $targetGrid = if ($Grid) { $Grid } else { $script:BitGrid }
    $results = [System.Collections.Generic.List[PSCustomObject]]::new()
    try {
        $srv    = $script:CompCtx.TargetDC
        $comp   = Get-ADComputer -Identity $ComputerName -Server $srv -ErrorAction Stop
        $compDN = $comp.DistinguishedName

        $searcher             = New-Object System.DirectoryServices.DirectorySearcher
        $searcher.SearchRoot  = New-Object System.DirectoryServices.DirectoryEntry("LDAP://$compDN")
        $searcher.Filter      = '(objectClass=msFVE-RecoveryInformation)'
        $searcher.SearchScope = 'OneLevel'
        [void]$searcher.PropertiesToLoad.AddRange(@('msFVE-RecoveryPassword','msFVE-RecoveryGuid','whenCreated','Name'))

        foreach ($r in $searcher.FindAll()) {
            $keyId   = [string]($r.Properties['name']                   | Select-Object -First 1)
            $key     = [string]($r.Properties['msfve-recoverypassword'] | Select-Object -First 1)
            $created = $r.Properties['whencreated'] | Select-Object -First 1
            $results.Add([PSCustomObject]@{
                Computer    = $ComputerName
                KeyID       = $keyId
                RecoveryKey = $key
                Created     = if ($created) { ([datetime]$created).ToString('yyyy-MM-dd HH:mm') } else { '' }
            })
        }

        $cols = @('Computer','KeyID','RecoveryKey','Created')
        Set-GridData -Grid $targetGrid -Data $results -Columns $cols

        if ($results.Count -gt 0) {
            Set-Status "Found $($results.Count) BitLocker recovery key(s) for $ComputerName. Double-click a row to copy the key." 'ok'
            Write-OperationLog -Context $script:CompCtx -Action 'BITLOCKER-LOOKUP' `
                -Target $ComputerName -Result 'OK' -Detail "$($results.Count) key(s) retrieved"
        } else {
            Set-Status "No BitLocker recovery keys found in AD for $ComputerName." 'warn'
        }
    } catch {
        Set-Status "BitLocker lookup failed: $($_.Exception.Message)" 'err'
    }
}
#endregion

Export-ModuleMember -Function Invoke-BitLockerLookup
