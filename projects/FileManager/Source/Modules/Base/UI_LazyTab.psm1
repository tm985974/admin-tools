# UI_LazyTab.psm1   (BASE TIER)
#
# Build-on-first-view tabs.
#
#   Enable-LazyTabActivation -Tabs $MainTabs -App $App
#       Called once by the tab registrar. Whenever the selected tab changes it
#       clears the status message, and the FIRST time a tab is selected it runs
#       that tab's  $Page.Tag.OnActivate  block. After the block has built the
#       tab, the activation is REPLAYED once (Selected / SelectedIndexChanged on
#       the main TabControl, then focus into the page so Enter fires), because a
#       tab built during its own first selection would otherwise miss those
#       events: code that wires $Tab.Parent.Add_Selected(...) or
#       $Tab.Add_Enter(...) while building (common in ported tools, whose tabs
#       were built at startup) still sees its first visit. Set
#       $Page.Tag.NoReplay = $true to skip the replay for a tab.
#
#   Set-LazyTabBuild -Page $Page -App $App -Build { param($Page, $App) ... }
#       Standard lazy tab: shows a "loading on first view" note, and on first
#       view clears it, turns on AutoScroll (fixed-size layouts scroll instead
#       of clipping), runs -Build with a wait cursor, and turns any exception
#       into a red message on the tab plus a full stack in Session.log.
#       -Build is invoked as  & $Build $Page $App  - keep it a plain script
#       block (no .GetNewClosure()) if it relies on its module's $script: state.
#
#   Invoke-LazyTabWarmup -Tabs $MainTabs -App $App [-Titles 'A','B']
#       Builds the listed lazy tabs that have not been viewed yet, one per timer
#       tick in the background (the window keeps painting between them). Use it
#       when tabs depend on each other's controls - e.g. an action on one tab
#       that fills in a form on another - so they all exist after the first
#       one is opened, as they would in an app that builds everything at start.
#       No -Titles = every lazy tab. A tab the user opens first is skipped.
#       On a warmed tab's first real visit, focus is moved into the page once
#       so its Enter handlers run.

function Enable-LazyTabActivation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Windows.Forms.TabControl]$Tabs,
        [Parameter(Mandatory)] $App
    )
    $state = @{ Replaying = $false }

    $Tabs.Add_SelectedIndexChanged({
        if ($state.Replaying) { return }
        try { $App.SetStatus('') } catch { }

        $p = $Tabs.SelectedTab
        if (-not ($p -and ($p.Tag -is [hashtable]))) { return }

        # A tab built in the background (Invoke-LazyTabWarmup) gets its first
        # real visit here: its Selected hooks fire on their own, so only make
        # sure focus enters the page once (its Enter handlers load data).
        if ($p.Tag['Warmed'] -and -not $p.Tag['Visited']) {
            $p.Tag['Visited'] = $true
            $focus = { try { if ($Tabs.SelectedTab -eq $p -and -not $p.ContainsFocus) { [void]$p.SelectNextControl($null, $true, $true, $true, $false) } } catch { } }.GetNewClosure()
            try { [void]$Tabs.BeginInvoke([System.Windows.Forms.MethodInvoker]$focus) } catch { }
            return
        }
        if (-not ($p.Tag.ContainsKey('OnActivate') -and -not $p.Tag['Activated'])) { return }
        $p.Tag['Activated'] = $true
        try { & $p.Tag['OnActivate'] }
        catch { if ($App) { $App.Log('ERROR', 'Tabs', "$($p.Text) activate: $($_.Exception.ToString())") } }
        if ($p.Tag['NoReplay']) { return }

        # Replay the first activation once the build has finished (queued, so it
        # runs after this handler and any focus change WinForms does itself).
        $replay = {
            if ($Tabs.SelectedTab -ne $p) { return }
            $state.Replaying = $true
            try {
                $bf  = [System.Reflection.BindingFlags]'Instance,NonPublic'
                $idx = $Tabs.TabPages.IndexOf($p)
                $ea  = New-Object System.Windows.Forms.TabControlEventArgs($p, $idx, [System.Windows.Forms.TabControlAction]::Selected)
                $m = [System.Windows.Forms.TabControl].GetMethod('OnSelected', $bf)
                if ($m) { [void]$m.Invoke($Tabs, [object[]]@($ea)) }
                $m = [System.Windows.Forms.TabControl].GetMethod('OnSelectedIndexChanged', $bf)
                if ($m) { [void]$m.Invoke($Tabs, [object[]]@([System.EventArgs]::Empty)) }
            }
            catch { if ($App) { $App.Log('WARN', 'Tabs', "$($p.Text) replay: $($_.Exception.Message)") } }
            finally { $state.Replaying = $false }
            try { if (-not $p.ContainsFocus) { [void]$p.SelectNextControl($null, $true, $true, $true, $false) } } catch { }
        }.GetNewClosure()
        try { [void]$Tabs.BeginInvoke([System.Windows.Forms.MethodInvoker]$replay) } catch { }
    }.GetNewClosure())
}

