#region -- ADComputers.Restart.Engine.psm1 -------------------------------------
# Concern : Invoke-RemoteRestart / Invoke-TimedRestart / Invoke-AbortRemoteRestart
#           - shutdown.exe wrappers for one or more remote computers. Logic
#           only, no UI. Parallel to ADComputers.BitLocker.Lookup /
#           ADComputers.LAPS.Lookup (lookup/engine module paired with its own
#           dialog module).
# Load order: 85b - depends on Services.AD.Reporting (Write-OperationLog is
#                            actually in Services.Logging - see below),
#                            Services.Logging (Write-OperationLog).
#             Must load before ADDirectory.Menus (15) is INVOKED (not
#             dot-sourced) - same "captured at run time" rule documented on
#             ADComputers.Sessions.Dialog (85a); this module can load
#             anywhere in the ADComputers block.
# Split from: (new module)
# Notes     : Same native-RPC approach as ADComputers.Sessions.Dialog's Force
#             Logoff (logoff.exe /server:) and ADDirectory.UserSessions.Dialog
#             - shells out to shutdown.exe via System.Diagnostics.ProcessStartInfo
#             against \\ComputerName. No WinRM / Invoke-Command / CIM session
#             dependency, consistent with every other remote action in this
#             suite even though PS Remoting is enabled on this host (see
#             NetworkEnvironment.txt) - that capability is simply not used
#             anywhere in this codebase for remote target actions.
#             shutdown.exe requires the remote registry / admin$ RPC path
#             (same underlying access as the C$ share browse action added
#             alongside this module) - no separate firewall rule beyond what
#             File and Printer Sharing / remote admin already requires.
#             Every function here returns the same OkCount/FailCount/Results
#             shape as Invoke-DeleteComputers (ADDirectory.Context.DeleteComputer)
#             so callers (menu handlers, the Timed Restart dialog, the Abort
#             Remote Reboot tab) can render results identically.
#             Invoke-TimedRestart also fires a modal msg.exe pop-up to the
#             remote computer (Invoke-RemoteMessage, private helper below)
#             immediately, alongside shutdown.exe's own /c countdown
#             notification. shutdown /c alone only feeds the OS's built-in
#             restart-countdown toast, which is tied to the logged-on
#             session, dismissible with one click, and can be silently
#             suppressed (Focus Assist, no one logged on) - msg.exe's
#             pop-up is a true modal message box, the same reliable
#             mechanism already used for admin-facing remote messaging
#             conventions on Windows, so the reason/message reliably
#             reaches the remote screen rather than only the admin's
#             tracking email. msg.exe ships with Server 2022 (Remote
#             Desktop Services command-line tools; present per
#             NetworkEnvironment.txt - RDS_Installed: True) - no new
#             dependency beyond what's already documented for this host.
#             No confirmation prompts and no admin-tracking mail live in this
#             module - those are caller concerns (menu handlers / dialogs),
#             same separation of concerns as Invoke-DeleteComputers vs. its
#             callers.
#             No ternary operators, no ??= operator, no -Parallel foreach.
#             PS 5.1 compatible throughout.
#endregion

#region -- Invoke-ShutdownExe (private helper) ---------------------------------
function Invoke-ShutdownExe {
    <#
    .SYNOPSIS
        Runs shutdown.exe with the given argument string and waits for exit.
        Not exported - internal to this module. Shared by every public
        function below so the process-start/wait/exit-code handling lives in
        exactly one place.
    .OUTPUTS
        PSCustomObject: Success [bool], Message [string] (stderr/stdout on
        failure, or '' on success).
    #>
    param([string]$Arguments)

    try {
        $psi                        = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName               = 'shutdown.exe'
        $psi.Arguments              = $Arguments
        $psi.UseShellExecute        = $false
        $psi.CreateNoWindow         = $true
        $psi.RedirectStandardError  = $true
        $psi.RedirectStandardOutput = $true

        $proc = [System.Diagnostics.Process]::Start($psi)
        $proc.WaitForExit(15000) | Out-Null

        if (-not $proc.HasExited) {
            try { $proc.Kill() } catch { }
            return [PSCustomObject]@{ Success = $false; Message = 'Timed out waiting for shutdown.exe.' }
        }

        if ($proc.ExitCode -eq 0) {
            return [PSCustomObject]@{ Success = $true; Message = '' }
        }

        $errText = $proc.StandardError.ReadToEnd().Trim()
        $outText = $proc.StandardOutput.ReadToEnd().Trim()
        $detail  = if ($errText) { $errText } elseif ($outText) { $outText } else { "Exit code $($proc.ExitCode)" }
        return [PSCustomObject]@{ Success = $false; Message = $detail }
    } catch {
        return [PSCustomObject]@{ Success = $false; Message = $_.Exception.Message }
    }
}
#endregion

