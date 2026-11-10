# UI_Tab_Import.psm1   (ADMIN TIER)
#
# Import functions from another project into the library.
#   1. Pick a source: a project zip (an Extract or Archive\Zip\*.zip), a project
#      folder, or one or more .psm1/.ps1 files. Click Scan. Nothing is run.
#   2. Every top-level function is listed with its status:
#        Ready   - runs on its own (helpers it calls are bundled with it)
#        Review  - probably runs; read the notes first
#        Blocked - cannot run outside its project (UI, $App, module state,
#                  launches a .ps1 ...); cannot be checked
#      and how it compares with the library: New, Same, Changed, Name exists.
#   3. Check the ones you want, pick a category, and Add checked. "Update
#      changed" refreshes the code of entries whose source has changed, keeping
#      your descriptions.

function New-ImportTab {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Windows.Forms.TabPage]$Page,
        [Parameter(Mandatory)] $App
    )
    Set-LazyTabBuild -Page $Page -App $App -Build { param($Page, $App) Build-ImportTab -Page $Page -App $App }
}

function Build-ImportTab {
    param([System.Windows.Forms.TabPage]$Page, $App)
    $st = @{ App = $App; Page = $Page; Source = $null; Candidates = @(); Paths = @() }

    # ---- top
    $top = New-Object System.Windows.Forms.Panel
    $top.Dock = 'Top'; $top.Height = 78
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = 'Source'; $lbl.AutoSize = $true; $lbl.Location = New-Object System.Drawing.Point(8, 13)
    $txtPath = New-Object System.Windows.Forms.TextBox
    $txtPath.Location = New-Object System.Drawing.Point(64, 9); $txtPath.Width = 620
    $btnZip = $App.Theme.MakeButton('Zip...'); $btnZip.Location = New-Object System.Drawing.Point(694, 6)
    $btnFolder = $App.Theme.MakeButton('Folder...'); $btnFolder.Location = New-Object System.Drawing.Point(($btnZip.Right + 6), 6)
    $btnFiles = $App.Theme.MakeButton('Files...'); $btnFiles.Location = New-Object System.Drawing.Point(($btnFolder.Right + 6), 6)
    $btnScan = $App.Theme.MakeButton('Scan'); $btnScan.Location = New-Object System.Drawing.Point(($btnFiles.Right + 14), 6)
    $chkTpl = New-Object System.Windows.Forms.CheckBox
    $chkTpl.Text = 'Show template engine functions'; $chkTpl.AutoSize = $true; $chkTpl.Location = New-Object System.Drawing.Point(64, 46)
    $chkBlocked = New-Object System.Windows.Forms.CheckBox
    $chkBlocked.Text = 'Show blocked'; $chkBlocked.AutoSize = $true; $chkBlocked.Checked = $true; $chkBlocked.Location = New-Object System.Drawing.Point(300, 46)
    $lblSum = New-Object System.Windows.Forms.Label
    $lblSum.AutoSize = $true; $lblSum.Location = New-Object System.Drawing.Point(430, 48); $lblSum.ForeColor = $App.Theme.Muted
    $lblSum.Text = 'Pick a project zip, folder or module files, then Scan. Files are only read, never run.'
    $top.Controls.AddRange(@($lbl, $txtPath, $btnZip, $btnFolder, $btnFiles, $btnScan, $chkTpl, $chkBlocked, $lblSum))

    # ---- bottom
    $bottom = New-Object System.Windows.Forms.Panel
    $bottom.Dock = 'Bottom'; $bottom.Height = 48
    $lblCat = New-Object System.Windows.Forms.Label
    $lblCat.Text = 'Category'; $lblCat.AutoSize = $true; $lblCat.Location = New-Object System.Drawing.Point(8, 17)
    $cboCat = New-Object System.Windows.Forms.ComboBox
    $cboCat.DropDownStyle = 'DropDown'; $cboCat.Location = New-Object System.Drawing.Point(74, 13); $cboCat.Width = 240
    $btnReady = $App.Theme.MakeButton('Check all Ready'); $btnReady.Location = New-Object System.Drawing.Point(330, 10)
    $btnNone = $App.Theme.MakeButton('Uncheck all'); $btnNone.Location = New-Object System.Drawing.Point(($btnReady.Right + 6), 10)
    $btnAdd = $App.Theme.MakeButton('Add checked to library'); $btnAdd.Location = New-Object System.Drawing.Point(($btnNone.Right + 20), 10)
    $btnUpd = $App.Theme.MakeButton('Update changed'); $btnUpd.Location = New-Object System.Drawing.Point(($btnAdd.Right + 6), 10)
    $lblRes = New-Object System.Windows.Forms.Label
    $lblRes.AutoSize = $true; $lblRes.Location = New-Object System.Drawing.Point(($btnUpd.Right + 14), 17); $lblRes.ForeColor = $App.Theme.Muted
    $bottom.Controls.AddRange(@($lblCat, $cboCat, $btnReady, $btnNone, $btnAdd, $btnUpd, $lblRes))

    # ---- middle
    $split = New-Object System.Windows.Forms.SplitContainer
    $split.Dock = 'Fill'; $split.Orientation = 'Vertical'; $split.SplitterWidth = 6
    $lv = New-Object System.Windows.Forms.ListView
    $lv.Dock = 'Fill'; $lv.View = 'Details'; $lv.CheckBoxes = $true; $lv.FullRowSelect = $true; $lv.HideSelection = $false; $lv.MultiSelect = $false
    $lv.BorderStyle = 'FixedSingle'
    [void]$lv.Columns.Add('Function', 250)
    [void]$lv.Columns.Add('Status', 80)
    [void]$lv.Columns.Add('Library', 110)
    [void]$lv.Columns.Add('File', 260)
    [void]$lv.Columns.Add('Helpers', 60)
    [void]$lv.Columns.Add('First note', 380)
    $split.Panel1.Controls.Add($lv)

    $tabs = New-Object System.Windows.Forms.TabControl
    $tabs.Dock = 'Fill'
    $pgA = New-Object System.Windows.Forms.TabPage 'Analysis'
    $pgC = New-Object System.Windows.Forms.TabPage 'Code (as it will be saved)'
    $txtA = New-Object System.Windows.Forms.TextBox
    $txtA.Dock = 'Fill'; $txtA.Multiline = $true; $txtA.ReadOnly = $true; $txtA.ScrollBars = 'Both'; $txtA.WordWrap = $true
    $txtA.Font = New-LibraryMonoFont -App $App; $txtA.BackColor = [System.Drawing.Color]::White
    $txtC = New-Object System.Windows.Forms.TextBox
    $txtC.Dock = 'Fill'; $txtC.Multiline = $true; $txtC.ReadOnly = $true; $txtC.ScrollBars = 'Both'; $txtC.WordWrap = $false
    $txtC.Font = New-LibraryMonoFont -App $App; $txtC.BackColor = [System.Drawing.Color]::White; $txtC.MaxLength = 0
    $pgA.Controls.Add($txtA); $pgC.Controls.Add($txtC)
    $tabs.TabPages.AddRange(@($pgA, $pgC))
    $split.Panel2.Controls.Add($tabs)

    $Page.Controls.Add($split)
    $Page.Controls.Add($bottom)
    $Page.Controls.Add($top)
    $setSplit = {
        try { $split.SplitterDistance = [int][Math]::Max(300, $split.ClientSize.Width * 0.6) } catch { }
        try { $split.Panel1MinSize = 300 } catch { }
    }.GetNewClosure()
    & $setSplit
    try { [void]$Page.BeginInvoke([System.Windows.Forms.MethodInvoker]$setSplit) } catch { }

    $st.Path = $txtPath; $st.ShowTemplate = $chkTpl; $st.ShowBlocked = $chkBlocked; $st.Summary = $lblSum
    $st.List = $lv; $st.Analysis = $txtA; $st.CodeBox = $txtC; $st.Category = $cboCat; $st.Result = $lblRes

    # ---- events
    $btnZip.Add_Click({
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Filter = 'Project zip (*.zip)|*.zip'; $dlg.Title = 'Pick a project zip (an Extract, or Archive\Zip\*.zip)'
        if ($dlg.ShowDialog($st.Page.FindForm()) -eq 'OK') { $st.Paths = @($dlg.FileName); $st.Path.Text = $dlg.FileName; Invoke-ImportScan -State $st }
    }.GetNewClosure())
    $btnFolder.Add_Click({
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = 'Pick a project folder (its Modules are scanned)'
        if ($dlg.ShowDialog($st.Page.FindForm()) -eq 'OK') { $st.Paths = @($dlg.SelectedPath); $st.Path.Text = $dlg.SelectedPath; Invoke-ImportScan -State $st }
    }.GetNewClosure())
    $btnFiles.Add_Click({
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Filter = 'PowerShell (*.psm1;*.ps1)|*.psm1;*.ps1'; $dlg.Multiselect = $true; $dlg.Title = 'Pick module or script files'
        if ($dlg.ShowDialog($st.Page.FindForm()) -eq 'OK') { $st.Paths = @($dlg.FileNames); $st.Path.Text = ($dlg.FileNames -join '; '); Invoke-ImportScan -State $st }
    }.GetNewClosure())
    $btnScan.Add_Click({
        $t = $st.Path.Text.Trim()
        if ($t) { $st.Paths = @($t -split ';' | ForEach-Object { $_.Trim().Trim('"') } | Where-Object { $_ }) }
        Invoke-ImportScan -State $st
    }.GetNewClosure())
    $txtPath.Add_KeyDown({ param($s, $e) if ($e.KeyCode -eq 'Enter') { $e.SuppressKeyPress = $true; $btnScan.PerformClick() } }.GetNewClosure())
    $chkTpl.Add_CheckedChanged({ Update-ImportList -State $st }.GetNewClosure())
    $chkBlocked.Add_CheckedChanged({ Update-ImportList -State $st }.GetNewClosure())

    $lv.Add_ItemCheck({
        param($s, $e)
        $c = $st.List.Items[$e.Index].Tag
        if ($e.NewValue -eq 'Checked' -and $c.Status -eq 'Blocked') { $e.NewValue = 'Unchecked' }
    }.GetNewClosure())
    $lv.Add_SelectedIndexChanged({
        if ($st.List.SelectedItems.Count -eq 0) { $st.Analysis.Text = ''; $st.CodeBox.Text = ''; return }
        $c = $st.List.SelectedItems[0].Tag
        $txt = Format-ExtractorCandidate -Candidate $c
        $lib = $st.Library[$c.Function.ToLower()]
        if ($lib) { $txt += "`r`nIn the library: $($lib.Status)$(if ($lib.Entry) { " ('$($lib.Entry.Name)', category $($lib.Entry.Category))" })`r`n" }
        $st.Analysis.Text = $txt -replace "(?<!`r)`n", "`r`n"
        $st.CodeBox.Text = ([string]$c.Code) -replace "(?<!`r)`n", "`r`n"
    }.GetNewClosure())

    $btnReady.Add_Click({ foreach ($it in $st.List.Items) { $it.Checked = ($it.Tag.Status -eq 'Ready' -and $it.SubItems[2].Text -in @('New', 'Name exists')) } }.GetNewClosure())
    $btnNone.Add_Click({ foreach ($it in $st.List.Items) { $it.Checked = $false } }.GetNewClosure())
    $btnAdd.Add_Click({ Invoke-ImportAdd -State $st }.GetNewClosure())
    $btnUpd.Add_Click({ Invoke-ImportUpdate -State $st }.GetNewClosure())
}

