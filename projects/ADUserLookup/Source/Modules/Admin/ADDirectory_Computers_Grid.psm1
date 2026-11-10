#region -- ADDirectory.Computers.Grid.psm1 ------------------------------------
# Concern : Update-CompGrid - pushes filtered computer data into the Computers
#           grid with disabled-row dimming and stale-logon row highlight.
# Load order: 20 - depends on ADDirectory.Computers.Filter (Get-FilteredComputers),
#                            ADDirectory.Computers.Load (script scope),
#                            Services.AD.Reporting (Set-GridData)
# Split from: ADDirectory.Tab.psm1
#endregion

#region -- Update-CompGrid ----------------------------------------------------
function Update-CompGrid {
    if (-not $script:CompGrid) { return }
    $data   = Get-FilteredComputers
    $cols   = @('Name','Enabled','OperatingSystem','OSVersion','LastLogon','IPv4Address','Created','Description','OU')
    Set-GridData -Grid $script:CompGrid -Data $data -Columns $cols
    $cutoff = (Get-Date).AddDays(-90)
    foreach ($row in $script:CompGrid.Rows) {
        if ($row.Cells['Enabled'].Value -eq 'False') {
            $row.DefaultCellStyle.ForeColor = [System.Drawing.Color]::FromArgb(160,160,160)
        }
        $ll = $row.Cells['LastLogon'].Value
        if ($ll -and $ll -ne 'Never') {
            try {
                if ([datetime]$ll -lt $cutoff) {
                    $row.DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(255,235,156)
                }
            } catch { }
        }
    }
    if ($script:LblCompCount) { $script:LblCompCount.Text = "$($data.Count) of $($script:AllComputers.Count)" }
}
#endregion

Export-ModuleMember -Function Update-CompGrid
