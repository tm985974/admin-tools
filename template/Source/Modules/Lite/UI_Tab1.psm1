# UI_Tab1.psm1   (LITE TIER)
#
# Wired reference tab. Copy this pattern for real tabs:
#   read the active environment -> do work -> write to the log -> update the UI.
# Hover help for its buttons is in Config\ToolTips.json ("Tab 1 > ..."); the
# "Open data root" button shows how an action that runs a command uses
# Invoke-AppCommand / Register-AppCommand (exact command, copyable).

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

    # Anything that runs a command goes through the engine (Base\Services_Commands.psm1):
    # build the PowerShell as text with the real values, then Invoke-AppCommand
    # shows it first when the setting (or Shift+click) asks for it, logs it, and
    # runs exactly that text. Register-AppCommand adds right-click
    # "Show command... / Copy command" to the button.
    $fmt = ${function:Format-AppCommandValue}     # captured: closures do not see module functions reliably
    $run = ${function:Invoke-AppCommand}
    $openCode = { 'Start-Process -FilePath ''explorer.exe'' -ArgumentList ' + (& $fmt ('"{0}"' -f $App.DataRoot)) }.GetNewClosure()
    Register-AppCommand -App $App -Control $btnOpen -Title 'Open data root' -Code $openCode
    $btnOpen.Add_Click({
        $r = & $run -App $App -Title 'Open data root' -Kind Read -Code (& $openCode)
        if ($r.Errors.Count -gt 0) { $status.Text = "Could not open it: $($r.Errors[0])" }
    }.GetNewClosure())

    $Page.Controls.Add($hdr); $Page.Controls.Add($info)
    $Page.Controls.Add($btnLog); $Page.Controls.Add($btnOpen); $Page.Controls.Add($status)
}