function Get-ImportLibraryEntries {
    param($State)
    try { return @((Read-Library -App $State.App).Entries) } catch { return @() }
}

function Invoke-ImportScan {
    param($State)
    if (@($State.Paths).Count -eq 0) { $State.Summary.Text = 'Pick a source first.'; return }
    $frm = $State.Page.FindForm()
    if ($frm) { $frm.Cursor = [System.Windows.Forms.Cursors]::WaitCursor }
    $State.App.SetStatus('Scanning ...', 'info')
    try {
        $src = Read-ExtractorSource -Path $State.Paths
        $State.Source = $src
        $State.Candidates = @(Get-ExtractorCandidates -Source $src)
        $State.App.Log('INFO', 'Import', "Scanned $($src.Project) $($src.Version): $(@($src.Files).Count) file(s), $($State.Candidates.Count) function(s).")
        $cats = @(Get-ImportLibraryEntries -State $State | ForEach-Object { $_.Category } | Where-Object { $_ } | Sort-Object -Unique)
        $State.Category.Items.Clear()
        foreach ($c in (@($src.Project) + $cats | Where-Object { $_ } | Select-Object -Unique)) { [void]$State.Category.Items.Add($c) }
        $State.Category.Text = [string]$src.Project
        Update-ImportList -State $State
        $State.App.SetStatus("Scanned $($State.Candidates.Count) function(s).", 'ok')
    }
    catch {
        $State.Summary.Text = "Scan failed: $($_.Exception.Message)"
        $State.App.Log('ERROR', 'Import', "scan failed: $($_.Exception.ToString())")
        $State.App.SetStatus('Scan failed.', 'err')
    }
    finally { if ($frm) { $frm.Cursor = [System.Windows.Forms.Cursors]::Default } }
}

