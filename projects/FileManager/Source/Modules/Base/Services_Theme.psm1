# Services_Theme.psm1   (BASE TIER)
#
# PowerShell helpers that reuse the host theme ($App.Theme) so tab content
# matches the shell's fonts and colors. $App.Theme exposes: FontName, FontSizePt,
# MonoFontName, and the colors Title/Section/Header/Panel/Surface/Border/AltRow/
# Pressed/Select/Text/Muted (System.Drawing.Color), plus MakeButton()/StyleButton().

function New-StyledButton {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $App, [Parameter(Mandatory)] [string]$Text)
    return $App.Theme.MakeButton($Text)   # already styled by the host
}

function New-AppFont {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $App, [single]$Size = 0, [System.Drawing.FontStyle]$Style = [System.Drawing.FontStyle]::Regular)
    if ($Size -le 0) { $Size = $App.Theme.FontSizePt }
    return New-Object System.Drawing.Font($App.Theme.FontName, $Size, $Style)
}

function Set-HeaderStyle {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $App, [Parameter(Mandatory)] $Label)
    $Label.ForeColor = $App.Theme.Title
    $Label.Font = New-AppFont -App $App -Size ($App.Theme.FontSizePt + 3) -Style ([System.Drawing.FontStyle]::Bold)
    $Label.AutoSize = $true
}

function Set-SectionStyle {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $App, [Parameter(Mandatory)] $Label)
    $Label.ForeColor = $App.Theme.Section
    $Label.Font = New-AppFont -App $App -Style ([System.Drawing.FontStyle]::Bold)
    $Label.AutoSize = $true
}

function Initialize-TabPage {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $App, [Parameter(Mandatory)] $Page)
    $Page.BackColor = $App.Theme.Surface
    $Page.Padding = New-Object System.Windows.Forms.Padding(14, 14, 14, 14)
}
