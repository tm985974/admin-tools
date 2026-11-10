# Services_RadminBatch.psm1   (LITE TIER)
#
# Runs the Radmin core (Services_Radmin.psm1) against many machines at once
# without freezing the window. Two ways to reach a remote machine:
#
#   WinRM    Invoke-Command -AsJob (PowerShell remoting, TCP 5985).
#   SMB      for networks where WinRM is off: the core and its options are
#            copied to the machine's admin share (\\PC\C$\FAS\_rlm\<id>\), WMI
#            (Win32_Process.Create over DCOM, TCP 135 + RPC) starts PowerShell
#            there to run it, and the result is read back from the share. The
#            job folder (it holds the key / license) is deleted afterwards.
#   Auto     WinRM first; when WinRM cannot connect, the same machine is retried
#            over SMB. A machine that worked over SMB before goes straight there.
#
# This machine (its own name, localhost, .) always runs in-process.
# At most -Parallel machines run at once; a WinForms timer collects the results
# on the UI thread.
#
#   $b = Start-RadminBatch -App $App -Action Request -Items $items -Transport Auto -Parallel 16 -TimeoutSec 150 `
#          [-Credential $cred] -OnResult { param($Item, $Result) ... } -OnDone { param($Summary) ... }
#   & $b.Stop          stop: running work is stopped, queued machines are dropped
#
#   $items = @( @{ Target = 'PC-01'; Opt = <New-RadminOptions>; Row = <anything>; Via = 'SMB' (last route, optional) }, ... )
#   $Result = the core's result (Ok, Skipped, Computer, Licensed, Message, FileBytes ...) plus Via
#             (Local | WinRM | SMB). Unreachable: Ok = $false and the error as Message.
#   $Summary = @{ Total; Ok; Failed; Skipped; Stopped }

