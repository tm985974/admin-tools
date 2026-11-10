# Services_Runner.psm1   (LITE TIER)
#
# Runs a library entry IN-PROCESS, in a fresh background runspace, so a bad
# function cannot break the app and the window keeps painting. No .ps1 file and
# no other PowerShell process is ever started.
#
#   $run = Start-LibraryRun -Entry $e -CallText 'Get-Thing -Name ''x''' -Variables @{...}
#              [-ComputerName a,b] [-RemoteCredential $cred]
#   Receive-LibraryRun -Run $run      -> new stream records since the last call
#                                         (Kind: Output | Error | Warning | Verbose | Info | Host)
#   $run.IsDone / $run.State / $run.Results (output objects) / $run.Elapsed
#   Stop-LibraryRun -Run $run
#   Complete-LibraryRun -Run $run     (disposes; call once IsDone)
#
# Local run:   <entry code>  then  <call>
# Remote run:  Invoke-Command -ComputerName ... -ScriptBlock { <entry code>; <call> }
#              (every result gets PSComputerName; unreachable computers come
#              back as errors naming the computer)

# A minimal PowerShell host for runs: captures what commands write to the host
# (WhatIf messages, Write-Host, Out-Host) and turns any request for typed input
# (Read-Host, a credential prompt, -Confirm) into a clear error instead of a
# hang. C# 5 syntax so Windows PowerShell 5.1's Add-Type compiles it.
$script:RunHostSource = @'
using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Globalization;
using System.Management.Automation;
using System.Management.Automation.Host;
using System.Text;

namespace CommandLibraryRunHost
{
    public class CaptureRawUI : PSHostRawUserInterface
    {
        private Size _buffer = new Size(220, 9999);
        public override ConsoleColor BackgroundColor { get { return ConsoleColor.Black; } set { } }
        public override ConsoleColor ForegroundColor { get { return ConsoleColor.Gray; } set { } }
        public override Size BufferSize { get { return _buffer; } set { _buffer = value; } }
        public override Coordinates CursorPosition { get { return new Coordinates(0, 0); } set { } }
        public override int CursorSize { get { return 1; } set { } }
        public override bool KeyAvailable { get { return false; } }
        public override Size MaxPhysicalWindowSize { get { return new Size(220, 200); } }
        public override Size MaxWindowSize { get { return new Size(220, 200); } }
        public override Coordinates WindowPosition { get { return new Coordinates(0, 0); } set { } }
        public override Size WindowSize { get { return new Size(220, 50); } set { } }
        public override string WindowTitle { get { return "Command Library"; } set { } }
        public override void FlushInputBuffer() { }
        public override BufferCell[,] GetBufferContents(Rectangle rectangle) { return new BufferCell[0, 0]; }
        public override KeyInfo ReadKey(ReadKeyOptions options) { throw new PSInvalidOperationException("This command waited for a key press, which a library run cannot give it."); }
        public override void ScrollBufferContents(Rectangle source, Coordinates destination, Rectangle clip, BufferCell fill) { }
        public override void SetBufferContents(Coordinates origin, BufferCell[,] contents) { }
        public override void SetBufferContents(Rectangle rectangle, BufferCell fill) { }
    }

    public class CaptureUI : PSHostUserInterface
    {
        private readonly object _lock = new object();
        private readonly List<string> _lines = new List<string>();
        private readonly StringBuilder _partial = new StringBuilder();
        private readonly CaptureRawUI _raw = new CaptureRawUI();

        public override PSHostRawUserInterface RawUI { get { return _raw; } }

        public string[] TakeLines()
        {
            lock (_lock) { string[] a = _lines.ToArray(); _lines.Clear(); return a; }
        }
        public string TakePartial()
        {
            lock (_lock) { string p = _partial.ToString(); _partial.Length = 0; return p; }
        }
        private void Add(string text, bool newLine)
        {
            lock (_lock)
            {
                _partial.Append(text ?? "");
                if (!newLine) return;
                foreach (string l in _partial.ToString().Replace("\r\n", "\n").Split('\n')) _lines.Add(l);
                _partial.Length = 0;
            }
        }
        public override void Write(string value) { Add(value, false); }
        public override void Write(ConsoleColor foregroundColor, ConsoleColor backgroundColor, string value) { Add(value, false); }
        public override void WriteLine(string value) { Add(value, true); }
        public override void WriteLine() { Add("", true); }
        public override void WriteLine(ConsoleColor foregroundColor, ConsoleColor backgroundColor, string value) { Add(value, true); }
        public override void WriteDebugLine(string message) { }
        public override void WriteErrorLine(string value) { }
        public override void WriteVerboseLine(string message) { }
        public override void WriteWarningLine(string message) { }
        public override void WriteProgress(long sourceId, ProgressRecord record) { }

