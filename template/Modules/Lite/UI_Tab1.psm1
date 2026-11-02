# UI_Tab1.psm1   (LITE TIER)
#
# Wired reference tab. Copy this pattern for real tabs:
#   read the active environment -> do work -> write to the log -> update the UI.

function New-Tab1 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Windows.Forms.TabPage]$Page,
        [Parameter(Mandatory)] $App
    )

    # What this tab needs on the machine (Base\Services_Requirements.psm1). Checked
    # once at start-up and logged; when missing, the tab shows a message instead.
    # A real tab names its real dependency, e.g.
    #   -Module 'ActiveDirectory' -Hint 'Install RSAT: Active Directory module for Windows PowerShell.'
    if (-not (Register-AppRequirement -App $App -Page $Page -For 'Tab 1' -Module 'Microsoft.PowerShell.Management')) { return }

    $hdr = New-Object System.Windows.Forms.Label
    $hdr.Text = 'Tab 1 - wired example'; $hdr.Location = New-Object System.Drawing.Point(4, 4); $hdr.AutoSize = $true
    if (Get-Command Set-HeaderStyle -ErrorAction SilentlyContinue) { Set-HeaderStyle -App $App -Label $hdr } else { $hdr.ForeColor = $App.Theme.Title }

    $info = New-Object System.Windows.Forms.Label
    $info.Location = New-Object System.Drawing.Point(6, 44); $info.AutoSize = $true
    $info.Text = "Active environment: {0}   (data: {1})" -f $App.ActiveLabel, $App.DataRootStatus

    $btnLog = $App.Theme.MakeButton('Write test log line')
    $btnLog.Location = New-Object System.Drawing.Point(8, 80)

    $btnOpen = $App.Theme.MakeButton('Open data root')
    $btnOpen.Location = New-Object System.Drawing.Point(180, 80)

    $status = New-Object System.Windows.Forms.Label
    $status.Location = New-Object System.Drawing.Point(8, 120); $status.AutoSize = $true; $status.ForeColor = $App.Theme.Muted
    $status.Text = 'Ready.'

    $btnLog.Add_Click({
        $App.Log('INFO', 'Tab1', 'Test log line from Tab 1.')
        $App.LogAction('Tab 1: user wrote a test action-log line.')
        $status.Text = "Wrote Session.log + $($App.ActiveName).log under: $($App.DataRoot)\Logs"
    }.GetNewClosure())

    $btnOpen.Add_Click({
        try { Start-Process explorer.exe ('"{0}"' -f $App.DataRoot) } catch {}
    }.GetNewClosure())

    $Page.Controls.Add($hdr); $Page.Controls.Add($info)
    $Page.Controls.Add($btnLog); $Page.Controls.Add($btnOpen); $Page.Controls.Add($status)
}
