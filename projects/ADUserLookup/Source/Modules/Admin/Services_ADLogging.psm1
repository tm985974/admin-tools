#region -- Services.Logging.psm1 ---------------------------------------------
# Concern : All persistent logging, plus the live Activity Log panels.
#
#   Log files (Logs\ under the app root, normally AppData):
#     <DOMAIN>.log  One per domain. Application actions written by
#                   Write-OperationLog (who did what, to what, result).
#     Session.log   Shared by all domains, written ONLY by the host ($App.Log):
#                   Write-SessionLog forwards status, User Actions / Bulk
#                   Onboard messages and startup lines to it, so there is one
#                   writer, one line format and one size cap (Environment >
#                   General > Logging). [DIAG] lines only with diagnostics on.
#
#   Line format (one entry per line; embedded line breaks become " | "):
#     [yyyy-MM-dd HH:mm:ss +hh:mm] [MACHINE] ...
#     Domain log : [ts] [MACHINE] [ACTION: a] [Admin: u] [Domain: d] [Target: t] [Result: r] detail
#   The UTC offset and machine name make entries from different machines
#   merge into the correct time order (the EXE merges logs it carries into
#   these files when it opens - see ADUserLookup.cs "Portable logs").
#
#   Size limits (FIFO): when a file grows past its limit, the oldest lines
#   are dropped until it is back to 90% of the limit.
#     Domain logs : per domain, LogMaxKB in DomainDefaults.json (default 5120)
#     Session.log : trimmed by the host (Session log max on the Logging page).
#
#   Initialize-LogStore (called once by _AD-Admin.ps1 after modules load):
#     - converts the old daily AD-Admin-yyyy-MM-dd.log files into the
#       per-domain files (each line goes to the domain it names, merged in
#       time order) and deletes them;
#     - deletes the old per-launch ModuleLoad_*.log files;
#     - applies the size limits to every domain log.
#
#   Activity Log panels (unchanged behaviour): Add-ActivityLogLine appends a
#   colored line to every registered RichTextBox - the Directory tab's
#   $script:ActivityLogRtb plus any added via Register-ActivityLogTarget.
#   Backfill-ActivityLogTarget writes today's entries into ONE new target.
#   Add-ActivityLogLine is display-only: everything it shows is already
#   persisted by Write-OperationLog or Set-Status.
#
# Load order: 4 - no dependencies on other AD-Admin modules at load time.
#   Soft runtime dependency on Get-DomainDefaults (Services.DomainDefaults.
#   Config) for per-domain size limits; falls back to the default if absent.
# Changes   : v1.2.0 - rewritten for per-domain logs, Session.log, FIFO size
#             limits, diagnostics gating and legacy conversion. Public
#             signatures of Write-OperationLog / Get-OperationLog unchanged,
#             so their callers and the Operations tab need no changes.
#             Get-OperationLog now reads the connected domain's file and
#             filters by each entry's own time (previously by file date).
#endregion

$script:ActivityLogTargets     = [System.Collections.Generic.List[System.Windows.Forms.RichTextBox]]::new()
$script:LogSettingsCache       = $null
$script:DomainLogMaxCache      = @{}
$script:DefaultDomainLogMaxKB  = 5120
$script:LogMinKB               = 64
$script:LogMaxAllowedKB        = 1048576

#region -- Private helpers -----------------------------------------------------
function Get-LogDirectory {
    $dir = if ($script:LogsDir) { $script:LogsDir }
           elseif ($script:RootDir) { Join-Path $script:RootDir 'Logs' }
           else { Join-Path $PWD.Path 'Logs' }
    if (-not (Test-Path $dir)) {
        try { New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null } catch { }
    }
    return $dir
}

# Parses a KB size, clamped to 64 KB .. 1 GB. Unparseable -> $Default.
function ConvertTo-LogMaxKB {
    param($Value, [int]$Default)
    $n = 0
    if (-not [int]::TryParse([string]$Value, [ref]$n)) { return $Default }
    if ($n -lt $script:LogMinKB)        { return $script:LogMinKB }
    if ($n -gt $script:LogMaxAllowedKB) { return $script:LogMaxAllowedKB }
    return $n
}

function Format-LogTimestamp {
    param([datetime]$When)
    return $When.ToString('yyyy-MM-dd HH:mm:ss zzz', [System.Globalization.CultureInfo]::InvariantCulture)
}

function ConvertTo-SingleLogLine {
    param([string]$Text)
    if (-not $Text) { return '' }
    return (($Text -replace '(\r\n|\r|\n)+', ' | ').Trim())
}

