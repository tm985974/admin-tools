# UI_Tab_Pipeline.psm1   (LITE TIER)
#
# Update Pipeline tab (ported from v8.4): the grid compares JSON / Incoming /
# Local / Repository / SCCM for every application of the ACTIVE environment's
# site and shows the next action. Step buttons act on the selected rows; with
# nothing selected they act on every row that needs that step.
# Right-click a row for the same steps, Copy JSON to environment, open folder /
# JSON. The activity log sits under the grid.

function New-SamPipelineTab {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Windows.Forms.TabPage]$Page,
        [Parameter(Mandatory)] $App
    )
    $Page.Tag = @{ SamView = 'Pipeline' }
    Set-LazyTabBuild -Page $Page -App $App -Build { param($Page, $App) Build-SamPipelineTab -Page $Page -App $App }
}

function Get-SamSelectedPipelineRows {
    $out = New-Object System.Collections.ArrayList
    $g = $global:SAM.PipeGrid
    if (-not $g) { return @() }
    foreach ($gr in ($g.SelectedRows | Sort-Object Index)) { if ($gr.Tag) { [void]$out.Add($gr.Tag) } }
    return $out.ToArray()
}

function Build-SamPipelineTab {
    param($Page, $App)
    $S = $global:SAM
    $Page.Padding = New-Object System.Windows.Forms.Padding(0)
    $Page.AutoScroll = $false

    $split = New-Object System.Windows.Forms.SplitContainer
    $split.Dock = 'Fill'
    $split.Orientation = 'Horizontal'
    $Page.Controls.Add($split)

    # ---- top band: environment / site / local root ----
    $info = New-Object System.Windows.Forms.Label
    $info.Dock = 'Top'; $info.Height = 24; $info.TextAlign = 'MiddleLeft'
    $info.Padding = New-Object System.Windows.Forms.Padding(6, 0, 0, 0)
    $info.Font = New-Object System.Drawing.Font($info.Font, [System.Drawing.FontStyle]::Bold)
    $S.PipeInfo = $info

    # ---- buttons ----
    $bar = New-SamToolbar
    $stepTip = 'Runs for the selected rows. With nothing selected, runs for every row that needs this step.'
    $btnScan   = New-SamButton 'Scan / Refresh' 120 $global:SamClrInfo 'Re-read the JSON files and compare Incoming / Local / Repository / SCCM'
    $btnPull   = New-SamButton $global:SamActPull   170 ([System.Drawing.Color]::Honeydew) $stepTip
    $btnJson   = New-SamButton $global:SamActJson   140 ([System.Drawing.Color]::Honeydew) $stepTip
    $btnUpload = New-SamButton $global:SamActUpload 180 ([System.Drawing.Color]::Honeydew) $stepTip
    $btnCreate = New-SamButton $global:SamActCreate 150 ([System.Drawing.Color]::Honeydew) $stepTip
    $btnDeploy = New-SamButton '5. Deploy...' 120 ([System.Drawing.Color]::MistyRose) 'Deploy window (collection, Required/Available, time). Selected rows; with nothing selected, every app not yet deployed to the test collection.'
    $btnCopy   = New-SamButton 'Copy JSON to environment...' 200 $null 'Make a JSON for another site from the selected rows (paths re-pointed, reviewed first)'
    $btnSelAll = New-SamButton 'Select All' 90
    $btnSelNone = New-SamButton 'Clear Selection' 110
    foreach ($b in @($btnScan, $btnPull, $btnJson, $btnUpload, $btnCreate, $btnDeploy, $btnCopy, $btnSelAll, $btnSelNone)) { $bar.Controls.Add($b) }
    foreach ($b in @($btnScan, $btnPull, $btnJson, $btnUpload, $btnCreate, $btnDeploy, $btnCopy)) { [void]$S.ActionControls.Add($b) }

    $btnScan.Add_Click({
        $global:SAM.ConnectFailedFor = ''
        Invoke-SamAction 'Scan pipeline' { Invoke-SamPipelineScan; $global:SAM.ScannedEnv = $global:SAM.Settings.EnvName }
        if ($global:SAM.Settings.SiteCode) {
            Invoke-SamAction 'Refresh SCCM data' -NeedSccm { Invoke-SamReloadAll -SkipDevices }
        }
    })
    $btnPull.Add_Click({   $sel = Get-SamSelectedPipelineRows; Invoke-SamAction 'Pull from Incoming'   { Invoke-SamPullFromIncoming -Selected $sel }.GetNewClosure() })
    $btnJson.Add_Click({   $sel = Get-SamSelectedPipelineRows; Invoke-SamAction 'Update JSON'          { Invoke-SamUpdateJson -Selected $sel }.GetNewClosure() })
    $btnUpload.Add_Click({ $sel = Get-SamSelectedPipelineRows; Invoke-SamAction 'Upload to Repository' { Invoke-SamUploadToRepository -Selected $sel }.GetNewClosure() })
    $btnCreate.Add_Click({ $sel = Get-SamSelectedPipelineRows; Invoke-SamAction 'Create in SCCM' -NeedSccm { Invoke-SamCreateInSccm -Selected $sel }.GetNewClosure() })
    $btnDeploy.Add_Click({ $sel = Get-SamSelectedPipelineRows; Invoke-SamAction 'Deploy' -NeedSccm { Invoke-SamPipelineDeploy -Selected $sel }.GetNewClosure() })
    $btnCopy.Add_Click({   $sel = Get-SamSelectedPipelineRows; Invoke-SamAction 'Copy JSON to environment' { Copy-SamJsonToEnvironment -Rows $sel }.GetNewClosure() })

    # ---- grid ----
    $g = New-Object System.Windows.Forms.DataGridView
    $g.Dock = 'Fill'
    $g.ReadOnly = $true
    $g.AllowUserToAddRows = $false
    $g.AllowUserToDeleteRows = $false
    $g.AllowUserToResizeRows = $false
    $g.SelectionMode = 'FullRowSelect'
    $g.MultiSelect = $true
    $g.AutoSizeColumnsMode = 'Fill'
    $g.RowHeadersVisible = $false
    $g.BackgroundColor = [System.Drawing.Color]::White
    $g.DefaultCellStyle.SelectionBackColor = [System.Drawing.Color]::SteelBlue
    try { $g.GetType().GetProperty('DoubleBuffered', [System.Reflection.BindingFlags]'Instance,NonPublic').SetValue($g, $true, $null) } catch { }
    foreach ($c in @(
            @('App', 'Application', 22), @('Json', 'JSON Version', 9), @('Incoming', 'Incoming (Network)', 10),
            @('Local', 'Local', 9), @('Repo', 'Repository', 13), @('Sccm', 'SCCM', 13),
            @('Deploys', 'Deploys', 6), @('Test', 'Test Deployed', 7), @('Next', 'Next Action', 16), @('File', 'JSON file', 12))) {
        $col = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
        $col.Name = $c[0]; $col.HeaderText = $c[1]; $col.FillWeight = $c[2]
        [void]$g.Columns.Add($col)
    }
    $S.PipeGrid = $g
    $btnSelAll.Add_Click({ $global:SAM.PipeGrid.SelectAll() })
    $btnSelNone.Add_Click({ $global:SAM.PipeGrid.ClearSelection() })
    $g.Add_CellDoubleClick({ param($s, $e)
        if ($e.RowIndex -lt 0) { return }
        $r = $s.Rows[$e.RowIndex].Tag
        if ($r) { Open-SamLocalFolder $r }
    })
    $g.Add_CellMouseDown({ param($s, $e)
        if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Right -or $e.RowIndex -lt 0) { return }
        $row = $s.Rows[$e.RowIndex]
        if (-not $row.Selected) { $s.ClearSelection(); $row.Selected = $true }
    })
    $g.Add_KeyDown({ param($s, $e) if ($e.KeyCode -eq 'F5') { $btnScan.PerformClick() } }.GetNewClosure())

    # ---- right-click menu ----
    $cms = New-Object System.Windows.Forms.ContextMenuStrip
    $add = {
        param([string]$Text, [scriptblock]$Do, [switch]$Bold)
        $mi = New-Object System.Windows.Forms.ToolStripMenuItem($Text)
        if ($Bold) { $mi.Font = New-Object System.Drawing.Font($mi.Font, [System.Drawing.FontStyle]::Bold) }
        $mi.Add_Click($Do)
        [void]$cms.Items.Add($mi)
    }
    & $add $global:SamActPull   { $btnPull.PerformClick() }.GetNewClosure()
    & $add $global:SamActJson   { $btnJson.PerformClick() }.GetNewClosure()
    & $add $global:SamActUpload { $btnUpload.PerformClick() }.GetNewClosure()
    & $add $global:SamActCreate { $btnCreate.PerformClick() }.GetNewClosure()
    & $add '5. Deploy...'       { $btnDeploy.PerformClick() }.GetNewClosure()
    [void]$cms.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    & $add 'Copy JSON to environment...' { $btnCopy.PerformClick() }.GetNewClosure()
    & $add 'Open local folder' { $r = @(Get-SamSelectedPipelineRows); if ($r.Count) { Open-SamLocalFolder $r[0] } }
    & $add 'Open repository folder' { $r = @(Get-SamSelectedPipelineRows); if ($r.Count) { Open-SamRepoFolder $r[0] } }
    & $add 'Open JSON in Notepad' { $r = @(Get-SamSelectedPipelineRows); if ($r.Count) { Open-SamPath -Path $r[0].JsonPath -Exe 'notepad.exe' -Title 'Open JSON in Notepad' } }
    & $add 'Show in Software tab' { $r = @(Get-SamSelectedPipelineRows); if ($r.Count) { Show-SamInSoftwareTab $r[0].AppName } }
    & $add 'Copy application name(s)' { Set-SamClipboard @(Get-SamSelectedPipelineRows | ForEach-Object { $_.AppName }) }
    $cms.Add_Opening({ param($s, $e)
        if ($global:SAM.PipeGrid.SelectedRows.Count -eq 0) { $e.Cancel = $true; return }
        foreach ($it in $s.Items) { if ($it -is [System.Windows.Forms.ToolStripMenuItem]) { $it.Enabled = -not $global:SAM.Busy } }
    })
    $g.ContextMenuStrip = $cms

    $sum = New-Object System.Windows.Forms.Label
    $sum.Dock = 'Bottom'; $sum.Height = 22; $sum.TextAlign = 'MiddleLeft'
    $S.PipeSummary = $sum
    $legend = New-Object System.Windows.Forms.Label
    $legend.Dock = 'Bottom'; $legend.Height = 20; $legend.ForeColor = [System.Drawing.Color]::DimGray
    $legend.Text = 'Yellow = newer version waiting / step needed    Red = missing or error    Green = done.    Double-click a row to open its local folder; right-click for more.'

    $split.Panel1.Controls.Add($g)
    $split.Panel1.Controls.Add($bar)
    $split.Panel1.Controls.Add($info)
    $split.Panel1.Controls.Add($legend)
    $split.Panel1.Controls.Add($sum)

    # ---- activity log ----
    $lblLog = New-Object System.Windows.Forms.Label
    $lblLog.Text = 'Activity log  (purple PERF lines = timings)'; $lblLog.Dock = 'Top'; $lblLog.Height = 20
    $lblLog.Font = New-Object System.Drawing.Font($lblLog.Font, [System.Drawing.FontStyle]::Bold)
    $box = New-SamLogBox
    $box.Dock = 'Fill'
    $split.Panel2.Controls.Add($box)
    $split.Panel2.Controls.Add($lblLog)
    $setSplit = { try { $split.SplitterDistance = [Math]::Max(250, $split.Height - 220) } catch { } }.GetNewClosure()
    $Page.Add_Layout({ if (-not $split.Tag) { & $setSplit; if ($split.Height -gt 300) { $split.Tag = 'set' } } }.GetNewClosure())

    $S.Views['Pipeline'] = { Show-SamPipelineGrid }

    # Load on first view and after an environment switch (Register-SamTabWatcher)
    $Page.Tag['SamEnsure'] = {
        $S2 = $global:SAM
        if ($S2.Busy) { return }
        $rescan = $S2.Settings.ReloadOnTabSelect -and (-not $S2.ScannedAt -or ((Get-Date) - $S2.ScannedAt).TotalSeconds -gt 5)
        if ($S2.ScannedEnv -ne $S2.Settings.EnvName -or ($rescan -and [IO.Directory]::Exists([string]$S2.Settings.LocalRootResolved))) {
            if ([IO.Directory]::Exists([string]$S2.Settings.LocalRootResolved)) {
                Invoke-SamAction 'Scan pipeline' { Invoke-SamPipelineScan; $global:SAM.ScannedEnv = $global:SAM.Settings.EnvName }
            }
            else {
                Write-SamLog "Local Root '$($S2.Settings.LocalRootResolved)' does not exist. Set Local Root on Environment > SCCM Site." -Level Warning
                $S2.ScannedEnv = $S2.Settings.EnvName
            }
        }
        if (-not $S2.Cache.Loaded -and $S2.Settings.SiteCode -and -not (Test-SamAutoConnectBlocked)) {
            Invoke-SamAction "Connect to site $($S2.Settings.SiteCode)" -NeedSccm {
                foreach ($r in $global:SAM.Rows) { Update-SamRowSccmStatus $r }
                Update-SamDeviceCounts
                Invoke-SamRenderViews
            }
        }
        elseif ($S2.Cache.Loaded -and $S2.Settings.ReloadOnTabSelect -and (Test-SamDataStale)) {
            Invoke-SamAction "Refresh site $($S2.Settings.SiteCode)" -NeedSccm {
                Update-SamCoreCache
                Update-SamDeviceCounts
                foreach ($r in $global:SAM.Rows) { Update-SamRowSccmStatus $r }
                Invoke-SamRenderViews
            }
        }
        Show-SamPipelineGrid
    }
    $Page.Tag['SamBuilt'] = $true
    Show-SamPipelineGrid
    # First view: load right after the build, without depending on the
    # tab-changed event (a short timer runs once the build has returned).
    Start-SamFirstLoad -Page $Page
}

