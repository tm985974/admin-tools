#region -- Services.Mail.RichHtml.psm1 ----------------------------------------
# Concern : Formatted (rich) email HTML - pure string logic, no WinForms.
#           ConvertTo-SafeMailHtml   - allowlist sanitizer. Takes HTML from
#             the Additional Info editor (MSHTML innerHTML, including pasted
#             Word / web content) or from DomainDefaults.json and returns
#             clean, email-safe, ASCII-only HTML:
#               kept tags  : b i u s sub sup span a br p div ul ol li img
#                            blockquote hr (strong/em/strike/del/font and
#                            common block tags are mapped onto these)
#               kept style : color, background-color, font-family,
#                            font-size, font-weight, font-style,
#                            text-decoration, text-align, margin-top,
#                            margin-bottom (+ width/height on img). Every
#                            value is validated by pattern.
#               links      : http, https and mailto only.
#               pictures   : only <img src="cid:ID"> (ID = 16 hex). Any
#                            other src is offered to the caller's
#                            -ImageResolver, which may return an ID (the
#                            editor maps its temp files / imports local
#                            files this way) or $null (picture dropped).
#               dropped    : script/style/head/xml/object/etc. WITH their
#                            content, comments, event attributes, classes,
#                            ids, unknown tags (their text is kept).
#               text       : entity-decoded, then re-encoded; anything
#                            outside printable ASCII becomes &#N;.
#             Runs at editor save time AND again at send time.
#           ConvertFrom-MailHtmlToText - plain-text version (preview text,
#             AdditionalInfoN fallback field).
#           ConvertTo-MailHtmlFromText - plain text -> escaped HTML with
#             <br> line breaks (upgrades snippets saved before v1.5.0).
#           Get-MailHtmlImageIds  - distinct cid: picture IDs in an HTML
#             string.
#           Get-MailSafeFonts     - the email-safe font list offered by the
#             editor.
# Load order: 4a1 - no dependencies. Loads before Services.Mail.Send, which
#             calls ConvertTo-SafeMailHtml on -AppendHtml.
# New module: v1.5.0 (rich Additional Info).
#endregion

#region -- Get-MailSafeFonts ---------------------------------------------------
function Get-MailSafeFonts {
    <#
    .SYNOPSIS
        Fonts offered by the Additional Info editor. All ship with Windows
        and Office and have close substitutes on other platforms, so a
        recipient without the font still sees a similar face.
    #>
    return @(
        'Arial', 'Calibri', 'Cambria', 'Courier New', 'Georgia',
        'Segoe UI', 'Tahoma', 'Times New Roman', 'Trebuchet MS', 'Verdana'
    )
}
#endregion

#region -- ConvertTo-MailHtmlEncoded (private helper) ---------------------------
function ConvertTo-MailHtmlEncoded {
    <#
    .SYNOPSIS
        Encodes already-DECODED text for HTML: & < > " escaped, anything
        outside printable ASCII written as a numeric entity (surrogate pairs
        combined). Control characters other than tab/CR/LF are dropped.
    #>
    param([string]$Text)
    if (-not $Text) { return '' }
    $sb = New-Object System.Text.StringBuilder
    $n  = $Text.Length
    for ($i = 0; $i -lt $n; $i++) {
        $ch   = $Text[$i]
        $code = [int]$ch
        if ($code -eq 38)      { [void]$sb.Append('&amp;');  continue }
        if ($code -eq 60)      { [void]$sb.Append('&lt;');   continue }
        if ($code -eq 62)      { [void]$sb.Append('&gt;');   continue }
        if ($code -eq 34)      { [void]$sb.Append('&quot;'); continue }
        if ($code -ge 32 -and $code -le 126) { [void]$sb.Append($ch); continue }
        if ($code -eq 9 -or $code -eq 10 -or $code -eq 13) { [void]$sb.Append($ch); continue }
        if ($code -lt 32 -or $code -eq 127) { continue }
        if ([char]::IsHighSurrogate($ch) -and ($i + 1) -lt $n -and [char]::IsLowSurrogate($Text[$i + 1])) {
            $cp = [char]::ConvertToUtf32($ch, $Text[$i + 1])
            [void]$sb.Append('&#' + $cp + ';')
            $i++
            continue
        }
        if ([char]::IsSurrogate($ch)) { continue }
        [void]$sb.Append('&#' + $code + ';')
    }
    return $sb.ToString()
}
#endregion

