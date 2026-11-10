#region -- ADIgnition.Discovery.Tab.psm1 ----------------------------------------
# Concern : Build-IgnitionDiscoveryTab - the Ignition tab: a toolbar (scope,
#           threads, Discover, Refresh from cache, Export CSV), a wildcard
#           filter box, a results grid of discovered gateways, a progress bar
#           and status line.
#           Discovery is HTTP-only (see ADIgnition.Discovery.Scan header) and
#           runs on the Discover button, never automatically. On first view the
#           last saved results load from cache so the tab is useful without a
#           rescan.
# Load order: before ADIgnition.Register-DiscoveryTab, which calls this. Depends
#           on ADIgnition.Discovery.Scan (Invoke-IgnitionDiscovery, Load-/Save-
#           IgnitionCache), Services.AD.Connection.Query (Get-DomainComputers),
#           Services.AD.Reporting (New-SectionPanel, New-StdGrid, New-StdButton,
#           Set-GridData, Export-ToCSV, Set-Placeholder, Get-PlaceholderValue),
#           Base\Services_Filter (Register-ListFilter, Select-FilterMatch),
#           Base\Services_Commands (Invoke-AppCommand, Format-AppCommandValue).
# Notes   : Dot-sourced functions captured via ${function:} before any
#           .GetNewClosure(); $Context captured into a local. Same closure-scope
#           rule used throughout this codebase. PS 5.1 compatible.
#endregion

#region -- Shared script-scope state --------------------------------------------
$script:IgnGrid        = $null
$script:IgnFilter      = $null
$script:IgnCmbScope    = $null
$script:IgnNumThreads  = $null
$script:IgnCount       = $null
$script:IgnProgress    = $null
$script:IgnAllGateways = New-Object System.Collections.Generic.List[PSCustomObject]
$script:IgnColumns     = @('Name','DNS','IP','Version','Edition','GatewayName','Role','Redundancy','Scheme')
#endregion

#region -- Update-IgnGrid -------------------------------------------------------
function Update-IgnGrid {
    if (-not $script:IgnGrid) { return }
    $text = ''
    if ($script:IgnFilter -and (Get-Command Get-PlaceholderValue -ErrorAction SilentlyContinue)) {
        $text = (Get-PlaceholderValue -TextBox $script:IgnFilter).Trim()
    }
    $data = @($script:IgnAllGateways)
    if ($text -and (Get-Command Select-FilterMatch -ErrorAction SilentlyContinue) -and (Get-Command ConvertTo-FilterRegex -ErrorAction SilentlyContinue)) {
        $rx = $null
        try { $rx = ConvertTo-FilterRegex -Pattern $text } catch { }
        if ($rx) { $data = @(Select-FilterMatch -Items $script:IgnAllGateways -Regex $rx -Property $script:IgnColumns) }
    }
    Set-GridData -Grid $script:IgnGrid -Data $data -Columns $script:IgnColumns
    if ($script:IgnCount) { $script:IgnCount.Text = "$($data.Count) of $($script:IgnAllGateways.Count) gateway(s)" }
}
#endregion

#region -- Set-IgnData ----------------------------------------------------------
function Set-IgnData {
    param([object]$Gateways)
    $script:IgnAllGateways.Clear()
    foreach ($g in @($Gateways)) { [void]$script:IgnAllGateways.Add([PSCustomObject]$g) }
    Update-IgnGrid
}
#endregion