# File name for a domain's log: upper-case, invalid file-name characters
# replaced. A blank domain logs to NO-DOMAIN.log.
function Get-DomainLogFileName {
    param([string]$Domain)
    $name = if ($Domain) { $Domain.Trim().ToUpperInvariant() } else { '' }
    $name = $name -replace '[\\/:*?"<>|\s]', '_'
    if (-not $name)            { $name = 'NO-DOMAIN' }
    if ($name -ieq 'SESSION')  { $name = 'SESSION-DOMAIN' }
    return "$name.log"
}

function Get-DomainLogPath {
    param([string]$Domain)
    return (Join-Path (Get-LogDirectory) (Get-DomainLogFileName $Domain))
}

function Get-DomainLogMaxKB {
    param([string]$Domain)
    $key = if ($Domain) { $Domain.Trim().ToUpperInvariant() } else { '' }
    if ($script:DomainLogMaxCache.ContainsKey($key)) { return $script:DomainLogMaxCache[$key] }
    $max = $script:DefaultDomainLogMaxKB
    if ($key -and (Get-Command Get-DomainDefaults -ErrorAction SilentlyContinue)) {
        try {
            $d = Get-DomainDefaults -Domain $Domain
            if ($d -and $d.PSObject.Properties.Match('LogMaxKB').Count -gt 0) {
                $max = ConvertTo-LogMaxKB $d.LogMaxKB $script:DefaultDomainLogMaxKB
            }
        } catch { }
    }
    $script:DomainLogMaxCache[$key] = $max
    return $max
}

# Time at the start of a log line, or $null. Accepts the current format
# "[yyyy-MM-dd HH:mm:ss +hh:mm]" and the older "[yyyy-MM-dd HH:mm:ss]".
function Get-LogLineTime {
    param([string]$Line)
    if ($Line -match '^\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})( [+-]\d{2}:\d{2})?\]') {
        $hasOffset = [bool]$Matches[2]
        $txt = if ($hasOffset) { $Matches[1] + $Matches[2] } else { $Matches[1] }
        $fmt = if ($hasOffset) { 'yyyy-MM-dd HH:mm:ss zzz' } else { 'yyyy-MM-dd HH:mm:ss' }
        $dto = [System.DateTimeOffset]::MinValue
        if ([System.DateTimeOffset]::TryParseExact($txt, $fmt,
                [System.Globalization.CultureInfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::AssumeLocal, [ref]$dto)) {
            return $dto
        }
    }
    return $null
}

# Combines two sets of lines: exact duplicates dropped (first copy kept),
# entries in time order. Lines without a timestamp stay with the entry above.
function Merge-LogLines {
    param([string[]]$First, [string[]]$Second)
    $seen  = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    $items = New-Object 'System.Collections.Generic.List[object]'
    $last  = [System.DateTimeOffset]::MinValue
    $idx   = 0
    foreach ($line in (@($First) + @($Second))) {
        if ($null -eq $line -or $line.Trim() -eq '') { continue }
        $ts = Get-LogLineTime $line
        if ($null -ne $ts) { $last = $ts } else { $ts = $last }
        if (-not $seen.Add($line)) { continue }
        $items.Add([PSCustomObject]@{ T = $ts; I = $idx; L = $line })
        $idx++
    }
    return @($items | Sort-Object -Property T, I | ForEach-Object { $_.L })
}

# FIFO: when the file is over MaxKB, drop the oldest lines until it is at 90%.
function Limit-LogFile {
    param([string]$Path, [int]$MaxKB)
    try {
        if (-not (Test-Path $Path)) { return }
        $maxBytes = [long]$MaxKB * 1024
        if ((New-Object System.IO.FileInfo($Path)).Length -le $maxBytes) { return }
        $target = [long]($maxBytes * 0.9)
        $enc    = New-Object System.Text.UTF8Encoding($false)
        $lines  = [System.IO.File]::ReadAllLines($Path, [System.Text.Encoding]::UTF8)
        $total  = [long]0
        $start  = $lines.Length
        for ($i = $lines.Length - 1; $i -ge 0; $i--) {
            $size = $enc.GetByteCount($lines[$i]) + 2
            if (($total + $size) -gt $target) { break }
            $total += $size
            $start  = $i
        }
        # Never start the kept part on a continuation line.
        while ($start -lt $lines.Length -and $lines[$start] -notmatch '^\[\d{4}-\d{2}-\d{2} ') { $start++ }
        $keep = @()
        if ($start -lt $lines.Length) { $keep = @($lines[$start..($lines.Length - 1)]) }
        [System.IO.File]::WriteAllLines($Path, [string[]]@($keep), $enc)
    } catch { }
}

function Add-LogLine {
    param([string]$Path, [string]$Line, [int]$MaxKB)
    try {
        $enc = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::AppendAllText($Path, $Line + "`r`n", $enc)
        if ((New-Object System.IO.FileInfo($Path)).Length -gt ([long]$MaxKB * 1024)) {
            Limit-LogFile -Path $Path -MaxKB $MaxKB
        }
    } catch { }
}

# Converts the old daily AD-Admin-yyyy-MM-dd.log files into per-domain files
# and deletes the old per-launch ModuleLoad_*.log files. Returns the number
# of entries converted.
function Convert-LegacyLogs {
    $dir = Get-LogDirectory
    foreach ($f in @(Get-ChildItem -Path $dir -Filter 'ModuleLoad_*.log' -File -ErrorAction SilentlyContinue)) {
        try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop } catch { }
    }

    $legacy = @(Get-ChildItem -Path $dir -Filter 'AD-Admin-*.log' -File -ErrorAction SilentlyContinue | Sort-Object Name)
    if ($legacy.Count -eq 0) { return 0 }

    $byFile   = @{}
    $domainOf = @{}
    $count    = 0
    foreach ($f in $legacy) {
        $lines = @()
        try { $lines = [System.IO.File]::ReadAllLines($f.FullName, [System.Text.Encoding]::UTF8) } catch { continue }
        foreach ($line in $lines) {
            if (-not $line -or -not $line.Trim()) { continue }
            $dom  = if ($line -match '\[Domain: ([^\]]*)\]') { $Matches[1].Trim() } else { '' }
            $file = Get-DomainLogFileName $dom
            if (-not $byFile.ContainsKey($file)) {
                $byFile[$file]   = New-Object 'System.Collections.Generic.List[string]'
                $domainOf[$file] = $dom
            }
            $byFile[$file].Add($line)
            $count++
        }
    }

    $enc = New-Object System.Text.UTF8Encoding($false)
    foreach ($file in @($byFile.Keys)) {
        $path     = Join-Path $dir $file
        $existing = @()
        if (Test-Path $path) { $existing = @([System.IO.File]::ReadAllLines($path, [System.Text.Encoding]::UTF8)) }
        $merged   = Merge-LogLines -First $existing -Second $byFile[$file].ToArray()
        [System.IO.File]::WriteAllLines($path, [string[]]@($merged), $enc)
        Limit-LogFile -Path $path -MaxKB (Get-DomainLogMaxKB $domainOf[$file])
    }
    foreach ($f in $legacy) {
        try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop } catch { }
    }
    return $count
}
#endregion

