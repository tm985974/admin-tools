# UI_Tab_Tools.psm1   (LITE TIER)
#
# Tools tab: every tool in the projects folder and its Lite EXE - the sealed
# build (asks for the user or admin password at launch). Double-click = Launch.
# The developer builds (<ExeName>Dev.exe) are on the Developer tab.

function New-TbToolsTab {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Windows.Forms.TabPage]$Page,
        [Parameter(Mandatory)] $App
    )
    $getProjects = ${function:Get-TbProjects}          # captured: closures do not see module functions reliably
    $getFolders  = ${function:Get-TbFolders}
    $selection   = ${function:Get-TbGridSelection}
    $fmtTime     = ${function:Format-TbTime}
    $openFolder  = ${function:Open-TbFolder}
    $invoke      = ${function:Invoke-AppCommand}
    $fmt         = ${function:Format-AppCommandValue}

    $hdr = New-TbHeader -App $App -Text 'Tools - run the sealed (Lite) builds'
    $where = New-Object System.Windows.Forms.Label
    $where.Dock = 'Top'; $where.Height = 22; $where.ForeColor = $App.Theme.Muted; $where.AutoSize = $false

    $bar = New-TbBar -App $App
    $btnLaunch  = $App.Theme.MakeButton('Launch')
    $btnLaunch.Font = New-Object System.Drawing.Font($btnLaunch.Font, [System.Drawing.FontStyle]::Bold)
    $btnFolder  = $App.Theme.MakeButton('Open folder')
    $btnRefresh = $App.Theme.MakeButton('Refresh')
    $bar.Controls.AddRange(@($btnLaunch, $btnFolder, $btnRefresh))

    $grid = New-TbGrid -App $App -Columns @('Tool', 'Version', 'State', 'Built', 'EXE')
    $grid.Columns['Tool'].FillWeight = 22; $grid.Columns['Version'].FillWeight = 10; $grid.Columns['State'].FillWeight = 16
    $grid.Columns['Built'].FillWeight = 14; $grid.Columns['EXE'].FillWeight = 38

    $refresh = {
        $keep = @(& $selection -Grid $grid | ForEach-Object { $_.Name })
        $f = & $getFolders -App $App
        $where.Text = "Projects folder: $($f.Projects)     Each tool's <Name>Lite.exe asks for the user or admin password when it starts."
        $grid.SuspendLayout()
        try {
            $grid.Rows.Clear()
            foreach ($p in @(& $getProjects -App $App)) {
                if ($p.IsSelf) { continue }
                $l = $p.Lite
                $state = switch ($p.LiteState) { 'current' { 'Ready' } 'older' { "Older than v$($p.Dev.Version) - rebuild" } default { 'Not built' } }
                $i = $grid.Rows.Add($p.AppName, $(if ($l.Exists) { $l.Version } else { '' }), $state,
                                    $(if ($l.Exists) { & $fmtTime $l.Time } else { '' }), $(if ($l.Exists) { $l.Path } else { "Build it on the Developer tab ($($p.Folder))" }))
                $row = $grid.Rows[$i]; $row.Tag = $p
                if (-not $l.Exists) { $row.DefaultCellStyle.ForeColor = $App.Theme.Muted }
                if ($keep -contains $p.Name) { $row.Selected = $true }
            }
        } finally { $grid.ResumeLayout() }
    }.GetNewClosure()

    $launch = {
        $p = @(& $selection -Grid $grid) | Select-Object -First 1
        if (-not $p) { $App.SetStatus('Select a tool first.', 'warn'); return }
        if (-not $p.Lite.Exists) { $App.SetStatus("$($p.AppName) has no Lite EXE yet - build it on the Developer tab (with passwords).", 'warn'); return }
        $exe = $p.Lite.Path
        $r = & $invoke -App $App -Title "Launch $($p.AppName)" -Kind Read -RunLabel 'Launch' `
            -Summary "Start $($p.AppName) v$($p.Lite.Version) (the sealed build: it asks for the user or admin password)." `
            -Code ('Start-Process -FilePath ' + (& $fmt $exe) + ' -WorkingDirectory ' + (& $fmt (Split-Path -Parent $exe)))
        if ($r.Errors.Count) { $App.SetStatus("Not started: $($r.Errors[0])", 'err') }
        elseif ($r.Ran) { $App.SetStatus("$($p.AppName) started.", 'ok') }
    }.GetNewClosure()

    $btnLaunch.Add_Click($launch)
    $grid.Add_CellDoubleClick({ param($s, $e) if ($e.RowIndex -ge 0) { & $launch } }.GetNewClosure())
    $btnFolder.Add_Click({
        $p = @(& $selection -Grid $grid) | Select-Object -First 1
        if (-not $p) { $App.SetStatus('Select a tool first.', 'warn'); return }
        & $openFolder -App $App -Path $p.Folder
    }.GetNewClosure())
    $btnRefresh.Add_Click($refresh)
    Register-TbView -Refresh $refresh
    Register-EnvironmentChangedHandler -Handler { param($a) & $refresh }.GetNewClosure()

    $Page.Controls.Add($grid)
    $Page.Controls.Add($bar)
    $Page.Controls.Add($where)
    $Page.Controls.Add($hdr)
    & $refresh
}