#region -- ConvertTo-MailSafeColor (private helper) ----------------------------
function ConvertTo-MailSafeColor {
    <#
    .SYNOPSIS
        Validates a CSS colour. Returns '#rrggbb' (rgb() and #rgb are
        normalised), a plain colour name, or '' when the value is not a
        simple colour.
    #>
    param([string]$Value)
    if (-not $Value) { return '' }
    $v = $Value.Trim().ToLowerInvariant()
    if ($v -match '^#[0-9a-f]{6}$') { return $v }
    if ($v -match '^#([0-9a-f])([0-9a-f])([0-9a-f])$') {
        return ('#' + $matches[1] + $matches[1] + $matches[2] + $matches[2] + $matches[3] + $matches[3])
    }
    if ($v -match '^rgb\(\s*(\d{1,3})\s*,\s*(\d{1,3})\s*,\s*(\d{1,3})\s*\)$') {
        $r = [Math]::Min(255, [int]$matches[1])
        $g = [Math]::Min(255, [int]$matches[2])
        $b = [Math]::Min(255, [int]$matches[3])
        return ('#{0:x2}{1:x2}{2:x2}' -f $r, $g, $b)
    }
    if ($v -match '^[a-z]{3,20}$' -and $v -ne 'expression' -and $v -ne 'inherit' -and $v -ne 'initial') { return $v }
    return ''
}
#endregion

#region -- ConvertTo-MailSafeFontFamily (private helper) -----------------------
function ConvertTo-MailSafeFontFamily {
    <#
    .SYNOPSIS
        Validates a CSS font-family list. Each name may only contain letters,
        digits, spaces and hyphens; names with spaces are single-quoted.
        Returns '' when nothing valid remains.
    #>
    param([string]$Value)
    if (-not $Value) { return '' }
    $out = [System.Collections.Generic.List[string]]::new()
    foreach ($part in ($Value -split ',')) {
        $name = $part.Trim().Trim('"').Trim("'").Trim()
        if (-not $name) { continue }
        if ($name -notmatch '^[A-Za-z0-9 \-]{1,40}$') { continue }
        if ($name -match ' ') { $out.Add("'" + $name + "'") } else { $out.Add($name) }
        if ($out.Count -ge 4) { break }
    }
    return ($out -join ',')
}
#endregion

#region -- ConvertTo-MailSafeStyle (private helper) -----------------------------
function ConvertTo-MailSafeStyle {
    <#
    .SYNOPSIS
        Filters a CSS declaration list down to the allowlisted properties,
        validating every value. Returns an ordered dictionary prop -> value
        (lower-case property names) so callers can merge more entries.
    .PARAMETER ForImage
        Also allow width / height (pixels) - used for <img>.
    #>
    param([string]$Style, [switch]$ForImage)
    $result = [ordered]@{}
    if (-not $Style) { return $result }
    foreach ($decl in ($Style -split ';')) {
        $idx = $decl.IndexOf(':')
        if ($idx -lt 1) { continue }
        $prop = $decl.Substring(0, $idx).Trim().ToLowerInvariant()
        $val  = $decl.Substring($idx + 1).Trim()
        $val  = ($val -replace '(?i)\s*!important\s*$', '').Trim()
        if (-not $val) { continue }
        $low  = $val.ToLowerInvariant()
        switch ($prop) {
            'color' {
                $c = ConvertTo-MailSafeColor $val
                if ($c) { $result['color'] = $c }
            }
            { $_ -eq 'background-color' -or $_ -eq 'background' } {
                # White is the email body colour - the editor's "No
                # highlight" choice writes it, so it is simply dropped.
                $c = ConvertTo-MailSafeColor $val
                if ($c -and @('transparent', '#ffffff', 'white') -notcontains $c) { $result['background-color'] = $c }
            }
            'font-family' {
                $f = ConvertTo-MailSafeFontFamily $val
                if ($f) { $result['font-family'] = $f }
            }
            'font-size' {
                if ($low -match '^\d{1,2}(\.\d{1,2})?(pt|px)$' -or
                    $low -match '^(xx-small|x-small|small|medium|large|x-large|xx-large|smaller|larger)$') {
                    $result['font-size'] = $low
                }
            }
            'font-weight' {
                if ($low -match '^(normal|bold|bolder|lighter|[1-9]00)$') { $result['font-weight'] = $low }
            }
            'font-style' {
                if ($low -match '^(normal|italic|oblique)$') { $result['font-style'] = $low }
            }
            'text-decoration' {
                if ($low -match '^(none|underline|line-through|overline)( (underline|line-through|overline))*$') {
                    $result['text-decoration'] = $low
                }
            }
            { $_ -eq 'margin-top' -or $_ -eq 'margin-bottom' } {
                # Spacing between Additional Info blocks (Services.Mail.Dialog).
                if ($low -match '^\d{1,2}(px|pt)?$') { $result[$prop] = $low }
            }
            'text-align' {
                if ($low -match '^(left|right|center|justify)$') { $result['text-align'] = $low }
            }
            'width' {
                if ($ForImage -and $low -match '^\d{1,4}px$') { $result['width'] = $low }
            }
            'height' {
                if ($ForImage -and $low -match '^\d{1,4}px$') { $result['height'] = $low }
            }
            default { }
        }
    }
    return $result
}
#endregion

