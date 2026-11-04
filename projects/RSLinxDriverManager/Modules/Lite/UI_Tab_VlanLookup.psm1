# UI_Tab_VlanLookup.psm1   (LITE TIER)
#
# The VLAN Lookup tab: the table that names the drivers. One row per site +
# subnet (first three octets); driver name = SITE(VLAN)DESCRIPTION.
# Saved to <data root>\Settings\VlanLookup.json (Services_VlanLookup.psm1) -
# Build preview on the Drivers tab reads the SAVED table.
#
# Editing: developer build and admin password. User password: read-only.

$script:V = $null

function New-VlanLookupTab {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Windows.Forms.TabPage]$Page,
        [Parameter(Mandatory)] $App
    )
    Set-LazyTabBuild -Page $Page -App $App -Build { param($Page, $App) Initialize-VlanTab -Page $Page -App $App }
}

function Initialize-VlanTab {
    param($Page, $App)
    $T = $App.Theme
    $canEdit = [bool]$App.CanEditDefaults
    $script:V = @{ App = $App; Page = $Page; Entries = New-Object System.Collections.ArrayList; NextId = 0; Dirty = $false; CanEdit = $canEdit; Filling = $false }
    $Page.AutoScroll = $false
    $Page.Padding = New-Object System.Windows.Forms.Padding(8, 6, 8, 6)

    $sub = New-Object System.Windows.Forms.Label
    $sub.Dock = 'Top'; $sub.Height = 40; $sub.ForeColor = $T.Muted
    $sub.Text = ("Driver name = SITE(VLAN)DESCRIPTION, at most {0} characters. An IP matches the row of its site whose IP base is its first three octets; " +
                 "failing that, a row with CIDR below 24 whose block contains it; failing that it is named SITE(3rd octet)SCADA.`r`nSaved to: {1}{2}") -f `
                 (Get-RSLinxDriverNameLimit), (Get-VlanLookupPath -App $App), $(if ($canEdit) { '' } else { '   (read-only with the user password)' })

    $fb = New-RSLinxFilterBar -App $App
    $script:V.Count = $fb.Count

    $grid = New-RSLinxGrid -App $App -MultiSelect
    $grid.ReadOnly = -not $canEdit
    [void](Add-RSLinxGridColumn -Grid $grid -Name 'Site' -Width 50)
    [void](Add-RSLinxGridColumn -Grid $grid -Name 'IpBase' -Header 'IP base (3 octets)' -Width 130)
    [void](Add-RSLinxGridColumn -Grid $grid -Name 'Cidr' -Header 'CIDR' -Width 50)
    [void](Add-RSLinxGridColumn -Grid $grid -Name 'Vlan' -Header 'VLAN' -Width 60)
    [void](Add-RSLinxGridColumn -Grid $grid -Name 'Description' -Width 140)
    [void](Add-RSLinxGridColumn -Grid $grid -Name 'DriverName' -Header 'Driver name' -Width 150 -ReadOnly)
    [void](Add-RSLinxGridColumn -Grid $grid -Name 'Length' -Header 'Len' -Width 40 -ReadOnly)
    [void](Add-RSLinxGridColumn -Grid $grid -Name 'Issue' -Fill 100 -ReadOnly)
    $grid.Columns['DriverName'].DefaultCellStyle.Font = New-Object System.Drawing.Font($T.FontName, $T.FontSizePt, [System.Drawing.FontStyle]::Bold)
    $script:V.Grid = $grid
    $grid.Add_CellValueChanged({ param($s, $e) Invoke-VlanCellChanged -RowIndex $e.RowIndex -ColumnIndex $e.ColumnIndex })

    $bAdd = $T.MakeButton('Add row')
    $bDel = $T.MakeButton('Delete selected')
    $bSave = $T.MakeButton('Save')
    $bReload = $T.MakeButton('Reload')
    $bImport = $T.MakeButton('Import CSV...')
    $bExport = $T.MakeButton('Export CSV...')
    $bReset = $T.MakeButton('Reset to shipped defaults')
    $state = New-Object System.Windows.Forms.Label
    $state.AutoSize = $true; $state.Margin = New-Object System.Windows.Forms.Padding(12, 7, 0, 0)
    $state.Font = New-Object System.Drawing.Font($T.FontName, $T.FontSizePt, [System.Drawing.FontStyle]::Bold)
    $script:V.State = $state
    $bar = New-RSLinxButtonBar -App $App -Buttons @($bAdd, $bDel, $bSave, $bReload, $bImport, $bExport, $bReset) -Dock 'Bottom' -Height 40
    $bar.Controls.Add($state)
    foreach ($b in @($bAdd, $bDel, $bSave, $bImport, $bReset)) { $b.Enabled = $canEdit }

    $bAdd.Add_Click({ Add-VlanRow })
    $bDel.Add_Click({ Remove-VlanSelectedRows })
    $bSave.Add_Click({ Save-VlanTable })
    $bReload.Add_Click({
        if ($script:V.Dirty -and (Show-VlanQuestion 'Discard the unsaved changes and reload the saved table?') -ne 'Yes') { return }
        Import-VlanEntries -Entries @(Get-VlanLookupTable -App $script:V.App) -Dirty $false
    })
    $bImport.Add_Click({ Import-VlanCsv })
    $bExport.Add_Click({ Export-VlanCsv })
    $bReset.Add_Click({
        if ((Show-VlanQuestion 'Replace the table with the shipped default (from RSLinx.xlsx)? Nothing is saved until you click Save.') -ne 'Yes') { return }
        Import-VlanEntries -Entries @(Get-VlanLookupTable -App $script:V.App -Defaults) -Dirty $true
    })

    $Page.Controls.Add($grid)
    $Page.Controls.Add($bar)
    $Page.Controls.Add($fb.Panel)
    $Page.Controls.Add($sub)
    $Page.Controls.Add((New-RSLinxHeader -App $App -Text 'VLAN lookup - how drivers are named'))

    $script:V.Filter = Register-ListFilter -App $App -TextBox $fb.Box -OnFilter { param($Regex, $Text) Update-VlanGrid -Regex $Regex }
    Import-VlanEntries -Entries @(Get-VlanLookupTable -App $App) -Dirty $false

    # another environment can have another data root (and so another saved table)
    Register-EnvironmentChangedHandler -Handler {
        param($App)
        if (-not $script:V) { return }
        if ($script:V.Dirty) { $App.SetStatus('Environment changed: the VLAN Lookup tab still shows your unsaved edits.', 'warn'); return }
        Import-VlanEntries -Entries @(Get-VlanLookupTable -App $App) -Dirty $false
    }
}

function Show-VlanQuestion {
    param([string]$Text, [string]$Icon = 'Question')
    return [string][System.Windows.Forms.MessageBox]::Show($script:V.Page.FindForm(), $Text, 'RSLinx Driver Manager',
        [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]$Icon)
}

function New-VlanItem {
    param($Entry)
    $script:V.NextId++
    return [pscustomobject]@{
        Id = $script:V.NextId; Site = [string]$Entry.Site; IpBase = [string]$Entry.IpBase; Cidr = [string]$Entry.Cidr
        Vlan = [string]$Entry.Vlan; Description = [string]$Entry.Description; DriverName = ''; Length = 0; Issue = ''
    }
}

function Import-VlanEntries {
    param([object[]]$Entries = @(), [bool]$Dirty = $false)
    $script:V.Entries.Clear()
    foreach ($e in $Entries) { [void]$script:V.Entries.Add((New-VlanItem -Entry $e)) }
    Update-VlanDerived
    Set-VlanDirty $Dirty
    & $script:V.Filter.Apply
}

# Driver name, length and issues for every row (duplicates need the whole table).
function Update-VlanDerived {
    $list = @($script:V.Entries)
    $issues = @(Test-VlanLookupTable -Entries $list)
    for ($i = 0; $i -lt $list.Count; $i++) {
        $it = $list[$i]
        $it.DriverName = Get-VlanDriverName -Entry $it
        $it.Length = $it.DriverName.Length
        $it.Issue = $(if ($i -lt $issues.Count) { [string]$issues[$i] } else { '' })
    }
}

function Set-VlanDirty {
    param([bool]$Dirty)
    $script:V.Dirty = $Dirty
    $n = @($script:V.Entries | Where-Object { $_.Issue }).Count
    $txt = '{0} row(s)' -f $script:V.Entries.Count
    if ($n) { $txt += ", $n with issues" }
    if ($Dirty) { $txt += '   - UNSAVED (Save to use these in Build preview)'; $script:V.State.ForeColor = [System.Drawing.Color]::Firebrick }
    else { $script:V.State.ForeColor = $script:V.App.Theme.Muted }
    $script:V.State.Text = $txt
}

function Update-VlanGrid {
    param($Regex)
    $g = $script:V.Grid
    $rows = @(Select-FilterMatch -Items @($script:V.Entries) -Regex $Regex -Property 'Site', 'IpBase', 'Vlan', 'Description', 'DriverName', 'Issue')
    $script:V.Filling = $true
    $g.SuspendLayout()
    try {
        $g.Rows.Clear()
        foreach ($r in $rows) {
            $i = $g.Rows.Add($r.Site, $r.IpBase, $r.Cidr, $r.Vlan, $r.Description, $r.DriverName, $r.Length, $r.Issue)
            $g.Rows[$i].Tag = $r
            Set-VlanRowStyle -GridRow $g.Rows[$i]
        }
    } finally { $g.ResumeLayout(); $script:V.Filling = $false }
    $script:V.Count.Text = '{0} shown of {1}' -f $rows.Count, $script:V.Entries.Count
}

function Set-VlanRowStyle {
    param($GridRow)
    $r = $GridRow.Tag
    if ($r.Issue) { $GridRow.DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(253, 226, 226); $GridRow.Cells['Issue'].Style.ForeColor = [System.Drawing.Color]::Firebrick }
    else { $GridRow.DefaultCellStyle.BackColor = [System.Drawing.Color]::Empty; $GridRow.Cells['Issue'].Style.ForeColor = [System.Drawing.Color]::Empty }
}

function Invoke-VlanCellChanged {
    param([int]$RowIndex, [int]$ColumnIndex)
    if ($script:V.Filling -or $RowIndex -lt 0) { return }
    $g = $script:V.Grid
    $gr = $g.Rows[$RowIndex]; $r = $gr.Tag; if (-not $r) { return }
    $name = $g.Columns[$ColumnIndex].Name
    if ($name -notin @('Site', 'IpBase', 'Cidr', 'Vlan', 'Description')) { return }
    $v = ([string]$gr.Cells[$ColumnIndex].Value).Trim()
    if ($name -eq 'Site' -or $name -eq 'Description') { $v = $v.ToUpperInvariant() }
    if ($name -eq 'IpBase') { $v = $v.TrimEnd('.') }
    $r.$name = $v
    Update-VlanDerived
    # refresh every visible row's derived cells (a duplicate elsewhere may have changed)
    $script:V.Filling = $true
    try {
        foreach ($row in $g.Rows) {
            $t = $row.Tag
            if ($row.Index -eq $RowIndex) { $row.Cells[$name].Value = $t.$name }
            $row.Cells['DriverName'].Value = $t.DriverName; $row.Cells['Length'].Value = $t.Length; $row.Cells['Issue'].Value = $t.Issue
            Set-VlanRowStyle -GridRow $row
        }
    } finally { $script:V.Filling = $false }
    Set-VlanDirty $true
}

function Add-VlanRow {
    $site = ''
    $sel = @($script:V.Grid.SelectedRows)
    if ($sel.Count -gt 0 -and $sel[0].Tag) { $site = $sel[0].Tag.Site }
    $it = New-VlanItem -Entry ([pscustomobject]@{ Site = $site; IpBase = ''; Cidr = 24; Vlan = ''; Description = 'SCADA' })
    [void]$script:V.Entries.Add($it)
    Update-VlanDerived
    Set-VlanDirty $true
    & $script:V.Filter.Apply
    $g = $script:V.Grid
    foreach ($row in $g.Rows) {
        if ($row.Tag -and $row.Tag.Id -eq $it.Id) {
            $g.ClearSelection(); $row.Selected = $true
            $g.CurrentCell = $row.Cells['IpBase']; $g.FirstDisplayedScrollingRowIndex = $row.Index
            [void]$g.BeginEdit($true)
            break
        }
    }
}

function Remove-VlanSelectedRows {
    $ids = @{}
    foreach ($gr in @($script:V.Grid.SelectedRows)) { if ($gr.Tag) { $ids[[int]$gr.Tag.Id] = $true } }
    if ($ids.Count -eq 0) { $script:V.App.SetStatus('Select rows first.', 'warn'); return }
    if ((Show-VlanQuestion "Delete $($ids.Count) row(s)? (Nothing is saved until you click Save.)") -ne 'Yes') { return }
    $keep = @($script:V.Entries | Where-Object { -not $ids.ContainsKey([int]$_.Id) })
    $script:V.Entries.Clear(); foreach ($k in $keep) { [void]$script:V.Entries.Add($k) }
    Update-VlanDerived
    Set-VlanDirty $true
    & $script:V.Filter.Apply
}

function Save-VlanTable {
    $App = $script:V.App
    [void]$script:V.Grid.EndEdit()
    $bad = @($script:V.Entries | Where-Object { $_.Issue -and $_.Issue -notlike 'Duplicate*' })
    if ($bad.Count -gt 0 -and (Show-VlanQuestion "$($bad.Count) row(s) have problems (red). Save anyway?" 'Warning') -ne 'Yes') { return }
    try {
        $p = Save-VlanLookupTable -App $App -Entries @($script:V.Entries)
        Set-VlanDirty $false
        $App.Log('INFO', 'VlanLookup', "Saved $($script:V.Entries.Count) row(s) to $p")
        $App.LogAction("VLAN lookup table saved ($($script:V.Entries.Count) rows).")
        $App.SetStatus("VLAN lookup saved ($($script:V.Entries.Count) rows).", 'ok')
    }
    catch {
        $App.Log('ERROR', 'VlanLookup', "Save failed: $($_.Exception.Message)")
        [void][System.Windows.Forms.MessageBox]::Show($script:V.Page.FindForm(), "Save failed:`r`n$($_.Exception.Message)", 'RSLinx Driver Manager', 'OK', 'Error')
    }
}

function Import-VlanCsv {
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = 'CSV files (*.csv;*.txt)|*.csv;*.txt|All files (*.*)|*.*'
    $dlg.Title = 'Import VLAN lookup (Site,IpBase,Cidr,Vlan,Description - or the RSLinx.xlsx VlanLookup columns)'
    if ($dlg.ShowDialog($script:V.Page.FindForm()) -ne 'OK') { return }
    try {
        $rows = @(ConvertFrom-VlanLookupCsv -Text ([System.IO.File]::ReadAllText($dlg.FileName)))
        if ($rows.Count -eq 0) { $script:V.App.SetStatus('No rows found in that file.', 'warn'); return }
        $ans = [System.Windows.Forms.MessageBox]::Show($script:V.Page.FindForm(),
            "$($rows.Count) row(s) read.`r`n`r`nYes = replace the table`r`nNo = add them to the table", 'RSLinx Driver Manager', 'YesNoCancel', 'Question')
        if ($ans -eq 'Cancel') { return }
        if ($ans -eq 'No') { $rows = @($script:V.Entries) + $rows }
        Import-VlanEntries -Entries $rows -Dirty $true
    }
    catch { [void][System.Windows.Forms.MessageBox]::Show($script:V.Page.FindForm(), "Import failed:`r`n$($_.Exception.Message)", 'RSLinx Driver Manager', 'OK', 'Error') }
}

function Export-VlanCsv {
    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Filter = 'CSV files (*.csv)|*.csv'; $dlg.FileName = 'VlanLookup.csv'
    if ($dlg.ShowDialog($script:V.Page.FindForm()) -ne 'OK') { return }
    try {
        @($script:V.Entries | Select-Object Site, IpBase, Cidr, Vlan, Description, DriverName) |
            Export-Csv -LiteralPath $dlg.FileName -NoTypeInformation -Encoding UTF8
        $script:V.App.SetStatus("Exported to $($dlg.FileName)", 'ok')
    }
    catch { [void][System.Windows.Forms.MessageBox]::Show($script:V.Page.FindForm(), "Export failed:`r`n$($_.Exception.Message)", 'RSLinx Driver Manager', 'OK', 'Error') }
}