function Set-LazyTabBuild {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Windows.Forms.TabPage]$Page,
        [Parameter(Mandatory)] $App,
        [Parameter(Mandatory)] [scriptblock]$Build,
        [string]$LoadingText = ''
    )
    if (-not $LoadingText) { $LoadingText = "Loading $($Page.Text.Trim()) on first view..." }

    $wait = New-Object System.Windows.Forms.Label
    $wait.Text = $LoadingText
    $wait.Dock = 'Fill'; $wait.Padding = New-Object System.Windows.Forms.Padding(16, 16, 16, 16)
    $wait.ForeColor = $App.Theme.Muted
    $Page.Controls.Add($wait)

    $run = {
        $frm = $Page.FindForm()
        if ($frm) { $frm.Cursor = [System.Windows.Forms.Cursors]::WaitCursor }
        try {
            $Page.Controls.Clear()
            $Page.Padding    = New-Object System.Windows.Forms.Padding(0)
            $Page.AutoScroll = $true
            & $Build $Page $App
        }
        catch {
            if ($App) { $App.Log('ERROR', 'Tabs', "$($Page.Text.Trim()) build failed: $($_.Exception.ToString())") }
            $err = New-Object System.Windows.Forms.Label
            $err.Text = "$($Page.Text.Trim()) failed to build:`r`n$($_.Exception.Message)`r`n`r`nDetails are in Session.log."
            $err.Dock = 'Fill'; $err.Padding = New-Object System.Windows.Forms.Padding(12, 12, 12, 12)
            $err.ForeColor = [System.Drawing.Color]::Firebrick
            $Page.Controls.Add($err)
        }
        finally { if ($frm) { $frm.Cursor = [System.Windows.Forms.Cursors]::Default } }
    }.GetNewClosure()

    if ($Page.Tag -is [hashtable]) { $Page.Tag['OnActivate'] = $run } else { $Page.Tag = @{ OnActivate = $run } }
}

function Invoke-LazyTabWarmup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Windows.Forms.TabControl]$Tabs,
        [Parameter(Mandatory)] $App,
        [string[]]$Titles = @(),
        [int]$IntervalMs = 150
    )
    $queue = New-Object System.Collections.Generic.Queue[object]
    foreach ($p in $Tabs.TabPages) {
        $want = ($Titles.Count -eq 0) -or ($Titles -contains $p.Text.Trim())
        if ($want -and ($p.Tag -is [hashtable]) -and $p.Tag.ContainsKey('OnActivate') -and -not $p.Tag['Activated']) { $queue.Enqueue($p) }
    }
    if ($queue.Count -eq 0) { return }

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = [Math]::Max(10, $IntervalMs)
    $timer.Add_Tick({
        $timer.Stop()
        try {
            while ($queue.Count -gt 0) {
                $p = $queue.Dequeue()
                if ($p.Tag['Activated']) { continue }          # opened by the user meanwhile
                $p.Tag['Activated'] = $true
                $p.Tag['Warmed']    = $true
                try { & $p.Tag['OnActivate'] }
                catch { if ($App) { $App.Log('ERROR', 'Tabs', "$($p.Text) warm-up: $($_.Exception.ToString())") } }
                break                                           # one tab per tick
            }
        }
        finally {
            if ($queue.Count -gt 0) { $timer.Start() } else { $timer.Dispose() }
        }
    }.GetNewClosure())
    $timer.Start()
}
