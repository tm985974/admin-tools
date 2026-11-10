# Services_FunctionAnalysis.psm1   (LITE TIER)
#
# Reads a library entry's code with the PowerShell parser (no regex), so the
# Run dialog is built from what the function itself declares:
#
#   Get-LibraryCodeInfo -Code $text
#       -> Functions (top-level names), Errors (parse errors), Ast
#   Get-LibraryParameterInfo -Code $text -Function Get-Thing
#       -> one object per parameter: Name, Kind, TypeName, Mandatory,
#          DefaultText, ValidateSet, HelpText, Position, IsArray
#   Get-LibraryFunctionHelp -Code $text -Function Get-Thing
#       -> Synopsis, Description, Examples, Notes (comment-based help)
#   Test-LibrarySupportsShouldProcess -Code $text -Function Get-Thing
#   ConvertTo-LibraryCallText -Function Get-Thing -Parameters $p -Values $v [-WhatIf]
#       -> the exact command line the Run dialog previews and runs
#
# Kinds drive the input control: Switch, Bool, Int, Number, String,
# StringArray, Credential, SecureString, DateTime.

function Get-LibraryCodeInfo {
    [CmdletBinding()]
    param([AllowEmptyString()] [string]$Code)
    $tokens = $null; $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput([string]$Code, [ref]$tokens, [ref]$errs)
    $fns = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false) |
             Where-Object { -not (Get-LibraryEnclosingFunction $_) })
    [pscustomobject]@{
        Ast       = $ast
        Errors    = @($errs)
        Functions = @($fns | ForEach-Object { $_.Name })
        FunctionAsts = $fns
    }
}

# The function a node sits inside (walks up the parents), or $null at top level.
function Get-LibraryEnclosingFunction {
    param($Node)
    $p = $Node.Parent
    while ($p) {
        if ($p -is [System.Management.Automation.Language.FunctionDefinitionAst]) { return $p }
        $p = $p.Parent
    }
    return $null
}

function Get-LibraryFunctionAst {
    [CmdletBinding()]
    param([AllowEmptyString()] [string]$Code, [string]$Function)
    $info = Get-LibraryCodeInfo -Code $Code
    $hit = @($info.FunctionAsts | Where-Object { $_.Name -ieq $Function }) | Select-Object -Last 1
    return $hit
}

# The param() block of a function, whichever way it is written
# (function X { param(...) }  or  function X($a, $b) { }).
function Get-LibraryParamAsts {
    param($FnAst)
    if (-not $FnAst) { return @() }
    if ($FnAst.Body -and $FnAst.Body.ParamBlock) { return @($FnAst.Body.ParamBlock.Parameters) }
    if ($FnAst.Parameters) { return @($FnAst.Parameters) }
    return @()
}

function Get-LibraryParameterKind {
    param([type]$Type, [string]$TypeName)
    $t = $Type
    if (-not $t) { return @{ Kind = 'String'; IsArray = $false } }
    $isArray = $t.IsArray
    $el = if ($isArray) { $t.GetElementType() } else { $t }
    $k = 'String'
    if     ($el -eq [System.Management.Automation.SwitchParameter]) { $k = 'Switch' }
    elseif ($el -eq [bool])                                         { $k = 'Bool' }
    elseif ($el -in @([int], [long], [int16], [byte], [uint32], [uint64])) { $k = 'Int' }
    elseif ($el -in @([double], [single], [decimal]))                { $k = 'Number' }
    elseif ($el -eq [System.Management.Automation.PSCredential])     { $k = 'Credential' }
    elseif ($el -eq [System.Security.SecureString])                  { $k = 'SecureString' }
    elseif ($el -eq [datetime])                                      { $k = 'DateTime' }
    if ($isArray -and $k -in @('String', 'Int', 'Number')) {
        return @{ Kind = 'StringArray'; IsArray = $true; ElementKind = $k }
    }
    return @{ Kind = $k; IsArray = $isArray; ElementKind = $k }
}

