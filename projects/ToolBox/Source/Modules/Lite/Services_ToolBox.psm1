# Services_ToolBox.psm1   (LITE TIER)
#
# The logic behind the Tools, Developer and Update tabs. No UI here.
#
#   Get-TbFolders  -App            Projects / Repo / Self folders
#   Get-TbProjects -App            every tool in the projects folder, with versions and status
#   Get-TbRunning  -Project $p     the tool's EXEs that are running now (names)
#   Start-TbBuild  -App -Projects [-LiteUser -LiteAdmin]
#                                  run each tool's Build-App.cmd, one at a time, in the
#                                  background (a WinForms timer follows it; output -> log).
#                                  With the passwords, each build also makes the tool's
#                                  <ExeName>Lite.exe (the sealed build) - the same for all.
#   Show-TbLitePasswordDialog      asks once for those passwords (or: no Lite EXEs)
#   Stop-TbBuild                   finish the tool being built, skip the rest
#   Test-TbBuilding
#   Register-TbView -Refresh {} / -Log { param($text) } / -BuildState { param($busy) }
#   Invoke-TbRefresh               tell every tab to re-read the tools
#   Get-TbZipOpenCode / Get-TbZipInfo / Get-TbZipApplyCode   Update from zip
#
# A tool = a folder in the projects folder with Source\AppIdentity.json (template 1.1
# layout) - new tools appear on their own.

$script:TbViews = @{ Refresh = (New-Object System.Collections.ArrayList); Log = (New-Object System.Collections.ArrayList); BuildState = (New-Object System.Collections.ArrayList) }
$script:TbBuild = $null

# ---------------------------------------------------------------- folders ---

function Get-TbFolders {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $App)
    $self = Split-Path -Parent ([string]$App.ExePath)
    $projects = ([string]$App.GetSetting('ProjectsFolder')).Trim()
    if (-not $projects) { $projects = Split-Path -Parent $self }
    $projects = $projects.TrimEnd('\')
    $repo = ''
    if ((Split-Path -Leaf $projects) -eq 'projects') { $repo = Split-Path -Parent $projects }
    [pscustomobject]@{
        Projects = $projects
        Repo     = $repo                                  # '' when the projects folder is not admin-tools\projects
        Self     = $self
        IsGit    = [bool]($repo -and (Test-Path -LiteralPath (Join-Path $repo '.git')))
    }
}

# ------------------------------------------------------------- the tools ---

function Get-TbExeInfo {
    [CmdletBinding()]
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{ Exists = $false; Version = ''; Time = $null; Path = $Path }
    }
    $v = ''
    try {
        $fv = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($Path)
        $v = [string]$fv.ProductVersion
        if (-not $v) { $v = [string]$fv.FileVersion }
        $parts = @($v.Split('.') | Select-Object -First 3)
        $v = $parts -join '.'
    } catch { }
    [pscustomobject]@{ Exists = $true; Version = $v; Time = (Get-Item -LiteralPath $Path).LastWriteTime; Path = $Path }
}

function Read-TbText {
    param([string]$Path)
    try { if (Test-Path -LiteralPath $Path) { return ([System.IO.File]::ReadAllText($Path)).Trim().TrimStart([char]0xFEFF) } } catch { }
    return ''
}

