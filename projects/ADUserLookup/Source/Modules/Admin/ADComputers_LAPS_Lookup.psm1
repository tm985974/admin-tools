#region -- ADComputers.LAPS.Lookup.psm1 ---------------------------------------
# Concern : Invoke-LAPSLookup - retrieves the local administrator password from
#           Windows LAPS (Get-LapsADPassword) or Legacy LAPS (ms-Mcs-AdmPwd).
#           Falls back to legacy if the Windows LAPS cmdlet is unavailable.
# Load order: 85 - depends on ADComputers.Connectivity.TestPort (script scope),
#                            Services.AD.Reporting (Set-GridData, Write-OperationLog)
# Split from: ADComputers.Actions.psm1
# Changes   : Added -Grid param so callers (now the LAPS right-click dialog,
#             ADComputers.LAPS.Dialog) can supply their own DataGridView
#             instead of the removed LAPS sub-tab's $script:LapsResultGrid.
#             Falls back to $script:LapsResultGrid if -Grid is not supplied,
#             for backward compatibility.
#endregion

#region -- Invoke-LAPSLookup --------------------------------------------------
function Invoke-LAPSLookup {
    param(
        [string]$ComputerName,
        [System.Windows.Forms.DataGridView]$Grid = $null
    )
    $targetGrid = if ($Grid) { $Grid } else { $script:LapsResultGrid }
    $results  = [System.Collections.Generic.List[PSCustomObject]]::new()
    $srv      = $script:CompCtx.TargetDC
    $foundNew = $false

    try {
        if (Get-Command Get-LapsADPassword -ErrorAction SilentlyContinue) {
            $lapsResult = Get-LapsADPassword -Identity $ComputerName -Server $srv -ErrorAction Stop
            if ($lapsResult) {
                $results.Add([PSCustomObject]@{
                    Computer  = $ComputerName
                    LAPSType  = 'Windows LAPS'
                    Account   = $lapsResult.Account
                    Password  = $lapsResult.Password
                    ExpiresOn = if ($lapsResult.PasswordExpirationTimestamp) {
                        $lapsResult.PasswordExpirationTimestamp.ToString('yyyy-MM-dd HH:mm')
                    } else { '' }
                })
                $foundNew = $true
            }
        }
    } catch { }

    if (-not $foundNew) {
        try {
            $comp = Get-ADComputer -Identity $ComputerName `
                        -Properties 'ms-Mcs-AdmPwd','ms-Mcs-AdmPwdExpirationTime' `
                        -Server $srv -ErrorAction Stop
            $pw = $comp.'ms-Mcs-AdmPwd'
            if ($pw) {
                $exp    = $comp.'ms-Mcs-AdmPwdExpirationTime'
                $expStr = ''
                if ($exp) { try { $expStr = [datetime]::FromFileTime($exp).ToString('yyyy-MM-dd HH:mm') } catch { } }
                $results.Add([PSCustomObject]@{
                    Computer  = $ComputerName
                    LAPSType  = 'Legacy LAPS'
                    Account   = 'Administrator'
                    Password  = $pw
                    ExpiresOn = $expStr
                })
            }
        } catch { }
    }

    $cols = @('Computer','LAPSType','Account','Password','ExpiresOn')
    Set-GridData -Grid $targetGrid -Data $results -Columns $cols

    if ($results.Count -gt 0) {
        Set-Status "LAPS password retrieved for $ComputerName. Double-click to copy." 'ok'
        Write-OperationLog -Context $script:CompCtx -Action 'LAPS-LOOKUP' `
            -Target $ComputerName -Result 'OK' -Detail "Type=$($results[0].LAPSType)"
    } else {
        Set-Status "No LAPS password found for $ComputerName. Check permissions or LAPS deployment." 'warn'
    }
}
#endregion

Export-ModuleMember -Function Invoke-LAPSLookup
