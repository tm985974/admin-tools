# Services_CcmJobs.psm1   (ADMIN TIER)
#
# Runs one long native tool at a time (sfc, DISM, chkdsk, ccmsetup ...) in its
# own VISIBLE console window, so the operator sees the tool's real progress and
# nothing runs hidden. A WinForms timer (UI thread) polls for completion, so the
# window stays responsive and the result handler runs in this runspace.
#
#   $job = Start-CcmJob -App $App -Name 'sfc' -FilePath sfc.exe -Arguments '/scannow' `
#              [-WaitForProcess 'ccmsetup','msiexec'] [-OnTick { param($job) }] -OnExit { param($exitCode, $job) }
#   Get-CcmActiveJob        the running job or $null
#
# -WaitForProcess: after the started process exits, keep waiting until no
# process with these names is left (ccmsetup hands work to child processes).
# Jobs cannot be cancelled from the tool on purpose - killing DISM / SFC /
# ccmsetup half-way does more harm than waiting.

function Get-CcmActiveJob {
    [CmdletBinding()]
    param()
    $st = Get-CcmTSState
    if ($st.Job -and -not $st.Job.Finished) { return $st.Job }
    return $null
}

function Start-CcmJob {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $App,
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [string]$FilePath,
        [string]$Arguments = '',
        [string[]]$WaitForProcess = @(),
        [string]$WorkingDirectory = '',
        [scriptblock]$OnTick = $null,
        [Parameter(Mandatory)] [scriptblock]$OnExit
    )
    $st = Get-CcmTSState
    if (Get-CcmActiveJob) { throw "A step is already running: $($st.Job.Name)" }

    $sp = @{ FilePath = $FilePath; PassThru = $true; ErrorAction = 'Stop' }
    if ($Arguments) { $sp['ArgumentList'] = $Arguments }
    if ($WorkingDirectory) { $sp['WorkingDirectory'] = $WorkingDirectory } else { $sp['WorkingDirectory'] = (Join-Path $env:windir 'System32') }
    $p = Start-Process @sp
    $null = $p.Handle            # keep the handle so ExitCode is readable after exit

    $job = [pscustomobject]@{
        Name     = $Name
        Process  = $p
        Started  = Get-Date
        Phase    = 'Main'        # Main -> Wait -> Done
        GraceTo  = [datetime]::MaxValue
        ExitCode = $null
        Finished = $false
        Command  = ("{0} {1}" -f $FilePath, $Arguments).Trim()
    }
    $st.Job = $job
    try { $App.Log('INFO', 'Job', "started: $($job.Command) (pid $($p.Id))") } catch { }

    $waitNames = @($WaitForProcess | Where-Object { $_ })
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 1000
    $timer.Add_Tick({
        try {
            if ($job.Phase -eq 'Main' -and $job.Process.HasExited) {
                try { $job.ExitCode = $job.Process.ExitCode } catch { $job.ExitCode = $null }
                $job.Phase = 'Wait'
                $job.GraceTo = (Get-Date).AddSeconds(5)
            }
            if ($job.Phase -eq 'Wait' -and (Get-Date) -ge $job.GraceTo) {
                $left = @()
                foreach ($n in $waitNames) { $left += @(Get-Process -Name $n -ErrorAction SilentlyContinue) }
                if ($left.Count -eq 0) { $job.Phase = 'Done' }
            }
            if ($OnTick) { try { & $OnTick $job } catch { } }
            if ($job.Phase -eq 'Done') {
                $timer.Stop()
                $job.Finished = $true
                try { $App.Log('INFO', 'Job', "finished: $($job.Name) exit=$($job.ExitCode) after $([int]((Get-Date) - $job.Started).TotalSeconds) s") } catch { }
                try { & $OnExit $job.ExitCode $job }
                catch { try { $App.Log('ERROR', 'Job', "$($job.Name) result handler: $($_.Exception.ToString())") } catch { } }
                $timer.Dispose()
            }
        }
        catch { try { $App.Log('ERROR', 'Job', "$($job.Name) poll: $($_.Exception.Message)") } catch { } }
    }.GetNewClosure())
    $timer.Start()
    return $job
}