function Get-TbProjects {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $App)
    $f = Get-TbFolders -App $App
    if (-not (Test-Path -LiteralPath $f.Projects -PathType Container)) { return @() }
    $list = foreach ($d in @(Get-ChildItem -LiteralPath $f.Projects -Directory | Sort-Object Name)) {
        $src = Join-Path $d.FullName 'Source'
        $idPath = Join-Path $src 'AppIdentity.json'
        if (-not (Test-Path -LiteralPath $idPath)) { continue }
        try { $id = [System.IO.File]::ReadAllText($idPath) | ConvertFrom-Json } catch { continue }
        $exeName = [string]$id.ExeName
        if (-not $exeName) { continue }
        $dev  = Get-TbExeInfo (Join-Path $d.FullName ($exeName + 'Dev.exe'))      # template 1.1.2: <ExeName>Dev.exe
        $lite = Get-TbExeInfo (Join-Path $d.FullName ($exeName + 'Lite.exe'))
        $srcVer = Read-TbText (Join-Path $src 'VERSION.txt')
        $newest = $null
        try { $newest = (Get-ChildItem -LiteralPath $src -Recurse -File | Measure-Object -Property LastWriteTime -Maximum).Maximum } catch { }

        $status = 'Up to date'
        if (-not $dev.Exists) { $status = 'Not built' }
        elseif ($srcVer -and $dev.Version -and $srcVer -ne $dev.Version) { $status = "Needs build (v$($dev.Version) -> v$srcVer)" }
        elseif ($newest -and $dev.Time -and $newest -gt $dev.Time.AddSeconds(5)) { $status = 'Source changed since build' }
        $liteState = $(if (-not $lite.Exists) { 'none' } elseif ($dev.Exists -and $lite.Version -ne $dev.Version) { 'older' } else { 'current' })
        [pscustomobject]@{
            Name          = $d.Name
            AppName       = $(if ($id.AppName) { [string]$id.AppName } else { $d.Name })
            ExeName       = $exeName
            Folder        = $d.FullName
            BuildCmd      = (Join-Path $d.FullName 'Build-App.cmd')
            SourceVersion = $srcVer
            Dev           = $dev
            Lite          = $lite
            LiteState     = $liteState                     # none | older (than the Dev build) | current
            IsSelf        = ($d.FullName.TrimEnd('\') -eq $f.Self.TrimEnd('\'))
            Status        = $status
            NeedsBuild    = ($status -ne 'Up to date')
        }
    }
    return @($list)
}

function Get-TbRunning {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Project)
    $names = @(($Project.ExeName + 'Dev'), ($Project.ExeName + 'Lite'), $Project.ExeName)   # (+ a pre-1.1.2 <ExeName>.exe)
    $hits = @(Get-Process -Name $names -ErrorAction SilentlyContinue | Where-Object {
        $p = ''; try { $p = [string]$_.Path } catch { }
        $p -and $p.StartsWith($Project.Folder, [System.StringComparison]::OrdinalIgnoreCase)
    })
    return @($hits | ForEach-Object { $_.ProcessName + '.exe' } | Select-Object -Unique)
}

# ------------------------------------------------------------- the views ---

function Register-TbView {
    [CmdletBinding()]
    param([scriptblock]$Refresh, [scriptblock]$Log, [scriptblock]$BuildState)
    if ($Refresh)    { [void]$script:TbViews.Refresh.Add($Refresh) }
    if ($Log)        { [void]$script:TbViews.Log.Add($Log) }
    if ($BuildState) { [void]$script:TbViews.BuildState.Add($BuildState) }
}

function Invoke-TbRefresh { foreach ($r in @($script:TbViews.Refresh)) { try { & $r } catch { } } }
function Write-TbLog { param([string]$Text) foreach ($l in @($script:TbViews.Log)) { try { & $l $Text } catch { } } }
function Set-TbBuildState { param([bool]$Busy) foreach ($b in @($script:TbViews.BuildState)) { try { & $b $Busy } catch { } } }

# ----------------------------------------------------------------- builds ---

# The cmd.exe line that builds one tool: its Build-App.cmd without the closing
# pause, with input from NUL (so an error "pause" inside it cannot wait forever)
# and the output into a log file that the timer below reads.
function Get-TbBuildArguments {
    param([string]$BuildCmd, [string]$LogFile)
    return ('/d /s /c ""{0}" -NoPause <NUL >"{1}" 2>&1"' -f $BuildCmd, $LogFile)
}

# The command window text for building these tools.
function Get-TbBuildCode {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $App, [Parameter(Mandatory)] $Projects, [switch]$Lite)
    $logDir = Join-Path ([string]$App.DataRoot) 'Logs'
    $lines = @('# One tool at a time; the output appears in the Developer tab''s log.')
    if ($Lite) {
        $lines += '# The Lite (sealed) passwords go to each build in these variables - never shown or logged:'
        $lines += '$env:APPTEMPLATE_LITE_USER  = Read-Host -Prompt ''User password''    # typed in the dialog'
        $lines += '$env:APPTEMPLATE_LITE_ADMIN = Read-Host -Prompt ''Admin password''   # typed in the dialog'
    }
    else { $lines += '# No Lite EXEs this time (no passwords): developer builds only.' }
    foreach ($p in @($Projects)) {
        $log = Join-Path $logDir ('Build_' + $p.Name + '.log')
        $lines += 'Start-Process -FilePath cmd.exe -ArgumentList ' + (Format-AppCommandValue (Get-TbBuildArguments -BuildCmd $p.BuildCmd -LogFile $log)) + ' -WindowStyle Hidden -Wait'
    }
    return ($lines -join "`r`n")
}