        public override string ReadLine() { throw new PSInvalidOperationException("This command asked for typed input (Read-Host). Give the value as a parameter instead - a library run cannot answer prompts."); }
        public override System.Security.SecureString ReadLineAsSecureString() { throw new PSInvalidOperationException("This command asked for a typed password (Read-Host -AsSecureString). Use a credential or SecureString parameter instead."); }
        public override Dictionary<string, PSObject> Prompt(string caption, string message, Collection<FieldDescription> descriptions)
        {
            StringBuilder names = new StringBuilder();
            foreach (FieldDescription d in descriptions) { if (names.Length > 0) names.Append(", "); names.Append(d.Name); }
            throw new PSInvalidOperationException("This command prompted for: " + names.ToString() + ". Mandatory parameters must be filled in the Run dialog.");
        }
        public override PSCredential PromptForCredential(string caption, string message, string userName, string targetName)
        { throw new PSInvalidOperationException("This command asked for a credential (Get-Credential). Use its Credential parameter instead."); }
        public override PSCredential PromptForCredential(string caption, string message, string userName, string targetName, PSCredentialTypes allowedCredentialTypes, PSCredentialUIOptions options)
        { throw new PSInvalidOperationException("This command asked for a credential (Get-Credential). Use its Credential parameter instead."); }
        public override int PromptForChoice(string caption, string message, Collection<ChoiceDescription> choices, int defaultChoice)
        { throw new PSInvalidOperationException("This command asked for confirmation (" + caption + ": " + message + "). Use WhatIf to preview, or run it without -Confirm."); }
    }

    public class CaptureHost : PSHost
    {
        private readonly Guid _id = Guid.NewGuid();
        private readonly CaptureUI _ui = new CaptureUI();
        private readonly CultureInfo _culture = CultureInfo.CurrentCulture;
        private readonly CultureInfo _uiCulture = CultureInfo.CurrentUICulture;
        public int? ExitCode;
        public CaptureUI Capture { get { return _ui; } }
        public override CultureInfo CurrentCulture { get { return _culture; } }
        public override CultureInfo CurrentUICulture { get { return _uiCulture; } }
        public override Guid InstanceId { get { return _id; } }
        public override string Name { get { return "CommandLibraryRunHost"; } }
        public override PSHostUserInterface UI { get { return _ui; } }
        public override Version Version { get { return new Version(1, 0); } }
        public override void EnterNestedPrompt() { throw new PSInvalidOperationException("Nested prompts are not available in a library run."); }
        public override void ExitNestedPrompt() { }
        public override void NotifyBeginApplication() { }
        public override void NotifyEndApplication() { }
        public override void SetShouldExit(int exitCode) { ExitCode = exitCode; }
    }
}
'@

function Initialize-LibraryRunHost {
    if ('CommandLibraryRunHost.CaptureHost' -as [type]) { return $true }
    try { Add-Type -TypeDefinition $script:RunHostSource -Language CSharp -ErrorAction Stop; return $true }
    catch { $script:RunHostError = $_.Exception.Message; return $false }
}