#region -- Get-RestartArguments / Get-RemoteRestartCommandText -------------------
function Get-RestartArguments {
    <#
    .SYNOPSIS
        The shutdown.exe argument string for one computer - the ONE place it
        is built, so the command shown to the user (Get-RemoteRestartCommandText)
        and the one run (Invoke-ShutdownExe) are always the same.
    .PARAMETER Mode
        Now (forced, immediate), Timed (/t delay + optional /c message) or Abort.
    #>
    param(
        [ValidateSet('Now', 'Timed', 'Abort')] [string]$Mode,
        [string]$Name,
        [int]$DelaySeconds = 0,
        [string]$Message = ''
    )
    switch ($Mode) {
        'Now'   { return "/r /f /t 0 /m \\$Name /c ""Restart initiated by AD-Admin.""" }
        'Abort' { return "/a /m \\$Name" }
        default {
            if ($DelaySeconds -lt 0) { $DelaySeconds = 0 }
            $a = "/r /t $DelaySeconds /m \\$Name"
            if ($Message) { $a += " /c ""$Message""" }
            return $a
        }
    }
}

function Get-RemoteRestartCommandText {
    <#
    .SYNOPSIS
        The exact commands a restart / abort runs for -Names, one line per
        computer (plus the msg.exe pop-up line for a timed restart with a
        message), for the command window (Confirm-Action -Code).
    #>
    param(
        [ValidateSet('Now', 'Timed', 'Abort')] [string]$Mode,
        [string[]]$Names,
        [int]$DelaySeconds = 0,
        [string]$Message = ''
    )
    $safe = $Message
    if ($safe.Length -gt 127) { $safe = $safe.Substring(0, 127) }
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($n in @($Names | Where-Object { $_ } | Select-Object -Unique)) {
        if ($Mode -eq 'Timed' -and $safe) { [void]$lines.Add("msg.exe * /server:$n /time:$DelaySeconds ""$safe""") }
        [void]$lines.Add('shutdown.exe ' + (Get-RestartArguments -Mode $Mode -Name $n -DelaySeconds $DelaySeconds -Message $safe))
    }
    return ($lines -join "`r`n")
}
#endregion

