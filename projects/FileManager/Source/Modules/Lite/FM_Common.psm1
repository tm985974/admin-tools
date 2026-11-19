# FM_Common.psm1   (LITE TIER)
#
# Small UI helpers shared by the File Manager tabs:
#   New-FmGrid        a styled, read-only DataGridView with the given columns
#   New-FmProgress    progress bar + phase + details + log box for a background task
#   Start-FmJobWatch  polls a running engine task (a timer on the UI thread)
#   Register-FmRefresh / Invoke-FmRefresh   tabs refresh each other after a task
#   Show-FmText       a read-only text window (health check output, notes)
#   Open-FmFolder     opens a folder in Explorer through the command engine
#   Format-FmSize     1536 -> '1.5 KB'

$script:FmRefresh = @{}

function Format-FmSize {
    [CmdletBinding()]
    param([long]$Bytes)
    return [FileManagerEngine.Util]::Size($Bytes)
}

function Register-FmRefresh {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Name, [Parameter(Mandatory)] [scriptblock]$Action)
    $script:FmRefresh[$Name] = $Action
}

function Invoke-FmRefresh {
    [CmdletBinding()]
    param([string[]]$Except = @())
    foreach ($k in @($script:FmRefresh.Keys)) {
        if ($Except -contains $k) { continue }
        try { & $script:FmRefresh[$k] } catch { }
    }
}

# Named hooks so one tab can drive another (the Workflow tab sets the Scan tab's mode).
$script:FmHooks = @{}

function Register-FmHook {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Name, [Parameter(Mandatory)] [scriptblock]$Action)
    $script:FmHooks[$Name] = $Action
}

function Invoke-FmHook {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Name, $Arg)
    if ($script:FmHooks.ContainsKey($Name)) { try { & $script:FmHooks[$Name] $Arg } catch { } }
}

# Switch the main window to the tab with this title (it is built on first view).
function Select-FmTab {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [System.Windows.Forms.Control]$From, [Parameter(Mandatory)] [string]$Title)
    # the outermost TabControl above this control is the main window's tab strip
    $c = $null
    for ($p = $From; $p; $p = $p.Parent) { if ($p -is [System.Windows.Forms.TabControl]) { $c = $p } }
    if (-not $c) { return }
    foreach ($pg in $c.TabPages) { if ($pg.Text.Trim() -eq $Title) { $c.SelectedTab = $pg; return } }
}

function New-FmLabel {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $App, [string]$Text = '', [switch]$Header, [switch]$Muted, [int]$Height = 22)
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Text
    $l.Dock = 'Top'
    if ($Header) { Set-HeaderStyle -App $App -Label $l; $l.AutoSize = $false; $l.Height = 34 }
    else { $l.AutoSize = $false; $l.Height = $Height }
    if ($Muted) { $l.ForeColor = $App.Theme.Muted }
    return $l
}

function New-FmBar {
    [CmdletBinding()]
    param([int]$Height = 40)
    $p = New-Object System.Windows.Forms.FlowLayoutPanel
    $p.Dock = 'Top'
    $p.Height = $Height
    $p.WrapContents = $false
    $p.FlowDirection = 'LeftToRight'
    $p.Padding = New-Object System.Windows.Forms.Padding(0, 4, 0, 0)
    return $p
}