#region -- Format-MailStyleAttr (private helper) -------------------------------
function Format-MailStyleAttr {
    param($StyleMap)
    if (-not $StyleMap -or $StyleMap.Count -eq 0) { return '' }
    $parts = [System.Collections.Generic.List[string]]::new()
    foreach ($k in $StyleMap.Keys) { $parts.Add($k + ':' + $StyleMap[$k]) }
    return (' style="' + (ConvertTo-MailHtmlEncoded ($parts -join ';')) + '"')
}
#endregion

#region -- Get-MailHtmlAttributes (private helper) -----------------------------
function Get-MailHtmlAttributes {
    <#
    .SYNOPSIS
        Parses a tag's attribute text into a hashtable (lower-case names,
        entity-DECODED values). Handles "double", 'single' and unquoted
        values and bare attributes (value '').
    #>
    param([string]$AttrText)
    $attrs = @{}
    if (-not $AttrText) { return $attrs }
    $rx = '([^\s=/"''<>]+)(?:\s*=\s*(?:"([^"]*)"|''([^'']*)''|([^\s"''>]+)))?'
    foreach ($m in [regex]::Matches($AttrText, $rx)) {
        $name = $m.Groups[1].Value.ToLowerInvariant()
        $val  = ''
        if ($m.Groups[2].Success)     { $val = $m.Groups[2].Value }
        elseif ($m.Groups[3].Success) { $val = $m.Groups[3].Value }
        elseif ($m.Groups[4].Success) { $val = $m.Groups[4].Value }
        $attrs[$name] = [System.Net.WebUtility]::HtmlDecode($val)
    }
    return $attrs
}
#endregion

#region -- ConvertTo-MailSafeUrl (private helper) -------------------------------
function ConvertTo-MailSafeUrl {
    <#
    .SYNOPSIS
        Returns the URL when it is http://, https:// or mailto: with no
        whitespace, quotes or angle brackets; otherwise ''.
    #>
    param([string]$Url)
    if (-not $Url) { return '' }
    $u = $Url.Trim()
    if ($u.Length -gt 2000) { return '' }
    if ($u -match '^(?i)(https?://[^\s"''<>]+|mailto:[^\s"''<>]+)$') { return $u }
    return ''
}
#endregion

