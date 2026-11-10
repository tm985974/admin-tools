# Services_Extractor.psm1   (ADMIN TIER)
#
# Turns the functions inside another project's modules into standalone library
# entries. Nothing is ever launched: the source files are only READ and PARSED.
#
#   Read-ExtractorSource -Path <zip | folder | .psm1/.ps1 file>
#       -> Project, Version, Template, Files (RelPath, Text, IsTemplate)
#   Get-ExtractorCandidates -Source $src
#       -> one candidate per top-level function:
#          Function, File, Status (Ready | Review | Blocked), Blockers, Warnings,
#          Helpers (bundled, dependency order), Modules, Tools, SuggestModifies,
#          Code (the function + its helpers, ready to run alone), Hash
#   Get-ExtractorCandidatesFromCode -Code $text -Label 'Pasted'
#       -> the same analysis for pasted code (Entry editor)
#
# Status rules
#   Blocked : needs the app host ($App), builds/uses WinForms controls, reads
#             $script:/$global: state it never sets, launches a .ps1 / another
#             PowerShell, has a parse error, or a bundled helper is Blocked.
#   Review  : waits for input (Read-Host, Out-GridView ...), uses variables it
#             never defines, calls 'exit', or calls commands that are not found.
#   Ready   : everything else.

Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue
Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue

# ---------------------------------------------------------------- reading ---

