# Services_CommandTemplate.psm1   (LITE TIER)
#
# Command entries: a syntax builder. The entry's Template is the command line
# with fields in braces; its Code is only a param() block that declares those
# fields (type, ValidateSet, Mandatory, default, comment help), so the Run
# dialog builds the same inputs it builds for functions.
#
#   Template rules
#     {Name}            the field's value. Quoted only when it needs it: double
#                       quotes when that is safe (works in PowerShell and cmd),
#                       otherwise single quotes. Names start with a letter, so
#                       format strings such as '{0:X}' are left alone.
#     {Name:raw}        the value exactly as typed (no quotes added)
#     {Name:q}          always quoted - use it where the value is a PowerShell
#                       string inside an expression, e.g. ({Path:q} -replace ...);
#                       an empty value gives ''
#     {Name:join=,}     a list field joined with "," (default ", " - a
#                       PowerShell array); combine: {Name:raw,join= }
#     [[ ... ]]         optional part (cannot contain a literal "]]", such as
#                       [byte[]] - keep those outside it): left out when any field inside it is
#                       empty, or is a switch that is off. A switch field
#                       itself writes nothing, so  [[ /force{Force}]]  adds
#                       " /force" only when Force is ticked.
#     Credential / SecureString fields run as a variable passed in memory; the
#     copyable text shows (Get-Credential) / (Read-Host -AsSecureString).
#     A template can be several lines (a short script).
#
# Entry-kind helpers used by the Library tab, Run dialog and runner:
#   Test-LibraryCommandEntry -Entry $e
#   Get-LibraryEntryParameters -Entry $e          (same shape as Get-LibraryParameterInfo)
#   Get-LibraryEntryHelp -Entry $e
#   Test-LibraryEntryWhatIf -Entry $e
#   Test-LibraryEntryRunnable -Entry $e           -> '' or the reason it cannot run
#   ConvertTo-LibraryEntryCall -Entry $e -Parameters $p -Values $v [-WhatIf]
#       -> Text (what runs), Display (what you copy), Variables, Errors
#   Get-LibraryEntryRunCode -Entry $e             (code defined before the call)
#   Get-LibraryTemplateFields -Template $t        (field names used)

$script:CommandWrapperName = '__LibraryCommand'

function Test-LibraryCommandEntry {
    param($Entry)
    return ($Entry -and [string]$Entry.Kind -eq 'Command')
}

function Get-LibraryCommandWrapper {
    param([AllowEmptyString()] [string]$Code)
    return "function $script:CommandWrapperName {`n" + [string]$Code + "`n}"
}

function Get-LibraryEntryParameters {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Entry)
    if (Test-LibraryCommandEntry $Entry) {
        return @(Get-LibraryParameterInfo -Code (Get-LibraryCommandWrapper $Entry.Code) -Function $script:CommandWrapperName)
    }
    return @(Get-LibraryParameterInfo -Code $Entry.Code -Function $Entry.Function)
}

function Get-LibraryEntryHelp {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Entry)
    if (Test-LibraryCommandEntry $Entry) { return Get-LibraryFunctionHelp -Code (Get-LibraryCommandWrapper $Entry.Code) -Function $script:CommandWrapperName }
    return Get-LibraryFunctionHelp -Code $Entry.Code -Function $Entry.Function
}

function Test-LibraryEntryWhatIf {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Entry)
    if (Test-LibraryCommandEntry $Entry) { return $false }
    return Test-LibrarySupportsShouldProcess -Code $Entry.Code -Function $Entry.Function
}

function Get-LibraryEntryRunCode {
    param($Entry)
    if (Test-LibraryCommandEntry $Entry) { return '' }
    return [string]$Entry.Code
}

# Field names a template uses, in order of first use.
function Get-LibraryTemplateFields {
    param([AllowEmptyString()] [string]$Template)
    $seen = New-Object System.Collections.Generic.List[string]
    foreach ($m in [regex]::Matches([string]$Template, '\{([A-Za-z]\w*)(?::[^}]*)?\}')) {
        $n = $m.Groups[1].Value
        if (-not ($seen -contains $n)) { $seen.Add($n) }
    }
    return $seen.ToArray()
}