# How each candidate compares with the library (keyed by function name).
function Get-ImportComparison {
    param($State)
    $entries = Get-ImportLibraryEntries -State $State
    $map = @{}
    $proj = [string]$State.Source.Project
    foreach ($c in $State.Candidates) {
        $same = @($entries | Where-Object { $_.Function -ieq $c.Function -and $_.Source.Kind -eq 'Project' -and $_.Source.Project -eq $proj })
        if ($same.Count) {
            $e = $same[0]
            $status = if ($e.Source.Hash -eq $c.Hash) { 'Same' } else { 'Changed' }
            $map[$c.Function.ToLower()] = @{ Status = $status; Entry = $e }
            continue
        }
        $other = @($entries | Where-Object { $_.Function -ieq $c.Function })
        if ($other.Count) { $map[$c.Function.ToLower()] = @{ Status = 'Name exists'; Entry = $other[0] } }
        else { $map[$c.Function.ToLower()] = @{ Status = 'New'; Entry = $null } }
    }
    return $map
}

function Update-ImportList {
    param($State)
    if (-not $State.Source) { return }
    $State.Library = Get-ImportComparison -State $State
    $lv = $State.List
    $checked = @{}
    foreach ($it in $lv.Items) { if ($it.Checked) { $checked[$it.Tag.Function] = $true } }
    $lv.BeginUpdate(); $lv.Items.Clear()
    $counts = @{ Ready = 0; Review = 0; Blocked = 0; Hidden = 0 }
    foreach ($c in $State.Candidates) {
        $counts[$c.Status]++
        if ($c.IsTemplate -and -not $State.ShowTemplate.Checked) { $counts.Hidden++; continue }
        if ($c.Status -eq 'Blocked' -and -not $State.ShowBlocked.Checked) { $counts.Hidden++; continue }
        $it = New-Object System.Windows.Forms.ListViewItem($c.Function)
        [void]$it.SubItems.Add($c.Status)
        [void]$it.SubItems.Add([string]$State.Library[$c.Function.ToLower()].Status)
        [void]$it.SubItems.Add($c.File)
        [void]$it.SubItems.Add([string]@($c.Helpers).Count)
        [void]$it.SubItems.Add([string]((@($c.Blockers) + @($c.Warnings)) | Select-Object -First 1))
        $it.Tag = $c
        $it.UseItemStyleForSubItems = $false
        $col = switch ($c.Status) { 'Ready' { [System.Drawing.Color]::FromArgb(20, 110, 40) } 'Review' { [System.Drawing.Color]::FromArgb(170, 100, 0) } default { [System.Drawing.Color]::Firebrick } }
        $it.SubItems[1].ForeColor = $col
        if ($c.Status -eq 'Blocked') { $it.ForeColor = $State.App.Theme.Muted; foreach ($si in $it.SubItems) { if ($si -ne $it.SubItems[1]) { $si.ForeColor = $State.App.Theme.Muted } } }
        [void]$lv.Items.Add($it)
        if ($checked.ContainsKey($c.Function) -and $c.Status -ne 'Blocked') { $it.Checked = $true }
    }
    $lv.EndUpdate()
    $ver = if ($State.Source.Version) { " v$($State.Source.Version)" } else { '' }
    $State.Summary.Text = "$($State.Source.Project)$ver - $(@($State.Candidates).Count) functions: $($counts.Ready) ready, $($counts.Review) to review, $($counts.Blocked) blocked$(if ($counts.Hidden) { " ($($counts.Hidden) hidden)" })."
}

