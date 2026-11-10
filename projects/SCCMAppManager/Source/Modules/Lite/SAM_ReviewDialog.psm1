# SAM_ReviewDialog.psm1   (LITE TIER)
#
# Side-by-side "Original / New (editable)" review used by Update JSON and by
# Copy JSON to environment. Fields = @(@{ Key; Label; Old; New; Tall }, ...).
# Returns @{ Result = 'Apply'; Values = @{ Key = value } } | @{ Result = 'Skip' } | @{ Result = 'Cancel' }

function Get-SamProposedText {
    param([string]$Text, [string]$OldVersion, [string]$NewVersion, [string]$OldCode, [string]$NewCode,
          [string]$OldFile, [string]$NewFile, [switch]$Detection)
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    $t = $Text

    if ($NewCode) {
        if ($OldCode) { $t = Edit-SamTextLiteral $t $OldCode $NewCode }
        elseif (-not $Detection) { $t = [regex]::Replace($t, $global:SamGuidPattern, $NewCode.Replace('$', '$$')) }
    }
    # Only the installer file name changes (never powershell.exe / msiexec.exe / cmd.exe)
    if ($NewFile -and $OldFile -and $OldFile -ne $NewFile) { $t = Edit-SamTextLiteral $t $OldFile $NewFile }

    if ($Detection -and $t -match '\$displayversion\s*=\s*"[^"]*"') {
        $t = [regex]::Replace($t, '(\$displayversion\s*=\s*")[^"]*"', ('${1}' + $NewVersion.Replace('$', '$$') + '"'),
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    }
    else {
        $t = Edit-SamTextVersion $t $OldVersion $NewVersion
    }
    return $t
}

function Show-SamReviewDialog {
    param([string]$Title, [string]$Header, [string]$Info, $Fields, [switch]$NoSkip)

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text          = $Title
    $dlg.Size          = New-Object System.Drawing.Size(1000, 860)
    $dlg.StartPosition = 'CenterParent'
    $dlg.MinimizeBox   = $false
    $dlg.ShowInTaskbar = $false

    $body = New-Object System.Windows.Forms.Panel
    $body.Dock = 'Fill'; $body.AutoScroll = $true
    $foot = New-Object System.Windows.Forms.Panel
    $foot.Dock = 'Bottom'; $foot.Height = 56
    $head = New-Object System.Windows.Forms.Label
    $head.Dock = 'Top'; $head.Height = 60; $head.Padding = New-Object System.Windows.Forms.Padding(10, 6, 10, 0)
    $head.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
    $head.Text = "$Header`r`n$Info"
    $dlg.Controls.Add($body); $dlg.Controls.Add($foot); $dlg.Controls.Add($head)

    $mono = New-Object System.Drawing.Font('Consolas', 9)
    $bold = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $y = 8; $w = 930; $ctl = @{}

    foreach ($f in @($Fields)) {
        $h = if ($f.Tall) { 170 } else { 46 }
        $changed = ([string]$f.Old) -ne ([string]$f.New)

        $l = New-Object System.Windows.Forms.Label
        $l.Location = New-Object System.Drawing.Point(8, $y); $l.Size = New-Object System.Drawing.Size($w, 20); $l.Font = $bold
        $l.Text = if ($changed) { $f.Label } else { "$($f.Label)   (no change proposed)" }
        $body.Controls.Add($l); $y += 22

        $newBox = $null
        foreach ($pair in @(@('Original:', $f.Old, $true), @('New (editable):', $f.New, $false))) {
            $lb = New-Object System.Windows.Forms.Label
            $lb.Location = New-Object System.Drawing.Point(20, $y); $lb.Size = New-Object System.Drawing.Size(200, 18); $lb.Text = $pair[0]
            if (-not $pair[2]) { $lb.ForeColor = [System.Drawing.Color]::DarkGreen }
            $body.Controls.Add($lb); $y += 18

            $tb = New-Object System.Windows.Forms.TextBox
            $tb.Location = New-Object System.Drawing.Point(20, $y); $tb.Size = New-Object System.Drawing.Size(($w - 20), $h)
            $tb.Multiline = $true; $tb.ScrollBars = 'Both'; $tb.WordWrap = (-not $f.Tall); $tb.Font = $mono
            $tb.Text = ConvertTo-SamCrLf $pair[1]
            $tb.Anchor = 'Top,Left,Right'
            if ($pair[2]) { $tb.ReadOnly = $true; $tb.BackColor = [System.Drawing.Color]::WhiteSmoke } else { $newBox = $tb }
            $body.Controls.Add($tb); $y += $h + 4
        }

        $chk = New-Object System.Windows.Forms.CheckBox
        $chk.Location = New-Object System.Drawing.Point(20, $y); $chk.Size = New-Object System.Drawing.Size(300, 22)
        $chk.Text = 'Use NEW value'; $chk.Checked = $changed; $chk.Font = $bold
        $body.Controls.Add($chk); $y += 34

        $ctl[$f.Key] = @{ Chk = $chk; Box = $newBox; Old = $f.Old; New = $f.New; Shown = (ConvertTo-SamCrLf $f.New) }
    }

    $mk = {
        param($text, $x, $color, $result)
        $b = New-Object System.Windows.Forms.Button
        $b.Text = $text; $b.Size = New-Object System.Drawing.Size(140, 34); $b.Location = New-Object System.Drawing.Point($x, 11)
        $b.BackColor = $color; $b.Anchor = 'Top,Right'; $b.DialogResult = $result
        $b.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
        $foot.Controls.Add($b); $b
    }
    $null = & $mk 'Apply Changes' 530 ([System.Drawing.Color]::LightGreen) ([System.Windows.Forms.DialogResult]::OK)
    if (-not $NoSkip) { $null = & $mk 'Skip' 680 ([System.Drawing.Color]::LightYellow) ([System.Windows.Forms.DialogResult]::Ignore) }
    $btnCancel = & $mk 'Cancel All' 830 ([System.Drawing.Color]::LightCoral) ([System.Windows.Forms.DialogResult]::Cancel)
    $dlg.CancelButton = $btnCancel

    try {
        $res = $dlg.ShowDialog((Get-SamOwnerForm))
        if ($res -eq [System.Windows.Forms.DialogResult]::OK) {
            $vals = @{}
            foreach ($k in $ctl.Keys) {
                $c = $ctl[$k]
                $vals[$k] = if (-not $c.Chk.Checked) { $c.Old } elseif ($c.Box.Text -eq $c.Shown) { $c.New } else { $c.Box.Text }
            }
            return @{ Result = 'Apply'; Values = $vals }
        }
        if ($res -eq [System.Windows.Forms.DialogResult]::Ignore) { return @{ Result = 'Skip' } }
        return @{ Result = 'Cancel' }
    }
    finally { $dlg.Dispose() }
}

function ConvertTo-SamCrLf {
    param($s)
    if ($null -eq $s) { return '' }
    return [regex]::Replace([string]$s, "(?<!`r)`n", "`r`n")
}