# '' when the entry can run, otherwise why not.
function Test-LibraryEntryRunnable {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Entry)
    if (Test-LibraryCommandEntry $Entry) {
        if (-not ([string]$Entry.Template).Trim()) { return 'This command entry has no template.' }
        $info = Get-LibraryCodeInfo -Code (Get-LibraryCommandWrapper $Entry.Code)
        if ($info.Errors.Count) { return "The fields (param block) do not parse: $($info.Errors[0].Message)" }
        $names = @(Get-LibraryEntryParameters -Entry $Entry | ForEach-Object { $_.Name })
        $missing = @(Get-LibraryTemplateFields $Entry.Template | Where-Object { $names -notcontains $_ })
        if ($missing.Count) { return "The template uses fields that are not declared: $($missing -join ', ')" }
        # every [[ needs a later ]] (a ]] outside a part, as in [byte[]], is plain text)
        $tt = [string]$Entry.Template; $at = 0
        while (($o = $tt.IndexOf('[[', $at)) -ge 0) {
            $c = $tt.IndexOf(']]', $o + 2)
            if ($c -lt 0) { return 'The template has an unclosed [[ ... ]] part.' }
            $at = $c + 2
        }
        return ''
    }
    $info = Get-LibraryCodeInfo -Code $Entry.Code
    if ($info.Errors.Count) { return "The code has a parse error: $($info.Errors[0].Message)" }
    if (-not ($info.Functions -contains $Entry.Function)) { return "The code does not define '$($Entry.Function)'." }
    return ''
}

# One value as command-line text.
function ConvertTo-LibraryTemplateWord {
    param([AllowEmptyString()] [string]$Text, [switch]$Raw, [switch]$Always)
    if ($Raw) { return $Text }
    if ($Text -eq '') { return '""' }
    if (-not $Always -and $Text -notmatch '[\s''"`$;&|(){}<>,#@]') { return $Text }
    if ($Text -notmatch '[`$"]') { return '"' + $Text + '"' }
    return "'" + ($Text -replace "'", "''") + "'"
}

