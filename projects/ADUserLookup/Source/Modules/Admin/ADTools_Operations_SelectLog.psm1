#region -- ADTools.Operations.SelectLog.psm1 ----------------------------------
# Concern : Select-OpLog - filters LogAllEntries by the search box text and
#           pushes the result into LogGrid with FAIL/OFFBOARD row highlighting.
# Load order: 121 - depends on ADTools.PasswordGenerator.Engine (script scope),
#                            Services.AD.Reporting (Set-GridData)
# Split from: ADTools.Actions.psm1
#endregion

#region -- Select-OpLog -------------------------------------------------------
function Select-OpLog {
    if ($null -eq $script:LogAllEntries) { return }
    $q = if ($script:LogTbFilter) { $script:LogTbFilter.Text.Trim().ToLower() } else { '' }
    $filtered = if ($q) {
        @($script:LogAllEntries | Where-Object {
            $_.Action.ToLower()  -like "*$q*" -or
            $_.Target.ToLower()  -like "*$q*" -or
            $_.Admin.ToLower()   -like "*$q*" -or
            $_.Result.ToLower()  -like "*$q*" -or
            $_.Detail.ToLower()  -like "*$q*"
        })
    } else { @($script:LogAllEntries) }
    $cols = @('Timestamp','Action','Admin','Domain','Target','Result','Detail')
    Set-GridData -Grid $script:LogGrid -Data $filtered -Columns $cols
    foreach ($row in $script:LogGrid.Rows) {
        if ($row.Cells['Result'].Value -eq 'FAIL') {
            $row.DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(255,199,206)
        } elseif ($row.Cells['Action'].Value -like '*OFFBOARD*') {
            $row.DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(255,235,156)
        }
    }
}
#endregion

Export-ModuleMember -Function Select-OpLog
