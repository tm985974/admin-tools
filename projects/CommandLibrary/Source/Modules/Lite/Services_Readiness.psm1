# Services_Readiness.psm1   (LITE TIER)
#
# "Will this entry work here?" - answered BEFORE Run, and explained after a
# failure. Three things make a library entry fail on a given computer:
#
#   Software      a cmdlet / module / tool it calls is not installed
#                 (ActiveDirectory module, RSAT, dcdiag, lmstat ...)
#   Rights        it needs an elevated (Run as administrator) session
#   Connectivity  the target computer / DC does not answer on the port the
#                 command uses (AD Web Services 9389, WinRM 5985, RPC 135 ...)
#
# Software and rights are checked once per session for every entry (a
# background scan, so the window never waits). Connectivity depends on the
# target you type, so it is checked when you press Check in the Run dialog and
# again at the start of every run - an unreachable host is reported in about a
# second instead of after a 30-90 second timeout.
#
# Fallback methods: an entry may carry alternates (Methods: Label + Template,
# same fields as the entry). The first method whose commands exist (and, for a
# target, whose port answers) is the one that runs. A read-only entry whose
# method fails for an environment reason (not installed / unreachable / denied)
# moves on to the next method automatically; an entry that changes things
# never retries.
#
#   Get-LibraryEntryNeeds -Entry $e [-MethodIndex n]  -> Commands, Admin, Domain, Ports, Diagnostic ...
#   Get-LibraryEntryMethods -Entry $e                  -> primary + alternates
#   Start-LibraryReadinessScan -Entries $e             (background)
#   Receive-LibraryReadinessScan                       -> snapshot once done, else $null
#   Get-LibraryReadinessSnapshotNow -Entries $e        (synchronous; tests)
#   Get-LibraryEntryReadiness -Entry $e -Snapshot $s [-Remote]
#       -> Level (Ready | Warn | Blocked | Unknown), Summary, Lines, MethodIndex, MethodLabel
#   Test-LibraryHostPorts -Hosts a,b -Ports 9389 [-TimeoutMs 1500]
#   Get-LibraryTargetHosts -Entry $e -Values $v        (host names typed into target fields)
#   Get-LibraryFailureReason -Text 'Access is denied'  -> Kind, Hint
#   Get-LibraryRunPreamble                             (helper code for the runner)

# ------------------------------------------------------------ knowledge ---

# command (regex on the name) -> where it comes from and how to get it
$script:ReadySources = @(
    @{ Pattern = '^(Get|Set|New|Remove|Add|Enable|Disable|Unlock|Search|Move|Rename|Clear|Reset|Install|Uninstall|Test|Restore|Sync)-AD'; Source = 'ActiveDirectory module'; Fix = 'Install RSAT AD tools: Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0 (Win 10/11) or Install-WindowsFeature RSAT-AD-PowerShell (Server).' }
    @{ Pattern = '^(Get|Set|New|Remove|Backup|Restore|Import|Copy|Rename|Invoke)-GP|^Get-GPResultantSetOfPolicy$'; Source = 'GroupPolicy module'; Fix = 'Install GPMC: Add-WindowsCapability -Online -Name Rsat.GroupPolicy.Management.Tools~~~~0.0.1.0 or Install-WindowsFeature GPMC.' }
    @{ Pattern = '^(Get|Install|Uninstall|Add|Remove)-WindowsFeature$'; Source = 'ServerManager module'; Fix = 'Windows Server only - on a workstation use Get-WindowsCapability / Get-WindowsOptionalFeature.' }
    @{ Pattern = '^(Get|Add|Set|Remove|Clear|Show)-DnsServer'; Source = 'DnsServer module'; Fix = 'Install RSAT DNS: Add-WindowsCapability -Online -Name Rsat.Dns.Tools~~~~0.0.1.0 or Install-WindowsFeature RSAT-DNS-Server.' }
    @{ Pattern = '^(Get|Add|Set|Remove)-Dhcp'; Source = 'DhcpServer module'; Fix = 'Install RSAT DHCP: Add-WindowsCapability -Online -Name Rsat.DHCP.Tools~~~~0.0.1.0 or Install-WindowsFeature RSAT-DHCP.' }
    @{ Pattern = '^(Get|Reset|Set|Invoke|Update|Find)-Laps'; Source = 'LAPS module (Windows LAPS)'; Fix = 'Needs Windows LAPS (April 2023 cumulative update or later) on this computer.' }
    @{ Pattern = '-AdmPwd'; Source = 'AdmPwd.PS (legacy LAPS)'; Fix = 'Install the legacy LAPS management tools (LAPS.x64.msi, PowerShell module option).' }
    @{ Pattern = '^Get-KdsRootKey$|^Add-KdsRootKey$'; Source = 'Kds module'; Fix = 'Part of RSAT AD tools / a domain controller.' }
    @{ Pattern = '-ClusterNode|-Cluster$|-ClusterGroup'; Source = 'FailoverClusters module'; Fix = 'Install RSAT Failover Clustering tools.' }
    @{ Pattern = '-MpPreference$|-MpComputerStatus$|-MpScan$|-MpThreat'; Source = 'Defender module'; Fix = 'Needs Microsoft Defender on this computer.' }
    @{ Pattern = '^(dcdiag|repadmin|netdom|dsquery|dsget|dsmod|dsadd|ntdsutil|setspn|csvde|ldifde|dsacls)$'; Source = 'AD DS tools'; Fix = 'Install RSAT AD tools: Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0.' }
    @{ Pattern = '^(gpmc\.msc|gpme)$'; Source = 'GPMC'; Fix = 'Install GPMC (RSAT Group Policy tools).' }
    @{ Pattern = '^dnscmd$'; Source = 'DNS server tools'; Fix = 'Install RSAT DNS tools.' }
    @{ Pattern = '^(lmstat|lmutil|lmtools)$'; Source = 'FlexLM tools'; Fix = 'Run from the FlexLM / FactoryTalk Activation folder, or add that folder to PATH.' }
    @{ Pattern = '^keytool$'; Source = 'Java keytool'; Fix = 'Use the keytool.exe in the application''s Java bin folder, or add it to PATH.' }
    @{ Pattern = '^(sqlcmd|Invoke-Sqlcmd)$'; Source = 'SQL Server tools'; Fix = 'Install SQL Server command line tools / the SqlServer module.' }
    @{ Pattern = '^(gwcmd)$'; Source = 'Ignition gateway'; Fix = 'Run from the Ignition install folder on the gateway.' }
    @{ Pattern = '^(Get-WmiObject|Invoke-WmiMethod|Set-WmiInstance|Remove-WmiObject|Register-WmiEvent|Get-EventLog|Write-EventLog|Clear-EventLog|New-EventLog|Limit-EventLog)$'; Source = 'Windows PowerShell 5.1'; Fix = 'Not in PowerShell 7 - use the CIM / Get-WinEvent version.' }
)