#region -- ConvertTo-SafeMailHtml ----------------------------------------------
function ConvertTo-SafeMailHtml {
    <#
    .SYNOPSIS
        Allowlist sanitizer for formatted email snippets. See module header.
    .PARAMETER Html
        Untrusted HTML (editor innerHTML, pasted content, or a saved value).
    .PARAMETER ImageResolver
        Optional scriptblock param([string]$Src). Called for every <img>
        whose src is not already 'cid:<16 hex>'. Return the picture ID to
        keep it (it is written as cid:ID), or $null to drop it.
    .OUTPUTS
        [string] Clean ASCII HTML, or '' when the input has no visible text
        and no pictures.
    #>
    param(
        [string]$Html,
        [scriptblock]$ImageResolver = $null
    )
    if (-not $Html) { return '' }
    if ($Html.Length -gt 500000) { $Html = $Html.Substring(0, 500000) }

    # Tags whose CONTENT is dropped too.
    $dropContent = @('script', 'style', 'head', 'title', 'xml', 'iframe', 'object', 'embed',
                     'noscript', 'template', 'svg', 'math', 'select', 'textarea', 'applet', 'frameset')
    # Source tag -> output tag.
    $tagMap = @{
        'b' = 'b'; 'strong' = 'b'; 'i' = 'i'; 'em' = 'i'; 'u' = 'u'; 'ins' = 'u'
        's' = 's'; 'strike' = 's'; 'del' = 's'; 'sub' = 'sub'; 'sup' = 'sup'
        'span' = 'span'; 'font' = 'span'; 'a' = 'a'
        'p' = 'p'; 'div' = 'div'; 'ul' = 'ul'; 'ol' = 'ol'; 'li' = 'li'; 'blockquote' = 'blockquote'
        'h1' = 'div'; 'h2' = 'div'; 'h3' = 'div'; 'h4' = 'div'; 'h5' = 'div'; 'h6' = 'div'
        'center' = 'div'; 'pre' = 'div'; 'address' = 'div'; 'section' = 'div'; 'article' = 'div'
        'header' = 'div'; 'footer' = 'div'; 'table' = 'div'; 'tr' = 'div'; 'dl' = 'div'
        'dt' = 'div'; 'dd' = 'div'; 'figure' = 'div'; 'figcaption' = 'div'; 'main' = 'div'
        'nav' = 'div'; 'aside' = 'div'; 'caption' = 'div'
    }
    $headingSize = @{ 'h1' = '18pt'; 'h2' = '16pt'; 'h3' = '14pt'; 'h4' = '12pt'; 'h5' = '10pt'; 'h6' = '9pt' }
    # <font size="N"> -> point size (matches the browser's own 1..7 scale).
    $fontSizeMap = @{ '1' = '8pt'; '2' = '10pt'; '3' = '12pt'; '4' = '14pt'; '5' = '18pt'; '6' = '24pt'; '7' = '36pt' }

    $out   = New-Object System.Text.StringBuilder
    $stack = [System.Collections.Generic.List[object]]::new()   # @{ Src; Out }
    $skipTag   = ''
    $skipDepth = 0

    $rxToken = '(?s)<!--.*?-->|<!\[CDATA\[.*?\]\]>|<![^>]*>|<\?[^>]*>|<(/?)([A-Za-z][A-Za-z0-9:_\-]*)((?:[^>"'']|"[^"]*"|''[^'']*'')*)>|[^<]+|<'

    foreach ($m in [regex]::Matches($Html, $rxToken)) {
        $tok = $m.Value

        if (-not $m.Groups[2].Success) {
            # Text, comment, doctype, PI, CDATA or a lone '<'.
            if ($skipTag) { continue }
            if ($tok.StartsWith('<!') -or $tok.StartsWith('<?')) { continue }
            if ($tok -eq '<') { [void]$out.Append('&lt;'); continue }
            [void]$out.Append((ConvertTo-MailHtmlEncoded ([System.Net.WebUtility]::HtmlDecode($tok))))
            continue
        }

        $isClose = ($m.Groups[1].Value -eq '/')
        $name    = $m.Groups[2].Value.ToLowerInvariant()
        $attrTxt = $m.Groups[3].Value
        $selfClosing = $attrTxt.TrimEnd().EndsWith('/')

        # Inside a dropped-content element: only track nesting of that tag.
        if ($skipTag) {
            if ($name -eq $skipTag) {
                if ($isClose) { $skipDepth-- } elseif (-not $selfClosing) { $skipDepth++ }
                if ($skipDepth -le 0) { $skipTag = ''; $skipDepth = 0 }
            }
            continue
        }

        if ($dropContent -contains $name) {
            if (-not $isClose -and -not $selfClosing) { $skipTag = $name; $skipDepth = 1 }
            continue
        }

        # ---- Void elements ---------------------------------------------
        if ($name -eq 'br') {
            if (-not $isClose) { [void]$out.Append('<br>') }
            continue
        }
        if ($name -eq 'hr') {
            if (-not $isClose) { [void]$out.Append('<hr style="border:0;border-top:1px solid #cccccc;">') }
            continue
        }
        if ($name -eq 'img') {
            if ($isClose) { continue }
            $a   = Get-MailHtmlAttributes $attrTxt
            $src = if ($a.ContainsKey('src')) { $a['src'].Trim() } else { '' }
            $id  = $null
            if ($src -match '^(?i)cid:([0-9a-f]{16})$') {
                $id = $matches[1].ToLowerInvariant()
            } elseif ($ImageResolver -and $src) {
                try { $id = & $ImageResolver $src } catch { $id = $null }
                if ($id) { $id = ([string]$id).ToLowerInvariant() }
                if ($id -and $id -notmatch '^[0-9a-f]{16}$') { $id = $null }
            }
            if (-not $id) { continue }
            $imgTag = '<img src="cid:' + $id + '" alt=""'
            foreach ($dim in @('width', 'height')) {
                if ($a.ContainsKey($dim) -and $a[$dim] -match '^\s*(\d{1,4})(px)?\s*$') {
                    $imgTag += ' ' + $dim + '="' + $matches[1] + '"'
                }
            }
            $st = ConvertTo-MailSafeStyle -Style $a['style'] -ForImage
            $st['border'] = '0'
            $imgTag += (Format-MailStyleAttr $st) + '>'
            [void]$out.Append($imgTag)
            continue
        }

        # ---- Table cells: no tag, keep a separator -----------------------
        if ($name -eq 'td' -or $name -eq 'th') {
            if ($isClose) { [void]$out.Append(' ') }
            continue
        }

        if (-not $tagMap.ContainsKey($name)) { continue }   # unknown tag: keep its text only
        $outTag = $tagMap[$name]

        if ($isClose) {
            # Pop up to and including the matching open element.
            $at = -1
            for ($k = $stack.Count - 1; $k -ge 0; $k--) {
                if ($stack[$k].Src -eq $name) { $at = $k; break }
            }
            if ($at -lt 0) { continue }
            for ($k = $stack.Count - 1; $k -ge $at; $k--) {
                if ($stack[$k].Out) { [void]$out.Append('</' + $stack[$k].Out + '>') }
                $stack.RemoveAt($k)
            }
            continue
        }

        if ($selfClosing) { continue }   # <span/> etc. - nothing to wrap

        # Implicitly closed elements (HTML allows <li>a<li>b and <p>a<p>b):
        # a new li/p closes an open one of the same kind at the top of the
        # stack instead of nesting inside it.
        if (($name -eq 'li' -or $name -eq 'p') -and $stack.Count -gt 0 -and $stack[$stack.Count - 1].Src -eq $name) {
            $top = $stack[$stack.Count - 1]
            if ($top.Out) { [void]$out.Append('</' + $top.Out + '>') }
            $stack.RemoveAt($stack.Count - 1)
        }

        $a     = Get-MailHtmlAttributes $attrTxt
        $style = ConvertTo-MailSafeStyle -Style $a['style']

        if ($name -eq 'font') {
            if ($a.ContainsKey('face')) {
                $f = ConvertTo-MailSafeFontFamily $a['face']
                if ($f) { $style['font-family'] = $f }
            }
            if ($a.ContainsKey('size')) {
                $sz = $a['size'].Trim()
                if ($fontSizeMap.ContainsKey($sz)) { $style['font-size'] = $fontSizeMap[$sz] }
            }
            if ($a.ContainsKey('color')) {
                $c = ConvertTo-MailSafeColor $a['color']
                if ($c) { $style['color'] = $c }
            }
        }
        if ($a.ContainsKey('align') -and $a['align'] -match '^(?i)(left|right|center|justify)$') {
            $style['text-align'] = $a['align'].ToLowerInvariant()
        }
        if ($name -eq 'center') { $style['text-align'] = 'center' }
        if ($headingSize.ContainsKey($name)) {
            $style['font-weight'] = 'bold'
            if (-not $style.Contains('font-size')) { $style['font-size'] = $headingSize[$name] }
        }
        if ($outTag -eq 'p') {
            if (-not $style.Contains('margin-top'))    { $style['margin-top'] = '0' }
            if (-not $style.Contains('margin-bottom')) { $style['margin-bottom'] = '0' }
        }
        if ($outTag -eq 'blockquote') { $style['margin'] = '0 0 0 30px' }
        if ($outTag -eq 'ul' -or $outTag -eq 'ol') {
            if (-not $style.Contains('margin-top'))    { $style['margin-top'] = '0' }
            if (-not $style.Contains('margin-bottom')) { $style['margin-bottom'] = '0' }
        }

        $open = '<' + $outTag
        if ($outTag -eq 'a') {
            $href = ''
            if ($a.ContainsKey('href')) { $href = ConvertTo-MailSafeUrl $a['href'] }
            if ($href) {
                $open += ' href="' + (ConvertTo-MailHtmlEncoded $href) + '"'
            } else {
                $outTag = 'span'
                $open   = '<span'
            }
        }
        $open += (Format-MailStyleAttr $style) + '>'

        # A bare <span> carries nothing - track it (so its close matches)
        # but write nothing.
        if ($outTag -eq 'span' -and $style.Count -eq 0) {
            $stack.Add(@{ Src = $name; Out = '' })
            continue
        }
        [void]$out.Append($open)
        $stack.Add(@{ Src = $name; Out = $outTag })
    }

    for ($k = $stack.Count - 1; $k -ge 0; $k--) {
        if ($stack[$k].Out) { [void]$out.Append('</' + $stack[$k].Out + '>') }
    }

    $result = $out.ToString().Trim()

    # Nothing visible (only tags, whitespace, nbsp) and no pictures -> blank.
    if ($result -notmatch '<img ') {
        $probe = ($result -replace '<[^>]*>', '') -replace '&#160;|&nbsp;', ''
        if (-not $probe.Trim()) { return '' }
    }
    return $result
}
#endregion

