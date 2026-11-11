# UI_ToolBoxCommon.psm1   (LITE TIER)
#
# Small UI pieces the ToolBox tabs share.
#   New-TbHeader  -App -Text            the tab's title band
#   New-TbBar     -App -Height          a button row (FlowLayoutPanel, Dock Top)
#   New-TbGrid    -App -Columns @(...)  a read-only, full-row grid in the theme
#   Get-TbGridSelection -Grid           the row objects (Tag) of the selected rows
#   Open-TbFolder -App -Path            Explorer, through the command window

function New-TbHeader {
    param([Parameter(Mandatory)] $App, [string]$Text)
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Text; $l.Dock = 'Top'; $l.Height = 32; $l.AutoSize = $false
    if (Get-Command Set-HeaderStyle -ErrorAction SilentlyContinue) { Set-HeaderStyle -App $App -Label $l } else { $l.ForeColor = $App.Theme.Title }
    $l.AutoSize = $false
    return $l
}

function New-TbBar {
    param([Parameter(Mandatory)] $App, [int]$Height = 40)
    $b = New-Object System.Windows.Forms.FlowLayoutPanel
    $b.Dock = 'Top'; $b.Height = $Height; $b.WrapContents = $false
    $b.Padding = New-Object System.Windows.Forms.Padding(0, 4, 0, 0)
    return $b
}

function New-TbGrid {
    param([Parameter(Mandatory)] $App, [Parameter(Mandatory)] [string[]]$Columns, [switch]$Multi)
    $g = New-Object System.Windows.Forms.DataGridView
    $g.Dock = 'Fill'
    $g.ReadOnly = $true; $g.AllowUserToAddRows = $false; $g.AllowUserToDeleteRows = $false
    $g.AllowUserToResizeRows = $false; $g.RowHeadersVisible = $false; $g.MultiSelect = [bool]$Multi
    $g.SelectionMode = 'FullRowSelect'; $g.AutoSizeColumnsMode = 'Fill'
    $g.BackgroundColor = $App.Theme.Surface; $g.BorderStyle = 'FixedSingle'; $g.GridColor = $App.Theme.Border
    $g.EnableHeadersVisualStyles = $false
    $g.ColumnHeadersDefaultCellStyle.BackColor = $App.Theme.Header
    $g.ColumnHeadersDefaultCellStyle.ForeColor = $App.Theme.Title
    $g.DefaultCellStyle.SelectionBackColor = $App.Theme.Select
    $g.DefaultCellStyle.SelectionForeColor = $App.Theme.Text
    $g.AlternatingRowsDefaultCellStyle.BackColor = $App.Theme.AltRow
    foreach ($c in $Columns) { [void]$g.Columns.Add($c, $c) }
    return $g
}

function Get-TbGridSelection {
    param([Parameter(Mandatory)] $Grid)
    return @($Grid.SelectedRows | Sort-Object Index | ForEach-Object { $_.Tag } | Where-Object { $_ })
}

function Format-TbTime {
    param($Time)
    if ($Time) { return ([datetime]$Time).ToString('yyyy-MM-dd HH:mm') }
    return ''
}

function Open-TbFolder {
    param([Parameter(Mandatory)] $App, [string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { $App.SetStatus("Folder not found: $Path", 'warn'); return }
    $r = Invoke-AppCommand -App $App -Title 'Open folder' -Kind Read -RunLabel 'Open' -Summary "Open $Path in Explorer." `
        -Code ('Start-Process -FilePath explorer.exe -ArgumentList ' + (Format-AppCommandValue ('"' + $Path + '"')))
    if ($r.Errors.Count) { $App.SetStatus("Not opened: $($r.Errors[0])", 'err') }
}