# command -> TCP ports it needs on the computer named in a target field
$script:ReadyPorts = @(
    @{ Pattern = '^(Get|Set|New|Remove|Add|Enable|Disable|Unlock|Search|Move|Rename|Clear|Reset|Install|Uninstall|Test|Restore|Sync)-AD'; Ports = @(9389); Name = 'AD Web Services' }
    @{ Pattern = '-GP|^Get-GPResultantSetOfPolicy$'; Ports = @(389, 445); Name = 'LDAP / SMB' }
    @{ Pattern = '^(dcdiag|repadmin|netdom|dsquery|dsget|setspn)$'; Ports = @(389, 135); Name = 'LDAP / RPC' }
    @{ Pattern = '^(Invoke-Command|Enter-PSSession|New-PSSession|New-CimSession|Get-CimInstance|Invoke-CimMethod|Set-CimInstance|Remove-CimInstance|Get-CimAssociatedInstance)$'; Ports = @(5985, 5986); Name = 'WinRM' }
    @{ Pattern = '^(Get-WmiObject|Invoke-WmiMethod|Set-WmiInstance|Get-WinEvent|Get-EventLog|Get-HotFix|Restart-Computer|Stop-Computer|wmic)$'; Ports = @(135); Name = 'RPC' }
    @{ Pattern = '^(Get-Service|Set-Service|sc|reg|shutdown|psexec|Get-Process|Get-Counter|schtasks|msinfo32|systeminfo|tasklist|taskkill|qwinsta|quser|logoff|Get-Printer|Get-PrintJob|driverquery)$'; Ports = @(445, 135); Name = 'SMB / RPC' }
    @{ Pattern = '^Send-MailMessage$'; Ports = @(25, 587); Name = 'SMTP' }
)

# Commands whose JOB is to test reachability: never pre-blocked by a port check.
$script:ReadyDiagnostics = @('Test-NetConnection', 'Test-Connection', 'ping', 'tracert', 'pathping', 'Test-WSMan', 'portqry',
    'Resolve-DnsName', 'nslookup', 'nltest', 'w32tm', 'Test-ComputerSecureChannel', 'arp', 'Test-NetConnectionFast', 'telnet', 'curl', 'Invoke-WebRequest')

# Parameter names that hold the computer(s) the command talks to.
$script:ReadyTargetParam = '^(ComputerName|ComputerNames|Computer|Computers|Server|Servers|Target|Targets|HostName|Host|Hosts|DC|DCs|DomainController|DomainControllers|Machine|MachineName|SmtpServer|PrimaryServer)$'

# Run-as-administrator: commands that refuse to work in a normal session.
$script:ReadyAdminCommands = '^(bcdedit|sfc|chkdsk|manage-bde|takeown|auditpol|secedit|diskpart|Repair-WindowsImage|Install-WindowsFeature|Uninstall-WindowsFeature|' +
    'Add-WindowsCapability|Remove-WindowsCapability|Enable-WindowsOptionalFeature|Disable-WindowsOptionalFeature|Add-MpPreference|Set-MpPreference|Remove-MpPreference|' +
    'Enable-PSRemoting|Disable-PSRemoting|Set-NetFirewallRule|New-NetFirewallRule|Remove-NetFirewallRule|Enable-NetFirewallRule|Disable-NetFirewallRule|' +
    'Set-NetIPAddress|New-NetIPAddress|Remove-NetIPAddress|Set-DnsClientServerAddress|Restart-NetAdapter|Enable-NetAdapter|Disable-NetAdapter|' +
    'Clear-EventLog|Limit-EventLog|New-EventLog|Register-ScheduledTask|Unregister-ScheduledTask|Set-ScheduledTask|Enable-BitLocker|Disable-BitLocker|' +
    'Suspend-BitLocker|Resume-BitLocker|Add-BitLockerKeyProtector|Initialize-Disk|Set-Disk|Format-Volume|Resize-Partition|New-Partition|' +
    'Set-ExecutionPolicy|Enable-ComputerRestore|Checkpoint-Computer|Add-Computer|Remove-Computer|Rename-Computer|Reset-ComputerMachinePassword|' +
    'Set-LocalUser|New-LocalUser|Remove-LocalUser|Add-LocalGroupMember|Remove-LocalGroupMember|Enable-LocalUser|Disable-LocalUser|' +
    'Install-Package|Uninstall-Package|wusa|UsoClient|Install-Module)$'