# Code that picks and runs one of several methods (primary + fallbacks), with
# an optional reachability check of the target hosts first. Plan items:
#   Label, Code (defined before the call), CallText, Commands (to look for), Ports
# Every name and label goes in as a literal, so the same text runs locally or
# inside Invoke-Command on another computer.
function New-LibraryPlanScript {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [object[]]$Plan, [string[]]$Hosts = @(), [switch]$Fallback, [switch]$NoHostCheck, [switch]$Force)
    $lit = { param($a) '@(' + ((@($a) | Where-Object { $null -ne $_ } | ForEach-Object { ConvertTo-LibraryLiteral ([string]$_) }) -join ', ') + ')' }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine((Get-LibraryRunPreamble))
    [void]$sb.AppendLine('$__plan = @(')
    foreach ($m in $Plan) {
        [void]$sb.AppendLine("    @{ Label = $(ConvertTo-LibraryLiteral ([string]$m.Label)); Commands = $(& $lit $m.Commands); Ports = @($((@($m.Ports) | ForEach-Object { [int]$_ }) -join ', ')) }")
    }
    [void]$sb.AppendLine(')')
    $h = if ($NoHostCheck) { '@()' } else { & $lit $Hosts }
    [void]$sb.AppendLine("`$__hosts = $h")
    [void]$sb.AppendLine("`$__fallback = `$$([bool]$Fallback)")
    [void]$sb.AppendLine("`$__force = `$$([bool]$Force)")
    [void]$sb.AppendLine(@'
$__usable = New-Object System.Collections.Generic.List[int]
$__why = New-Object System.Collections.Generic.List[string]
$__checked = @{}
for ($__i = 0; $__i -lt $__plan.Count; $__i++) {
    $__m = $__plan[$__i]
    $__miss = @($__m.Commands | Where-Object { -not (Get-Command $_ -ErrorAction SilentlyContinue) })
    if ($__miss.Count) { $__why.Add("$($__m.Label): not installed here ($($__miss -join ', '))"); if ($__plan.Count -gt 1) { Write-Host "[CHECK] $($__m.Label) - not installed here: $($__miss -join ', ')" }; continue }
    if ($__hosts.Count -and $__m.Ports.Count) {
        $__key = ($__m.Ports -join ',')
        if (-not $__checked.ContainsKey($__key)) {
            $__checked[$__key] = @(Test-LibraryHostPorts -Hosts $__hosts -Ports $__m.Ports)
            foreach ($__c in $__checked[$__key]) { Write-Host "[CHECK] $($__c.Text)" }
        }
        $__bad = @($__checked[$__key] | Where-Object { $_.Status -ne 'OK' })
        if ($__bad.Count -eq @($__checked[$__key]).Count) { $__why.Add("$($__m.Label): " + (@($__bad | ForEach-Object { $_.Text }) -join '; ')); continue }
    }
    $__usable.Add($__i)
}
if ($__usable.Count -eq 0) {
    if (-not $__force) { throw ("Not run - it would fail. " + ($__why -join ' | ')) }
    Write-Warning ("Running anyway: " + ($__why -join ' | '))
    $__usable.Add(0)
}
if ($__usable[0] -gt 0) { Write-Host "[METHOD] Using '$($__plan[$__usable[0]].Label)' (fallback)" }
for ($__k = 0; $__k -lt $__usable.Count; $__k++) {
    $__i = $__usable[$__k]
    $__methodUsed = $__i
    try {
'@)
    for ($i = 0; $i -lt $Plan.Count; $i++) {
        $kw = if ($i -eq 0) { 'if' } else { 'elseif' }
        [void]$sb.AppendLine("        $kw (`$__i -eq $i) {")
        if ($Plan[$i].Code) { [void]$sb.AppendLine([string]$Plan[$i].Code) }
        [void]$sb.AppendLine([string]$Plan[$i].CallText)
        [void]$sb.AppendLine('        }')
    }
    [void]$sb.AppendLine(@'
        break
    }
    catch {
        if ($__fallback -and $__k -lt $__usable.Count - 1 -and (Test-LibraryEnvFailure $_)) {
            Write-Warning "'$($__plan[$__i].Label)' failed: $($_.Exception.Message)"
            Write-Host "[METHOD] Trying '$($__plan[$__usable[$__k + 1]].Label)' instead"
            continue
        }
        throw
    }
}
'@)
    return $sb.ToString()
}

function Start-LibraryRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Entry,
        [Parameter(Mandatory)] [string]$CallText,
        [hashtable]$Variables = @{},
        [string[]]$ComputerName = @(),
        [System.Management.Automation.PSCredential]$RemoteCredential,
        [int]$ThrottleLimit = 16,
        # optional: methods to choose from (Label, Code, CallText, Commands, Ports); the first is CallText's
        [object[]]$Plan = @(),
        # hosts typed into the target fields (checked before a local run)
        [string[]]$Hosts = @(),
        # check hosts / WinRM before running
        [switch]$PreCheck,
        # move on to the next method after an environment failure (read-only entries)
        [switch]$Fallback,
        # run even when the checks say it will fail ("Run anyway")
        [switch]$Force
    )

    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    $runHost = $null
    if (Initialize-LibraryRunHost) { $runHost = New-Object CommandLibraryRunHost.CaptureHost }
    $rs = if ($runHost) { [runspacefactory]::CreateRunspace($runHost, $iss) } else { [runspacefactory]::CreateRunspace($iss) }
    $rs.ApartmentState = [System.Threading.ApartmentState]::STA
    $rs.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
    $rs.Open()

    $code = Get-LibraryEntryRunCode -Entry $Entry
    # command entries: run "| Select-Object" instead of a trailing Format-*, format only for display
    $runText = $CallText; $format = ''
    if (Test-LibraryCommandEntry $Entry) { $sp = Split-LibraryTrailingFormat -Text $CallText; $runText = $sp.Text; $format = $sp.Format }
    $targets = @($ComputerName | Where-Object { $_ } | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Sort-Object -Unique)

    # the methods to run: just this call, or a plan with fallbacks / host checks
    $steps = @(); $formats = @()
    if (@($Plan).Count -gt 1 -or ($PreCheck -and @($Hosts).Count -gt 0 -and $targets.Count -eq 0)) {
        $steps = foreach ($m in @($Plan)) {
            # fallbacks are templates: run "| Select-Object" for a trailing Format-*, like command entries
            $sp = Split-LibraryTrailingFormat -Text ([string]$m.CallText)
            [pscustomobject]@{ Label = $m.Label; Code = $m.Code; CallText = $sp.Text; Commands = @($m.Commands); Ports = @($m.Ports) }
        }
        if (@($steps).Count -eq 0) {
            $steps = @([pscustomobject]@{ Label = [string]$Entry.Function; Code = $code; CallText = $runText; Commands = @(); Ports = @() })
        }
        $steps[0].Code = $code; $steps[0].CallText = $runText
        # each method shows its results with its own Format-Table columns; the one
        # that ran is known when the run completes (remote: only if all agree)
        $formats = @(for ($i = 0; $i -lt @($steps).Count; $i++) { if ($i -eq 0) { $format } else { (Split-LibraryTrailingFormat -Text ([string]@($Plan)[$i].CallText)).Format } })
        if ($targets.Count -gt 0 -and @($formats | Select-Object -Unique).Count -gt 1) { $format = '' }
    }
    $body = if (@($steps).Count) { New-LibraryPlanScript -Plan $steps -Hosts $(if ($PreCheck) { $Hosts } else { @() }) -Fallback:$Fallback -NoHostCheck:($targets.Count -gt 0) -Force:$Force } else { $code + "`r`n" + $runText }

    if ($targets.Count -gt 0) {
        $remoteBody = "param(`$__vars)`r`nforeach (`$__k in `$__vars.Keys) { Set-Variable -Name `$__k -Value `$__vars[`$__k] }`r`n" +
                      "Remove-Variable __k, __vars -ErrorAction SilentlyContinue`r`n" + $body
        $rs.SessionStateProxy.SetVariable('__remoteBody', $remoteBody)
        $rs.SessionStateProxy.SetVariable('__targets', [string[]]$targets)
        $rs.SessionStateProxy.SetVariable('__vars', $Variables)
        $rs.SessionStateProxy.SetVariable('__throttle', $ThrottleLimit)
        $rs.SessionStateProxy.SetVariable('__cred', $RemoteCredential)
        $rs.SessionStateProxy.SetVariable('__precheck', [bool]$PreCheck)
        # unreachable computers are reported in a second and left out, instead
        # of each one waiting for a WinRM timeout
        $script = (Get-LibraryRunPreamble) + "`r`n" + @'
if ($__precheck) {
    $__chk = @(Test-LibraryHostPorts -Hosts $__targets -Ports 5985, 5986)
    $__ok = @($__chk | Where-Object { $_.Status -eq 'OK' } | ForEach-Object { $_.Host })
    foreach ($__c in @($__chk | Where-Object { $_.Status -ne 'OK' })) {
        Write-Error -Message "[$($__c.Host)] skipped - $($__c.Text -replace '^[^:]+:\s*', ''). WinRM (TCP 5985) must answer: Enable-PSRemoting on it, firewall rule 'Windows Remote Management'." -Category ConnectionError -TargetObject $__c.Host
    }
    if ($__ok.Count -eq 0) { throw 'Not run - none of the computers answered on WinRM (TCP 5985).' }
    if ($__ok.Count -lt $__targets.Count) { Write-Host "[CHECK] $($__ok.Count) of $($__targets.Count) computers answer on WinRM - running on those." }
    $__targets = [string[]]$__ok
}
$__p = @{ ComputerName = $__targets; ScriptBlock = [scriptblock]::Create($__remoteBody); ArgumentList = @(,$__vars); ThrottleLimit = $__throttle; ErrorAction = 'Continue' }
if ($__cred) { $__p.Credential = $__cred }
Invoke-Command @__p
'@
    }
    else {
        foreach ($k in $Variables.Keys) { $rs.SessionStateProxy.SetVariable($k, $Variables[$k]) }
        $script = $body
    }

    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($script)
    $output = New-Object 'System.Management.Automation.PSDataCollection[psobject]'
    $inBuf = New-Object 'System.Management.Automation.PSDataCollection[psobject]'
    $inBuf.Complete()
    $handle = $ps.BeginInvoke($inBuf, $output)

    [pscustomobject]@{
        Entry     = $Entry
        CallText  = $CallText
        Script    = $script
        Formats   = $(if ($targets.Count -eq 0) { $formats } else { @() })
        Format    = $format
        Targets   = $targets
        PS        = $ps
        Runspace  = $rs
        RunHost   = $runHost
        HostInfo  = New-Object System.Collections.Generic.List[string]
        HostPending = New-Object System.Collections.Generic.List[string]
        InfoPartial = ''
        Handle    = $handle
        Output    = $output
        Started   = Get-Date
        Seen      = @{ Output = 0; Error = 0; Warning = 0; Verbose = 0; Info = 0 }
        Stopping  = $false
        Disposed  = $false
    } | Add-Member -MemberType ScriptProperty -Name IsDone -Value { $this.Disposed -or $this.Handle.IsCompleted } -PassThru |
        Add-Member -MemberType ScriptProperty -Name State -Value { if ($this.Disposed) { 'Completed' } else { [string]$this.PS.InvocationStateInfo.State } } -PassThru |
        Add-Member -MemberType ScriptProperty -Name Elapsed -Value { (Get-Date) - $this.Started } -PassThru |
        Add-Member -MemberType ScriptProperty -Name Results -Value { @($this.Output) } -PassThru
}