function Invoke-SamPipelineDeploy {
    param($Selected)
    $sel = @($Selected | Where-Object { $_ })
    if ($sel.Count) {
        foreach ($r in $sel) { if (-not $r.AppExists) { Write-SamLog "  Skipping $($r.BaseName): '$($r.AppName)' is not in SCCM yet" -Level Warning } }
        $rows = @($sel | Where-Object { $_.AppExists })
    }
    else { $rows = @(Get-SamTargetRows $global:SamActDeploy ${function:Test-SamCanDeploy} @()) }
    Invoke-SamDeployApps -AppNames @($rows | ForEach-Object { $_.AppName })
}

function Open-SamLocalFolder {
    param($Row)
    $p = [IO.Path]::Combine($global:SAM.Settings.LocalRootResolved, $Row.BaseName)
    if ([IO.Directory]::Exists($p)) { Open-SamPath -Path $p -Title 'Open local folder' }
    else { Write-SamLog "Folder not found: $p" -Level Warning }
}

function Open-SamRepoFolder {
    param($Row)
    $p = [IO.Path]::Combine([string]$global:SAM.Settings.RepositoryPath, $Row.BaseName)
    if ($global:SAM.Settings.RepositoryPath -and [IO.Directory]::Exists($p)) { Open-SamPath -Path $p -Title 'Open repository folder' }
    else { Write-SamLog "Folder not found: $p" -Level Warning }
}