# ...and command lines whose arguments make them admin-only (pattern, plain words)
$script:ReadyAdminText = @(
    @{ P = '(?i)\bdism(\.exe)?\s+/online\s+/(cleanup|enable|disable|add|remove)'; W = 'DISM /Online repairs and changes' }
    @{ P = '(?i)\bnetsh\s+[^\r\n|]*\b(set|add|delete|reset)\b'; W = 'netsh changes' }
    @{ P = '(?i)\bipconfig\s+/(flushdns|registerdns)'; W = 'ipconfig /flushdns and /registerdns' }
    @{ P = '(?i)\bw32tm\s+/(config|resync|register|unregister)'; W = 'w32tm /config and /resync' }
    @{ P = '(?i)\bwevtutil\s+(cl|clear-log|sl|set-log)\b'; W = 'changing or clearing an event log' }
    @{ P = '(?i)\bnet\s+(stop|start)\b|\bsc(\.exe)?\s+(stop|start|config|delete|create|failure)\b|\b(Stop|Start|Restart|Set)-Service\b'; W = 'starting, stopping or changing a service' }
    @{ P = '(?i)\bGet-WinEvent\b[^|]*?LogName\s*=\s*''Security'''; W = 'reading the Security log' }
    @{ P = '(?i)\breg(\.exe)?\s+(add|delete|import)\s+"?HKLM|\b(New|Set|Remove)-Item(Property)?\b[^\r\n]*HKLM:'; W = 'writing to HKLM' }
    @{ P = '(?i)\bicacls\b[^\r\n]*/(restore|setowner|reset)'; W = 'icacls /restore, /setowner and /reset' }
    @{ P = '(?i)\bmsiexec(\.exe)?\b[^\r\n]*/(i|x|fa|package|uninstall)\b'; W = 'installing or removing software' }
)

# AD-bound commands: the computer should be in a domain (or a Server / Domain filled in).
$script:ReadyDomainCommands = '^((Get|Set|New|Remove|Add|Enable|Disable|Unlock|Search|Move|Rename|Clear|Reset|Test)-AD|(Get|Set|New|Remove|Backup|Restore|Import|Copy|Invoke)-GP|Get-GPResultantSetOfPolicy|' +
    'nltest|netdom|dcdiag|repadmin|setspn|dsquery|dsget|gpresult|Test-ComputerSecureChannel|Get-KdsRootKey|Test-ADServiceAccount)$'

# Names the parser reports that are not commands to look for.
$script:ReadyIgnore = @('%', '?', 'foreach', 'where', 'select', 'sort', 'ft', 'fl', 'gm', 'measure', 'group', 'cd', 'dir', 'ls', 'cls',
    'echo', 'cat', 'type', 'copy', 'move', 'del', 'rm', 'md', 'mkdir', 'iex', 'icm', 'gci', 'gc', 'gi', 'gp', 'sp', 'ni', 'ri', 'sls', 'ogv', 'oh', 'h', 'r', 'cmd', 'powershell', 'exit')

$script:ReadyToolNames = '(?i)^(nltest|netdom|dcdiag|repadmin|w32tm|gpresult|gpupdate|secedit|nslookup|ipconfig|ping|tracert|netstat|whoami|klist|setspn|' +
    'dsquery|dsget|ntdsutil|certutil|icacls|takeown|net|sc|reg|msiexec|wmic|robocopy|xcopy|schtasks|wevtutil|auditpol|dism|sfc|chkdsk|shutdown|bcdedit|' +
    'manage-bde|subst|setx|hostname|systeminfo|quser|qwinsta|arp|route|pathping|netsh|lmstat|lmutil|tasklist|taskkill|driverquery|powercfg|pnputil|fsutil|' +
    'keytool|regsvr32|mklink|winrm|wusa|nbtstat|logoff|msg|attrib|findstr|winget|sqlcmd)$'

$script:NeedsCache = @{}
$script:Scan = $null

# ------------------------------------------------------------ analysis ---

# Primary (index 0) plus the entry's alternates, as uniform objects.
function Get-LibraryEntryMethods {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Entry)
    $isCmd = [string]$Entry.Kind -eq 'Command'
    $list = New-Object System.Collections.Generic.List[object]
    $list.Add([pscustomobject]@{ Index = 0; Label = $(if ($Entry.Function) { [string]$Entry.Function } else { 'Default' }); Template = $(if ($isCmd) { [string]$Entry.Template } else { '' }); Code = $(if ($isCmd) { '' } else { [string]$Entry.Code }); IsPrimary = $true })
    $i = 1
    foreach ($m in @($Entry.Methods)) {
        if (-not $m) { continue }
        $tpl = if ($m -is [System.Collections.IDictionary]) { [string]$m['Template'] } else { [string]$m.Template }
        $lbl = if ($m -is [System.Collections.IDictionary]) { [string]$m['Label'] } else { [string]$m.Label }
        if (-not $tpl.Trim()) { continue }
        $list.Add([pscustomobject]@{ Index = $i; Label = $(if ($lbl) { $lbl } else { "Method $($i + 1)" }); Template = $tpl; Code = ''; IsPrimary = $false })
        $i++
    }
    return $list.ToArray()
}

