# Services_CcmSteps.psm1   (LITE TIER)
#
# The step catalog: every troubleshooting / repair step in the order it should
# be worked through, plus the shared tool state and per-computer step progress.
# Metadata only - the code that RUNS the steps is admin tier
# (Admin\Services_CcmStepActions.psm1), so a user-tier session can see the plan
# and the discovery verdict but cannot change the machine.
#
#   Get-CcmStepCatalog            ordered steps (Order, Id, Phase, Title, Kind, Reboot, Risk, Confirm, Summary, Details)
#   Get-CcmStep -Id <id>          one step
#   Get-CcmTSState                the shared tool state ($global:CcmTS): last discovery, running job, handlers
#   Get-CcmTSConfig -App          site code / MP / client source / repair source of the active environment
#   Get-CcmStepProgress -App      saved per-computer step status (survives reboots)
#   Set-CcmStepProgress -App -Id -Status -Result
#   Reset-CcmStepProgress -App [-Id]

function Get-CcmTSState {
    [CmdletBinding()]
    param()
    if (-not ($global:CcmTS -is [hashtable])) {
        $global:CcmTS = @{
            Discovery       = $null
            Job             = $null
            ScanHandlers    = New-Object System.Collections.ArrayList
            ProgressHandlers = New-Object System.Collections.ArrayList
            RepairSourceOverride = ''
        }
    }
    return $global:CcmTS
}

