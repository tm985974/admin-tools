# SAM_Grid.psm1   (LITE TIER)
#
# Data grids for the SCCM tabs: a DataGridView bound to a DataTable through a
# DataView, so header-click sorting (numeric for counts) and type-to-filter
# are done by .NET, not by PowerShell loops.
#
#   $g = New-SamDataGrid -Columns @(@{ Name='Name'; Header='Device'; Width=200 },
#                                   @{ Name='Members'; Type='int'; Width=80 }, ...)
#                        [-Key 'ResourceID'] [-Multi] [-ColorRules @{...}] [-GrayColumn 'Gray']
#   Set-SamGridData     -G $g -Items <objects with those property names>
#   Set-SamGridFilter   -G $g -Text 'abc' [-CountLabel $label]
#   Get-SamGridSelected -G $g      -> the source objects of the selected rows
#
# Column: Name (property), Header, Type = string | int | date, Width (px), Fill
# (weight; the column stretches), Hidden.
# ColorRules: @{ <column> = @{ Positive = <Color> } }  (int > 0)
#             @{ <column> = @{ Map = @{ 'Error' = <Color>; ... } } }
# GrayColumn: a (usually hidden) column whose value $true greys the row text.

function New-SamDataGrid {
    param(
        $Columns,
        [string]$Key = '',
        [switch]$Multi,
        $ColorRules = $null,
        [string]$GrayColumn = ''
    )
    $cols = New-Object System.Collections.ArrayList
    foreach ($c in @($Columns)) { if ($c) { [void]$cols.Add($c) } }

    $dt = New-Object System.Data.DataTable
    foreach ($c in $cols) {
        $t = switch ([string]$c.Type) { 'int' { [int] } 'date' { [datetime] } default { [string] } }
        [void]$dt.Columns.Add([string]$c.Name, $t)
    }
    [void]$dt.Columns.Add('__Obj', [object])
    [void]$dt.Columns.Add('__Match', [bool])
    $view = New-Object System.Data.DataView($dt)

    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.AutoGenerateColumns = $false
    $grid.ReadOnly = $true
    $grid.AllowUserToAddRows = $false
    $grid.AllowUserToDeleteRows = $false
    $grid.AllowUserToResizeRows = $false
    $grid.SelectionMode = 'FullRowSelect'
    $grid.MultiSelect = [bool]$Multi
    $grid.RowHeadersVisible = $false
    $grid.BackgroundColor = [System.Drawing.Color]::White
    $grid.BorderStyle = 'None'
    $grid.DefaultCellStyle.SelectionBackColor = [System.Drawing.Color]::SteelBlue
    $grid.DefaultCellStyle.SelectionForeColor = [System.Drawing.Color]::White
    $grid.ColumnHeadersHeightSizeMode = 'AutoSize'
    $grid.RowTemplate.Height = 22
    try {
        $grid.AlternatingRowsDefaultCellStyle.BackColor = $global:SAM.App.Theme.AltRow
    } catch { }
    try {
        $pi = $grid.GetType().GetProperty('DoubleBuffered', [System.Reflection.BindingFlags]'Instance,NonPublic')
        $pi.SetValue($grid, $true, $null)
    } catch { }

    foreach ($c in $cols) {
        $gc = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
        $gc.Name = [string]$c.Name
        $gc.DataPropertyName = [string]$c.Name
        $gc.HeaderText = $(if ($c.Header) { [string]$c.Header } else { [string]$c.Name })
        $gc.SortMode = 'Automatic'
        if ($c.Fill) { $gc.AutoSizeMode = 'Fill'; $gc.FillWeight = [single]$c.Fill; $gc.MinimumWidth = 80 }
        else { $gc.Width = $(if ($c.Width) { [int]$c.Width } else { 120 }) }
        if ([string]$c.Type -eq 'int') { $gc.DefaultCellStyle.Alignment = 'MiddleRight' }
        if ([string]$c.Type -eq 'date') { $gc.DefaultCellStyle.Format = 'yyyy-MM-dd HH:mm' }
        if ($c.Hidden) { $gc.Visible = $false }
        [void]$grid.Columns.Add($gc)
    }
    $grid.DataSource = $view

    $g = @{
        Grid = $grid; Table = $dt; View = $view; Cols = $cols
        Key = $(if ($Key) { $Key } else { [string]$cols[0].Name })
        Rules = $(if ($ColorRules) { $ColorRules } else { @{} })
        Gray = $GrayColumn
        GrayColor = [System.Drawing.Color]::Gray
        Text = ''
    }

    # Right-click selects the row under the mouse (keeps a multi-selection that includes it)
    $grid.Add_CellMouseDown({
        param($s, $e)
        if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Right -or $e.RowIndex -lt 0) { return }
        $row = $s.Rows[$e.RowIndex]
        if (-not $row.Selected) { $s.ClearSelection(); $row.Selected = $true }
    })

    # Data errors are logged instead of the "DataGridView Default Error Dialog"
    $grid.Add_DataError({
        param($s, $e)
        $e.ThrowException = $false
        try { Write-SamLog "Grid data error (row $($e.RowIndex)): $($e.Exception.Message)" -Level Warning } catch { }
    })

    if ($g.Rules.Count -gt 0 -or $g.Gray) {
        $grid.Add_CellFormatting({
            param($s, $e)
            if ($e.RowIndex -lt 0 -or $e.RowIndex -ge $g.View.Count) { return }
            if ($g.Gray) {
                $drv = $g.View[$e.RowIndex]
                if ($drv -and [string]$drv.Row[$g.Gray] -eq 'True') { $e.CellStyle.ForeColor = $g.GrayColor }
            }
            $rule = $g.Rules[$s.Columns[$e.ColumnIndex].DataPropertyName]
            if (-not $rule) { return }
            $v = $e.Value
            if ($rule.Map) {
                $c = $rule.Map[[string]$v]
                if ($c) { $e.CellStyle.BackColor = $c }
            }
            elseif ($rule.Positive -and $v -is [int] -and $v -gt 0) { $e.CellStyle.BackColor = $rule.Positive }
        }.GetNewClosure())
    }
    return $g
}