# The command names a piece of template / code calls (template fields become a dummy word).
function Get-LibraryCalledCommands {
    param([AllowEmptyString()] [string]$Text, [switch]$IsTemplate)
    $src = [string]$Text
    $tokens = $null; $errs = $null
    if ($IsTemplate) {
        # fields become a dummy value: quoted where an expression may hold it,
        # bare where it is raw text (it can be part of a command name)
        $src = $src -replace '\[\[', '' -replace '\]\]', ''
        $quoted = [regex]::Replace($src, '\{([A-Za-z]\w*)(:[^}]*)?\}', { param($m) if ($m.Groups[2].Value -match 'raw') { 'zqxfield' } else { "'zqxfield'" } })
        $bare = [regex]::Replace($src, '\{[A-Za-z]\w*(?::[^}]*)?\}', 'zqxfield')
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($quoted, [ref]$tokens, [ref]$errs)
        if (@($errs).Count) {
            $e2 = $null
            $ast2 = [System.Management.Automation.Language.Parser]::ParseInput($bare, [ref]$tokens, [ref]$e2)
            if (@($e2).Count -lt @($errs).Count) { $ast = $ast2; $errs = $e2 }
        }
    }
    else { $ast = [System.Management.Automation.Language.Parser]::ParseInput($src, [ref]$tokens, [ref]$errs) }
    $defined = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object { $_.Name })
    # commands the code itself tests for first (if (Get-Command X ...)) are optional
    $guarded = @()
    foreach ($g in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -in @('Get-Command', 'gcm') }, $true)) {
        foreach ($el in @($g.CommandElements | Select-Object -Skip 1)) {
            if ($el -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $guarded += $el.Value }
            elseif ($el -is [System.Management.Automation.Language.ArrayLiteralAst]) { $guarded += @($el.Elements | Where-Object { $_ -is [System.Management.Automation.Language.StringConstantExpressionAst] } | ForEach-Object { $_.Value }) }
        }
    }
    $names = New-Object System.Collections.Generic.List[string]
    foreach ($c in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
        $n = $c.GetCommandName()
        if (-not $n) { continue }
        if ($n -match 'zqxfield|[\\/:$]' -or $n -notmatch '^[A-Za-z][\w.-]*$') { continue }
        $n = $n -replace '\.(exe|cmd|bat|com)$', ''
        if ($defined -contains $n) { continue }
        if ($script:ReadyIgnore -contains $n.ToLower()) { continue }
        # a template that does not parse cleanly can make a word look like a command:
        # then only verb-noun names and known tools count
        if (@($errs).Count -and $n -notmatch '-' -and $n -notmatch $script:ReadyToolNames) { continue }
        if ($guarded -contains $n -or $guarded -contains "$n.exe") { continue }
        if (-not ($names -contains $n)) { $names.Add($n) }
    }
    return $names.ToArray()
}

function Get-LibraryEntryNeeds {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Entry, [int]$MethodIndex = 0)
    $methods = @(Get-LibraryEntryMethods -Entry $Entry)
    if ($MethodIndex -ge $methods.Count) { $MethodIndex = 0 }
    $m = $methods[$MethodIndex]
    $text = if ($m.Template) { $m.Template } else { $m.Code }
    $key = "$($Entry.Id)|$MethodIndex|" + $text.GetHashCode() + '|' + ([string]$Entry.WhereToRun).GetHashCode() + "|$($Entry.Elevation)"
    if ($script:NeedsCache.ContainsKey($key)) { return $script:NeedsCache[$key] }

    $cmds = @(Get-LibraryCalledCommands -Text $text -IsTemplate:([bool]$m.Template))

    # rights
    $admin = $false; $adminWhy = ''; $maybe = ''
    switch ([string]$Entry.Elevation) {
        'Required' { $admin = $true; $adminWhy = 'marked as needing admin' }
        'No' { }
        default {
            $hit = @($cmds | Where-Object { $_ -match $script:ReadyAdminCommands }) | Select-Object -First 1
            if ($hit) { $admin = $true; $adminWhy = "$hit needs an elevated session" }
            else {
                $rule = @($script:ReadyAdminText | Where-Object { $text -match $_.P }) | Select-Object -First 1
                if ($rule) { $admin = $true; $adminWhy = "$($rule.W) needs an elevated session" }
            }
            # "Where to run" says so: plainly (required) or only for some uses (maybe)
            $w = [string]$Entry.WhereToRun
            if (-not $admin -and $w -match '(?i)\belevated\b|as administrator') {
                if ($w -match '(?i)elevated (for|to|if|the first time|with)|or elevated|elevated if|not to elevated|\((elevated|or)\b') { $maybe = "Where to run: $($w.Trim())" }
                else { $admin = $true; $adminWhy = 'Where to run says elevated' }
            }
        }
    }

    # software: what to look for, and where it comes from
    $items = foreach ($c in $cmds) {
        $src = ''; $fix = ''
        foreach ($s in $script:ReadySources) { if ($c -match $s.Pattern) { $src = $s.Source; $fix = $s.Fix; break } }
        [pscustomobject]@{ Name = $c; Source = $src; Fix = $fix }
    }

    # connectivity
    $ports = New-Object System.Collections.Generic.List[int]
    $portNames = New-Object System.Collections.Generic.List[string]
    $diag = [bool](@($cmds | Where-Object { $script:ReadyDiagnostics -contains $_ }).Count)
    if (-not $diag) {
        foreach ($c in $cmds) {
            foreach ($p in $script:ReadyPorts) {
                if ($c -match $p.Pattern) {
                    foreach ($n in $p.Ports) { if (-not $ports.Contains($n)) { $ports.Add($n) } }
                    if (-not $portNames.Contains($p.Name)) { $portNames.Add($p.Name) }
                }
            }
        }
        # .NET directory access (fallbacks without RSAT) talks LDAP to the DC
        if ($text -match 'DirectorySearcher|\[adsi\]\s*"LDAP://|DirectoryServices\.ActiveDirectory\.') {
            if (-not $ports.Contains(389)) { $ports.Add(389) }
            if (-not $portNames.Contains('LDAP')) { $portNames.Add('LDAP') }
        }
        foreach ($n in @($Entry.Ports)) { $v = 0; if ([int]::TryParse([string]$n, [ref]$v) -and $v -gt 0 -and -not $ports.Contains($v)) { $ports.Add($v) } }
    }
    $paramNames = @()
    try { $paramNames = @(Get-LibraryEntryParameters -Entry $Entry | ForEach-Object { $_.Name }) } catch { }
    $targets = @($paramNames | Where-Object { $_ -match $script:ReadyTargetParam })

    $r = [pscustomobject]@{
        Method       = $m
        Commands     = $cmds
        Items        = @($items)
        Admin        = $admin
        AdminWhy     = $adminWhy
        AdminMaybe   = $maybe
        Domain       = [bool](@($cmds | Where-Object { $_ -match $script:ReadyDomainCommands }).Count)
        Ports        = $ports.ToArray()
        PortNames    = ($portNames -join ' / ')
        Diagnostic   = $diag
        TargetFields = $targets
    }
    $script:NeedsCache[$key] = $r
    return $r
}

