# UI_Tab3.psm1   (LITE TIER)
#
# Empty placeholder tab. Rename the module and function and build your UI here.
# One function per module keeps the Function Map meaningful.

function New-Tab3 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Windows.Forms.TabPage]$Page,
        [Parameter(Mandatory)] $App
    )
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = "Placeholder tab 3." + [Environment]::NewLine +
                "Build this in Modules\Lite\UI_Tab3.psm1 (function New-Tab3)."
    $lbl.Dock = 'Fill'; $lbl.Padding = New-Object System.Windows.Forms.Padding(4,4,4,4)
    $Page.Controls.Add($lbl)
}