#region -- ConvertFrom-MailHtmlToText ------------------------------------------
function ConvertFrom-MailHtmlToText {
    <#
    .SYNOPSIS
        Plain-text rendering of an HTML snippet: block ends and <br> become
        line breaks, list items get "- ", pictures become "[picture]",
        links keep their text. ASCII-only output (common typographic
        characters folded, anything else '?').
    #>
    param([string]$Html)
    if (-not $Html) { return '' }
    $t = $Html -replace '[\r\n]+', ' '
    $t = $t -replace '(?i)<br\s*/?>', "`n"
    $t = $t -replace '(?i)<li[^>]*>', "`n- "
    $t = $t -replace '(?i)</(p|div|li|ul|ol|blockquote|h[1-6]|tr|table)\s*>', "`n"
    $t = $t -replace '(?i)<img[^>]*>', '[picture]'
    $t = $t -replace '<[^>]*>', ''
    $t = [System.Net.WebUtility]::HtmlDecode($t)

    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $t.ToCharArray()) {
        $code = [int]$ch
        if ($code -eq 10 -or ($code -ge 32 -and $code -le 126)) { [void]$sb.Append($ch); continue }
        switch ($code) {
            160   { [void]$sb.Append(' ') }
            8216  { [void]$sb.Append("'") }
            8217  { [void]$sb.Append("'") }
            8220  { [void]$sb.Append('"') }
            8221  { [void]$sb.Append('"') }
            8211  { [void]$sb.Append('-') }
            8212  { [void]$sb.Append('-') }
            8226  { [void]$sb.Append('*') }
            8230  { [void]$sb.Append('...') }
            9     { [void]$sb.Append(' ') }
            default { if ($code -ge 32) { [void]$sb.Append('?') } }
        }
    }
    $lines = @($sb.ToString() -split "`n" | ForEach-Object { ($_ -replace ' {2,}', ' ').Trim() })
    $text  = ($lines -join "`r`n")
    $text  = $text -replace '(\r\n){3,}', "`r`n`r`n"
    return $text.Trim()
}
#endregion

