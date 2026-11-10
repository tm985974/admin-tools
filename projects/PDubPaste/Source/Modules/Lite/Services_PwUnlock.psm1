# Services_PwUnlock.psm1   (LITE TIER)
#
# "Prove you are the Windows user running this app" before the window shows
# its contents (and, at start-up, before any hotkey is registered).
#
#   1. Windows Hello (PIN / fingerprint / face) when it is set up and available
#      - not over Remote Desktop, where Windows reports it unavailable.
#   2. Otherwise, or if Hello is cancelled: the Windows account password,
#      checked with LogonUser and required to be THIS account (same SID).
#
# Invoke-PwUnlock returns $true when verified. It never stores or logs the
# password; the check is done by Windows.

# AsTask(IAsyncOperation<T>) from System.Runtime.WindowsRuntime, found once.
function Get-PwAsTaskMethod {
    if (-not $script:PwAsTask) {
        Add-Type -AssemblyName System.Runtime.WindowsRuntime
        $script:PwAsTask = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
            $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
            $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
        } | Select-Object -First 1
    }
    return $script:PwAsTask
}

# Wait for a WinRT async operation while keeping the window responsive.
function Wait-PwWinRT {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Operation, [Parameter(Mandatory)] [Type]$ResultType, [int]$TimeoutSec = 180)
    $task = (Get-PwAsTaskMethod).MakeGenericMethod($ResultType).Invoke($null, @($Operation))
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while (-not $task.IsCompleted) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 40
        if ($sw.Elapsed.TotalSeconds -gt $TimeoutSec) { throw "Windows Hello did not answer within $TimeoutSec s." }
    }
    if ($task.IsFaulted) { throw $task.Exception.GetBaseException() }
    return $task.Result
}

# Returns 'Verified' | 'Canceled' | 'Unavailable' | 'Failed'
function Invoke-PwHello {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $App, [IntPtr]$Hwnd = [IntPtr]::Zero, [string]$Message = 'Unlock PDubPaste')

    try {
        $verT = [Windows.Security.Credentials.UI.UserConsentVerifier, Windows.Security.Credentials.UI, ContentType = WindowsRuntime]
        $resT = [Windows.Security.Credentials.UI.UserConsentVerificationResult, Windows.Security.Credentials.UI, ContentType = WindowsRuntime]
        $avT  = [Windows.Security.Credentials.UI.UserConsentVerifierAvailability, Windows.Security.Credentials.UI, ContentType = WindowsRuntime]
        $avail = Wait-PwWinRT -Operation ($verT::CheckAvailabilityAsync()) -ResultType $avT -TimeoutSec 15
        if ("$avail" -ne 'Available') {
            $App.Diag('PwUnlock', "Windows Hello not available: $avail")
            return 'Unavailable'
        }
    }
    catch {
        $App.Diag('PwUnlock', "Windows Hello not usable here: $($_.Exception.Message)")
        return 'Unavailable'
    }

    $result = $null
    try {
        # Parent the prompt to our window so it opens in front of it.
        $opT  = (Get-PwAsTaskMethod).GetParameters()[0].ParameterType.GetGenericTypeDefinition().MakeGenericType($resT)
        $op   = [PwPaste.Hello]::RequestForWindow($verT, $Hwnd, $Message, $opT.GUID)
        $result = Wait-PwWinRT -Operation $op -ResultType $resT
    }
    catch {
        $App.Diag('PwUnlock', "Hello window interop failed ($($_.Exception.Message)); using the plain request.")
        try { $result = Wait-PwWinRT -Operation ($verT::RequestVerificationAsync($Message)) -ResultType $resT }
        catch {
            $App.Log('WARN', 'PwUnlock', "Windows Hello request failed: $($_.Exception.Message)")
            return 'Failed'
        }
    }
    switch ("$result") {
        'Verified' { return 'Verified' }
        'Canceled' { return 'Canceled' }
        default    { $App.Log('INFO', 'PwUnlock', "Windows Hello result: $result"); return 'Failed' }
    }
}

function Invoke-PwUnlock {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $App, [Parameter(Mandatory)] [System.Windows.Forms.Form]$Owner)
    $st = Get-PwState
    if ($st.Unlocking) { return $false }
    $st.Unlocking = $true
    try {
        $how = $null
        $tryHello = $true
        $helloAvailable = $false
        for ($round = 0; $round -lt 6 -and -not $how; $round++) {
            if ($tryHello) {
                $h = Invoke-PwHello -App $App -Hwnd $Owner.Handle -Message 'Unlock PDubPaste'
                if ($h -eq 'Verified') { $how = 'Windows Hello'; break }
                $helloAvailable = ($h -ne 'Unavailable')
                $tryHello = $false
            }
            $d = Show-PwPasswordDialog -App $App -Owner $Owner -HelloAvailable $helloAvailable
            if     ($d -eq 'Verified') { $how = 'Windows password' }
            elseif ($d -eq 'Hello')    { $tryHello = $true }
            else                       { break }
        }
        if (-not $how) {
            $App.Log('INFO', 'PwUnlock', 'Unlock cancelled.')
            return $false
        }

        $st.WindowLocked = $false
        $App.Log('INFO', 'PwUnlock', "Unlocked with $how.")
        if (-not $st.Unlocked) {
            $st.Unlocked = $true
            $App.LogAction("Unlocked with $how; hotkeys started.")
            Update-PwHotkeys -App $App
            Resolve-PwOtherCopies -App $App -Owner $Owner
        }
        else { Invoke-PwStateChanged -App $App }
        return $true
    }
    finally { $st.Unlocking = $false }
}