#region -- Invoke-RemoteRestart -------------------------------------------------
function Invoke-RemoteRestart {
    <#
    .SYNOPSIS
        Immediately (forced) restarts one or more remote computers via
        shutdown.exe /r /f /t 0. No confirmation, no mail - caller
        (New-ComputerContextMenu's Restart Now handler) owns Confirm-Action.
    .PARAMETER Names
        One or more computer names.
    .PARAMETER Context
        Shared context object, passed through to Write-OperationLog.
    .OUTPUTS
        PSCustomObject: OkCount [int], FailCount [int], Results
        [PSCustomObject[]] - one entry per requested name with Name/Success/
        Message. $null if Names is empty.
    #>
    param(
        [Parameter(Mandatory)]
        [string[]]$Names,
        [PSCustomObject]$Context
    )

    $names = @($Names | Where-Object { $_ } | Select-Object -Unique)
    if ($names.Count -eq 0) { return $null }

    $ok = 0; $fail = 0
    $itemResults = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($name in $names) {
        $result = Invoke-ShutdownExe -Arguments (Get-RestartArguments -Mode Now -Name $name)
        if ($result.Success) {
            Write-OperationLog -Context $Context -Action 'RESTART-NOW' -Target $name -Result 'OK'
            [void]$itemResults.Add([PSCustomObject]@{ Name = $name; Success = $true; Message = 'Restart initiated' })
            $ok++
        } else {
            Write-OperationLog -Context $Context -Action 'RESTART-NOW' -Target $name -Result 'FAIL' -Detail $result.Message
            [void]$itemResults.Add([PSCustomObject]@{ Name = $name; Success = $false; Message = $result.Message })
            $fail++
        }
    }

    return [PSCustomObject]@{ OkCount = $ok; FailCount = $fail; Results = $itemResults }
}
#endregion

#region -- Invoke-RemoteMessage (private helper) --------------------------------
function Invoke-RemoteMessage {
    <#
    .SYNOPSIS
        Sends a modal pop-up message to every session on a remote computer
        via msg.exe. Not exported - internal helper for Invoke-TimedRestart.
        Best-effort and always non-fatal: a failure here never blocks or
        fails the caller's restart scheduling, it only means the pop-up
        itself didn't reach the remote screen (e.g. no session logged on).
        Native RPC, same approach as every other remote action in this
        suite (logoff.exe /server:, query user /server:) - no WinRM/
        Invoke-Command dependency. msg.exe ships with Server 2022 as part
        of the Remote Desktop Services command-line tools (present on this
        host per NetworkEnvironment.txt - RDS_Installed: True).
    .PARAMETER ComputerName
        The target computer.
    .PARAMETER Message
        Text to display in the pop-up.
    .PARAMETER TimeoutSeconds
        How long the pop-up itself stays on screen before auto-dismissing
        (msg.exe's /time switch) - separate from the restart delay.
    #>
    param(
        [string]$ComputerName,
        [string]$Message,
        [int]$TimeoutSeconds = 60
    )
    if (-not $Message) { return }
    try {
        $psi                        = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName               = 'msg.exe'
        $psi.Arguments              = "* /server:$ComputerName /time:$TimeoutSeconds ""$Message"""
        $psi.UseShellExecute        = $false
        $psi.CreateNoWindow         = $true
        $psi.RedirectStandardError  = $true
        $psi.RedirectStandardOutput = $true
        $proc = [System.Diagnostics.Process]::Start($psi)
        $proc.WaitForExit(15000) | Out-Null
        if (-not $proc.HasExited) { try { $proc.Kill() } catch { } }
    } catch {
        # Non-fatal by design - see .SYNOPSIS above.
    }
}
#endregion


function Invoke-TimedRestart {
    <#
    .SYNOPSIS
        Restarts one or more remote computers after a delay, showing the
        given message on the remote console via shutdown.exe /r /t <seconds>
        /c <message>. No confirmation, no mail - caller (Show-
        TimedRestartDialog) owns Confirm-Action and the admin tracking mail.
    .PARAMETER Names
        One or more computer names.
    .PARAMETER DelaySeconds
        Delay before restart, in seconds (shutdown.exe's /t value). Valid
        range enforced by shutdown.exe itself (0-315360000); no extra
        validation here beyond a positive integer.
    .PARAMETER Message
        Text shown in the remote restart notification (shutdown.exe's /c
        comment, 127-character limit enforced by shutdown.exe itself).
    .PARAMETER Context
        Shared context object, passed through to Write-OperationLog.
    .OUTPUTS
        PSCustomObject: OkCount [int], FailCount [int], Results
        [PSCustomObject[]] - one entry per requested name with Name/Success/
        Message. $null if Names is empty.
    #>
    param(
        [Parameter(Mandatory)]
        [string[]]$Names,
        [Parameter(Mandatory)]
        [int]$DelaySeconds,
        [string]$Message = '',
        [PSCustomObject]$Context
    )

    $names = @($Names | Where-Object { $_ } | Select-Object -Unique)
    if ($names.Count -eq 0) { return $null }
    if ($DelaySeconds -lt 0) { $DelaySeconds = 0 }

    # shutdown.exe's /c comment has a hard 127-character limit - truncate
    # rather than let the call fail outright on a long custom message.
    $safeMessage = $Message
    if ($safeMessage.Length -gt 127) { $safeMessage = $safeMessage.Substring(0, 127) }

    $ok = 0; $fail = 0
    $itemResults = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($name in $names) {
        # Modal pop-up (msg.exe) fires first, immediately, best-effort and
        # non-fatal - independent of whether shutdown.exe itself succeeds
        # below, so the remote user is warned even in the rare case the
        # restart scheduling call fails.
        if ($safeMessage) { Invoke-RemoteMessage -ComputerName $name -Message $safeMessage -TimeoutSeconds $DelaySeconds }

        $result = Invoke-ShutdownExe -Arguments (Get-RestartArguments -Mode Timed -Name $name -DelaySeconds $DelaySeconds -Message $safeMessage)
        if ($result.Success) {
            Write-OperationLog -Context $Context -Action 'RESTART-TIMED' -Target $name -Result 'OK' -Detail "Delay: ${DelaySeconds}s. Message: $safeMessage"
            [void]$itemResults.Add([PSCustomObject]@{ Name = $name; Success = $true; Message = "Restart scheduled in ${DelaySeconds}s" })
            $ok++
        } else {
            Write-OperationLog -Context $Context -Action 'RESTART-TIMED' -Target $name -Result 'FAIL' -Detail $result.Message
            [void]$itemResults.Add([PSCustomObject]@{ Name = $name; Success = $false; Message = $result.Message })
            $fail++
        }
    }

    return [PSCustomObject]@{ OkCount = $ok; FailCount = $fail; Results = $itemResults }
}
#endregion

#region -- Invoke-AbortRemoteRestart --------------------------------------------
function Invoke-AbortRemoteRestart {
    <#
    .SYNOPSIS
        Aborts a pending shutdown/restart on one or more remote computers via
        shutdown.exe /a /m. No confirmation, no mail - caller (the Abort
        Remote Reboot Tools sub-tab) owns those. A target with no pending
        restart returns Success=$false with shutdown.exe's own "no shutdown
        is in progress" text as Message - that is a normal, expected outcome
        here, not a system error, so callers should render it distinctly
        from a genuine connectivity/access failure rather than as a red
        error (they share the same Success=$false shape but different
        Message text).
    .PARAMETER Names
        One or more computer names.
    .PARAMETER Context
        Shared context object, passed through to Write-OperationLog.
    .OUTPUTS
        PSCustomObject: OkCount [int], FailCount [int], Results
        [PSCustomObject[]] - one entry per requested name with Name/Success/
        Message. $null if Names is empty.
    #>
    param(
        [Parameter(Mandatory)]
        [string[]]$Names,
        [PSCustomObject]$Context
    )

    $names = @($Names | Where-Object { $_ } | Select-Object -Unique)
    if ($names.Count -eq 0) { return $null }

    $ok = 0; $fail = 0
    $itemResults = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($name in $names) {
        $result = Invoke-ShutdownExe -Arguments (Get-RestartArguments -Mode Abort -Name $name)
        if ($result.Success) {
            Write-OperationLog -Context $Context -Action 'RESTART-ABORT' -Target $name -Result 'OK'
            [void]$itemResults.Add([PSCustomObject]@{ Name = $name; Success = $true; Message = 'Pending restart aborted' })
            $ok++
        } else {
            Write-OperationLog -Context $Context -Action 'RESTART-ABORT' -Target $name -Result 'FAIL' -Detail $result.Message
            [void]$itemResults.Add([PSCustomObject]@{ Name = $name; Success = $false; Message = $result.Message })
            $fail++
        }
    }

    return [PSCustomObject]@{ OkCount = $ok; FailCount = $fail; Results = $itemResults }
}
#endregion

Export-ModuleMember -Function `
    Get-RestartArguments, `
    Get-RemoteRestartCommandText, `
    Invoke-RemoteRestart, `
    Invoke-TimedRestart, `
    Invoke-AbortRemoteRestart
