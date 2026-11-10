# AD_Core.psm1   (ADMIN TIER)
#
# The bridge between the template host ($App) and the ported AD Admin 1.6.1
# modules. It is combined into the launcher's shared-scope module together with
# every ported AD module (see $SharedScopeModules in _AppLauncher.ps1), because
# the original app dot-sourced its modules into ONE $script: scope and they rely
# on it. Everything here therefore uses $script: so the ported modules see it.
#
# It replaces what the original launcher (_AD-Admin.ps1) provided:
#   * paths      $script:RootDir / ExportsDir / LogsDir / ConfigDir
#                (ConfigDir = <data root>\Settings - persistent; the host's
#                 Config\ mirror is rewritten every launch, see Get-AppSettingsDir)
#   * logging    hands start-up to Services_ADLogging (the original logging
#                module: per-domain action logs, Session.log, Activity Log panes)
#   * helpers    Set-Status (-> $App.SetStatus + Session.log), Set-Selected*,
#                Update-DomainBar, Update-ContextMailDefaults, Write-ModuleDebugLog
#   * $Context   ONE shared context object for every AD tab (Get-ADSharedContext)
#                - the original had exactly one; separate copies per tab made
#                OU/selection state diverge between tabs.
#   * domain     connect on first use; reconnect when the environment (domain)
#                is changed on the Environment tab (the original's
#                "Change Domain..." button).
#   * settings   the original Domain Defaults editor, split across the
#                Environment tab's Mail / Accounts / Messages / Lists & Logs
#                pages (Register-EnvironmentSection) for the ACTIVE
#                environment's domain - no AD connection needed.
#   * start-up   the first AD tab you open connects; Users, Groups, Account
#                Management and Computers are then built in the background
#                (the original built every tab before showing the window).

# Layout canvas. Each AD tab is laid out against the size of the window's tab
# page AT BUILD TIME (Set-ADTabCanvas), so it fills a window opened for the
# target screen (1885 x 1020, see AppHost.cs) without scrolling. These are the
# floors: the smallest size the 1.6.1 layouts were proven at (the original's
# 1680 x 860 form). Below that a tab scrolls instead of squeezing.
$script:ADTabMinW = 1390
$script:ADTabMinH = 730
$script:ADTabW    = 1400       # fallback when the window size is unknown
$script:ADTabH    = 820

$script:ADApp        = $null
$script:ADContext    = $null
$script:ADConnected  = $false
$script:ADConnectAttempted = $false
$script:ADConnectError     = ''      # why the last connect failed (shown on the banner)
$script:SessionLogReady = $false

# Called by the launcher once the shared-scope module is imported.
function Initialize-SharedScope {
    param($App)
    Initialize-ADCore -App $App
}

