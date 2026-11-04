# UI_Tab_SiteCodes.psm1   (LITE TIER)
#
# The Site Codes tab: device registry Lease name -> 2-letter site code
# (Belridge -> BL). Saved to <data root>\Settings\SiteCodes.json
# (Services_SiteCodes.psm1) - Build preview on the Drivers tab reads the SAVED table.
#
# Editing: developer build and admin password. User password: read-only.

$script:S = $null

function New-SiteCodesTab {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Windows.Forms.TabPage]$Page,
        [Parameter(Mandatory)] $App
    )
    Set-LazyTabBuild -Page $Page -App $App -Build { param($Page, $App) Initialize-SiteCodesTab -Page $Page -App $App }
}

function Initialize-SiteCodesTab {
    param($Page, $App)
    $T = $App.Theme
    $canEdit = [bool]$App.CanEditDefaults
    $script:S = @{ App = $App; Page = $Page; Entries = New-Object System.Collections.ArrayList; NextId = 0; Dirty = $false; Filling = $false }
    $Page.AutoScroll = $false
    $Page.Padding = New-Object System.Windows.Forms.Padding(8, 6, 8, 6)

    $sub = New-Object System.Windows.Forms.Label
    $sub.Dock = 'Top'; $sub.Height = 40; $sub.ForeColor = $T.Muted
    $sub.Text = ("The device registry's Lease column holds the site name; driver names use its 2-letter code (Belridge -> BL(25)SCADA). " +
                 "Names are matched ignoring case and extra spaces. A Lease that is already a code (BL), or starts with one (BL - Belridge), needs no row.`r`nSaved to: {0}{1}") -f `
                 (Get-SiteCodePath -App $App), $(if ($canEdit) { '' } else { '   (read-only with the user password)' })

    # the grid sits in a fixed-width panel: two short columns do not need the whole window
    $holder = New-Object System.Windows.Forms.Panel
    $holder.Dock = 'Left'; $holder.Width = 720

    $grid = New-RSLinxGrid -App $App -MultiSelect
    $grid.ReadOnly = -not $canEdit
    [void](Add-RSLinxGridColumn -Grid $grid -Name 'Lease' -Header 'Lease name (as in the device registry)' -Width 260)
    [void](Add-RSLinxGridColumn -Grid $grid -Name 'Code' -Header 'Site code' -Width 80)
    [void](Add-RSLinxGridColumn -Grid $grid -Name 'Issue' -Fill 100 -ReadOnly)
    $grid.Columns['Code'].DefaultCellStyle.Font = New-Object System.Drawing.Font($T.FontName, $T.FontSizePt, [System.Drawing.FontStyle]::Bold)
    $script:S.Grid = $grid
    $grid.Add_CellValueChanged({ param($s, $e) Invoke-SiteCellChanged -RowIndex $e.RowIndex -ColumnIndex $e.ColumnIndex })

    $bAdd = $T.MakeButton('Add row')
    $bDel = $T.MakeButton('Delete selected')
    $bSave = $T.MakeButton('Save')
    $bReload = $T.MakeButton('Reload')
    $bReset = $T.MakeButton('Reset to shipped defaults')
    $state = New-Object System.Windows.Forms.Label
    $state.AutoSize = $true; $state.Margin = New-Object System.Windows.Forms.Padding(12, 7, 0, 0)
    $state.Font = New-Object System.Drawing.Font($T.FontName, $T.FontSizePt, [System.Drawing.FontStyle]::Bold)
    $script:S.State = $state
    $bar = New-RSLinxButtonBar -App $App -Buttons @($bAdd, $bDel, $bSave, $bReload, $bReset) -Dock 'Bottom' -Height 40
    $bar.Controls.Add($state)
    foreach ($b in @($bAdd, $bDel, $bSave, $bReset)) { $b.Enabled = $canEdit }

    $bAdd.Add_Click({ Add-SiteRow })
    $bDel.Add_Click({ Remove-SiteSelectedRows })
    $bSave.Add_Click({ Save-SiteTable })
    $bReload.Add_Click({
        if ($script:S.Dirty -and (Show-SiteQuestion 'Discard the unsaved changes and reload the saved table?') -ne 'Yes') { return }
        Import-SiteEntries -Entries @(Get-SiteCodeTable -App $script:S.App) -Dirty $false
    })
    $bReset.Add_Click({
        if ((Show-SiteQuestion 'Replace the table with the shipped default? Nothing is saved until you click Save.') -ne 'Yes') { return }
        Import-SiteEntries -Entries @(Get-SiteCodeTable -App $script:S.App -Defaults) -Dirty $true
    })

    $holder.Controls.Add($grid)
    $holder.Controls.Add($bar)
    $Page.Controls.Add($holder)
    $Page.Controls.Add($sub)
    $Page.Controls.Add((New-RSLinxHeader -App $App -Text 'Site codes - Lease name to 2-letter code'))

    Import-SiteEntries -Entries @(Get-SiteCodeTable -App $App) -Dirty $false

    Register-EnvironmentChangedHandler -Handler {
        param($App)
        if (-not $script:S -or $script:S.Dirty) { return }
        Import-SiteEntries -Entries @(Get-SiteCodeTable -App $App) -Dirty $false
    }
}

function Show-SiteQuestion {
    param([string]$Text, [string]$Icon = 'Question')
    return [string][System.Windows.Forms.MessageBox]::Show($script:S.Page.FindForm(), $Text, 'RSLinx Driver Manager',
        [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]$Icon)
}

function Import-SiteEntries {
    param([object[]]$Entries = @(), [bool]$Dirty = $false)
    $script:S.Entries.Clear()
    foreach ($e in $Entries) {
        $script:S.NextId++
        [void]$script:S.Entries.Add([pscustomobject]@{ Id = $script:S.NextId; Lease = [string]$e.Lease; Code = [string]$e.Code; Issue = '' })
    }
    Update-SiteIssues
    Update-SiteGrid
    Set-SiteDirty $Dirty
}

function Update-SiteIssues {
    $list = @($script:S.Entries)
    $issues = @(Test-SiteCodeTable -Entries $list)
    for ($i = 0; $i -lt $list.Count; $i++) { $list[$i].Issue = $(if ($i -lt $issues.Count) { [string]$issues[$i] } else { '' }) }
}

function Set-SiteDirty {
    param([bool]$Dirty)
    $script:S.Dirty = $Dirty
    $n = @($script:S.Entries | Where-Object { $_.Issue }).Count
    $txt = '{0} row(s)' -f $script:S.Entries.Count
    if ($n) { $txt += ", $n with issues" }
    if ($Dirty) { $txt += '   - UNSAVED'; $script:S.State.ForeColor = [System.Drawing.Color]::Firebrick }
    else { $script:S.State.ForeColor = $script:S.App.Theme.Muted }
    $script:S.State.Text = $txt
}

function Update-SiteGrid {
    $g = $script:S.Grid
    $script:S.Filling = $true
    $g.SuspendLayout()
    try {
        $g.Rows.Clear()
        foreach ($r in @($script:S.Entries | Sort-Object { $_.Lease })) {
            $i = $g.Rows.Add($r.Lease, $r.Code, $r.Issue)
            $g.Rows[$i].Tag = $r
            Set-SiteRowStyle -GridRow $g.Rows[$i]
        }
    } finally { $g.ResumeLayout(); $script:S.Filling = $false }
}

function Set-SiteRowStyle {
    param($GridRow)
    if ($GridRow.Tag.Issue) { $GridRow.DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(253, 226, 226); $GridRow.Cells['Issue'].Style.ForeColor = [System.Drawing.Color]::Firebrick }
    else { $GridRow.DefaultCellStyle.BackColor = [System.Drawing.Color]::Empty; $GridRow.Cells['Issue'].Style.ForeColor = [System.Drawing.Color]::Empty }
}

function Invoke-SiteCellChanged {
    param([int]$RowIndex, [int]$ColumnIndex)
    if ($script:S.Filling -or $RowIndex -lt 0) { return }
    $g = $script:S.Grid
    $gr = $g.Rows[$RowIndex]; $r = $gr.Tag; if (-not $r) { return }
    $name = $g.Columns[$ColumnIndex].Name
    if ($name -ne 'Lease' -and $name -ne 'Code') { return }
    $v = ([string]$gr.Cells[$ColumnIndex].Value).Trim()
    if ($name -eq 'Code') { $v = $v.ToUpperInvariant() } else { $v = [regex]::Replace($v, '\s+', ' ') }
    $r.$name = $v
    Update-SiteIssues
    $script:S.Filling = $true
    try {
        $gr.Cells[$ColumnIndex].Value = $v
        foreach ($row in $g.Rows) { $row.Cells['Issue'].Value = $row.Tag.Issue; Set-SiteRowStyle -GridRow $row }
    } finally { $script:S.Filling = $false }
    Set-SiteDirty $true
}

function Add-SiteRow {
    $script:S.NextId++
    $it = [pscustomobject]@{ Id = $script:S.NextId; Lease = ''; Code = ''; Issue = '' }
    [void]$script:S.Entries.Add($it)
    Update-SiteIssues
    $g = $script:S.Grid
    $script:S.Filling = $true
    try { $i = $g.Rows.Add($it.Lease, $it.Code, $it.Issue); $g.Rows[$i].Tag = $it; Set-SiteRowStyle -GridRow $g.Rows[$i] }
    finally { $script:S.Filling = $false }
    Set-SiteDirty $true
    $g.ClearSelection(); $g.Rows[$i].Selected = $true
    $g.CurrentCell = $g.Rows[$i].Cells['Lease']; $g.FirstDisplayedScrollingRowIndex = $i
    [void]$g.BeginEdit($true)
}

function Remove-SiteSelectedRows {
    $ids = @{}
    foreach ($gr in @($script:S.Grid.SelectedRows)) { if ($gr.Tag) { $ids[[int]$gr.Tag.Id] = $true } }
    if ($ids.Count -eq 0) { $script:S.App.SetStatus('Select rows first.', 'warn'); return }
    if ((Show-SiteQuestion "Delete $($ids.Count) row(s)? (Nothing is saved until you click Save.)") -ne 'Yes') { return }
    $keep = @($script:S.Entries | Where-Object { -not $ids.ContainsKey([int]$_.Id) })
    $script:S.Entries.Clear(); foreach ($k in $keep) { [void]$script:S.Entries.Add($k) }
    Update-SiteIssues
    Update-SiteGrid
    Set-SiteDirty $true
}

function Save-SiteTable {
    $App = $script:S.App
    [void]$script:S.Grid.EndEdit()
    $bad = @($script:S.Entries | Where-Object { $_.Issue -and $_.Issue -notlike 'Duplicate*' })
    if ($bad.Count -gt 0 -and (Show-SiteQuestion "$($bad.Count) row(s) have problems (red) and will be ignored. Save anyway?" 'Warning') -ne 'Yes') { return }
    try {
        $p = Save-SiteCodeTable -App $App -Entries @($script:S.Entries)
        Set-SiteDirty $false
        $App.Log('INFO', 'SiteCodes', "Saved $($script:S.Entries.Count) row(s) to $p")
        $App.LogAction("Site codes saved ($($script:S.Entries.Count) rows).")
        $App.SetStatus("Site codes saved ($($script:S.Entries.Count) rows).", 'ok')
    }
    catch {
        $App.Log('ERROR', 'SiteCodes', "Save failed: $($_.Exception.Message)")
        [void][System.Windows.Forms.MessageBox]::Show($script:S.Page.FindForm(), "Save failed:`r`n$($_.Exception.Message)", 'RSLinx Driver Manager', 'OK', 'Error')
    }
}