# ------------------------------------------------------------ environment ---

# What this computer has, looked up once. Runs in a background runspace (the
# Get-Command lookup can take a few seconds the first time).
$script:SnapshotScript = @'
param([string[]]$Names)
$found = @{}
if ($Names.Count) {
    foreach ($c in @(Get-Command -Name $Names -ErrorAction SilentlyContinue)) {
        $n = [string]$c.Name
        if ($c.CommandType -eq 'Application') { $n = [System.IO.Path]::GetFileNameWithoutExtension($n) }
        $found[$n.ToLower()] = [string]$c.CommandType
    }
}
$isWin = $true
try { if ($PSVersionTable.PSVersion.Major -ge 6 -and -not $IsWindows) { $isWin = $false } } catch { }
$admin = $false; $joined = $false; $domain = ''
if ($isWin) {
    try { $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) } catch { }
    try { $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop; $joined = [bool]$cs.PartOfDomain; $domain = [string]$cs.Domain } catch { }
}
[pscustomobject]@{
    Found = $found; IsAdmin = $admin; PartOfDomain = $joined; Domain = $domain; IsWindows = $isWin
    PSVersion = $PSVersionTable.PSVersion.ToString(); Computer = [Environment]::MachineName; Taken = Get-Date
}
'@

function Get-LibraryAllCommandNames {
    param([object[]]$Entries)
    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($e in @($Entries)) {
        $mc = @(Get-LibraryEntryMethods -Entry $e).Count
        for ($i = 0; $i -lt $mc; $i++) {
            try { foreach ($c in (Get-LibraryEntryNeeds -Entry $e -MethodIndex $i).Commands) { [void]$set.Add($c) } } catch { }
        }
    }
    return @($set)
}

# The whole scan (parse every entry, look the commands up, judge each entry)
# runs in a background runspace with this module's code and the parsing
# helpers it uses, so the window never waits for it.
$script:ScanScript = @'
param($Entries, [string[]]$Defs)
foreach ($__d in $Defs) { . ([scriptblock]::Create($__d)) }
$snap = Get-LibraryReadinessSnapshotNow -Entries $Entries
$map = @{}
foreach ($e in $Entries) { try { $map[[string]$e.Id] = Get-LibraryEntryReadiness -Entry $e -Snapshot $snap } catch { } }
[pscustomobject]@{ Snapshot = $snap; Map = $map }
'@

function Get-LibraryReadinessDefinitions {
    $defs = New-Object System.Collections.Generic.List[string]
    foreach ($fn in @('Get-LibraryCodeInfo', 'Test-LibraryCommandEntry', 'Get-LibraryEntryNeeds')) {
        $m = $null
        try { $m = (Get-Command $fn -ErrorAction Stop).Module } catch { }
        if ($m -and $m.Definition -and -not $defs.Contains([string]$m.Definition)) { $defs.Add([string]$m.Definition) }
    }
    return $defs.ToArray()
}

function Start-LibraryReadinessScan {
    [CmdletBinding()]
    param([object[]]$Entries = @())
    Stop-LibraryReadinessScan
    $ps = [powershell]::Create()
    [void]$ps.AddScript($script:ScanScript).AddArgument(@($Entries)).AddArgument([string[]](Get-LibraryReadinessDefinitions))
    $script:Scan = @{ PS = $ps; Handle = $ps.BeginInvoke(); Started = Get-Date }
}