function Initialize-ADCore {
    param($App)
    $script:ADApp = $App
    $done = New-Object System.Collections.Generic.List[string]

    # 1. Environment tab pages FIRST - nothing below can stop them appearing.
    try {
        if (Get-Command Register-EnvironmentSection -ErrorAction SilentlyContinue) {
            Register-EnvironmentSection -Title 'Domain'   -Order 10 -Build { param($Page, $App) New-ADDomainPage   -Page $Page -App $App }
            Register-EnvironmentSection -Title 'Accounts' -Order 20 -Build { param($Page, $App) New-ADAccountsPage -Page $Page -App $App }
            Register-EnvironmentSection -Title 'Mail'     -Order 30 -Build { param($Page, $App) New-ADMailPage     -Page $Page -App $App }
            Register-EnvironmentSection -Title 'Messages' -Order 40 -Build { param($Page, $App) New-ADMessagesPage -Page $Page -App $App }
            $done.Add('environment pages')
        } else { $App.Log('ERROR', 'ADCore', 'Register-EnvironmentSection not found - Base\Services_Environment.psm1 is out of date.') }
    } catch { $App.Log('ERROR', 'ADCore', "registering environment pages: $($_.Exception.ToString())") }

    # 2. Paths (Exports, Logs, Settings under the data root).
    try { Set-ADDataPaths -App $App; $done.Add('paths') }
    catch { $App.Log('ERROR', 'ADCore', "paths: $($_.Exception.ToString())") }

    # 3. Original start-up: hand diagnostics to Services_ADLogging, tidy the log store.
    try {
        if (Get-Command Write-SessionLog -ErrorAction SilentlyContinue) {
            $script:SessionLogReady = $true
            if (Get-Command Initialize-LogStore -ErrorAction SilentlyContinue) { Initialize-LogStore }
            $done.Add('logging')
        }
    } catch { $App.Log('WARN', 'ADCore', "Initialize-LogStore: $($_.Exception.Message)") }

    # 4. Domain = environment: re-point paths and reconnect when it changes; drop
    #    the AD logger's cache when the app-wide Logging page saves.
    try {
        if (Get-Command Register-EnvironmentChangedHandler -ErrorAction SilentlyContinue) {
            Register-EnvironmentChangedHandler -Handler ${function:Invoke-ADEnvironmentChanged}
        }
        if (Get-Command Register-AppSettingsChangedHandler -ErrorAction SilentlyContinue) {
            Register-AppSettingsChangedHandler -Handler ${function:Invoke-ADSettingsRefresh}
        }
        $done.Add('handlers')
    } catch { $App.Log('ERROR', 'ADCore', "handlers: $($_.Exception.ToString())") }

    # 5. One time: bring the 1.6.1 Domain Defaults into the environments.
    try { Import-AD161Settings -App $App; $done.Add('1.6.1 import checked') }
    catch { $App.Log('ERROR', 'ADCore', "1.6.1 settings import: $($_.Exception.ToString())") }

    $App.Log('INFO', 'ADCore', "AD core ready: $($done -join ', ').")
}

# After the Environment tab saves (or the Logging settings change): push the new
# values into every AD tab that is already built - what 1.6.1's Domain Defaults
# Save did. Each refresher reads the active environment's settings itself.
function Invoke-ADSettingsRefresh {
    param($App, [string]$Name = '')
    if (Get-Command Reset-LogSettingsCache -ErrorAction SilentlyContinue) { try { Reset-LogSettingsCache } catch { } }
    foreach ($fn in @('Update-ContextMailDefaults', 'Update-CreateUserDomainDefaults', 'Update-OffboardDomainDefaults',
                      'Update-BulkOnboardDomainDefaults', 'Update-UsersFilterDefault', 'Update-GroupsFilterDefault',
                      'Update-ComputersFilterDefault')) {
        if (Get-Command $fn -ErrorAction SilentlyContinue) {
            try { & $fn } catch { if ($script:ADApp) { $script:ADApp.Log('WARN', 'ADCore', "$fn after save: $($_.Exception.Message)") } }
        }
    }
}

