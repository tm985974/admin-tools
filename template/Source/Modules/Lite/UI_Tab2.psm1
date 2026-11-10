# UI_Tab2.psm1   (LITE TIER)
#
# Reference tab: a filterable grid. Copy this pattern for EVERY list, grid or
# tree with a filter box - filters accept wildcards in any position
# (Base\Services_Filter.psm1):
#   1. keep the full data set in a variable (never filter the control itself)
#   2. Register-ListFilter wires the box (as-you-type or Enter, per environment)
#   3. -OnFilter refills the control from Select-FilterMatch and updates the count
#   4. & $filter.Apply after loading (or reloading) the data
# The sample rows are made up; replace them with the project's real data.

function New-Tab2 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Windows.Forms.TabPage]$Page,
        [Parameter(Mandatory)] $App
    )

    # ---- sample data (the full set; the grid shows a filtered copy) ----
    $sites  = @(@('LON', 'London'), @('PAR', 'Paris'), @('NYC', 'New York'), @('SGP', 'Singapore'))
    $roles  = @(@('APP', 'Application', 'Platform team'), @('SQL', 'Database', 'Database team'),
                @('WEB', 'Web', 'Web team'), @('DC', 'Domain controller', 'Identity team'), @('FS', 'File server', 'Storage team'))
    $data = @(
        foreach ($s in $sites) {
            foreach ($r in $roles) {
                for ($n = 1; $n -le 2; $n++) {
                    [pscustomobject]@{
                        Name  = '{0}-{1}-{2:00}' -f $s[0], $r[0], $n
                        Site  = $s[1]
                        Role  = $r[1]
                        OS    = $(if ($n % 2) { 'Windows Server 2022' } else { 'Windows Server 2019' })
                        Owner = $r[2]
                    }
                }
            }
        }
    )
    $columns = @('Name', 'Site', 'Role', 'OS', 'Owner')

    # ---- controls ----
    $hdr = New-Object System.Windows.Forms.Label
    $hdr.Text = 'Tab 2 - filterable grid (wildcard filter example)'; $hdr.Dock = 'Top'; $hdr.Height = 32
    if (Get-Command Set-HeaderStyle -ErrorAction SilentlyContinue) { Set-HeaderStyle -App $App -Label $hdr } else { $hdr.ForeColor = $App.Theme.Title }
    $hdr.AutoSize = $false

    $bar = New-Object System.Windows.Forms.Panel
    $bar.Dock = 'Top'; $bar.Height = 62

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = 'Filter:'; $lbl.AutoSize = $true; $lbl.Location = New-Object System.Drawing.Point(0, 8)

    $box = New-Object System.Windows.Forms.TextBox
    $box.Location = New-Object System.Drawing.Point(48, 5); $box.Width = 280

    $count = New-Object System.Windows.Forms.Label
    $count.AutoSize = $true; $count.Location = New-Object System.Drawing.Point(340, 8); $count.ForeColor = $App.Theme.Muted

    $hint = New-Object System.Windows.Forms.Label
    $hint.AutoSize = $true; $hint.Location = New-Object System.Drawing.Point(48, 34); $hint.ForeColor = $App.Theme.Muted
    $hint.Text = (Get-FilterHintText) + '   Try:  lon*01    *sql*    web-0?    par*2022'

    $bar.Controls.AddRange(@($lbl, $box, $count, $hint))

    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Dock = 'Fill'
    $grid.ReadOnly = $true; $grid.AllowUserToAddRows = $false; $grid.AllowUserToDeleteRows = $false
    $grid.AllowUserToResizeRows = $false; $grid.RowHeadersVisible = $false; $grid.MultiSelect = $false
    $grid.SelectionMode = 'FullRowSelect'; $grid.AutoSizeColumnsMode = 'Fill'
    $grid.BackgroundColor = $App.Theme.Surface; $grid.BorderStyle = 'FixedSingle'; $grid.GridColor = $App.Theme.Border
    $grid.EnableHeadersVisualStyles = $false
    $grid.ColumnHeadersDefaultCellStyle.BackColor = $App.Theme.Header
    $grid.ColumnHeadersDefaultCellStyle.ForeColor = $App.Theme.Title
    $grid.DefaultCellStyle.SelectionBackColor = $App.Theme.Select
    $grid.DefaultCellStyle.SelectionForeColor = $App.Theme.Text
    $grid.AlternatingRowsDefaultCellStyle.BackColor = $App.Theme.AltRow
    foreach ($c in $columns) { [void]$grid.Columns.Add($c, $c) }

    # ---- filter: refill the grid from the full set ----
    $select = ${function:Select-FilterMatch}     # captured: closures do not see module functions reliably
    $total = $data.Count
    $onFilter = {
        param($Regex, $Text)
        $rows = @(& $select -Items $data -Regex $Regex -Property $columns)
        $grid.SuspendLayout()
        try {
            $grid.Rows.Clear()
            foreach ($r in $rows) { [void]$grid.Rows.Add($r.Name, $r.Site, $r.Role, $r.OS, $r.Owner) }
        }
        finally { $grid.ResumeLayout() }
        $count.Text = '{0} of {1}' -f $rows.Count, $total
        if ($Text.Trim() -ne '' -and $rows.Count -eq 0) { $App.SetStatus("No rows match '$($Text.Trim())'.", 'warn') } else { $App.SetStatus('') }
    }.GetNewClosure()

    $filter = Register-ListFilter -App $App -TextBox $box -OnFilter $onFilter

    # Dock order: Fill first (back), then the Top bands (last added = top-most).
    $Page.Controls.Add($grid)
    $Page.Controls.Add($bar)
    $Page.Controls.Add($hdr)

    & $filter.Apply          # first fill (no filter)
}
