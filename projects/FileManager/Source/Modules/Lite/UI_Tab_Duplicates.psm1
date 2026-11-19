# UI_Tab_Duplicates.psm1   (LITE TIER)
#
# Duplicates: groups of folders with the same content (top-down: when a whole
# folder matches, its sub folders are not listed again), biggest saving first.
# Pick a different keeper, open a copy, find folders contained in bigger ones,
# and open the Actions window to move things.

function New-FmDuplicatesTab {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Windows.Forms.TabPage]$Page,
        [Parameter(Mandatory)] $App
    )
    Set-LazyTabBuild -Page $Page -App $App -Build ${function:Build-FmDuplicatesTab}
}

function Build-FmDuplicatesTab {
    param($Page, $App)
    $Page.Padding = New-Object System.Windows.Forms.Padding(14)
    $cat = Get-FmCatalog -App $App

    $hdr = New-FmLabel -App $App -Text 'Duplicate folders' -Header
    $summary = New-FmLabel -App $App -Height 24

    $bar = New-FmBar
    $btnFind = $App.Theme.MakeButton('Find duplicates')
    $chkQuick = New-Object System.Windows.Forms.CheckBox
    $chkQuick.Text = 'Include quick matches'
    $chkQuick.AutoSize = $true; $chkQuick.Margin = New-Object System.Windows.Forms.Padding(4, 8, 16, 0)
    $btnActions = $App.Theme.MakeButton('Actions')
    $btnContained = $App.Theme.MakeButton('Find contained folders')
    $lblFilter = New-Object System.Windows.Forms.Label
    $lblFilter.Text = 'Filter:'; $lblFilter.AutoSize = $true; $lblFilter.Margin = New-Object System.Windows.Forms.Padding(24, 8, 4, 0)
    $txtFilter = New-Object System.Windows.Forms.TextBox
    $txtFilter.Width = 260; $txtFilter.Margin = New-Object System.Windows.Forms.Padding(0, 5, 8, 0)
    $lblCount = New-Object System.Windows.Forms.Label
    $lblCount.AutoSize = $true; $lblCount.ForeColor = $App.Theme.Muted; $lblCount.Margin = New-Object System.Windows.Forms.Padding(0, 8, 0, 0)
    $bar.Controls.AddRange(@($btnFind, $chkQuick, $btnActions, $btnContained, $lblFilter, $txtFilter, $lblCount))

    $tabs = New-Object System.Windows.Forms.TabControl
    $tabs.Dock = 'Fill'
    $pgGroups = New-Object System.Windows.Forms.TabPage 'Duplicate groups'
    $pgContained = New-Object System.Windows.Forms.TabPage 'Contained folders'
    $pgGroups.BackColor = $App.Theme.Surface; $pgContained.BackColor = $App.Theme.Surface
    $pgGroups.Padding = New-Object System.Windows.Forms.Padding(6); $pgContained.Padding = New-Object System.Windows.Forms.Padding(6)
    [void]$tabs.TabPages.Add($pgGroups)
    [void]$tabs.TabPages.Add($pgContained)

    # ---- groups (top) and the copies of the selected group (bottom) ----
    $split = New-Object System.Windows.Forms.SplitContainer
    $split.Orientation = 'Horizontal'; $split.Size = New-Object System.Drawing.Size(1600, 900); $split.SplitterDistance = 380; $split.Dock = 'Fill'
    $gGroups = New-FmGrid -App $App -Columns @('Folder', 'Status', 'Copies', 'Files', 'Size each', 'Reclaim', 'Kept copy') -Weights @(170, 110, 55, 70, 80, 80, 420)
    $split.Panel1.Controls.Add($gGroups)

    $mBar = New-FmBar
    $lblCopies = New-Object System.Windows.Forms.Label
    $lblCopies.Text = 'Copies of the selected folder:'; $lblCopies.AutoSize = $true; $lblCopies.Margin = New-Object System.Windows.Forms.Padding(0, 8, 12, 0)
    $btnKeeper = $App.Theme.MakeButton('Make keeper')
    $btnOpen = $App.Theme.MakeButton('Open folder')
    $btnClearPicks = $App.Theme.MakeButton('Clear my keeper picks')
    $mBar.Controls.AddRange(@($lblCopies, $btnKeeper, $btnOpen, $btnClearPicks))
    $gMembers = New-FmGrid -App $App -Columns @('Role', 'Drive', 'Path', 'Oldest file', 'Why') -Weights @(70, 140, 460, 80, 260)
    $split.Panel2.Controls.Add($gMembers)
    $split.Panel2.Controls.Add($mBar)
    $pgGroups.Controls.Add($split)

    # ---- contained folders ----
    $cBar = New-FmBar
    $cNote = New-Object System.Windows.Forms.Label
    $cNote.AutoSize = $true; $cNote.ForeColor = $App.Theme.Muted; $cNote.Margin = New-Object System.Windows.Forms.Padding(12, 8, 0, 0)
    $cNote.Text = 'Every file of the folder on the left is also inside the bigger folder on the right (often an older backup of a folder that grew). Report only: check, then move or delete by hand.'
    $btnCOpen = $App.Theme.MakeButton('Open contained folder')
    $cBar.Controls.AddRange(@($btnCOpen, $cNote))
    $gContained = New-FmGrid -App $App -Columns @('Drive', 'Folder', 'Files', 'Size', 'Is inside (drive)', 'Bigger folder', 'Its files') -Weights @(110, 330, 60, 70, 110, 330, 60)
    $pgContained.Controls.Add($gContained)
    $pgContained.Controls.Add($cBar)

    $s = @{ Cat = $cat; Groups = $gGroups; Members = $gMembers; Contained = $gContained; Summary = $summary; Count = $lblCount
            Data = @(); Quick = $chkQuick; Find = $btnFind; ContainedBtn = $btnContained }

    $fillMembers = {
        $s.Members.Rows.Clear()
        $g = Get-FmSelected -Grid $s.Groups
        if (-not $g) { return }
        foreach ($m in $s.Cat.GetMembers($g.Id)) {
            $i = $s.Members.Rows.Add($m.Role, $m.Drive, ('\' + $m.Path), $m.Oldest, $m.Reason)
            $s.Members.Rows[$i].Tag = $m
            if ($m.Role -eq 'Keep') { $s.Members.Rows[$i].DefaultCellStyle.ForeColor = [System.Drawing.Color]::FromArgb(26, 127, 55) }
            elseif ($m.Role -eq 'Duplicate') { $s.Members.Rows[$i].DefaultCellStyle.ForeColor = [System.Drawing.Color]::FromArgb(180, 35, 24) }
            else { $s.Members.Rows[$i].DefaultCellStyle.ForeColor = [System.Drawing.Color]::Gray }
        }
    }.GetNewClosure()
    $s.FillMembers = $fillMembers

    $select = ${function:Select-FilterMatch}
    $onFilter = {
        param($Regex, $Text)
        $rows = @(& $select -Items $s.Data -Regex $Regex -Property @('Name', 'Keeper', 'Status'))
        $s.Groups.SuspendLayout()
        try {
            $s.Groups.Rows.Clear()
            foreach ($g in $rows) {
                $i = $s.Groups.Rows.Add($g.Name, $g.Status, $g.Copies, $g.Files.ToString('N0'), [FileManagerEngine.Util]::Size($g.Bytes), [FileManagerEngine.Util]::Size($g.Reclaim), $g.Keeper)
                $s.Groups.Rows[$i].Tag = $g
                if (-not $g.Confirmed) { $s.Groups.Rows[$i].DefaultCellStyle.ForeColor = [System.Drawing.Color]::DarkOrange }
            }
        }
        finally { $s.Groups.ResumeLayout() }
        $s.Count.Text = '{0:N0} of {1:N0} shown' -f $rows.Count, $s.Data.Count
        & $s.FillMembers
    }.GetNewClosure()
    $filter = Register-ListFilter -App $App -TextBox $txtFilter -OnFilter $onFilter
    $s.Filter = $filter

    $refresh = {
        $s.Data = @($s.Cat.GetGroups(5000))
        $total = $s.Cat.GroupCount()
        $picks = $s.Cat.KeeperPickCount()
        $s.Summary.Text = '{0:N0} duplicate groups  |  {1} to reclaim{2}{3}' -f $total, [FileManagerEngine.Util]::Size($s.Cat.ReclaimTotal()),
            $(if ($total -gt $s.Data.Count) { "  |  the $($s.Data.Count.ToString('N0')) biggest are listed (use the CSV export for all)" } else { '' }),
            $(if ($picks -gt 0) { "  |  $picks keeper pick(s) of yours" } else { '' })
        & $s.Filter.Apply
        $s.Contained.Rows.Clear()
        foreach ($c in $s.Cat.GetContained(5000)) {
            $i = $s.Contained.Rows.Add($c.Drive, ('\' + $c.Path), $c.Files.ToString('N0'), [FileManagerEngine.Util]::Size($c.Bytes), $c.InDrive, ('\' + $c.InPath), $c.InFiles.ToString('N0'))
            $s.Contained.Rows[$i].Tag = $c
        }
    }.GetNewClosure()
    $s.Refresh = $refresh
    Register-FmRefresh -Name 'Duplicates' -Action $refresh

    $runAnalyze = {
        $s = $s   # local copy: GetNewClosure below only captures local variables
        $o = New-FmOptions -App $App -IncludeQuick:($s.Quick.Checked)
        $job = Invoke-FmSafe -App $App -What 'Find duplicates' -Action { $s.Cat.StartAnalyze($o) }
        if (-not $job) { return }
        $s.Find.Enabled = $false
        $App.SetStatus('Finding duplicate folders...', 'info')
        Start-FmJobWatch -App $App -Job $job -OnDone { param($j) $s.Find.Enabled = $true; Invoke-FmRefresh }.GetNewClosure()
    }.GetNewClosure()

    $gGroups.Add_SelectionChanged({ & $s.FillMembers }.GetNewClosure())
    $btnFind.Add_Click({ & $runAnalyze }.GetNewClosure())
    $btnActions.Add_Click({ Show-FmActionsDialog -App $App }.GetNewClosure())

    $btnKeeper.Add_Click({
        $m = Get-FmSelected -Grid $s.Members
        if (-not $m) { $App.SetStatus('Select the copy to keep in the lower list first.', 'warn'); return }
        if ($m.Role -eq 'Keep') { $App.SetStatus('That copy is already the keeper.', 'info'); return }
        $s.Cat.SetKeeper($m.Id)
        $App.LogAction("Keeper picked: $($m.Drive) \$($m.Path)")
        & $runAnalyze
    }.GetNewClosure())

    $btnClearPicks.Add_Click({
        $s.Cat.ClearKeeperPicks()
        $App.LogAction('Keeper picks cleared.')
        & $runAnalyze
    }.GetNewClosure())

    $btnOpen.Add_Click({
        $m = Get-FmSelected -Grid $s.Members
        if (-not $m) { $App.SetStatus('Select a copy in the lower list first.', 'warn'); return }
        Open-FmFolder -App $App -Path $m.FullPath
    }.GetNewClosure())

    $btnCOpen.Add_Click({
        $c = Get-FmSelected -Grid $s.Contained
        if (-not $c) { $App.SetStatus('Select a folder in the list first.', 'warn'); return }
        $root = $null
        foreach ($d in $s.Cat.GetDrives()) { if ($d.Connected -and ($d.Letter + ' ' + $d.Label) -eq $c.Drive) { $root = $d.Letter + '\' } }
        if (-not $root) { $App.SetStatus('That drive is not connected.', 'warn'); return }
        Open-FmFolder -App $App -Path ($root + $c.Path)
    }.GetNewClosure())

    $btnContained.Add_Click({
        $s = $s   # local copy for the OnDone closure
        $job = Invoke-FmSafe -App $App -What 'Find contained folders' -Action { $s.Cat.StartContained() }
        if (-not $job) { return }
        $s.ContainedBtn.Enabled = $false
        $App.SetStatus('Looking for folders whose files are all inside a bigger folder...', 'info')
        Start-FmJobWatch -App $App -Job $job -OnDone { param($j) $s.ContainedBtn.Enabled = $true; Invoke-FmRefresh }.GetNewClosure()
    }.GetNewClosure())

    $note = New-FmLabel -App $App -Muted -Height 40 -Text ("Green = kept, red = moves to _Duplicates, grey = stays (it holds a folder kept elsewhere). Orange groups are quick matches only - run a content check to confirm them." +
        [Environment]::NewLine + "Find contained folders works best after a content check with 'Also hash every file whose size matches another file'.")
    $note.Dock = 'Bottom'

    $Page.Controls.Add($tabs)
    $Page.Controls.Add($note)
    $Page.Controls.Add($bar)
    $Page.Controls.Add($summary)
    $Page.Controls.Add($hdr)
    & $refresh
}