#region -- Reset-LogSettingsCache ---------------------------------------------
function Reset-LogSettingsCache {
    # Clears the cached per-domain size limits so the next write re-reads them.
    # Called after Domain Defaults are saved and when the data root changes.
    $script:DomainLogMaxCache = @{}
}
#endregion

#region -- Initialize-LogStore ----------------------------------------------------
function Initialize-LogStore {
    <#
    .SYNOPSIS
        One-time startup maintenance: converts old daily logs, removes old
        per-launch diagnostics files, and applies size limits to every log.
        Called by _AD-Admin.ps1 after all modules have loaded. Never throws.
    #>
    try {
        $n = Convert-LegacyLogs
        if ($n -gt 0) {
            Write-SessionLog -Text "Converted $n entries from the old daily AD-Admin-*.log files into per-domain logs." -Level 'INFO' -Source 'Logging'
        }
        foreach ($f in @(Get-ChildItem -Path (Get-LogDirectory) -Filter '*.log' -File -ErrorAction SilentlyContinue)) {
            if ($f.Name -ieq 'Session.log') { continue }            # the host trims Session.log
            Limit-LogFile -Path $f.FullName -MaxKB (Get-DomainLogMaxKB $f.BaseName)
        }
    } catch { }
}
#endregion

#region -- Write-SessionLog ---------------------------------------------------------
function Write-SessionLog {
    <#
    .SYNOPSIS
        One entry in Logs\Session.log, through the host's logger ($App.Log) -
        the same writer, format and size cap as every other Session.log line.
    .PARAMETER Level
        ok / warn / err (or fail) / diag / anything else = info. DIAG entries
        are written only when diagnostic logging is on (the host decides).
    .PARAMETER Source
        Short origin tag, e.g. Status, UserActions, BulkOnboard, Startup.
    .PARAMETER Timestamp
        Accepted for old callers; the host stamps the time it is written.
    #>
    param(
        [string]$Text,
        [string]$Level  = 'info',
        [string]$Source = '',
        $Timestamp      = $null
    )
    if (-not $Text -or -not $Text.Trim() -or -not $script:ADApp) { return }
    try {
        $lvl = switch -Regex (([string]$Level).ToLowerInvariant()) {
            '^(ok|success)$'      { 'OK';    break }
            '^(warn|warning)$'    { 'WARN';  break }
            '^(err|error|fail)$'  { 'ERROR'; break }
            '^diag$'              { 'DIAG';  break }
            default               { 'INFO' }
        }
        $src = if ($Source) { $Source } else { 'AD' }
        $script:ADApp.Log($lvl, $src, (ConvertTo-SingleLogLine $Text))
    } catch { }
}
#endregion