function Get-CcmTSConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $App)
    $site = ([string]$App.GetSetting('SiteCode')).Trim().ToUpperInvariant()
    $mp   = ([string]$App.GetSetting('ManagementPoint')).Trim()
    $src  = ([string]$App.GetSetting('ClientSource')).Trim().TrimEnd('\')
    $rep  = ([string]$App.GetSetting('RepairSource')).Trim().TrimEnd('\')
    if (-not $src) { $src = 'C:\ccmclient' }
    $st = Get-CcmTSState
    if ($st.RepairSourceOverride) { $rep = [string]$st.RepairSourceOverride }
    $share = ''
    if ($mp -and $site) { $share = "\\$mp\SMS_$site\Client" }
    [pscustomobject]@{
        SiteCode        = $site
        ManagementPoint = $mp
        ClientSource    = $src
        RepairSource    = $rep
        SiteShare       = $share
    }
}

function Get-CcmStepCatalog {
    [CmdletBinding()]
    param()
    $n = [Environment]::NewLine
    $steps = @(
        # ---------------------------------------------------------------- 1. Prepare
        @{ Id='Elevate'; Phase='1 Prepare'; Title='Run this tool as administrator'; Kind='Auto'; Reboot='No'; Risk='None'
           Summary='Restart the tool elevated. Almost every check and repair needs administrator rights.'
           Details=("WHAT: Starts this EXE again with 'Run as administrator' and closes this window." + $n +
                    "WHEN: The Discovery banner says the session is not elevated." + $n +
                    "RUNS: Start-Process <this exe> -Verb RunAs") }
        @{ Id='TimeSync'; Phase='1 Prepare'; Title='Resync the clock with the domain'; Kind='Auto'; Reboot='No'; Risk='Low'
           Summary='Clock skew over ~5 minutes breaks client registration and Kerberos.'
           Details=("WHAT: Makes sure the Windows Time service runs, then forces a resync from the domain hierarchy." + $n +
                    "WHEN: Discovery shows a large offset against the management point." + $n +
                    "RUNS: Start-Service W32Time; w32tm /resync /force") }
        @{ Id='Services'; Phase='1 Prepare'; Title='Repair required Windows services'; Kind='Auto'; Reboot='No'; Risk='Low'
           Summary='Re-enables and starts services the client depends on (CNG Key Isolation, WMI, BITS, Cryptographic, Installer ...).'
           Details=("WHAT: Any required service set to Disabled is set back to its Windows default start type, and services that must run are started." + $n +
                    "      Covers KeyIso (CNG Key Isolation - the 0x800706d9 'cannot create certificate' cause), Winmgmt, BITS, wuauserv, CryptSvc, msiserver, TrustedInstaller, EventLog, W32Time, CcmExec." + $n +
                    "      Services are only ever ENABLED here, never disabled." + $n +
                    "WHEN: Discovery lists a disabled / stopped service, or the client cannot create its certificates." + $n +
                    "NOTE: If a service goes back to Disabled after gpupdate or a reboot, a GPO or security baseline enforces it - IT has to change that.") }

        # ---------------------------------------------------------------- 2. Windows health
        @{ Id='ChkdskScan'; Phase='2 Windows health'; Title='Check the disk (online scan)'; Kind='Job'; Reboot='No'; Risk='Low'
           Summary='Read-mostly online scan of C: for file system errors; scattered corruption can mean a failing disk.'
           Details=("WHAT: Online NTFS scan of the system drive. It does not take the volume offline." + $n +
                    "WHEN: SFC/DISM find corruption that keeps coming back, or as a baseline before repairs." + $n +
                    "RUNS: chkdsk.exe C: /scan   (visible console window)" + $n +
                    "RESULT: exit 0 = no problems, 1 = errors found and fixed, 3 = errors that need an offline repair (chkdsk C: /f at next boot).") }
        @{ Id='WmiVerify'; Phase='2 Windows health'; Title='Verify the WMI repository'; Kind='Auto'; Reboot='No'; Risk='None'
           Summary='The client lives in WMI (root\ccm). An inconsistent repository breaks install and registration.'
           Details=("WHAT: Asks WMI to check its own repository. Read-only." + $n +
                    "RUNS: winmgmt /verifyrepository" + $n +
                    "NEXT: 'inconsistent' -> run 'Salvage the WMI repository'.") }
        @{ Id='WmiSalvage'; Phase='2 Windows health'; Title='Salvage the WMI repository'; Kind='Job'; Reboot='Recommended'; Risk='Medium'
           Confirm='Salvage rebuilds the WMI repository, keeping what it can. Only run it when verify reported the repository as inconsistent. Continue?'
           Summary='Rebuilds an inconsistent WMI repository, merging what is readable.'
           Details=("WHAT: Consistency check plus rebuild of the WMI repository (keeps readable data)." + $n +
                    "WHEN: Only after 'Verify the WMI repository' reports it inconsistent." + $n +
                    "RUNS: winmgmt /salvagerepository" + $n +
                    "NOTE: /resetrepository is deliberately not offered - it throws away every provider registration.") }
        @{ Id='DismScan'; Phase='2 Windows health'; Title='Scan the component store (DISM ScanHealth)'; Kind='Job'; Reboot='No'; Risk='None'
           Summary='Full scan of the WinSxS component store; tells you whether a RestoreHealth is needed.'
           Details=("WHAT: Scans the component store for corruption (5-30 minutes). Read-only." + $n +
                    "RUNS: DISM /Online /Cleanup-Image /ScanHealth, then /CheckHealth to read the verdict." + $n +
                    "NEXT: 'repairable' -> RestoreHealth (from a healthy PC on an air-gapped network).") }
        @{ Id='DismRestoreSource'; Phase='2 Windows health'; Title='Repair the component store from a healthy PC (DISM /Source /LimitAccess)'; Kind='Job'; Reboot='If repaired'; Risk='Low'
           Summary='The fix that works air-gapped: repairs WinSxS from another PC on the SAME build, without Windows Update.'
           Details=("WHAT: DISM RestoreHealth using the repair source below instead of Windows Update / WSUS." + $n +
                    "SOURCE: \\HEALTHY-PC\C$\Windows (same Windows build, ideally same edition and language), or wim:E:\install.wim:1 patched to the same build." + $n +
                    "        Set it in the Repair source box (or the environment's RepairSource). 'Test source' compares the source's build with this PC." + $n +
                    "RUNS: DISM /Online /Cleanup-Image /RestoreHealth /Source:<source> /LimitAccess" + $n +
                    "WHEN: SFC reports 'source file in store is also corrupted', or ScanHealth says repairable. Then run SFC again.") }
        @{ Id='DismRestoreWU'; Phase='2 Windows health'; Title='Repair the component store from Windows Update / WSUS'; Kind='Job'; Reboot='If repaired'; Risk='Low'
           Summary='Standard RestoreHealth. Not useful on an air-gapped network - use the healthy-PC step instead.'
           Details=("RUNS: DISM /Online /Cleanup-Image /RestoreHealth" + $n +
                    "NOTE: Fails with 0x800f081f / 0x800f0906 when no repair content is reachable (air-gapped, or WSUS without repair content).") }
        @{ Id='Sfc'; Phase='2 Windows health'; Title='System File Checker (sfc /scannow)'; Kind='Job'; Reboot='If repaired'; Risk='Low'
           Summary='Verifies and repairs protected system files from the component store; results summarised from CBS.log.'
           Details=("RUNS: sfc /scannow   (visible console window, 10-20 minutes)" + $n +
                    "RESULT: read from CBS.log [SR] lines: files repaired vs 'Cannot repair' (store also corrupt -> repair the store from a healthy PC, then run SFC again)." + $n +
                    "NOTE: 'Overlap: Directory ... owned twice' lines in CBS.log are harmless.") }
        @{ Id='DismCleanup'; Phase='2 Windows health'; Title='Clean up superseded components (DISM StartComponentCleanup)'; Kind='Job'; Reboot='No'; Risk='Low'
           Summary='Removes superseded component versions; frees space and can clear stuck servicing.'
           Details=("RUNS: DISM /Online /Cleanup-Image /StartComponentCleanup" + $n +
                    "WHEN: After a successful repair, or when C: is low on space. Updates installed before it can no longer be uninstalled.") }
        @{ Id='WuReset'; Phase='2 Windows health'; Title='Reset Windows Update components'; Kind='Auto'; Reboot='No'; Risk='Medium'
           Confirm='This stops the update services, renames SoftwareDistribution and catroot2 (kept as .bak folders) and starts the services again. Local update history is lost. Continue?'
           Summary='Classic WU reset: rename SoftwareDistribution and catroot2, restart the update services.'
           Details=("WHAT: Stops wuauserv, BITS, CryptSvc, msiserver; renames C:\Windows\SoftwareDistribution and System32\catroot2 to *.bak_<time>; starts the services again." + $n +
                    "WHEN: Update scans / installs fail repeatedly, or the client's software update scan never completes." + $n +
                    "NOTE: Nothing is deleted - the old folders stay as .bak and can be removed later.") }
        @{ Id='WuTroubleshooter'; Phase='2 Windows health'; Title='Windows Update troubleshooter'; Kind='Job'; Reboot='No'; Risk='Low'
           Summary="Runs Windows' own Windows Update troubleshooting pack unattended and saves its report."
           Details=("RUNS: Get-TroubleshootingPack <windir>\diagnostics\system\WindowsUpdate | Invoke-TroubleshootingPack -Unattended -Result <folder>" + $n +
                    "      in a visible Windows PowerShell window. msdt.exe is deliberately not used (deprecated, and flagged by security tools)." + $n +
                    "RESULT: the report folder (ResultReport.xml) - Open log opens it.") }

        # ---------------------------------------------------------------- 3. Client: light repairs
        @{ Id='RestartCcmExec'; Phase='3 Client repair'; Title='Restart the SMS Agent Host'; Kind='Auto'; Reboot='No'; Risk='Low'
           Summary='Restarts CcmExec so it retries certificate creation, site assignment and registration.'
           Details=("RUNS: Stop SMS Agent Host (CcmExec), wait, start it." + $n +
                    "WHEN: After fixing services / KeyIso, or the client looks stuck.") }
        @{ Id='TriggerActions'; Phase='3 Client repair'; Title='Run client actions (policy, DDR, inventory, scans)'; Kind='Auto'; Reboot='No'; Risk='None'
           Summary='Machine policy retrieval + evaluation, discovery data, hardware inventory, app evaluation, update scan.'
           Details=("RUNS: SMS_Client.TriggerSchedule for {..21} {..22} {..3} {..1} {..121} {..113}" + $n +
                    "WHEN: The client is registered (approval 1). Before that only Machine/User Policy exist and nothing comes down.") }
        @{ Id='ResetPolicy'; Phase='3 Client repair'; Title='Reset machine policy'; Kind='Auto'; Reboot='No'; Risk='Low'
           Summary='Purges cached policy so the client downloads it again from the MP.'
           Details=("RUNS: SMS_Client.ResetPolicy(uFlags=1), then machine policy retrieval." + $n +
                    "WHEN: Registered, but policy looks stale or deployments do not show up.") }
        @{ Id='ClientRepair'; Phase='3 Client repair'; Title='Repair the client in place (ccmrepair)'; Kind='Job'; Reboot='No'; Risk='Low'
           Summary='Repairs the installed client files and registrations without uninstalling.'
           Details=("RUNS: C:\Windows\CCM\ccmrepair.exe, then waits for the repair (ccmsetup / msiexec) to finish." + $n +
                    "WHEN: Client files or WMI classes are damaged but the identity is fine.") }
        @{ Id='ResetIdentity'; Phase='3 Client repair'; Title='Reset the client identity (new GUID + certificates)'; Kind='Auto'; Reboot='No'; Risk='Medium'
           Confirm="This gives the client a NEW identity: SMSCFG.ini and the SMS certificates are deleted and the agent restarted. The device's old record in the console becomes obsolete - delete it. Continue?"
           Summary='Deletes SMSCFG.ini and the SMS certificates so the client registers as new.'
           Details=("RUNS: Stop CcmExec; delete C:\Windows\SMSCFG.ini; delete Cert:\LocalMachine\SMS\*; start CcmExec." + $n +
                    "WHEN: Duplicate / conflicting records, a revoked or blocked identity ('Server rejected registration request: 3')." + $n +
                    "      Clear the server side FIRST (step 'Clear the device on the server'), or the new identity is rejected too.") }

        # ---------------------------------------------------------------- 4. Client: reinstall
        @{ Id='Uninstall'; Phase='4 Client reinstall'; Title='Uninstall the client (ccmsetup /uninstall)'; Kind='Job'; Reboot='Yes'; Risk='High'
           Confirm='This uninstalls the Configuration Manager client. Reboot afterwards, then run the cleanup step. Continue?'
           Summary='Supported uninstall. Waits until every ccmsetup process has finished, then checks ccmsetup.log.'
           Details=("RUNS: C:\Windows\ccmsetup\ccmsetup.exe /uninstall (or the client source's ccmsetup.exe)" + $n +
                    "RESULT: 'Uninstall succeeded' in C:\Windows\ccmsetup\Logs\ccmsetup.log." + $n +
                    "THEN: Reboot, then 'Remove client leftovers'.") }
        @{ Id='Cleanup'; Phase='4 Client reinstall'; Title='Remove client leftovers (files, registry, WMI, certificates, tasks)'; Kind='Auto'; Reboot='Yes'; Risk='High'
           Confirm='This removes everything the client leaves behind: CCM services, C:\Windows\CCM, ccmsetup, ccmcache, SMSCFG.ini, the CCM/SMS registry keys, the root\ccm WMI namespaces, SMS certificates and client scheduled tasks. Continue?'
           Summary='Removes every remnant so the next install starts clean. Run after the uninstall and a reboot.'
           Details=("REMOVES: services CcmExec/ccmsetup/smstsmgr/CmRcService; C:\Windows\CCM, ccmsetup, ccmcache, SMSCFG.ini, SMS*.mif;" + $n +
                    "         HKLM\SOFTWARE\Microsoft\CCM, CCMSetup, SMS (+Wow6432Node); WMI root\ccm, root\SmsDm, root\cimv2\sms;" + $n +
                    "         Cert:\LocalMachine\SMS; scheduled tasks under \Microsoft\Configuration Manager; Software Center shortcut." + $n +
                    "THEN: Reboot. If anything is still listed afterwards, run it once more.") }
        @{ Id='RemoveTpmKey'; Phase='4 Client reinstall'; Title='Remove the client key from the TPM'; Kind='Auto'; Reboot='No'; Risk='Medium'
           Confirm="This deletes the client's 'ConfigMgrPrimaryKey' from the Microsoft Platform Crypto Provider (TPM), so the next install creates a brand-new key. Only do this with the client uninstalled. Continue?"
           Summary="Deletes the TPM-held ConfigMgrPrimaryKey so a reinstall gets a completely new identity."
           Details=("RUNS: .NET CngKey.Open('ConfigMgrPrimaryKey', 'Microsoft Platform Crypto Provider', MachineKey).Delete()  (no certutil)" + $n +
                    "WHEN: After the cleanup, when the old identity keeps being rejected. Does not touch BitLocker or other TPM keys.") }
        @{ Id='ServerSide'; Phase='4 Client reinstall'; Title='Clear the device on the server (manual)'; Kind='Manual'; Reboot='No'; Risk='None'
           Summary='Console work on the site server: conflicting records, blocked / duplicate / obsolete records, approval.'
           Details=("DO (Configuration Manager console):" + $n +
                    "  1. Monitoring > System Status > Conflicting Records - Merge or delete this computer." + $n +
                    "  2. Assets and Compliance > Devices - search by name, serial and SMBIOS GUID (Copy details puts them on the clipboard). Unblock, or delete ALL records." + $n +
                    "  3. MP: MP_RegistrationManager.log - search for the client GUID / hardware ID for the exact reason." + $n +
                    "  4. After the client registers: Approve the device if the site requires approval." + $n +
                    "WHEN: Before a reinstall or identity reset, and whenever registration is rejected or pending.") }
        @{ Id='InstallLocal'; Phase='4 Client reinstall'; Title='Install the client from the local source'; Kind='Job'; Reboot='No'; Risk='Medium'
           Confirm='Install the Configuration Manager client from the local client source now?'
           Summary='ccmsetup.exe from the local source with /source, site code and MP. Allowed only when Discovery says the install can succeed.'
           Details=("RUNS: <ClientSource>\ccmsetup.exe /source:<ClientSource> /mp:<MP> SMSSITECODE=<site> SMSMP=<MP> [RESETKEYINFORMATION=TRUE] [/forceinstall]" + $n +
                    "GATE: Discovery must show no install blockers (elevated, no client remnants, no pending reboot, key storage OK, WMI consistent," + $n +
                    "      services OK, MP reachable and answering, clock in sync, source complete). You can override, but that is why installs 'rarely work'." + $n +
                    "RESULT: 'CcmSetup is exiting with return code 0' in ccmsetup.log, then registration in ClientIDManagerStartup.log.") }
        @{ Id='InstallShare'; Phase='4 Client reinstall'; Title='Install the client from the site server share'; Kind='Job'; Reboot='No'; Risk='Medium'
           Confirm='Install the Configuration Manager client from the site server share now?'
           Summary='Same as the local install, run from \\<MP>\SMS_<site>\Client. Same gate.'
           Details=("RUNS: \\<MP>\SMS_<site>\Client\ccmsetup.exe /mp:<MP> SMSSITECODE=<site> SMSMP=<MP> [RESETKEYINFORMATION=TRUE] [/forceinstall]" + $n +
                    "WHEN: No usable local source. Needs SMB (445) to the server.") }

        # ---------------------------------------------------------------- 5. Verify
        @{ Id='Verify'; Phase='5 Verify'; Title='Verify: run discovery again'; Kind='Auto'; Reboot='No'; Risk='None'
           Summary='Re-runs every discovery check and shows the new verdict.'
           Details=("WANT: 'Healthy' - registered with approval 1, client actions present, policy received, Software Center installed." + $n +
                    "Registration retries every ~5 minutes; run this again after a cycle or two.") }
    )
    $i = 0
    foreach ($s in $steps) {
        $i++
        [pscustomobject]@{
            Order   = $i
            Id      = $s.Id
            Phase   = $s.Phase
            Title   = $s.Title
            Kind    = $s.Kind
            Reboot  = $s.Reboot
            Risk    = $s.Risk
            Confirm = $(if ($s.ContainsKey('Confirm')) { $s.Confirm } else { '' })
            Summary = $s.Summary
            Details = $s.Details
        }
    }
}

function Get-CcmStep {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Id)
    foreach ($s in (Get-CcmStepCatalog)) { if ($s.Id -eq $Id) { return $s } }
    return $null
}