function Stop-LibraryReadinessScan {
    if ($script:Scan -and $script:Scan.PS) { try { [void]$script:Scan.PS.BeginStop($null, $null) } catch { } }
    $script:Scan = $null
}

# Once the background scan has finished: Snapshot + Map (entry Id -> readiness).
# $null while it is still running (or when none was started).
function Receive-LibraryReadinessScan {
    [CmdletBinding()]
    param()
    if (-not $script:Scan) { return $null }
    if (-not $script:Scan.Handle.IsCompleted) { return $null }
    $res = $null; $err = ''
    try { $res = @($script:Scan.PS.EndInvoke($script:Scan.Handle)) | Select-Object -Last 1 } catch { $err = $_.Exception.Message }
    if (-not $err -and $script:Scan.PS.Streams.Error.Count) { $err = [string]$script:Scan.PS.Streams.Error[0] }
    try { $script:Scan.PS.Dispose() } catch { }
    $script:Scan = $null
    if (-not $res) {
        $snap = [pscustomobject]@{ Found = @{}; IsAdmin = $false; PartOfDomain = $false; Domain = ''; IsWindows = $true; PSVersion = ''; Computer = ''; Taken = Get-Date; Failed = $true }
        $res = [pscustomobject]@{ Snapshot = $snap; Map = @{}; Error = $err }
    }
    return $res
}

function Get-LibraryReadinessSnapshotNow {
    [CmdletBinding()]
    param([object[]]$Entries = @())
    $names = [string[]](Get-LibraryAllCommandNames -Entries $Entries)
    return (& ([scriptblock]::Create($script:SnapshotScript)) $names)
}

# ------------------------------------------------------------ verdict ---

function Get-LibraryMissingCommands {
    param($Needs, $Snapshot)
    return @($Needs.Items | Where-Object { -not $Snapshot.Found.ContainsKey(([string]$_.Name).ToLower()) })
}

# Level: Ready | Warn | Blocked | Unknown. Summary is the short list-column text.
function Get-LibraryEntryReadiness {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Entry, $Snapshot, [switch]$Remote)
    $lines = New-Object System.Collections.Generic.List[object]
    $add = { param($k, $t, $f) $lines.Add([pscustomobject]@{ Kind = $k; Text = $t; Fix = $f }) }
    if (-not $Snapshot) {
        return [pscustomobject]@{ Level = 'Unknown'; Summary = 'Checking...'; Lines = @(); MethodIndex = 0; MethodLabel = ''; Needs = $null; Fallback = $false }
    }
    $methods = @(Get-LibraryEntryMethods -Entry $Entry)
    $pick = -1; $firstMissing = @(); $allNeeds = @()
    for ($i = 0; $i -lt $methods.Count; $i++) {
        $n = Get-LibraryEntryNeeds -Entry $Entry -MethodIndex $i
        $allNeeds += $n
        $miss = @(Get-LibraryMissingCommands -Needs $n -Snapshot $Snapshot)
        if ($i -eq 0) { $firstMissing = $miss }
        if ($Remote -or $miss.Count -eq 0) { if ($pick -lt 0) { $pick = $i } }
    }
    $level = 'Ready'; $summary = 'Ready'
    $chosen = if ($pick -ge 0) { $allNeeds[$pick] } else { $allNeeds[0] }

    if ($pick -lt 0) {
        $level = 'Blocked'
        $srcs = @($firstMissing | ForEach-Object { if ($_.Source) { $_.Source -replace ' module$', '' } else { $_.Name } } | Select-Object -Unique)
        $summary = 'Missing: ' + ($srcs -join ', ')
        foreach ($x in $firstMissing) {
            & $add 'Software' "Not on this computer: $($x.Name)$(if ($x.Source) { " ($($x.Source))" })" $(if ($x.Fix) { $x.Fix } else { 'Install the program that provides it, or add its folder to PATH.' })
        }
        if ($methods.Count -gt 1) { & $add 'Software' "No fallback method is available here either ($((@($methods | Select-Object -Skip 1 | ForEach-Object { $_.Label })) -join ', '))." '' }
    }
    elseif ($pick -gt 0) {
        $summary = "Ready - via $($methods[$pick].Label)"
        $srcs = @($firstMissing | ForEach-Object { if ($_.Source) { $_.Source } else { $_.Name } } | Select-Object -Unique)
        & $add 'Method' "Uses the fallback '$($methods[$pick].Label)' - $($srcs -join ', ') not installed here." $(@($firstMissing | Where-Object { $_.Fix } | Select-Object -First 1 | ForEach-Object { "For the full version: $($_.Fix)" }))
    }

    if (-not $Remote -and $chosen.Admin -and -not $Snapshot.IsAdmin) {
        & $add 'Rights' "Needs admin: $($chosen.AdminWhy)." 'Close the app and start it with Run as administrator.'
        if ($level -eq 'Ready') { $level = 'Blocked'; $summary = 'Needs admin' }
    }
    if (-not $Remote -and $chosen.Domain -and -not $Snapshot.PartOfDomain -and $Snapshot.IsWindows) {
        & $add 'Domain' 'This computer is not in a domain.' 'Fill in Server / Domain (a DC name), or run it from a domain-joined computer.'
        if ($level -eq 'Ready') { $level = 'Warn'; $summary = 'Not on a domain' }
    }
    if ($chosen.Ports.Count -and $chosen.TargetFields.Count) {
        & $add 'Target' "Checks $($chosen.TargetFields -join ' / ') answers on $($chosen.PortNames) (TCP $($chosen.Ports -join ', ')) before it runs." ''
    }
    [pscustomobject]@{
        Level = $level; Summary = $summary; Lines = $lines.ToArray()
        MethodIndex = $(if ($pick -ge 0) { $pick } else { 0 }); MethodLabel = $methods[$(if ($pick -ge 0) { $pick } else { 0 })].Label
        Needs = $chosen; Fallback = ($pick -gt 0)
    }
}