function Read-ExtractorSource {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string[]]$Path)

    $files = New-Object System.Collections.Generic.List[object]
    $meta = @{ Project = ''; IdentityName = ''; Version = ''; Template = ''; TemplateFiles = @(); Label = '' }

    foreach ($one in $Path) {
        if (-not (Test-Path -LiteralPath $one)) { throw "Not found: $one" }
        $item = Get-Item -LiteralPath $one
        if ($item.PSIsContainer) {
            if (-not $meta.Label) { $meta.Label = $item.Name }
            $root = $item.FullName.TrimEnd('\', '/')
            foreach ($f in @(Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction SilentlyContinue)) {
                $rel = $f.FullName.Substring($root.Length).TrimStart('\', '/') -replace '\\', '/'
                Add-ExtractorFile -Files $files -Meta $meta -RelPath $rel -Reader { [System.IO.File]::ReadAllText($f.FullName) }
            }
        }
        elseif ($item.Extension -ieq '.zip') {
            if (-not $meta.Label) { $meta.Label = [System.IO.Path]::GetFileNameWithoutExtension($item.Name) }
            $zip = [System.IO.Compression.ZipFile]::OpenRead($item.FullName)
            try {
                $entries = @($zip.Entries | Where-Object { $_.Name })
                # a zip whose entries all sit under one folder is read from inside it
                $prefix = ''
                $tops = @($entries | ForEach-Object { ($_.FullName -replace '\\', '/').Split('/')[0] } | Sort-Object -Unique)
                if ($tops.Count -eq 1 -and @($entries | Where-Object { ($_.FullName -replace '\\', '/') -notlike '*/*' }).Count -eq 0) { $prefix = $tops[0] + '/' }
                foreach ($e in $entries) {
                    $rel = $e.FullName -replace '\\', '/'
                    if ($prefix -and $rel.StartsWith($prefix)) { $rel = $rel.Substring($prefix.Length) }
                    $entry = $e
                    Add-ExtractorFile -Files $files -Meta $meta -RelPath $rel -Reader {
                        $sr = New-Object System.IO.StreamReader($entry.Open(), [System.Text.Encoding]::UTF8, $true)
                        try { $sr.ReadToEnd() } finally { $sr.Dispose() }
                    }
                }
            }
            finally { $zip.Dispose() }
        }
        else {
            if (-not $meta.Label) { $meta.Label = $item.BaseName }
            $full = $item.FullName
            Add-ExtractorFile -Files $files -Meta $meta -RelPath $item.Name -Reader { [System.IO.File]::ReadAllText($full) } -Force
        }
    }

    # template-owned engine files (from TEMPLATE_FILES.txt) + the template's
    # project-shell modules are marked so the Import tab can hide them
    $tplSet = @{}
    foreach ($t in $meta.TemplateFiles) { $tplSet[$t.ToLower()] = $true }
    foreach ($f in $files) {
        $n = [System.IO.Path]::GetFileName($f.RelPath)
        $f.IsTemplate = $tplSet.ContainsKey($f.RelPath.ToLower()) -or ($n -in @('UI_Register-Tabs.psm1', 'UI_Tab_Overview.psm1'))
    }

    $project = $meta.IdentityName
    if (-not $project) { $project = $meta.Project }
    if (-not $project) { $project = $meta.Label }
    [pscustomobject]@{
        Project  = $project
        Version  = $meta.Version
        Template = $meta.Template
        Files    = $files.ToArray()
    }
}

function Add-ExtractorFile {
    param($Files, $Meta, [string]$RelPath, [scriptblock]$Reader, [switch]$Force)
    $low = $RelPath.ToLower()
    $name = [System.IO.Path]::GetFileName($low)

    # project identity / version files
    if ($name -eq 'version.txt' -and $low -notlike '*/*') { try { $Meta.Version = ([string](& $Reader)).Trim() } catch { }; return }
    if ($name -eq 'template_version.txt' -and $low -notlike '*/*') { try { $Meta.Template = ([string](& $Reader)).Trim() } catch { }; return }
    if ($name -eq 'template_files.txt' -and $low -notlike '*/*') {
        try {
            $Meta.TemplateFiles = @(([string](& $Reader)) -split "`r?`n" | Where-Object { $_ -and $_ -notmatch '^\s*#' } |
                ForEach-Object { ($_ -split '\s+', 2)[1] } | Where-Object { $_ } | ForEach-Object { $_.Trim() -replace '\\', '/' })
        } catch { }
        return
    }
    # project name: AppIdentity.json (AppTemplate 1.0.17+); older projects keep it
    # in the PROJECT IDENTITY block of AppHost.cs
    if ($name -eq 'appidentity.json' -and $low -notlike '*/*') {
        try { $id = ([string](& $Reader)) | ConvertFrom-Json; if ($id.AppName) { $Meta.IdentityName = [string]$id.AppName } } catch { }
        return
    }
    if ($name -eq 'apphost.cs' -and $low -notlike '*/*') {
        try { $cs = [string](& $Reader); if ($cs -match 'const string AppName\s*=\s*"([^"]+)"') { $Meta.Project = $Matches[1] } } catch { }
        return
    }

    if (-not $Force) {
        if ($low -notmatch '\.(psm1|ps1)$') { return }
        if ($low -match '(^|/)(archive|backup|\.git)/') { return }
        if ($name -in @('_applauncher.ps1', 'build-app.ps1')) { return }
    }
    $text = ''
    try { $text = [string](& $Reader) } catch { return }
    $Files.Add([pscustomobject]@{ RelPath = $RelPath; Text = $text; IsTemplate = $false })
}

# ---------------------------------------------------------------- analysis ---

$script:AutomaticVariables = @(
    '_', 'PSItem', 'args', 'input', 'this', 'true', 'false', 'null', 'Matches', 'Error', 'LASTEXITCODE',
    'PSBoundParameters', 'PSCmdlet', 'MyInvocation', 'ExecutionContext', 'Host', 'HOME', 'PID', 'PWD',
    'PSScriptRoot', 'PSCommandPath', 'PSVersionTable', 'PSHOME', 'ShellId', 'StackTrace', 'Event',
    'EventArgs', 'EventSubscriber', 'Sender', 'SourceArgs', 'SourceEventArgs', 'ForEach', 'Switch',
    'ErrorActionPreference', 'WarningPreference', 'VerbosePreference', 'DebugPreference',
    'InformationPreference', 'ProgressPreference', 'ConfirmPreference', 'WhatIfPreference',
    'OFS', 'PSDefaultParameterValues', 'PSEmailServer', 'PSSessionOption', 'MaximumHistoryCount',
    'NestedPromptLevel', 'PSCulture', 'PSUICulture', 'IsWindows', 'IsLinux', 'IsMacOS', 'IsCoreCLR',
    'PSItem', 'ConsoleFileName', 'FormatEnumerationLimit', 'OutputEncoding', 'PSModuleAutoLoadingPreference'
)

$script:InteractiveCommands = @('Read-Host', 'Out-GridView', 'Pause', 'Show-Command', 'Get-Credential')

# Cmdlets with a modifying verb that only touch the session, not the system.
$script:SessionOnlyCommands = @(
    'New-Object', 'Add-Member', 'Set-Variable', 'New-Variable', 'Remove-Variable', 'Clear-Variable', 'Add-Type',
    'Set-StrictMode', 'Start-Sleep', 'New-TimeSpan', 'Set-Alias', 'New-Alias', 'Start-Job', 'Stop-Job', 'Remove-Job',
    'New-PSSession', 'Remove-PSSession', 'New-CimSession', 'Remove-CimSession', 'New-PSSessionOption',
    'New-CimSessionOption', 'New-ScheduledTaskAction', 'New-ScheduledTaskTrigger', 'New-ScheduledTaskSettingsSet',
    'New-ScheduledTaskPrincipal', 'New-Guid', 'New-Module', 'Set-Location', 'Push-Location', 'Pop-Location',
    'Clear-Host', 'Register-ObjectEvent', 'Unregister-Event', 'Remove-Event', 'New-Event', 'Set-PSDebug',
    'Start-Transcript', 'Stop-Transcript', 'Set-PSBreakpoint', 'Remove-Module', 'Add-History', 'Clear-History',
    'Set-Date'
)
$script:ModifyingVerbs = @('Set', 'New', 'Remove', 'Add', 'Clear', 'Disable', 'Enable', 'Install', 'Uninstall',
    'Restart', 'Stop', 'Start', 'Reset', 'Unlock', 'Lock', 'Move', 'Rename', 'Register', 'Unregister', 'Grant',
    'Revoke', 'Deny', 'Suspend', 'Resume', 'Update', 'Initialize', 'Mount', 'Dismount', 'Publish',
    'Unpublish', 'Import', 'Copy', 'Write', 'Out', 'Send', 'Repair', 'Rebuild', 'Protect', 'Unprotect', 'Block', 'Unblock')
# (Format-* is output formatting, not Format-Volume, so it is not listed)
$script:ModifyingNoModify = @('Write-Host', 'Write-Output', 'Write-Verbose', 'Write-Warning', 'Write-Error', 'Write-Debug',
    'Write-Information', 'Write-Progress', 'Out-String', 'Out-Null', 'Out-Default', 'Out-Host', 'Import-Module',
    'Import-Csv', 'Import-Clixml', 'Import-PowerShellDataFile', 'Import-LocalizedData', 'Copy-ItemProperty')
$script:ModifyingTools = @('msiexec', 'icacls', 'takeown', 'reg', 'sc', 'net', 'netdom', 'shutdown', 'gpupdate',
    'bcdedit', 'diskpart', 'format', 'cipher', 'wevtutil', 'auditpol', 'dism', 'subst', 'setx', 'schtasks', 'klist')

# Commands -> module, for when the importing machine does not have the module
# (Get-Command is tried first).
$script:ModuleHints = @(
    @{ Pattern = '^(Get|Set|New|Remove|Add|Enable|Disable|Unlock|Search|Move|Rename|Clear|Reset|Install|Uninstall|Test)-AD'; Module = 'ActiveDirectory' }
    @{ Pattern = '^(Get|Set|New|Remove|Backup|Restore|Import|Copy|Rename|Invoke)-GP|^Get-GPResultantSetOfPolicy$'; Module = 'GroupPolicy' }
    @{ Pattern = '^(Get|Install|Uninstall|Add|Remove)-WindowsFeature$'; Module = 'ServerManager' }
    @{ Pattern = '^Resolve-DnsName$|^(Get|Set|Clear)-DnsClient'; Module = 'DnsClient' }
    @{ Pattern = '^(Get|Add|Set|Remove)-DnsServer'; Module = 'DnsServer' }
    @{ Pattern = '^(Get|Add|Set|Remove)-Dhcp'; Module = 'DhcpServer' }
    @{ Pattern = '^Test-NetConnection$|^(Get|Set|New|Remove)-Net(IPAddress|Route|IPInterface|TCPConnection)'; Module = 'NetTCPIP' }
    @{ Pattern = '^(Get|Set|Enable|Disable|Rename|Restart)-NetAdapter'; Module = 'NetAdapter' }
    @{ Pattern = '-ScheduledTask'; Module = 'ScheduledTasks' }
    @{ Pattern = '-NetFirewall'; Module = 'NetSecurity' }
    @{ Pattern = '^(Get|Set|Reset|Invoke|Update)-Laps'; Module = 'LAPS' }
    @{ Pattern = '-AdmPwd'; Module = 'AdmPwd.PS' }
    @{ Pattern = '-SmbShare|-SmbSession|-SmbMapping'; Module = 'SmbShare' }
    @{ Pattern = '-LocalUser$|-LocalGroup|-LocalGroupMember$'; Module = 'Microsoft.PowerShell.LocalAccounts' }
    @{ Pattern = '-WindowsCapability$|-WindowsOptionalFeature$'; Module = 'Dism' }
    @{ Pattern = '-AppxPackage$'; Module = 'Appx' }
    @{ Pattern = '-Printer$|-PrinterDriver$|-PrinterPort$'; Module = 'PrintManagement' }
    @{ Pattern = '-BitLocker'; Module = 'BitLocker' }
    @{ Pattern = '^(Get|Set|Initialize|Clear)-(Disk|Volume|Partition)$'; Module = 'Storage' }
    @{ Pattern = '^Get-KdsRootKey$|^Add-KdsRootKey$'; Module = 'Kds' }
)
$script:CoreModules = @('Microsoft.PowerShell.Core', 'Microsoft.PowerShell.Management', 'Microsoft.PowerShell.Utility',
    'Microsoft.PowerShell.Security', 'Microsoft.PowerShell.Diagnostics', 'Microsoft.WSMan.Management', 'CimCmdlets',
    'Microsoft.PowerShell.Host', 'PSReadLine')
# Windows built-in cmdlets (core modules) - known even when the importing
# machine lacks them, so they are never reported as "not found".
$script:KnownCoreCommands = @('Get-CimInstance', 'Invoke-CimMethod', 'Get-CimClass', 'Set-CimInstance', 'Get-WinEvent',
    'Get-EventLog', 'Get-WmiObject', 'Invoke-WmiMethod', 'Get-Service', 'Set-Service', 'Start-Service', 'Stop-Service',
    'Restart-Service', 'Get-Process', 'Stop-Process', 'Test-Connection', 'Get-Counter', 'Get-HotFix', 'Get-ComputerInfo',
    'Restart-Computer', 'Stop-Computer', 'Rename-Computer', 'Add-Computer', 'Remove-Computer', 'Test-ComputerSecureChannel',
    'Get-ExecutionPolicy', 'Set-ExecutionPolicy', 'Get-Acl', 'Set-Acl', 'Get-AuthenticodeSignature', 'Get-PfxCertificate',
    'Test-WSMan', 'Get-Item', 'Get-ItemProperty', 'Get-ChildItem', 'Get-Content', 'Clear-RecycleBin', 'Get-Clipboard',
    'Set-Clipboard', 'Get-TimeZone', 'Set-TimeZone', 'Write-EventLog', 'New-EventLog', 'Limit-EventLog', 'Clear-EventLog',
    'Show-EventLog', 'Get-PSDrive', 'New-PSDrive', 'Remove-PSDrive', 'Enter-PSSession', 'Invoke-Command', 'New-PSSession',
    'Receive-Job', 'Wait-Job', 'Get-Job', 'ConvertFrom-SecureString', 'ConvertTo-SecureString', 'Get-Credential')

$script:KnownTools = @('nltest', 'netdom', 'dcdiag', 'repadmin', 'w32tm', 'gpresult', 'gpupdate', 'secedit', 'nslookup',
    'ipconfig', 'ping', 'tracert', 'netstat', 'whoami', 'klist', 'setspn', 'dsquery', 'dsget', 'ntdsutil', 'certutil',
    'icacls', 'takeown', 'net', 'sc', 'reg', 'msiexec', 'wmic', 'cmd', 'robocopy', 'xcopy', 'schtasks', 'wevtutil',
    'auditpol', 'dism', 'sfc', 'chkdsk', 'shutdown', 'bcdedit', 'manage-bde', 'subst', 'setx', 'hostname', 'systeminfo',
    'quser', 'qwinsta', 'arp', 'route', 'pathping', 'netsh', 'lmstat', 'lmutil', 'tasklist', 'taskkill', 'driverquery')

function Get-ExtractorModuleFor {
    param([string]$Command)
    try {
        $c = Get-Command -Name $Command -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($c) {
            if ($c.CommandType -eq 'Application') { return @{ Kind = 'Tool'; Name = [System.IO.Path]::GetFileNameWithoutExtension($c.Name) } }
            if ($c.CommandType -eq 'Alias' -and $c.ResolvedCommand) { $c = $c.ResolvedCommand }
            $src = [string]$c.Source
            if (-not $src) { $src = [string]$c.ModuleName }
            if ($src -and -not ($script:CoreModules -contains $src)) { return @{ Kind = 'Module'; Name = $src } }
            if ($c.CommandType -in @('Cmdlet', 'Function', 'Alias', 'Filter')) { return @{ Kind = 'Core'; Name = $src } }
        }
    } catch { }
    if ($script:KnownCoreCommands -contains $Command) { return @{ Kind = 'Core'; Name = '' } }
    foreach ($h in $script:ModuleHints) { if ($Command -match $h.Pattern) { return @{ Kind = 'Module'; Name = $h.Module } } }
    $bare = [System.IO.Path]::GetFileNameWithoutExtension($Command).ToLower()
    if ($Command -match '\.exe$' -or $script:KnownTools -contains $bare) { return @{ Kind = 'Tool'; Name = $bare } }
    if ($Command -notmatch '-') { return @{ Kind = 'Tool'; Name = $bare } }
    return @{ Kind = 'Unknown'; Name = $Command }
}

# What one function body does, on its own (helpers are combined later).
function Get-ExtractorFunctionFacts {
    param([System.Management.Automation.Language.FunctionDefinitionAst]$Fn)

    $L = [System.Management.Automation.Language.Ast]
    $facts = @{
        Calls = New-Object System.Collections.Generic.List[string]
        Blockers = New-Object System.Collections.Generic.List[string]
        Warnings = New-Object System.Collections.Generic.List[string]
        ScriptRead = @{}; ScriptSet = @{}
        FreeVars = New-Object System.Collections.Generic.List[string]
        Modifies = New-Object System.Collections.Generic.List[string]
        Optional = @{}
    }

    # names of functions defined INSIDE this one (not dependencies)
    $nested = @{}
    foreach ($n in $Fn.Body.FindAll({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) { $nested[$n.Name.ToLower()] = $true }

    # ---- commands
    foreach ($cmd in $Fn.Body.FindAll({ param($x) $x -is [System.Management.Automation.Language.CommandAst] }, $true)) {
        $name = $cmd.GetCommandName()
        $first = $cmd.CommandElements[0]

        # . $path / & "x.ps1" / & $scriptPath  -> launches a script file
        if (-not $name) {
            if ($first -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) { continue }
            if ($cmd.InvocationOperator -eq 'Dot' -and -not ($first -is [System.Management.Automation.Language.ScriptBlockExpressionAst])) {
                $facts.Blockers.Add("Dot-sources a file ($($cmd.Extent.Text.Split("`n")[0].Trim()))")
            }
            elseif ($first.Extent.Text -match '\.ps1[''"]?\s*$') {
                $facts.Blockers.Add("Launches a script file ($($first.Extent.Text))")
            }
            continue
        }
        if ($name -match '\.ps1$') { $facts.Blockers.Add("Launches a script file ($name)"); continue }
        if ($nested.ContainsKey($name.ToLower())) { continue }
        if (-not ($facts.Calls -contains $name)) { $facts.Calls.Add($name) }

        $argText = (@($cmd.CommandElements | Select-Object -Skip 1) | ForEach-Object { $_.Extent.Text }) -join ' '
        if ($name -in @('Get-Command', 'gcm')) {
            # "if (Get-Command X -ErrorAction SilentlyContinue)" - X is optional, not required
            foreach ($el in @($cmd.CommandElements | Select-Object -Skip 1)) {
                if ($el -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $facts.Optional[$el.Value.ToLower()] = $true }
            }
        }
        if ($name -in @('Start-Process', 'saps', 'start') -and $argText -match '(powershell|pwsh)(\.exe)?|\.ps1') {
            $facts.Blockers.Add('Starts another PowerShell / .ps1 (Start-Process)')
        }
        if ($name -in @('powershell', 'powershell.exe', 'pwsh', 'pwsh.exe')) { $facts.Blockers.Add("Starts another PowerShell ($name)") }
        if ($name -in @('Invoke-Command', 'icm') -and $argText -match '-FilePath') { $facts.Blockers.Add('Runs a script file remotely (Invoke-Command -FilePath)') }
        if ($name -ieq 'Import-Module' -and $argText -match '\.psm1|\.ps1') { $facts.Blockers.Add("Imports a project module file ($argText)") }
        if ($name -ieq 'Add-Type' -and $argText -match 'Windows\.Forms|System\.Drawing|PresentationFramework') { $facts.Blockers.Add('Loads UI assemblies (WinForms/WPF)') }
        if ($name -ieq 'New-Object' -and $argText -match 'Windows\.Forms|System\.Drawing\.(?!Color)|System\.Windows\.') { $facts.Blockers.Add('Creates UI controls (WinForms/WPF)') }

        if ($script:InteractiveCommands -contains $name) {
            $facts.Warnings.Add("Waits for input or a window ($name)")
        }

        # modifies the system?
        $verb = ($name -split '-', 2)[0]
        if ($name -match '-' -and ($script:ModifyingVerbs -contains $verb) -and -not ($script:SessionOnlyCommands -contains $name) -and -not ($script:ModifyingNoModify -contains $name)) {
            if ($name -notmatch '^(Write|Out)-' -or $name -in @('Out-File')) { $facts.Modifies.Add($name) }
        }
        $bare = [System.IO.Path]::GetFileNameWithoutExtension($name).ToLower()
        if ($script:ModifyingTools -contains $bare) {
            $readOnly = ($bare -eq 'net' -and $argText -match '^\s*(localgroup\s+\S+\s*$|user\s+\S+(\s+/domain)?\s*$|view|share\s*$|use\s*$|time)') -or
                        ($bare -eq 'sc' -and $argText -match '^\s*(query|qc|queryex|qdescription)') -or
                        ($bare -eq 'reg' -and $argText -match '^\s*(query|export|compare)') -or
                        ($bare -eq 'klist' -and $argText -notmatch 'purge') -or
                        ($bare -eq 'schtasks' -and $argText -match '/query') -or
                        ($bare -eq 'auditpol' -and $argText -match '/get') -or
                        ($bare -eq 'dism' -and $argText -match '/get-')
            if (-not $readOnly) { $facts.Modifies.Add($bare) }
        }
    }
    foreach ($m in $Fn.Body.FindAll({ param($x) $x -is [System.Management.Automation.Language.InvokeMemberExpressionAst] }, $true)) {
        $mn = [string]$m.Member.Extent.Text
        if ($mn -match '^(ShowDialog|Add_Click|Add_SelectedIndexChanged|Add_TextChanged|Add_Tick|Add_AfterSelect)$') { $facts.Blockers.Add("Uses UI controls (.$mn)") }
        if ($m.Expression.Extent.Text -match '^\[Console\]$' -and $mn -match '^Read') { $facts.Warnings.Add("Waits for keyboard input ([Console]::$mn)") }
    }

    # ---- types
    foreach ($t in $Fn.FindAll({ param($x) ($x -is [System.Management.Automation.Language.TypeExpressionAst]) -or ($x -is [System.Management.Automation.Language.TypeConstraintAst]) }, $true)) {
        $tn = $t.TypeName.FullName
        if (($tn -match 'Windows\.Forms|^System\.Windows\.|^Windows\.') -or ($tn -match '^System\.Drawing\.(Font|Point|Size|Bitmap|Image|Graphics|Rectangle)$')) {
            $facts.Blockers.Add("Uses UI types ([$tn])")
        }
        elseif ($tn -match '^(TabPage|TabControl|Form|Control|TreeView|TreeNode|ListView|ListViewItem|TextBox|Button|Label|Panel|DataGridView|ComboBox)$') {
            $facts.Blockers.Add("Uses UI types ([$tn])")
        }
    }

    # ---- variables
    $declared = @{}
    foreach ($p in (Get-LibraryParamAsts $Fn)) { $declared[$p.Name.VariablePath.UserPath.ToLower()] = $true }
    foreach ($pb in $Fn.Body.FindAll({ param($x) $x -is [System.Management.Automation.Language.ParamBlockAst] }, $true)) {
        foreach ($p in $pb.Parameters) { $declared[$p.Name.VariablePath.UserPath.ToLower()] = $true }
    }
    foreach ($nf in $Fn.Body.FindAll({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
        foreach ($p in @($nf.Parameters)) { if ($p) { $declared[$p.Name.VariablePath.UserPath.ToLower()] = $true } }
    }
    foreach ($a in $Fn.Body.FindAll({ param($x) $x -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)) {
        foreach ($v in $a.Left.FindAll({ param($x) $x -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)) {
            $vp = $v.VariablePath
            if ($vp.IsScript -or $vp.IsGlobal) { $facts.ScriptSet[$vp.UserPath.ToLower() -replace '^(script|global):', ''] = $true }
            else { $declared[$vp.UserPath.ToLower()] = $true }
        }
    }
    foreach ($f in $Fn.Body.FindAll({ param($x) $x -is [System.Management.Automation.Language.ForEachStatementAst] }, $true)) { $declared[$f.Variable.VariablePath.UserPath.ToLower()] = $true }
    # [ref]$x, -OutVariable x, -ErrorVariable x, -Variable x, Set-Variable -Name x
    foreach ($cmd in $Fn.Body.FindAll({ param($x) $x -is [System.Management.Automation.Language.CommandAst] }, $true)) {
        $els = @($cmd.CommandElements)
        for ($i = 0; $i -lt $els.Count - 1; $i++) {
            if ($els[$i] -is [System.Management.Automation.Language.CommandParameterAst] -and $els[$i].ParameterName -match '^(OutVariable|ov|ErrorVariable|ev|WarningVariable|wv|InformationVariable|iv|PipelineVariable|pv|Variable|Name)$') {
                $nm = $els[$i + 1].Extent.Text.Trim([char[]]"'`"+$")
                if ($nm) { $declared[$nm.ToLower()] = $true }
            }
        }
        $cn = $cmd.GetCommandName()
        if ($cn -in @('Set-Variable', 'New-Variable', 'sv') -and $els.Count -ge 2 -and $els[1] -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $declared[$els[1].Value.ToLower()] = $true }
    }
    foreach ($c in $Fn.Body.FindAll({ param($x) $x -is [System.Management.Automation.Language.ConvertExpressionAst] -and $x.Type.TypeName.Name -ieq 'ref' }, $true)) {
        foreach ($v in $c.FindAll({ param($x) $x -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)) { $declared[$v.VariablePath.UserPath.ToLower()] = $true }
    }

    $seenFree = @{}
    foreach ($v in $Fn.Body.FindAll({ param($x) $x -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)) {
        $vp = $v.VariablePath
        $raw = $vp.UserPath
        if ($vp.IsScript -or $vp.IsGlobal) {
            $k = ($raw -replace '^(script|global):', '').ToLower()
            $facts.ScriptRead[$k] = $raw
            continue
        }
        if ($vp.DriveName -and $vp.DriveName -notin @('local', 'private')) { continue }   # $env:, $using:, $function: ...
        $k = ($raw -replace '^(local|private):', '').ToLower()
        if ($k -eq 'app') { if (-not $facts.Blockers.Contains('Needs the app host ($App)')) { $facts.Blockers.Add('Needs the app host ($App)') }; continue }
        if ($declared.ContainsKey($k)) { continue }
        if ($script:AutomaticVariables -contains $k) { continue }
        if ($v.Splatted -and $declared.ContainsKey($k)) { continue }
        if (-not $seenFree.ContainsKey($k)) { $seenFree[$k] = $true; $facts.FreeVars.Add('$' + $raw) }
    }

    foreach ($e in $Fn.Body.FindAll({ param($x) $x -is [System.Management.Automation.Language.ExitStatementAst] }, $true)) {
        $facts.Warnings.Add("Calls 'exit' (ends the run)"); break
    }
    return $facts
}

# Builds the candidate list for a set of parsed files.
function Get-ExtractorCandidatesCore {
    param([object[]]$Files, [string]$Project, [string]$Version)

    # index every top-level function across all files
    $index = @{}
    $order = New-Object System.Collections.Generic.List[object]
    $parseErrors = @{}
    foreach ($f in $Files) {
        $info = Get-LibraryCodeInfo -Code $f.Text
        if ($info.Errors.Count -gt 0) { $parseErrors[$f.RelPath] = "$($info.Errors[0].Message) (line $($info.Errors[0].Extent.StartLineNumber))" }
        foreach ($fa in $info.FunctionAsts) {
            $rec = [pscustomobject]@{ Name = $fa.Name; Ast = $fa; File = $f.RelPath; IsTemplate = [bool]$f.IsTemplate; Facts = $null; Duplicate = $false }
            if ($index.ContainsKey($fa.Name.ToLower())) { $rec.Duplicate = $true; $index[$fa.Name.ToLower()].Duplicate = $true }
            $index[$fa.Name.ToLower()] = $rec        # the later definition wins, as at import time
            $order.Add($rec)
        }
    }
    foreach ($rec in $index.Values) { $rec.Facts = Get-ExtractorFunctionFacts -Fn $rec.Ast }

    $modCache = @{}
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($rec in $order) {
        if ($index[$rec.Name.ToLower()] -ne $rec) { continue }   # shadowed duplicate

        # dependency closure (post-order: helpers before the functions that use them)
        $helpers = New-Object System.Collections.Generic.List[object]
        $visiting = @{}
        $visit = $null
        $visit = {
            param($r)
            $key = $r.Name.ToLower()
            if ($visiting.ContainsKey($key)) { return }
            $visiting[$key] = $true
            foreach ($c in $r.Facts.Calls) {
                $ck = $c.ToLower()
                if ($index.ContainsKey($ck) -and $ck -ne $rec.Name.ToLower()) { & $visit $index[$ck] }
            }
            if ($r -ne $rec) { $helpers.Add($r) }
        }
        & $visit $rec

        $all = @($rec) + $helpers.ToArray()
        $blockers = New-Object System.Collections.Generic.List[string]
        $warnings = New-Object System.Collections.Generic.List[string]
        $modules = New-Object System.Collections.Generic.List[string]
        $tools = New-Object System.Collections.Generic.List[string]
        $unknown = New-Object System.Collections.Generic.List[string]
        $modifies = New-Object System.Collections.Generic.List[string]
        $optional = New-Object System.Collections.Generic.List[string]
        $setAll = @{}
        foreach ($r in $all) { foreach ($k in $r.Facts.ScriptSet.Keys) { $setAll[$k] = $true } }

        foreach ($r in $all) {
            $who = if ($r -eq $rec) { '' } else { " [in helper $($r.Name)]" }
            foreach ($b in $r.Facts.Blockers) { $msg = "$b$who"; if (-not $blockers.Contains($msg)) { $blockers.Add($msg) } }
            foreach ($w in $r.Facts.Warnings) { $msg = "$w$who"; if (-not $warnings.Contains($msg)) { $warnings.Add($msg) } }
            foreach ($k in $r.Facts.ScriptRead.Keys) {
                if (-not $setAll.ContainsKey($k)) {
                    $msg = "Reads module state it never sets (`$$($r.Facts.ScriptRead[$k]))$who"
                    if (-not $blockers.Contains($msg)) { $blockers.Add($msg) }
                }
            }
            if ($r.Facts.FreeVars.Count -gt 0) {
                $warnings.Add("Uses variables it never defines: $(@($r.Facts.FreeVars) -join ', ')$who")
            }
            foreach ($m in $r.Facts.Modifies) { if (-not $modifies.Contains($m)) { $modifies.Add($m) } }
            foreach ($c in $r.Facts.Calls) {
                $ck = $c.ToLower()
                if ($index.ContainsKey($ck)) { continue }
                if ($r.Facts.Optional.ContainsKey($ck)) { if (-not $optional.Contains($c)) { $optional.Add($c) }; continue }
                if (-not $modCache.ContainsKey($ck)) { $modCache[$ck] = Get-ExtractorModuleFor -Command $c }
                $res = $modCache[$ck]
                switch ($res.Kind) {
                    'Module'  { if (-not $modules.Contains($res.Name)) { $modules.Add($res.Name) } }
                    'Tool'    { if (-not $tools.Contains($res.Name)) { $tools.Add($res.Name) } }
                    'Unknown' { if (-not $unknown.Contains($c)) { $unknown.Add($c) } }
                }
            }
        }
        if ($unknown.Count -gt 0) { $warnings.Add("Calls commands not found on this machine: $($unknown -join ', ')") }
        if ($rec.Duplicate) { $warnings.Add('Defined in more than one file - the last definition is used') }
        if ($parseErrors.ContainsKey($rec.File)) { $blockers.Add("Parse error in $($rec.File): $($parseErrors[$rec.File])") }
        $ownVerb = ($rec.Name -split '-', 2)[0]
        if ($script:ModifyingVerbs -contains $ownVerb -and $ownVerb -notin @('Write', 'Out', 'Import', 'Copy')) { if (-not $modifies.Contains($rec.Name)) { $modifies.Add($rec.Name) } }

        # the standalone code: helpers first, then the function itself
        $sb = New-Object System.Text.StringBuilder
        foreach ($h in $helpers) {
            [void]$sb.AppendLine("# helper from $($h.File)")
            [void]$sb.AppendLine($h.Ast.Extent.Text)
            [void]$sb.AppendLine()
        }
        [void]$sb.AppendLine("# from $($rec.File)")
        [void]$sb.Append($rec.Ast.Extent.Text)
        $code = $sb.ToString()

        $status = 'Ready'
        if ($blockers.Count -gt 0) { $status = 'Blocked' }
        elseif ($warnings.Count -gt 0) { $status = 'Review' }

        $out.Add([pscustomobject]@{
            Function        = $rec.Name
            File            = $rec.File
            IsTemplate      = $rec.IsTemplate
            Project         = $Project
            Version         = $Version
            Status          = $status
            Blockers        = $blockers.ToArray()
            Warnings        = $warnings.ToArray()
            Helpers         = @($helpers | ForEach-Object { $_.Name })
            Modules         = $modules.ToArray()
            Tools           = $tools.ToArray()
            Optional        = $optional.ToArray()
            SuggestModifies = ($modifies.Count -gt 0)
            ModifyingCalls  = $modifies.ToArray()
            Code            = $code
            Hash            = Get-LibraryCodeHash -Code $code
        })
    }
    return $out.ToArray()
}

function Get-ExtractorCandidates {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Source)
    return Get-ExtractorCandidatesCore -Files $Source.Files -Project $Source.Project -Version $Source.Version
}

function Get-ExtractorCandidatesFromCode {
    [CmdletBinding()]
    param([AllowEmptyString()] [string]$Code, [string]$Label = 'Pasted')
    $f = [pscustomobject]@{ RelPath = $Label; Text = $Code; IsTemplate = $false }
    return Get-ExtractorCandidatesCore -Files @($f) -Project $Label -Version ''
}

# A plain-text summary of a candidate, for the Import tab / editor.
function Format-ExtractorCandidate {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Candidate)
    $nl = [Environment]::NewLine
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("$($Candidate.Function)   -   $($Candidate.Status)$nl")
    [void]$sb.Append("From: $($Candidate.File)$nl$nl")
    if ($Candidate.Blockers.Count) { [void]$sb.Append("Cannot run standalone:$nl"); foreach ($b in $Candidate.Blockers) { [void]$sb.Append("  x $b$nl") }; [void]$sb.Append($nl) }
    if ($Candidate.Warnings.Count) { [void]$sb.Append("Check before using:$nl"); foreach ($w in $Candidate.Warnings) { [void]$sb.Append("  ! $w$nl") }; [void]$sb.Append($nl) }
    if ($Candidate.Helpers.Count)  { [void]$sb.Append("Bundled helpers: $($Candidate.Helpers -join ', ')$nl") }
    if ($Candidate.Modules.Count)  { [void]$sb.Append("Needs modules: $($Candidate.Modules -join ', ')$nl") }
    if ($Candidate.Tools.Count)    { [void]$sb.Append("Uses tools: $($Candidate.Tools -join ', ')$nl") }
    if (@($Candidate.Optional).Count) { [void]$sb.Append("Uses if present: $(@($Candidate.Optional) -join ', ')$nl") }
    if ($Candidate.SuggestModifies) { [void]$sb.Append("Changes things: $($Candidate.ModifyingCalls -join ', ')$nl") }
    $params = @(Get-LibraryParameterInfo -Code $Candidate.Code -Function $Candidate.Function)
    if ($params.Count) {
        [void]$sb.Append("${nl}Parameters:$nl")
        foreach ($p in $params) { [void]$sb.Append("  -$($p.Name)  [$($p.TypeName)]$(if ($p.Mandatory) { '  required' })$(if ($p.DefaultText) { "  = $($p.DefaultText)" })$nl") }
    }
    return $sb.ToString()
}
