# UI_EmbeddedTabPage.psm1   (BASE TIER)
#
#   $tp = New-EmbeddedTabPage -Parent $panel -X 0 -Y 0 -Width 1400 -Height 820
#
# Returns a [TabPage] whose client area is exactly Width x Height at X,Y inside
# -Parent, WITHOUT a visible tab strip or border. For ported code whose build
# functions take a [TabPage] parameter (a TabPage can only live inside a
# TabControl): the page sits in a one-page TabControl that is shifted so its
# strip and border fall outside a clipping panel. Nothing about it looks like a
# sub-tab.

function New-EmbeddedTabPage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Windows.Forms.Control]$Parent,
        [int]$X = 0,
        [int]$Y = 0,
        [Parameter(Mandatory)] [int]$Width,
        [Parameter(Mandatory)] [int]$Height,
        [string]$Title = 'Page'
    )
    $clip = New-Object System.Windows.Forms.Panel
    $clip.Location  = New-Object System.Drawing.Point($X, $Y)
    $clip.Size      = New-Object System.Drawing.Size($Width, $Height)
    $clip.BackColor = $Parent.BackColor
    $Parent.Controls.Add($clip)

    $tc = New-Object System.Windows.Forms.TabControl
    $tc.TabStop = $false
    $tc.Location = New-Object System.Drawing.Point(0, 0)
    $tc.Size     = New-Object System.Drawing.Size($Width, $Height)
    $tp = New-Object System.Windows.Forms.TabPage $Title
    $tp.UseVisualStyleBackColor = $false
    $tp.BackColor = $Parent.BackColor
    $tc.TabPages.Add($tp)
    $clip.Controls.Add($tc)

    # Real strip/border sizes need the window handle; then move the strip and
    # border out of view and make the page's client area exactly Width x Height.
    try {
        [void]$tc.Handle
        $dr = $tc.DisplayRectangle
        $padW = $tc.Width  - $dr.Width
        $padH = $tc.Height - $dr.Height
        $tc.Location = New-Object System.Drawing.Point((-$dr.X), (-$dr.Y))
        $tc.Size     = New-Object System.Drawing.Size(($Width + $padW), ($Height + $padH))
    }
    catch {
        # fallback: typical strip/border for Segoe UI 9pt
        $tc.Location = New-Object System.Drawing.Point(-4, -24)
        $tc.Size     = New-Object System.Drawing.Size(($Width + 8), ($Height + 28))
    }
    return $tp
}

#   Set-EmbeddedTabPageSize -Page $tp -Width 1400 -Height 600
# Resizes a page made by New-EmbeddedTabPage (e.g. to fit what was built in it).
function Set-EmbeddedTabPageSize {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Windows.Forms.TabPage]$Page,
        [Parameter(Mandatory)] [int]$Width,
        [Parameter(Mandatory)] [int]$Height
    )
    $tc = $Page.Parent; if (-not $tc) { return }
    $clip = $tc.Parent; if (-not $clip) { return }
    $padW = $tc.Width  - $clip.Width
    $padH = $tc.Height - $clip.Height
    $clip.Size = New-Object System.Drawing.Size($Width, $Height)
    $tc.Size   = New-Object System.Drawing.Size(($Width + $padW), ($Height + $padH))
}
