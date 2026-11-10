# UI_SamGridTab.psm1   (LITE TIER)
#
# The common layout of the Software, Collections and Devices tabs:
#
#   [Refresh] [tab buttons...] Filter: [______]  1234 total   [Export CSV] [Activity...]   Site A30 @ server
#   +-------------------------------------------------------------------------------+
#   |  grid: every row shown by default, click a header to sort, right-click menu   |
#   +-------------------------------------------------------------------------------+
#
#   New-SamGridTab -Page -App -View 'Devices' -Columns @(...) -Key 'ResourceID'
#                  -GetItems { <objects> } [-NeedDevices] [-ColorRules] [-GrayColumn]
#                  -Menu @( @{ Text; Click = { param($Sel) }; Dialog; Single; Admin = 'Fn' }, @{ Separator = $true }, ... )
#                  -Buttons @( @{ Text; Width; Color; Tip; Click = { param($Sel) }; Dialog; NoSelection; Admin } )
#                  -DoubleClick { param($Item) }
#
# Menu / button Click gets the selected source objects. Actions run through
# Invoke-SamAction (connects first, one at a time); Dialog = $true runs them
# directly (detail windows, which run their own actions). Admin = the name of
# an admin-tier function: the entry is only added when that function exists.
#
# Loading: the first time the tab is shown, and whenever the environment has
# changed, Register-SamTabWatcher connects and loads what the tab needs.

