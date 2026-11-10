#region -- Services.AD.Reporting.psm1 ----------------------------------------
# Concern : CSV/HTML export, confirm dialog, shared UI controls
#           (section panel, standard button, standard grid, grid data loader,
#           placeholder helpers).
# Load order: 1b - no dependencies on other AD-Admin modules.
#             Write-OperationLog / Get-OperationLog live in Services.Logging.psm1.
# Split from: ADReporting.psm1
# Changes   : Added Get-GridRowsAsObjects - generic "read every row of this
#             grid back out as objects" helper for Export HTML buttons,
#             keyed off the grid's own current columns rather than a
#             hardcoded property list per call site. Added for the Audit
#             tab's list reports (ADAudit.ListReports.*), which needed the
#             same extraction shape 10 times over; new call sites elsewhere
#             should prefer this over writing another one-off extractor.
#             BUG FIX: Set-GridData used to force every value to a string
#             before adding it to the grid, and every column was created
#             with no ValueType set - so every column in every grid in this
#             app sorted lexicographically regardless of its real data type
#             ("15" sorting before "2"). Rewritten to preserve each column's
#             real type (Int32/Int64/Double/Decimal/DateTime) when every row
#             agrees on it, so numeric and date columns now sort correctly;
#             a column that legitimately mixes real values with a status
#             sentinel (e.g. the literal text "Never set") is left as text-
#             sortable, deliberately, since there's no single correct
#             chronological answer for where that sentinel belongs among
#             real dates. Get-GridRowsAsObjects updated to read
#             FormattedValue instead of Value so HTML/CSV exports keep
#             matching whatever the grid displays (a DateTime column's
#             display Format would otherwise be lost on export).
#endregion

#region -- Export-ToCSV -------------------------------------------------------
function Export-ToCSV {
    param([PSCustomObject]$Context, [object]$Data, [string]$BaseName = 'Export')
    try {
        $dir = if ($Context -and $Context.ExportsDir) { $Context.ExportsDir } else { Join-Path $PSScriptRoot '..\Exports' }
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $ts   = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
        $path = Join-Path $dir "$BaseName-$ts.csv"
        $Data | Export-Csv -Path $path -NoTypeInformation -Encoding UTF8 -ErrorAction Stop
        return $path
    } catch { return '' }
}
#endregion