function New-ImportEntryFromCandidate {
    param($Candidate, [string]$Category)
    $e = New-LibraryEntry
    $help = Get-LibraryFunctionHelp -Code $Candidate.Code -Function $Candidate.Function
    $e.Name = $Candidate.Function
    $e.Function = $Candidate.Function
    $e.Category = $(if ($Category.Trim()) { $Category.Trim() } else { $Candidate.Project })
    $e.Tags = @($Candidate.Project, [System.IO.Path]::GetFileNameWithoutExtension($Candidate.File)) | Where-Object { $_ } | Select-Object -Unique
    $e.Description = (@($help.Synopsis, $help.Description) | Where-Object { $_ } | Select-Object -Unique) -join "`r`n`r`n"
    if (@($help.Examples).Count) { $e.HowToUse = (@($help.Examples) -join "`r`n`r`n") }
    $req = @()
    if (@($Candidate.Modules).Count) { $req += 'Modules: ' + (@($Candidate.Modules) -join ', ') }
    if (@($Candidate.Tools).Count) { $req += 'Tools: ' + (@($Candidate.Tools) -join ', ') }
    $e.Requirements = $req -join "`r`n"
    $e.Modules = @($Candidate.Modules)
    $e.Modifies = [bool]$Candidate.SuggestModifies
    $e.Code = $Candidate.Code
    if (@($Candidate.Warnings).Count) { $e.Notes = "Imported with notes:`r`n" + ((@($Candidate.Warnings) | ForEach-Object { "- $_" }) -join "`r`n") }
    $e.Source = [ordered]@{
        Kind = 'Project'; Project = $Candidate.Project; Version = $Candidate.Version; File = $Candidate.File
        Hash = $Candidate.Hash; Imported = (Get-Date).ToUniversalTime().ToString('s') + 'Z'
    }
    return $e
}