# New records since the last call, oldest first within each stream.
function Receive-LibraryRun {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Run)
    $recs = New-Object System.Collections.Generic.List[object]
    if ($Run.Disposed) { return $recs.ToArray() }
    $st = $Run.PS.Streams

    $take = {
        param($kind, $coll)
        $n = $coll.Count
        for ($i = $Run.Seen[$kind]; $i -lt $n; $i++) {
            $item = $coll[$i]
            $text = switch ($kind) {
                'Error'   {
                    $where = ''
                    try { if ($item.OriginInfo -and $item.OriginInfo.PSComputerName) { $where = "[$($item.OriginInfo.PSComputerName)] " } } catch { }
                    if (-not $where) { try { if ($item.TargetObject -is [string] -and $item.FullyQualifiedErrorId -match 'PSSessionStateBroken|ComputerNotFound|CannotConnect|WinRM|PSRemotingTransportException') { $where = "[$($item.TargetObject)] " } } catch { } }
                    $where + [string]$item.Exception.Message
                }
                'Info'    { [string]$item.MessageData }
                'Output'  { $null }
                default   { [string]$item.Message }
            }
            $recs.Add([pscustomobject]@{ Kind = $kind; Text = $text; Object = $item })
        }
        $Run.Seen[$kind] = $n
    }
    & $take 'Output'  $Run.Output
    & $take 'Error'   $st.Error
    & $take 'Warning' $st.Warning
    & $take 'Verbose' $st.Verbose
    try { & $take 'Info' $st.Information } catch { }

    # Write-Host lands in the Information stream (tag PSHOST) AND, with the run
    # host, in the host output. Write-Host pieces (-NoNewline) are joined into
    # lines; a host line equal to such a line is shown once. Unmatched host lines
    # (WhatIf messages, Out-Host) wait one poll, in case their Information
    # record arrives a moment later.
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($r in $recs) {
        $isHostInfo = $false
        if ($r.Kind -eq 'Info') {
            try {
                if (@($r.Object.Tags) -contains 'PSHOST') {
                    $isHostInfo = $true
                    $Run.InfoPartial += [string]$r.Text
                    $noNl = $false
                    try { $noNl = [bool]$r.Object.MessageData.NoNewLine } catch { }
                    if (-not $noNl) {
                        $line = $Run.InfoPartial; $Run.InfoPartial = ''
                        $j = $Run.HostPending.IndexOf($line)
                        if ($j -ge 0) { $Run.HostPending.RemoveAt($j) } else { $Run.HostInfo.Add($line) }
                        $out.Add([pscustomobject]@{ Kind = 'Info'; Text = $line; Object = $r.Object })
                    }
                }
            } catch { }
        }
        if (-not $isHostInfo) { $out.Add($r) }
    }
    if ($Run.RunHost) {
        $done = $Run.Handle.IsCompleted
        # last poll's unmatched host lines are shown now
        foreach ($l in @($Run.HostPending)) { $out.Add([pscustomobject]@{ Kind = 'Host'; Text = [string]$l; Object = $null }) }
        $Run.HostPending.Clear()
        $lines = @($Run.RunHost.Capture.TakeLines())
        if ($done) { $p = $Run.RunHost.Capture.TakePartial(); if ($p) { $lines += $p } }
        foreach ($l in $lines) {
            $i = $Run.HostInfo.IndexOf([string]$l)
            if ($i -ge 0) { $Run.HostInfo.RemoveAt($i); continue }
            if ($done) { $out.Add([pscustomobject]@{ Kind = 'Host'; Text = [string]$l; Object = $null }) }
            else { $Run.HostPending.Add([string]$l) }
        }
        if ($Run.HostInfo.Count -gt 500) { $Run.HostInfo.RemoveRange(0, $Run.HostInfo.Count - 500) }
    }
    if ($Run.Handle.IsCompleted -and $Run.InfoPartial) { $out.Add([pscustomobject]@{ Kind = 'Info'; Text = $Run.InfoPartial; Object = $null }); $Run.InfoPartial = '' }
    return $out.ToArray()
}