function Set-SamGridData {
    param($G, $Items)
    $grid = $G.Grid
    $keep = @{}
    foreach ($r in $grid.SelectedRows) {
        $drv = $r.DataBoundItem
        if ($drv) { $keep[[string]$drv.Row[$G.Key]] = $true }
    }
    $first = -1
    try { $first = $grid.FirstDisplayedScrollingRowIndex } catch { }

    $t = $G.Table
    $n = $G.Cols.Count
    $grid.SuspendLayout()
    # Detach while the table is rebuilt: a bound grid can otherwise paint / format
    # a row index that no longer exists ("Index n does not have a value").
    $sort = $G.View.Sort
    $grid.DataSource = $null
    $t.BeginLoadData()
    $t.Clear()
    foreach ($it in @($Items)) {
        if ($null -eq $it) { continue }
        $vals = New-Object object[] ($n + 2)
        for ($i = 0; $i -lt $n; $i++) {
            $c = $G.Cols[$i]
            $v = $it.([string]$c.Name)
            switch ([string]$c.Type) {
                'int'  { $x = 0; if ($null -ne $v) { [void][int]::TryParse([string]$v, [ref]$x) }; $vals[$i] = $x }
                'date' { if ($v -is [datetime] -and $v.Year -gt 1900) { $vals[$i] = $v } else { $vals[$i] = [DBNull]::Value } }
                default { $vals[$i] = $(if ($null -eq $v) { '' } else { [string]$v }) }
            }
        }
        $vals[$n] = $it
        $vals[$n + 1] = $true
        [void]$t.Rows.Add($vals)
    }
    $t.EndLoadData()
    $grid.DataSource = $G.View
    Set-SamGridSortGlyph -G $G -Sort $sort
    $grid.ClearSelection()
    if ($keep.Count) {
        foreach ($r in $grid.Rows) {
            $drv = $r.DataBoundItem
            if ($drv -and $keep.ContainsKey([string]$drv.Row[$G.Key])) { $r.Selected = $true }
        }
    }
    if ($first -ge 0 -and $first -lt $grid.Rows.Count) { try { $grid.FirstDisplayedScrollingRowIndex = $first } catch { } }
    $grid.ResumeLayout()
}