function New-SamGridTab {
    param(
        $Page, $App,
        [string]$View,
        $Columns,
        [string]$Key = '',
        [scriptblock]$GetItems,
        [switch]$NeedDevices,
        $ColorRules = $null,
        [string]$GrayColumn = '',
        $Menu = @(),
        $Buttons = @(),
        [scriptblock]$DoubleClick = $null
    )
    $S = $global:SAM
    $Page.Padding = New-Object System.Windows.Forms.Padding(0)
    $Page.AutoScroll = $false

    $bar = New-SamToolbar
    $btnRefresh = New-SamButton 'Refresh' 90 $global:SamClrInfo 'Reload from SCCM (F5)'
    $bar.Controls.Add($btnRefresh)
    [void]$S.ActionControls.Add($btnRefresh)

    $g = New-SamDataGrid -Columns $Columns -Key $Key -Multi -ColorRules $ColorRules -GrayColumn $GrayColumn
    $g.Grid.Dock = 'Fill'

    $runItem = {
        param($Spec, $Grid)
        $sel = @(Get-SamGridSelected -G $Grid)
        if (-not $Spec.NoSelection -and -not $sel.Count) { Write-SamLog "$($Spec.Text): select one or more rows first." -Level Warning; return }
        if ($Spec.Single -and $sel.Count -gt 1) { $sel = @($sel[0]) }
        $click = $Spec.Click
        $label = ([string]$Spec.Text).Replace('...', '').Replace('&&', '&')
        if ($Spec.Dialog) {
            Invoke-SamSafe $label {
                if (-not $global:SAM.Cache.Loaded -and -not (Assert-SamConnected)) { return }
                & $click $sel
            }
        }
        else { Invoke-SamAction $label -NeedSccm { & $click $sel } }
    }

    foreach ($b in @($Buttons)) {
        if (-not $b) { continue }
        if ($b.Admin -and -not (Get-Command $b.Admin -ErrorAction SilentlyContinue)) { continue }
        $btn = New-SamButton $b.Text $(if ($b.Width) { [int]$b.Width } else { 130 }) $b.Color $b.Tip
        $spec = $b
        $btn.Add_Click({ & $runItem $spec $g }.GetNewClosure())
        $bar.Controls.Add($btn)
        [void]$S.ActionControls.Add($btn)
    }

    [void](Add-SamToolbarLabel $bar 'Name filter:')
    $txt = New-Object System.Windows.Forms.TextBox
    if (-not $S.ToolTip) { $S.ToolTip = New-Object System.Windows.Forms.ToolTip }
    $S.ToolTip.SetToolTip($txt, 'Filters the first column. * = any text, ? = one character, e.g. ivn-*-ic')
    $txt.Width = 240; $txt.Margin = New-Object System.Windows.Forms.Padding(3, 7, 3, 0)
    $bar.Controls.Add($txt)
    $lbl = Add-SamToolbarLabel $bar ''
    $lbl.MinimumSize = New-Object System.Drawing.Size(150, 0)
    $btnCsv = New-SamButton 'Export CSV...' 105
    $btnCsv.Add_Click({ Export-SamGridCsv -G $g -Name "$View $($global:SAM.Settings.SiteCode)" }.GetNewClosure())
    $bar.Controls.Add($btnCsv)
    $btnAct = New-SamButton 'Activity...' 90
    $btnAct.Add_Click({ Show-SamActivityWindow })
    $bar.Controls.Add($btnAct)
    $lblSite = Add-SamToolbarLabel $bar '' -Bold
    $lblSite.ForeColor = $App.Theme.Section

    # ---- right-click menu ----
    $cms = New-Object System.Windows.Forms.ContextMenuStrip
    $lastWasSep = $true
    foreach ($m in @($Menu)) {
        if (-not $m) { continue }
        if ($m.Separator) { if (-not $lastWasSep) { [void]$cms.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)); $lastWasSep = $true }; continue }
        if ($m.Admin -and -not (Get-Command $m.Admin -ErrorAction SilentlyContinue)) { continue }
        $mi = New-Object System.Windows.Forms.ToolStripMenuItem([string]$m.Text)
        if ($m.Bold) { $mi.Font = New-Object System.Drawing.Font($mi.Font, [System.Drawing.FontStyle]::Bold) }
        $spec = $m
        $mi.Add_Click({ & $runItem $spec $g }.GetNewClosure())
        [void]$cms.Items.Add($mi)
        $lastWasSep = $false
    }
    $cms.Add_Opening({
        param($s, $e)
        $n = $g.Grid.SelectedRows.Count
        if ($n -eq 0) { $e.Cancel = $true; return }
        foreach ($it in $s.Items) {
            if ($it -is [System.Windows.Forms.ToolStripMenuItem]) { $it.Enabled = -not $global:SAM.Busy }
        }
    }.GetNewClosure())
    $g.Grid.ContextMenuStrip = $cms

    if ($DoubleClick) {
        $dbl = $DoubleClick
        $g.Grid.Add_CellDoubleClick({
            param($s, $e)
            if ($e.RowIndex -lt 0) { return }
            $drv = $s.Rows[$e.RowIndex].DataBoundItem
            if (-not $drv) { return }
            $item = $drv.Row['__Obj']
            Invoke-SamSafe "$View double-click" { & $dbl $item }
        }.GetNewClosure())
    }

    $Page.Controls.Add($g.Grid)
    $Page.Controls.Add($bar)

    # ---- filter ----
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 250
    $timer.Add_Tick({ $timer.Stop(); Set-SamGridFilter -G $g -Text $txt.Text -CountLabel $lbl }.GetNewClosure())
    $txt.Add_TextChanged({ $timer.Stop(); $timer.Start() }.GetNewClosure())
    $txt.Add_KeyDown({ param($s, $e) if ($e.KeyCode -eq 'Enter') { $e.SuppressKeyPress = $true; $timer.Stop(); Set-SamGridFilter -G $g -Text $txt.Text -CountLabel $lbl } }.GetNewClosure())
    Register-SamGridCount -G $g -CountLabel $lbl

    # ---- render from the caches ----
    $render = {
        $items = @(& $GetItems)
        Set-SamGridData -G $g -Items $items
        Set-SamGridFilter -G $g -Text $txt.Text -CountLabel $lbl
        $st = $global:SAM.Settings
        $lblSite.Text = if ($global:SAM.Connected) { "Site $($st.SiteCode) @ $($st.SiteServer)" }
                        elseif ($st.SiteCode) { "Site $($st.SiteCode) - not connected" } else { 'No site set' }
        $lblSite.ForeColor = if ($global:SAM.Connected) { [System.Drawing.Color]::DarkGreen } else { [System.Drawing.Color]::Firebrick }
    }.GetNewClosure()
    $S.Views[$View] = $render

    $needDev = [bool]$NeedDevices
    $btnRefresh.Add_Click({
        $global:SAM.ConnectFailedFor = ''
        Invoke-SamAction "Refresh ($View)" -NeedSccm { Invoke-SamReloadAll -Devices:$needDev }
    }.GetNewClosure())
    $g.Grid.Add_KeyDown({ param($s, $e) if ($e.KeyCode -eq 'F5') { $btnRefresh.PerformClick() } }.GetNewClosure())

    # What the tab watcher calls whenever this tab is shown
    $ensure = {
        $S2 = $global:SAM
        if ($S2.Busy) { return }
        $need = (-not $S2.Cache.Loaded) -or ($needDev -and -not $S2.DeviceCache)
        # Reload on every visit (Environment > SCCM Site) unless loaded in the last few seconds
        $fresh = (-not $need) -and $S2.Settings.ReloadOnTabSelect -and (Test-SamDataStale -Devices:$needDev)
        if (-not $need -and -not $fresh) { & $render; return }
        if (Test-SamAutoConnectBlocked) { & $render; return }   # failed moments ago - Refresh retries now
        $label = if ($fresh) { "Reload $View" } else { "Load $View" }
        Invoke-SamAction $label -NeedSccm {
            if ($fresh) {
                if (Test-SamDataStale) { Update-SamCoreCache }
                if ($needDev) { Update-SamDeviceCache }
            }
            elseif ($needDev -and -not $global:SAM.DeviceCache) { Update-SamDeviceCache }
            Update-SamDeviceCounts
            foreach ($r in $global:SAM.Rows) { Update-SamRowSccmStatus $r }
            Invoke-SamRenderViews
        }
        & $render
    }.GetNewClosure()
    $Page.Tag['SamEnsure'] = $ensure
    $Page.Tag['SamBuilt'] = $true
    & $render
    # First view: load right after the build, without depending on the
    # tab-changed event (a short timer runs once the build has returned).
    Start-SamFirstLoad -Page $Page
    return $g
}

