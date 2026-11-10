#region -- ADComputers.Ping.Engine.psm1 ------------------------------------------
# Concern : Group ping engine - used by the Ping Computers dialog (right-click
#           "Ping Selected..." on any computer list) and the Tools > Ping List
#           sub-tab. No UI here.
#             ConvertTo-ComputerNameList  - pasted text -> clean, unique names
#             Get-PingGroupCommandText    - the exact PowerShell for a round
#                                           (shown / copied via the command
#                                           engine, Base\Services_Commands)
#             Start-PingRound             - one ICMP echo to every name, all in
#                                           parallel (Ping.SendPingAsync)
#             Get-PingRoundResult         - poll one item of a round
# Notes   : Non-blocking by design: Start-PingRound returns at once with one
#           Task per name and the caller polls them from a WinForms timer, so
#           the window keeps painting while slow / unknown hosts time out. Each
#           name gets its own Ping object (a Ping instance can only have one
#           request outstanding). Name resolution happens inside the Ping call
#           (on the thread pool), so an unknown name shows as an error row,
#           not a hang.
#           The command text is a standalone script doing the same
#           Ping.Send(name, timeout) call one name after another - the window
#           sends them in parallel; results are the same.
#           PS 5.1 compatible: no ternaries, no ??, no -Parallel.
#endregion

