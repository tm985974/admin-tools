# SAM_Log.psm1   (LITE TIER)
#
# Activity log + performance timing.
#   Write-SamLog   -> Session.log (through $App.Log) + every open activity box.
#                     PERF lines go to Session.log as DIAG (shown only with
#                     diagnostics on) but always appear in the activity boxes.
#   Measure-SamStep -> times a block, logs a PERF line, appends <DataRoot>\Logs\perf.csv.
# Activity boxes: the pane on the Update Pipeline tab and the Activity window
# (Activity... button on every SCCM tab). They show the last 5000 lines.

function Write-SamLog {
    param(
        [string]$Message,
        [ValidateSet('Info', 'Warning', 'Error', 'Success', 'Perf')]
        [string]$Level = 'Info'
    )
    $S = $global:SAM
    $line = '[{0}] [{1}] {2}' -f (Get-Date -Format 'HH:mm:ss'), $Level.ToUpper(), $Message
    if (-not $S) { return }
    [void]$S.LogLines.Add(@($line, $Level))
    if ($S.LogLines.Count -gt 5000) { $S.LogLines.RemoveRange(0, 500) }

    $lvl = switch ($Level) { 'Warning' { 'WARN' } 'Error' { 'ERROR' } 'Perf' { 'DIAG' } default { 'INFO' } }
    try { $S.App.Log($lvl, 'SAM', $Message) } catch { }

    foreach ($b in @($S.LogBoxes.ToArray())) {
        if ($b.IsDisposed) { $S.LogBoxes.Remove($b); continue }
        if ($b.IsHandleCreated) { Add-SamLogLine -Box $b -Line $line -Level $Level }
    }
    # Keep the window painting during long operations (at most every 150 ms)
    if ($S.Busy -and ((Get-Date) - $S.LastPump).TotalMilliseconds -gt 150) {
        [System.Windows.Forms.Application]::DoEvents()
        $S.LastPump = Get-Date
    }
}

function Add-SamLogLine {
    param($Box, [string]$Line, [string]$Level)
    $color = switch ($Level) {
        'Warning' { [System.Drawing.Color]::DarkOrange }
        'Error'   { [System.Drawing.Color]::Red }
        'Success' { [System.Drawing.Color]::DarkGreen }
        'Perf'    { [System.Drawing.Color]::Purple }
        default   { $Box.ForeColor }
    }
    $Box.SelectionStart  = $Box.TextLength
    $Box.SelectionLength = 0
    $Box.SelectionColor  = $color
    $Box.AppendText($Line + "`r`n")
    $Box.SelectionColor  = $Box.ForeColor
    $Box.ScrollToCaret()
}

# A RichTextBox that receives every log line (filled with the history first).
function New-SamLogBox {
    $App = $global:SAM.App
    $box = New-Object System.Windows.Forms.RichTextBox
    $box.ReadOnly = $true
    $box.BackColor = [System.Drawing.Color]::White
    $box.ForeColor = [System.Drawing.Color]::Black
    $box.Font = New-Object System.Drawing.Font($(if ($App.Theme.MonoFontName) { $App.Theme.MonoFontName } else { 'Consolas' }), 8.5)
    $box.DetectUrls = $false
    $box.Add_HandleCreated({
        param($s, $e)
        foreach ($l in @($global:SAM.LogLines.ToArray())) { Add-SamLogLine -Box $s -Line $l[0] -Level $l[1] }
    })
    [void]$global:SAM.LogBoxes.Add($box)
    return $box
}

function Show-SamActivityWindow {
    if ($global:SAM.ActivityForm -and -not $global:SAM.ActivityForm.IsDisposed) {
        $global:SAM.ActivityForm.Activate(); return
    }
    $f = New-Object System.Windows.Forms.Form
    $f.Text = 'Activity - ' + [string]$global:SAM.Settings.EnvLabel
    $f.Size = New-Object System.Drawing.Size(1100, 520)
    $f.StartPosition = 'CenterScreen'
    $f.ShowInTaskbar = $false
    $box = New-SamLogBox
    $box.Dock = 'Fill'
    $bar = New-Object System.Windows.Forms.FlowLayoutPanel
    $bar.Dock = 'Bottom'; $bar.Height = 40
    $b1 = New-SamButton 'Open log folder' 120
    $b1.Add_Click({ Open-SamPath -Path $global:SAM.LogDir -Title 'Open log folder' })
    $b2 = New-SamButton 'Clear' 80
    $b2.Add_Click({ $global:SAM.LogLines.Clear(); foreach ($b in @($global:SAM.LogBoxes.ToArray())) { if (-not $b.IsDisposed) { $b.Clear() } } })
    $bar.Controls.Add($b1); $bar.Controls.Add($b2)
    $f.Controls.Add($box); $f.Controls.Add($bar)
    $f.Add_FormClosed({ param($s, $e) foreach ($c in @($global:SAM.LogBoxes.ToArray())) { if ($c.IsDisposed -or $c.FindForm() -eq $s) { $global:SAM.LogBoxes.Remove($c) } } })
    $global:SAM.ActivityForm = $f
    $owner = $null; try { $owner = $global:SAM.Tabs.FindForm() } catch { }
    if ($owner) { $f.Show($owner) } else { $f.Show() }
}

function Write-SamPerfRecord {
    param([string]$Operation, [long]$Milliseconds, [bool]$Succeeded)
    $p = [string]$global:SAM.PerfFile
    if (-not $p) { return }
    try {
        if (-not [IO.File]::Exists($p)) { [IO.File]::AppendAllText($p, "Timestamp,Site,Operation,Milliseconds,Succeeded`r`n") }
        $op = $Operation.Trim() -replace '"', '""'
        [IO.File]::AppendAllText($p, ('{0},{1},"{2}",{3},{4}' -f (Get-Date -Format 's'), $global:SAM.Settings.SiteCode, $op, $Milliseconds, $Succeeded) + "`r`n")
    } catch { }
}

# Times a block, logs a PERF line and writes a perf.csv record. Output passes through.
# Parameter names are deliberately unusual so they never shadow the block's variables.
function Measure-SamStep {
    param([string]$__StepName, [scriptblock]$__StepBlock, [switch]$__Quiet)
    $__sw = [System.Diagnostics.Stopwatch]::StartNew()
    $__ok = $false
    try {
        & $__StepBlock
        $__ok = $true
    }
    finally {
        $__sw.Stop()
        if (-not $__Quiet) {
            $suffix = if ($__ok) { '' } else { '  (FAILED)' }
            Write-SamLog ('{0} : {1:N0} ms{2}' -f $__StepName.Trim(), $__sw.ElapsedMilliseconds, $suffix) -Level Perf
        }
        Write-SamPerfRecord -Operation $__StepName -Milliseconds $__sw.ElapsedMilliseconds -Succeeded $__ok
    }
}

function Add-SamTimer {
    param([hashtable]$Timers, [string]$Key, [System.Diagnostics.Stopwatch]$Sw)
    if ($null -ne $Timers) { $Timers[$Key] = [long]$Timers[$Key] + $Sw.ElapsedMilliseconds }
    $Sw.Restart()
}
