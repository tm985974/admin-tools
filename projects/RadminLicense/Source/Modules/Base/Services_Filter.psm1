# Services_Filter.psm1   (BASE TIER)
#
# Wildcard filtering for every filterable list, grid or tree in a project.
# TEMPLATE RULE: a filter box always accepts wildcards in any position, so use
# these helpers for every filter instead of -like / .Contains() of your own.
#
#   *   any run of characters (including none)     ?   exactly one character
#   No wildcard     -> "contains": the text appears anywhere in the value.
#   With wildcards  -> the pattern can match ANY part of the value:
#       lon*01     LON-APP-01, LON-SQL-01, ...
#       *sql*      anything containing "sql" (same as plain sql)
#       web-0?     WEB-01 .. WEB-09 (also WEB-010: matches are never anchored)
#       par*2022   PAR-... values with 2022 somewhere after "par"
#   Case-insensitive. Leading/trailing spaces are ignored; inner spaces are
#   literal. Every other character is literal ("a.b" means a dot, not a regex).
#
#   $rx = ConvertTo-FilterRegex -Pattern $text
#       [regex] for the filter text, or $null when there is nothing to filter
#       (empty, or only *).
#   Test-FilterMatch -Regex $rx -Value $text
#       $true when the value matches ($null regex = everything matches).
#   $rows = @(Select-FilterMatch -Items $all -Regex $rx -Property 'Name','Site')
#       the items where ANY listed property matches (objects, hashtables and
#       DataRows); without -Property each item is matched as text.
#   $f = Register-ListFilter -App $App -TextBox $box -OnFilter { param($Regex, $Text) ... }
#       wires a filter box. With the environment's "Filter as I type" on
#       (Environment > General > Lists & logs) it filters after a short pause
#       in typing; with it off, on Enter. Esc clears the box. -OnFilter gets
#       the [regex] (or $null) and the raw text; refill the list there.
#       & $f.Apply   runs the filter now (after loading or reloading data).
#   Get-FilterHintText
#       the one-line wildcard hint to show beside a filter box.

function ConvertTo-FilterRegex {
    [CmdletBinding()]
    param([AllowNull()] [AllowEmptyString()] [string]$Pattern)

    $p = ([string]$Pattern).Trim()
    if ($p -eq '') { return $null }

    # Segments between the stars, in order. Each segment is an atomic
    # "(?>.*?segment)" from the start of the value: it takes the FIRST place the
    # segment fits after the one before. That is always enough for this kind of
    # pattern (an earlier fit never rules out a later segment), and it means one
    # forward pass with no backtracking, even on long values. Leading / trailing
    # stars add nothing (matches are never anchored).
    $parts = New-Object System.Collections.ArrayList
    foreach ($seg in $p.Split('*')) {
        if ($seg -eq '') { continue }
        $sb = New-Object System.Text.StringBuilder
        foreach ($ch in $seg.ToCharArray()) {
            if ($ch -eq '?') { [void]$sb.Append('.') }
            else { [void]$sb.Append([System.Text.RegularExpressions.Regex]::Escape([string]$ch)) }
        }
        [void]$parts.Add($sb.ToString())
    }
    if ($parts.Count -eq 0) { return $null }           # only stars: everything matches

    $body = '\A'
    foreach ($seg in $parts) { $body += '(?>.*?' + [string]$seg + ')' }

    $opts = [System.Text.RegularExpressions.RegexOptions]'IgnoreCase, CultureInvariant, Singleline'
    return New-Object System.Text.RegularExpressions.Regex($body, $opts, [TimeSpan]::FromMilliseconds(200))
}

function Test-FilterMatch {
    [CmdletBinding()]
    param([System.Text.RegularExpressions.Regex]$Regex, [AllowNull()] $Value)
    if ($null -eq $Regex) { return $true }
    if ($null -eq $Value -or $Value -is [System.DBNull]) { return $false }
    try { return $Regex.IsMatch([string]$Value) } catch { return $false }
}

function Select-FilterMatch {
    [CmdletBinding()]
    param(
        [AllowNull()] $Items,
        [System.Text.RegularExpressions.Regex]$Regex,
        [string[]]$Property = @()
    )
    if ($null -eq $Items) { return }
    foreach ($it in $Items) {
        if ($null -eq $Regex) { $it; continue }
        $hit = $false
        if ($Property.Count -gt 0) {
            foreach ($p in $Property) {
                if ($it -is [System.Collections.IDictionary]) { $v = $it[$p] } else { $v = $it.$p }
                if ($null -eq $v -or $v -is [System.DBNull]) { continue }
                try { if ($Regex.IsMatch([string]$v)) { $hit = $true; break } } catch { }
            }
        }
        elseif ($null -ne $it) {
            try { $hit = $Regex.IsMatch([string]$it) } catch { }
        }
        if ($hit) { $it }
    }
}

function Register-ListFilter {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $App,
        [Parameter(Mandatory)] [System.Windows.Forms.TextBox]$TextBox,
        [Parameter(Mandatory)] [scriptblock]$OnFilter,
        [int]$DelayMs = 250
    )
    # Closures cannot see this module's functions reliably: capture them first.
    $toRegex = ${function:ConvertTo-FilterRegex}

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = [Math]::Max(50, $DelayMs)

    $apply = {
        $timer.Stop()
        $text = [string]$TextBox.Text
        $rx = $null
        try { $rx = & $toRegex -Pattern $text } catch { }
        try { & $OnFilter $rx $text }
        catch { try { $App.Log('ERROR', 'Filter', "list filter failed: $($_.Exception.Message)") } catch { } }
    }.GetNewClosure()

    $timer.Add_Tick($apply)

    $TextBox.Add_TextChanged({
        # Read each time: the user may switch environment (or change the setting).
        $v = [string]$App.GetSetting('FilterAsYouType')
        if ($v -eq '' -or $v -eq 'True' -or $v -eq '1') { $timer.Stop(); $timer.Start() }
    }.GetNewClosure())

    $TextBox.Add_KeyDown({
        param($s, $e)
        if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Return) { $e.SuppressKeyPress = $true; & $apply }
        elseif ($e.KeyCode -eq [System.Windows.Forms.Keys]::Escape -and $TextBox.Text -ne '') {
            $e.SuppressKeyPress = $true
            $TextBox.Text = ''
            & $apply
        }
    }.GetNewClosure())

    $TextBox.Add_Disposed({ try { $timer.Stop(); $timer.Dispose() } catch { } }.GetNewClosure())

    return @{ Apply = $apply; TextBox = $TextBox }
}

function Get-FilterHintText {
    [CmdletBinding()]
    param()
    return 'Wildcards anywhere: * = any text, ? = one character. Enter filters, Esc clears.'
}