function New-FmGrid {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $App, [Parameter(Mandatory)] [string[]]$Columns, [int[]]$Weights = @(), [switch]$Multi)
    $g = New-Object System.Windows.Forms.DataGridView
    $g.Dock = 'Fill'
    $g.ReadOnly = $true
    $g.AllowUserToAddRows = $false
    $g.AllowUserToDeleteRows = $false
    $g.AllowUserToResizeRows = $false
    $g.RowHeadersVisible = $false
    $g.MultiSelect = [bool]$Multi
    $g.SelectionMode = 'FullRowSelect'
    $g.AutoSizeColumnsMode = 'Fill'
    $g.BackgroundColor = $App.Theme.Surface
    $g.BorderStyle = 'FixedSingle'
    $g.GridColor = $App.Theme.Border
    $g.EnableHeadersVisualStyles = $false
    $g.ColumnHeadersDefaultCellStyle.BackColor = $App.Theme.Header
    $g.ColumnHeadersDefaultCellStyle.ForeColor = $App.Theme.Title
    $g.DefaultCellStyle.SelectionBackColor = $App.Theme.Select
    $g.DefaultCellStyle.SelectionForeColor = $App.Theme.Text
    $g.AlternatingRowsDefaultCellStyle.BackColor = $App.Theme.AltRow
    for ($i = 0; $i -lt $Columns.Count; $i++) {
        $idx = $g.Columns.Add(('c' + $i), $Columns[$i])
        if ($i -lt $Weights.Count -and $Weights[$i] -gt 0) { $g.Columns[$idx].FillWeight = $Weights[$i] }
        $g.Columns[$idx].SortMode = 'NotSortable'
    }
    return $g
}

# The selected row's Tag (the data object the row was made from), or $null.
function Get-FmSelected {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [System.Windows.Forms.DataGridView]$Grid)
    if ($Grid.SelectedRows.Count -gt 0) { return $Grid.SelectedRows[0].Tag }
    if ($Grid.CurrentRow) { return $Grid.CurrentRow.Tag }
    return $null
}

