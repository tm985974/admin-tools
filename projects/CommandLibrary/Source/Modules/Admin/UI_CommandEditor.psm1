# UI_CommandEditor.psm1   (ADMIN TIER)
#
#   $saved = Show-LibraryCommandEditor -App $App -Entry $entry -Categories $cats -Owner $form
#
# Edit (or create) a Command entry - a syntax template:
#   Template  the command line, with {Field} where a value goes and [[ ... ]]
#             around parts that are only used when their field is filled in
#             (or ticked, for a switch). Several lines are fine.
#   Fields    a param() block declaring each field: [string], [int], [switch],
#             [string[]] (one per line), [pscredential], [ValidateSet(...)],
#             [Parameter(Mandatory)], a default value, and comment help
#             (.PARAMETER Name) above it for the hint shown in the Run dialog.
# "Add missing fields" declares any {Field} the template uses as [string].
# The preview fills the template with the defaults. Returns the edited entry
# or $null on Cancel; the caller saves it.

function Show-LibraryCommandEditor {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $App, [Parameter(Mandatory)] $Entry, [string[]]$Categories = @(), $Owner = $null)

    $e = ConvertTo-LibraryEntry $Entry
    $e.Kind = 'Command'
    $isNew = -not ([string]$e.Template).Trim()
    $d = @{ App = $App; Entry = $e; Result = $null; OrigText = ([string]$e.Template + "`n" + [string]$e.Code) -replace "`r`n", "`n" }

    $f = New-Object System.Windows.Forms.Form
    $f.Text = $(if ($isNew) { 'New command (syntax template)' } else { "Edit command - $($e.Name)" })
    $f.StartPosition = 'CenterParent'; $f.ShowInTaskbar = $false; $f.MinimizeBox = $false
    $f.Font = New-AppFont -App $App; $f.BackColor = $App.Theme.Surface
    $f.Size = New-Object System.Drawing.Size(1380, 880); $f.MinimumSize = New-Object System.Drawing.Size(1000, 640)
    $d.Form = $f

    $split = New-Object System.Windows.Forms.SplitContainer
    $split.Dock = 'Fill'; $split.Orientation = 'Vertical'; $split.SplitterWidth = 6

    # ---- left: descriptive fields
    $tl = New-Object System.Windows.Forms.TableLayoutPanel
    $tl.Dock = 'Fill'; $tl.ColumnCount = 2; $tl.Padding = New-Object System.Windows.Forms.Padding(10, 10, 6, 6); $tl.AutoScroll = $true
    [void]$tl.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Absolute', 120)))
    [void]$tl.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent', 100)))
    $rowRef = @{ N = 0 }
    $addRow = {
        param([string]$label, $ctl, [int]$height = 0)
        $l = New-Object System.Windows.Forms.Label
        $l.Text = $label; $l.AutoSize = $true; $l.Margin = New-Object System.Windows.Forms.Padding(0, 7, 6, 3)
        $ctl.Dock = 'Fill'; $ctl.Margin = New-Object System.Windows.Forms.Padding(0, 3, 0, 3)
        $tl.RowCount = $rowRef.N + 1
        if ($height -gt 0) { [void]$tl.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute', $height))) }
        else { [void]$tl.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('AutoSize'))) }
        $tl.Controls.Add($l, 0, $rowRef.N); $tl.Controls.Add($ctl, 1, $rowRef.N)
        $rowRef.N++
    }
    $newText = {
        param([string]$text, [int]$lines = 1)
        $t = New-Object System.Windows.Forms.TextBox
        $t.Text = ([string]$text) -replace '(?<!\r)\n', "`r`n"
        if ($lines -gt 1) { $t.Multiline = $true; $t.ScrollBars = 'Vertical'; $t.AcceptsReturn = $true }
        return $t
    }

    $tName = & $newText $e.Name
    $cCat = New-Object System.Windows.Forms.ComboBox
    $cCat.DropDownStyle = 'DropDown'
    foreach ($c in ($Categories | Where-Object { $_ } | Sort-Object -Unique)) { [void]$cCat.Items.Add($c) }
    $cCat.Text = $e.Category
    $tTags = & $newText ((@($e.Tags)) -join ', ')
    $tCmd = & $newText $e.Function
    $tDesc = & $newText $e.Description 4
    $tHow = & $newText $e.HowToUse 4
    $tWhere = & $newText $e.WhereToRun 2
    $tReq = & $newText $e.Requirements 2
    $tMods = & $newText ((@($e.Modules)) -join ', ')
    $flags = New-Object System.Windows.Forms.FlowLayoutPanel
    $flags.AutoSize = $true; $flags.WrapContents = $true
    $chkMod = New-Object System.Windows.Forms.CheckBox
    $chkMod.Text = 'Changes things (asks before running)'; $chkMod.AutoSize = $true; $chkMod.Checked = [bool]$e.Modifies
    $chkRem = New-Object System.Windows.Forms.CheckBox
    $chkRem.Text = 'Can run on remote computers'; $chkRem.AutoSize = $true; $chkRem.Checked = [bool]$e.RemoteCapable
    $flags.Controls.AddRange(@($chkMod, $chkRem))
    $tNotes = & $newText $e.Notes 3

    & $addRow 'Name' $tName
    & $addRow 'Category' $cCat
    & $addRow 'Tags' $tTags
    & $addRow 'Command' $tCmd
    & $addRow 'Description' $tDesc 92
    & $addRow 'How to use' $tHow 92
    & $addRow 'Where to run' $tWhere 52
    & $addRow 'Requirements' $tReq 52
    & $addRow 'Modules' $tMods
    & $addRow '' $flags
    & $addRow 'Notes' $tNotes 72
    $split.Panel1.Controls.Add($tl)

    # ---- right: template, fields, preview
    $right = New-Object System.Windows.Forms.TableLayoutPanel
    $right.Dock = 'Fill'; $right.ColumnCount = 1; $right.RowCount = 6
    [void]$right.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute', 26)))
    [void]$right.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Percent', 32)))
    [void]$right.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute', 36)))
    [void]$right.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Percent', 43)))
    [void]$right.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute', 26)))
    [void]$right.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Percent', 25)))
    $mono = New-LibraryMonoFont -App $App
    $l1 = New-Object System.Windows.Forms.Label
    $l1.Text = 'Template - {Field} for a value, [[ ... ]] around a part used only when its fields are filled in / ticked'; $l1.AutoSize = $true; $l1.Margin = New-Object System.Windows.Forms.Padding(0, 6, 0, 0)
    $tTpl = New-Object System.Windows.Forms.TextBox
    $tTpl.Dock = 'Fill'; $tTpl.Multiline = $true; $tTpl.ScrollBars = 'Both'; $tTpl.WordWrap = $false; $tTpl.AcceptsReturn = $true; $tTpl.Font = $mono
    $tTpl.Text = ([string]$e.Template) -replace '(?<!\r)\n', "`r`n"
    $fieldsHead = New-Object System.Windows.Forms.Panel
    $fieldsHead.Dock = 'Fill'
    $l2 = New-Object System.Windows.Forms.Label
    $l2.Text = 'Fields - a param() block (types, ValidateSet, Mandatory, defaults; .PARAMETER help above it)'; $l2.AutoSize = $true; $l2.Location = New-Object System.Drawing.Point(0, 12)
    $btnAdd = $App.Theme.MakeButton('Add missing fields'); $btnAdd.Anchor = 'Top,Right'
    $fieldsHead.Controls.AddRange(@($l2, $btnAdd))
    $tFields = New-Object System.Windows.Forms.TextBox
    $tFields.Dock = 'Fill'; $tFields.Multiline = $true; $tFields.ScrollBars = 'Both'; $tFields.WordWrap = $false; $tFields.AcceptsReturn = $true; $tFields.AcceptsTab = $true; $tFields.Font = $mono
    $tFields.Text = $(if (([string]$e.Code).Trim()) { [string]$e.Code } else { "param(`n)" }) -replace '(?<!\r)\n', "`r`n"
    $l3 = New-Object System.Windows.Forms.Label
    $l3.Text = 'Preview (filled with the defaults)'; $l3.AutoSize = $true; $l3.Margin = New-Object System.Windows.Forms.Padding(0, 6, 0, 0)
    $tPrev = New-Object System.Windows.Forms.TextBox
    $tPrev.Dock = 'Fill'; $tPrev.Multiline = $true; $tPrev.ReadOnly = $true; $tPrev.ScrollBars = 'Vertical'; $tPrev.Font = $mono; $tPrev.BackColor = [System.Drawing.Color]::White
    $right.Controls.Add($l1, 0, 0); $right.Controls.Add($tTpl, 0, 1); $right.Controls.Add($fieldsHead, 0, 2)
    $right.Controls.Add($tFields, 0, 3); $right.Controls.Add($l3, 0, 4); $right.Controls.Add($tPrev, 0, 5)
    $split.Panel2.Controls.Add($right)
    $split.Panel2.Padding = New-Object System.Windows.Forms.Padding(4, 6, 10, 6)

    # ---- bottom buttons
    $bar = New-Object System.Windows.Forms.Panel
    $bar.Dock = 'Bottom'; $bar.Height = 48
    $btnSave = $App.Theme.MakeButton('Save'); $btnSave.Anchor = 'Top,Right'
    $btnCancel = $App.Theme.MakeButton('Cancel'); $btnCancel.Anchor = 'Top,Right'; $btnCancel.DialogResult = 'Cancel'
    $lblMsg = New-Object System.Windows.Forms.Label
    $lblMsg.AutoSize = $true; $lblMsg.Location = New-Object System.Drawing.Point(12, 17); $lblMsg.ForeColor = [System.Drawing.Color]::Firebrick
    $bar.Controls.AddRange(@($lblMsg, $btnSave, $btnCancel))

    $f.Controls.Add($split)
    $f.Controls.Add($bar)
    $f.CancelButton = $btnCancel

    $d.Name = $tName; $d.Cat = $cCat; $d.Tags = $tTags; $d.Cmd = $tCmd; $d.Desc = $tDesc; $d.How = $tHow; $d.Where = $tWhere
    $d.Req = $tReq; $d.Mods = $tMods; $d.Modifies = $chkMod; $d.Remote = $chkRem; $d.Notes = $tNotes
    $d.Tpl = $tTpl; $d.Fields = $tFields; $d.Prev = $tPrev; $d.Msg = $lblMsg

    $bar.Add_Resize({
        $btnCancel.Location = New-Object System.Drawing.Point(($bar.ClientSize.Width - $btnCancel.Width - 12), 9)
        $btnSave.Location = New-Object System.Drawing.Point(($btnCancel.Left - $btnSave.Width - 8), 9)
    }.GetNewClosure())
    $fieldsHead.Add_Resize({ $btnAdd.Location = New-Object System.Drawing.Point(($fieldsHead.ClientSize.Width - $btnAdd.Width - 2), 4) }.GetNewClosure())

    $refresh = { Update-CommandEditorPreview -Dialog $d }.GetNewClosure()
    $tTpl.Add_TextChanged($refresh)
    $tFields.Add_TextChanged($refresh)
    $btnAdd.Add_Click({
        $d.Fields.Text = (Add-CommandEditorMissingFields -Template $d.Tpl.Text -Fields $d.Fields.Text) -replace '(?<!\r)\n', "`r`n"
    }.GetNewClosure())

    $btnSave.Add_Click({
        $d.Msg.Text = ''
        $x = $d.Entry
        $x.Template = ($d.Tpl.Text -replace "`r`n", "`n").TrimEnd()
        $x.Code = ($d.Fields.Text -replace "`r`n", "`n").TrimEnd()
        if (-not $x.Template.Trim()) { $d.Msg.Text = 'Write the command in Template first.'; return }
        $why = Test-LibraryEntryRunnable -Entry $x
        if ($why) { $d.Msg.Text = $why; return }
        $cmd = $d.Cmd.Text.Trim()
        if (-not $cmd) { $cmd = (($x.Template.Trim() -split '\s+')[0]) -replace '[\{\[].*$', '' }
        $x.Function = $cmd
        $x.Name = $(if ($d.Name.Text.Trim()) { $d.Name.Text.Trim() } else { $cmd })
        $x.Category = $(if ($d.Cat.Text.Trim()) { $d.Cat.Text.Trim() } else { 'General' })
        $x.Tags = @(Split-LibraryList $d.Tags.Text)
        $x.Description = $d.Desc.Text.Trim(); $x.HowToUse = $d.How.Text.Trim(); $x.WhereToRun = $d.Where.Text.Trim()
        $x.Requirements = $d.Req.Text.Trim(); $x.Notes = $d.Notes.Text.Trim()
        $x.Modules = @(Split-LibraryList $d.Mods.Text)
        $x.Modifies = $d.Modifies.Checked; $x.RemoteCapable = $d.Remote.Checked
        $now = ($x.Template + "`n" + $x.Code)
        if ($d.OrigText.Trim() -and $now.TrimEnd() -ne $d.OrigText.TrimEnd()) { $x.Revision = [int]$x.Revision + 1 }
        $x.Edited = $true
        $d.Result = $x
        $d.Form.DialogResult = 'OK'; $d.Form.Close()
    }.GetNewClosure())

    $f.Add_Shown({
        try { $split.SplitterDistance = [int]($split.ClientSize.Width * 0.40) } catch { }
        Update-CommandEditorPreview -Dialog $d
        if (-not $d.Tpl.Text) { [void]$d.Tpl.Focus() }
    }.GetNewClosure())

    [void]$(if ($Owner) { $f.ShowDialog($Owner) } else { $f.ShowDialog() })
    $res = $d.Result
    $f.Dispose()
    return $res
}

