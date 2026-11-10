# UI_Tab_Overview.psm1   (BASE TIER)
#
# The Overview tab: a short, bulleted guide to the template. Replace this with
# your project's own overview when development begins.

function New-OverviewTab {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Windows.Forms.TabPage]$Page,
        [Parameter(Mandatory)] $App
    )

    $header = New-Object System.Windows.Forms.Label
    $header.Text = 'AD User Lookup'; $header.Dock = 'Top'; $header.Height = 32
    if (Get-Command Set-HeaderStyle -ErrorAction SilentlyContinue) { Set-HeaderStyle -App $App -Label $header } else { $header.ForeColor = $App.Theme.Title }

    $sub = New-Object System.Windows.Forms.Label
    $sub.Dock = 'Top'; $sub.Height = 22; $sub.ForeColor = $App.Theme.Muted
    $sub.Text = 'Active Directory administration, built on the portable template. One EXE, two logins: user = lookup, admin = full tools.'

    $panel = New-Object System.Windows.Forms.FlowLayoutPanel
    $panel.Dock = 'Fill'; $panel.FlowDirection = 'TopDown'; $panel.WrapContents = $false; $panel.AutoScroll = $true
    $panel.BackColor = $App.Theme.Surface; $panel.Padding = New-Object System.Windows.Forms.Padding(2, 8, 2, 8)

    $wrapWidth = 780
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

    Add-Section 'What this is'
    Add-Bullet 'One portable EXE for Active Directory administration, built from the template.'
    Add-Bullet 'Developer build: full tooling + embedded source. Never distribute it.'
    Add-Bullet 'Sealed build: the distributable. Password at launch - user password = lookup only, admin password = full tools.'
    Add-Bullet 'The sealed build omits the source and seals the modules per tier (the password is the key).'

    Add-Section 'The tabs'
    Add-Bullet 'Overview - this page.'
    Add-Bullet 'User Lookup (everyone) - search AD users, copy and export. This is what the user password gets.'
    Add-Bullet 'Users, Groups, Account Management, Computers, Bulk Operations, Infrastructure, Tools, Audit (admin only) - the full AD Admin toolset.'
    Add-Bullet 'Admin tabs build the first time you open one; the first one connects to the domain, the rest then build in the background.'
    Add-Bullet 'Environment - the 1.6.1 Domain Defaults: pick, create (New), edit and Save a domain''s settings on General, Domain, Accounts, Mail and Messages.'

    Add-Section 'Domains (environments)'
    Add-Bullet 'Each environment is one domain with all of its settings. Ships with AERAIPCS.COM and CA1-OG.ADS (from 1.6.1).'
    Add-Bullet 'Admin password: New / edit / Save on the Environment tab (saved per machine). User password: pick only.'
    Add-Bullet 'User Lookup and the admin tabs use the picked domain (Domain page: Domain, optional DC); blank = the current domain.'
    Add-Bullet 'If the domain names a reachable shared path, logs and data go there - otherwise local AppData.'

    Add-Section 'Module tiers'
    Add-Bullet 'Base - always loaded (services, theme, the tab registrar, Overview, Environment).'
    Add-Bullet 'Lite - everyone (User Lookup).'
    Add-Bullet 'Admin - admin only (the AD tool areas; a user-password launch never decrypts them).'
    Add-Bullet 'One function per module keeps the Function Map meaningful.'

    Add-Section 'Logging'
    Add-Bullet 'Per-environment Logs\<ENV>.log plus a shared Session.log.'
    Add-Bullet 'Admin actions: per-domain Logs\<DOMAIN>.log (Tools > Operation Log), as in the original tool.'
    Add-Bullet 'Settings you save (environment settings, word lists) live in <data root>\Settings and survive restarts.'
    Add-Bullet 'Machine/UTC stamped and size-capped (FIFO).'
    Add-Bullet 'Written to the resolved data root; never packed back into the EXE.'

    Add-Section 'Build and update (developer build)'
    Add-Bullet 'Build-App.ps1 - first build or recovery.'
    Add-Bullet 'Update - apply a zip or a folder, preview the changes, recompile.'
    Add-Bullet 'Build Sealed - mint the distributable with user/admin passwords.'
    Add-Bullet 'Extract - write the whole project out (with FunctionMap.txt and Environment.txt) for hand-off.'

    Add-Section 'Make it your own'
    Add-Bullet 'New project: change only the PROJECT IDENTITY block in AppHost.cs (AppName, ExeName, AppDataFolder); Build-App.ps1 reads it.'
    Add-Bullet 'Template-owned files stay identical in every project (TEMPLATE_FILES.txt); the status bar shows the template version and any changed engine files.'
    Add-Bullet 'See README.md for the full checklist.'

    # Dock order: Fill first (back), then the Top bands.
    $Page.Controls.Add($panel)
    $Page.Controls.Add($sub)
    $Page.Controls.Add($header)
}