function New-FmProgress {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $App, [int]$LogHeight = 0)
    $panel = New-Object System.Windows.Forms.Panel
    $panel.Dock = 'Top'
    $panel.Height = 86

    $phase = New-Object System.Windows.Forms.Label
    $phase.Location = New-Object System.Drawing.Point(0, 4); $phase.AutoSize = $true
    $phase.Text = 'Ready.'
    $phase.Font = New-AppFont -App $App -Style ([System.Drawing.FontStyle]::Bold)

    $bar = New-Object System.Windows.Forms.ProgressBar
    $bar.Location = New-Object System.Drawing.Point(0, 26); $bar.Size = New-Object System.Drawing.Size(900, 18)
    $bar.Anchor = 'Top, Left, Right'
    $bar.Minimum = 0; $bar.Maximum = 100

    $detail = New-Object System.Windows.Forms.Label
    $detail.Location = New-Object System.Drawing.Point(0, 48); $detail.AutoSize = $true
    $detail.ForeColor = $App.Theme.Text

    $current = New-Object System.Windows.Forms.Label
    $current.Location = New-Object System.Drawing.Point(0, 66); $current.AutoSize = $false
    $current.Size = New-Object System.Drawing.Size(900, 18); $current.Anchor = 'Top, Left, Right'
    $current.ForeColor = $App.Theme.Muted; $current.AutoEllipsis = $true

    $panel.Controls.AddRange(@($phase, $bar, $detail, $current))

    $log = New-Object System.Windows.Forms.TextBox
    $log.Multiline = $true; $log.ReadOnly = $true; $log.ScrollBars = 'Vertical'; $log.WordWrap = $false
    $log.BackColor = $App.Theme.Surface
    $log.Font = New-Object System.Drawing.Font($App.Theme.MonoFontName, ($App.Theme.FontSizePt - 0.5))
    if ($LogHeight -gt 0) { $log.Dock = 'Top'; $log.Height = $LogHeight } else { $log.Dock = 'Fill' }

    $p = @{ Panel = $panel; Phase = $phase; Bar = $bar; Detail = $detail; Current = $current; Log = $log }

    $p.Update = {
        param($job)
        if ($null -eq $job) { return }
        $span = {
            param([double]$s)
            if ($s -lt 0 -or [double]::IsInfinity($s) -or [double]::IsNaN($s)) { return '?' }
            $t = [TimeSpan]::FromSeconds([Math]::Min($s, 8640000))
            if ($t.TotalHours -ge 1) { return ('{0}h {1:00}m' -f [int][Math]::Floor($t.TotalHours), $t.Minutes) }
            if ($t.TotalMinutes -ge 1) { return ('{0}m {1:00}s' -f $t.Minutes, $t.Seconds) }
            return ('{0}s' -f [int]$t.TotalSeconds)
        }
        $p.Phase.Text = [string]$job.Phase
        $secs = [Math]::Max(0.5, [double]$job.PhaseSeconds)
        $err = $(if ($job.Errors -gt 0) { '  |  {0:N0} problems (see the log)' -f $job.Errors } else { '' })
        if ($job.BytesTotal -gt 0) {
            $pct = [int][Math]::Min(100, [Math]::Floor(100.0 * $job.BytesDone / $job.BytesTotal))
            $p.Bar.Style = 'Continuous'; $p.Bar.Value = [Math]::Max(0, $pct)
            $rate = [double]$job.BytesDone / $secs
            $left = $(if ($rate -gt 0) { & $span (([double]$job.BytesTotal - $job.BytesDone) / $rate) } else { '?' })
            $p.Detail.Text = '{0:N0} of {1:N0} files  |  {2} of {3}  |  {4}/s  |  about {5} left{6}' -f $job.FilesDone, $job.FilesTotal,
                [FileManagerEngine.Util]::Size($job.BytesDone), [FileManagerEngine.Util]::Size($job.BytesTotal), [FileManagerEngine.Util]::Size([long]$rate), $left, $err
        }
        elseif ($job.FilesTotal -gt 0) {
            $pct = [int][Math]::Min(100, [Math]::Floor(100.0 * $job.FilesDone / $job.FilesTotal))
            $p.Bar.Style = 'Continuous'; $p.Bar.Value = [Math]::Max(0, $pct)
            $p.Detail.Text = '{0:N0} of {1:N0} done  |  {2} elapsed{3}' -f $job.FilesDone, $job.FilesTotal, (& $span $job.PhaseSeconds), $err
        }
        else {
            if ($job.Finished) { $p.Bar.Style = 'Continuous'; $p.Bar.Value = 100 } else { $p.Bar.Style = 'Marquee' }
            if ($job.Folders -gt 0 -or $job.FilesDone -gt 0) {
                $p.Detail.Text = '{0:N0} folders, {1:N0} files, {2} found  |  {3} elapsed{4}' -f $job.Folders, $job.FilesDone, [FileManagerEngine.Util]::Size($job.BytesDone), (& $span $job.Seconds), $err
            }
            else { $p.Detail.Text = '{0} elapsed{1}' -f (& $span $job.Seconds), $err }
        }
        if ($job.Finished) {
            $p.Bar.Style = 'Continuous'
            $p.Bar.Value = $(if ($job.Failed) { 0 } else { 100 })
            $p.Current.Text = $(if ($job.Failed) { $job.Error } elseif ($job.Summary) { $job.Summary } else { '' })
        }
        else { $p.Current.Text = [string]$job.Current }
        $lines = $job.TakeLog()
        if ($lines.Count -gt 0) {
            if ($p.Log.TextLength -gt 2000000) { $p.Log.Clear() }
            $p.Log.AppendText(($lines -join "`r`n") + "`r`n")
        }
    }.GetNewClosure()

    $p.Reset = {
        param([string]$Text = 'Starting...')
        $p.Phase.Text = $Text
        $p.Bar.Style = 'Marquee'
        $p.Detail.Text = ''
        $p.Current.Text = ''
    }.GetNewClosure()

    return $p
}

