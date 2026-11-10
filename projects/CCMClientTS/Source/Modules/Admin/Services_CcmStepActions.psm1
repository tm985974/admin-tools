# Services_CcmStepActions.psm1   (ADMIN TIER)
#
# The code behind every step in the catalog (Lite\Services_CcmSteps.psm1).
#
#   Invoke-CcmStep -App $App -Id <step id> -Ctx <hashtable> -Out { param($line) } -Done { param($status, $summary) }
#
#   Ctx keys: RepairSource (string), ResetKey (bool), ForceInstall (bool), Deep (bool)
#   Status  : Done | Done - reboot | Warning | Failed | Skipped
#
# Quick steps finish before Invoke-CcmStep returns; long ones start a job
# (Services_CcmJobs) and call -Done when the tool exits. The caller confirms
# risky steps (the catalog's Confirm text) BEFORE calling this.
#
# What this module deliberately does NOT do (to stay clear of EDR / AV rules):
# encoded or hidden PowerShell, Add-Type, downloads, certutil, msdt, regsvr32,
# nltest, disabling any service or security feature, touching LSASS, BitLocker
# or the TPM beyond the client's own key, remote execution on other computers.

function Get-CcmHex {
    param($Code)
    if ($null -eq $Code) { return '(none)' }
    try { return ('0x{0:X8}' -f [BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$Code), 0)) } catch { return [string]$Code }
}

function Wait-CcmServiceStatus {
    param([string]$Name, [string]$Status, [int]$Seconds = 60)
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        $s = Get-Service -Name $Name -ErrorAction SilentlyContinue
        if (-not $s -or [string]$s.Status -eq $Status) { return $true }
        [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 250
    }
    return $false
}

function Get-CcmSetupResult {
    $e = Get-CcmLogEntries -Path (Join-Path $env:windir 'ccmsetup\Logs\ccmsetup.log') -MaxBytes 262144
    $last = @($e | Where-Object { $_.Message -match 'CcmSetup is exiting with return code|CcmSetup failed with error code|Uninstall succeeded|Installation succeeded' } | Select-Object -Last 1)
    if ($last.Count) { return $last[0] }
    return $null
}