function Stop-LibraryRun {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Run)
    if ($Run.Disposed -or $Run.Handle.IsCompleted -or $Run.Stopping) { return }
    $Run.Stopping = $true
    try { [void]$Run.PS.BeginStop($null, $null) } catch { }
}

# Ends the invocation and frees the runspace. Returns the terminating error
# message, if the run failed as a whole (a throw, a parse error, Stop).
function Complete-LibraryRun {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Run)
    if ($Run.Disposed) { return '' }
    $msg = ''
    try { [void]$Run.PS.EndInvoke($Run.Handle) }
    catch {
        $ex = $_.Exception
        while ($ex.InnerException -and $ex -is [System.Management.Automation.MethodInvocationException]) { $ex = $ex.InnerException }
        $msg = [string]$ex.Message
    }
    if ($Run.Stopping) { $msg = 'Stopped.' }
    # which method of a plan ran: show its results with its own columns
    if (@($Run.Formats).Count -gt 1) {
        try {
            $used = $Run.Runspace.SessionStateProxy.GetVariable('__methodUsed')
            if ($null -ne $used -and [int]$used -lt @($Run.Formats).Count) { $Run.Format = [string]@($Run.Formats)[[int]$used]; $Run | Add-Member -NotePropertyName MethodUsed -NotePropertyValue ([int]$used) -Force }
        } catch { }
    }
    $Run | Add-Member -NotePropertyName FinalState -NotePropertyValue ([string]$Run.PS.InvocationStateInfo.State) -Force
    $Run | Add-Member -NotePropertyName Finished -NotePropertyValue (Get-Date) -Force
    $Run | Add-Member -NotePropertyName ResultsCache -NotePropertyValue (@($Run.Output)) -Force
    try { $Run.PS.Dispose() } catch { }
    try { $Run.Runspace.Dispose() } catch { }
    $Run.Disposed = $true
    $Run | Add-Member -MemberType ScriptProperty -Name Results -Value { @($this.ResultsCache) } -Force
    $Run | Add-Member -MemberType ScriptProperty -Name Elapsed -Value { $this.Finished - $this.Started } -Force
    return $msg
}

