# UI_Tab_Developer.psm1   (LITE TIER)
#
# Developer tab: every tool's source version against the developer EXE built from
# it, and whether it needs a build. Build selected / Build all run each tool's
# Build-App.cmd here, one after another (Services_ToolBox: Start-TbBuild), with
# the output in the log pane - a local build works where downloaded EXEs are
# blocked. A tool that is running is skipped (Windows cannot replace a running
# EXE); ToolBox itself is skipped too - close it and run its Build-App.cmd.

function New-TbDeveloperTab {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Windows.Forms.TabPage]$Page,
        [Parameter(Mandatory)] $App
    )
    $getProjects = ${function:Get-TbProjects}          # captured: closures do not see module functions reliably
    $selection   = ${function:Get-TbGridSelection}
    $fmtTime     = ${function:Format-TbTime}
    $openFolder  = ${function:Open-TbFolder}
    $buildCode   = ${function:Get-TbBuildCode}
    $startBuild  = ${function:Start-TbBuild}
    $stopBuild   = ${function:Stop-TbBuild}
    $isBuilding  = ${function:Test-TbBuilding}
    $confirm     = ${function:Confirm-AppCommand}
    $invoke      = ${function:Invoke-AppCommand}
    $fmt         = ${function:Format-AppCommandValue}

    $hdr = New-TbHeader -App $App -Text 'Developer - build the tools here from their source'

    $bar = New-TbBar -App $App
    $btnBuildSel = $App.Theme.MakeButton('Build selected')
    $btnBuildAll = $App.Theme.MakeButton('Build all')
    $btnBuildAll.Font = New-Object System.Drawing.Font($btnBuildAll.Font, [System.Drawing.FontStyle]::Bold)
    $btnStop     = $App.Theme.MakeButton('Stop'); $btnStop.Enabled = $false
    $btnLaunch   = $App.Theme.MakeButton('Launch developer EXE')
    $btnFolder   = $App.Theme.MakeButton('Open folder')
    $btnRefresh  = $App.Theme.MakeButton('Refresh')
    $bar.Controls.AddRange(@($btnBuildSel, $btnBuildAll, $btnStop, $btnLaunch, $btnFolder, $btnRefresh))

    $split = New-Object System.Windows.Forms.SplitContainer
    $split.Dock = 'Fill'; $split.Orientation = 'Horizontal'

    $grid = New-TbGrid -App $App -Multi -Columns @('Tool', 'Source', 'Built', 'Status', 'Built at', 'Lite EXE')
    $grid.Columns['Tool'].FillWeight = 22; $grid.Columns['Source'].FillWeight = 9; $grid.Columns['Built'].FillWeight = 9
    $grid.Columns['Status'].FillWeight = 30; $grid.Columns['Built at'].FillWeight = 15; $grid.Columns['Lite EXE'].FillWeight = 15
    $split.Panel1.Controls.Add($grid)

    $logHdr = New-Object System.Windows.Forms.Label
    $logHdr.Text = 'Build output'; $logHdr.Dock = 'Top'; $logHdr.Height = 20; $logHdr.AutoSize = $false
    if (Get-Command Set-SectionStyle -ErrorAction SilentlyContinue) { Set-SectionStyle -App $App -Label $logHdr; $logHdr.AutoSize = $false }
    $log = New-Object System.Windows.Forms.TextBox
    $log.Dock = 'Fill'; $log.Multiline = $true; $log.ReadOnly = $true; $log.ScrollBars = 'Both'; $log.WordWrap = $false
    $log.BackColor = $App.Theme.Surface; $log.Font = New-Object System.Drawing.Font($App.Theme.MonoFontName, 9)
    $split.Panel2.Controls.Add($log)
    $split.Panel2.Controls.Add($logHdr)

    $okColor   = [System.Drawing.Color]::FromArgb(20, 110, 40)
    $needColor = [System.Drawing.Color]::FromArgb(150, 90, 0)

    $refresh = {
        $keep = @(& $selection -Grid $grid | ForEach-Object { $_.Name })
        $all = @(& $getProjects -App $App)
        $grid.SuspendLayout()
        try {
            $grid.Rows.Clear()
            foreach ($p in $all) {
                $status = $p.Status + $(if ($p.IsSelf) { '   (this app: close it to rebuild)' } else { '' })
                $i = $grid.Rows.Add($p.AppName, $p.SourceVersion, $p.Dev.Version, $status, (& $fmtTime $p.Dev.Time),
                                    $(if ($p.Lite.Exists) { 'v' + $p.Lite.Version } else { '-' }))
                $row = $grid.Rows[$i]; $row.Tag = $p
                $row.Cells['Status'].Style.ForeColor = $(if ($p.NeedsBuild) { $needColor } else { $okColor })
                if ($keep -contains $p.Name) { $row.Selected = $true }
            }
        } finally { $grid.ResumeLayout() }
        $need = @($all | Where-Object { $_.NeedsBuild -and -not $_.IsSelf }).Count
        if ($need -gt 0 -and -not (& $isBuilding)) { $App.SetStatus("$need tool(s) need a build.", 'warn') }
    }.GetNewClosure()

    $writeLog = {
        param([string]$Text)
        $log.AppendText(($Text -replace "`r?`n", "`r`n") + "`r`n")
    }.GetNewClosure()

    $setBusy = {
        param([bool]$Busy)
        $btnBuildSel.Enabled = -not $Busy; $btnBuildAll.Enabled = -not $Busy; $btnStop.Enabled = $Busy
    }.GetNewClosure()

    $build = {
        param($Projects, [string]$What)
        $list = @($Projects)
        if ($list.Count -eq 0) { $App.SetStatus('Select one or more tools first.', 'warn'); return }
        if (& $isBuilding) { $App.SetStatus('A build is already running.', 'warn'); return }
        $sum = "$What : run Build-App.cmd for $($list.Count) tool(s), one at a time: " + (($list | ForEach-Object { $_.AppName }) -join ', ') +
               '. Each makes the developer EXE and its Lite EXE in the tool''s folder. Running tools are skipped.'
        if (-not (& $confirm -App $App -Title $What -Kind Change -RunLabel 'Build' -Summary $sum -Code (& $buildCode -App $App -Projects $list))) { return }
        $log.Clear()
        & $startBuild -App $App -Projects $list
    }.GetNewClosure()

    $btnBuildSel.Add_Click({ & $build (& $selection -Grid $grid) 'Build selected' }.GetNewClosure())
    $btnBuildAll.Add_Click({ & $build (@(& $getProjects -App $App)) 'Build all' }.GetNewClosure())
    $btnStop.Add_Click({ & $stopBuild }.GetNewClosure())
    $btnLaunch.Add_Click({
        $p = @(& $selection -Grid $grid) | Select-Object -First 1
        if (-not $p) { $App.SetStatus('Select a tool first.', 'warn'); return }
        if (-not $p.Dev.Exists) { $App.SetStatus("$($p.AppName) has no developer EXE yet - build it first.", 'warn'); return }
        $r = & $invoke -App $App -Title "Launch $($p.AppName) (developer)" -Kind Read -RunLabel 'Launch' `
            -Summary "Start the developer build of $($p.AppName) (v$($p.Dev.Version)): Update, Build Sealed, Extract ..." `
            -Code ('Start-Process -FilePath ' + (& $fmt $p.Dev.Path) + ' -WorkingDirectory ' + (& $fmt $p.Folder))
        if ($r.Errors.Count) { $App.SetStatus("Not started: $($r.Errors[0])", 'err') }
    }.GetNewClosure())
    $btnFolder.Add_Click({
        $p = @(& $selection -Grid $grid) | Select-Object -First 1
        if (-not $p) { $App.SetStatus('Select a tool first.', 'warn'); return }
        & $openFolder -App $App -Path $p.Folder
    }.GetNewClosure())
    $btnRefresh.Add_Click($refresh)

    Register-TbView -Refresh $refresh -Log $writeLog -BuildState $setBusy
    Register-EnvironmentChangedHandler -Handler { param($a) & $refresh }.GetNewClosure()

    # splitter: list on top, output below, once the page has its real size
    $sizer = New-Object System.Windows.Forms.Timer; $sizer.Interval = 200
    $sizer.Add_Tick({
        $sizer.Stop(); $sizer.Dispose()
        try { if ($split.Height -gt 300) { $split.SplitterDistance = [int]($split.Height * 0.45) } } catch { }
    }.GetNewClosure())
    $sizer.Start()

    $Page.Controls.Add($split)
    $Page.Controls.Add($bar)
    $Page.Controls.Add($hdr)
    & $refresh
}