#region -- Register-ActivityLogTarget ------------------------------------------
function Register-ActivityLogTarget {
    <#
    .SYNOPSIS
        Adds a RichTextBox as an additional live mirror of the Activity Log -
        every future Add-ActivityLogLine call (and therefore every
        Write-OperationLog call) writes to it too, alongside
        $script:ActivityLogRtb and any other registered target.
    .PARAMETER RichTextBox
        The control to register. Registering the same control twice is a no-op.
    #>
    param([System.Windows.Forms.RichTextBox]$RichTextBox)
    if (-not $RichTextBox) { return }
    if (-not $script:ActivityLogTargets.Contains($RichTextBox)) {
        [void]$script:ActivityLogTargets.Add($RichTextBox)
    }
}
#endregion

#region -- Backfill-ActivityLogTarget -------------------------------------------
function Backfill-ActivityLogTarget {
    <#
    .SYNOPSIS
        Writes today's operation log entries directly into ONE RichTextBox -
        for populating a newly-registered Activity Log mirror so it isn't
        blank on first view. Never goes through Add-ActivityLogLine, which
        would re-broadcast the same lines into every other target.
    #>
    param(
        [System.Windows.Forms.RichTextBox]$RichTextBox,
        [PSCustomObject]$Context
    )
    if (-not $RichTextBox) { return }
    $entries = @(Get-OperationLog -Context $Context -LastNDays 1)
    if ($entries.Count -eq 0) {
        Write-ActivityLogLineTo -RichTextBox $RichTextBox -Text 'No activity logged yet today.' -Level ''
        return
    }
    foreach ($entry in $entries) {
        $lvl = if ($entry.Result -eq 'OK') { 'ok' } else { 'fail' }
        $txt = "$($entry.Action) | $($entry.Target) | $($entry.Result)$(if ($entry.Detail) { " | $($entry.Detail)" })"
        Write-ActivityLogLineTo -RichTextBox $RichTextBox -Text $txt -Level $lvl
    }
}
#endregion

#region -- Write-ActivityLogLineTo (private) --------------------------------------
function Write-ActivityLogLineTo {
    param(
        [System.Windows.Forms.RichTextBox]$RichTextBox,
        [string]$Text,
        [string]$Level = ''
    )
    $color = switch ($Level.ToLower()) {
        'ok'    { [System.Drawing.Color]::FromArgb(80, 255, 80)  }
        'err'   { [System.Drawing.Color]::FromArgb(255, 255, 80) }
        'fail'  { [System.Drawing.Color]::FromArgb(255, 255, 80) }
        'warn'  { [System.Drawing.Color]::FromArgb(255, 255, 80) }
        default { [System.Drawing.Color]::FromArgb(150, 150, 150) }
    }
    try {
        $ts = Get-Date -Format 'HH:mm:ss'
        $RichTextBox.SelectionStart  = $RichTextBox.TextLength
        $RichTextBox.SelectionLength = 0
        $RichTextBox.SelectionColor  = $color
        $RichTextBox.AppendText("[$ts] $Text`r`n")
        $RichTextBox.SelectionStart  = $RichTextBox.TextLength
        $RichTextBox.ScrollToCaret()
    } catch { }
}
#endregion

#region -- Add-ActivityLogLine ------------------------------------------------
function Add-ActivityLogLine {
    <#
    .SYNOPSIS
        Appends one line to every registered Activity Log RichTextBox,
        color-coded by level ('ok' green, 'err'/'fail'/'warn' yellow, else
        gray). Display only - not written to any log file. Safe to call
        before any panel exists.
    #>
    param([string]$Text, [string]$Level = '')

    $targets = [System.Collections.Generic.List[System.Windows.Forms.RichTextBox]]::new()
    if ($script:ActivityLogRtb) { [void]$targets.Add($script:ActivityLogRtb) }
    foreach ($t in $script:ActivityLogTargets) {
        if ($t -and -not $targets.Contains($t)) { [void]$targets.Add($t) }
    }
    if ($targets.Count -eq 0) { return }

    foreach ($rtb in $targets) {
        Write-ActivityLogLineTo -RichTextBox $rtb -Text $Text -Level $Level
    }
}
#endregion