# Host names typed into the entry's target fields (Values: name -> raw value).
function Get-LibraryTargetHosts {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Entry, [hashtable]$Values = @{})
    $hosts = New-Object System.Collections.Generic.List[string]
    foreach ($k in @($Values.Keys)) {
        if ($k -notmatch $script:ReadyTargetParam) { continue }
        foreach ($v in @($Values[$k])) {
            foreach ($h in ([string]$v -split '[\s,;]+')) {
                $h = $h.Trim().Trim('"', "'")
                if (-not $h -or $h -match '^(localhost|\.|127\.0\.0\.1)$' -or $h -match '[\\/<>{}$*]') { continue }
                if (-not $hosts.Contains($h)) { $hosts.Add($h) }
            }
        }
    }
    return $hosts.ToArray()
}

# What a run hands the runner: the methods in order (primary first) with the
# exact call text for the values typed in, the commands each needs, and the
# ports to check on the hosts typed into target fields.
#   -> Plan (Label, Code, CallText, Commands, Ports), Variables, Hosts, Fallback
function Get-LibraryRunPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Entry, [object[]]$Parameters = @(), [hashtable]$Values = @{}, [Parameter(Mandatory)] $Call, [switch]$WhatIf)
    $methods = @(Get-LibraryEntryMethods -Entry $Entry)
    $vars = @{}
    foreach ($k in @($Call.Variables.Keys)) { $vars[$k] = $Call.Variables[$k] }
    $plan = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $methods.Count; $i++) {
        $m = $methods[$i]
        $n = Get-LibraryEntryNeeds -Entry $Entry -MethodIndex $i
        if ($i -eq 0) { $text = [string]$Call.Text; $code = [string](Get-LibraryEntryRunCode -Entry $Entry) }
        else {
            # a WhatIf preview never falls through to a method that cannot preview
            if ($WhatIf) { continue }
            $c = ConvertTo-LibraryTemplateText -Template $m.Template -Parameters $Parameters -Values $Values
            if (@($c.Errors).Count) { continue }
            $text = [string]$c.Text; $code = ''
            foreach ($k in @($c.Variables.Keys)) { $vars[$k] = $c.Variables[$k] }
        }
        $plan.Add([pscustomobject]@{
            Label = $m.Label; Code = $code; CallText = $text; Commands = @($n.Commands)
            Ports = $(if ($n.TargetFields.Count) { @($n.Ports) } else { @() })
        })
    }
    [pscustomobject]@{
        Plan = $plan.ToArray(); Variables = $vars
        Hosts = @(Get-LibraryTargetHosts -Entry $Entry -Values $Values)
        Fallback = (-not $Entry.Modifies)
    }
}

# ------------------------------------------------------------ host checks ---

# Shared by the Run dialog's Check button (here) and the run preamble (in the
# run's runspace), so it is kept as text and defined in both places.
$script:HostCheckFunction = @'
function Test-LibraryHostPorts {
    param([string[]]$Hosts = @(), [int[]]$Ports = @(), [int]$TimeoutMs = 1500)
    $out = @()
    $jobs = @()
    foreach ($h in $Hosts) {
        $dns = $null
        try { $dns = [System.Net.Dns]::BeginGetHostAddresses($h, $null, $null) } catch { }
        $jobs += [pscustomobject]@{ Host = $h; Dns = $dns; Addr = $null; Conns = @() }
    }
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs + 1000)
    foreach ($j in $jobs) {
        if (-not $j.Dns) { continue }
        $left = [int][Math]::Max(1, ($deadline - (Get-Date)).TotalMilliseconds)
        if ($j.Dns.AsyncWaitHandle.WaitOne($left)) {
            try { $j.Addr = @([System.Net.Dns]::EndGetHostAddresses($j.Dns) | Where-Object { $_.AddressFamily -eq 'InterNetwork' }) + @([System.Net.Dns]::EndGetHostAddresses($j.Dns) | Where-Object { $_.AddressFamily -ne 'InterNetwork' }) } catch { $j.Addr = @() }
        }
    }
    foreach ($j in $jobs) {
        if (-not $j.Addr -or @($j.Addr).Count -eq 0) { continue }
        foreach ($p in $Ports) {
            $c = New-Object System.Net.Sockets.TcpClient
            $ar = $null
            try { $ar = $c.BeginConnect(@($j.Addr)[0], $p, $null, $null) } catch { }
            $j.Conns += [pscustomobject]@{ Port = $p; Client = $c; Ar = $ar }
        }
    }
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    foreach ($j in $jobs) {
        $open = @(); $closed = @()
        foreach ($cn in $j.Conns) {
            $ok = $false
            if ($cn.Ar) {
                $left = [int][Math]::Max(1, ($deadline - (Get-Date)).TotalMilliseconds)
                if ($cn.Ar.AsyncWaitHandle.WaitOne($left)) { try { $cn.Client.EndConnect($cn.Ar); $ok = $true } catch { } }
            }
            try { $cn.Client.Close() } catch { }
            if ($ok) { $open += $cn.Port } else { $closed += $cn.Port }
        }
        $resolved = [bool]($j.Addr -and @($j.Addr).Count)
        $status = if (-not $resolved) { 'NoDns' } elseif ($Ports.Count -eq 0 -or $open.Count) { 'OK' } else { 'Closed' }
        $out += [pscustomobject]@{
            Host = $j.Host; Address = $(if ($resolved) { [string]@($j.Addr)[0] } else { '' }); Status = $status
            Open = $open; Closed = $closed
            Text = switch ($status) {
                'NoDns'  { "$($j.Host): name not found in DNS" }
                'Closed' { "$($j.Host) ($(@($j.Addr)[0])): no answer on TCP $($closed -join ', ') - firewall, service stopped, or host down" }
                default  { "$($j.Host) ($(@($j.Addr)[0])): OK$(if ($open.Count) { " - TCP $($open -join ', ') open" })" }
            }
        }
    }
    return $out
}
'@
. ([scriptblock]::Create($script:HostCheckFunction))