function Invoke-ImportAdd {
    param($State)
    $sel = @($State.List.CheckedItems | ForEach-Object { $_.Tag } | Where-Object { $_.Status -ne 'Blocked' })
    if ($sel.Count -eq 0) { $State.Result.Text = 'Nothing checked.'; return }
    $review = @($sel | Where-Object { $_.Status -eq 'Review' })
    if ($review.Count) {
        $r = [System.Windows.Forms.MessageBox]::Show($State.Page.FindForm(),   # not-a-command: library import
            "$($review.Count) of these need a look before they are relied on:`r`n`r`n$((@($review | Select-Object -First 12 | ForEach-Object { "$($_.Function): $(@($_.Warnings)[0])" })) -join "`r`n")`r`n`r`nAdd them anyway? (The notes are saved with each entry.)",
            'Import', 'YesNo', 'Question')
        if ($r -ne 'Yes') { return }
    }
    $added = 0; $updated = 0; $skipped = 0
    foreach ($c in $sel) {
        $cmp = $State.Library[$c.Function.ToLower()]
        try {
            if ($cmp.Status -eq 'Same') { $skipped++; continue }
            if ($cmp.Status -eq 'Changed') { Save-LibraryEntry -App $State.App -Entry (Update-ImportEntryCode -Entry $cmp.Entry -Candidate $c) | Out-Null; $updated++; continue }
            Save-LibraryEntry -App $State.App -Entry (New-ImportEntryFromCandidate -Candidate $c -Category $State.Category.Text) | Out-Null
            $added++
        }
        catch { $State.App.Log('ERROR', 'Import', "$($c.Function): $($_.Exception.Message)") }
    }
    $State.Result.Text = "Added $added, updated $updated, skipped $skipped (already the same)."
    $State.App.SetStatus($State.Result.Text, 'ok')
    Update-ImportList -State $State
    if (Get-Command Invoke-AppSettingsChanged -ErrorAction SilentlyContinue) { Invoke-AppSettingsChanged -App $State.App -Name 'Library' }
}

