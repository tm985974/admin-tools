# UI_Tab_Overview.psm1   (BASE TIER)
#
# The Overview tab: what ToolBox does and the usual update routine.

function New-OverviewTab {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Windows.Forms.TabPage]$Page,
        [Parameter(Mandatory)] $App
    )

    $header = New-Object System.Windows.Forms.Label
    $header.Text = 'ToolBox'; $header.Dock = 'Top'; $header.Height = 32
    if (Get-Command Set-HeaderStyle -ErrorAction SilentlyContinue) { Set-HeaderStyle -App $App -Label $header } else { $header.ForeColor = $App.Theme.Title }

    $sub = New-Object System.Windows.Forms.Label
    $sub.Dock = 'Top'; $sub.Height = 22; $sub.ForeColor = $App.Theme.Muted
    $sub.Text = 'One place to run, build and update the admin tools in this folder.'

    $panel = New-Object System.Windows.Forms.FlowLayoutPanel
    $panel.Dock = 'Fill'; $panel.FlowDirection = 'TopDown'; $panel.WrapContents = $false; $panel.AutoScroll = $true
    $panel.BackColor = $App.Theme.Surface; $panel.Padding = New-Object System.Windows.Forms.Padding(2, 8, 2, 8)

    $wrapWidth = 820
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

    Add-Section 'The tabs'
    Add-Bullet 'Tools - every tool in the projects folder. Launch runs its sealed EXE when the environment''s Sealed EXE folder has one, otherwise its Lite (test) EXE.'
    Add-Bullet 'Developer - each tool''s source version against the EXE built from it. Build selected / Build all run each tool''s Build-App.cmd here, one at a time, with the output below the list.'
    Add-Bullet 'Update - Open zip... (a zip of the repository downloaded from GitHub) shows which tools change; Apply update replaces their source and builds them. Pull (git) appears when this folder is a git clone.'
    Add-Bullet 'Environment - Projects folder (blank = the folder ToolBox sits in) and Sealed EXE folder.'

    Add-Section 'Updating the tools'
    Add-Bullet 'On GitHub: open the repository, choose the branch, Code > Download ZIP.'
    Add-Bullet 'Here: Update > Open zip... > check the list > Apply update. With "Build all after the update" ticked, the Developer tab builds every tool.'
    Add-Bullet 'Close the tools first - a running EXE cannot be replaced, so that tool is skipped (build it again afterwards).'
    Add-Bullet 'ToolBox cannot rebuild itself while it runs: close it and double-click its Build-App.cmd (or Build-All.cmd at the top of the repository, which builds every tool).'
    Add-Bullet 'The replaced Source folders are kept in <repository>\_Backup\Update_<time>.'

    Add-Section 'Good to know'
    Add-Bullet 'Building on this PC makes the EXEs locally, so they run where downloaded EXEs are blocked.'
    Add-Bullet 'Lite EXEs are sealed TEST builds (admin password "a", user password "u") - for your own use. For others, make a sealed EXE with Build Sealed in the tool''s developer EXE and keep it in the Sealed EXE folder.'
    Add-Bullet 'Every launch, build and update shows its exact command first (Environment > General > Commands decides when).'
    Add-Bullet 'Saved environments and logs of each tool live in its AppData folder, so a rebuild or update keeps them.'

    # Dock order: Fill first (back), then the Top bands.
    $Page.Controls.Add($panel)
    $Page.Controls.Add($sub)
    $Page.Controls.Add($header)
}