# Values: hashtable Name -> raw value (as the Run dialog gives it).
function ConvertTo-LibraryTemplateText {
    [CmdletBinding()]
    param(
        [AllowEmptyString()] [string]$Template,
        [object[]]$Parameters = @(),
        [hashtable]$Values = @{}
    )
    $errors = New-Object System.Collections.Generic.List[string]
    $vars = @{}
    $byName = @{}
    foreach ($p in $Parameters) { $byName[$p.Name.ToLower()] = $p }

    # render each field once: Run text, Display text, Empty flag
    $rendered = @{}
    foreach ($p in $Parameters) {
        $has = $Values.ContainsKey($p.Name)
        $v = if ($has) { $Values[$p.Name] } else { $null }
        $r = @{ Run = ''; Show = ''; Empty = $true; Items = @() }
        switch ($p.Kind) {
            'Switch' { $r.Empty = -not ($v -eq $true) }
            'Bool' {
                if ($null -ne $v -and [string]$v -ne '') { $t = '$' + ([bool]$v).ToString().ToLower(); $r.Run = $t; $r.Show = $t; $r.Empty = $false }
            }
            'Credential' {
                if ($null -ne $v) { $vn = "__p_$($p.Name)"; $vars[$vn] = $v; $r.Run = "`$$vn"; $r.Show = '(Get-Credential)'; $r.Empty = $false }
            }
            'SecureString' {
                if ($null -ne $v) { $vn = "__p_$($p.Name)"; $vars[$vn] = $v; $r.Run = "`$$vn"; $r.Show = '(Read-Host -AsSecureString)'; $r.Empty = $false }
            }
            'Int' {
                $s = ([string]$v).Trim()
                if ($s -match '^<\w+>$') { $r.Run = $s; $r.Show = $s; $r.Empty = $false }
                elseif ($s) { $n = 0L; if ([long]::TryParse($s, [ref]$n)) { $r.Run = [string]$n; $r.Show = [string]$n; $r.Empty = $false } else { $errors.Add("$($p.Name): '$s' is not a whole number") } }
            }
            'Number' {
                $s = ([string]$v).Trim()
                if ($s -match '^<\w+>$') { $r.Run = $s; $r.Show = $s; $r.Empty = $false }
                elseif ($s) {
                    $d = 0.0
                    if ([double]::TryParse($s, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$d)) { $t = $d.ToString([System.Globalization.CultureInfo]::InvariantCulture); $r.Run = $t; $r.Show = $t; $r.Empty = $false }
                    else { $errors.Add("$($p.Name): '$s' is not a number") }
                }
            }
            'StringArray' {
                $items = @(Split-LibraryList ([string]$v))
                if ($items.Count) {
                    if ($p.ElementKind -in @('Int', 'Number')) {
                        $bad = @($items | Where-Object { $null -eq ($_ -as [double]) })
                        if ($bad.Count) { $errors.Add("$($p.Name): not a number: $($bad -join ', ')") }
                    }
                    $r.Items = $items; $r.Empty = $false
                }
            }
            default {
                $s = [string]$v
                if ($s.Trim()) {
                    if ($p.IsArray) { $r.Items = @(Split-LibraryList $s) } else { $r.Run = $s; $r.Show = $s }
                    $r.Empty = $false
                }
            }
        }
        if ($p.Mandatory -and $r.Empty -and $p.Kind -ne 'Switch') { $errors.Add("$($p.Name) is required") }
        if (-not $r.Empty -and @($p.ValidateSet).Count -gt 0 -and $p.Kind -notin @('Switch', 'Bool', 'Credential', 'SecureString')) {
            $check = if (@($r.Items).Count) { @($r.Items) } else { @($r.Run) }
            foreach ($item in $check) { if (-not (@($p.ValidateSet) -contains $item)) { $errors.Add("$($p.Name): '$item' is not one of $(@($p.ValidateSet) -join ', ')") } }
        }
        $rendered[$p.Name.ToLower()] = $r
    }

    # token -> text for one mode ('Run' or 'Show'); $State.Empty set when a field in it is empty
    $renderPart = {
        param([string]$Part, [string]$Mode, $State)
        $sb = New-Object System.Text.StringBuilder
        $pos = 0
        foreach ($m in [regex]::Matches($Part, '\{([A-Za-z]\w*)(?::([^}]*))?\}')) {
            [void]$sb.Append($Part.Substring($pos, $m.Index - $pos))
            $pos = $m.Index + $m.Length
            $name = $m.Groups[1].Value.ToLower()
            $opts = $m.Groups[2].Value
            if (-not $rendered.ContainsKey($name)) { $State.Unknown += $m.Groups[1].Value; [void]$sb.Append($m.Value); continue }
            $r = $rendered[$name]
            $p = $byName[$name]
            # {Name:q} is a string expression: empty is '' (and keeps an optional part)
            if ($r.Empty -and $opts -match '(^|,)q(,|$)' -and $p.Kind -ne 'Switch') { [void]$sb.Append("''"); continue }
            if ($r.Empty) { $State.Empty = $true; continue }
            if ($p.Kind -eq 'Switch') { continue }
            $raw = $opts -match '(^|,)raw(,|$)'
            $always = $opts -match '(^|,)q(,|$)'
            $join = $null
            if ($opts -match '(^|,)join=(.*)$') { $join = $Matches[2] }
            if (@($r.Items).Count) {
                if ($null -eq $join) { $join = ', ' }
                $isNum = $p.ElementKind -in @('Int', 'Number')
                [void]$sb.Append((@($r.Items | ForEach-Object { if ($isNum) { $_ } else { ConvertTo-LibraryTemplateWord -Text $_ -Raw:$raw -Always:$always } }) -join $join))
                continue
            }
            $val = if ($Mode -eq 'Run') { $r.Run } else { $r.Show }
            if ($p.Kind -in @('Credential', 'SecureString', 'Int', 'Number', 'Bool')) { [void]$sb.Append($val) }
            else { [void]$sb.Append((ConvertTo-LibraryTemplateWord -Text $val -Raw:$raw -Always:$always)) }
        }
        [void]$sb.Append($Part.Substring($pos))
        return $sb.ToString()
    }

    $state = [pscustomobject]@{ Empty = $false; Unknown = @() }
    $build = {
        param([string]$Mode)
        $sb = New-Object System.Text.StringBuilder
        $rest = [string]$Template
        while ($rest.Length) {
            $i = $rest.IndexOf('[[')
            if ($i -lt 0) { $state.Empty = $false; [void]$sb.Append((& $renderPart $rest $Mode $state)); break }
            $state.Empty = $false
            [void]$sb.Append((& $renderPart $rest.Substring(0, $i) $Mode $state))
            $j = $rest.IndexOf(']]', $i + 2)
            if ($j -lt 0) { [void]$sb.Append($rest.Substring($i)); break }
            $seg = $rest.Substring($i + 2, $j - $i - 2)
            $state.Empty = $false
            $out = & $renderPart $seg $Mode $state
            if (-not $state.Empty) { [void]$sb.Append($out) }
            $rest = $rest.Substring($j + 2)
        }
        # tidy: no trailing blanks on lines, CRLF-neutral
        return ((($sb.ToString() -replace "`r`n", "`n") -split "`n" | ForEach-Object { $_.TrimEnd() }) -join "`r`n").Trim()
    }
    $runText = & $build 'Run'
    $showText = & $build 'Show'
    foreach ($u in @($state.Unknown | Select-Object -Unique)) { $errors.Add("Template field {$u} is not declared") }

    [pscustomobject]@{ Text = $runText; Display = $showText; Variables = $vars; Errors = $errors.ToArray() }
}

