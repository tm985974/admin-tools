# UI_Layout.psm1   (BASE TIER)
#
#   $area = Get-TabPageArea -Tabs $MainTabs
#
# The usable size (Width x Height) of a page in the main TabControl right now -
# what a fixed-layout tab should be designed against so it fits the window
# without scrolling. The window opens sized for the target screen (AppHost.cs
# TargetScreenWidth / TargetScreenHeight; maximized on a screen that size or
# smaller), so call this when a tab is BUILT (lazily, after the window is
# shown), not at launch. -MinWidth / -MinHeight floor the result for layouts
# that cannot shrink further; the page then scrolls.

function Get-TabPageArea {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Windows.Forms.TabControl]$Tabs,
        [int]$MinWidth  = 0,
        [int]$MinHeight = 0
    )
    $w = 0; $h = 0
    try {
        $r = $Tabs.DisplayRectangle
        $w = $r.Width - 2; $h = $r.Height - 2      # 1px breathing room each side, no stray scrollbars
    } catch { }
    if ($w -lt $MinWidth)  { $w = $MinWidth }
    if ($h -lt $MinHeight) { $h = $MinHeight }
    return New-Object System.Drawing.Size($w, $h)
}