# ---------------------------------------------------------------------------
# SMB + WMI runner - runs in a background runspace, returns the core's result
# ---------------------------------------------------------------------------
$script:RadminSmbRunner = {
    param([string]$Computer, [string]$Action, [hashtable]$Opt, [string]$CoreText, $Credential, [int]$TimeoutSec)
    $ErrorActionPreference = 'Stop'
    $r = $null; $drive = $null; $cim = $null; $uncJob = ''
    $step = 'start'
    try {
        $dev = [string]$Opt.DeviceFolder
        if (-not $dev) { $dev = 'C:\FAS' }
        if ($dev -notmatch '^[A-Za-z]:\\') { throw "the device folder must be a plain local path such as C:\FAS for the SMB route (it is '$dev')." }
        $dev = $dev.TrimEnd('\')
        $share = '\\' + $Computer + '\' + $dev.Substring(0, 1) + '$'
        if ($Opt.ContainsKey('_ShareRoot') -and $Opt._ShareRoot) { $share = [string]$Opt._ShareRoot }    # tests only
        $rest  = $dev.Substring(3)

        $step = "open $share"
        if ($Credential) {
            $drive = New-PSDrive -Name ('RLM' + [guid]::NewGuid().ToString('N').Substring(0, 8)) -PSProvider FileSystem -Root $share -Credential $Credential
        }
        if (-not (Test-Path -LiteralPath $share)) { throw "cannot open $share (admin share off, no access, or machine off)." }

        $id     = [guid]::NewGuid().ToString('N')
        $jobDir = $dev + '\_rlm\' + $id                                  # as the target sees it
        $uncJob = $share
        foreach ($part in @($rest -split '\\') + @('_rlm', $id)) { if ($part) { $uncJob = Join-Path $uncJob $part } }

        $step = 'copy the job'
        New-Item -ItemType Directory -Path $uncJob -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $uncJob 'core.ps1'), $CoreText)
        @{ Action = $Action; Opt = $Opt } | Export-Clixml -LiteralPath (Join-Path $uncJob 'in.xml')

        # -EncodedCommand is not subject to the execution policy (a .ps1 file would be).
        # Plain string paths (no Join-Path): if anything fails, err.txt must still be writable.
        $boot = "`$d = '$jobDir'; try { `$o = Import-Clixml -LiteralPath (`$d + '\in.xml'); " +
                "`$sb = [scriptblock]::Create([IO.File]::ReadAllText(`$d + '\core.ps1')); " +
                "`$res = & `$sb `$o.Action `$o.Opt; `$res | Export-Clixml -LiteralPath (`$d + '\out.tmp'); " +
                "Move-Item -LiteralPath (`$d + '\out.tmp') -Destination (`$d + '\out.xml') } " +
                "catch { [IO.File]::WriteAllText(`$d + '\err.txt', [string]`$_.Exception.Message) }"
        $cmd = 'powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden -EncodedCommand ' +
               [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($boot))

        $step = 'start it with WMI'
        $cp = @{ ComputerName = $Computer; SessionOption = (New-CimSessionOption -Protocol Dcom); OperationTimeoutSec = 30 }
        if ($Credential) { $cp.Credential = $Credential }
        $cim = New-CimSession @cp
        $ret = Invoke-CimMethod -CimSession $cim -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $cmd; CurrentDirectory = $dev }
        if ([int]$ret.ReturnValue -ne 0) { throw "Win32_Process.Create returned $($ret.ReturnValue) (2 = access denied)." }

        $step = 'wait for the result'
        $until = (Get-Date).AddSeconds([Math]::Max(30, $TimeoutSec))
        while ((Get-Date) -lt $until) {
            if (Test-Path -LiteralPath (Join-Path $uncJob 'out.xml')) { $r = Import-Clixml -LiteralPath (Join-Path $uncJob 'out.xml'); break }
            if (Test-Path -LiteralPath (Join-Path $uncJob 'err.txt')) { throw ('the remote PowerShell failed: ' + (Get-Content -LiteralPath (Join-Path $uncJob 'err.txt') -Raw).Trim()) }
            Start-Sleep -Milliseconds 700
        }
        if (-not $r) { throw "no result after $TimeoutSec s (PowerShell started but did not finish - blocked by AppLocker / antivirus?)." }
    }
    catch {
        $m = ($_.Exception.Message -replace '\s+', ' ').Trim()
        if ($step -eq 'start it with WMI' -and $m -match '(?i)RPC server is unavailable|0x800706BA') { $m = 'WMI not reachable (TCP 135 / RPC blocked by the firewall). ' + $m }
        elseif ($m -match '(?i)access is denied|0x80070005') { $m = 'Access denied - use Credential... with an account that is admin on that machine (local accounts need LocalAccountTokenFilterPolicy). ' + $m }
        $r = [pscustomobject]@{ Action = $Action; Computer = ''; Ok = $false; Skipped = $false; RadminFound = $null; Licensed = $null
                                Message = "SMB/WMI ($step): $m"; FileBytes = $null; Time = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') }
    }
    finally {
        if ($uncJob) { for ($i = 0; $i -lt 3; $i++) { try { if (Test-Path -LiteralPath $uncJob) { Remove-Item -LiteralPath $uncJob -Recurse -Force }; break } catch { Start-Sleep -Milliseconds 500 } } }
        if ($cim)   { try { Remove-CimSession -CimSession $cim } catch { } }
        if ($drive) { try { Remove-PSDrive -Name $drive.Name -Force } catch { } }
    }
    return $r
}

