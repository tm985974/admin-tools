<#
.SYNOPSIS
  Checks the template and every project for manifest errors and engine drift.

.DESCRIPTION
  Runs on every push (GitHub Actions) and can be run locally:
      powershell -ExecutionPolicy Bypass -File tools\Test-Template.ps1

  Errors (exit code 1):
    - template\TEMPLATE_FILES.txt lists a hash that does not match the file (stale manifest:
      run tools\Update-TemplateManifest.ps1), or VERSION / TEMPLATE_VERSION / CHANGELOG disagree
    - a project's template-owned files differ from its own TEMPLATE_FILES.txt (local engine edit)
    - a project claims the current template version but carries a different manifest
    - a project is on a newer template than template\ , or AppIdentity.json is missing/invalid
    - two projects share an ExeName or AppDataFolder
  Warnings:
    - a project is behind the template (tools\Sync-Template.ps1 brings it up)
    - an engine-looking file in template\Modules\Base is not in the manifest

  -Strict turns "behind the template" into an error.
#>
[CmdletBinding()]
param([switch]$Strict)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AdminTools.psm1') -Force

$errors = 0; $warnings = 0
function Err([string]$m) { $script:errors++; Write-Finding error $m }
function Warn([string]$m) { $script:warnings++; Write-Finding warning $m }

# Files in Modules/Base that every project owns itself (see TEMPLATE_FILES.txt header).
$projectOwnedBase = @('Modules/Base/UI_Register-Tabs.psm1', 'Modules/Base/UI_Tab_Overview.psm1')

# ---- template ---------------------------------------------------------------
$t = Get-TemplateRoot
Write-Host "template"
$tVersion = Get-TextFile (Join-Path $t 'VERSION.txt')
$tTemplateVersion = Get-TextFile (Join-Path $t 'TEMPLATE_VERSION.txt')
if ($tVersion -ne $tTemplateVersion) { Err "template: VERSION.txt ($tVersion) and TEMPLATE_VERSION.txt ($tTemplateVersion) differ" }

$header = [System.IO.File]::ReadAllLines((Join-Path $t 'TEMPLATE_FILES.txt')) | Select-Object -First 3
$hm = [regex]::Match(($header -join "`n"), 'AppTemplate v(\d+\.\d+\.\d+)')
if ($hm.Success -and $hm.Groups[1].Value -ne $tVersion) { Err "template: TEMPLATE_FILES.txt header says v$($hm.Groups[1].Value), VERSION.txt says $tVersion" }

$top = Get-ChangelogEntries (Join-Path $t 'CHANGELOG.txt') | Select-Object -First 1
if (-not $top -or $top.Version -ne [version]$tVersion) { Err "template: newest CHANGELOG.txt entry is v$($top.Version), VERSION.txt says $tVersion" }

$tManifest = @(Read-TemplateManifest $t)
foreach ($p in (Test-ManifestFiles -Root $t -Manifest $tManifest)) {
    Err "template: $($p.File) is $($p.Problem) compared with TEMPLATE_FILES.txt (stale manifest? run tools\Update-TemplateManifest.ps1)"
}
$listed = $tManifest | ForEach-Object File
Get-ChildItem (Join-Path $t 'Modules/Base') -File | ForEach-Object {
    $rel = 'Modules/Base/' + $_.Name
    if (($listed -notcontains $rel) -and ($projectOwnedBase -notcontains $rel)) {
        Warn "template: $rel is not in TEMPLATE_FILES.txt, so it will never reach the projects"
    }
}
$tManifestText = ($tManifest | ForEach-Object { "$($_.Hash)  $($_.File)" }) -join "`n"
Write-Host ("  v{0}, {1} template-owned files" -f $tVersion, $tManifest.Count)