function Test-TbBuilding { return [bool]($script:TbBuild -and -not $script:TbBuild.Finished) }

function Stop-TbBuild {
    if (-not (Test-TbBuilding)) { return }
    $script:TbBuild.Queue.Clear()
    Write-TbLog '---- Stop: the tool being built finishes; the rest are skipped.'
}

function Start-TbBuild {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $App, [Parameter(Mandatory)] $Projects, [string]$LiteUser = '', [string]$LiteAdmin = '')
    if (Test-TbBuilding) { $App.SetStatus('A build is already running.', 'warn'); return }
    $queue = New-Object System.Collections.Generic.Queue[object]
    foreach ($p in @($Projects)) { $queue.Enqueue($p) }
    if ($queue.Count -eq 0) { return }
    $logDir = Join-Path ([string]$App.DataRoot) 'Logs'
    if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    $st = @{
        App = $App; Queue = $queue; Current = $null; Proc = $null; LogFile = ''; Pos = [long]0
        Ok = 0; Failed = (New-Object System.Collections.ArrayList); Skipped = (New-Object System.Collections.ArrayList)
        Finished = $false; Timer = (New-Object System.Windows.Forms.Timer); LogDir = $logDir; Started = (Get-Date)
        LiteUser = $LiteUser; LiteAdmin = $LiteAdmin      # kept only while the builds run
    }
    $script:TbBuild = $st
    $tickFn = ${function:Invoke-TbBuildTick}       # captured: closures do not see module functions reliably
    $st.Timer.Interval = 400
    $st.Timer.Add_Tick({
        try { & $tickFn $st }
        catch {
            try { $st.Timer.Stop() } catch { }
            $st.Finished = $true
            try { $st.App.Log('ERROR', 'Build', "build runner: $($_.Exception.ToString())") } catch { }
        }
    }.GetNewClosure())
    Set-TbBuildState $true
    Write-TbLog ("==== Build started: {0} tool(s){1}" -f $queue.Count, $(if ($LiteUser) { ', with Lite (sealed) EXEs' } else { ', developer builds only (no Lite EXEs)' }))
    $App.Log('INFO', 'Build', "Build started: $(@($Projects | ForEach-Object { $_.Name }) -join ', ')")
    $st.Timer.Start()
}

function Read-TbLogTail {
    param($State)
    if (-not $State.LogFile -or -not (Test-Path -LiteralPath $State.LogFile)) { return }
    try {
        $fs = New-Object System.IO.FileStream($State.LogFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            if ($fs.Length -le $State.Pos) { return }
            [void]$fs.Seek($State.Pos, [System.IO.SeekOrigin]::Begin)
            $buf = New-Object byte[] ($fs.Length - $State.Pos)
            $n = $fs.Read($buf, 0, $buf.Length)
            $State.Pos += $n
            $text = [System.Text.Encoding]::Default.GetString($buf, 0, $n)
            if ($text) { Write-TbLog ($text.TrimEnd("`r", "`n")) }
        } finally { $fs.Dispose() }
    } catch { }
}