# ------------------------------------------------------------ failures ---

# Plain-words reason for an error message: Rights | Connectivity | Software | Auth | Input | Policy | ''.
function Get-LibraryFailureReason {
    [CmdletBinding()]
    param([AllowEmptyString()] [string]$Text)
    $t = [string]$Text
    $rules = @(
        @{ K = 'Software'; P = 'not installed here|is not recognized as (the )?name of a cmdlet|CommandNotFoundException|module .* could not be loaded|was not loaded because no valid module file|The term .* is not recognized'; H = 'Something this command calls is not installed here - see the entry''s Status for what to install.' }
        @{ K = 'Connectivity'; P = 'Unable to find a default server with Active Directory Web Services|Unable to contact the server|ADServerDownException'; H = 'AD Web Services (TCP 9389) on the DC did not answer. Try another DC in Server, or check the firewall / ADWS service.' }
        @{ K = 'Connectivity'; P = 'WinRM cannot complete|WinRM client cannot|cannot connect to the destination|The client cannot connect|PSRemotingTransportException|WS-Management service'; H = 'WinRM (TCP 5985) did not answer. On the target: Enable-PSRemoting, and allow WinRM through the firewall.' }
        @{ K = 'Connectivity'; P = 'RPC server is unavailable|0x800706BA|0x800706BE|RPC server was unavailable'; H = 'RPC (TCP 135 + dynamic ports) is blocked or the computer is off. Try the WinRM/CIM version, or open the firewall rule.' }
        @{ K = 'Connectivity'; P = 'not found in DNS|no answer on TCP|answered on WinRM|network path was not found|0x80070035|No such host is known|could not be resolved|name could not be resolved|host is unknown|DNS name does not exist'; H = 'The name did not resolve or the share is unreachable. Check the spelling and DNS (Resolve-DnsName).' }
        @{ K = 'Connectivity'; P = 'timed out|timeout|A connection attempt failed|actively refused|No connection could be made|network is unreachable|host is down|Destination host unreachable'; H = 'The target did not answer in time. Check it is on, and that the port is open (Test-NetConnection -Port).' }
        @{ K = 'Auth'; P = 'logon failure|user name or password is incorrect|0x8007052E|The server has rejected the client credentials|Kerberos|trust relationship|SEC_E_|Authentication failed|The security database on the server'; H = 'The credentials were refused (or Kerberos failed). Check the account, use DOMAIN\user, or use the FQDN instead of an IP.' }
        @{ K = 'Rights'; P = 'Access is denied|access denied|UnauthorizedAccess|0x80070005|requires elevation|Requested registry access is not allowed|administrator|PermissionDenied|Insufficient access rights|not have permission|privilege'; H = 'Your account is not allowed to do this. Run the app as administrator (local) or use an account with rights on the target.' }
        @{ K = 'Policy'; P = 'running scripts is disabled|execution polic|is not digitally signed'; H = 'Execution policy blocked it. See the Execution policy entry.' }
        @{ K = 'Input'; P = 'Cannot find an object with identity|ObjectNotFound|Cannot find path|does not exist|not found|Cannot bind parameter|Cannot validate argument|is not valid|invalid'; H = 'A value you entered did not match anything. Check the name / path / format in the fields.' }
    )
    foreach ($r in $rules) {
        if ($t -match $r.P) { return [pscustomobject]@{ Kind = $r.K; Hint = $r.H } }
    }
    return [pscustomobject]@{ Kind = ''; Hint = '' }
}

# Code the runner puts in front of a planned run (host checks + method picking).
function Get-LibraryRunPreamble {
    return $script:HostCheckFunction + @'

function Test-LibraryEnvFailure {
    param($Err)
    $m = [string]$Err
    try { $m = $m + ' ' + [string]$Err.FullyQualifiedErrorId + ' ' + $Err.Exception.GetType().Name } catch { }
    return ($m -match 'Failed to compare two elements|not recognized as (the )?name of a cmdlet|CommandNotFound|could not be loaded|Active Directory Web Services|Unable to contact the server|ServerDown|RPC server|0x800706BA|WinRM|cannot connect|network path|No such host|timed out|A connection attempt failed|actively refused|Access is denied|0x80070005|UnauthorizedAccess|requires elevation')
}
'@
}