function Start-RadminBatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $App,
        [Parameter(Mandatory)] [ValidateSet('Status', 'Request', 'License')] [string]$Action,
        [Parameter(Mandatory)] [object[]]$Items,
        [ValidateSet('Auto', 'WinRM', 'SMB')] [string]$Transport = 'Auto',
        [int]$Parallel = 16,
        [int]$TimeoutSec = 120,
        [System.Management.Automation.PSCredential]$Credential = $null,
        [Parameter(Mandatory)] [scriptblock]$OnResult,
        [scriptblock]$OnDone = $null
    )

    $core     = Get-RadminCore
    $coreText = $core.ToString()
    $smbText  = $script:RadminSmbRunner.ToString()
    $isLocal  = ${function:Test-RadminLocalTarget}
    $queue    = New-Object System.Collections.Generic.Queue[object]
    foreach ($i in $Items) { $queue.Enqueue($i) }

    $state = @{
        Running = New-Object System.Collections.ArrayList
        Stop    = $false
        Sum     = @{ Total = $Items.Count; Ok = 0; Failed = 0; Skipped = 0; Stopped = $false }
        Timer   = New-Object System.Windows.Forms.Timer
        Session = $null
        Pool    = $null
    }
    try { $state.Session = New-PSSessionOption -OpenTimeout 15000 -OperationTimeout ([Math]::Max(30, $TimeoutSec) * 1000) } catch { }

    $fail = {
        param([string]$Msg, [string]$Via)
        [pscustomobject]@{ Action = $Action; Computer = ''; Ok = $false; Skipped = $false; RadminFound = $null; Licensed = $null
                           Message = $Msg; FileBytes = $null; Time = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); Via = $Via }
    }.GetNewClosure()

    $deliver = {
        param($Item, $Result, [string]$Via)
        try { $Result | Add-Member -NotePropertyName Via -NotePropertyValue $Via -Force } catch { }
        if ($Result.Ok -and $Result.Skipped) { $state.Sum.Skipped++ } elseif ($Result.Ok) { $state.Sum.Ok++ } else { $state.Sum.Failed++ }
        try { & $OnResult $Item $Result }
        catch { $App.Log('ERROR', 'Radmin', "batch result handler ($($Item.Target)): $($_.Exception.Message)") }
    }.GetNewClosure()

    $shortError = {
        param([string]$m)
        $m = ($m -replace '\s+', ' ').Trim()
        if ($m -match '(?i)cannot connect to the destination|WinRM cannot complete the operation|WS-Management|5985') { $m = 'WinRM not reachable (machine off, firewall, or WinRM not enabled). ' + $m }
        elseif ($m -match '(?i)Access is denied') { $m = 'Access denied - use Credential... with an admin account on that machine. ' + $m }
        if ($m.Length -gt 400) { $m = $m.Substring(0, 400) + ' ...' }
        return $m
    }
    $winrmDown = { param([string]$m) return ($m -match '(?i)WinRM not reachable|cannot connect to the destination|WS-Management|WSMan|WinRM cannot complete|5985|network path was not found') }

    $startSmb = {
        param($item)
        if (-not $state.Pool) {
            $state.Pool = [runspacefactory]::CreateRunspacePool(1, [Math]::Max(1, $Parallel))
            $state.Pool.Open()
        }
        $ps = [powershell]::Create()
        $ps.RunspacePool = $state.Pool
        [void]$ps.AddScript($smbText).AddArgument([string]$item.Target).AddArgument($Action).AddArgument($item.Opt).AddArgument($coreText).AddArgument($Credential).AddArgument([int]$TimeoutSec)
        $h = $ps.BeginInvoke()
        [void]$state.Running.Add(@{ Item = $item; Via = 'SMB'; PS = $ps; Handle = $h; Started = (Get-Date) })
    }.GetNewClosure()

    $startWinRm = {
        param($item)
        $p = @{ ComputerName = [string]$item.Target; ScriptBlock = $core; ArgumentList = @($Action, $item.Opt); AsJob = $true; ErrorAction = 'Stop' }
        if ($state.Session) { $p.SessionOption = $state.Session }
        if ($Credential) { $p.Credential = $Credential }
        $job = Invoke-Command @p
        [void]$state.Running.Add(@{ Item = $item; Via = 'WinRM'; Job = $job; Started = (Get-Date) })
    }.GetNewClosure()

    # WinRM failed to connect: in Auto, try the same machine over SMB instead of reporting it.
    $retrySmb = {
        param($item, [string]$msg)
        if ($Transport -ne 'Auto' -or $item.TriedSmb -or $state.Stop -or -not (& $winrmDown $msg)) { return $false }
        $item.TriedSmb = $true
        $item.WinRmError = $msg
        & $startSmb $item
        return $true
    }.GetNewClosure()

    $tick = {
        $state.Timer.Stop()
        try {
            # ---- collect finished work ----
            for ($i = $state.Running.Count - 1; $i -ge 0; $i--) {
                $run = $state.Running[$i]
                $late = ((Get-Date) - $run.Started).TotalSeconds -gt ($TimeoutSec + 30)

                if ($run.Via -eq 'SMB') {
                    if (-not $late -and -not $run.Handle.IsCompleted) { continue }
                    $state.Running.RemoveAt($i)
                    $res = $null
                    if ($late) { try { $run.PS.Stop() } catch { } }
                    else {
                        try { $res = @($run.PS.EndInvoke($run.Handle)) | Where-Object { $_ -and $_.PSObject.Properties['Action'] } | Select-Object -Last 1 } catch { $res = & $fail ("SMB/WMI: " + $_.Exception.Message) 'SMB' }
                    }
                    try { $run.PS.Dispose() } catch { }
                    if (-not $res) { $res = & $fail ("SMB/WMI: no result after $TimeoutSec s - stopped.") 'SMB' }
                    if (-not $res.Ok -and $run.Item.WinRmError) { $res.Message = [string]$res.Message + '   [WinRM: ' + $run.Item.WinRmError + ']' }
                    & $deliver $run.Item $res 'SMB'
                    continue
                }

                $job = $run.Job
                if (-not $late -and $job.State -notin @('Completed', 'Failed', 'Stopped', 'Disconnected')) { continue }
                $state.Running.RemoveAt($i)
                $res = $null; $errs = $null
                if ($late) { try { Stop-Job -Job $job } catch { } }
                try { $res = @(Receive-Job -Job $job -ErrorAction SilentlyContinue -ErrorVariable errs) | Where-Object { $_ -and $_.PSObject.Properties['Action'] } | Select-Object -Last 1 } catch { }
                try { Remove-Job -Job $job -Force } catch { }
                if (-not $res) {
                    $msg = ''
                    try { $msg = [string]$job.ChildJobs[0].JobStateInfo.Reason.Message } catch { }
                    if (-not $msg -and $errs) { $msg = [string]$errs[0] }
                    if ($late) { $msg = "No answer after $TimeoutSec s - stopped. $msg" }
                    if (-not $msg) { $msg = "Remote call ended ($($job.State)) without a result." }
                    $msg = & $shortError $msg
                    if (& $retrySmb $run.Item $msg) { continue }
                    $res = & $fail $msg 'WinRM'
                }
                & $deliver $run.Item $res 'WinRM'
            }

            # ---- start more ----
            while (-not $state.Stop -and $queue.Count -gt 0 -and $state.Running.Count -lt [Math]::Max(1, $Parallel)) {
                $item = $queue.Dequeue()
                if (& $isLocal $item.Target) {
                    $res = $null
                    try { $res = & $core $Action $item.Opt } catch { $res = & $fail $_.Exception.Message 'Local' }
                    & $deliver $item $res 'Local'
                    break                                  # in-process work: let the window paint before the next one
                }
                $useSmb = ($Transport -eq 'SMB') -or ($Transport -eq 'Auto' -and [string]$item.Via -eq 'SMB')
                try {
                    if ($useSmb) { $item.TriedSmb = $true; & $startSmb $item }
                    else { & $startWinRm $item }
                }
                catch {
                    $msg = & $shortError $_.Exception.Message
                    $retried = $false
                    if (-not $useSmb) { try { $retried = & $retrySmb $item $msg } catch { } }
                    if (-not $retried) { & $deliver $item (& $fail $msg $(if ($useSmb) { 'SMB' } else { 'WinRM' })) $(if ($useSmb) { 'SMB' } else { 'WinRM' }) }
                }
            }
        }
        catch { $App.Log('ERROR', 'Radmin', "batch tick: $($_.Exception.ToString())") }

        if ($state.Running.Count -eq 0 -and ($queue.Count -eq 0 -or $state.Stop)) {
            $state.Sum.Stopped = [bool]$state.Stop
            $state.Timer.Dispose()
            if ($state.Pool) { try { $state.Pool.Close(); $state.Pool.Dispose() } catch { } }
            if ($OnDone) { try { & $OnDone $state.Sum } catch { $App.Log('ERROR', 'Radmin', "batch done handler: $($_.Exception.Message)") } }
            return
        }
        $state.Timer.Start()
    }.GetNewClosure()

    $state.Timer.Interval = 300
    $state.Timer.Add_Tick($tick)
    $state.Timer.Start()
    $App.Log('INFO', 'Radmin', "batch $Action started: $($Items.Count) machine(s), $Parallel at a time, via $Transport" + $(if ($Credential) { ", as $($Credential.UserName)" } else { '' }) + '.')

    return @{
        Stop  = {
            $state.Stop = $true
            foreach ($r in @($state.Running)) {
                if ($r.Job) { try { Stop-Job -Job $r.Job } catch { } }
                if ($r.PS)  { try { [void]$r.PS.BeginStop($null, $null) } catch { } }
            }
        }.GetNewClosure()
        State = $state
    }
}