function Invoke-TbBuildTick {
    param($State)
    $State.Timer.Stop()
    try {
        # ---- the tool being built ----
        if ($State.Proc) {
            Read-TbLogTail $State
            if (-not $State.Proc.HasExited) { return }
            $code = $State.Proc.ExitCode
            Read-TbLogTail $State
            $name = $State.Current.Name
            if ($code -eq 0) { $State.Ok++; Write-TbLog "---- $name : built." }
            else { [void]$State.Failed.Add($name); Write-TbLog "---- $name : FAILED (exit $code) - see the lines above." }
            $State.App.Log($(if ($code -eq 0) { 'INFO' } else { 'WARN' }), 'Build', "$name : exit $code")
            try { $State.Proc.Dispose() } catch { }
            $State.Proc = $null; $State.Current = $null
            Invoke-TbRefresh
        }

        # ---- the next one ----
        while (-not $State.Proc -and $State.Queue.Count -gt 0) {
            $p = $State.Queue.Dequeue()
            if ($p.IsSelf) {
                [void]$State.Skipped.Add($p.Name)
                Write-TbLog "---- $($p.Name) : skipped - ToolBox cannot rebuild itself while it is running. Close it and run its Build-App.cmd (or Build-All.cmd)."
                continue
            }
            $running = @(Get-TbRunning -Project $p)
            if ($running.Count) {
                [void]$State.Skipped.Add($p.Name)
                Write-TbLog "---- $($p.Name) : skipped - close $($running -join ', ') first (a running EXE cannot be replaced)."
                continue
            }
            if (-not (Test-Path -LiteralPath $p.BuildCmd)) {
                [void]$State.Failed.Add($p.Name)
                Write-TbLog "---- $($p.Name) : no Build-App.cmd in $($p.Folder)."
                continue
            }
            $State.LogFile = Join-Path $State.LogDir ('Build_' + $p.Name + '.log')
            $State.Pos = [long]0
            if (Test-Path -LiteralPath $State.LogFile) { Remove-Item -LiteralPath $State.LogFile -Force -ErrorAction SilentlyContinue }
            Write-TbLog ""
            Write-TbLog "==== $($p.Name) (source v$($p.SourceVersion))"
            $psi = New-Object System.Diagnostics.ProcessStartInfo('cmd.exe', (Get-TbBuildArguments -BuildCmd $p.BuildCmd -LogFile $State.LogFile))
            $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.WorkingDirectory = $p.Folder
            if ($State.LiteUser -and $State.LiteAdmin) {                     # for this build only (Build-App reads them)
                $psi.EnvironmentVariables['APPTEMPLATE_LITE_USER']  = $State.LiteUser
                $psi.EnvironmentVariables['APPTEMPLATE_LITE_ADMIN'] = $State.LiteAdmin
            }
            try {
                $State.Proc = [System.Diagnostics.Process]::Start($psi)
                $State.Current = $p
            }
            catch { [void]$State.Failed.Add($p.Name); Write-TbLog "---- $($p.Name) : could not start: $($_.Exception.Message)" }
        }

        # ---- all done ----
        if (-not $State.Proc -and $State.Queue.Count -eq 0) {
            $State.Finished = $true
            $State.LiteUser = $null; $State.LiteAdmin = $null
            $secs = [int]((Get-Date) - $State.Started).TotalSeconds
            $sum = "Build finished in $secs s: $($State.Ok) built" +
                   $(if ($State.Failed.Count) { ", FAILED: $($State.Failed -join ', ')" } else { '' }) +
                   $(if ($State.Skipped.Count) { ", skipped: $($State.Skipped -join ', ')" } else { '' }) + '.'
            Write-TbLog ""
            Write-TbLog "==== $sum"
            $State.App.SetStatus($sum, $(if ($State.Failed.Count) { 'err' } elseif ($State.Skipped.Count) { 'warn' } else { 'ok' }))
            $State.App.Log('INFO', 'Build', $sum)
            try { $State.Timer.Dispose() } catch { }
            Set-TbBuildState $false
            Invoke-TbRefresh
            return
        }
    }
    finally { if (-not $State.Finished) { $State.Timer.Start() } }
}