# One call for both kinds: Text runs, Display is what the user sees and copies.
function ConvertTo-LibraryEntryCall {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Entry, [object[]]$Parameters = @(), [hashtable]$Values = @{}, [switch]$WhatIf)
    if (Test-LibraryCommandEntry $Entry) {
        return ConvertTo-LibraryTemplateText -Template $Entry.Template -Parameters $Parameters -Values $Values
    }
    $c = ConvertTo-LibraryCallText -Function $Entry.Function -Parameters $Parameters -Values $Values -WhatIf:$WhatIf
    return [pscustomobject]@{ Text = $c.Text; Display = $c.Text; Variables = $c.Variables; Errors = $c.Errors }
}

# Values a command entry starts with in the Run dialog when nothing was
# remembered: the param default, unquoted.
function Get-LibraryTemplateDefault {
    param($Param)
    $t = ([string]$Param.DefaultText).Trim()
    if (-not $t) { return $null }
    if ($Param.Kind -eq 'Switch') { return ($t -match '^\$true$') }
    if ($Param.Kind -eq 'Bool') { if ($t -match '^\$?(true|1)$') { return $true } elseif ($t -match '^\$?(false|0)$') { return $false } else { return $null } }
    if ($t -match "^'(.*)'$") { return ($Matches[1] -replace "''", "'") }
    if ($t -match '^"(.*)"$') { return $Matches[1] }
    if ($t -match '^@\((.*)\)$') { return (@($Matches[1] -split ',' | ForEach-Object { $_.Trim().Trim("'", '"') }) -join "`r`n") }
    if ($t -match '^\$') { return $null }
    return $t
}

# A command that ends in "| Format-Table a, b -AutoSize" prints nicely but its
# output is formatting records, useless for the grid and CSV export. The runner
# runs "| Select-Object a, b" instead and applies the Format-* part only when
# showing the Results text. Returns @{ Text; Format } (Format '' = unchanged).
function Split-LibraryTrailingFormat {
    param([AllowEmptyString()] [string]$Text)
    $res = @{ Text = $Text; Format = '' }
    $tk = $null; $er = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput([string]$Text, [ref]$tk, [ref]$er)
    if ($er -or -not $ast.EndBlock -or $ast.EndBlock.Statements.Count -eq 0) { return $res }
    $last = $ast.EndBlock.Statements[$ast.EndBlock.Statements.Count - 1]
    if (-not ($last -is [System.Management.Automation.Language.PipelineAst]) -or $last.PipelineElements.Count -lt 2) { return $res }
    $cmd = $last.PipelineElements[$last.PipelineElements.Count - 1]
    if (-not ($cmd -is [System.Management.Automation.Language.CommandAst])) { return $res }
    $name = [string]$cmd.GetCommandName()
    if ($name -notin @('Format-Table', 'Format-List', 'ft', 'fl')) { return $res }
    $props = New-Object System.Collections.Generic.List[string]
    $els = @($cmd.CommandElements)
    for ($i = 1; $i -lt $els.Count; $i++) {
        $el = $els[$i]
        if ($el -is [System.Management.Automation.Language.CommandParameterAst]) {
            $pn = $el.ParameterName
            if ($pn -like 'Prop*') {
                if ($el.Argument) { $props.Add($el.Argument.Extent.Text) }
                elseif ($i + 1 -lt $els.Count) { $i++; $props.Add($els[$i].Extent.Text) }
            }
            elseif ($pn -in @('GroupBy', 'View', 'Expand') -and -not $el.Argument) { $i++ }
            continue
        }
        $props.Add($el.Extent.Text)
    }
    $prev = $last.PipelineElements[$last.PipelineElements.Count - 2]
    $head = $Text.Substring(0, $prev.Extent.EndOffset)
    $res.Text = $head + $(if ($props.Count) { ' | Select-Object ' + ($props -join ', ') } else { '' }) + $Text.Substring($cmd.Extent.EndOffset)
    $res.Format = $cmd.Extent.Text
    return $res
}