function Start-FmJobWatch {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $App, [Parameter(Mandatory)] $Job, [scriptblock]$OnTick, [scriptblock]$OnDone)
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 400
    $st = @{ Timer = $timer; Job = $Job; Tick = $OnTick; Done = $OnDone; App = $App }
    $timer.Add_Tick({
        $j = $st.Job
        if ($st.Tick) { try { & $st.Tick $j } catch { $st.App.Log('WARN', 'FileManager', "progress display: $($_.Exception.Message)") } }
        if ($j.Finished) {
            $st.Timer.Stop()
            if ($st.Tick) { try { & $st.Tick $j } catch { } }
            $level = $(if ($j.Failed) { 'ERROR' } elseif ($j.Cancelled) { 'WARN' } else { 'INFO' })
            $text = $(if ($j.Failed) { $j.Error } else { $j.Summary })
            $st.App.Log($level, 'FileManager', "$($j.Name): $($j.Phase). $text")
            foreach ($line in $j.FullLog()) { if ($line -match 'ERROR|FAILED|NOT deleted|Cannot ') { $st.App.Log('WARN', 'FileManager', $line) } }
            if ($j.Failed) { $st.App.SetStatus("$($j.Name) failed: $($j.Error)", 'err') }
            elseif ($j.Cancelled) { $st.App.SetStatus("$($j.Name) stopped. Work done so far is saved.", 'warn') }
            else { $st.App.SetStatus($text, 'ok') }
            if ($st.Done) { try { & $st.Done $j } catch { $st.App.Log('ERROR', 'FileManager', "after $($j.Name): $($_.Exception.Message)") } }
            $st.Timer.Dispose()
        }
    }.GetNewClosure())
    $timer.Start()
}

function Show-FmText {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $App, [Parameter(Mandatory)] [string]$Title, [AllowEmptyString()] [string]$Text = '', [string]$Note = '')
    $f = New-Object System.Windows.Forms.Form
    $f.Text = $Title
    $f.StartPosition = 'CenterParent'
    $f.Size = New-Object System.Drawing.Size(980, 560)
    $f.Font = New-AppFont -App $App
    $f.BackColor = $App.Theme.Surface
    $f.Padding = New-Object System.Windows.Forms.Padding(10)
    $box = New-Object System.Windows.Forms.TextBox
    $box.Multiline = $true; $box.ReadOnly = $true; $box.ScrollBars = 'Both'; $box.WordWrap = $false; $box.Dock = 'Fill'
    $box.Font = New-Object System.Drawing.Font($App.Theme.MonoFontName, $App.Theme.FontSizePt)
    $box.BackColor = $App.Theme.Surface
    $box.Text = $Text
    $bottom = New-Object System.Windows.Forms.Panel
    $bottom.Dock = 'Bottom'; $bottom.Height = 44
    $close = $App.Theme.MakeButton('Close')
    $close.Anchor = 'Top, Right'
    $close.Location = New-Object System.Drawing.Point(($bottom.Width - $close.Width - 4), 8)
    $close.Add_Click({ $f.Close() }.GetNewClosure())
    $bottom.Controls.Add($close)
    $f.Controls.Add($box)
    if ($Note) {
        $n = New-Object System.Windows.Forms.Label
        $n.Text = $Note; $n.Dock = 'Top'; $n.Height = 44; $n.ForeColor = $App.Theme.Muted
        $f.Controls.Add($n)
    }
    $f.Controls.Add($bottom)
    $f.CancelButton = $close
    [void]$f.ShowDialog()
    $f.Dispose()
}

function Open-FmFolder {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $App, [string]$Path)
    if (-not $Path) { $App.SetStatus('Nothing to open: that drive is not connected.', 'warn'); return }
    $code = 'Start-Process -FilePath ''explorer.exe'' -ArgumentList ' + (Format-AppCommandValue ('"{0}"' -f $Path))
    $r = Invoke-AppCommand -App $App -Title 'Open folder' -Kind Read -Code $code
    if ($r.Errors.Count -gt 0) { $App.SetStatus("Could not open it: $($r.Errors[0])", 'err') }
}

# Runs an engine call that may throw; shows the message instead of failing the tab.
function Invoke-FmSafe {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $App, [Parameter(Mandatory)] [scriptblock]$Action, [string]$What = 'That')
    try { return (& $Action) }
    catch {
        $msg = $_.Exception.Message
        if ($_.Exception.InnerException) { $msg = $_.Exception.InnerException.Message }
        $App.Log('WARN', 'FileManager', "$What : $msg")
        [void][System.Windows.Forms.MessageBox]::Show($msg, $What, 'OK', 'Warning')
        return $null
    }
}