# ---- the Lite passwords: asked once for a whole Build ----
# Returns @{ Lite = $true; User; Admin }, @{ Lite = $false } (developer builds
# only), or $null (cancelled). Each password twice; user and admin must differ.
function Show-TbLitePasswordDialog {
    param([Parameter(Mandatory)] $App, [int]$Count = 1)
    $T = $App.Theme
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'Build - Lite (sealed) EXE passwords'
    $dlg.FormBorderStyle = 'FixedDialog'; $dlg.MinimizeBox = $false; $dlg.MaximizeBox = $false
    $dlg.StartPosition = 'CenterParent'; $dlg.ClientSize = New-Object System.Drawing.Size(430, 330)
    $dlg.Font = New-Object System.Drawing.Font($T.FontName, $T.FontSizePt); $dlg.BackColor = $T.Panel
    $chk = New-Object System.Windows.Forms.CheckBox
    $chk.Text = 'Also build the Lite EXEs (the sealed builds to hand out)'; $chk.Checked = $true; $chk.AutoSize = $true
    $chk.Location = New-Object System.Drawing.Point(14, 14)
    $mk = {
        param([string]$Text, [int]$Y)
        $l = New-Object System.Windows.Forms.Label; $l.Text = $Text; $l.AutoSize = $true; $l.Location = New-Object System.Drawing.Point(14, $Y)
        $t = New-Object System.Windows.Forms.TextBox; $t.UseSystemPasswordChar = $true; $t.Width = 400; $t.Location = New-Object System.Drawing.Point(14, ($Y + 20))
        $dlg.Controls.AddRange(@($l, $t)); return $t
    }
    $u1 = & $mk 'User password (user features):' 48
    $u2 = & $mk 'User password again:' 98
    $a1 = & $mk 'Admin password (all features):' 148
    $a2 = & $mk 'Admin password again:' 198
    $hint = New-Object System.Windows.Forms.Label
    $hint.AutoSize = $false; $hint.Size = New-Object System.Drawing.Size(400, 34); $hint.Location = New-Object System.Drawing.Point(14, 248)
    $hint.ForeColor = $T.Muted
    $hint.Text = "The same passwords for all $Count tool(s). They are passed to each build and not kept afterwards."
    $ok = $T.MakeButton('Build'); $ok.AutoSize = $false; $ok.Size = New-Object System.Drawing.Size(90, 30); $ok.Location = New-Object System.Drawing.Point(230, 290)
    $cn = $T.MakeButton('Cancel'); $cn.AutoSize = $false; $cn.Size = New-Object System.Drawing.Size(90, 30); $cn.Location = New-Object System.Drawing.Point(326, 290)
    $cn.DialogResult = 'Cancel'
    $chk.Add_CheckedChanged({ foreach ($b in @($u1, $u2, $a1, $a2)) { $b.Enabled = $chk.Checked } }.GetNewClosure())
    $ok.Add_Click({
        $why = ''
        if ($chk.Checked) {
            if (-not $u1.Text -or -not $a1.Text) { $why = 'Both passwords are required (or untick the Lite EXEs).' }
            elseif ($u1.Text -cne $u2.Text) { $why = 'The two user passwords differ.' }
            elseif ($a1.Text -cne $a2.Text) { $why = 'The two admin passwords differ.' }
            elseif ($u1.Text -ceq $a1.Text) { $why = 'Use different user and admin passwords.' }
        }
        if ($why) { [void][System.Windows.Forms.MessageBox]::Show($dlg, $why, 'Build', 'OK', 'Warning'); return }
        $dlg.DialogResult = 'OK'
    }.GetNewClosure())
    $dlg.Controls.AddRange(@($chk, $hint, $ok, $cn))
    $dlg.AcceptButton = $ok; $dlg.CancelButton = $cn
    $owner = $null; try { $owner = [System.Windows.Forms.Form]::ActiveForm } catch { }
    $r = $(if ($owner) { $dlg.ShowDialog($owner) } else { $dlg.ShowDialog() })
    $res = $null
    if ($r -eq 'OK') {
        $res = $(if ($chk.Checked) { @{ Lite = $true; User = $u1.Text; Admin = $a1.Text } } else { @{ Lite = $false } })
    }
    foreach ($b in @($u1, $u2, $a1, $a2)) { $b.Text = '' }
    $dlg.Dispose()
    return $res
}

# ---------------------------------------------------------- update from zip ---

# Where a GitHub zip is unpacked to look at it (a fresh folder each time).
function New-TbZipWorkFolder {
    param([Parameter(Mandatory)] $App)
    return (Join-Path (Join-Path ([string]$App.LocalAppData) 'Update') ('zip_' + (Get-Date).ToString('yyyyMMdd_HHmmss')))
}

function Get-TbZipOpenCode {
    param([string]$Zip, [string]$WorkFolder)
    return @(
        'Expand-Archive -LiteralPath ' + (Format-AppCommandValue $Zip) + ' -DestinationPath ' + (Format-AppCommandValue $WorkFolder) + ' -Force'
        'Get-ChildItem -LiteralPath ' + (Format-AppCommandValue $WorkFolder) + ' -Recurse -File | Unblock-File   # downloaded: clear "from the internet"'
    ) -join "`r`n"
}