# ---- per-computer step progress (Settings\StepProgress_<COMPUTER>.json) ----
function Get-CcmStepProgressPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $App)
    $dir = Get-AppSettingsDir -App $App
    return (Join-Path $dir ("StepProgress_{0}.json" -f $env:COMPUTERNAME))
}

function Get-CcmStepProgress {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $App)
    $h = @{}
    try {
        $p = Get-CcmStepProgressPath -App $App
        if (Test-Path -LiteralPath $p) {
            $j = [System.IO.File]::ReadAllText($p) | ConvertFrom-Json
            foreach ($pr in $j.PSObject.Properties) {
                $h[$pr.Name] = [pscustomobject]@{ Status = [string]$pr.Value.Status; LastRun = [string]$pr.Value.LastRun; Result = [string]$pr.Value.Result }
            }
        }
    } catch { try { $App.Log('WARN', 'Steps', "step progress could not be read: $($_.Exception.Message)") } catch { } }
    return $h
}

function Set-CcmStepProgress {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $App, [Parameter(Mandatory)] [string]$Id, [string]$Status = 'Done', [string]$Result = '')
    $h = Get-CcmStepProgress -App $App
    $h[$Id] = [pscustomobject]@{ Status = $Status; LastRun = (Get-Date).ToString('yyyy-MM-dd HH:mm'); Result = $Result }
    Save-CcmStepProgress -App $App -Progress $h
}

function Reset-CcmStepProgress {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $App, [string]$Id = '')
    $h = @{}
    if ($Id) { $h = Get-CcmStepProgress -App $App; [void]$h.Remove($Id) }
    Save-CcmStepProgress -App $App -Progress $h
}

function Save-CcmStepProgress {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $App, [Parameter(Mandatory)] [hashtable]$Progress)
    try {
        $o = [ordered]@{}
        foreach ($k in @($Progress.Keys | Sort-Object)) { $o[$k] = $Progress[$k] }
        $json = [pscustomobject]$o | ConvertTo-Json -Depth 4
        [System.IO.File]::WriteAllText((Get-CcmStepProgressPath -App $App), $json, (New-Object System.Text.UTF8Encoding($false)))
    } catch { try { $App.Log('WARN', 'Steps', "step progress could not be saved: $($_.Exception.Message)") } catch { } }
    $st = Get-CcmTSState
    foreach ($hd in @($st.ProgressHandlers)) { try { & $hd } catch { } }
}
