#region -- ADComputers.LAPS.Dialog.psm1 ---------------------------------------
# Concern : Show-LAPSDialog - fixed-size popup invoked from the Computers grid
#           right-click menu ("LAPS Password..."). Hosts its own DataGridView
#           and Copy button, calls Invoke-LAPSLookup with -Grid pointed at the
#           dialog's own grid (replaces the removed LAPS sub-tab/grid).
# Load order: 86 - depends on ADComputers.LAPS.Lookup (Invoke-LAPSLookup),
#                            Services.AD.Reporting (New-StdGrid, New-StdButton, Set-GridData)
# Split from: n/a (new module; replaces ADComputers.LAPS.Tab.psm1 /
#             ADComputers.LAPS.Grid.psm1, both removed)
#endregion

#region -- Show-LAPSDialog ------------------------------------------------------
function Show-LAPSDialog {
    <#
    .SYNOPSIS
        Shows a fixed-size dialog with the LAPS local admin password for a
        single computer. Looks the password up immediately on open.
    .PARAMETER ComputerName
        The target computer name.
    #>
    param([string]$ComputerName)

    $F_UI   = New-Object System.Drawing.Font('Segoe UI', 9)
    $F_UI_B = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)

    $dlg                 = New-Object System.Windows.Forms.Form
    $dlg.Text            = "LAPS Password - $ComputerName"
    $dlg.Size            = New-Object System.Drawing.Size(620, 320)
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox     = $false
    $dlg.MinimizeBox     = $false
    $dlg.StartPosition   = 'CenterParent'
    $dlg.Font            = $F_UI

    $lTitle           = New-Object System.Windows.Forms.Label
    $lTitle.Text      = "LAPS Local Administrator Password for $ComputerName"
    $lTitle.Location  = New-Object System.Drawing.Point(12, 12)
    $lTitle.Size      = New-Object System.Drawing.Size(580, 22)
    $lTitle.Font      = $F_UI_B
    $lTitle.ForeColor = [System.Drawing.Color]::FromArgb(0, 70, 140)
    $dlg.Controls.Add($lTitle)

    $grid = New-StdGrid -X 12 -Y 42 -W 580 -H 150 -Parent $dlg
    $grid.MultiSelect   = $false
    $grid.SelectionMode = 'FullRowSelect'

    $lNotes           = New-Object System.Windows.Forms.Label
    $lNotes.Text      = "Legacy LAPS attribute: ms-Mcs-AdmPwd`r`n" +
                        "Windows LAPS (2023+) attribute: msLAPS-Password`r`n" +
                        "Requires read rights on the computer object. Select a row and click Copy Password, or double-click the row."
    $lNotes.Location  = New-Object System.Drawing.Point(12, 198)
    $lNotes.Size      = New-Object System.Drawing.Size(580, 56)
    $lNotes.Font      = $F_UI
    $lNotes.ForeColor = [System.Drawing.Color]::DimGray
    $dlg.Controls.Add($lNotes)

    $btnCopy  = New-StdButton -Text 'Copy Password' -X 12  -Y 262 -W 120 -H 28 -Parent $dlg
    $btnClose = New-StdButton -Text 'Close'          -X 492 -Y 262 -W 100 -H 28 -Parent $dlg

    $btnCopy.Add_Click({
        if ($grid.SelectedRows.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show('Select a password row first.','Copy Password','OK','Information')
            return
        }
        $val = $grid.SelectedRows[0].Cells['Password'].Value
        if ($val) {
            [System.Windows.Forms.Clipboard]::SetText([string]$val)
            if (Get-Command Set-Status -ErrorAction SilentlyContinue) { Set-Status 'LAPS password copied to clipboard.' 'ok' }
        }
    }.GetNewClosure())

    $btnClose.Add_Click({ $dlg.Close() }.GetNewClosure())

    $grid.Add_CellDoubleClick({
        param($s, $e)
        if ($e.RowIndex -lt 0) { return }
        $val = $grid.Rows[$e.RowIndex].Cells['Password'].Value
        if ($val) {
            [System.Windows.Forms.Clipboard]::SetText([string]$val)
            if (Get-Command Set-Status -ErrorAction SilentlyContinue) { Set-Status 'LAPS password copied to clipboard.' 'ok' }
        }
    }.GetNewClosure())

    Invoke-LAPSLookup -ComputerName $ComputerName -Grid $grid

    [void]$dlg.ShowDialog()
}
#endregion

Export-ModuleMember -Function Show-LAPSDialog