# Runs the shown tab's SamEnsure (after it is built) - first view and every later view.
function Register-SamTabWatcher {
    param([System.Windows.Forms.TabControl]$Tabs)
    $global:SAM.Tabs = $Tabs
    $Tabs.Add_SelectedIndexChanged({
        $p = $Tabs.SelectedTab
        if (-not $p -or -not ($p.Tag -is [hashtable])) { return }
        $run = { Invoke-SamTabEnsure -Tabs $Tabs -Page $p }.GetNewClosure()
        try { [void]$Tabs.BeginInvoke([System.Windows.Forms.MethodInvoker]$run) } catch { }
    }.GetNewClosure())

    # Startup: whichever SCCM tab is showing ~1 s after launch gets loaded,
    # even if its first selection happened before this handler existed.
    $kick = New-Object System.Windows.Forms.Timer
    $kick.Interval = 1000
    $kick.Add_Tick({
        $kick.Stop(); $kick.Dispose()
        $p = $Tabs.SelectedTab
        if ($p -and ($p.Tag -is [hashtable])) { Invoke-SamTabEnsure -Tabs $Tabs -Page $p }
    }.GetNewClosure())
    $kick.Start()
}

# True when the core cache (and with -Devices the device cache) was loaded more
# than $Seconds ago - used by "reload every time a tab is selected".
function Test-SamDataStale {
    param([switch]$Devices, [int]$Seconds = 5)
    $S = $global:SAM
    $now = Get-Date
    if (-not $S.Cache.LoadedAt -or ($now - $S.Cache.LoadedAt).TotalSeconds -gt $Seconds) { return $true }
    if ($Devices -and (-not $S.DeviceCache -or -not $S.DeviceCache.LoadedAt -or ($now - $S.DeviceCache.LoadedAt).TotalSeconds -gt $Seconds)) { return $true }
    return $false
}
# Runs a tab's load (SamEnsure) if it is still the selected tab. While another
# operation is running (Busy) it waits and runs as soon as that finishes, so a tab
# opened during the startup load still fills itself.
function Invoke-SamTabEnsure {
    param($Tabs, $Page)
    if (-not $Tabs -or $Tabs.SelectedTab -ne $Page) { return }
    $ens = $Page.Tag['SamEnsure']
    if (-not $ens) { return }
    try { $global:SAM.App.Log('DIAG', 'SAM', "Tab load: $($Page.Text.Trim()) (busy=$($global:SAM.Busy))") } catch { }
    if (-not $global:SAM.Busy) {
        try { & $ens } catch { Write-SamLog "Loading $($Page.Text.Trim()): $($_.Exception.Message)" -Level Error }
        return
    }
    if ($Page.Tag['SamWaiting']) { return }
    $Page.Tag['SamWaiting'] = $true
    $state = @{ N = 0 }
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 300
    $timer.Add_Tick({
        $state.N++
        if ($global:SAM.Busy -and $state.N -lt 2000) { return }     # wait up to ~10 minutes
        $timer.Stop(); $timer.Dispose()
        $Page.Tag['SamWaiting'] = $false
        Invoke-SamTabEnsure -Tabs $Tabs -Page $Page
    }.GetNewClosure())
    $timer.Start()
}
# One-shot timer: runs the tab's load ~200 ms after its first build.
function Start-SamFirstLoad {
    param($Page)
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 200
    $timer.Add_Tick({
        $timer.Stop(); $timer.Dispose()
        Invoke-SamTabEnsure -Tabs $global:SAM.Tabs -Page $Page
    }.GetNewClosure())
    $timer.Start()
}