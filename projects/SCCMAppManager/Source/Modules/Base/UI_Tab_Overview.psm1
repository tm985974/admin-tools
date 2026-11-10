# UI_Tab_Overview.psm1   (BASE TIER - project-owned)
#
# The Overview tab: what SCCM App Manager does and how to use it.

function New-OverviewTab {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Windows.Forms.TabPage]$Page,
        [Parameter(Mandatory)] $App
    )

    $header = New-Object System.Windows.Forms.Label
    $header.Text = 'SCCM App Manager'; $header.Dock = 'Top'; $header.Height = 32
    if (Get-Command Set-HeaderStyle -ErrorAction SilentlyContinue) { Set-HeaderStyle -App $App -Label $header } else { $header.ForeColor = $App.Theme.Title }

    $sub = New-Object System.Windows.Forms.Label
    $sub.Dock = 'Top'; $sub.Height = 22; $sub.ForeColor = $App.Theme.Muted
    $sub.Text = "Application lifecycle, collections and devices for ConfigMgr sites.   Active environment: $($App.ActiveLabel)"

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

    Add-Section 'Environments = sites'
    Add-Bullet 'Each environment is one SCCM site (A30, CA1 ...). Pick it on the Environment tab; every SCCM tab then works on that site.'
    Add-Bullet 'Environment > SCCM Site: site code, SMS Provider server, Local Root, Incoming / Repository / Icons paths, test collection, DP group. Test connection checks them.'
    Add-Bullet 'Environment > General: Log & data path (UNC). If it cannot be reached within 1.5 seconds, logs go to local AppData instead; leave it blank to always use AppData.'

    Add-Section 'Update Pipeline'
    Add-Bullet 'Incoming share -> 1. Pull -> 2. Update JSON -> 3. Upload to Repository -> 4. Create in SCCM -> 5. Deploy. The grid shows the next action for every application.'
    Add-Bullet 'Buttons act on the selected rows; with nothing selected, on every row that needs that step. Right-click a row for the same steps and more.'
    Add-Bullet 'JSON files carry their site (SiteCode). The grid shows this site''s JSON files (and untagged ones); other sites'' files are hidden. New exports are named <App>_<SITE>.json.'
    Add-Bullet 'Copy JSON to environment: makes a JSON for another site from the selected rows - repository, content location, icon and command paths re-pointed, every change reviewed first.'

    Add-Section 'Software, Collections, Devices'
    Add-Bullet 'Every row is shown by default. Type in Filter to narrow down, click a column header to sort, select several rows with Ctrl / Shift.'
    Add-Bullet 'Software: deployments, targeted / installed / failed counts (from SCCM deployment summaries - they can lag a few minutes). Right-click: deploy, deployments, device status, export to JSON, content.'
    Add-Bullet 'Collections: members and deployment counts. Double-click for members with install status. Right-click: add devices, deploy software to it, deployments, update membership.'
    Add-Bullet 'Devices: collections and targeted deployments per device. Select devices, right-click > Add to collection... to add them as direct members.'
    Add-Bullet 'Refresh (or F5) reloads from SCCM. Export CSV saves the rows shown. Activity... shows the activity log.'

    Add-Section 'Admin password'
    Add-Bullet 'Adds: remove devices from collections, delete deployments, retire / reinstate / delete applications, new / rename / delete collections, delete device records, clear PXE deployments.'
    Add-Bullet 'Every change made in SCCM is written to the environment''s action log (Logs\<environment>.log).'

    Add-Section 'Requirements'
    Add-Bullet 'Reading SCCM uses CIM (DCOM) to the SMS Provider - no console needed. Create, deploy, export and content actions use the ConfigMgr console''s PowerShell module, loaded the first time it is needed.'

    $Page.Controls.Add($panel)
    $Page.Controls.Add($sub)
    $Page.Controls.Add($header)
}