# Selects an application on the Software tab and switches to it.
function Show-SamInSoftwareTab {
    param([string]$AppName)
    $tabs = $global:SAM.Tabs
    if (-not $tabs -or -not $AppName) { return }
    foreach ($p in $tabs.TabPages) {
        if ($p.Tag -is [hashtable] -and $p.Tag['SamView'] -eq 'Software') {
            $tabs.SelectedTab = $p
            $find = {
                $grid = $null
                foreach ($c in $p.Controls) { if ($c -is [System.Windows.Forms.DataGridView]) { $grid = $c } }
                if (-not $grid) { return }
                $grid.ClearSelection()
                foreach ($r in $grid.Rows) {
                    $drv = $r.DataBoundItem
                    if ($drv -and [string]$drv.Row['Name'] -eq $AppName) { $r.Selected = $true; $grid.FirstDisplayedScrollingRowIndex = $r.Index; break }
                }
            }.GetNewClosure()
            try { [void]$tabs.BeginInvoke([System.Windows.Forms.MethodInvoker]$find) } catch { }
            return
        }
    }
}

function Show-SamPipelineGrid {
    $S = $global:SAM
    $g = $S.PipeGrid
    if (-not $g -or $g.IsDisposed) { return }
    $st = $S.Settings
    if ($S.PipeInfo) {
        $conn = if ($S.Connected) { "connected to $($st.SiteServer)" } elseif ($st.SiteCode) { 'not connected' } else { 'no site set' }
        $hid = if ($S.HiddenJson) { "    |    $($S.HiddenJson) JSON file(s) of other sites hidden" } else { '' }
        $S.PipeInfo.Text = "$($st.EnvLabel)  -  site $($st.SiteCode) ($conn)    |    Local Root: $($st.LocalRootResolved)    |    Repository: $($st.RepositoryPath)$hid"
        $S.PipeInfo.ForeColor = if ($S.Connected) { [System.Drawing.Color]::DarkGreen } else { [System.Drawing.Color]::Firebrick }
    }
    $keep = @{}
    foreach ($sr in $g.SelectedRows) { if ($sr.Tag) { $keep[$sr.Tag.JsonPath] = $true } }
    $connected = $S.Connected
    $bold = New-Object System.Drawing.Font($g.Font, [System.Drawing.FontStyle]::Bold)

    $g.SuspendLayout()
    $g.Rows.Clear()
    foreach ($r in ($S.Rows.ToArray() | Sort-Object BaseName)) {
        $repoTxt = if (-not $r.JsonVersion) { '' } elseif ($r.RepoHasJsonVersion) { "Yes ($($r.JsonVersion))" } else { 'MISSING' + $(if ($r.RepoLatest) { " (has $($r.RepoLatest))" } else { '' }) }
        $sccmTxt = if (-not $connected) { '-' } elseif ($r.AppExists) { 'Exists' } else { 'Not created' + $(if ($r.SccmLatest) { " (latest $($r.SccmLatest))" } else { '' }) }
        $depTxt  = if ($connected -and $r.AppExists) { [string]$r.Deployments } else { '-' }
        $testTxt = if (-not $connected -or -not $r.AppExists) { '-' } elseif ($r.TestDeployed) { 'Yes' } else { 'No' }
        $fileTxt = $r.JsonFile + $(if (-not $r.Site) { '  (untagged)' } else { '' })
        $vals = [object[]]@($r.BaseName, (Format-SamVer $r.JsonVersion), (Format-SamVer $r.IncomingVersion), (Format-SamVer $r.LocalVersion), $repoTxt, $sccmTxt, $depTxt, $testTxt, $r.NextAction, $fileTxt)
        $idx = $g.Rows.Add($vals)
        $gr = $g.Rows[$idx]
        $gr.Tag = $r

        if ($r.Error) { $gr.DefaultCellStyle.BackColor = $global:SamClrBad; continue }
        if (Test-SamCanPull $r)       { $gr.Cells['Incoming'].Style.BackColor = $global:SamClrWarn }
        if (Test-SamCanUpdateJson $r) { $gr.Cells['Local'].Style.BackColor = $global:SamClrWarn }
        $gr.Cells['Repo'].Style.BackColor = if ($r.RepoHasJsonVersion) { $global:SamClrGood } else { $global:SamClrBad }
        if ($connected) {
            $gr.Cells['Sccm'].Style.BackColor = if ($r.AppExists) { $global:SamClrGood } else { $global:SamClrWarn }
            if ($r.AppExists) { $gr.Cells['Test'].Style.BackColor = if ($r.TestDeployed) { $global:SamClrGood } else { $global:SamClrWarn } }
        }
        $next = $gr.Cells['Next']
        $next.Style.Font = $bold
        $next.Style.BackColor = if ($r.NextAction -like '*NEWER*') { $global:SamClrBad } elseif ($r.NextAction -eq $global:SamActDone) { $global:SamClrGood } elseif ($r.NextAction -match '^\d\.') { $global:SamClrWarn } else { $global:SamClrBad }
    }
    $g.ClearSelection()
    foreach ($gr in $g.Rows) { if ($gr.Tag -and $keep[$gr.Tag.JsonPath]) { $gr.Selected = $true } }
    $g.ResumeLayout()

    if ($S.PipeSummary) {
        $summary = ($S.Rows.ToArray() | Group-Object NextAction | Sort-Object Name | ForEach-Object { '{0}: {1}' -f $_.Name, $_.Count }) -join '    |    '
        $S.PipeSummary.Text = "$($S.Rows.Count) application(s)    |    $summary"
    }
}