# One-time import of the 1.6.1 Domain Defaults into the environments
# (store marker "ADImport161"). Sources, newest SavedUtc per domain wins:
#   * the embedded environments (this release ships both 1.6.1 domains in
#     Config\Environments.json);
#   * 1.6.1's live file on this machine:
#       %APPDATA%\WindowsDiagnosticData\Config\DomainDefaults.json
#   * this app's 1.2.0-1.2.6 copy: <data root>\Settings\DomainDefaults.json
# A domain with no environment yet gets one, named after the domain.
function Import-AD161Settings {
    param($App)
    if (-not (Get-Command Read-AppEnvironmentStore -ErrorAction SilentlyContinue)) { return }
    $store = Read-AppEnvironmentStore -App $App
    if ($store.Extra.Contains('ADImport161')) { return }

    $sources = @(
        (Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'WindowsDiagnosticData\Config\DomainDefaults.json'),
        (Join-Path ([string]$script:ConfigDir) 'DomainDefaults.json')
    )
    $toTime = { param($v) $t = [datetime]::MinValue; if ($v) { [void][datetime]::TryParse([string]$v, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal, [ref]$t) }; $t }
    $best = @{}      # domain -> @{ Data; Time; From }
    foreach ($src in $sources) {
        if (-not $src -or -not (Test-Path -LiteralPath $src)) { continue }
        try {
            $j = [System.IO.File]::ReadAllText($src, [System.Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
            foreach ($p in $j.PSObject.Properties) {
                $t = & $toTime $p.Value.SavedUtc
                $k = $p.Name.ToLowerInvariant()
                if (-not $best.ContainsKey($k) -or $t -gt $best[$k].Time) { $best[$k] = @{ Domain = $p.Name; Data = $p.Value; Time = $t; From = $src } }
            }
        } catch { $App.Log('WARN', 'ADCore', "1.6.1 import: could not read $src : $($_.Exception.Message)") }
    }

    $blank = @((New-BlankDomainDefaults).PSObject.Properties.Name)
    $report = New-Object System.Collections.ArrayList
    foreach ($k in @($best.Keys)) {
        $b = $best[$k]
        $rec = $null
        foreach ($r in $store.Environments) { if (([string]$r['Domain']).Trim() -ieq $b.Domain) { $rec = $r; break } }
        if (-not $rec) {
            $rec = [ordered]@{ Name = ($b.Domain -replace '[^A-Za-z0-9_.-]+', '-'); Label = $b.Domain; Domain = $b.Domain; Server = ''; SharedPath = ''; IsDefault = $false; FilterAsYouType = $true; LogMaxKB = 5120 }
            [void]$store.Environments.Add($rec)
        }
        elseif ((& $toTime $rec['SavedUtc']) -ge $b.Time) { continue }     # what we have is as new or newer
        foreach ($pn in $blank) {
            $pp = $b.Data.PSObject.Properties[$pn]
            if ($pp -and $null -ne $pp.Value) { $rec[$pn] = $pp.Value }
        }
        [void]$report.Add("$($b.Domain) <- $($b.From)")
    }
    $store.Extra['ADImport161'] = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    Write-AppEnvironmentStore -App $App -Store $store
    if ($report.Count -gt 0) { $App.Log('INFO', 'ADCore', "Imported 1.6.1 Domain Defaults: $($report.ToArray() -join '; ')") }
    else { $App.Log('INFO', 'ADCore', '1.6.1 Domain Defaults: nothing newer than the shipped environments.') }
}

function Set-ADDataPaths {
    param($App)
    $root = [string]$App.DataRoot
    $script:RootDir    = $root
    $script:ExportsDir = Join-Path $root 'Exports'
    $script:LogsDir    = Join-Path $root 'Logs'
    $script:ConfigDir  = if (Get-Command Get-AppSettingsDir -ErrorAction SilentlyContinue) { Get-AppSettingsDir -App $App } else { Join-Path $root 'Settings' }
    foreach ($d in @($script:ExportsDir, $script:LogsDir, $script:ConfigDir)) {
        try { if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null } } catch { }
    }
    if ($script:ADContext) {
        $script:ADContext.ExportsDir = $script:ExportsDir
        $script:ADContext.LogsDir    = $script:LogsDir
        $script:ADContext.RootDir    = $script:RootDir
    }
    if (Get-Command Reset-LogSettingsCache -ErrorAction SilentlyContinue) { try { Reset-LogSettingsCache } catch { } }
}

# ---- launcher helper functions the AD modules call by name ----------------

function Set-Status {
    param([string]$Text, [string]$Level = 'info')
    if ($script:ADApp) { try { $script:ADApp.SetStatus([string]$Text, [string]$Level) } catch { } }
    if ($Text -and $Text.Trim()) {
        if ($script:SessionLogReady) { try { Write-SessionLog -Text $Text -Level $Level -Source 'Status' } catch { } }
        elseif ($script:ADApp)       { $script:ADApp.Log('INFO', 'Status', [string]$Text) }
    }
}

function Set-SelectedUser     { param($User)  if ($script:ADContext) { $script:ADContext.SelectedUser  = $User } }
function Set-SelectedComputer { param($Comp)  if ($script:ADContext) { $script:ADContext.SelectedComp  = $Comp } }
function Set-SelectedOU       { param([string]$Name, [string]$DN) if ($script:ADContext) { $script:ADContext.SelectedOU = $Name; $script:ADContext.SelectedOUDN = $DN } }
function Set-SelectedGroup    { param($Group) if ($script:ADContext) { $script:ADContext.SelectedGroup = $Group } }

# The original domain bar (Domain / DC labels) is the host's status line here.
function Update-DomainBar {
    if (-not $script:ADContext) { return }
    if ($script:ADContext.Domain) { Set-Status "Connected to $($script:ADContext.Domain)  (DC: $($script:ADContext.TargetDC))" 'ok' }
    else                          { Set-Status 'Not connected to a domain.' 'warn' }
}

# Original launcher's start-up trace; routed to Session.log as [DIAG].
function Write-ModuleDebugLog {
    param([string]$Text)
    if ($script:SessionLogReady) { try { Write-SessionLog -Text $Text -Level 'diag' -Source 'Startup' } catch { } }
    elseif ($script:ADApp)       { $script:ADApp.Diag('ADCore', $Text) }
}

# Mail settings: the environment's AD settings (Environment tab > Mail). An
# environment entry may still carry SmtpServer/MailFrom from older versions;
# they are used only when the settings have none.
function Update-ContextMailDefaults {
    $ctx = $script:ADContext
    if (-not $ctx) { return }
    if ($script:ADApp) {
        $s = [string]$script:ADApp.GetSetting('SmtpServer'); if ($s) { $ctx.SmtpServer = $s }
        $m = [string]$script:ADApp.GetSetting('MailFrom');   if ($m) { $ctx.MailFrom   = $m }
    }
    if (-not $ctx.Domain) { return }
    if (-not (Get-Command Get-DomainDefaults -ErrorAction SilentlyContinue)) { return }
    try {
        $d = Get-DomainDefaults -Domain $ctx.Domain
        if ($d.SmtpServer) { $ctx.SmtpServer = $d.SmtpServer }
        if ($d.SmtpPort)   { $ctx.SmtpPort   = $d.SmtpPort }
        if ($d.MailFrom)   { $ctx.MailFrom   = $d.MailFrom }
    } catch { }
}

# ---- the shared $Context ----------------------------------------------------

function Build-ADContext {
    param($App, [int]$TabW = $script:ADTabW, [int]$TabH = $script:ADTabH)
    $ctx = [PSCustomObject]@{
        Domain = ''; DomainDN = ''; ForestRoot = ''; TargetDC = ''
        SelectedOU = ''; SelectedOUDN = ''; SelectedUser = $null; SelectedComp = $null; SelectedGroup = $null
        AdminAccount = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        ExportsDir = $script:ExportsDir; LogsDir = $script:LogsDir; RootDir = $script:RootDir
        Capabilities = $null
        TabW = $TabW; TabH = $TabH; SubTabH = ($TabH - 22)
        AdminMail = ''; MailEnabled = $true
        SmtpServer = ''; SmtpPort = 25; MailFrom = ''
    }

    # Navigation hook from the original launcher:  & $Context.SelectMainTab '<key>'
    $keyToTitle = @{
        directory = 'Users'; groups = 'Groups'; useractions = 'Account Management'; computers = 'Computers'
        bulkops = 'Bulk Operations'; infrastructure = 'Infrastructure'; tools = 'Tools'; audit = 'Audit'
        domaindefaults = 'Environment'
    }
    $nav = $global:MainTabs
    $ctx | Add-Member -MemberType NoteProperty -Name SelectMainTab -Force -Value ({
        param([string]$Key)
        if (-not $nav -or -not $Key -or -not $keyToTitle.ContainsKey($Key)) { return }
        $tp = $null
        foreach ($p in $nav.TabPages) { if ($p.Text.Trim() -eq $keyToTitle[$Key]) { $tp = $p; break } }
        if ($tp) {
            $switch = { $nav.SelectedTab = $tp }.GetNewClosure()
            [void]$nav.BeginInvoke([System.Windows.Forms.MethodInvoker]$switch)
        }
    }).GetNewClosure()

    $script:ADContext = $ctx
    $script:Context   = $ctx      # the original launcher's name; Services_ADLogging falls back to it
    # In the original every registrar's own context variable WAS this one object,
    # set when the tabs were built at start-up. Tabs now build in any order, so
    # set them all up front - e.g. Groups' loader exits early without
    # $script:DirContext (which only the Users tab used to set).
    $script:DirContext = $ctx; $script:GroupsCtx = $ctx; $script:UAContext = $ctx
    $script:CompCtx    = $ctx; $script:BulkOpsCtx = $ctx; $script:InfraCtx = $ctx
    $script:ToolsCtx   = $ctx; $script:AudContext = $ctx; $script:AudCtx   = $ctx
    $script:NamingCtx  = $ctx
    return $ctx
}

# Every AD tab calls this: the first call builds the context and connects;
# later calls return the same object (so Users, Groups and the rest share
# selection, OU and domain state exactly as in the original).
# -NoConnect: just the context (Domain taken from the environment) - used by
# the Environment tab, which must work even when AD is unreachable.
function Get-ADSharedContext {
    param($App, [switch]$NoConnect)
    if (-not $App) { $App = $script:ADApp }
    if (-not $script:ADContext) {
        [void](Build-ADContext -App $App)
        $script:ADContext.Domain = Get-ADSettingsKey -App $App
        Update-ContextMailDefaults
    }
    if ($NoConnect -or $script:ADConnectAttempted) { return $script:ADContext }

    $script:ADConnectAttempted = $true
    $ctx = $script:ADContext
    Set-Status 'Detecting environment...'
    $script:ADConnected = Initialize-ADConnection -Context $ctx -App $App
    if (-not $script:ADConnected) { $ctx.Domain = '' }
    Update-ContextMailDefaults
    if ($script:ADConnected) {
        Update-DomainBar
        if (Get-Command Write-OperationLog -ErrorAction SilentlyContinue) {
            Write-OperationLog -Context $ctx -Action 'STARTUP' -Target 'AD User Lookup' -Result 'OK' `
                -Detail "Domain: $($ctx.Domain) | Admin: $($ctx.AdminAccount)"
        }
    }
    else { Set-Status "Not connected to AD: $script:ADConnectError" 'warn' }

    # The original built every tab before showing the window, and some actions
    # rely on it: "Clone User..." (Users) fills in Account Management's form,
    # "Test Connectivity" (Users computer menu) writes to the Computers tab's
    # cards. Build those - and Users / Groups, the everyday tabs - in the
    # background now. The rest (Bulk Operations, Infrastructure, Tools, Audit)
    # are independent and build when first opened.
    if ($global:MainTabs -and (Get-Command Invoke-LazyTabWarmup -ErrorAction SilentlyContinue)) {
        try { Invoke-LazyTabWarmup -Tabs $global:MainTabs -App $App -Titles $script:ADWarmTitles -IntervalMs 250 } catch { }
    }
    return $ctx
}

# Tabs built in the background once connected (titles as in UI_Register-Tabs).
$script:ADWarmTitles = @('Users', 'Groups', 'Account Management', 'Computers')

# Run -Action whenever -Page comes on screen (v1.2.20), after the click has
# been handled, so the tab paints first. -Action must do nothing when its data
# is already loaded (the Invoke-*FirstLoad functions check a flag), so this
# loads a tab's data on its first view - and again on the next view after an
# environment change marked it stale, or after a view while not connected.
# The ported tabs loaded in $Tab.Add_Enter, i.e. when keyboard focus moved into
# the tab - not reliable for a tab built in the background (Invoke-LazyTabWarmup):
# if focus did not land inside it, nothing loaded until you clicked the list.
function Register-ADTabFirstShow {
    param([System.Windows.Forms.TabPage]$Page, [scriptblock]$Action)
    $tabs = $Page.Parent
    if (-not ($tabs -is [System.Windows.Forms.TabControl])) { return }
    $app = $script:ADApp
    $run = {
        if ($tabs.SelectedTab -ne $Page) { return }
        try { & $Action }
        catch { if ($app) { $app.Log('ERROR', 'Tabs', "$($Page.Text.Trim()) load: $($_.Exception.Message)") } }
    }.GetNewClosure()
    $tabs.Add_SelectedIndexChanged({
        if ($tabs.SelectedTab -eq $Page) {
            try { [void]$tabs.BeginInvoke([System.Windows.Forms.MethodInvoker]$run) } catch { }
        }
    }.GetNewClosure())
    if ($tabs.SelectedTab -eq $Page -and $tabs.IsHandleCreated) {
        try { [void]$tabs.BeginInvoke([System.Windows.Forms.MethodInvoker]$run) } catch { }
    }
}

# The key the environment's AD settings (Settings\DomainDefaults.json) are
# stored under: the environment's Domain field; else the connected domain;
# else - when the environment names no server - the domain this machine is in.
function Get-ADSettingsKey {
    param($App)
    $d = [string]$App.GetSetting('Domain')
    if ($d.Trim()) { return $d.Trim() }
    if ($script:ADConnected -and $script:ADContext -and $script:ADContext.Domain) { return [string]$script:ADContext.Domain }
    if (-not [string]$App.GetSetting('Server') -and $env:USERDNSDOMAIN) { return [string]$env:USERDNSDOMAIN }
    return ''
}

function Test-ADSharedConnected { return [bool]$script:ADConnected }

# Size the shared $Context for the tab about to be built: the window's tab-page
# area minus what the host puts beside/above the ported layout (the Users tab's
# OU tree, a not-connected banner). The 1.6.1 registrars read TabW / TabH /
# SubTabH only while building, so setting them per tab is safe.
function Set-ADTabCanvas {
    param($Context, [int]$ReserveW = 0, [int]$ReserveH = 0)
    $w = $script:ADTabW; $h = $script:ADTabH
    if ($global:MainTabs -and (Get-Command Get-TabPageArea -ErrorAction SilentlyContinue)) {
        $a = Get-TabPageArea -Tabs $global:MainTabs
        if ($a.Width -gt 0 -and $a.Height -gt 0) { $w = $a.Width - $ReserveW; $h = $a.Height - $ReserveH }
    }
    if ($w -lt $script:ADTabMinW) { $w = $script:ADTabMinW }
    if ($h -lt $script:ADTabMinH) { $h = $script:ADTabMinH }
    $Context.TabW = $w; $Context.TabH = $h; $Context.SubTabH = $h - 22
}

# A red banner for tabs built while AD is not reachable.
function Add-ADNotConnectedBanner {
    param([System.Windows.Forms.Control]$Parent)
    if ($script:ADConnected) { return }
    $banner = New-Object System.Windows.Forms.Label
    $why = if ($script:ADConnectError) { $script:ADConnectError } else { 'needs the RSAT ActiveDirectory module and a reachable domain' }
    $banner.Text = "Not connected to AD - $why   (Environment tab: Domain / Domain controller. User Lookup works without RSAT.)"
    $banner.AutoEllipsis = $true
    $banner.Dock = 'Top'; $banner.Height = 30; $banner.ForeColor = [System.Drawing.Color]::Firebrick
    $banner.Padding = New-Object System.Windows.Forms.Padding(8, 8, 8, 0)
    $Parent.Controls.Add($banner)
    $banner.BringToFront()
}

# ---- AD connection (RSAT ActiveDirectory). Uses the active environment's
#      Server when set, else the domain this machine is joined to. ----------
function Initialize-ADConnection {
    param($Context, $App)
    # (Capabilities - RSAT/LAPS/WinRM/OS probes - are left to the Environment
    #  Report, which computes them on first use.)
    $script:ADConnectError = ''
    $server = [string]$App.GetSetting('Server')
    if (-not $server) { $server = [string]$App.GetSetting('Domain') }
    $target = if ($server) { "'$server'" } else { 'the current domain' }

    # 1. the RSAT ActiveDirectory module
    $modOk = $false
    try { Import-Module ActiveDirectory -ErrorAction Stop; $modOk = $true }
    catch {
        $script:ADConnectError = "The ActiveDirectory PowerShell module could not be loaded: $($_.Exception.Message)"
        if ($App) { $App.Log('WARN', 'ADCore', $script:ADConnectError) }
    }
    if (-not (Get-Command Get-ADDomain -ErrorAction SilentlyContinue)) {      # (also tries module auto-loading)
        if (-not $script:ADConnectError) { $script:ADConnectError = 'Get-ADDomain is not available (RSAT ActiveDirectory module missing?).' }
        return $false
    }
    $script:ADConnectError = ''

    # 2. the domain
    try {
        $d = if ($server) { Get-ADDomain -Server $server -ErrorAction Stop } else { Get-ADDomain -ErrorAction Stop }
        $Context.Domain = $d.DNSRoot; $Context.DomainDN = $d.DistinguishedName; $Context.TargetDC = $d.PDCEmulator
        try { $f = if ($server) { Get-ADForest -Server $server -ErrorAction Stop } else { Get-ADForest -ErrorAction Stop }; $Context.ForestRoot = $f.RootDomain }
        catch { $Context.ForestRoot = $d.DNSRoot }
        if ($App) { $App.Log('INFO', 'ADCore', "connected to $($Context.Domain) via $($Context.TargetDC) (target $target)") }
        return $true
    }
    catch {
        $script:ADConnectError = "Could not reach $target : $($_.Exception.Message)"
        if ($App) { $App.Log('WARN', 'ADCore', $script:ADConnectError) }
    }
    return $false
}

# Environment (domain) switched on the Environment tab - the original's
# "Change Domain..." flow: new paths, reconnect, rebuild tree, reload panes.
function Invoke-ADEnvironmentChanged {
    param($App)
    Set-ADDataPaths -App $App
    $ctx = $script:ADContext
    if (-not $ctx) { return }          # no AD tab opened yet; the first one connects
    if (-not $script:ADConnectAttempted) {
        # only the Environment tab has used the context so far: follow the new
        # environment's domain without connecting
        $ctx.Domain = Get-ADSettingsKey -App $App
        Update-ContextMailDefaults
        return
    }
    $script:ConnCompLoaded = $false      # Computers tab re-reads on its next view
    foreach ($k in @('Domain','DomainDN','ForestRoot','TargetDC','SelectedOU','SelectedOUDN')) { $ctx.$k = '' }
    $ctx.SelectedUser = $null; $ctx.SelectedComp = $null; $ctx.SelectedGroup = $null
    $script:ADConnected = Initialize-ADConnection -Context $ctx -App $App
    Update-ContextMailDefaults
    Update-DomainBar
    if (-not $script:ADConnected) { return }

    # v1.2.20: the old domain's lists are cleared and marked stale; only the tab
    # on screen loads now, every other tab loads its list when next shown
    # (Register-ADTabFirstShow). Before, users, groups and computers were all
    # re-read here, for tabs that might never be opened.
    $script:UsersFirstLoaded  = $false
    $script:GroupsFirstLoaded = $false
    if (Get-Command Stop-ADIPv4Fill -ErrorAction SilentlyContinue) { Stop-ADIPv4Fill }
    try { $script:AllUsers.Clear();  if (Get-Command Update-UserGrid  -ErrorAction SilentlyContinue) { Update-UserGrid } } catch { }
    try { $script:AllGroups.Clear(); if (Get-Command Update-GroupGrid -ErrorAction SilentlyContinue) { Update-GroupGrid } } catch { }
    try { $script:AllConnComputers.Clear(); if (Get-Command Update-ConnCompGrid -ErrorAction SilentlyContinue) { Update-ConnCompGrid } } catch { }
    $shown = if ($global:MainTabs -and $global:MainTabs.SelectedTab) { $global:MainTabs.SelectedTab.Text.Trim() } else { '' }

    $frm = if ($global:AppForm) { $global:AppForm } else { $null }
    if ($frm) { $frm.Cursor = [System.Windows.Forms.Cursors]::WaitCursor }
    try {
        if (Get-Command Update-DirectoryTree -ErrorAction SilentlyContinue) { try { Update-DirectoryTree -Context $ctx } catch { } }
        switch ($shown) {
            'Users'     { try { Invoke-UsersFirstLoad } catch { } }
            'Groups'    { try { Invoke-GroupsFirstLoad } catch { } }
            'Computers' { try { Reset-ConnCompCards; Read-ConnComputers } catch { } }
        }
    }
    finally { if ($frm) { $frm.Cursor = [System.Windows.Forms.Cursors]::Default } }
    if (Get-Command Write-OperationLog -ErrorAction SilentlyContinue) {
        Write-OperationLog -Context $ctx -Action 'DOMAIN-CHANGE' -Target $ctx.Domain -Result 'OK' -Detail "DC: $($ctx.TargetDC)"
    }
}