#region -- New-IgnitionContextMenu ----------------------------------------------
# Compact, gateway-specific menu. Launch actions go through the command engine
# (Invoke-AppCommand, Kind Read) so the exact line is shown/copyable, matching
# the computer menu's launch items. No SMB/admin-share actions here.
function New-IgnitionContextMenu {
    param([scriptblock]$TargetProvider)
    $menu        = New-Object System.Windows.Forms.ContextMenuStrip
    $menu.Font   = New-Object System.Drawing.Font('Segoe UI', 9)
    $invokeCmdFn = ${function:Invoke-AppCommand}
    $fmtCmdFn    = ${function:Format-AppCommandValue}
    $statusFn    = ${function:Set-Status}
    $menuApp     = $script:ADApp
    $httpPort    = $script:IgnHttpPort
    $httpsPort   = $script:IgnHttpsPort

    $runLines = {
        param([string]$Title, [string[]]$Lines, [string]$Summary)
        if (@($Lines).Count -eq 0) { return }
        if (-not $invokeCmdFn) { if ($statusFn) { & $statusFn 'Command engine not loaded.' 'err' }; return }
        $r = & $invokeCmdFn -App $menuApp -Title $Title -Kind Read -Code (@($Lines) -join "`r`n") -Summary $Summary
        if ($r.Errors.Count -gt 0 -and $statusFn) { & $statusFn "${Title}: $($r.Errors[0])" 'err' }
    }.GetNewClosure()

    $addrOf = { param($row) if ($row.DNS) { [string]$row.DNS } elseif ($row.IP) { [string]$row.IP } else { [string]$row.Name } }.GetNewClosure()

    $miWeb      = New-Object System.Windows.Forms.ToolStripMenuItem
    $miWeb.Text = 'Open Gateway Web Page'
    $miWeb.Add_Click(({
        $rows = @(& $TargetProvider)
        $lines = @($rows | ForEach-Object {
            $h = & $addrOf $_
            $scheme = if ($_.Scheme) { [string]$_.Scheme } else { 'http' }
            $port = if ($scheme -eq 'https') { $httpsPort } else { $httpPort }
            'Start-Process ' + (& $fmtCmdFn ("{0}://{1}:{2}/main/web/home" -f $scheme, $h, $port))
        })
        & $runLines 'Open Gateway Web Page' $lines "Open the gateway home page for $($rows.Count) gateway(s)."
    }).GetNewClosure())
    [void]$menu.Items.Add($miWeb)
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

    $miRDP      = New-Object System.Windows.Forms.ToolStripMenuItem
    $miRDP.Text = 'RDP'
    $miRDP.Add_Click(({
        $names = @(@(& $TargetProvider) | ForEach-Object { $_.Name } | Where-Object { $_ })
        $lines = @($names | ForEach-Object { 'Start-Process -FilePath ''mstsc.exe'' -ArgumentList ' + (& $fmtCmdFn "/v:$_") })
        & $runLines 'RDP' $lines "Open Remote Desktop to $($names.Count) computer(s)."
    }).GetNewClosure())
    [void]$menu.Items.Add($miRDP)

    $miPing      = New-Object System.Windows.Forms.ToolStripMenuItem
    $miPing.Text = 'Ping (continuous, command window)'
    $miPing.Add_Click(({
        $names = @(@(& $TargetProvider) | ForEach-Object { $_.Name } | Where-Object { $_ })
        $lines = @($names | ForEach-Object { 'Start-Process -FilePath ''cmd.exe'' -ArgumentList ' + (& $fmtCmdFn "/k ping -t $_") })
        & $runLines 'Ping (command window)' $lines "Open a ping -t window for each of $($names.Count) computer(s)."
    }).GetNewClosure())
    [void]$menu.Items.Add($miPing)
    return $menu
}
#endregion