# The PowerShell a step amounts to, for the command window (Base\Services_Commands).
# It mirrors the switch in Invoke-CcmStep below: same programs, same arguments,
# same paths. Invoke-CcmStep then runs the step (long tools in their own console
# window, with waits and result checks the text leaves out).
# KEEP IN STEP: a change to a step's commands below must be made here too.
function Get-CcmStepCommandText {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $App, [Parameter(Mandatory)] [string]$Id, [hashtable]$Ctx = @{})
    $cfg = Get-CcmTSConfig -App $App
    $q = { param($v) "'" + ([string]$v).Replace("'", "''") + "'" }
    $run = { param([string]$exe, [string]$argLine) 'Start-Process -FilePath ' + (& $q $exe) + $(if ($argLine) { ' -ArgumentList ' + (& $q $argLine) } else { '' }) + ' -Wait   # own console window' }
    $sys = { param([string]$n) Get-CcmSystemExe $n }
    $trigger = { param([string]$guid) "Invoke-CimMethod -Namespace root\ccm -ClassName SMS_Client -MethodName TriggerSchedule -Arguments @{ sScheduleID = '$guid' }" }
    $lines = New-Object System.Collections.Generic.List[string]
    switch ($Id) {
        'Elevate' { $lines.Add('Start-Process -FilePath ' + (& $q ([string]$App.ExePath)) + ' -Verb RunAs') }
        'TimeSync' {
            $lines.Add("if ((Get-Service W32Time).StartType -eq 'Disabled') { Set-Service W32Time -StartupType Manual }")
            $lines.Add('Start-Service W32Time')
            $lines.Add('& ' + (& $q (& $sys 'w32tm.exe')) + ' /resync /force')
        }
        'Services' {
            $names = @(Get-CcmServiceSpec | ForEach-Object { $_.Name }) + 'CcmExec'
            $lines.Add('# For each required service: a Disabled one goes back to its default start type, one that must run is started.')
            $lines.Add('foreach ($s in Get-Service -Name ' + (($names | ForEach-Object { & $q $_ }) -join ', ') + ' -ErrorAction SilentlyContinue) {')
            $lines.Add("    if ([string]`$s.StartType -eq 'Disabled') { Set-Service -Name `$s.Name -StartupType Manual }   # Automatic for those that default to it")
            $lines.Add("    if (`$s.Status -ne 'Running') { Start-Service -Name `$s.Name }")
            $lines.Add('}')
        }
        'ChkdskScan' { $lines.Add((& $run (& $sys 'chkdsk.exe') "$env:SystemDrive /scan")) }
        'WmiVerify'  { $lines.Add('& ' + (& $q (& $sys 'wbem\winmgmt.exe')) + ' /verifyrepository') }
        'WmiSalvage' {
            $lines.Add((& $run (& $sys 'wbem\winmgmt.exe') '/salvagerepository'))
            $lines.Add('& ' + (& $q (& $sys 'wbem\winmgmt.exe')) + ' /verifyrepository')
        }
        'DismScan' {
            $lines.Add((& $run (& $sys 'dism.exe') '/Online /Cleanup-Image /ScanHealth'))
            $lines.Add('& ' + (& $q (& $sys 'dism.exe')) + ' /Online /Cleanup-Image /CheckHealth')
        }
        'DismRestoreSource' {
            $src = [string]$Ctx.RepairSource; if (-not $src) { $src = $cfg.RepairSource }
            $path = $src
            try { $t = Test-CcmRepairSource -Source $src; if ($t.Path) { $path = $t.Path } } catch { }
            $lines.Add((& $run (& $sys 'dism.exe') "/Online /Cleanup-Image /RestoreHealth /Source:$path /LimitAccess"))
        }
        'DismRestoreWU' { $lines.Add((& $run (& $sys 'dism.exe') '/Online /Cleanup-Image /RestoreHealth')) }
        'Sfc'           { $lines.Add((& $run (& $sys 'sfc.exe') '/scannow')) }
        'DismCleanup'   { $lines.Add((& $run (& $sys 'dism.exe') '/Online /Cleanup-Image /StartComponentCleanup')) }
        'WuReset' {
            $stamp = (Get-Date).ToString('yyyyMMdd_HHmmss')
            $lines.Add("Stop-Service wuauserv, bits, cryptsvc, msiserver -Force")
            $lines.Add("Rename-Item -LiteralPath '$env:windir\SoftwareDistribution' -NewName 'SoftwareDistribution.bak_$stamp'")
            $lines.Add("Rename-Item -LiteralPath '$env:windir\System32\catroot2' -NewName 'catroot2.bak_$stamp'")
            $lines.Add('Start-Service cryptsvc, bits, wuauserv')
        }
        'WuTroubleshooter' {
            $res = Join-Path (Join-Path ([string]$App.DataRoot) 'Reports') ("WUTroubleshooter_{0}_<time>" -f $env:COMPUTERNAME)
            $lines.Add("`$p = Get-TroubleshootingPack -Path '$env:windir\diagnostics\system\WindowsUpdate'")
            $lines.Add("Invoke-TroubleshootingPack -Pack `$p -Unattended -Result '$res'   # in its own PowerShell window")
        }
        'RestartCcmExec' {
            $lines.Add("if ((Get-Service CcmExec).StartType -eq 'Disabled') { Set-Service CcmExec -StartupType Automatic }")
            $lines.Add('Stop-Service CcmExec -Force')
            $lines.Add('Start-Service CcmExec')
        }
        'TriggerActions' {
            foreach ($g in '021', '022', '003', '001', '121', '113') { $lines.Add((& $trigger "{00000000-0000-0000-0000-000000000$g}")) }
            $lines.Add('# 021/022 machine policy retrieval + evaluation, 003 discovery data, 001 hardware inventory, 121 application evaluation, 113 software updates scan')
        }
        'ResetPolicy' {
            $lines.Add('Invoke-CimMethod -Namespace root\ccm -ClassName SMS_Client -MethodName ResetPolicy -Arguments @{ uFlags = [uint32]1 }')
            $lines.Add((& $trigger '{00000000-0000-0000-0000-000000000021}'))
            $lines.Add((& $trigger '{00000000-0000-0000-0000-000000000022}'))
        }
        'ClientRepair' { $lines.Add((& $run (Join-Path $env:windir 'CCM\ccmrepair.exe') '')); $lines.Add('# then waits for ccmrepair / ccmsetup to finish') }
        'ResetIdentity' {
            $lines.Add('Stop-Service CcmExec -Force   # the process is ended if it has not stopped after 90 s')
            $lines.Add("Remove-Item -LiteralPath '$env:windir\SMSCFG.ini' -Force")
            $lines.Add('Get-ChildItem Cert:\LocalMachine\SMS | Remove-Item -Force')
            $lines.Add('Start-Service CcmExec')
        }
        'Uninstall' {
            $exe = @((Join-Path $env:windir 'ccmsetup\ccmsetup.exe'), (Join-Path $cfg.ClientSource 'ccmsetup.exe')) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
            if (-not $exe) { $exe = Join-Path $env:windir 'ccmsetup\ccmsetup.exe' }
            $lines.Add((& $run $exe '/uninstall'))
        }
        'Cleanup' {
            $lines.Add("foreach (`$s in 'CcmExec', 'ccmsetup', 'smstsmgr', 'CmRcService') { Stop-Service `$s -Force; & '$(& $sys 'sc.exe')' delete `$s }")
            $lines.Add("Get-Process CcmExec, CcmRestart, SCNotification, SCClient, CmRcService -ErrorAction SilentlyContinue | Stop-Process -Force")
            $lines.Add("Remove-Item '$env:windir\CCM', '$env:windir\ccmsetup', '$env:windir\ccmcache', '$env:windir\SMSCFG.ini', '$env:windir\SMS*.mif' -Recurse -Force")
            $lines.Add("Remove-Item 'HKLM:\SOFTWARE\Microsoft\CCM', 'HKLM:\SOFTWARE\Microsoft\CCMSetup', 'HKLM:\SOFTWARE\Microsoft\SMS', 'HKLM:\SOFTWARE\Microsoft\DeviceManageabilityCSP' -Recurse -Force")
            $lines.Add("Remove-Item 'HKLM:\SOFTWARE\Wow6432Node\Microsoft\CCM', 'HKLM:\SOFTWARE\Wow6432Node\Microsoft\CCMSetup', 'HKLM:\SOFTWARE\Wow6432Node\Microsoft\SMS', 'HKLM:\SOFTWARE\Microsoft\SystemCertificates\SMS' -Recurse -Force")
            $lines.Add("Get-CimInstance -Namespace root -ClassName __Namespace -Filter `"Name='ccm'`" | Remove-CimInstance")
            $lines.Add("Get-CimInstance -Namespace root -ClassName __Namespace -Filter `"Name='SmsDm'`" | Remove-CimInstance")
            $lines.Add("Get-CimInstance -Namespace root\cimv2 -ClassName __Namespace -Filter `"Name='sms'`" | Remove-CimInstance")
            $lines.Add('Get-ChildItem Cert:\LocalMachine\SMS | Remove-Item -Force')
            $lines.Add("Get-ScheduledTask -TaskPath '\Microsoft\Configuration Manager\*' | Unregister-ScheduledTask -Confirm:`$false")
            $lines.Add("Get-ChildItem `"`$env:ProgramData\Microsoft\Windows\Start Menu\Programs`" -Recurse -Filter '*Software Center*.lnk' | Remove-Item -Force")
        }
        'RemoveTpmKey' {
            $lines.Add("`$pcp = New-Object System.Security.Cryptography.CngProvider('Microsoft Platform Crypto Provider')")
            $lines.Add("[System.Security.Cryptography.CngKey]::Open('ConfigMgrPrimaryKey', `$pcp, [System.Security.Cryptography.CngKeyOpenOptions]::MachineKey).Delete()")
        }
        'ServerSide' { $lines.Add('# Nothing runs here: the device details are copied to the clipboard for the console work on the site server.') }
        { $_ -eq 'InstallLocal' -or $_ -eq 'InstallShare' } {
            $isLocal = ($Id -eq 'InstallLocal')
            $base = $(if ($isLocal) { $cfg.ClientSource } else { $cfg.SiteShare })
            $args2 = @()
            if ($isLocal) { $args2 += "/source:$base" }
            $args2 += "/mp:$($cfg.ManagementPoint)"
            if ($Ctx.ForceInstall) { $args2 += '/forceinstall' }
            $args2 += "SMSSITECODE=$($cfg.SiteCode)"
            $args2 += "SMSMP=$($cfg.ManagementPoint)"
            if ($Ctx.ResetKey) { $args2 += 'RESETKEYINFORMATION=TRUE' }
            $lines.Add((& $run (Join-Path $base 'ccmsetup.exe') ($args2 -join ' ')))
            $lines.Add('# then waits for ccmsetup to finish and reads the result from ccmsetup.log')
        }
        'Verify' { $lines.Add('# Runs discovery again (read-only checks of the client, its services, WMI and registration).') }
        default { $lines.Add("# Unknown step '$Id'.") }
    }
    return ($lines -join "`r`n")
}

function Invoke-CcmStep {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $App,
        [Parameter(Mandatory)] [string]$Id,
        [hashtable]$Ctx = @{},
        [Parameter(Mandatory)] [scriptblock]$Out,
        [Parameter(Mandatory)] [scriptblock]$Done
    )
    $cfg = Get-CcmTSConfig -App $App
    $say = { param($t) try { & $Out $t } catch { } }.GetNewClosure()
    try { $App.LogAction("Step started: $Id") } catch { }

    if ($Id -ne 'Elevate' -and $Id -ne 'ServerSide' -and $Id -ne 'Verify' -and -not (Test-CcmElevated)) {
        & $Done 'Skipped' 'Not elevated - run the tool as administrator first (step 1).'
        return
    }

    switch ($Id) {

        # ======================================================== 1. Prepare
        'Elevate' {
            if (Test-CcmElevated) { & $Done 'Done' 'Already running as administrator.'; return }
            try {
                Start-Process -FilePath ([string]$App.ExePath) -Verb RunAs -ErrorAction Stop | Out-Null
                & $Done 'Done' 'Elevated copy started. Close this window and continue in the elevated one.'
                $a = [System.Windows.Forms.MessageBox]::Show('The elevated copy has started. Close this (non-elevated) window now?', 'CCM Client Troubleshooter', 'YesNo', 'Question')   # not-a-command: closes this window
                if ($a -eq 'Yes') { foreach ($fm in @([System.Windows.Forms.Application]::OpenForms)) { try { $fm.Close() } catch { } } }
            } catch { & $Done 'Failed' "Elevation was cancelled or failed: $($_.Exception.Message)" }
            return
        }

        'TimeSync' {
            $s = Get-Service W32Time -ErrorAction SilentlyContinue
            if (-not $s) { & $Done 'Failed' 'The Windows Time service does not exist.'; return }
            if ([string]$s.StartType -eq 'Disabled') { Set-Service W32Time -StartupType Manual; & $say 'W32Time was Disabled - set to Manual.' }
            if ($s.Status -ne 'Running') { Start-Service W32Time -ErrorAction SilentlyContinue; [void](Wait-CcmServiceStatus W32Time Running 20); & $say 'Started W32Time.' }
            & $say 'w32tm /resync /force'
            $r = Invoke-CcmNative -FilePath (Get-CcmSystemExe 'w32tm.exe') -Arguments '/resync /force' -TimeoutSec 60
            & $say $r.Output
            if ($r.ExitCode -eq 0) { & $Done 'Done' 'Clock resynchronised.' } else { & $Done 'Failed' "w32tm exit $($r.ExitCode): $($r.Output)" }
            return
        }

        'Services' {
            $specs = @(Get-CcmServiceSpec)
            if (Get-Service CcmExec -ErrorAction SilentlyContinue) { $specs += [pscustomobject]@{ Name = 'CcmExec'; Display = 'SMS Agent Host'; Default = 'Automatic'; MustRun = $true; Critical = $true; Protected = $false } }
            $changed = 0; $failed = 0
            foreach ($sp in $specs) {
                $s = Get-Service -Name $sp.Name -ErrorAction SilentlyContinue
                if (-not $s) { continue }
                if ([string]$s.StartType -eq 'Disabled') {
                    if ($sp.Protected) { & $say "$($sp.Name) is Disabled and protected - Windows refuses the change here; fix the GPO / baseline that disables it."; $failed++ }
                    else {
                        try { Set-Service -Name $sp.Name -StartupType $sp.Default -ErrorAction Stop; & $say "$($sp.Name): Disabled -> $($sp.Default)"; $changed++ }
                        catch { & $say "$($sp.Name): could not change start type: $($_.Exception.Message)"; $failed++ }
                    }
                }
                $s = Get-Service -Name $sp.Name -ErrorAction SilentlyContinue
                $wantRun = $sp.MustRun -or $sp.Name -eq 'KeyIso'
                if ($wantRun -and $s.Status -ne 'Running' -and [string]$s.StartType -ne 'Disabled') {
                    try {
                        Start-Service -Name $sp.Name -ErrorAction Stop
                        if (Wait-CcmServiceStatus $sp.Name Running 30) { & $say "$($sp.Name): started."; $changed++ } else { & $say "$($sp.Name): did not reach Running in 30 s."; $failed++ }
                    } catch { & $say "$($sp.Name): start failed: $($_.Exception.Message)"; $failed++ }
                }
            }
            $ksp = $true
            try { [void][System.Security.Cryptography.CngKey]::Exists('CcmTS_probe', [System.Security.Cryptography.CngProvider]::MicrosoftSoftwareKeyStorageProvider, [System.Security.Cryptography.CngKeyOpenOptions]::MachineKey) } catch { $ksp = $false }
            & $say ("Software key storage provider: " + $(if ($ksp) { 'opens (OK)' } else { 'STILL FAILS' }))
            if ($failed -gt 0 -or -not $ksp) { & $Done 'Warning' "$changed change(s), $failed problem(s). If a service reverts to Disabled after gpupdate, a GPO enforces it." }
            elseif ($changed -eq 0) { & $Done 'Done' 'All required services were already fine.' }
            else { & $Done 'Done' "$changed service change(s). Next: Restart the SMS Agent Host so the client retries." }
            return
        }

        # ======================================================== 2. Windows health
        'ChkdskScan' {
            $drive = $env:SystemDrive
            & $say "chkdsk $drive /scan  (console window)"
            Start-CcmJob -App $App -Name 'chkdsk' -FilePath (Get-CcmSystemExe 'chkdsk.exe') -Arguments "$drive /scan" -OnExit {
                param($code)
                switch ($code) {
                    0 { & $Done 'Done' 'No file system problems found.' }
                    1 { & $Done 'Done' 'Errors were found and fixed.' }
                    2 { & $Done 'Done' 'Disk cleanup performed (no errors).' }
                    3 { & $Done 'Failed' 'Errors need an offline repair: run  chkdsk C: /f  and reboot (it runs at boot). Check the disk health too.' }
                    default { & $Done 'Warning' "chkdsk exit code $code." }
                }
            }.GetNewClosure() | Out-Null
            return
        }

        'WmiVerify' {
            $r = Invoke-CcmNative -FilePath (Get-CcmSystemExe 'wbem\winmgmt.exe') -Arguments '/verifyrepository' -TimeoutSec 180
            & $say $r.Output
            if ($r.Output -match 'not consistent|inconsistent') { & $Done 'Failed' 'WMI repository is INCONSISTENT - run Salvage the WMI repository.' }
            elseif ($r.Output -match 'consistent') { & $Done 'Done' 'WMI repository is consistent.' }
            else { & $Done 'Warning' "Unexpected result (exit $($r.ExitCode))." }
            return
        }

        'WmiSalvage' {
            Start-CcmJob -App $App -Name 'winmgmt salvage' -FilePath (Get-CcmSystemExe 'wbem\winmgmt.exe') -Arguments '/salvagerepository' -OnExit {
                param($code)
                $v = Invoke-CcmNative -FilePath (Get-CcmSystemExe 'wbem\winmgmt.exe') -Arguments '/verifyrepository' -TimeoutSec 180
                & $say "verify after salvage: $($v.Output)"
                if ($code -eq 0 -and $v.Output -match 'is consistent') { & $Done 'Done - reboot' 'Repository salvaged and consistent. Reboot recommended.' }
                else { & $Done 'Failed' "Salvage exit $code; verify says: $($v.Output)" }
            }.GetNewClosure() | Out-Null
            return
        }

        'DismScan' {
            & $say 'DISM /Online /Cleanup-Image /ScanHealth  (console window, 5-30 min)'
            Start-CcmJob -App $App -Name 'DISM ScanHealth' -FilePath (Get-CcmSystemExe 'dism.exe') -Arguments '/Online /Cleanup-Image /ScanHealth' -OnExit {
                param($code)
                $c = Invoke-CcmNative -FilePath (Get-CcmSystemExe 'dism.exe') -Arguments '/Online /Cleanup-Image /CheckHealth' -TimeoutSec 180
                if ($c.Output -match 'No component store corruption detected') { & $Done 'Done' 'No component store corruption detected.' }
                elseif ($c.Output -match 'is repairable') { & $Done 'Warning' 'Component store is REPAIRABLE - run Repair the component store from a healthy PC, then SFC.' }
                elseif ($c.Output -match 'not repairable') { & $Done 'Failed' 'Component store is NOT repairable - an in-place upgrade (keep files and apps) is needed.' }
                else { & $Done 'Warning' ("ScanHealth exit {0}; CheckHealth: {1}" -f (Get-CcmHex $code), $c.Output) }
            }.GetNewClosure() | Out-Null
            return
        }

        'DismRestoreSource' {
            $src = [string]$Ctx.RepairSource
            if (-not $src) { $src = $cfg.RepairSource }
            $t = Test-CcmRepairSource -Source $src
            & $say "Repair source: $src"
            & $say $t.Detail
            if (-not $t.Ok) { & $Done 'Failed' "Repair source not usable: $($t.Detail)"; return }
            if ($t.Kind -eq 'Folder' -and -not $t.Match) {
                $a = [System.Windows.Forms.MessageBox]::Show("The source build ($($t.SourceBuild)) does not match this PC ($($t.LocalBuild)).`r`n`r`nDISM will most likely fail with 0x800f081f. Run anyway?", 'Repair source', 'YesNo', 'Warning', 'Button2')   # not-a-command: safety gate after the command window
                if ($a -ne 'Yes') { & $Done 'Skipped' 'Cancelled: source build does not match.'; return }
            }
            $arg = "/Online /Cleanup-Image /RestoreHealth /Source:$($t.Path) /LimitAccess"
            & $say "DISM $arg  (console window)"
            Start-CcmJob -App $App -Name 'DISM RestoreHealth (source)' -FilePath (Get-CcmSystemExe 'dism.exe') -Arguments $arg -OnExit {
                param($code)
                $hx = Get-CcmHex $code
                if ($code -eq 0) { & $Done 'Done - reboot' 'Component store repaired. Run SFC next, then reboot.' }
                elseif ($hx -eq '0x800F081F' -or $hx -eq '0x800F0906' -or $hx -eq '0x800F0950') { & $Done 'Failed' "$hx - source files not found in the source. The source must be the SAME build (and edition/language)." }
                else { & $Done 'Failed' "DISM exit $hx - see Logs: Windows: DISM." }
            }.GetNewClosure() | Out-Null
            return
        }

        'DismRestoreWU' {
            & $say 'DISM /Online /Cleanup-Image /RestoreHealth  (console window)'
            Start-CcmJob -App $App -Name 'DISM RestoreHealth (WU)' -FilePath (Get-CcmSystemExe 'dism.exe') -Arguments '/Online /Cleanup-Image /RestoreHealth' -OnExit {
                param($code)
                $hx = Get-CcmHex $code
                if ($code -eq 0) { & $Done 'Done - reboot' 'Component store repaired. Run SFC next, then reboot.' }
                elseif ($hx -eq '0x800F081F' -or $hx -eq '0x800F0906') { & $Done 'Failed' "$hx - no repair content reachable (air-gapped / WSUS). Use the healthy-PC repair step instead." }
                else { & $Done 'Failed' "DISM exit $hx - see Logs: Windows: DISM." }
            }.GetNewClosure() | Out-Null
            return
        }

        'Sfc' {
            & $say 'sfc /scannow  (console window, 10-20 min)'
            Start-CcmJob -App $App -Name 'sfc /scannow' -FilePath (Get-CcmSystemExe 'sfc.exe') -Arguments '/scannow' -OnExit {
                param($code)
                $s = Get-CcmSfcSummary
                & $say $s.Text
                if ($s.CannotRepair -gt 0) { & $Done 'Failed' "$($s.Files.Count) file(s) could not be repaired (store also corrupt). Repair the component store from a healthy PC, then run SFC again." }
                elseif ($s.Repaired -gt 0) { & $Done 'Done - reboot' "$($s.Repaired) repair(s) made. Reboot." }
                else { & $Done 'Done' 'No integrity violations.' }
            }.GetNewClosure() | Out-Null
            return
        }

        'DismCleanup' {
            Start-CcmJob -App $App -Name 'DISM StartComponentCleanup' -FilePath (Get-CcmSystemExe 'dism.exe') -Arguments '/Online /Cleanup-Image /StartComponentCleanup' -OnExit {
                param($code)
                if ($code -eq 0) { & $Done 'Done' 'Component cleanup finished.' } else { & $Done 'Warning' "DISM exit $(Get-CcmHex $code)." }
            }.GetNewClosure() | Out-Null
            return
        }

        'WuReset' {
            $stamp = (Get-Date).ToString('yyyyMMdd_HHmmss')
            $svcs = @('wuauserv', 'bits', 'cryptsvc', 'msiserver')
            foreach ($n in $svcs) {
                $s = Get-Service $n -ErrorAction SilentlyContinue
                if ($s -and $s.Status -ne 'Stopped') {
                    try { Stop-Service $n -Force -ErrorAction Stop } catch { & $say "$n stop: $($_.Exception.Message)" }
                    if (Wait-CcmServiceStatus $n Stopped 45) { & $say "$n stopped." } else { & $say "$n did not stop in 45 s." }
                }
            }
            $ok = $true
            foreach ($d in @((Join-Path $env:windir 'SoftwareDistribution'), (Join-Path $env:windir 'System32\catroot2'))) {
                if (Test-Path -LiteralPath $d) {
                    $new = "$(Split-Path $d -Leaf).bak_$stamp"
                    try { Rename-Item -LiteralPath $d -NewName $new -ErrorAction Stop; & $say "Renamed $d -> $new" }
                    catch { $ok = $false; & $say "Could not rename $d : $($_.Exception.Message)" }
                }
            }
            foreach ($n in @('cryptsvc', 'bits', 'wuauserv')) {
                try { Start-Service $n -ErrorAction Stop; & $say "$n started." } catch { & $say "$n start: $($_.Exception.Message)" }
            }
            if ($ok) { & $Done 'Done' "Windows Update components reset (old folders kept as *.bak_$stamp)." } else { & $Done 'Warning' 'Partly reset - a folder was in use. Reboot and run again.' }
            return
        }

        'WuTroubleshooter' {
            $pack = Join-Path $env:windir 'diagnostics\system\WindowsUpdate'
            if (-not (Test-Path -LiteralPath $pack)) { & $Done 'Failed' "Troubleshooting pack not found: $pack"; return }
            $repDir = Join-Path ([string]$App.DataRoot) 'Reports'
            if (-not (Test-Path -LiteralPath $repDir)) { New-Item -ItemType Directory -Path $repDir -Force | Out-Null }
            $res = Join-Path $repDir ("WUTroubleshooter_{0}_{1}" -f $env:COMPUTERNAME, (Get-Date).ToString('yyyyMMdd_HHmmss'))
            $cmd = "& { `$p = Get-TroubleshootingPack -Path '$pack'; Invoke-TroubleshootingPack -Pack `$p -Unattended -Result '$res'; Write-Host ''; Write-Host 'Finished. Report folder: $res'; Start-Sleep -Seconds 5 }"
            $global:CcmTS.LastReportFolder = $res
            & $say "Windows Update troubleshooter (unattended) - report: $res"
            Start-CcmJob -App $App -Name 'WU troubleshooter' -FilePath (Get-CcmSystemExe 'WindowsPowerShell\v1.0\powershell.exe') -Arguments "-NoProfile -Command `"$cmd`"" -OnExit {
                param($code)
                $xml = Join-Path $res 'ResultReport.xml'
                if (Test-Path -LiteralPath $xml) {
                    $txt = [System.IO.File]::ReadAllText($xml)
                    $rc = ([regex]::Matches($txt, '<RootCause\b')).Count
                    & $Done 'Done' "Troubleshooter finished: $rc root cause(s) checked. Report: $res"
                } else { & $Done 'Warning' "Troubleshooter exited ($code) without a report in $res." }
            }.GetNewClosure() | Out-Null
            return
        }

        # ======================================================== 3. Client repair
        'RestartCcmExec' {
            $s = Get-Service CcmExec -ErrorAction SilentlyContinue
            if (-not $s) { & $Done 'Skipped' 'CcmExec is not installed.'; return }
            if ([string]$s.StartType -eq 'Disabled') { Set-Service CcmExec -StartupType Automatic; & $say 'CcmExec was Disabled - set to Automatic.' }
            if ($s.Status -ne 'Stopped') {
                & $say 'Stopping SMS Agent Host ...'
                try { Stop-Service CcmExec -Force -ErrorAction Stop } catch { & $say $_.Exception.Message }
                if (-not (Wait-CcmServiceStatus CcmExec Stopped 90)) { & $Done 'Failed' 'CcmExec did not stop within 90 s - reboot instead.'; return }
            }
            try { Start-Service CcmExec -ErrorAction Stop } catch { & $Done 'Failed' "Start failed: $($_.Exception.Message)"; return }
            if (Wait-CcmServiceStatus CcmExec Running 60) { & $Done 'Done' 'SMS Agent Host restarted. Registration retries within ~5 minutes - then Verify.' }
            else { & $Done 'Failed' 'CcmExec did not reach Running.' }
            return
        }

        'TriggerActions' {
            $ri = Get-CcmRegistrationInfo
            if ($ri.State -ne 'Registered') { & $say "Note: the client is not registered ($($ri.State)) - only policy retrieval will do anything." }
            $acts = [ordered]@{
                'Machine policy retrieval'  = '{00000000-0000-0000-0000-000000000021}'
                'Machine policy evaluation' = '{00000000-0000-0000-0000-000000000022}'
                'Discovery data (DDR)'      = '{00000000-0000-0000-0000-000000000003}'
                'Hardware inventory'        = '{00000000-0000-0000-0000-000000000001}'
                'Application evaluation'    = '{00000000-0000-0000-0000-000000000121}'
                'Software updates scan'     = '{00000000-0000-0000-0000-000000000113}'
            }
            $okc = 0; $bad = 0
            foreach ($k in $acts.Keys) {
                try { Invoke-CimMethod -Namespace root\ccm -ClassName SMS_Client -MethodName TriggerSchedule -Arguments @{ sScheduleID = $acts[$k] } -ErrorAction Stop | Out-Null; & $say "OK    $k"; $okc++ }
                catch { & $say "FAIL  $k : $($_.Exception.Message)"; $bad++ }
            }
            if ($bad -eq 0) { & $Done 'Done' "$okc action(s) triggered." } elseif ($okc -gt 0) { & $Done 'Warning' "$okc triggered, $bad failed (not available until policy arrives)." } else { & $Done 'Failed' 'No action could be triggered.' }
            return
        }

        'ResetPolicy' {
            try {
                Invoke-CimMethod -Namespace root\ccm -ClassName SMS_Client -MethodName ResetPolicy -Arguments @{ uFlags = [uint32]1 } -ErrorAction Stop | Out-Null
                & $say 'Policy reset.'
                Start-Sleep -Seconds 2
                Invoke-CimMethod -Namespace root\ccm -ClassName SMS_Client -MethodName TriggerSchedule -Arguments @{ sScheduleID = '{00000000-0000-0000-0000-000000000021}' } -ErrorAction SilentlyContinue | Out-Null
                Invoke-CimMethod -Namespace root\ccm -ClassName SMS_Client -MethodName TriggerSchedule -Arguments @{ sScheduleID = '{00000000-0000-0000-0000-000000000022}' } -ErrorAction SilentlyContinue | Out-Null
                & $Done 'Done' 'Policy reset and machine policy requested. Give it a few minutes (PolicyAgent.log).'
            } catch { & $Done 'Failed' "ResetPolicy failed: $($_.Exception.Message)" }
            return
        }

        'ClientRepair' {
            $exe = Join-Path $env:windir 'CCM\ccmrepair.exe'
            if (-not (Test-Path -LiteralPath $exe)) { & $Done 'Failed' "ccmrepair.exe not found ($exe) - reinstall instead."; return }
            Start-CcmJob -App $App -Name 'ccmrepair' -FilePath $exe -WaitForProcess @('ccmrepair', 'ccmsetup') -OnExit {
                param($code)
                $r = Get-CcmSetupResult
                $txt = $(if ($r) { "$($r.Time) $($r.Message)" } else { 'no result in ccmsetup.log' })
                if ($r -and $r.Message -match 'return code 0\b') { & $Done 'Done' "Repair finished: $txt" } else { & $Done 'Warning' "Repair finished (exit $code): $txt" }
            }.GetNewClosure() | Out-Null
            return
        }

        'ResetIdentity' {
            $s = Get-Service CcmExec -ErrorAction SilentlyContinue
            if (-not $s) { & $Done 'Skipped' 'CcmExec is not installed.'; return }
            & $say 'Stopping SMS Agent Host ...'
            try { Stop-Service CcmExec -Force -ErrorAction Stop } catch { & $say $_.Exception.Message }
            if (-not (Wait-CcmServiceStatus CcmExec Stopped 90)) {
                & $say 'Still running after 90 s - ending the CcmExec process.'
                Get-Process CcmExec -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 3
            }
            $ini = Join-Path $env:windir 'SMSCFG.ini'
            if (Test-Path -LiteralPath $ini) {
                try { Remove-Item -LiteralPath $ini -Force -ErrorAction Stop; & $say 'Deleted SMSCFG.ini' } catch { & $Done 'Failed' "Could not delete SMSCFG.ini: $($_.Exception.Message)"; return }
            }
            $n = 0
            foreach ($c in @(Get-ChildItem Cert:\LocalMachine\SMS -ErrorAction SilentlyContinue)) {
                try { Remove-Item -LiteralPath $c.PSPath -Force -ErrorAction Stop; $n++ } catch { & $say "cert $($c.Thumbprint): $($_.Exception.Message)" }
            }
            & $say "Deleted $n SMS certificate(s)."
            try { Start-Service CcmExec -ErrorAction Stop } catch { & $Done 'Failed' "CcmExec start failed: $($_.Exception.Message)"; return }
            [void](Wait-CcmServiceStatus CcmExec Running 60)
            & $Done 'Done' 'New identity requested. Delete the old device record in the console; watch for a NEW GUID in ClientIDManagerStartup.log (2-10 min).'
            return
        }

        # ======================================================== 4. Client reinstall
        'Uninstall' {
            $exe = @((Join-Path $env:windir 'ccmsetup\ccmsetup.exe'), (Join-Path $cfg.ClientSource 'ccmsetup.exe')) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
            if (-not $exe) { & $Done 'Failed' 'ccmsetup.exe not found (C:\Windows\ccmsetup or the client source).'; return }
            & $say "$exe /uninstall  (5-15 min)"
            Start-CcmJob -App $App -Name 'ccmsetup /uninstall' -FilePath $exe -Arguments '/uninstall' -WaitForProcess @('ccmsetup') -OnExit {
                param($code)
                $r = Get-CcmSetupResult
                $txt = $(if ($r) { "$($r.Time) $($r.Message)" } else { 'no result in ccmsetup.log' })
                if ($r -and $r.Message -match 'Uninstall succeeded') { & $Done 'Done - reboot' "Uninstall succeeded. REBOOT, then Remove client leftovers." }
                else { & $Done 'Warning' "Uninstall finished without 'Uninstall succeeded' ($txt). Reboot and run Remove client leftovers anyway." }
            }.GetNewClosure() | Out-Null
            return
        }

        'Cleanup' {
            if (Get-Process ccmsetup -ErrorAction SilentlyContinue) { & $Done 'Failed' 'ccmsetup.exe is still running - wait for it (or reboot) first.'; return }
            $warn = 0
            foreach ($svc in 'CcmExec', 'ccmsetup', 'smstsmgr', 'CmRcService') {
                if (Get-Service -Name $svc -ErrorAction SilentlyContinue) {
                    try { Stop-Service $svc -Force -ErrorAction SilentlyContinue } catch { }
                    [void](Wait-CcmServiceStatus $svc Stopped 30)
                    $r = Invoke-CcmNative -FilePath (Get-CcmSystemExe 'sc.exe') -Arguments "delete $svc" -TimeoutSec 30
                    & $say "service $svc removed: $($r.Output)"
                }
            }
            foreach ($p in 'CcmExec', 'CcmRestart', 'SCNotification', 'SCClient', 'CmRcService') { Get-Process -Name $p -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue }
            foreach ($p in @("$env:windir\CCM", "$env:windir\ccmsetup", "$env:windir\ccmcache", "$env:windir\SMSCFG.ini", "$env:windir\SMS*.mif")) {
                foreach ($it in @(Get-Item -Path $p -Force -ErrorAction SilentlyContinue)) {
                    try { Remove-Item -LiteralPath $it.FullName -Recurse -Force -ErrorAction Stop; & $say "deleted $($it.FullName)" }
                    catch { $warn++; & $say "could not delete $($it.FullName): $($_.Exception.Message) (reboot and run again)" }
                    [System.Windows.Forms.Application]::DoEvents()
                }
            }
            foreach ($k in @('HKLM:\SOFTWARE\Microsoft\CCM', 'HKLM:\SOFTWARE\Microsoft\CCMSetup', 'HKLM:\SOFTWARE\Microsoft\SMS', 'HKLM:\SOFTWARE\Microsoft\DeviceManageabilityCSP',
                             'HKLM:\SOFTWARE\Wow6432Node\Microsoft\CCM', 'HKLM:\SOFTWARE\Wow6432Node\Microsoft\CCMSetup', 'HKLM:\SOFTWARE\Wow6432Node\Microsoft\SMS',
                             'HKLM:\SOFTWARE\Microsoft\SystemCertificates\SMS')) {
                if (Test-Path $k) { try { Remove-Item $k -Recurse -Force -ErrorAction Stop; & $say "deleted $k" } catch { $warn++; & $say "could not delete ${k}: $($_.Exception.Message)" } }
            }
            foreach ($ns in @(@('root', 'ccm'), @('root', 'SmsDm'), @('root\cimv2', 'sms'))) {
                $inst = Get-CimInstance -Namespace $ns[0] -ClassName __Namespace -Filter "Name='$($ns[1])'" -ErrorAction SilentlyContinue
                if ($inst) { try { $inst | Remove-CimInstance -ErrorAction Stop; & $say "deleted WMI $($ns[0])\$($ns[1])" } catch { $warn++; & $say "WMI $($ns[0])\$($ns[1]): $($_.Exception.Message)" } }
            }
            foreach ($c in @(Get-ChildItem Cert:\LocalMachine\SMS -ErrorAction SilentlyContinue)) { try { Remove-Item -LiteralPath $c.PSPath -Force -ErrorAction Stop; & $say "deleted cert $($c.Thumbprint)" } catch { $warn++ } }
            $tasks = @(Get-ScheduledTask -TaskPath '\Microsoft\Configuration Manager\*' -ErrorAction SilentlyContinue)
            if ($tasks.Count) {
                $tasks | Unregister-ScheduledTask -Confirm:$false -ErrorAction SilentlyContinue
                & $say "removed $($tasks.Count) scheduled task(s)"
                try { $sch = New-Object -ComObject Schedule.Service; $sch.Connect(); $sch.GetFolder('\Microsoft').DeleteFolder('Configuration Manager', 0) } catch { }
            }
            Get-ChildItem "$env:ProgramData\Microsoft\Windows\Start Menu\Programs" -Recurse -Filter '*Software Center*.lnk' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue

            $left = @()
            if (Get-Service CcmExec -ErrorAction SilentlyContinue) { $left += 'CcmExec service' }
            if (Test-Path "$env:windir\CCM") { $left += 'C:\Windows\CCM' }
            if (Test-Path "$env:windir\SMSCFG.ini") { $left += 'SMSCFG.ini' }
            if (Test-Path 'HKLM:\SOFTWARE\Microsoft\CCM') { $left += 'HKLM\SOFTWARE\Microsoft\CCM' }
            if (Get-CimInstance -Namespace root -ClassName __Namespace -Filter "Name='ccm'" -ErrorAction SilentlyContinue) { $left += 'WMI root\ccm' }
            if ($left.Count) { & $Done 'Warning' ("Still present: {0}. Reboot and run this step again." -f ($left -join ', ')) }
            else { & $Done 'Done - reboot' 'Client fully removed. REBOOT, clear the server side, then install.' }
            return
        }

        'RemoveTpmKey' {
            if (Get-Service CcmExec -ErrorAction SilentlyContinue) { & $Done 'Skipped' 'The client is still installed - uninstall and clean up first.'; return }
            try {
                $pcp = New-Object System.Security.Cryptography.CngProvider('Microsoft Platform Crypto Provider')
                if (-not [System.Security.Cryptography.CngKey]::Exists('ConfigMgrPrimaryKey', $pcp, [System.Security.Cryptography.CngKeyOpenOptions]::MachineKey)) { & $Done 'Done' 'No ConfigMgrPrimaryKey in the TPM - nothing to remove.'; return }
                $k = [System.Security.Cryptography.CngKey]::Open('ConfigMgrPrimaryKey', $pcp, [System.Security.Cryptography.CngKeyOpenOptions]::MachineKey)
                $k.Delete()
                & $Done 'Done' 'ConfigMgrPrimaryKey deleted from the TPM. The next install creates a new key.'
            } catch { & $Done 'Failed' "Could not remove the key: $($_.Exception.Message)" }
            return
        }

        'ServerSide' {
            $d = (Get-CcmTSState).Discovery
            $f = $(if ($d) { $d.Facts } else { @{} })
            $txt = @(
                "Device for the Configuration Manager console / MP logs:"
                "  Computer    : $env:COMPUTERNAME"
                "  Serial      : $($f.Serial)"
                "  SMBIOS GUID : $($f.SmbiosGuid)"
                "  Client GUID : $($f.ClientGuid)"
                "  Hardware ID : $($f.HardwareId)"
                "  Last state  : $(if ($d) { $d.State } else { '(run discovery)' })"
                ""
                "1. Monitoring > System Status > Conflicting Records: merge / delete $env:COMPUTERNAME"
                "2. Devices: search name, serial, SMBIOS GUID - unblock or delete ALL records"
                "3. MP_RegistrationManager.log: search the client GUID / hardware ID"
                "4. After registration: Approve the device if approval is required"
            ) -join "`r`n"
            try { [System.Windows.Forms.Clipboard]::SetText($txt) } catch { }
            & $say $txt
            $a = [System.Windows.Forms.MessageBox]::Show("The device details are on the clipboard (also in the output pane).`r`n`r`nDo the console work on the site server now. Is it done?", 'Clear the device on the server', 'YesNo', 'Information')   # not-a-command: asks the operator
            if ($a -eq 'Yes') { & $Done 'Done' 'Server side cleared (confirmed by operator).' } else { & $Done 'Warning' 'Details copied; server side not confirmed yet.' }
            return
        }

        { $_ -eq 'InstallLocal' -or $_ -eq 'InstallShare' } {
            $isLocal = ($Id -eq 'InstallLocal')
            $d = (Get-CcmTSState).Discovery
            if (-not $d -or ((Get-Date) - $d.Time).TotalMinutes -gt 30) {
                & $say 'Discovery is missing or older than 30 minutes - running it now.'
                $d = Invoke-CcmDiscovery -App $App
            }
            $ready = $(if ($isLocal) { $d.InstallReady } else { $d.ShareReady })
            $block = @($(if ($isLocal) { $d.InstallBlockers } else { $d.ShareBlockers }))
            if ($Ctx.ForceInstall) { $block = @($block | Where-Object { $_ -notmatch 'a client is installed' }); $ready = ($block.Count -eq 0) }
            if (-not $ready) {
                $msg = "Discovery says this install is likely to FAIL:`r`n`r`n - " + ($block -join "`r`n - ") + "`r`n`r`nFix those first (recommended). Install anyway?"
                $a = [System.Windows.Forms.MessageBox]::Show($msg, 'Install gate', 'YesNo', 'Warning', 'Button2')   # not-a-command: safety gate after the command window
                if ($a -ne 'Yes') { & $Done 'Skipped' ('Install gate: ' + ($block -join '; ')); return }
                & $say ('Install gate overridden by operator: ' + ($block -join '; '))
            }
            if (-not $cfg.SiteCode -or -not $cfg.ManagementPoint) { & $Done 'Failed' 'Site code and management point must be set on the Environment tab.'; return }
            $base = $(if ($isLocal) { $cfg.ClientSource } else { $cfg.SiteShare })
            $exe = Join-Path $base 'ccmsetup.exe'
            if (-not (Test-Path -LiteralPath $exe)) { & $Done 'Failed' "Not found: $exe"; return }
            $args2 = @()
            if ($isLocal) { $args2 += "/source:$base" }
            $args2 += "/mp:$($cfg.ManagementPoint)"
            if ($Ctx.ForceInstall) { $args2 += '/forceinstall' }
            $args2 += "SMSSITECODE=$($cfg.SiteCode)"
            $args2 += "SMSMP=$($cfg.ManagementPoint)"
            if ($Ctx.ResetKey) { $args2 += 'RESETKEYINFORMATION=TRUE' }
            $argLine = $args2 -join ' '
            & $say "$exe $argLine"
            & $say 'Installing (5-15 min). Follow Logs: Client: install (ccmsetup).'
            Start-CcmJob -App $App -Name 'ccmsetup install' -FilePath $exe -Arguments $argLine -WaitForProcess @('ccmsetup') -OnExit {
                param($code)
                $r = Get-CcmSetupResult
                $txt = $(if ($r) { "$($r.Time) $($r.Message)" } else { 'no result in ccmsetup.log' })
                if ($r -and $r.Message -match 'return code 0\b') { & $Done 'Done' "Installed. $txt  Next: wait ~5 min, then Verify (registration)." }
                elseif ($r -and $r.Message -match 'return code 7\b') { & $Done 'Done - reboot' "Installed, reboot required. $txt" }
                else { & $Done 'Failed' "Install did not succeed: $txt  (see Logs: ccmsetup.log and client.msi.log)" }
            }.GetNewClosure() | Out-Null
            return
        }

        # ======================================================== 5. Verify
        'Verify' {
            $r = Invoke-CcmDiscovery -App $App -Deep:([bool]$Ctx.Deep)
            & $say ("State: {0} - {1}" -f $r.State, $r.StateDetail)
            if ($r.StateLevel -eq 'OK') { & $Done 'Done' 'Healthy.' } else { & $Done 'Warning' "$($r.State)" }
            return
        }

        default { & $Done 'Failed' "Unknown step '$Id'." }
    }
}