function Get-LibraryParameterInfo {
    [CmdletBinding()]
    param([AllowEmptyString()] [string]$Code, [Parameter(Mandatory)] [string]$Function)

    $fn = Get-LibraryFunctionAst -Code $Code -Function $Function
    if (-not $fn) { return @() }
    $help = $null
    try { $help = $fn.GetHelpContent() } catch { }

    $out = New-Object System.Collections.Generic.List[object]
    $pos = 0
    foreach ($p in (Get-LibraryParamAsts $fn)) {
        $name = $p.Name.VariablePath.UserPath
        $typeName = ''
        $type = $null
        foreach ($a in $p.Attributes) {
            if ($a -is [System.Management.Automation.Language.TypeConstraintAst]) {
                $typeName = $a.TypeName.FullName
                try { $type = $a.TypeName.GetReflectionType() } catch { }
                if (-not $type) { try { $type = [type]$a.TypeName.FullName } catch { } }
            }
        }
        if (-not $type -and $p.StaticType -and $p.StaticType -ne [object]) { $type = $p.StaticType }
        $kind = Get-LibraryParameterKind -Type $type -TypeName $typeName

        $mandatory = $false; $helpMsg = ''; $set = @(); $paramSets = @()
        foreach ($a in $p.Attributes) {
            if (-not ($a -is [System.Management.Automation.Language.AttributeAst])) { continue }
            $an = $a.TypeName.Name
            if ($an -ieq 'Parameter') {
                foreach ($na in $a.NamedArguments) {
                    if ($na.ArgumentName -ieq 'Mandatory') {
                        if ($na.ExpressionOmitted) { $mandatory = $true }
                        else { $mandatory = ($na.Argument.Extent.Text -notmatch '^\$?false$|^0$') }
                    }
                    elseif ($na.ArgumentName -ieq 'HelpMessage') {
                        try { $helpMsg = [string]$na.Argument.SafeGetValue() } catch { $helpMsg = $na.Argument.Extent.Text.Trim("'`"") }
                    }
                    elseif ($na.ArgumentName -ieq 'ParameterSetName') {
                        try { $paramSets += [string]$na.Argument.SafeGetValue() } catch { }
                    }
                }
            }
            elseif ($an -ieq 'ValidateSet') {
                foreach ($pa in $a.PositionalArguments) {
                    try { $set += [string]$pa.SafeGetValue() } catch { $set += $pa.Extent.Text.Trim("'`"") }
                }
            }
        }

        $helpText = $helpMsg
        if (-not $helpText -and $help -and $help.Parameters) {
            foreach ($k in $help.Parameters.Keys) { if ($k -ieq $name) { $helpText = ([string]$help.Parameters[$k]).Trim() } }
        }

        $out.Add([pscustomobject]@{
            Name          = $name
            Kind          = $kind.Kind
            ElementKind   = $kind.ElementKind
            IsArray       = [bool]$kind.IsArray
            TypeName      = $(if ($typeName) { $typeName } else { 'object' })
            Mandatory     = $mandatory
            DefaultText   = $(if ($p.DefaultValue) { $p.DefaultValue.Extent.Text } else { '' })
            ValidateSet   = @($set)
            HelpText      = $helpText
            ParameterSets = @($paramSets)
            Position      = $pos
        })
        $pos++
    }
    return $out.ToArray()
}

function Get-LibraryFunctionHelp {
    [CmdletBinding()]
    param([AllowEmptyString()] [string]$Code, [Parameter(Mandatory)] [string]$Function)
    $fn = Get-LibraryFunctionAst -Code $Code -Function $Function
    $r = [pscustomobject]@{ Synopsis = ''; Description = ''; Examples = @(); Notes = '' }
    if (-not $fn) { return $r }
    try {
        $h = $fn.GetHelpContent()
        if ($h) {
            $r.Synopsis    = ([string]$h.Synopsis).Trim()
            $r.Description = ([string]$h.Description).Trim()
            $r.Examples    = @($h.Examples | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
            $r.Notes       = ([string]$h.Notes).Trim()
        }
    } catch { }
    return $r
}

function Test-LibrarySupportsShouldProcess {
    [CmdletBinding()]
    param([AllowEmptyString()] [string]$Code, [Parameter(Mandatory)] [string]$Function)
    $fn = Get-LibraryFunctionAst -Code $Code -Function $Function
    if (-not ($fn -and $fn.Body -and $fn.Body.ParamBlock)) { return $false }
    foreach ($a in $fn.Body.ParamBlock.Attributes) {
        if ($a.TypeName.Name -ieq 'CmdletBinding') {
            foreach ($na in $a.NamedArguments) {
                if ($na.ArgumentName -ieq 'SupportsShouldProcess') {
                    if ($na.ExpressionOmitted) { return $true }
                    return ($na.Argument.Extent.Text -notmatch '^\$?false$|^0$')
                }
            }
        }
    }
    return $false
}

# Single-quoted PowerShell literal.
function ConvertTo-LibraryLiteral {
    param([AllowEmptyString()] [string]$Text)
    return "'" + ($Text -replace "'", "''") + "'"
}

# Split a multi-line / comma / semicolon list into clean items.
function Split-LibraryList {
    param([AllowEmptyString()] [string]$Text)
    return @(([string]$Text) -split '[\r\n,;]+' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

# Values: hashtable Name -> raw value from the dialog (string, bool, or for
# Credential/SecureString any non-null marker). Returns @{ Text; Variables; Errors }.
# Credential / SecureString values are never written into the text: the call
# references $__p_<Name>, which the runner sets in the run's session.
function ConvertTo-LibraryCallText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Function,
        [object[]]$Parameters = @(),
        [hashtable]$Values = @{},
        [switch]$WhatIf
    )
    $parts = New-Object System.Collections.Generic.List[string]
    $parts.Add($Function)
    $vars = @{}
    $errors = New-Object System.Collections.Generic.List[string]

    foreach ($p in $Parameters) {
        $has = $Values.ContainsKey($p.Name)
        $v = if ($has) { $Values[$p.Name] } else { $null }
        switch ($p.Kind) {
            'Switch' {
                if ($v -eq $true) { $parts.Add("-$($p.Name)") }
            }
            'Bool' {
                if ($null -ne $v -and [string]$v -ne '') {
                    $parts.Add("-$($p.Name) `$$(([bool]$v).ToString().ToLower())")
                }
            }
            { $_ -in @('Credential', 'SecureString') } {
                if ($null -ne $v) {
                    $vn = "__p_$($p.Name)"
                    $vars[$vn] = $v
                    $parts.Add("-$($p.Name) `$$vn")
                }
            }
            'StringArray' {
                $items = @(Split-LibraryList ([string]$v))
                if ($items.Count -gt 0) {
                    if ($p.ElementKind -in @('Int', 'Number')) {
                        $bad = @($items | Where-Object { -not ($_ -as [double] -ne $null) })
                        if ($bad.Count) { $errors.Add("$($p.Name): not a number: $($bad -join ', ')") }
                        $parts.Add("-$($p.Name) @($($items -join ', '))")
                    }
                    else {
                        $parts.Add("-$($p.Name) @($((@($items | ForEach-Object { ConvertTo-LibraryLiteral $_ })) -join ', '))")
                    }
                }
            }
            'Int' {
                $s = ([string]$v).Trim()
                if ($s) {
                    $n = 0L
                    if ([long]::TryParse($s, [ref]$n)) { $parts.Add("-$($p.Name) $n") }
                    else { $errors.Add("$($p.Name): '$s' is not a whole number") }
                }
            }
            'Number' {
                $s = ([string]$v).Trim()
                if ($s) {
                    $d = 0.0
                    if ([double]::TryParse($s, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$d)) {
                        $parts.Add("-$($p.Name) $($d.ToString([System.Globalization.CultureInfo]::InvariantCulture))")
                    }
                    else { $errors.Add("$($p.Name): '$s' is not a number") }
                }
            }
            'DateTime' {
                $s = ([string]$v).Trim()
                if ($s) {
                    $dt = [datetime]::MinValue
                    if ([datetime]::TryParse($s, [ref]$dt)) { $parts.Add("-$($p.Name) ([datetime]$(ConvertTo-LibraryLiteral $dt.ToString('s')))") }
                    else { $errors.Add("$($p.Name): '$s' is not a date/time") }
                }
            }
            default {
                $s = [string]$v
                if ($s.Trim()) {
                    if ($p.IsArray) {
                        $items = @(Split-LibraryList $s)
                        $parts.Add("-$($p.Name) @($((@($items | ForEach-Object { ConvertTo-LibraryLiteral $_ })) -join ', '))")
                    }
                    else { $parts.Add("-$($p.Name) $(ConvertTo-LibraryLiteral $s)") }
                }
            }
        }

        $given = $false
        if ($p.Kind -eq 'Switch') { $given = $true }
        elseif ($p.Kind -in @('Credential', 'SecureString')) { $given = ($null -ne $v) }
        else { $given = ([string]$v).Trim() -ne '' }
        if ($p.Mandatory -and -not $given) { $errors.Add("$($p.Name) is required") }
        if ($given -and @($p.ValidateSet).Count -gt 0 -and $p.Kind -notin @('Switch', 'Bool', 'Credential', 'SecureString')) {
            foreach ($item in @(Split-LibraryList ([string]$v))) {
                if (-not (@($p.ValidateSet) -contains $item)) { $errors.Add("$($p.Name): '$item' is not one of $(@($p.ValidateSet) -join ', ')") }
            }
        }
    }
    if ($WhatIf) { $parts.Add('-WhatIf') }

    [pscustomobject]@{
        Text      = ($parts -join ' ')
        Variables = $vars
        Errors    = $errors.ToArray()
    }
}
