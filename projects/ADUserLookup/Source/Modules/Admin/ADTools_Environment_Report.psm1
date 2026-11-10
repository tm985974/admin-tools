#region -- ADTools.Environment.Report.psm1 ------------------------------------
# Concern : Update-EnvReport - builds the capability matrix from a Caps object,
#           populates EnvGrid with colour-coded status rows, and renders a
#           structured RTB summary into EnvRtb. Stores data in $script:EnvData.
# Load order: 123 - depends on ADTools.PasswordGenerator.Engine (script scope),
#                            Services.AD.Reporting (Set-GridData)
# Split from: ADTools.Actions.psm1
#endregion

#region -- Add-Row (private helper) -------------------------------------------
function Add-EnvRow {
    param(
        [System.Collections.Generic.List[PSCustomObject]]$Results,
        [string]$Cat,[string]$Item,[string]$Value,[string]$Status,[string]$Note=''
    )
    $Results.Add([PSCustomObject]@{ Category=$Cat; Item=$Item; Value=$Value; Status=$Status; Note=$Note })
}
#endregion

#region -- Update-EnvReport ---------------------------------------------------
function Update-EnvReport {
    param([PSCustomObject]$Caps)
    $results = [System.Collections.Generic.List[PSCustomObject]]::new()
    $C_OK    = [System.Drawing.Color]::FromArgb(198,239,206)
    $C_FAIL  = [System.Drawing.Color]::FromArgb(255,199,206)
    $C_WARN  = [System.Drawing.Color]::FromArgb(255,235,156)

    Add-EnvRow $results 'PowerShell' 'Version'    $Caps.PS_Version `
        $(if ($Caps.PS_Major -ge 5) {'PASS'} else {'WARN'}) ''
    Add-EnvRow $results 'System'     'OS'         $Caps.OS_Caption 'INFO' ''
    Add-EnvRow $results 'System'     'Elevated'   ([string]$Caps.IsElevated) `
        $(if ($Caps.IsElevated) {'PASS'} else {'WARN'}) `
        $(if (-not $Caps.IsElevated) {'Some operations require elevation'})
    Add-EnvRow $results 'AD'         'AD Module'  $(if ($Caps.ADModule) {'Present'} else {'Missing'}) `
        $(if ($Caps.ADModule) {'PASS'} else {'FAIL'}) `
        $(if (-not $Caps.ADModule) {'Install RSAT AD DS Tools'})
    Add-EnvRow $results 'RSAT'       'DNS Tools'  $(if ($Caps.RSAT_DNS)  {'Present'} else {'Missing'}) `
        $(if ($Caps.RSAT_DNS)  {'PASS'} else {'WARN'}) ''
    Add-EnvRow $results 'RSAT'       'DHCP Tools' $(if ($Caps.RSAT_DHCP) {'Present'} else {'Missing'}) `
        $(if ($Caps.RSAT_DHCP) {'PASS'} else {'WARN'}) ''
    Add-EnvRow $results 'RSAT'       'GPMC / GPO' $(if ($Caps.RSAT_GPO)  {'Present'} else {'Missing'}) `
        $(if ($Caps.RSAT_GPO)  {'PASS'} else {'WARN'}) ''
    Add-EnvRow $results 'LAPS'       'LAPS' `
        $(if ($Caps.LAPS_Present) { $Caps.LAPS_Version } else { 'Not Detected' }) `
        $(if ($Caps.LAPS_Present) {'PASS'} else {'INFO'}) ''
    Add-EnvRow $results 'Network'    'WinRM'      $(if ($Caps.WinRM) {'Running'} else {'Stopped'}) `
        $(if ($Caps.WinRM) {'PASS'} else {'WARN'}) `
        $(if (-not $Caps.WinRM) {'Remote session scanning may be limited'})

    $script:EnvData = $results
    $cols = @('Category','Item','Value','Status','Note')
    Set-GridData -Grid $script:EnvGrid -Data $results -Columns $cols

    foreach ($row in $script:EnvGrid.Rows) {
        $row.DefaultCellStyle.BackColor = switch ($row.Cells['Status'].Value) {
            'PASS' { $C_OK } 'FAIL' { $C_FAIL } 'WARN' { $C_WARN }
            default { [System.Drawing.Color]::White }
        }
    }

    $rtb = $script:EnvRtb; $rtb.Clear()
    $F_B = New-Object System.Drawing.Font('Consolas',9,[System.Drawing.FontStyle]::Bold)
    $F_N = New-Object System.Drawing.Font('Consolas',9)
    foreach ($r in $results) {
        $rtb.SelectionFont  = $F_B
        $rtb.SelectionColor = switch ($r.Status) {
            'PASS' { [System.Drawing.Color]::FromArgb(0,120,0)   }
            'FAIL' { [System.Drawing.Color]::FromArgb(180,0,0)   }
            'WARN' { [System.Drawing.Color]::FromArgb(160,100,0) }
            default{ [System.Drawing.Color]::DimGray             }
        }
        $rtb.AppendText("[$($r.Status.PadRight(4))]  ")
        $rtb.SelectionFont  = $F_N
        $rtb.SelectionColor = [System.Drawing.Color]::FromArgb(40,40,40)
        $rtb.AppendText("$($r.Category.PadRight(12)) $($r.Item.PadRight(20)) $($r.Value)")
        if ($r.Note) { $rtb.AppendText("  -- $($r.Note)") }
        $rtb.AppendText("`n")
    }
}
#endregion

Export-ModuleMember -Function Update-EnvReport