#region -- Export-ToHTML ------------------------------------------------------
function Export-ToHTML {
    param(
        [PSCustomObject]$Context,
        [string]$Title,
        [string]$Subtitle = '',
        [object]$Data,
        [string]$BaseName = 'Export'
    )
    try {
        $dir = if ($Context -and $Context.ExportsDir) { $Context.ExportsDir } else { Join-Path $PSScriptRoot '..\Exports' }
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $ts   = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
        $path = Join-Path $dir "$BaseName-$ts.html"
        $list = @($Data)
        if ($list.Count -eq 0) { return '' }
        $cols = $list[0].PSObject.Properties.Name
        $sb   = [System.Text.StringBuilder]::new()
        [void]$sb.AppendLine('<!DOCTYPE html><html><head><meta charset="UTF-8">')
        [void]$sb.AppendLine("<title>$Title</title>")
        [void]$sb.AppendLine('<style>
body{font-family:Segoe UI,sans-serif;font-size:13px;background:#f0f2f5;color:#222;margin:24px}
h1{color:#003d7a;margin-bottom:4px} p.sub{color:#555;margin-top:0;margin-bottom:16px}
table{border-collapse:collapse;width:100%;background:#fff;box-shadow:0 1px 4px rgba(0,0,0,.1)}
th{background:#0063b1;color:#fff;padding:8px 10px;text-align:left;font-size:12px}
td{padding:6px 10px;border-bottom:1px solid #e0e6f0;font-size:12px}
tr:nth-child(even) td{background:#f5f8fc} tr:hover td{background:#e8f0fb}
.ts{color:#888;font-size:11px;margin-top:20px}
</style></head><body>')
        [void]$sb.AppendLine("<h1>$Title</h1>")
        if ($Subtitle) { [void]$sb.AppendLine("<p class='sub'>$Subtitle</p>") }
        [void]$sb.AppendLine('<table><thead><tr>')
        foreach ($col in $cols) { [void]$sb.AppendLine("<th>$col</th>") }
        [void]$sb.AppendLine('</tr></thead><tbody>')
        foreach ($item in $list) {
            [void]$sb.Append('<tr>')
            foreach ($col in $cols) {
                $val = ([string]($item.$col)) -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;'
                [void]$sb.Append("<td>$val</td>")
            }
            [void]$sb.AppendLine('</tr>')
        }
        [void]$sb.AppendLine("</tbody></table>")
        [void]$sb.AppendLine("<p class='ts'>Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  |  $($list.Count) row(s)</p>")
        [void]$sb.AppendLine('</body></html>')
        [System.IO.File]::WriteAllText($path, $sb.ToString(), [System.Text.Encoding]::UTF8)
        return $path
    } catch { return '' }
}
#endregion

#region -- Show-ExportResult --------------------------------------------------
function Show-ExportResult {
    param([string]$FilePath)
    if (-not $FilePath) {
        if (Get-Command Set-Status -ErrorAction SilentlyContinue) { Set-Status 'Export failed.' 'err' }
        return
    }
    if (Get-Command Set-Status -ErrorAction SilentlyContinue) { Set-Status "Exported: $FilePath" 'ok' }
    try { Start-Process explorer.exe -ArgumentList "/select,`"$FilePath`"" } catch { }
}
#endregion

#region -- New-ADCommandText ----------------------------------------------------
# The exact command text for an AD cmdlet run once per identity, as the action
# runs it (the -Server the action uses, its -Confirm / -ErrorAction switches),
# for Confirm-Action -Code. One line per identity; -Comment adds '#' lines on
# top (e.g. the recovery snapshot each action takes first).
function ConvertTo-ADCodeLiteral {
    param([AllowNull()] $Value)
    if (Get-Command Format-AppCommandValue -ErrorAction SilentlyContinue) { return (Format-AppCommandValue $Value) }
    return "'" + ([string]$Value).Replace("'", "''") + "'"
}

function New-ADCommandText {
    param(
        [Parameter(Mandatory)] [string]$Cmdlet,
        [string[]]$Identity,
        [PSCustomObject]$Context,
        [string]$Tail = '',
        [string]$Comment = ''
    )
    $lines = New-Object System.Collections.Generic.List[string]
    if ($Comment) { foreach ($c in ($Comment -split "`r?`n")) { [void]$lines.Add('# ' + $c) } }
    $srv = ''
    if ($Context -and $Context.TargetDC) { $srv = ' -Server ' + (ConvertTo-ADCodeLiteral ([string]$Context.TargetDC)) }
    foreach ($i in @($Identity | Where-Object { $_ })) {
        $l = $Cmdlet + ' -Identity ' + (ConvertTo-ADCodeLiteral ([string]$i)) + $srv
        if ($Tail) { $l += ' ' + $Tail }
        [void]$lines.Add($l)
    }
    return ($lines -join "`r`n")
}
#endregion

#region -- Confirm-Action -----------------------------------------------------
# -Code (v1.2.12): the exact PowerShell the action is about to run. When given,
# the confirmation IS the engine's command window (Show-AppCommandDialog via
# Confirm-AppCommand -Always): the message on top, the code below with Copy,
# then the action button / Cancel - one popup, never two. The command is
# logged ([Command] Run / Cancelled). Without -Code: the original dialog.
function Confirm-Action {
    param([string]$Title, [string]$Message, [string]$ActionLabel = 'Confirm', [string]$Code = '')
    if ($Code -and (Get-Command Confirm-AppCommand -ErrorAction SilentlyContinue)) {
        return [bool](Confirm-AppCommand -App $script:ADApp -Title $Title -Code $Code -Summary $Message -RunLabel $ActionLabel -Kind Change -Always)
    }
    $F_UI   = New-Object System.Drawing.Font('Segoe UI', 9)
    $F_UI_B = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $F_13B  = New-Object System.Drawing.Font('Segoe UI', 13, [System.Drawing.FontStyle]::Bold)
    $dlg                  = New-Object System.Windows.Forms.Form
    $dlg.Text             = $Title
    $dlg.ClientSize       = New-Object System.Drawing.Size(460, 220)
    $dlg.FormBorderStyle  = 'FixedSingle'
    $dlg.MaximizeBox      = $false
    $dlg.StartPosition    = 'CenterParent'
    $dlg.BackColor        = [System.Drawing.Color]::FromArgb(235,238,242)
    $pTitle               = New-Object System.Windows.Forms.Panel
    $pTitle.Dock          = 'Top'; $pTitle.Height = 48
    $pTitle.BackColor     = [System.Drawing.Color]::FromArgb(0,99,177)
    $dlg.Controls.Add($pTitle)
    $lT                   = New-Object System.Windows.Forms.Label
    $lT.Text              = "   $Title"
    $lT.Dock              = 'Fill'; $lT.Font = $F_13B
    $lT.ForeColor         = [System.Drawing.Color]::White
    $lT.TextAlign         = 'MiddleLeft'
    $pTitle.Controls.Add($lT)
    $lMsg                 = New-Object System.Windows.Forms.Label
    $lMsg.Text            = $Message
    $lMsg.Location        = New-Object System.Drawing.Point(16, 62)
    $lMsg.Size            = New-Object System.Drawing.Size(428, 110)
    $lMsg.Font            = $F_UI
    $lMsg.ForeColor       = [System.Drawing.Color]::FromArgb(40,40,40)
    $dlg.Controls.Add($lMsg)
    $btnOK                = New-Object System.Windows.Forms.Button
    $btnOK.Text           = $ActionLabel
    $btnOK.Location       = New-Object System.Drawing.Point(248, 178)
    $btnOK.Size           = New-Object System.Drawing.Size(96, 30)
    $btnOK.FlatStyle      = 'Standard'
    $btnOK.Font           = $F_UI_B
    $btnOK.DialogResult   = [System.Windows.Forms.DialogResult]::OK
    $dlg.Controls.Add($btnOK)
    $btnCancel            = New-Object System.Windows.Forms.Button
    $btnCancel.Text       = 'Cancel'
    $btnCancel.Location   = New-Object System.Drawing.Point(352, 178)
    $btnCancel.Size       = New-Object System.Drawing.Size(96, 30)
    $btnCancel.FlatStyle  = 'Standard'
    $btnCancel.Font       = $F_UI
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $dlg.Controls.Add($btnCancel)
    $dlg.AcceptButton     = $btnOK
    $dlg.CancelButton     = $btnCancel
    return ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK)
}
#endregion

#region -- New-SectionPanel ---------------------------------------------------
function New-SectionPanel {
    <#
    .SYNOPSIS
        Creates a titled section panel with a coloured header strip and white
        content area. Returns the inner white Panel for child controls.
    .PARAMETER H
        Total outer border height (legacy, used when ContentH is not supplied).
    .PARAMETER ContentH
        Height of the usable white content area inside the section (excludes the
        24px header strip and 1px bottom border pixel). When supplied, H is
        auto-calculated as ContentH + 25, eliminating all control-clip issues.
        Prefer ContentH for all new or fixed call sites.
    .OUTPUTS
        The inner white Panel. Add child controls to this returned panel.
    #>
    param(
        [System.Windows.Forms.Control]$Parent,
        [string]$Title,
        [int]$X,
        [int]$Y,
        [int]$W,
        [int]$H        = 0,
        [int]$ContentH = 0
    )
    $HDR_H = 24
    if ($ContentH -gt 0) { $H = $ContentH + $HDR_H + 1 }

    $border              = New-Object System.Windows.Forms.Panel
    $border.Location     = New-Object System.Drawing.Point($X, $Y)
    $border.Size         = New-Object System.Drawing.Size($W, $H)
    $border.BackColor    = [System.Drawing.Color]::FromArgb(160, 160, 160)
    $Parent.Controls.Add($border)

    $hdr                 = New-Object System.Windows.Forms.Panel
    $hdr.Location        = New-Object System.Drawing.Point(1, 0)
    $hdr.Size            = New-Object System.Drawing.Size(($W - 2), $HDR_H)
    $hdr.BackColor       = [System.Drawing.Color]::FromArgb(210, 225, 245)
    $border.Controls.Add($hdr)

    $lbl                 = New-Object System.Windows.Forms.Label
    $lbl.Text            = "  $Title"
    $lbl.Dock            = 'Fill'
    $lbl.Font            = New-Object System.Drawing.Font('Segoe UI', 8, [System.Drawing.FontStyle]::Bold)
    $lbl.ForeColor       = [System.Drawing.Color]::FromArgb(0, 80, 160)
    $lbl.TextAlign       = 'MiddleLeft'
    $hdr.Controls.Add($lbl)

    $inner               = New-Object System.Windows.Forms.Panel
    $inner.Location      = New-Object System.Drawing.Point(1, $HDR_H)
    $inner.Size          = New-Object System.Drawing.Size(($W - 2), ($H - $HDR_H - 1))
    $inner.BackColor     = [System.Drawing.Color]::White
    $border.Controls.Add($inner)

    return $inner
}
#endregion

#region -- New-StdButton ------------------------------------------------------
function New-StdButton {
    param(
        [string]$Text,
        [int]$X, [int]$Y,
        [int]$W = 120, [int]$H = 26,
        [System.Windows.Forms.Control]$Parent = $null
    )
    $btn           = New-Object System.Windows.Forms.Button
    $btn.Text      = $Text
    $btn.Location  = New-Object System.Drawing.Point($X, $Y)
    $btn.Size      = New-Object System.Drawing.Size($W, $H)
    $btn.FlatStyle = 'Standard'
    $btn.Font      = New-Object System.Drawing.Font('Segoe UI', 9)
    if ($Parent) { $Parent.Controls.Add($btn) }
    return $btn
}
#endregion

#region -- New-StdGrid --------------------------------------------------------
function New-StdGrid {
    param(
        [int]$X, [int]$Y, [int]$W, [int]$H,
        [System.Windows.Forms.Control]$Parent = $null
    )
    $grid                            = New-Object System.Windows.Forms.DataGridView
    $grid.Location                   = New-Object System.Drawing.Point($X, $Y)
    $grid.Size                       = New-Object System.Drawing.Size($W, $H)
    $grid.ReadOnly                   = $true
    $grid.AllowUserToAddRows         = $false
    $grid.AllowUserToDeleteRows      = $false
    $grid.AllowUserToResizeRows      = $false
    $grid.RowHeadersVisible          = $false
    $grid.MultiSelect                = $false
    $grid.SelectionMode              = 'FullRowSelect'
    $grid.AutoSizeColumnsMode        = 'Fill'
    $grid.BackgroundColor            = [System.Drawing.Color]::White
    $grid.BorderStyle                = 'None'
    $grid.Font                       = New-Object System.Drawing.Font('Consolas', 9)
    $grid.ColumnHeadersDefaultCellStyle.Font      = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $grid.ColumnHeadersDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(210, 225, 245)
    $grid.ColumnHeadersDefaultCellStyle.ForeColor = [System.Drawing.Color]::FromArgb(0, 80, 160)
    $grid.ColumnHeadersHeightSizeMode             = 'DisableResizing'
    $grid.ColumnHeadersHeight                     = 26
    $grid.EnableHeadersVisualStyles               = $false
    $grid.GridColor                               = [System.Drawing.Color]::FromArgb(220, 230, 240)
    $grid.DefaultCellStyle.SelectionBackColor     = [System.Drawing.Color]::FromArgb(180, 210, 245)
    $grid.DefaultCellStyle.SelectionForeColor     = [System.Drawing.Color]::FromArgb(0, 40, 80)
    if ($Parent) { $Parent.Controls.Add($grid) }
    return $grid
}
#endregion

#region -- Set-GridData -------------------------------------------------------
function Set-GridData {
    <#
    .SYNOPSIS
        Populates a DataGridView from a list of objects, one column per
        property. Preserves each column's real data type (Int32/Int64/
        Double/Decimal/DateTime) when every row agrees on it, so numeric and
        date columns sort correctly (15 > 2 numerically, not "15" < "2"
        lexicographically) - the previous version forced every value to a
        string before adding it to the grid, which is why "Days"-style
        columns sorted as text everywhere in the app.
    .PARAMETER DateFormat
        Display format applied to any column whose values are ALL
        [datetime] - default 'yyyy-MM-dd', matching the date format used
        everywhere else in this app. Ignored for columns that don't
        qualify for strict typing (see below).
    .DESCRIPTION
        A column only gets a strict ValueType when EVERY non-blank value in
        that column, across ALL rows, is the exact same qualifying type.
        Sampling only the first row is not enough - a status
        sentinel like the literal text "Never set" might not appear until a
        later row. A column that legitimately mixes real dates/numbers with
        a status sentinel (e.g. a Password-Last-Set column showing "Never
        set" for accounts that have none) is deliberately left untyped and
        text-comparable, exactly as before - there is no single correct
        chronological answer for where "Never set" sorts among real dates,
        so falling back to text sort for those specific columns is the
        right behavior, not a residual bug. Purely numeric or purely
        datetime columns (no sentinel mixed in) get real sorting.
    #>
    param(
        [System.Windows.Forms.DataGridView]$Grid,
        [object]$Data,
        [string[]]$Columns = @(),
        [string]$DateFormat = 'yyyy-MM-dd'
    )
    $Grid.SuspendLayout()
    $Grid.Rows.Clear()
    $Grid.Columns.Clear()
    $list = @($Data)
    if ($list.Count -eq 0) { $Grid.ResumeLayout(); return }
    $cols = if ($Columns.Count -gt 0) { $Columns } else { $list[0].PSObject.Properties.Name }

    # A value counts as "blank" the same way regardless of its type -
    # avoids the ambiguous cross-type comparison ($intValue -eq '') that
    # PowerShell does not always resolve the way you'd expect.
    $isBlank = { param($v) ($null -eq $v) -or ($v -is [string] -and $v -eq '') }

    # Determine each column's consistent type (if any) across every row.
    $qualifyingTypes = @([int], [int32], [int64], [double], [decimal], [datetime])
    $colType = @{}
    foreach ($col in $cols) {
        $vals = @($list | ForEach-Object { $_.$col } | Where-Object { -not (& $isBlank $_) })
        if ($vals.Count -eq 0) {
            $colType[$col] = $null
            continue
        }
        $types = @($vals | ForEach-Object { $_.GetType() } | Select-Object -Unique)
        if ($types.Count -eq 1 -and ($qualifyingTypes -contains $types[0])) {
            $colType[$col] = $types[0]
        } else {
            $colType[$col] = $null
        }
    }

    foreach ($col in $cols) {
        $c            = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
        $c.HeaderText = $col
        $c.Name       = $col
        $c.SortMode   = 'Automatic'
        $t = $colType[$col]
        if ($t) {
            $c.ValueType = $t
            if ($t -eq [datetime]) { $c.DefaultCellStyle.Format = $DateFormat }
        }
        $Grid.Columns.Add($c) | Out-Null
    }

    foreach ($item in $list) {
        $rowIdx  = $Grid.Rows.Add()
        $gridRow = $Grid.Rows[$rowIdx]
        foreach ($col in $cols) {
            $v = $item.$col
            $t = $colType[$col]
            if (& $isBlank $v) {
                $gridRow.Cells[$col].Value = $null
            } elseif ($t) {
                $gridRow.Cells[$col].Value = $v
            } else {
                $gridRow.Cells[$col].Value = [string]$v
            }
        }
    }
    $Grid.ResumeLayout()
}
#endregion

#region -- Get-GridRowsAsObjects -----------------------------------------------
function Get-GridRowsAsObjects {
    <#
    .SYNOPSIS
        Extracts every row of a DataGridView into a list of PSCustomObjects,
        one property per column, using the grid's OWN current column names -
        no hardcoded property list required. For HTML/CSV export buttons that
        just need "whatever is currently on screen" rather than a fresh query
        (the grid already reflects the query result, filters, and formatting
        applied when it was populated via Set-GridData).
        Generalizes the pattern already used ad hoc by
        ADInfrastructure.PrivAudit.Query's Get-PrivAuditGridData (which
        hardcodes its 7 column names) - new call sites should prefer this
        function over writing another hardcoded extractor.
    .PARAMETER Grid
        The populated DataGridView to read from.
    .OUTPUTS
        [System.Collections.Generic.List[PSCustomObject]] - empty (not $null)
        if the grid is $null or has no rows, so callers can safely check
        .Count without a separate null guard.
    .NOTES
        Reads FormattedValue, not Value - a column typed as [datetime] with
        a display Format (see Set-GridData) would otherwise export the raw
        DateTime's full culture-default ToString() (e.g. a timestamp with
        time-of-day) instead of the clean date the grid actually shows.
        FormattedValue applies the column's Format the same way the grid's
        own rendering does, so an HTML/CSV export always matches what's on
        screen.
    #>
    param([System.Windows.Forms.DataGridView]$Grid)

    $data = [System.Collections.Generic.List[PSCustomObject]]::new()
    if (-not $Grid -or $Grid.Columns.Count -eq 0) { return $data }

    $colNames = @($Grid.Columns | ForEach-Object { $_.Name })
    foreach ($row in $Grid.Rows) {
        $obj = [ordered]@{}
        foreach ($col in $colNames) { $obj[$col] = $row.Cells[$col].FormattedValue }
        $data.Add([PSCustomObject]$obj)
    }
    return $data
}
#endregion

#region -- Set-Placeholder ----------------------------------------------------
function Set-Placeholder {
    param([System.Windows.Forms.TextBox]$TextBox, [string]$Text)

    $C_PLACEHOLDER = [System.Drawing.SystemColors]::GrayText
    $C_NORMAL      = [System.Drawing.SystemColors]::WindowText

    $TextBox.Text      = $Text
    $TextBox.ForeColor = $C_PLACEHOLDER

    $TextBox.Add_Enter(({
        if ($this.ForeColor -eq $C_PLACEHOLDER -and $this.Text -eq $Text) {
            $this.Text      = ''
            $this.ForeColor = $C_NORMAL
        }
    }).GetNewClosure())

    $TextBox.Add_Leave(({
        if ($this.Text -eq '') {
            $this.Text      = $Text
            $this.ForeColor = $C_PLACEHOLDER
        }
    }).GetNewClosure())
}

function Get-PlaceholderValue {
    param([System.Windows.Forms.TextBox]$TextBox)
    if ($TextBox.ForeColor -eq [System.Drawing.SystemColors]::GrayText) { return '' }
    return $TextBox.Text
}
#endregion

Export-ModuleMember -Function `
    Export-ToCSV, `
    Export-ToHTML, `
    Show-ExportResult, `
    Confirm-Action, `
    New-SectionPanel, `
    New-StdButton, `
    New-StdGrid, `
    Set-GridData, `
    Get-GridRowsAsObjects, `
    Set-Placeholder, `
    Get-PlaceholderValue
