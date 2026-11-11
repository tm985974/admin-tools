# UI_Tab_Tools.psm1   (LITE TIER)
#
# Tools tab: every tool in the projects folder and the EXE to run it with.
# Launch uses the tool's SEALED EXE when the environment's "Sealed EXE folder"
# holds <ExeName>.exe, else its Lite EXE (the sealed TEST build Build-App makes:
# admin password "a", user password "u"). Double-click a row = Launch.

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

    $hdr = New-TbHeader -App $App -Text 'Tools - run the tools built in this folder'
    $where = New-Object System.Windows.Forms.Label
    $where.Dock = 'Top'; $where.Height = 22; $where.ForeColor = $App.Theme.Muted; $where.AutoSize = $false

    $bar = New-TbBar -App $App
    $btnLaunch  = $App.Theme.MakeButton('Launch')
    $btnLaunch.Font = New-Object System.Drawing.Font($btnLaunch.Font, [System.Drawing.FontStyle]::Bold)
    $btnFolder  = $App.Theme.MakeButton('Open folder')
    $btnRefresh = $App.Theme.MakeButton('Refresh')
    $bar.Controls.AddRange(@($btnLaunch, $btnFolder, $btnRefresh))

    $grid = New-TbGrid -App $App -Columns @('Tool', 'Version', 'Runs as', 'Built', 'EXE')
    $grid.Columns['Tool'].FillWeight = 22; $grid.Columns['Version'].FillWeight = 10; $grid.Columns['Runs as'].FillWeight = 12
    $grid.Columns['Built'].FillWeight = 14; $grid.Columns['EXE'].FillWeight = 42

    $refresh = {
        $keep = @(& $selection -Grid $grid | ForEach-Object { $_.Name })
        $f = & $getFolders -App $App
        $where.Text = "Projects folder: $($f.Projects)" + $(if ($f.Sealed) { "     Sealed EXE folder: $($f.Sealed)" } else { '     (no Sealed EXE folder set: Launch uses the Lite test builds)' })
        $grid.SuspendLayout()
        try {
            $grid.Rows.Clear()
            foreach ($p in @(& $getProjects -App $App)) {
                if ($p.IsSelf) { continue }
                $l = $p.Launch
                $i = $grid.Rows.Add($p.AppName, $(if ($l) { $l.Version } else { '' }), $(if ($p.LaunchKind) { $p.LaunchKind } else { 'Not built' }),
                                    $(if ($l) { & $fmtTime $l.Time } else { '' }), $(if ($l) { $l.Path } else { "Build it on the Developer tab ($($p.Folder))" }))
                $row = $grid.Rows[$i]; $row.Tag = $p
                if (-not $l) { $row.DefaultCellStyle.ForeColor = $App.Theme.Muted }
                if ($keep -contains $p.Name) { $row.Selected = $true }
            }
        } finally { $grid.ResumeLayout() }
    }.GetNewClosure()

    $launch = {
        $p = @(& $selection -Grid $grid) | Select-Object -First 1
        if (-not $p) { $App.SetStatus('Select a tool first.', 'warn'); return }
        if (-not $p.Launch) { $App.SetStatus("$($p.AppName) is not built yet - build it on the Developer tab.", 'warn'); return }
        $exe = $p.Launch.Path
        $r = & $invoke -App $App -Title "Launch $($p.AppName)" -Kind Read -RunLabel 'Launch' `
            -Summary "Start $($p.AppName) v$($p.Launch.Version) ($($p.LaunchKind))." `
            -Code ('Start-Process -FilePath ' + (& $fmt $exe) + ' -WorkingDirectory ' + (& $fmt (Split-Path -Parent $exe)))
        if ($r.Errors.Count) { $App.SetStatus("Not started: $($r.Errors[0])", 'err') }
        elseif ($r.Ran) { $App.SetStatus("$($p.AppName) started.", 'ok') }
    }.GetNewClosure()

    $btnLaunch.Add_Click($launch)
    $grid.Add_CellDoubleClick({ param($s, $e) if ($e.RowIndex -ge 0) { & $launch } }.GetNewClosure())
    $btnFolder.Add_Click({
        $p = @(& $selection -Grid $grid) | Select-Object -First 1
        if (-not $p) { $App.SetStatus('Select a tool first.', 'warn'); return }
        & $openFolder -App $App -Path $(if ($p.Launch) { Split-Path -Parent $p.Launch.Path } else { $p.Folder })
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