# What an unpacked zip holds: its admin-tools folder (the one with projects\ in it)
# and every tool in it with the version it carries vs the one here.
function Get-TbZipInfo {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $App, [Parameter(Mandatory)] [string]$WorkFolder)
    $root = $null
    foreach ($c in @(@(Get-Item -LiteralPath $WorkFolder) + @(Get-ChildItem -LiteralPath $WorkFolder -Directory))) {
        if (Test-Path -LiteralPath (Join-Path $c.FullName 'projects') -PathType Container) { $root = $c.FullName; break }
    }
    if (-not $root) { throw "No projects folder in the zip - is it a download of the admin-tools repository?" }
    $local = @{}
    foreach ($p in (Get-TbProjects -App $App)) { $local[$p.Name] = $p }
    $tools = foreach ($d in @(Get-ChildItem -LiteralPath (Join-Path $root 'projects') -Directory | Sort-Object Name)) {
        if (-not (Test-Path -LiteralPath (Join-Path $d.FullName 'Source\AppIdentity.json'))) { continue }
        $zv = Read-TbText (Join-Path $d.FullName 'Source\VERSION.txt')
        $lv = $(if ($local.ContainsKey($d.Name)) { [string]$local[$d.Name].SourceVersion } else { '' })
        [pscustomobject]@{
            Name = $d.Name; Here = $(if ($lv) { $lv } else { '(new)' }); InZip = $zv
            Change = $(if (-not $lv) { 'New tool' } elseif ($lv -eq $zv) { 'Same version' } else { "v$lv -> v$zv" })
        }
    }
    [pscustomobject]@{ Root = $root; Tools = @($tools) }
}

# The command window text that applies an unpacked zip: for each tool its Source
# folder is replaced (the old one is moved to _Backup\Update_<time>) and
# Build-App.cmd copied; then the same for template\ and tools\, and the top-level
# files. EXEs, Build\, Archive\ and Update\ are not touched. This exact text runs.
function Get-TbZipApplyCode {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $App, [Parameter(Mandatory)] $Info)
    $f = Get-TbFolders -App $App
    $repo = $(if ($f.Repo) { $f.Repo } else { Split-Path -Parent $f.Projects })
    $backup = Join-Path $repo ('_Backup\Update_' + (Get-Date).ToString('yyyyMMdd_HHmmss'))
    $q = { param($v) Format-AppCommandValue ([string]$v) }
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('$zip    = ' + (& $q $Info.Root))
    $lines.Add('$repo   = ' + (& $q $repo))
    $lines.Add('$backup = ' + (& $q $backup))
    $lines.Add('foreach ($name in ' + (Format-AppCommandValue ([string[]]@($Info.Tools | ForEach-Object { $_.Name }))) + ') {')
    $lines.Add('    $src = Join-Path $zip "projects\$name"; $dst = Join-Path $repo "projects\$name"')
    $lines.Add('    New-Item -ItemType Directory -Path $dst -Force | Out-Null')
    $lines.Add('    if (Test-Path "$dst\Source") { New-Item -ItemType Directory -Path "$backup\projects\$name" -Force | Out-Null; Move-Item "$dst\Source" "$backup\projects\$name\Source" }')
    $lines.Add('    Copy-Item "$src\Source" "$dst\Source" -Recurse')
    $lines.Add('    Copy-Item "$src\Build-App.cmd" "$dst\Build-App.cmd" -Force')
    $lines.Add('}')
    $lines.Add('if (Test-Path "$zip\template\Source") {                         # the template: like a tool')
    $lines.Add('    New-Item -ItemType Directory -Path "$repo\template" -Force | Out-Null')
    $lines.Add('    if (Test-Path "$repo\template\Source") { New-Item -ItemType Directory -Path "$backup\template" -Force | Out-Null; Move-Item "$repo\template\Source" "$backup\template\Source" }')
    $lines.Add('    Copy-Item "$zip\template\Source" "$repo\template\Source" -Recurse')
    $lines.Add('    Copy-Item "$zip\template\Build-App.cmd" "$repo\template\Build-App.cmd" -Force')
    $lines.Add('}')
    $lines.Add('if (Test-Path "$zip\tools") {                                    # the repo tools: the whole folder')
    $lines.Add('    if (Test-Path "$repo\tools") { New-Item -ItemType Directory -Path $backup -Force | Out-Null; Move-Item "$repo\tools" "$backup\tools" }')
    $lines.Add('    Copy-Item "$zip\tools" "$repo\tools" -Recurse')
    $lines.Add('}')
    $lines.Add('Get-ChildItem -LiteralPath $zip -File | Copy-Item -Destination $repo -Force   # Build-All.cmd, README.md, ...')
    return ($lines -join "`r`n")
}