#region -- ConvertTo-MailHtmlFromText ------------------------------------------
function ConvertTo-MailHtmlFromText {
    <#
    .SYNOPSIS
        Plain text -> HTML: encoded, line breaks as <br>. Used to open
        snippets saved before v1.5.0 (plain text only) in the editor and
        to send them when no formatted version exists.
    #>
    param([string]$Text)
    if (-not $Text -or -not $Text.Trim()) { return '' }
    $enc = ConvertTo-MailHtmlEncoded $Text.Trim()
    $enc = $enc -replace "`r`n", '<br>' -replace "`n", '<br>' -replace "`r", '<br>'
    return $enc
}
#endregion

#region -- Get-MailHtmlImageIds ------------------------------------------------
function Get-MailHtmlImageIds {
    <#
    .SYNOPSIS
        Distinct lower-case picture IDs referenced as cid:<16 hex> in the
        given HTML (one or more strings).
    #>
    param([string[]]$Html)
    $ids = [System.Collections.Generic.List[string]]::new()
    foreach ($h in $Html) {
        if (-not $h) { continue }
        foreach ($m in [regex]::Matches($h, '(?i)cid:([0-9a-f]{16})')) {
            $id = $m.Groups[1].Value.ToLowerInvariant()
            if (-not $ids.Contains($id)) { $ids.Add($id) }
        }
    }
    return ,$ids.ToArray()
}
#endregion

Export-ModuleMember -Function Get-MailSafeFonts, ConvertTo-SafeMailHtml, ConvertFrom-MailHtmlToText, `
    ConvertTo-MailHtmlFromText, Get-MailHtmlImageIds
