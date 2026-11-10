# UI_RSLinxCommon.psm1   (LITE TIER)
#
# Small control builders shared by this project's tabs, styled from $App.Theme.
#
#   New-RSLinxGrid -App $App [-ReadOnly] [-MultiSelect]           -> styled DataGridView (Dock Fill)
#   Add-RSLinxGridColumn -Grid $g -Name Driver -Header 'Driver name' [-Width 140] [-ReadOnly] [-CheckBox] [-Fill 30]
#   New-RSLinxHeader -App $App -Text '1. Device data' [-Section]   -> Label (Dock Top)
#   New-RSLinxFilterBar -App $App                                  -> @{ Panel; Box; Count }  (Dock Top)
#   New-RSLinxButtonBar -App $App -Buttons @($b1, $b2) [-Dock Bottom]  -> FlowLayoutPanel

function New-RSLinxGrid {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $App, [switch]$ReadOnly, [switch]$MultiSelect)
    $g = New-Object System.Windows.Forms.DataGridView
    $g.Dock = 'Fill'
    $g.ReadOnly = [bool]$ReadOnly
    $g.AllowUserToAddRows = $false; $g.AllowUserToDeleteRows = $false; $g.AllowUserToResizeRows = $false
    $g.RowHeadersVisible = $false; $g.MultiSelect = [bool]$MultiSelect
    $g.SelectionMode = 'FullRowSelect'; $g.AutoSizeColumnsMode = 'None'
    $g.BackgroundColor = $App.Theme.Surface; $g.BorderStyle = 'FixedSingle'; $g.GridColor = $App.Theme.Border
    $g.EnableHeadersVisualStyles = $false
    $g.ColumnHeadersDefaultCellStyle.BackColor = $App.Theme.Header
    $g.ColumnHeadersDefaultCellStyle.ForeColor = $App.Theme.Title
    $g.ColumnHeadersHeightSizeMode = 'AutoSize'
    $g.DefaultCellStyle.SelectionBackColor = $App.Theme.Select
    $g.DefaultCellStyle.SelectionForeColor = $App.Theme.Text
    $g.AlternatingRowsDefaultCellStyle.BackColor = $App.Theme.AltRow
    $g.RowTemplate.Height = 22
    # double buffering keeps large grids from flickering while they refill
    try {
        $pi = [System.Windows.Forms.DataGridView].GetProperty('DoubleBuffered', [System.Reflection.BindingFlags]'Instance,NonPublic')
        $pi.SetValue($g, $true, $null)
    } catch { }
    return $g
}

function Add-RSLinxGridColumn {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Windows.Forms.DataGridView]$Grid,
        [Parameter(Mandatory)] [string]$Name,
        [string]$Header = '',
        [int]$Width = 100,
        [int]$Fill = 0,
        [switch]$ReadOnly,
        [switch]$CheckBox
    )
    if ($CheckBox) { $c = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn }
    else { $c = New-Object System.Windows.Forms.DataGridViewTextBoxColumn }
    $c.Name = $Name
    $c.HeaderText = $(if ($Header) { $Header } else { $Name })
    $c.ReadOnly = [bool]$ReadOnly
    if ($Fill -gt 0) { $c.AutoSizeMode = 'Fill'; $c.FillWeight = $Fill; $c.MinimumWidth = 60 }
    else { $c.Width = $Width }
    [void]$Grid.Columns.Add($c)
    return $c
}

function New-RSLinxHeader {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $App, [Parameter(Mandatory)] [string]$Text, [switch]$Section)
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Text
    if ($Section) { Set-SectionStyle -App $App -Label $l } else { Set-HeaderStyle -App $App -Label $l }
    $l.AutoSize = $false; $l.Dock = 'Top'
    $l.Height = $(if ($Section) { 24 } else { 30 })
    $l.TextAlign = 'MiddleLeft'
    return $l
}

function New-RSLinxFilterBar {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $App, [int]$BoxWidth = 220)
    $bar = New-Object System.Windows.Forms.Panel
    $bar.Dock = 'Top'; $bar.Height = 50

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = 'Filter:'; $lbl.AutoSize = $true; $lbl.Location = New-Object System.Drawing.Point(0, 7)

    $box = New-Object System.Windows.Forms.TextBox
    $box.Location = New-Object System.Drawing.Point(46, 4); $box.Width = $BoxWidth

    $count = New-Object System.Windows.Forms.Label
    $count.AutoSize = $true; $count.Location = New-Object System.Drawing.Point((56 + $BoxWidth), 7); $count.ForeColor = $App.Theme.Muted

    $hint = New-Object System.Windows.Forms.Label
    $hint.AutoSize = $true; $hint.Location = New-Object System.Drawing.Point(46, 30); $hint.ForeColor = $App.Theme.Muted
    $hint.Text = Get-FilterHintText

    $bar.Controls.AddRange(@($lbl, $box, $count, $hint))
    return @{ Panel = $bar; Box = $box; Count = $count }
}

function New-RSLinxButtonBar {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $App, [object[]]$Buttons = @(), [string]$Dock = 'Bottom', [int]$Height = 40)
    $f = New-Object System.Windows.Forms.FlowLayoutPanel
    $f.Dock = $Dock; $f.Height = $Height; $f.WrapContents = $false
    $f.Padding = New-Object System.Windows.Forms.Padding(0, 4, 0, 0)
    foreach ($b in $Buttons) { if ($b) { $b.Margin = New-Object System.Windows.Forms.Padding(0, 0, 8, 0); $f.Controls.Add($b) } }
    return $f
}
