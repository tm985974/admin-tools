# UI_Tab_Workflow.psm1   (LITE TIER)
#
# Workflow: the recommended steps as a checklist. Each step says where you are
# (worked out from the catalog), what to do next, and has a button that takes
# you to the right place. Refreshes every time the tab is opened.

function New-FmWorkflowTab {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Windows.Forms.TabPage]$Page,
        [Parameter(Mandatory)] $App
    )
    Set-LazyTabBuild -Page $Page -App $App -Build ${function:Build-FmWorkflowTab}
}

function Build-FmWorkflowTab {
    param($Page, $App)
    $Page.Padding = New-Object System.Windows.Forms.Padding(14)
    $cat = Get-FmCatalog -App $App

    $hdr = New-FmLabel -App $App -Text 'Workflow' -Header
    $sub = New-FmLabel -App $App -Muted -Height 24 -Text 'The recommended order, step by step. The arrow marks the next thing to do. Nothing here changes anything; the buttons take you to the right place.'

    $bar = New-FmBar
    $btnRefresh = $App.Theme.MakeButton('Refresh')
    $bar.Controls.Add($btnRefresh)

    $flow = New-Object System.Windows.Forms.FlowLayoutPanel
    $flow.Dock = 'Fill'; $flow.FlowDirection = 'TopDown'; $flow.WrapContents = $false; $flow.AutoScroll = $true
    $flow.BackColor = $App.Theme.Surface

    $done = [string][char]0x2714      # check mark
    $next = [string][char]0x27A4      # arrow
    $todo = [string][char]0x25CB      # circle
    $green = [System.Drawing.Color]::FromArgb(26, 127, 55)

    # One step: a mark, a title, a detail text and up to two buttons.
    $steps = @()
    $defs = @(
        @{ Title = '1. Scan every drive (quick scan)';           Buttons = @('Go to Scan') }
        @{ Title = '2. Content check every drive';               Buttons = @('Content check') }
        @{ Title = '3. Review the duplicates';                   Buttons = @('Go to Duplicates') }
        @{ Title = '4. Build a plan and move, a few at a time';  Buttons = @('Open Actions', 'Go to Reports') }
        @{ Title = '5. Check _Duplicates, then delete';          Buttons = @('Go to Reports') }
        @{ Title = '6. Every drive cleaned';                     Buttons = @('Go to Drives') }
        @{ Title = '7. Consolidate onto one drive (later)';      Buttons = @('Go to Consolidate') }
        @{ Title = '8. Found another folder? Check it';          Buttons = @('Check a folder') }
    )
    foreach ($d in $defs) {
        $p = New-Object System.Windows.Forms.Panel
        $p.Width = 1500; $p.Height = 104; $p.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 6)
        $p.BorderStyle = 'FixedSingle'; $p.BackColor = $App.Theme.Surface
        $mark = New-Object System.Windows.Forms.Label
        $mark.Location = New-Object System.Drawing.Point(10, 8); $mark.Size = New-Object System.Drawing.Size(34, 34)
        $mark.Font = New-AppFont -App $App -Size ($App.Theme.FontSizePt + 8) -Style ([System.Drawing.FontStyle]::Bold)
        $title = New-Object System.Windows.Forms.Label
        $title.Location = New-Object System.Drawing.Point(50, 10); $title.AutoSize = $true; $title.Text = $d.Title
        Set-SectionStyle -App $App -Label $title
        $detail = New-Object System.Windows.Forms.Label
        $detail.Location = New-Object System.Drawing.Point(50, 34); $detail.Size = New-Object System.Drawing.Size(1150, 64)
        $detail.ForeColor = $App.Theme.Text
        $p.Controls.AddRange(@($mark, $title, $detail))
        $x = 1220
        $btns = @()
        foreach ($b in $d.Buttons) {
            $btn = $App.Theme.MakeButton($b)
            $btn.Location = New-Object System.Drawing.Point($x, 30)
            $p.Controls.Add($btn)
            $btns += $btn
            $x += $btn.Width + 8
        }
        $flow.Controls.Add($p)
        $steps += @{ Panel = $p; Mark = $mark; Detail = $detail; Buttons = $btns }
    }

    $s = @{ Cat = $cat; Steps = $steps; Page = $Page; Done = $done; Next = $next; Todo = $todo; Green = $green; App = $App }

    $refresh = {
        $w = $s.Cat.GetWorkflow()
        $nl = [Environment]::NewLine
        $list = { param($items, [int]$max = 4) $a = @($items); if ($a.Count -le $max) { $a -join ', ' } else { (($a | Select-Object -First $max) -join ', ') + " and $($a.Count - $max) more" } }
        $state = @()

        # 1 scan
        $ok1 = $w.Drives -gt 0 -and $w.NotScanned.Count -eq 0 -and $w.NeedRescan.Count -eq 0
        $t = $(if ($w.Drives -eq 0) { 'No drives yet. Plug in a drive, then Scan > Whole drive > Start (leave "Full content check" unticked for now: minutes per drive).' }
               else { "$($w.Scanned) of $($w.Drives) drive(s) scanned." +
                      $(if ($w.NotScanned.Count) { " Not scanned yet: $(& $list $w.NotScanned)." } else { '' }) +
                      $(if ($w.NeedRescan.Count) { " Need a new quick scan: $(& $list $w.NeedRescan)." } else { '' }) +
                      $nl + 'Scan every drive before moving anything: the best copy to keep may be on a drive you have not scanned yet. Plug in one drive at a time.' })
        $state += , @($ok1, $t)

        # 2 content check
        $ok2 = $ok1 -and $w.ToCheckFiles -eq 0
        $t = $(if ($w.ToCheckFiles -gt 0) { "{0:N0} files ({1}) in folders that might be duplicates still need reading: {2}." -f $w.ToCheckFiles, [FileManagerEngine.Util]::Size($w.ToCheckBytes), (& $list $w.ToCheck) +
                    $nl + 'Plug in each of those drives in turn and click Content check (Scan tab). Stop is safe; it carries on where it stopped.' }
               elseif ($w.Drives -gt 0) { 'Every file that could be a duplicate has been read. Matches are confirmed by content.' }
               else { 'After step 1.' })
        $state += , @($ok2, $t)

        # 3 review
        $ok3 = $ok2 -and ($w.Groups -eq 0 -and $w.Batches -gt 0)
        $t = $(if ($w.Groups -gt 0) { "{0:N0} duplicate groups, {1} to reclaim{2}. Check the biggest ones; change a keeper with Make keeper; set drive priorities on the Drives tab." -f $w.Groups, [FileManagerEngine.Util]::Size($w.Reclaim), $(if ($w.QuickGroups -gt 0) { " ($($w.QuickGroups) are quick matches only - finish step 2 first)" } else { '' }) }
               elseif ($w.Batches -gt 0) { 'No duplicate folders left in the catalog.' }
               else { 'After steps 1 and 2.' })
        $state += , @($ok3, $t)

        # 4 move
        $ok4 = $ok3 -and $w.PlannedSteps -eq 0
        $t = 'Actions > Build plan lists every move with a tick box; nothing moves until you tick steps and click Move selected. Start with one drive, duplicates only.'
        if ($w.PlannedSteps -gt 0) { $t = "{0:N0} planned step(s) not run yet (Reports > Open batch). " -f $w.PlannedSteps + $t }
        $state += , @($ok4, $t)

        # 5 delete
        $ok5 = $ok4 -and $w.MovedDuplicates -eq 0 -and $w.DeletedDuplicates -gt 0
        $t = $(if ($w.MovedDuplicates -gt 0) { "{0:N0} duplicate folder(s) ({1}) are waiting in _Duplicates. Look through them, then Reports > Open batch > tick > Delete selected duplicates (each one is re-checked first)." -f $w.MovedDuplicates, [FileManagerEngine.Util]::Size($w.MovedDuplicateBytes) }
               elseif ($w.DeletedDuplicates -gt 0) { "{0:N0} duplicate folder(s) deleted so far. Nothing waiting." -f $w.DeletedDuplicates }
               else { 'After step 4. Take your time: the copies are safe in _Duplicates until you delete them.' })
        $state += , @($ok5, $t)

        # 6 all drives cleaned
        $ok6 = $ok5 -and $w.NotCleaned.Count -eq 0 -and $w.Drives -gt 0
        $t = $(if ($w.NotCleaned.Count -gt 0) { "Still outside _Clean: $(& $list $w.NotCleaned 3)." + $nl + 'Repeat steps 4-5 per drive (Actions with "Move keepers and unique folders to _Clean" ticked).' }
               elseif ($w.Drives -gt 0) { 'Every scanned drive holds only _Clean (and _Duplicates).' }
               else { 'After step 5.' })
        $state += , @($ok6, $t)

        # 7 consolidate
        $ok7 = $w.VerifyRuns -gt 0
        $t = 'When there is room: copy each drive''s _Clean to one NTFS drive (Robocopy), Verify copy, then Remove verified source files. Then scan that drive with "Also hash every file whose size matches another file" ticked, so step 8 can confirm matches.'
        $state += , @($ok7, $t)

        # 8 check stray folders
        $t = "Any time: put the folder on a thumb drive (or anywhere), then Scan > Check only. You get a list of what is already in the catalog and what is new. Checks so far: $($w.Checks)."
        $state += , @($false, $t)

        $nextFound = $false
        for ($i = 0; $i -lt $s.Steps.Count; $i++) {
            $st = $s.Steps[$i]
            $ok = [bool]$state[$i][0]
            $st.Detail.Text = [string]$state[$i][1]
            if ($ok) { $st.Mark.Text = $s.Done; $st.Mark.ForeColor = $s.Green; $st.Panel.BackColor = $s.App.Theme.Surface }
            elseif (-not $nextFound -and $i -lt 7) { $st.Mark.Text = $s.Next; $st.Mark.ForeColor = $s.App.Theme.Title; $st.Panel.BackColor = $s.App.Theme.Header; $nextFound = $true }
            else { $st.Mark.Text = $s.Todo; $st.Mark.ForeColor = $s.App.Theme.Muted; $st.Panel.BackColor = $s.App.Theme.Surface }
        }
    }.GetNewClosure()
    $s.Refresh = $refresh
    Register-FmRefresh -Name 'Workflow' -Action $refresh

    $go = {
        param([string]$What)
        switch ($What) {
            'Go to Scan'        { Select-FmTab -From $s.Page -Title 'Scan'; Invoke-FmHook -Name 'ScanMode' -Arg 'Drive' }
            'Content check'     { Select-FmTab -From $s.Page -Title 'Scan'; $s.App.SetStatus('Plug in the drive(s), then click Content check only.', 'info') }
            'Go to Duplicates'  { Select-FmTab -From $s.Page -Title 'Duplicates' }
            'Open Actions'      { Show-FmActionsDialog -App $s.App; & $s.Refresh }
            'Go to Reports'     { Select-FmTab -From $s.Page -Title 'Reports' }
            'Go to Drives'      { Select-FmTab -From $s.Page -Title 'Drives' }
            'Go to Consolidate' { Select-FmTab -From $s.Page -Title 'Consolidate' }
            'Check a folder'    { Select-FmTab -From $s.Page -Title 'Scan'; Invoke-FmHook -Name 'ScanMode' -Arg 'Check' }
        }
    }.GetNewClosure()
    foreach ($st in $steps) {
        foreach ($b in $st.Buttons) {
            $b.Add_Click({ param($sender, $e) & $go ([string]$sender.Text) }.GetNewClosure())
        }
    }
    $btnRefresh.Add_Click({ & $s.Refresh }.GetNewClosure())
    $Page.Add_Enter({ & $s.Refresh }.GetNewClosure())

    $Page.Controls.Add($flow)
    $Page.Controls.Add($bar)
    $Page.Controls.Add($sub)
    $Page.Controls.Add($hdr)
    & $refresh
}