# Results as text the way the console would show them.
function Format-LibraryResults {
    [CmdletBinding()]
    param([object[]]$Results = @(), [int]$Width = 220, [string]$Format = '')
    if (@($Results).Count -eq 0) { return '' }
    if ($Format) {
        try { $sb = [scriptblock]::Create('param($__r) $__r | ' + $Format); return ((& $sb @($Results)) | Out-String -Width $Width).TrimEnd() } catch { }
    }
    try { return (@($Results) | Out-String -Width $Width).TrimEnd() }
    catch { return (@($Results) | ForEach-Object { [string]$_ }) -join [Environment]::NewLine }
}

# Results as a DataTable for a grid (one column per property, union of the
# first 200 objects; plain values get one 'Value' column).
function ConvertTo-LibraryDataTable {
    [CmdletBinding()]
    param([object[]]$Results = @())
    $dt = New-Object System.Data.DataTable
    $items = @($Results | Where-Object { $null -ne $_ })
    if ($items.Count -eq 0) { return ,$dt }
    # already-formatted output (Format-Table / Format-List in the command): one row per text line
    if (@($items | Where-Object { $_.PSObject.TypeNames[0] -like 'Microsoft.PowerShell.Commands.Internal.Format.*' }).Count -eq $items.Count) {
        [void]$dt.Columns.Add('Output', [string])
        foreach ($l in ((@($items) | Out-String -Width 400) -split "`r?`n")) { if ($l.Trim()) { $row = $dt.NewRow(); $row['Output'] = $l.TrimEnd(); [void]$dt.Rows.Add($row) } }
        return ,$dt
    }
    $scalar = { param($o) $b = $o; if ($o -is [psobject]) { $b = $o.PSObject.BaseObject }; ($b -is [string]) -or ($b -is [ValueType]) }
    $cols = New-Object System.Collections.Generic.List[string]
    $hide = @('PSShowComputerName', 'RunspaceId', 'PSSourceJobInstanceId')
    foreach ($o in ($items | Select-Object -First 200)) {
        if (& $scalar $o) { if (-not $cols.Contains('Value')) { $cols.Add('Value') }; continue }
        foreach ($p in $o.PSObject.Properties) {
            if ($p.MemberType -notin @('NoteProperty', 'Property', 'AliasProperty', 'ScriptProperty', 'CodeProperty')) { continue }
            if ($hide -contains $p.Name) { continue }
            if (-not $cols.Contains($p.Name)) { $cols.Add($p.Name) }
        }
    }
    # PSComputerName first when present (remote runs)
    if ($cols.Contains('PSComputerName')) { $cols.Remove('PSComputerName') | Out-Null; $cols.Insert(0, 'PSComputerName') }
    foreach ($c in $cols) { [void]$dt.Columns.Add($c, [string]) }
    foreach ($o in $items) {
        $row = $dt.NewRow()
        if (& $scalar $o) { $row['Value'] = [string]$o }
        else {
            foreach ($c in $cols) {
                $v = $null
                try { $v = $o.$c } catch { }
                if ($null -eq $v) { continue }
                if ($v -is [System.Collections.IEnumerable] -and -not ($v -is [string])) { $v = (@($v) | ForEach-Object { [string]$_ }) -join '; ' }
                $row[$c] = [string]$v
            }
        }
        $dt.Rows.Add($row)
    }
    return ,$dt
}

# Checks the entry's required modules are available before a LOCAL run.
function Test-LibraryRequirements {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Entry)
    $missing = @()
    foreach ($m in @($Entry.Modules)) {
        if (-not $m) { continue }
        if (-not (Get-Module -ListAvailable -Name $m -ErrorAction SilentlyContinue)) { $missing += $m }
    }
    return $missing
}
