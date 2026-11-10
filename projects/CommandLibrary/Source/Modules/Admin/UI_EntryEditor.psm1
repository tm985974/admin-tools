# UI_EntryEditor.psm1   (ADMIN TIER)
#
#   $saved = Show-LibraryEntryEditor -App $App -Entry $entry -Categories $cats -Owner $form
#
# Edit (or create) one library entry: its description, how to use it, where to
# run it, and its code. Paste a function from a chat into Code and click
# Analyze: the function list, parameters, required modules and the "changes
# things" hint are read from the code (same checks as the Import tab).
# Returns the edited entry (ordered hashtable) or $null on Cancel. The caller
# saves it (Save-LibraryEntry).

function Show-LibraryEntryEditor {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $App, [Parameter(Mandatory)] $Entry, [string[]]$Categories = @(), $Owner = $null)

    # command (syntax template) entries have their own editor
    if (Test-LibraryCommandEntry $Entry) { return Show-LibraryCommandEditor -App $App -Entry $Entry -Categories $Categories -Owner $Owner }

    $e = ConvertTo-LibraryEntry $Entry
    $isNew = -not [string]$e.Code
    $d = @{ App = $App; Entry = $e; Result = $null; OrigCode = [string]$e.Code; Candidates = @() }

    $f = New-Object System.Windows.Forms.Form
    $f.Text = $(if ($isNew) { 'New library entry' } else { "Edit - $($e.Name)" })
    $f.StartPosition = 'CenterParent'; $f.ShowInTaskbar = $false; $f.MinimizeBox = $false
    $f.Font = New-AppFont -App $App; $f.BackColor = $App.Theme.Surface
    $f.Size = New-Object System.Drawing.Size(1380, 860); $f.MinimumSize = New-Object System.Drawing.Size(1000, 640)
    $d.Form = $f

    $split = New-Object System.Windows.Forms.SplitContainer
    $split.Dock = 'Fill'; $split.Orientation = 'Vertical'; $split.SplitterWidth = 6

    # ---- left: fields
    $tl = New-Object System.Windows.Forms.TableLayoutPanel
    $tl.Dock = 'Fill'; $tl.ColumnCount = 2; $tl.Padding = New-Object System.Windows.Forms.Padding(10, 10, 6, 6); $tl.AutoScroll = $true
    [void]$tl.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Absolute', 120)))
    [void]$tl.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent', 100)))
    $script:edRow = 0
    $addRow = {
        param([string]$label, $ctl, [int]$height = 0)
        $l = New-Object System.Windows.Forms.Label
        $l.Text = $label; $l.AutoSize = $true; $l.Margin = New-Object System.Windows.Forms.Padding(0, 7, 6, 3)
        $ctl.Dock = 'Fill'; $ctl.Margin = New-Object System.Windows.Forms.Padding(0, 3, 0, 3)
        $tl.RowCount = $script:edRow + 1
        if ($height -gt 0) { [void]$tl.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute', $height))) }
        else { [void]$tl.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('AutoSize'))) }
        $tl.Controls.Add($l, 0, $script:edRow); $tl.Controls.Add($ctl, 1, $script:edRow)
        $script:edRow++
    }
    function New-EdText([string]$text, [int]$lines = 1) {
        $t = New-Object System.Windows.Forms.TextBox
        $t.Text = ([string]$text) -replace '(?<!\r)\n', "`r`n"
        if ($lines -gt 1) { $t.Multiline = $true; $t.ScrollBars = 'Vertical'; $t.AcceptsReturn = $true }
        return $t
    }

    $tName = New-EdText $e.Name
    $cCat = New-Object System.Windows.Forms.ComboBox
    $cCat.DropDownStyle = 'DropDown'
    foreach ($c in ($Categories | Where-Object { $_ } | Sort-Object -Unique)) { [void]$cCat.Items.Add($c) }
    $cCat.Text = $e.Category
    $tTags = New-EdText ((@($e.Tags)) -join ', ')
    $cFn = New-Object System.Windows.Forms.ComboBox
    $cFn.DropDownStyle = 'DropDownList'
    $tWhere = New-EdText $e.WhereToRun 2
    $tReq = New-EdText $e.Requirements 2
    $tMods = New-EdText ((@($e.Modules)) -join ', ')
    $flags = New-Object System.Windows.Forms.FlowLayoutPanel
    $flags.AutoSize = $true; $flags.WrapContents = $true
    $chkMod = New-Object System.Windows.Forms.CheckBox
    $chkMod.Text = 'Changes things (asks before running)'; $chkMod.AutoSize = $true; $chkMod.Checked = [bool]$e.Modifies
    $chkRem = New-Object System.Windows.Forms.CheckBox
    $chkRem.Text = 'Can run on remote computers'; $chkRem.AutoSize = $true; $chkRem.Checked = [bool]$e.RemoteCapable
    $flags.Controls.AddRange(@($chkMod, $chkRem))
    $tDesc = New-EdText $e.Description 4
    $tHow = New-EdText $e.HowToUse 5
    $tNotes = New-EdText $e.Notes 3
    $lblSrc = New-Object System.Windows.Forms.Label
    $lblSrc.AutoSize = $true; $lblSrc.ForeColor = $App.Theme.Muted
    $lblSrc.Text = $(switch ($e.Source.Kind) {
        'Project' { "Imported from $($e.Source.Project) $($e.Source.Version), $($e.Source.File) ($($e.Source.Imported))" }
        'Chat' { 'From a past chat' }
        default { 'Added by hand' }
    }) + "   |   revision $($e.Revision)"

    & $addRow 'Name' $tName
    & $addRow 'Category' $cCat
    & $addRow 'Tags' $tTags
    & $addRow 'Function' $cFn
    & $addRow 'Description' $tDesc 92
    & $addRow 'How to use' $tHow 112
    & $addRow 'Where to run' $tWhere 52
    & $addRow 'Requirements' $tReq 52
    & $addRow 'Modules' $tMods
    & $addRow '' $flags
    & $addRow 'Notes' $tNotes 72
    & $addRow 'Source' $lblSrc
    $split.Panel1.Controls.Add($tl)

    # ---- right: code + analysis
    $codeHead = New-Object System.Windows.Forms.Panel
    $codeHead.Dock = 'Top'; $codeHead.Height = 40
    $lc = New-Object System.Windows.Forms.Label
    $lc.Text = 'Code - the function (and any helpers it calls). Paste from a chat, then Analyze.'; $lc.AutoSize = $true; $lc.Location = New-Object System.Drawing.Point(4, 12)
    $btnAn = $App.Theme.MakeButton('Analyze'); $btnAn.Anchor = 'Top,Right'
    $btnHelp = $App.Theme.MakeButton('Fill from help'); $btnHelp.Anchor = 'Top,Right'
    $codeHead.Controls.AddRange(@($lc, $btnAn, $btnHelp))
    $tCode = New-Object System.Windows.Forms.TextBox
    $tCode.Dock = 'Fill'; $tCode.Multiline = $true; $tCode.ScrollBars = 'Both'; $tCode.WordWrap = $false; $tCode.AcceptsTab = $true; $tCode.AcceptsReturn = $true
    $tCode.Font = New-LibraryMonoFont -App $App; $tCode.MaxLength = 0
    $tCode.Text = ([string]$e.Code) -replace '(?<!\r)\n', "`r`n"
    $tAn = New-Object System.Windows.Forms.TextBox
    $tAn.Dock = 'Bottom'; $tAn.Height = 200; $tAn.Multiline = $true; $tAn.ReadOnly = $true; $tAn.ScrollBars = 'Vertical'
    $tAn.Font = New-LibraryMonoFont -App $App -Size 9; $tAn.BackColor = [System.Drawing.Color]::White
    $split.Panel2.Controls.Add($tCode)
    $split.Panel2.Controls.Add($tAn)
    $split.Panel2.Controls.Add($codeHead)
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

    $d.Name = $tName; $d.Cat = $cCat; $d.Tags = $tTags; $d.Fn = $cFn; $d.Where = $tWhere; $d.Req = $tReq; $d.Mods = $tMods
    $d.Modifies = $chkMod; $d.Remote = $chkRem; $d.Desc = $tDesc; $d.How = $tHow; $d.Notes = $tNotes
    $d.Code = $tCode; $d.Analysis = $tAn; $d.Msg = $lblMsg

    $bar.Add_Resize({
        $btnCancel.Location = New-Object System.Drawing.Point(($bar.ClientSize.Width - $btnCancel.Width - 12), 9)
        $btnSave.Location = New-Object System.Drawing.Point(($btnCancel.Left - $btnSave.Width - 8), 9)
    }.GetNewClosure())
    $codeHead.Add_Resize({
        $btnAn.Location = New-Object System.Drawing.Point(($codeHead.ClientSize.Width - $btnAn.Width - 2), 4)
        $btnHelp.Location = New-Object System.Drawing.Point(($btnAn.Left - $btnHelp.Width - 6), 4)
    }.GetNewClosure())

    $btnAn.Add_Click({ Invoke-EntryEditorAnalyze -Dialog $d -Suggest }.GetNewClosure())
    $cFn.Add_SelectedIndexChanged({ Show-EntryEditorAnalysis -Dialog $d }.GetNewClosure())
    $btnHelp.Add_Click({
        Invoke-EntryEditorAnalyze -Dialog $d
        $fn = [string]$d.Fn.SelectedItem
        if (-not $fn) { return }
        $h = Get-LibraryFunctionHelp -Code $d.Code.Text -Function $fn
        if (-not $d.Desc.Text.Trim()) { $d.Desc.Text = ((@($h.Synopsis, $h.Description) | Where-Object { $_ } | Select-Object -Unique) -join "`r`n`r`n") -replace '(?<!\r)\n', "`r`n" }
        if (-not $d.How.Text.Trim() -and @($h.Examples).Count) { $d.How.Text = (@($h.Examples) -join "`r`n`r`n") -replace '(?<!\r)\n', "`r`n" }
        if (-not $d.Notes.Text.Trim() -and $h.Notes) { $d.Notes.Text = ([string]$h.Notes) -replace '(?<!\r)\n', "`r`n" }
        if (-not $d.Name.Text.Trim()) { $d.Name.Text = $fn }
    }.GetNewClosure())

    $btnSave.Add_Click({
        $d.Msg.Text = ''
        $code = [string]$d.Code.Text
        $info = Get-LibraryCodeInfo -Code $code
        if (-not $code.Trim()) { $d.Msg.Text = 'Paste the function into Code first.'; return }
        if ($info.Errors.Count) { $d.Msg.Text = "Code has a parse error: $($info.Errors[0].Message) (line $($info.Errors[0].Extent.StartLineNumber))"; return }
        if ($info.Functions.Count -eq 0) { $d.Msg.Text = 'The code must define at least one function (function Verb-Noun { ... }).'; return }
        if (-not $d.Fn.SelectedItem -or -not ($info.Functions -contains [string]$d.Fn.SelectedItem)) { Invoke-EntryEditorAnalyze -Dialog $d }
        $fn = [string]$d.Fn.SelectedItem
        if (-not $fn) { $d.Msg.Text = 'Pick the function to run.'; return }
        $cand = @($d.Candidates | Where-Object { $_.Function -eq $fn }) | Select-Object -First 1
        if ($cand -and $cand.Status -eq 'Blocked') {
            $r = [System.Windows.Forms.MessageBox]::Show($d.Form, "'$fn' cannot run standalone:`r`n`r`n$((@($cand.Blockers) | ForEach-Object { "- $_" }) -join "`r`n")`r`n`r`nSave anyway?", 'Save entry', 'YesNo', 'Warning')   # not-a-command: library edit
            if ($r -ne 'Yes') { return }
        }
        $x = $d.Entry
        $x.Name = $(if ($d.Name.Text.Trim()) { $d.Name.Text.Trim() } else { $fn })
        $x.Category = $(if ($d.Cat.Text.Trim()) { $d.Cat.Text.Trim() } else { 'General' })
        $x.Tags = @(Split-LibraryList $d.Tags.Text)
        $x.Function = $fn
        $x.Description = $d.Desc.Text.Trim(); $x.HowToUse = $d.How.Text.Trim(); $x.WhereToRun = $d.Where.Text.Trim()
        $x.Requirements = $d.Req.Text.Trim(); $x.Notes = $d.Notes.Text.Trim()
        $x.Modules = @(Split-LibraryList $d.Mods.Text)
        $x.Modifies = $d.Modifies.Checked; $x.RemoteCapable = $d.Remote.Checked
        $newCode = $code -replace "`r`n", "`n"
        if ($newCode.TrimEnd() -ne ($d.OrigCode -replace "`r`n", "`n").TrimEnd()) {
            $x.Code = $newCode
            if ($d.OrigCode) { $x.Revision = [int]$x.Revision + 1 }
        }
        $x.Edited = $true
        $d.Result = $x
        $d.Form.DialogResult = 'OK'; $d.Form.Close()
    }.GetNewClosure())

    $f.Add_Shown({
        try { $split.SplitterDistance = [int]($split.ClientSize.Width * 0.42) } catch { }
        Invoke-EntryEditorAnalyze -Dialog $d -Select $d.Entry.Function
        if (-not $d.Code.Text) { [void]$d.Code.Focus() }
    }.GetNewClosure())

    [void]$(if ($Owner) { $f.ShowDialog($Owner) } else { $f.ShowDialog() })
    $res = $d.Result
    $f.Dispose()
    return $res
}