# Declares every {Field} the template uses that the param block does not.
function Add-CommandEditorMissingFields {
    param([AllowEmptyString()] [string]$Template, [AllowEmptyString()] [string]$Fields)
    $text = ([string]$Fields) -replace "`r`n", "`n"
    if (-not $text.Trim()) { $text = "param(`n)" }
    $have = @(Get-LibraryParameterInfo -Code (Get-LibraryCommandWrapper $text) -Function '__LibraryCommand' | ForEach-Object { $_.Name })
    $add = @(Get-LibraryTemplateFields $Template | Where-Object { $have -notcontains $_ })
    if (-not $add.Count) { return $text }
    $i = $text.LastIndexOf(')')
    if ($i -lt 0) { return $text }
    $before = $text.Substring(0, $i).TrimEnd()
    $sep = if ($before -match '\(\s*$') { "`n" } else { ",`n" }
    $lines = @($add | ForEach-Object { "    [string]`$$_" }) -join ",`n"
    return $before + $sep + $lines + "`n" + $text.Substring($i)
}

function Update-CommandEditorPreview {
    param($Dialog)
    $x = [pscustomobject]@{ Kind = 'Command'; Template = $Dialog.Tpl.Text; Code = $Dialog.Fields.Text; Function = ''; Name = '' }
    $why = Test-LibraryEntryRunnable -Entry $x
    if ($why) { $Dialog.Prev.Text = $why; return }
    $ps = @(Get-LibraryEntryParameters -Entry $x)
    $ex = Get-LibraryExampleCall -Entry $x
    $Dialog.Prev.Text = ($ex + "`r`n`r`nFields: " + ((@($ps | ForEach-Object { "$($_.Name) [$($_.Kind)]$(if ($_.Mandatory) { ' required' })" })) -join ', ')) -replace '(?<!\r)\n', "`r`n"
}
