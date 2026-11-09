# Services_RadminBatch.psm1   (LITE TIER)
#
# Runs the Radmin core (Services_Radmin.psm1) against many machines at once
# without freezing the window: remote machines go through
# Invoke-Command -AsJob (WinRM), at most -Parallel at a time, and a WinForms
# timer collects the results on the UI thread. This machine (its own name,
# localhost, .) runs in-process instead - no WinRM needed for it.
#
#   $b = Start-RadminBatch -App $App -Action Request -Items $items -Parallel 16 -TimeoutSec 120 `
#          [-Credential $cred] -OnResult { param($Item, $Result) ... } -OnDone { param($Summary) ... }
#   & $b.Stop          stop: running jobs are stopped, queued ones are dropped
#
#   $items = @( @{ Target = 'PC-01'; Opt = <hashtable from New-RadminOptions>; Row = <anything> }, ... )
#   $Result = the core's result object (Ok, Skipped, Computer, Licensed, Message, FileBytes ...).
#             A machine that cannot be reached gets Ok = $false and the WinRM error as Message.
#   $Summary = @{ Total; Ok; Failed; Skipped; Stopped }

function Start-RadminBatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $App,
        [Parameter(Mandatory)] [ValidateSet('Status', 'Request', 'License')] [string]$Action,
        [Parameter(Mandatory)] [object[]]$Items,
        [int]$Parallel = 16,
        [int]$TimeoutSec = 120,
        [System.Management.Automation.PSCredential]$Credential = $null,
        [Parameter(Mandatory)] [scriptblock]$OnResult,
        [scriptblock]$OnDone = $null
    )

    $core    = Get-RadminCore
    $isLocal = ${function:Test-RadminLocalTarget}
    $queue   = New-Object System.Collections.Generic.Queue[object]
    foreach ($i in $Items) { $queue.Enqueue($i) }

    $state = @{
        Running = New-Object System.Collections.ArrayList
        Stop    = $false
        Sum     = @{ Total = $Items.Count; Ok = 0; Failed = 0; Skipped = 0; Stopped = $false }
        Timer   = New-Object System.Windows.Forms.Timer
        Session = (New-PSSessionOption -OpenTimeout 20000 -OperationTimeout ([Math]::Max(30, $TimeoutSec) * 1000))
    }

    $fail = {
        param([string]$Target, [string]$Msg)
        [pscustomobject]@{ Action = $Action; Computer = ''; Ok = $false; Skipped = $false; RadminFound = $null; Licensed = $null
                           Message = $Msg; FileBytes = $null; Time = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') }
    }.GetNewClosure()

    $deliver = {
        param($Item, $Result)
        if ($Result.Ok -and $Result.Skipped) { $state.Sum.Skipped++ } elseif ($Result.Ok) { $state.Sum.Ok++ } else { $state.Sum.Failed++ }
        try { & $OnResult $Item $Result }
        catch { $App.Log('ERROR', 'Radmin', "batch result handler ($($Item.Target)): $($_.Exception.Message)") }
    }.GetNewClosure()

    $shortError = {
        param([string]$m)
        $m = ($m -replace '\s+', ' ').Trim()
        if ($m -match '(?i)WinRM cannot complete the operation') { $m = 'WinRM not reachable (machine off, firewall, or WinRM not enabled). ' + $m }
        elseif ($m -match '(?i)Access is denied') { $m = 'Access denied - use Credential... with an admin account on that machine. ' + $m }
        if ($m.Length -gt 400) { $m = $m.Substring(0, 400) + ' ...' }
        return $m
    }

    $tick = {
        $state.Timer.Stop()
        try {
            # ---- collect finished jobs ----
            for ($i = $state.Running.Count - 1; $i -ge 0; $i--) {
                $run = $state.Running[$i]
                $job = $run.Job
                $late = ((Get-Date) - $run.Started).TotalSeconds -gt ($TimeoutSec + 30)
                if (-not $late -and $job.State -notin @('Completed', 'Failed', 'Stopped', 'Disconnected')) { continue }
                $state.Running.RemoveAt($i)
                $res = $null; $errs = $null
                if ($late) { try { Stop-Job -Job $job } catch { } }
                try { $res = @(Receive-Job -Job $job -ErrorAction SilentlyContinue -ErrorVariable errs) | Where-Object { $_ -and $_.PSObject.Properties['Action'] } | Select-Object -Last 1 } catch { }
                if (-not $res) {
                    $msg = ''
                    try { $msg = [string]$job.ChildJobs[0].JobStateInfo.Reason.Message } catch { }
                    if (-not $msg -and $errs) { $msg = [string]$errs[0] }
                    if ($late) { $msg = "No answer after $TimeoutSec s - stopped. $msg" }
                    if (-not $msg) { $msg = "Remote call ended ($($job.State)) without a result." }
                    $res = & $fail $run.Item.Target (& $shortError $msg)
                }
                try { Remove-Job -Job $job -Force } catch { }
                & $deliver $run.Item $res
            }

            # ---- start more ----
            while (-not $state.Stop -and $queue.Count -gt 0 -and $state.Running.Count -lt [Math]::Max(1, $Parallel)) {
                $item = $queue.Dequeue()
                if (& $isLocal $item.Target) {
                    $res = $null
                    try { $res = & $core $Action $item.Opt } catch { $res = & $fail $item.Target $_.Exception.Message }
                    & $deliver $item $res
                    break                                  # in-process work: let the window paint before the next one
                }
                try {
                    $p = @{ ComputerName = [string]$item.Target; ScriptBlock = $core; ArgumentList = @($Action, $item.Opt)
                            AsJob = $true; SessionOption = $state.Session; ErrorAction = 'Stop' }
                    if ($Credential) { $p.Credential = $Credential }
                    $job = Invoke-Command @p
                    [void]$state.Running.Add(@{ Item = $item; Job = $job; Started = (Get-Date) })
                }
                catch { & $deliver $item (& $fail $item.Target (& $shortError $_.Exception.Message)) }
            }
        }
        catch { $App.Log('ERROR', 'Radmin', "batch tick: $($_.Exception.ToString())") }

        if ($state.Running.Count -eq 0 -and ($queue.Count -eq 0 -or $state.Stop)) {
            $state.Sum.Stopped = [bool]$state.Stop
            $state.Timer.Dispose()
            if ($OnDone) { try { & $OnDone $state.Sum } catch { $App.Log('ERROR', 'Radmin', "batch done handler: $($_.Exception.Message)") } }
            return
        }
        $state.Timer.Start()
    }.GetNewClosure()

    $state.Timer.Interval = 300
    $state.Timer.Add_Tick($tick)
    $state.Timer.Start()
    $App.Log('INFO', 'Radmin', "batch $Action started: $($Items.Count) machine(s), $Parallel at a time" + $(if ($Credential) { ", as $($Credential.UserName)" } else { '' }) + '.')

    return @{
        Stop  = {
            $state.Stop = $true
            foreach ($r in @($state.Running)) { try { Stop-Job -Job $r.Job } catch { } }
        }.GetNewClosure()
        State = $state
    }
}
