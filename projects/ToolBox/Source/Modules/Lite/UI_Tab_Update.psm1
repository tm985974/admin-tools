# UI_Tab_Update.psm1   (LITE TIER)
#
# Update tab: bring the tools' source up to date, then build them.
#   Open zip...    a zip of the admin-tools repository downloaded from GitHub
#                  (Code > Download ZIP, or a branch's zip): unpacked into
#                  AppData\Update, and the tools it carries listed with their
#                  version here and in the zip.
#   Apply update   each tool's Source folder is replaced from the zip (the old one
#                  is moved to <repo>\_Backup\Update_<time>), Build-App.cmd copied;
#                  template\ and tools\ too. EXEs, Build\, Archive\ and Update\
#                  are not touched. Then (ticked by default) Build all.
#   Pull (git)     only when the folder is a git clone: git pull.

function New-TbUpdateTab {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Windows.Forms.TabPage]$Page,
        [Parameter(Mandatory)] $App
    )
    $getFolders  = ${function:Get-TbFolders}           # captured: closures do not see module functions reliably
    $getProjects = ${function:Get-TbProjects}
    $newWork     = ${function:New-TbZipWorkFolder}
    $openCode    = ${function:Get-TbZipOpenCode}
    $zipInfo     = ${function:Get-TbZipInfo}
    $applyCode   = ${function:Get-TbZipApplyCode}
    $startBuild  = ${function:Start-TbBuild}
    $isBuilding  = ${function:Test-TbBuilding}
    $refreshAll  = ${function:Invoke-TbRefresh}
    $invoke      = ${function:Invoke-AppCommand}
    $settingsDir = ${function:Get-AppSettingsDir}
    $askPw       = ${function:Show-TbLitePasswordDialog}
    $state = @{ Info = $null; Zip = '' }

    $hdr = New-TbHeader -App $App -Text 'Update - new source for the tools, then build'

    $info = New-Object System.Windows.Forms.Label
    $info.Dock = 'Top'; $info.Height = 92; $info.AutoSize = $false; $info.ForeColor = $App.Theme.Text
    $info.Padding = New-Object System.Windows.Forms.Padding(2, 4, 2, 0)

    $bar = New-TbBar -App $App -Height 42
    $btnOpen  = $App.Theme.MakeButton('Open zip...')
    $btnApply = $App.Theme.MakeButton('Apply update'); $btnApply.Enabled = $false
    $btnApply.Font = New-Object System.Drawing.Font($btnApply.Font, [System.Drawing.FontStyle]::Bold)
    $chkBuild = New-Object System.Windows.Forms.CheckBox
    $chkBuild.Text = 'Build all after the update'; $chkBuild.Checked = $true; $chkBuild.AutoSize = $true
    $chkBuild.Margin = New-Object System.Windows.Forms.Padding(10, 9, 10, 0)
    $btnPull  = $App.Theme.MakeButton('Pull (git)'); $btnPull.Visible = $false
    $bar.Controls.AddRange(@($btnOpen, $btnApply, $chkBuild, $btnPull))

    $grid = New-TbGrid -App $App -Columns @('Tool', 'Here', 'In the zip', 'Change')

    $showInfo = {
        $f = & $getFolders -App $App
        $last = ''
        try {
            $p = Join-Path (& $settingsDir -App $App) 'ToolBoxUpdate.json'
            if (Test-Path -LiteralPath $p) { $j = [System.IO.File]::ReadAllText($p) | ConvertFrom-Json; $last = "$($j.When)  from  $($j.Zip)" }
        } catch { }
        $info.Text = "Projects folder:  $($f.Projects)`r`n" +
                     "Repository folder:  " + $(if ($f.Repo) { $f.Repo + $(if ($f.IsGit) { '   (a git clone: Pull works)' } else { '' }) } else { '(not an admin-tools\projects folder - Update from zip needs one)' }) + "`r`n" +
                     "Last update:  " + $(if ($last) { $last } else { '(none recorded)' }) + "`r`n`r`n" +
                     "Get the zip on GitHub: open the repository, pick the branch, then Code > Download ZIP. Then Open zip... here."
        $btnPull.Visible = [bool]$f.IsGit
    }.GetNewClosure()

    $btnOpen.Add_Click({
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Title = 'admin-tools zip downloaded from GitHub'; $dlg.Filter = 'Zip files (*.zip)|*.zip|All files (*.*)|*.*'
        $dlg.InitialDirectory = [Environment]::GetFolderPath('UserProfile') + '\Downloads'
        if ($dlg.ShowDialog() -ne 'OK') { $dlg.Dispose(); return }
        $zip = $dlg.FileName; $dlg.Dispose()
        $work = & $newWork -App $App
        $r = & $invoke -App $App -Title 'Open zip' -Kind Read -RunLabel 'Unpack' `
            -Summary "Unpack $([System.IO.Path]::GetFileName($zip)) into AppData to see what it changes. Nothing in the tools' folders changes yet." `
            -Code (& $openCode -Zip $zip -WorkFolder $work)
        if (-not $r.Ran) { return }
        if ($r.Errors.Count) { $App.SetStatus("Could not unpack: $($r.Errors[0])", 'err'); return }
        try { $zi = & $zipInfo -App $App -WorkFolder $work }
        catch { $App.SetStatus($_.Exception.Message, 'err'); return }
        $state.Info = $zi; $state.Zip = $zip
        $grid.Rows.Clear()
        foreach ($t in $zi.Tools) { [void]$grid.Rows.Add($t.Name, $t.Here, $t.InZip, $t.Change) }
        $changes = @($zi.Tools | Where-Object { $_.Change -ne 'Same version' }).Count
        $btnApply.Enabled = $true
        $App.SetStatus("$($zi.Tools.Count) tool(s) in the zip, $changes with a new version. Apply update to use it.", 'info')
    }.GetNewClosure())

    $btnApply.Add_Click({
        if (-not $state.Info) { return }
        if (& $isBuilding) { $App.SetStatus('Wait for the build to finish first.', 'warn'); return }
        $pw = $null
        if ($chkBuild.Checked) {                       # ask before anything changes, so Cancel leaves everything as it was
            $pw = & $askPw -App $App -Count @($state.Info.Tools).Count
            if (-not $pw) { return }
        }
        $f = & $getFolders -App $App
        if (-not $f.Repo) { $App.SetStatus('The projects folder is not admin-tools\projects - set Projects folder on the Environment tab.', 'err'); return }
        $sum = "Replace each tool's Source folder (and Build-App.cmd, template\, tools\, Build-All.cmd) with the zip's. " +
               "The replaced folders are moved to $($f.Repo)\_Backup. EXEs, Build\, Archive\ and Update\ stay." +
               $(if ($chkBuild.Checked) { ' Then build every tool.' } else { '' })
        $r = & $invoke -App $App -Title 'Apply update' -Kind Change -Always -RunLabel 'Apply' -Summary $sum -Code (& $applyCode -App $App -Info $state.Info)
        if (-not $r.Ran) { return }
        if ($r.Errors.Count) { $App.SetStatus("Update stopped: $($r.Errors[0]) (see Session.log; the _Backup folder has what was replaced)", 'err'); $App.Log('ERROR', 'Update', ($r.Errors -join ' | ')); return }
        try {
            $p = Join-Path (& $settingsDir -App $App) 'ToolBoxUpdate.json'
            (@{ When = (Get-Date).ToString('yyyy-MM-dd HH:mm'); Zip = [System.IO.Path]::GetFileName($state.Zip) } | ConvertTo-Json) | Set-Content -LiteralPath $p -Encoding UTF8
        } catch { }
        $App.LogAction("Update from zip: $($state.Zip)")
        $state.Info = $null; $btnApply.Enabled = $false
        & $showInfo
        & $refreshAll
        $App.SetStatus('Update applied.', 'ok')
        if ($chkBuild.Checked) {
            foreach ($tp in $Page.Parent.TabPages) { if ($tp.Text.Trim() -eq 'Developer') { $Page.Parent.SelectedTab = $tp; break } }
            if ($pw.Lite) { & $startBuild -App $App -Projects (@(& $getProjects -App $App)) -LiteUser $pw.User -LiteAdmin $pw.Admin }
            else { & $startBuild -App $App -Projects (@(& $getProjects -App $App)) }
        }
        $pw = $null
    }.GetNewClosure())

    $btnPull.Add_Click({
        $f = & $getFolders -App $App
        if (-not $f.IsGit) { return }
        $r = & $invoke -App $App -Title 'Pull (git)' -Kind Change -RunLabel 'Pull' `
            -Summary "Get the latest source from GitHub into $($f.Repo). Then use Build all on the Developer tab." `
            -Code ("git -C '" + $f.Repo.Replace("'", "''") + "' pull")
        if (-not $r.Ran) { return }
        $out = (@($r.Output) + @($r.Errors) | ForEach-Object { [string]$_ }) -join ' '
        $App.SetStatus($(if ($out) { "git: $out" } else { 'Pulled.' }), $(if ($r.Errors.Count) { 'warn' } else { 'ok' }))
        & $refreshAll
    }.GetNewClosure())

    Register-EnvironmentChangedHandler -Handler { param($a) & $showInfo }.GetNewClosure()

    $Page.Controls.Add($grid)
    $Page.Controls.Add($bar)
    $Page.Controls.Add($info)
    $Page.Controls.Add($hdr)
    & $showInfo
}
