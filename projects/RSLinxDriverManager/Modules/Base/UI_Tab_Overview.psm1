# UI_Tab_Overview.psm1   (BASE TIER)
#
# The Overview tab: a short guide to RSLinx Driver Manager.

function New-OverviewTab {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Windows.Forms.TabPage]$Page,
        [Parameter(Mandatory)] $App
    )

    $header = New-Object System.Windows.Forms.Label
    $header.Text = 'RSLinx Driver Manager'; $header.Dock = 'Top'; $header.Height = 32
    if (Get-Command Set-HeaderStyle -ErrorAction SilentlyContinue) { Set-HeaderStyle -App $App -Label $header } else { $header.ForeColor = $App.Theme.Title }

    $sub = New-Object System.Windows.Forms.Label
    $sub.Dock = 'Top'; $sub.Height = 22; $sub.ForeColor = $App.Theme.Muted
    $sub.Text = 'Builds and manages the RSLinx Classic Ethernet drivers on this PC from the device registry.'

    $panel = New-Object System.Windows.Forms.FlowLayoutPanel
    $panel.Dock = 'Fill'; $panel.FlowDirection = 'TopDown'; $panel.WrapContents = $false; $panel.AutoScroll = $true
    $panel.BackColor = $App.Theme.Surface; $panel.Padding = New-Object System.Windows.Forms.Padding(2, 8, 2, 8)

    $wrapWidth = 1100
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

    Add-Section 'What it does'
    Add-Bullet 'Builds the RSLinx Classic Ethernet (AB_ETH) drivers on this PC from the device registry: one driver per site and VLAN, holding every Allen-Bradley device IP on that VLAN.'
    Add-Bullet 'Driver names come from the VLAN lookup table: SITE(VLAN)DESCRIPTION, e.g. BL(25)SCADA (at most 15 characters). The site is the registry''s Lease column.'
    Add-Bullet 'Every change to the drivers on this PC saves a backup of the current drivers first.'

    Add-Section 'Drivers tab - step by step'
    Add-Bullet '1. Export the device registry to CSV, then paste the rows into the box (with or without the header row) or click Load CSV file. Pasting straight from Excel works too.'
    Add-Bullet '   Only rows whose Manufacturer is Allen-Bradley are used (Environment tab: Manufacturer to include). Primary IP and Secondary IP each become a driver node (untick Include Secondary IPs to use Primary only). Inactive devices are skipped unless ticked.'
    Add-Bullet '2. Click Build preview. Each row is one driver + IP. Untick sites you do not want on this PC. Yellow driver name = the subnet is not in the VLAN lookup table and got the default name SITE(3rd octet)SCADA - add it on the VLAN Lookup tab and build again, or edit the name. Red row = cannot be applied (see Note).'
    Add-Bullet '3. Add to this PC keeps the current drivers and adds what is missing (IPs go into the existing driver of the same name). Overwrite this PC deletes every AB_ETH driver and writes the preview.'
    Add-Bullet 'Restart RSLinx (or the PC) afterwards if it was running, so it loads the new drivers.'
    Add-Bullet 'Drivers on this PC: remove selected IPs (a driver left empty is deleted), or copy them to the preview. Backups: save the current drivers, restore one to the preview, delete. Old RSLinx.csv files and the previous tool''s backups (Name,Node) load the same way.'
    Add-Bullet 'Adding or removing drivers needs Run as administrator - the tab offers to restart elevated.'

    Add-Section 'VLAN Lookup tab'
    Add-Bullet 'One row per site + subnet (first three octets): CIDR, VLAN number and description. A row with CIDR below 24 also covers the rest of its block (e.g. 137.206.24 /21 covers 137.206.24-31) when no exact row exists.'
    Add-Bullet 'Started from the VlanLookup sheet of the old RSLinx.xlsx. Save writes Settings\VlanLookup.json under the data root - set a Log & data path on the Environment tab to share one table between PCs.'
    Add-Bullet 'Problems (wrong IP base, duplicate subnet, name too long) show in red. Import / Export CSV; Reset to shipped defaults. Editing needs the admin password (or the developer build).'

    Add-Section 'RSLinx tab'
    Add-Bullet 'Shows the RSLinx Classic control panel inside this window, plus this PC''s IP, admin rights, RSLinx service state and installed RSLogix / Studio 5000 versions.'

    Add-Section 'Environment tab'
    Add-Bullet 'Driver backup folder (UNC): where backups go (a local Backups folder is used when it is not reachable). Manufacturer to include: the device-registry Manufacturer to use.'
    Add-Bullet 'Log & data path: logs, backups fallback and the VLAN lookup table. Session.log is the file to send when something goes wrong.'

    Add-Section 'Build and update (developer build)'
    Add-Bullet 'Built on AppTemplate - see README.md. Build-App.exe / Build-App.cmd builds the developer EXE; Build Sealed makes the password-protected EXE to hand out. Never distribute the developer build.'

    # Dock order: Fill first (back), then the Top bands.
    $Page.Controls.Add($panel)
    $Page.Controls.Add($sub)
    $Page.Controls.Add($header)
}
