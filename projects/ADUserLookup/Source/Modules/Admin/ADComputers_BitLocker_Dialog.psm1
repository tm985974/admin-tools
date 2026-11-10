#region -- ADComputers.BitLocker.Dialog.psm1 ----------------------------------
# Concern : Show-BitLockerDialog - fixed-size popup invoked from the Computers
#           grid right-click menu ("BitLocker Recovery Key..."). Hosts its own
#           DataGridView and Copy button, calls Invoke-BitLockerLookup with
#           -Grid pointed at the dialog's own grid (replaces the removed
#           BitLocker sub-tab/grid).
# Load order: 84 - depends on ADComputers.BitLocker.Lookup (Invoke-BitLockerLookup),
#                            Services.AD.Reporting (New-StdGrid, New-StdButton, Set-GridData)
# Split from: n/a (new module; replaces ADComputers.BitLocker.Tab.psm1 /
#             ADComputers.BitLocker.Grid.psm1, both removed)
#endregion

#region -- Show-BitLockerDialog ------------------------------------------------
function Show-BitLockerDialog {
    <#
    .SYNOPSIS
        Shows a fixed-size dialog with BitLocker recovery key(s) for a single
        computer. Looks the keys up immediately on open.
    .PARAMETER ComputerName
        The target computer name.
    #>
    param([string]$ComputerName)

    $F_UI   = New-Object System.Drawing.Font('Segoe UI', 9)
    $F_UI_B = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)

    $dlg                = New-Object System.Windows.Forms.Form
    $dlg.Text           = "BitLocker Recovery Key - $ComputerName"
    $dlg.Size            = New-Object System.Drawing.Size(620, 320)
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox     = $false
    $dlg.MinimizeBox     = $false
    $dlg.StartPosition   = 'CenterParent'
    $dlg.Font            = $F_UI

    $lTitle           = New-Object System.Windows.Forms.Label
    $lTitle.Text      = "BitLocker Recovery Key(s) for $ComputerName"
    $lTitle.Location  = New-Object System.Drawing.Point(12, 12)
    $lTitle.Size      = New-Object System.Drawing.Size(580, 22)
    $lTitle.Font      = $F_UI_B
    $lTitle.ForeColor = [System.Drawing.Color]::FromArgb(0, 70, 140)
    $dlg.Controls.Add($lTitle)

    $grid = New-StdGrid -X 12 -Y 42 -W 580 -H 190 -Parent $dlg
    $grid.MultiSelect   = $false
    $grid.SelectionMode = 'FullRowSelect'

    $lblHint           = New-Object System.Windows.Forms.Label
    $lblHint.Text      = 'Select a row, then click Copy Key to copy the recovery password to the clipboard.'
    $lblHint.Location  = New-Object System.Drawing.Point(12, 238)
    $lblHint.Size      = New-Object System.Drawing.Size(580, 20)
    $lblHint.Font      = $F_UI
    $lblHint.ForeColor = [System.Drawing.Color]::DimGray
    $dlg.Controls.Add($lblHint)

    $btnCopy = New-StdButton -Text 'Copy Key'  -X 12  -Y 262 -W 100 -H 28 -Parent $dlg
    $btnClose = New-StdButton -Text 'Close'    -X 492 -Y 262 -W 100 -H 28 -Parent $dlg

    $btnCopy.Add_Click({
        if ($grid.SelectedRows.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show('Select a recovery key row first.','Copy Key','OK','Information')
            return
        }
        $val = $grid.SelectedRows[0].Cells['RecoveryKey'].Value
        if ($val) {
            [System.Windows.Forms.Clipboard]::SetText([string]$val)
            if (Get-Command Set-Status -ErrorAction SilentlyContinue) { Set-Status 'Recovery key copied to clipboard.' 'ok' }
        }
    }.GetNewClosure())

    $btnClose.Add_Click({ $dlg.Close() }.GetNewClosure())

    $grid.Add_CellDoubleClick({
        param($s, $e)
        if ($e.RowIndex -lt 0) { return }
        $val = $grid.Rows[$e.RowIndex].Cells['RecoveryKey'].Value
        if ($val) {
            [System.Windows.Forms.Clipboard]::SetText([string]$val)
            if (Get-Command Set-Status -ErrorAction SilentlyContinue) { Set-Status 'Recovery key copied to clipboard.' 'ok' }
        }
    }.GetNewClosure())

    Invoke-BitLockerLookup -ComputerName $ComputerName -Grid $grid

    [void]$dlg.ShowDialog()
}
#endregion

Export-ModuleMember -Function Show-BitLockerDialog