# ---- projects ---------------------------------------------------------------
$rows = @(); $exeNames = @{}; $dataFolders = @{}
foreach ($root in Get-ProjectRoots) {
    $name = Split-Path $root -Leaf
    $state = 'ok'
    try {
        $id = [System.IO.File]::ReadAllText((Join-Path $root 'AppIdentity.json')) | ConvertFrom-Json
        foreach ($k in 'AppName', 'ExeName', 'AppDataFolder') { if (-not $id.$k) { throw "no $k" } }
        if ($id.ExeName -ne $name) { Warn "${name}: folder name differs from ExeName '$($id.ExeName)'" }
        if ($exeNames.ContainsKey($id.ExeName)) { Err "${name}: ExeName '$($id.ExeName)' is also used by $($exeNames[$id.ExeName])" } else { $exeNames[$id.ExeName] = $name }
        if ($dataFolders.ContainsKey($id.AppDataFolder)) { Err "${name}: AppDataFolder '$($id.AppDataFolder)' is also used by $($dataFolders[$id.AppDataFolder]) (they would share environments and logs)" } else { $dataFolders[$id.AppDataFolder] = $name }
    } catch { Err "${name}: AppIdentity.json is missing or invalid ($($_.Exception.Message))"; $state = 'error' }

    $v = Get-TextFile (Join-Path $root 'VERSION.txt')
    $tv = Get-TextFile (Join-Path $root 'TEMPLATE_VERSION.txt')
    $top = Get-ChangelogEntries (Join-Path $root 'CHANGELOG.txt') | Select-Object -First 1
    if (-not $top -or $top.Version -ne [version]$v) { Err "${name}: newest CHANGELOG.txt entry is v$($top.Version), VERSION.txt says $v"; $state = 'error' }

    $m = @(Read-TemplateManifest $root)
    $drift = @(Test-ManifestFiles -Root $root -Manifest $m)
    foreach ($p in $drift) { Err "${name}: template-owned $($p.File) is $($p.Problem) (engine edits belong in template\, then Sync-Template)" }
    if ($drift.Count) { $state = 'drift' }

    $cmp = (ConvertTo-Version $tv).CompareTo((ConvertTo-Version $tVersion))
    if ($cmp -gt 0) { Err "${name}: on template $tv, newer than template\ ($tVersion)"; $state = 'error' }
    elseif ($cmp -lt 0) {
        $msg = "${name}: on template $tv, template is $tVersion (run tools\Sync-Template.ps1 -Project $name)"
        if ($Strict) { Err $msg } else { Warn $msg }
        if ($state -eq 'ok') { $state = 'behind' }
    } else {
        $mText = ($m | ForEach-Object { "$($_.Hash)  $($_.File)" }) -join "`n"
        if ($mText -ne $tManifestText) { Err "${name}: claims template $tv but its TEMPLATE_FILES.txt differs from template\"; $state = 'error' }
    }
    $rows += [pscustomobject]@{ Project = $name; Version = $v; Template = $tv; Status = $state }
}

# ---- template rules: every PowerShell file parses ----------------------------
$repo = Get-RepoRoot
$psFiles = @(Get-ChildItem -Path (Join-Path $repo 'template'), (Join-Path $repo 'projects'), (Join-Path $repo 'tools') -Recurse -File -Include *.ps1, *.psm1)
$parseErrors = 0
foreach ($f in $psFiles) {
    $tokens = $null; $perr = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$perr)
    foreach ($e in @($perr)) {
        $parseErrors++
        $rel = $f.FullName.Substring($repo.Length + 1) -replace '\\', '/'
        Err ("{0}:{1}: syntax error: {2}" -f $rel, $e.Extent.StartLineNumber, $e.Message)
    }
}
Write-Host ("  {0} PowerShell files parsed, {1} syntax error(s)" -f $psFiles.Count, $parseErrors)