#region -- Write-OperationLog -------------------------------------------------
function Write-OperationLog {
    <#
    .SYNOPSIS
        Records one application action in the domain's log (Logs\<DOMAIN>.log)
        and shows it on the Activity Log panels. The domain is taken from
        -Context, else the app's current context, else the user's DNS domain.
    #>
    param(
        [PSCustomObject]$Context,
        [string]$Action,
        [string]$Target,
        [string]$Result = 'OK',
        [string]$Detail = ''
    )
    try {
        $ctx    = if ($Context) { $Context } elseif ($script:Context) { $script:Context } else { $null }
        $admin  = if ($ctx -and $ctx.AdminAccount) { $ctx.AdminAccount } else { "$env:USERDOMAIN\$env:USERNAME" }
        $domain = if ($ctx -and $ctx.Domain) { [string]$ctx.Domain } elseif ($env:USERDNSDOMAIN) { $env:USERDNSDOMAIN } else { '' }
        $line   = "[$(Format-LogTimestamp (Get-Date))] [$env:COMPUTERNAME] [ACTION: $Action] [Admin: $admin] [Domain: $domain] [Target: $Target] [Result: $Result] $(ConvertTo-SingleLogLine $Detail)"
        Add-LogLine -Path (Get-DomainLogPath $domain) -Line $line.TrimEnd() -MaxKB (Get-DomainLogMaxKB $domain)
    } catch { }
    $logLevel = if ($Result -eq 'OK') { 'ok' } else { 'fail' }
    Add-ActivityLogLine -Text "$Action | $Target | $Result$(if ($Detail) { " | $Detail" })" -Level $logLevel
}
#endregion

#region -- Get-OperationLog ---------------------------------------------------
function Get-OperationLog {
    <#
    .SYNOPSIS
        Returns the connected domain's logged actions from the last N days
        (N=1 means today), oldest first. Each entry: Timestamp, Machine,
        Action, Admin, Domain, Target, Result, Detail. Reads both the current
        line format and older lines without offset/machine.
    #>
    param(
        [PSCustomObject]$Context,
        [int]$LastNDays = 7
    )
    $entries = [System.Collections.Generic.List[PSCustomObject]]::new()
    try {
        $ctx    = if ($Context) { $Context } elseif ($script:Context) { $script:Context } else { $null }
        $domain = if ($ctx -and $ctx.Domain) { [string]$ctx.Domain } elseif ($env:USERDNSDOMAIN) { $env:USERDNSDOMAIN } else { '' }
        $path   = Get-DomainLogPath $domain
        if (-not (Test-Path $path)) { return $entries }

        $days    = [Math]::Max($LastNDays, 1)
        $cutoff  = (Get-Date).Date.AddDays(-($days - 1))
        $pattern = '^\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})(?: [+-]\d{2}:\d{2})?\] (?:\[([^\]]+)\] )?\[ACTION: ([^\]]+)\] \[Admin: ([^\]]+)\] \[Domain: ([^\]]*)\] \[Target: ([^\]]*)\] \[Result: ([^\]]+)\] ?(.*)'
        $culture = [System.Globalization.CultureInfo]::InvariantCulture
        foreach ($line in [System.IO.File]::ReadAllLines($path, [System.Text.Encoding]::UTF8)) {
            if ($line -notmatch $pattern) { continue }
            $when = [datetime]::ParseExact($Matches[1], 'yyyy-MM-dd HH:mm:ss', $culture)
            if ($when -lt $cutoff) { continue }
            $entries.Add([PSCustomObject]@{
                Timestamp = $Matches[1]; Machine = [string]$Matches[2]
                Action    = $Matches[3]; Admin   = $Matches[4]; Domain = $Matches[5]
                Target    = $Matches[6]; Result  = $Matches[7]; Detail = $Matches[8]
            })
        }
    } catch { }
    return $entries
}
#endregion

Export-ModuleMember -Function `
    Write-OperationLog, `
    Get-OperationLog, `
    Write-SessionLog, `
    Reset-LogSettingsCache, `
    Initialize-LogStore, `
    Add-ActivityLogLine, `
    Register-ActivityLogTarget, `
    Backfill-ActivityLogTarget