function Invoke-EntryEditorAnalyze {
    param($Dialog, [string]$Select = '', [switch]$Suggest)
    $code = [string]$Dialog.Code.Text
    $Dialog.Candidates = @()
    $Dialog.Fn.Items.Clear()
    if (-not $code.Trim()) { $Dialog.Analysis.Text = 'No code yet.'; return }
    $info = Get-LibraryCodeInfo -Code $code
    if ($info.Errors.Count) {
        $Dialog.Analysis.Text = "Parse error: $($info.Errors[0].Message) (line $($info.Errors[0].Extent.StartLineNumber))"
        return
    }
    if (Get-Command Get-ExtractorCandidatesFromCode -ErrorAction SilentlyContinue) {
        $Dialog.Candidates = @(Get-ExtractorCandidatesFromCode -Code $code -Label 'Code')
    }
    foreach ($n in $info.Functions) { [void]$Dialog.Fn.Items.Add($n) }
    $pick = $Select
    if (-not $pick -or -not ($info.Functions -contains $pick)) {
        $cur = [string]$Dialog.Entry.Function
        if ($cur -and ($info.Functions -contains $cur)) { $pick = $cur }
        else {
            # the function no other function calls is usually the entry point (helpers come first)
            $called = @{}
            foreach ($c in $Dialog.Candidates) { foreach ($h in $c.Helpers) { $called[$h.ToLower()] = $true } }
            $tops = @($info.Functions | Where-Object { -not $called.ContainsKey($_.ToLower()) })
            $pick = $(if ($tops.Count) { $tops[-1] } elseif ($info.Functions.Count) { $info.Functions[-1] } else { '' })
        }
    }
    if ($pick) { $Dialog.Fn.SelectedItem = $pick }
    Show-EntryEditorAnalysis -Dialog $Dialog
    if ($Suggest) {
        $c = @($Dialog.Candidates | Where-Object { $_.Function -eq $pick }) | Select-Object -First 1
        if ($c) {
            if (-not $Dialog.Mods.Text.Trim() -and @($c.Modules).Count) { $Dialog.Mods.Text = (@($c.Modules) -join ', ') }
            if ($c.SuggestModifies) { $Dialog.Modifies.Checked = $true }
            if (-not $Dialog.Req.Text.Trim()) {
                $req = @()
                if (@($c.Modules).Count) { $req += 'Modules: ' + (@($c.Modules) -join ', ') }
                if (@($c.Tools).Count) { $req += 'Tools: ' + (@($c.Tools) -join ', ') }
                $Dialog.Req.Text = $req -join "`r`n"
            }
            if (-not $Dialog.Name.Text.Trim()) { $Dialog.Name.Text = $pick }
        }
    }
}

function Show-EntryEditorAnalysis {
    param($Dialog)
    $fn = [string]$Dialog.Fn.SelectedItem
    if (-not $fn) { return }
    $c = @($Dialog.Candidates | Where-Object { $_.Function -eq $fn }) | Select-Object -First 1
    if ($c) {
        $txt = Format-ExtractorCandidate -Candidate $c
        # helpers are bundled when imported from a project; here they must be in the pasted code
        $Dialog.Analysis.Text = $txt -replace '(?<!\r)\n', "`r`n"
    }
    else {
        $ps = @(Get-LibraryParameterInfo -Code $Dialog.Code.Text -Function $fn)
        $Dialog.Analysis.Text = "$fn - $($ps.Count) parameter(s): $((@($ps | ForEach-Object { $_.Name })) -join ', ')"
    }
}