# ---- template rules: tooltips and the command window (projects) ------------
# Rule 1: every clickable control has hover help: an entry in Config\ToolTips.json
#         (or the engine catalog). An empty text marks "no tooltip on purpose".
# Rule 2: actions that run a command go through the command window
#         (Invoke-AppCommand / Confirm-AppCommand), not a Yes/No message box.
$engineKeys = @{}
$ttAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $t 'Modules/Base/Services_ToolTips.psm1'), [ref]$null, [ref]$null)
$ttAst.FindAll({ param($a) $a -is [System.Management.Automation.Language.AssignmentStatementAst] -and $a.Left.Extent.Text -eq '$script:EngineToolTips' }, $true) | ForEach-Object {
    $_.FindAll({ param($a) $a -is [System.Management.Automation.Language.HashtableAst] }, $true) | ForEach-Object {
        foreach ($pair in $_.KeyValuePairs) { $engineKeys[(ConvertTo-ToolTipKey ([string]$pair.Item1.Value))] = $true }
    }
}
$clickTypes = 'Button|CheckBox|RadioButton|LinkLabel|ToolStripMenuItem|ToolStripButton'
foreach ($root in Get-ProjectRoots) {
    $name = Split-Path $root -Leaf
    $ttPath = Join-Path $root 'Config/ToolTips.json'
    $keys = @{}
    if (-not (Test-Path $ttPath)) { Err "${name}: Config/ToolTips.json is missing (template rule: every clickable control has hover help)"; continue }
    try {
        $j = [System.IO.File]::ReadAllText($ttPath) | ConvertFrom-Json
        $src = $(if ($j.PSObject.Properties['ToolTips']) { $j.ToolTips } else { $j })
        foreach ($p in $src.PSObject.Properties) { if ($p.Name -notlike '_*') { $keys[(ConvertTo-ToolTipKey (($p.Name -split '>')[-1]))] = $true } }
    } catch { Err "${name}: Config/ToolTips.json is not valid JSON ($($_.Exception.Message))"; continue }

    $missing = New-Object System.Collections.Generic.List[string]
    $files = @(Get-ChildItem (Join-Path $root 'Modules') -Recurse -File -Filter *.psm1 | Where-Object { -not ($_.Directory.Name -eq 'Base' -and (Test-Path (Join-Path $t ('Modules/Base/' + $_.Name))) -and $_.Name -notin 'UI_Register-Tabs.psm1', 'UI_Tab_Overview.psm1') })
    foreach ($f in $files) {
        $rel = 'Modules/' + $f.Directory.Name + '/' + $f.Name
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$null)
        $captions = New-Object System.Collections.Generic.List[object]
        # $x = New-Object ...Button  ->  remember $x as clickable
        $clickVars = @{}
        foreach ($a in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)) {
            if ($a.Right.Extent.Text -match ('New-Object\s+(System\.Windows\.Forms\.)?(' + $clickTypes + ')\b')) { $clickVars[$a.Left.Extent.Text.ToLowerInvariant()] = $true }
        }
        foreach ($n in $ast.FindAll({ param($x) $true }, $true)) {
            # $T.MakeButton('Save') / $App.Theme.MakeButton('Save')
            if ($n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Member.Extent.Text -eq 'MakeButton' -and
                $n.Arguments.Count -ge 1 -and $n.Arguments[0] -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                $captions.Add(@($n.Arguments[0].Value, $n.Extent.StartLineNumber))
            }
            # New-Object ...ToolStripMenuItem('Text') / New-Object ...Button -ArgumentList 'Text' is rare; menu items are usually .Text = '...'
            # $x.Text = 'Caption'  where $x is a clickable control made in this file
            if ($n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left -is [System.Management.Automation.Language.MemberExpressionAst] -and
                $n.Left.Member.Extent.Text -eq 'Text' -and $n.Right -is [System.Management.Automation.Language.CommandExpressionAst] -and
                $n.Right.Expression -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
                $clickVars.ContainsKey($n.Left.Expression.Extent.Text.ToLowerInvariant())) {
                $captions.Add(@($n.Right.Expression.Value, $n.Extent.StartLineNumber))
            }
            # $menu.Items.Add('Open')  (context / tray menu items)
            if ($n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Member.Extent.Text -eq 'Add' -and
                $n.Expression.Extent.Text -match '(?i)(menu|strip|cms|ctx)\w*\.(Items|DropDownItems)$' -and
                $n.Arguments.Count -eq 1 -and $n.Arguments[0] -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                $captions.Add(@($n.Arguments[0].Value, $n.Extent.StartLineNumber))
            }
            # New-StyledButton 'Text' / New-SamButton 'Text' ... : any New-*Button command with a text first
            if ($n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -match '^New-\w*Button$') {
                $els = $n.CommandElements
                for ($i = 1; $i -lt $els.Count; $i++) {
                    if ($els[$i] -is [System.Management.Automation.Language.CommandParameterAst]) {
                        if ($els[$i].ParameterName -eq 'Text' -and $i + 1 -lt $els.Count -and $els[$i + 1] -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $captions.Add(@($els[$i + 1].Value, $n.Extent.StartLineNumber)) }
                        break
                    }
                    if ($els[$i] -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $captions.Add(@($els[$i].Value, $n.Extent.StartLineNumber)) }
                    break
                }
            }
            # Tab titles: @{ Title = 'Fleet'; Fn = ... } in UI_Register-Tabs, and Register-EnvironmentSection -Title 'Radmin'
            if ($n -is [System.Management.Automation.Language.HashtableAst] -and $f.Name -eq 'UI_Register-Tabs.psm1') {
                foreach ($pair in $n.KeyValuePairs) {
                    if ($pair.Item1.Extent.Text -eq 'Title' -and $pair.Item2.Extent.Text -match "^'([^']+)'$") { $captions.Add(@($Matches[1], $pair.Item1.Extent.StartLineNumber)) }
                }
            }
            if ($n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Register-EnvironmentSection') {
                $els = $n.CommandElements
                for ($i = 0; $i -lt $els.Count - 1; $i++) {
                    if ($els[$i] -is [System.Management.Automation.Language.CommandParameterAst] -and $els[$i].ParameterName -eq 'Title' -and
                        $els[$i + 1] -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                        $captions.Add(@($els[$i + 1].Value, $n.Extent.StartLineNumber))
                    }
                }
            }
            # Rule 2: [MessageBox]::Show(..., 'YesNo' | 'OKCancel' | 'YesNoCancel', ...)
            if ($n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Member.Extent.Text -eq 'Show' -and
                $n.Expression.Extent.Text -match 'MessageBox\]$' -and $n.Static) {
                $btnArg = @($n.Arguments | Where-Object { $_ -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $_.Value -in 'YesNo', 'OKCancel', 'YesNoCancel' })
                $line = $f.FullName | ForEach-Object { ([System.IO.File]::ReadAllLines($_))[$n.Extent.StartLineNumber - 1] }
                if ($btnArg.Count -and $line -notmatch '#\s*not-a-command') {
                    Warn ("{0}: {1}:{2}: Yes/No message box - if it confirms an action that runs a command, use Confirm-AppCommand / Invoke-AppCommand (or mark the line '# not-a-command')" -f $name, $rel, $n.Extent.StartLineNumber)
                }
            }
        }
        foreach ($c in $captions) {
            if (([string]$c[0]).Contains('>')) {
                Err ("{0}: {1}:{2}: control text '{3}' contains '>', which separates places in a tooltip key - it can never have an entry; drop the '>' or set it with Set-AppToolTip" -f $name, $rel, $c[1], $c[0])
                continue
            }
            $k = ConvertTo-ToolTipKey ([string]$c[0])
            if (-not $k -or $keys.ContainsKey($k) -or $engineKeys.ContainsKey($k)) { continue }
            $missing.Add(("{0}:{1} '{2}'" -f $rel, $c[1], (([string]$c[0]) -replace '&', '')))
        }
    }
    foreach ($m in ($missing | Sort-Object -Unique)) { Err "${name}: no tooltip for $m - add it to Config/ToolTips.json (an empty text = none on purpose)" }
}

$rows | Format-Table -AutoSize | Out-String | Write-Host
Write-Host ("{0} error(s), {1} warning(s)" -f $errors, $warnings)
if ($env:GITHUB_STEP_SUMMARY) {
    $md = @("### Template v$tVersion", '', '| Project | Version | Template | Status |', '|---|---|---|---|')
    $md += $rows | ForEach-Object { "| $($_.Project) | $($_.Version) | $($_.Template) | $($_.Status) |" }
    $md += '', "$errors error(s), $warnings warning(s)"
    Add-Content -Path $env:GITHUB_STEP_SUMMARY -Value ($md -join "`n")
}
if ($errors) { exit 1 }