#region -- Build-IgnitionDiscoveryTab -------------------------------------------
function Build-IgnitionDiscoveryTab {
    param([System.Windows.Forms.TabPage]$Tab, [PSCustomObject]$Context)
    $PAD  = 8
    $F_UI = New-Object System.Drawing.Font('Segoe UI', 9)
    $TW   = $script:_TW; $TH = $script:_TH

    # ----- toolbar ------------------------------------------------------------
    $bar          = New-Object System.Windows.Forms.Panel
    $bar.Location = New-Object System.Drawing.Point($PAD, $PAD)
    $bar.Size     = New-Object System.Drawing.Size(($TW - $PAD * 2), 64)
    $Tab.Controls.Add($bar)

    $lHint           = New-Object System.Windows.Forms.Label
    $lHint.Text      = 'Discovers Ignition gateways by a single HTTP request to each server''s gateway info endpoint (ports 8088 / 8043). No SMB or admin-share access. Results are cached; Discover re-probes.'
    $lHint.Location  = New-Object System.Drawing.Point(2, 0)
    $lHint.Size      = New-Object System.Drawing.Size(($TW - $PAD * 2 - 4), 30)
    $lHint.Font      = New-Object System.Drawing.Font('Segoe UI', 8)
    $lHint.ForeColor = [System.Drawing.Color]::DimGray
    $bar.Controls.Add($lHint)

    $btnDiscover = New-StdButton -Text 'Discover Gateways' -X 2 -Y 32 -W 150 -H 28 -Parent $bar
    $btnDiscover.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $btnCache    = New-StdButton -Text 'Reload Cached' -X 158 -Y 32 -W 110 -H 28 -Parent $bar

    $lScope          = New-Object System.Windows.Forms.Label
    $lScope.Text     = 'Scope:'
    $lScope.Location = New-Object System.Drawing.Point(280, 36); $lScope.Size = New-Object System.Drawing.Size(46, 22)
    $lScope.Font     = $F_UI; $bar.Controls.Add($lScope)
    $script:IgnCmbScope = New-Object System.Windows.Forms.ComboBox
    $script:IgnCmbScope.Location = New-Object System.Drawing.Point(326, 33)
    $script:IgnCmbScope.Size     = New-Object System.Drawing.Size(150, 24)
    $script:IgnCmbScope.DropDownStyle = 'DropDownList'; $script:IgnCmbScope.Font = $F_UI
    @('Servers only','All computers') | ForEach-Object { [void]$script:IgnCmbScope.Items.Add($_) }
    $script:IgnCmbScope.SelectedIndex = 0
    $bar.Controls.Add($script:IgnCmbScope)

    $lThreads          = New-Object System.Windows.Forms.Label
    $lThreads.Text     = 'Threads:'
    $lThreads.Location = New-Object System.Drawing.Point(486, 36); $lThreads.Size = New-Object System.Drawing.Size(54, 22)
    $lThreads.Font     = $F_UI; $bar.Controls.Add($lThreads)
    $script:IgnNumThreads = New-Object System.Windows.Forms.NumericUpDown
    $script:IgnNumThreads.Location = New-Object System.Drawing.Point(540, 33)
    $script:IgnNumThreads.Size     = New-Object System.Drawing.Size(52, 24)
    $script:IgnNumThreads.Minimum  = 1; $script:IgnNumThreads.Maximum = 16; $script:IgnNumThreads.Value = 8
    $script:IgnNumThreads.Font     = $F_UI
    $bar.Controls.Add($script:IgnNumThreads)

    $lFilt          = New-Object System.Windows.Forms.Label
    $lFilt.Text     = 'Filter:'
    $lFilt.Location = New-Object System.Drawing.Point(604, 36); $lFilt.Size = New-Object System.Drawing.Size(42, 22)
    $lFilt.Font     = $F_UI; $bar.Controls.Add($lFilt)
    $script:IgnFilter = New-Object System.Windows.Forms.TextBox
    $script:IgnFilter.Location = New-Object System.Drawing.Point(646, 33)
    $script:IgnFilter.Size     = New-Object System.Drawing.Size(220, 24); $script:IgnFilter.Font = $F_UI
    if (Get-Command Set-Placeholder -ErrorAction SilentlyContinue) { Set-Placeholder -TextBox $script:IgnFilter -Text 'gateway / version / role...' }
    $bar.Controls.Add($script:IgnFilter)

    $btnExport = New-StdButton -Text 'Export CSV' -X 874 -Y 32 -W 100 -H 28 -Parent $bar

    $script:IgnCount = New-Object System.Windows.Forms.Label
    $script:IgnCount.Location  = New-Object System.Drawing.Point(($bar.Width - 230), 36)
    $script:IgnCount.Size      = New-Object System.Drawing.Size(220, 22)
    $script:IgnCount.Font      = $F_UI; $script:IgnCount.ForeColor = [System.Drawing.Color]::DimGray
    $script:IgnCount.TextAlign = 'MiddleRight'
    $script:IgnCount.Anchor    = 'Top, Right'
    $script:IgnCount.Text      = '0 of 0 gateway(s)'
    $bar.Controls.Add($script:IgnCount)

    # ----- progress bar -------------------------------------------------------
    $script:IgnProgress = New-Object System.Windows.Forms.ProgressBar
    $script:IgnProgress.Location = New-Object System.Drawing.Point($PAD, ($PAD + 66))
    $script:IgnProgress.Size     = New-Object System.Drawing.Size(($TW - $PAD * 2), 6)
    $Tab.Controls.Add($script:IgnProgress)

    # ----- grid ---------------------------------------------------------------
    $GRID_Y = $PAD + 76
    $sec = New-SectionPanel -Parent $Tab -Title 'Discovered Ignition Gateways' `
        -X $PAD -Y $GRID_Y -W ($TW - $PAD * 2) -H ($TH - $GRID_Y - $PAD)
    $script:IgnGrid = New-StdGrid -X 4 -Y 4 -W ($sec.Width - 8) -H ($sec.Height - 8) -Parent $sec
    $script:IgnGrid.MultiSelect   = $true
    $script:IgnGrid.SelectionMode = 'FullRowSelect'

    $gridProvider = {
        $rows = @()
        if ($script:IgnGrid) {
            foreach ($r in $script:IgnGrid.SelectedRows) {
                $rows += [PSCustomObject]@{
                    Name = [string]$r.Cells['Name'].Value
                    DNS  = [string]$r.Cells['DNS'].Value
                    IP   = [string]$r.Cells['IP'].Value
                    Scheme = [string]$r.Cells['Scheme'].Value
                }
            }
        }
        $rows
    }
    $script:IgnGrid.ContextMenuStrip = New-IgnitionContextMenu -TargetProvider $gridProvider
    $script:IgnGrid.Add_MouseDown({
        param($s, $e)
        if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Right) { return }
        $hit = $script:IgnGrid.HitTest($e.X, $e.Y)
        if ($hit.RowIndex -ge 0 -and -not $script:IgnGrid.Rows[$hit.RowIndex].Selected) {
            $script:IgnGrid.ClearSelection(); $script:IgnGrid.Rows[$hit.RowIndex].Selected = $true
        }
    })

    # ----- captures + handlers ------------------------------------------------
    $discoverFn   = ${function:Invoke-IgnitionDiscovery}
    $getCompFn    = ${function:Get-DomainComputers}
    $loadCacheFn  = ${function:Load-IgnitionCache}
    $setDataFn    = ${function:Set-IgnData}
    $updateGridFn = ${function:Update-IgnGrid}
    $exportFn     = ${function:Export-ToCSV}
    $statusFn     = ${function:Set-Status}
    $capturedCtx  = $Context
    $ignApp       = $script:ADApp
    # Capture script-scope controls/collections into locals BEFORE any
    # .GetNewClosure() - bare $script: reads inside a closure can resolve to
    # $null in this codebase (see ADTools.AbortReboot.Tab header). These are
    # references to the same objects the Update-IgnGrid / Set-IgnData functions
    # mutate, so they stay in sync.
    $cmbScope   = $script:IgnCmbScope
    $numThreads = $script:IgnNumThreads
    $progress   = $script:IgnProgress
    $allGw      = $script:IgnAllGateways

    # filter (wildcards anywhere) via the template filter service
    if (Get-Command Register-ListFilter -ErrorAction SilentlyContinue) {
        $onFilter = { param($Regex, $Text) if ($updateGridFn) { & $updateGridFn } }.GetNewClosure()
        [void](Register-ListFilter -App $ignApp -TextBox $script:IgnFilter -OnFilter $onFilter)
    }

    $btnDiscover.Add_Click({
        if (-not $discoverFn -or -not $getCompFn) { if ($statusFn) { & $statusFn 'Discovery engine not loaded.' 'err' }; return }
        $btnDiscover.Enabled = $false; $btnCache.Enabled = $false
        try {
            if ($statusFn) { & $statusFn 'Loading computer list from Active Directory...' 'info' }
            $srv = @{}
            if ($capturedCtx -and $capturedCtx.TargetDC) { $srv['Server'] = $capturedCtx.TargetDC }
            $computers = @(& $getCompFn @srv -IncludeDisabled)
            $serversOnly = ($cmbScope.SelectedItem -eq 'Servers only')
            $gw = & $discoverFn -Computers $computers -ThreadCount ([int]$numThreads.Value) `
                    -ServersOnly $serversOnly -StatusLabel $null -ProgressBar $progress
            & $setDataFn -Gateways $gw
        } catch {
            if ($statusFn) { & $statusFn "Discovery failed: $($_.Exception.Message)" 'err' }
        } finally {
            $btnDiscover.Enabled = $true; $btnCache.Enabled = $true
        }
    }.GetNewClosure())

    $btnCache.Add_Click({
        if (-not $loadCacheFn) { return }
        $c = & $loadCacheFn
        if ($c -and $c.Data) {
            & $setDataFn -Gateways $c.Data
            $when = if ($c.ScannedAt) { $c.ScannedAt.ToString('yyyy-MM-dd HH:mm') } else { 'unknown' }
            if ($statusFn) { & $statusFn "Loaded $($c.Data.Count) cached gateway(s) (scanned $when)." 'ok' }
        } elseif ($statusFn) { & $statusFn 'No cached Ignition results yet - click Discover Gateways.' 'warn' }
    }.GetNewClosure())

    $showExportFn = ${function:Show-ExportResult}
    $ignCols = $script:IgnColumns
    $btnExport.Add_Click({
        if ($allGw.Count -eq 0) { if ($statusFn) { & $statusFn 'Nothing to export.' 'warn' }; return }
        if (-not $exportFn) { return }
        $rows = @($allGw | Select-Object $ignCols)
        $path = & $exportFn -Context $capturedCtx -Data $rows -BaseName 'Ignition-Gateways'
        if ($path -and $showExportFn) { & $showExportFn -FilePath $path }
        elseif ($path -and $statusFn) { & $statusFn "Exported $($rows.Count) gateway(s) to $path" 'ok' }
        elseif ($statusFn) { & $statusFn 'Export failed.' 'err' }
    }.GetNewClosure())

    # ----- first view: load whatever is cached --------------------------------
    $Tab.Add_Enter(({
        if ($allGw.Count -eq 0 -and $loadCacheFn) {
            $c = & $loadCacheFn
            if ($c -and $c.Data) { & $setDataFn -Gateways $c.Data }
        }
    }).GetNewClosure())
}
#endregion

Export-ModuleMember -Function `
    Build-IgnitionDiscoveryTab, Update-IgnGrid, Set-IgnData, New-IgnitionContextMenu