# Re-binding clears the header sort arrow; the DataView keeps its sort, so show it again.
function Set-SamGridSortGlyph {
    param($G, [string]$Sort)
    if (-not $Sort) { return }
    $m = [regex]::Match($Sort, '^\[?([^\]\s]+)\]?(?:\s+(ASC|DESC))?', 'IgnoreCase')
    if (-not $m.Success) { return }
    $col = $G.Grid.Columns[$m.Groups[1].Value]
    if (-not $col) { return }
    $col.HeaderCell.SortGlyphDirection = if ($m.Groups[2].Value -ieq 'DESC') { 'Descending' } else { 'Ascending' }
}

function ConvertTo-SamLikeText {
    param([string]$Text)
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $Text.ToCharArray()) {
        switch ($ch) {
            '['  { [void]$sb.Append('[[]') }
            ']'  { [void]$sb.Append('[]]') }
            '*'  { [void]$sb.Append('[*]') }
            '%'  { [void]$sb.Append('[%]') }
            "'"  { [void]$sb.Append("''") }
            default { [void]$sb.Append($ch) }
        }
    }
    return $sb.ToString()
}

# Name filter: the FIRST column only (device / collection / application ...),
# "contains", case-insensitive. * = any text, ? = one character, anywhere:
#   ivn        -> names containing "ivn"
#   ivn-*-ic   -> names containing "ivn-", then anything, then "-ic"
# A plain term uses the DataView filter; a wildcard term is matched in a loop
# (the DataView LIKE only allows * at the ends) and flags rows in __Match.
function New-SamNameMatcher {
    param([string]$Text)
    $t = ([string]$Text).Trim()
    if (-not $t) { return $null }
    $rx = [regex]::Escape($t).Replace('\*', '.*').Replace('\?', '.')
    return New-Object System.Text.RegularExpressions.Regex($rx, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
}

function Set-SamGridFilter {
    param($G, [string]$Text, $CountLabel = $null)
    $G.Text = [string]$Text
    $t = ([string]$Text).Trim()
    $name = [string]$G.Cols[0].Name
    $f = ''
    if ($t -and ($t.Contains('*') -or $t.Contains('?'))) {
        $rx = New-SamNameMatcher $t
        $grid = $G.Grid
        $keep = @{}
        foreach ($sr in $grid.SelectedRows) { $drv = $sr.DataBoundItem; if ($drv) { $keep[[string]$drv.Row[$G.Key]] = $true } }
        $sort = $G.View.Sort
        $grid.DataSource = $null
        $G.Table.BeginLoadData()
        foreach ($r in $G.Table.Rows) { $r['__Match'] = $rx.IsMatch([string]$r[$name]) }
        $G.Table.EndLoadData()
        $f = '[__Match] = true'
        $G.View.RowFilter = $f
        $grid.DataSource = $G.View
        Set-SamGridSortGlyph -G $G -Sort $sort
        $grid.ClearSelection()
        if ($keep.Count) { foreach ($gr in $grid.Rows) { $drv = $gr.DataBoundItem; if ($drv -and $keep.ContainsKey([string]$drv.Row[$G.Key])) { $gr.Selected = $true } } }
    }
    else {
        if ($t) { $f = "[$name] LIKE '%" + (ConvertTo-SamLikeText $t) + "%'" }
        try { $G.View.RowFilter = $f } catch { $G.View.RowFilter = '' }
    }
    if ($CountLabel) { Update-SamGridCount -G $G -CountLabel $CountLabel }
}

function Update-SamGridCount {
    param($G, $CountLabel)
    $CountLabel.Text = if ($G.View.RowFilter) { "$($G.View.Count) of $($G.Table.Rows.Count) shown" } else { "$($G.Table.Rows.Count) total" }
    $sel = $G.Grid.SelectedRows.Count
    if ($sel -gt 1) { $CountLabel.Text += "  -  $sel selected" }
}
function Get-SamGridSelected {
    param($G)
    $out = New-Object System.Collections.ArrayList
    $rows = @($G.Grid.SelectedRows | Sort-Object Index)
    foreach ($r in $rows) {
        $drv = $r.DataBoundItem
        if ($drv) { [void]$out.Add($drv.Row['__Obj']) }
    }
    return $out.ToArray()
}

function Select-SamGridRowsBy {
    param($G, [string]$Property, $Values)
    $set = @{}
    foreach ($v in @($Values)) { $set[[string]$v] = $true }
    $G.Grid.ClearSelection()
    $firstIdx = -1
    foreach ($r in $G.Grid.Rows) {
        $drv = $r.DataBoundItem
        if (-not $drv) { continue }
        $o = $drv.Row['__Obj']
        if ($o -and $set.ContainsKey([string]$o.$Property)) {
            $r.Selected = $true
            if ($firstIdx -lt 0) { $firstIdx = $r.Index }
        }
    }
    if ($firstIdx -ge 0) { try { $G.Grid.FirstDisplayedScrollingRowIndex = $firstIdx } catch { } }
}

# Shows the selected-row count on a label whenever the selection changes.
function Register-SamGridCount {
    param($G, $CountLabel)
    $G.Grid.Add_SelectionChanged({ Update-SamGridCount -G $G -CountLabel $CountLabel }.GetNewClosure())
}

# Writes the rows currently shown (filter applied, in the shown order) to a CSV file.
function Export-SamGridCsv {
    param($G, [string]$Name = 'export')
    $sfd = New-Object System.Windows.Forms.SaveFileDialog
    $sfd.Filter = 'CSV (*.csv)|*.csv'
    $safe = ($Name -replace '[\\/:*?"<>|]', '_').Trim()
    $sfd.FileName = '{0}_{1}.csv' -f $safe, (Get-Date -Format 'yyyyMMdd_HHmm')
    if ($sfd.ShowDialog((Get-SamOwnerForm)) -ne [System.Windows.Forms.DialogResult]::OK) { return }
    $visible = @($G.Cols | Where-Object { -not $_.Hidden })
    $sb = New-Object System.Text.StringBuilder
    $q = { param($s) '"' + ([string]$s -replace '"', '""') + '"' }
    [void]$sb.AppendLine((($visible | ForEach-Object { & $q $(if ($_.Header) { $_.Header } else { $_.Name }) }) -join ','))
    foreach ($r in $G.Grid.Rows) {
        $drv = $r.DataBoundItem
        if (-not $drv) { continue }
        $cells = foreach ($c in $visible) {
            $v = $drv.Row[[string]$c.Name]
            if ($v -is [datetime]) { $v = $v.ToString('yyyy-MM-dd HH:mm') }
            elseif ($v -is [DBNull]) { $v = '' }
            & $q $v
        }
        [void]$sb.AppendLine(($cells -join ','))
    }
    try {
        [IO.File]::WriteAllText($sfd.FileName, $sb.ToString(), (New-Object Text.UTF8Encoding($true)))
        Write-SamLog "Exported $($G.Grid.Rows.Count) row(s) to $($sfd.FileName)" -Level Success
    }
    catch { Write-SamLog "Export failed: $($_.Exception.Message)" -Level Error }
}
