# UI_Tab_Overview.psm1   (BASE TIER, project-owned)
#
# The Overview tab: the Radmin offline-licensing workflow and how the tabs map
# onto it.

function New-OverviewTab {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Windows.Forms.TabPage]$Page,
        [Parameter(Mandatory)] $App
    )

    $header = New-Object System.Windows.Forms.Label
    $header.Text = 'Radmin License Manager'; $header.Dock = 'Top'; $header.Height = 32
    if (Get-Command Set-HeaderStyle -ErrorAction SilentlyContinue) { Set-HeaderStyle -App $App -Label $header } else { $header.ForeColor = $App.Theme.Title }
    $header.AutoSize = $false

    $sub = New-Object System.Windows.Forms.Label
    $sub.Dock = 'Top'; $sub.Height = 22; $sub.ForeColor = $App.Theme.Muted
    $sub.Text = 'Offline activation of Radmin Server 3 on air-gapped machines: collect the requests, activate on the website, bring the licenses back.'

    $panel = New-Object System.Windows.Forms.FlowLayoutPanel
    $panel.Dock = 'Fill'; $panel.FlowDirection = 'TopDown'; $panel.WrapContents = $false; $panel.AutoScroll = $true
    $panel.BackColor = $App.Theme.Surface; $panel.Padding = New-Object System.Windows.Forms.Padding(2, 8, 2, 8)

    $wrapWidth = 900
    function Add-Section([string]$title) {
        $l = New-Object System.Windows.Forms.Label
        $l.Text = $title; $l.AutoSize = $true; $l.Margin = New-Object System.Windows.Forms.Padding(0, 12, 0, 4)
        if (Get-Command Set-SectionStyle -ErrorAction SilentlyContinue) { Set-SectionStyle -App $App -Label $l } else { $l.ForeColor = $App.Theme.Section }
        $panel.Controls.Add($l)
    }
    function Add-Bullet([string]$text) {
        $l = New-Object System.Windows.Forms.Label
        $l.Text = [char]0x2022 + '  ' + $text
        $l.AutoSize = $true; $l.MaximumSize = New-Object System.Drawing.Size($wrapWidth, 0)
        $l.Margin = New-Object System.Windows.Forms.Padding(14, 1, 0, 1); $l.ForeColor = $App.Theme.Text
        $panel.Controls.Add($l)
    }

    Add-Section 'The round trip'
    Add-Bullet '1. Collect - every unlicensed machine saves <MACHINE>.request (rserver3.exe /saverequest). The files land in the transfer folder: Requests\.'
    Add-Bullet '2. Activate - carry the transfer folder to a PC with internet, open https://activate.famatech.com/, upload each .request and save each .license into Licenses\ (same name).'
    Add-Bullet '3. Apply - carry it back. Each machine gets its <MACHINE>.license (rserver3.exe /uselicense) and is checked: licensed = the registry key HKLM\SOFTWARE\WOW6432Node\Radmin\v3.0\Shared\Parameters\XferParam\2 exists.'
    Add-Bullet 'Licensed machines have their request and license moved to Done\, so Requests\ only ever holds what still has to go to the website.'

    Add-Section 'The tabs'
    Add-Bullet 'This Machine - the round trip for the PC this app runs on: status, Save request, Apply license (or browse for one). For machines the network cannot reach.'
    Add-Bullet 'Fleet - from one admin PC: a list of machines, Check status, Collect requests (unlicensed only), Apply licenses (where a .license is waiting). Runs in the background, several machines at a time.'
    Add-Bullet 'Environment - the license key, transfer folder and rserver3 settings (Radmin page). Editable with the admin password or in the developer build.'

    Add-Section 'Transfer folder'
    Add-Bullet 'Requests\<MACHINE>.request + _requests.csv  -  Licenses\<MACHINE>.license  -  Done\  -  README-ACTIVATION.txt (the website steps for whoever does them).'
    Add-Bullet 'Set once per environment; a PC can override it with Change... (a USB stick gets a different drive letter on every PC).'

    Add-Section 'Requirements'
    Add-Bullet 'Run as administrator - rserver3.exe needs it to save a request or apply a license. This Machine shows a Restart as administrator button when it is not.'
    Add-Bullet 'Fleet: PowerShell remoting (WinRM) on the target machines and an account that is admin there (Credential..., or the current login).'
    Add-Bullet 'Nothing here needs internet access; the only internet step is the website, on another PC.'

    Add-Section 'If something fails'
    Add-Bullet 'Double-click a Fleet row for the full result. Every action is in the environment''s action log; errors and the machine facts are in Session.log (Logs folder).'
    Add-Bullet 'rserver3 argument forms differ between the old scripts (/requestfile:"x" and /requestfile"x"): both are tried; the one that worked is reported so it can be set on Environment > Radmin.'

    $Page.Controls.Add($panel)
    $Page.Controls.Add($sub)
    $Page.Controls.Add($header)
}