function Update-ImportEntryCode {
    param($Entry, $Candidate)
    $e = ConvertTo-LibraryEntry $Entry
    $e.Code = $Candidate.Code
    $e.Modules = @(@($e.Modules) + @($Candidate.Modules) | Where-Object { $_ } | Select-Object -Unique)
    if ($Candidate.SuggestModifies) { $e.Modifies = $true }
    $e.Revision = [int]$e.Revision + 1
    $e.Source.Version = $Candidate.Version
    $e.Source.File = $Candidate.File
    $e.Source.Hash = $Candidate.Hash
    $e.Source.Imported = (Get-Date).ToUniversalTime().ToString('s') + 'Z'
    return $e
}

function Invoke-ImportUpdate {
    param($State)
    if (-not $State.Source) { return }
    $changed = @($State.Candidates | Where-Object { $State.Library[$_.Function.ToLower()].Status -eq 'Changed' -and $_.Status -ne 'Blocked' })
    if ($changed.Count -eq 0) { $State.Result.Text = 'No library entry has changed in this source.'; return }
    $edited = @($changed | Where-Object { $State.Library[$_.Function.ToLower()].Entry.Edited })
    $msg = "Update the code of $($changed.Count) entr$(if ($changed.Count -eq 1) { 'y' } else { 'ies' }) from $($State.Source.Project)?`r`nDescriptions, categories and notes are kept."
    if ($edited.Count) { $msg += "`r`n`r`n$($edited.Count) of them were edited in the library; their edited code will be replaced: $((@($edited | ForEach-Object { $_.Function })) -join ', ')" }
    $r = [System.Windows.Forms.MessageBox]::Show($State.Page.FindForm(), $msg, 'Update changed', 'YesNo', 'Question')   # not-a-command: library edit
    if ($r -ne 'Yes') { return }
    $n = 0
    foreach ($c in $changed) {
        try { Save-LibraryEntry -App $State.App -Entry (Update-ImportEntryCode -Entry $State.Library[$c.Function.ToLower()].Entry -Candidate $c) | Out-Null; $n++ }
        catch { $State.App.Log('ERROR', 'Import', "$($c.Function): $($_.Exception.Message)") }
    }
    $State.Result.Text = "Updated $n entr$(if ($n -eq 1) { 'y' } else { 'ies' })."
    $State.App.SetStatus($State.Result.Text, 'ok')
    Update-ImportList -State $State
    if (Get-Command Invoke-AppSettingsChanged -ErrorAction SilentlyContinue) { Invoke-AppSettingsChanged -App $State.App -Name 'Library' }
}
