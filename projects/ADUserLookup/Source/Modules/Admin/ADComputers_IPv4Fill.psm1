#region -- ADComputers.IPv4Fill.psm1 --------------------------------------------
# Concern : Fills the IPv4Address column of a computer list in the background
#           (v1.2.20). Asking AD for IPv4Address (Get-ADComputer -Properties
#           IPv4Address) makes the cmdlet resolve every computer's DNS name, one
#           after another, before the list can show - minutes on a large domain.
#           The list now loads without it and this resolves the names afterwards:
#           up to -Parallel DNS lookups at a time (.NET async, so nothing waits on
#           the window's thread); a WinForms timer collects the answers, writes
#           them into the list's objects (so filter / sort / export see them) and
#           into the grid's IP cells in place (no refill, selection kept).
#           Same address AD reports: the first IPv4 address of the DNSHostName.
#
#   Start-ADIPv4Fill -Items $list -HostNames @{ Name = DNSHostName } -Grid $grid [-Parallel 24]
#   Stop-ADIPv4Fill            (a new Start also stops the previous fill)
#endregion

$script:IPv4Fill = $null

function Stop-ADIPv4Fill {
    param($State = $null)
    $s = if ($State) { $State } else { $script:IPv4Fill }
    if (-not $s -or $s.Stopped) { return }
    $s.Stopped = $true
    try { $s.Timer.Stop(); $s.Timer.Dispose() } catch { }
    if ($script:IPv4Fill -eq $s) { $script:IPv4Fill = $null }
}

function Invoke-ADIPv4FillTick {
    param($State)
    if ($State.Stopped) { return }
    if (-not $State.Grid -or $State.Grid.IsDisposed) { Stop-ADIPv4Fill -State $State; return }

    # collect finished lookups
    $resolved = @{}
    for ($i = $State.Running.Count - 1; $i -ge 0; $i--) {
        $r = $State.Running[$i]
        if (-not $r.Task.IsCompleted) { continue }
        $State.Running.RemoveAt($i)
        $ip = ''
        if ($r.Task.Status -eq [System.Threading.Tasks.TaskStatus]::RanToCompletion) {
            foreach ($a in @($r.Task.Result)) {
                if ($a.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) { $ip = $a.IPAddressToString; break }
            }
        }
        if ($ip) {
            $r.Item.IPv4Address = $ip
            $resolved[[string]$r.Item.Name] = $ip
        }
        $State.Done++
    }

    # start more
    while ($State.Running.Count -lt $State.Parallel -and $State.Queue.Count -gt 0) {
        $it = $State.Queue.Dequeue()
        $h = [string]$State.Hosts[[string]$it.Name]
        if (-not $h) { $h = [string]$it.Name }
        try { [void]$State.Running.Add(@{ Item = $it; Task = [System.Net.Dns]::GetHostAddressesAsync($h) }) }
        catch { $State.Done++ }
    }

    # show the new addresses in the grid's rows (whatever the filter / sort)
    $g = $State.Grid
    if ($resolved.Count -gt 0 -and $g.Columns.Contains('IPv4Address') -and $g.Columns.Contains('Name')) {
        $ci = $g.Columns['IPv4Address'].Index
        $ni = $g.Columns['Name'].Index
        foreach ($row in $g.Rows) {
            $n = [string]$row.Cells[$ni].Value
            if ($resolved.ContainsKey($n)) { $row.Cells[$ci].Value = $resolved[$n] }
        }
    }

    if ($State.Queue.Count -eq 0 -and $State.Running.Count -eq 0) {
        Stop-ADIPv4Fill -State $State
        $secs = [int]((Get-Date) - $State.Started).TotalSeconds
        if ($script:ADApp) { $script:ADApp.Log('INFO', 'Computers', "IP addresses resolved for $($State.Total) computer(s) in $secs s.") }
    }
}

function Start-ADIPv4Fill {
    param(
        $Items,
        [hashtable]$HostNames = @{},
        [System.Windows.Forms.DataGridView]$Grid,
        [int]$Parallel = 24
    )
    Stop-ADIPv4Fill
    $queue = New-Object System.Collections.Generic.Queue[object]
    foreach ($it in @($Items)) { if ($it -and -not $it.IPv4Address) { $queue.Enqueue($it) } }
    if ($queue.Count -eq 0 -or -not $Grid) { return }
    $state = @{
        Queue = $queue; Running = (New-Object System.Collections.ArrayList); Hosts = $HostNames; Grid = $Grid
        Parallel = [Math]::Max(1, $Parallel); Done = 0; Total = $queue.Count; Started = (Get-Date); Stopped = $false
        Timer = (New-Object System.Windows.Forms.Timer)
    }
    $script:IPv4Fill = $state
    $tickFn = ${function:Invoke-ADIPv4FillTick}     # captured: bare names are unreliable inside .GetNewClosure()
    $stopFn = ${function:Stop-ADIPv4Fill}
    $app    = $script:ADApp
    $state.Timer.Interval = 150
    $state.Timer.Add_Tick({
        try { & $tickFn $state }
        catch {
            & $stopFn $state                         # never keep ticking on an error
            if ($app) { $app.Log('WARN', 'Computers', "IP address fill stopped: $($_.Exception.Message)") }
        }
    }.GetNewClosure())
    $state.Timer.Start()
}

Export-ModuleMember -Function Start-ADIPv4Fill, Stop-ADIPv4Fill