#region -- ConvertTo-ComputerNameList -------------------------------------------
function ConvertTo-ComputerNameList {
    <#
    .SYNOPSIS
        Splits pasted text into computer names: one per line, or separated by
        commas, semicolons, tabs or spaces. Strips leading "\\", trailing "$"
        (computer account names) and surrounding quotes; skips blank lines and
        lines starting with '#'. Unique, case-insensitive, first spelling and
        order kept.
    #>
    param([AllowEmptyString()] [string]$Text)
    $seen  = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
    $names = New-Object System.Collections.Generic.List[string]
    if (-not $Text) { return }
    foreach ($line in ($Text -split "`r?`n")) {
        $l = $line.Trim()
        if (-not $l -or $l.StartsWith('#')) { continue }
        foreach ($tok in ($l -split '[,;\s]+')) {
            $n = $tok.Trim().Trim('"', "'").TrimStart('\').TrimEnd('$').Trim()
            if (-not $n) { continue }
            if ($seen.Add($n)) { [void]$names.Add($n) }
        }
    }
    # Unrolled on purpose: callers wrap with @(...). Returning ', $array' made
    # @(...) a one-element array holding the whole list (v1.2.12 bug: one row
    # named 'System.String[]').
    return $names.ToArray()
}
#endregion

#region -- Get-PingGroupCommandText ---------------------------------------------
function Get-PingGroupCommandText {
    <#
    .SYNOPSIS
        The exact PowerShell for one ping round over -Names: the same
        System.Net.NetworkInformation.Ping call with the same timeout. Runs as
        is in any PowerShell 5.1 window and prints one row per computer.
    #>
    param([string[]]$Names, [int]$TimeoutMs = 1000, [int]$IntervalSeconds = 0)
    $fmt = ${function:Format-AppCommandValue}
    $list = ''
    if ($fmt) { $list = & $fmt @($Names) } else { $list = "@('" + (($Names | ForEach-Object { $_.Replace("'", "''") }) -join "', '") + "')" }
    $lines = New-Object System.Collections.Generic.List[string]
    [void]$lines.Add("# Ping $(@($Names).Count) computer(s) once, $TimeoutMs ms timeout. The window sends these in")
    [void]$lines.Add('# parallel; this runs the same call one computer after another.')
    if ($IntervalSeconds -gt 0) { [void]$lines.Add("# Continuous: the window repeats it every $IntervalSeconds s until Stop.") }
    [void]$lines.Add("`$names = $list")
    [void]$lines.Add('foreach ($n in $names) {')
    [void]$lines.Add('    try {')
    [void]$lines.Add("        `$r = (New-Object System.Net.NetworkInformation.Ping).Send(`$n, $TimeoutMs)")
    [void]$lines.Add('        [pscustomobject]@{ Computer = $n; Status = [string]$r.Status; Address = [string]$r.Address; TimeMs = $r.RoundtripTime }')
    [void]$lines.Add('    }')
    [void]$lines.Add('    catch {')
    [void]$lines.Add('        $m = $_.Exception; while ($m.InnerException) { $m = $m.InnerException }')
    [void]$lines.Add('        [pscustomobject]@{ Computer = $n; Status = ''Error''; Address = $m.Message; TimeMs = $null }')
    [void]$lines.Add('    }')
    [void]$lines.Add('}')
    return ($lines -join "`r`n")
}
#endregion

#region -- Start-PingRound ------------------------------------------------------
function Start-PingRound {
    <#
    .SYNOPSIS
        Sends one echo request to every name, all at once, and returns
        immediately. Poll each returned item with Get-PingRoundResult.
    .OUTPUTS
        List of PSCustomObject: Name, Ping, Task, Error, Started, TimeoutMs.
    #>
    param([string[]]$Names, [int]$TimeoutMs = 1000)
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($n in @($Names)) {
        if (-not $n) { continue }
        $p = $null; $task = $null; $err = ''
        try {
            $p    = New-Object System.Net.NetworkInformation.Ping
            $task = $p.SendPingAsync($n, $TimeoutMs)
        }
        catch {
            $m = $_.Exception; while ($m.InnerException) { $m = $m.InnerException }
            $err = $m.Message
        }
        [void]$list.Add([pscustomobject]@{ Name = $n; Ping = $p; Task = $task; Error = $err; Started = [datetime]::Now; TimeoutMs = $TimeoutMs })
    }
    return , $list
}
#endregion

#region -- Get-PingRoundResult --------------------------------------------------
function Get-PingRoundResult {
    <#
    .SYNOPSIS
        $null while the item's echo is still in flight; otherwise
        PSCustomObject: Name, Up [bool], Status, Address, TimeMs, Detail.
        An item that has not finished 5 s after its own timeout (a name
        lookup that hangs) is reported as TimedOut.
    #>
    param($Item)
    $res = [pscustomobject]@{ Name = $Item.Name; Up = $false; Status = ''; Address = ''; TimeMs = $null; Detail = '' }
    if ($Item.Error) {
        $res.Status = 'Error'; $res.Detail = [string]$Item.Error
        if ($Item.Ping) { try { $Item.Ping.Dispose() } catch { } }
        return $res
    }
    $t = $Item.Task
    if (-not $t) { $res.Status = 'Error'; $res.Detail = 'Not sent.'; return $res }
    if (-not $t.IsCompleted) {
        if (([datetime]::Now - $Item.Started).TotalMilliseconds -lt ($Item.TimeoutMs + 5000)) { return $null }
        $res.Status = 'TimedOut'; $res.Detail = 'No answer (name lookup or echo did not finish).'
        return $res
    }
    try {
        if ($t.IsFaulted -or $t.IsCanceled) {
            $m = $t.Exception
            if ($m) { while ($m.InnerException) { $m = $m.InnerException } }
            $res.Status = 'Error'
            if ($m) { $res.Detail = $m.Message } else { $res.Detail = 'Cancelled.' }
        }
        else {
            $r = $t.Result
            $res.Status = [string]$r.Status
            if ($r.Address) { $res.Address = $r.Address.ToString() }
            if ($r.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
                $res.Up = $true
                $res.TimeMs = [int]$r.RoundtripTime
            }
        }
    }
    catch { $res.Status = 'Error'; $res.Detail = $_.Exception.Message }
    finally { if ($Item.Ping) { try { $Item.Ping.Dispose() } catch { } } }
    return $res
}
#endregion
