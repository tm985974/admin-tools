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
    $header.Text = 'App Template'; $header.Dock = 'Top'; $header.Height = 32
    if (Get-Command Set-HeaderStyle -ErrorAction SilentlyContinue) { Set-HeaderStyle -App $App -Label $header } else { $header.ForeColor = $App.Theme.Title }

    $sub = New-Object System.Windows.Forms.Label
    $sub.Dock = 'Top'; $sub.Height = 22; $sub.ForeColor = $App.Theme.Muted
    $sub.Text = 'A portable PowerShell project shell. Rename the placeholders and build your tabs in the module folders.'

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
    Add-Bullet 'One portable EXE, built from one source tree.'
    Add-Bullet 'Developer build: full tooling + embedded source. Never distribute it.'
    Add-Bullet 'Sealed build: the distributable. Prompts for a password at launch - user password = lite tier, admin password = full tier.'
    Add-Bullet 'The sealed build omits the source and seals the modules per tier (the password is the key).'

    Add-Section 'The tabs'
    Add-Bullet 'Overview - this page.'
    Add-Bullet 'Tab 1 - a wired example (reads the active environment, writes a log line).'
    Add-Bullet 'Tab 2 - a filterable grid: the reference for every list with a filter box (wildcards in any position).'
    Add-Bullet 'Tab 3-4 - empty placeholders to build on.'
    Add-Bullet 'Environment - pick, create (New), edit and Save environments. General: name, log & data path, Variable 1-4, lists & logs, logging. Projects add their own pages.'

    Add-Section 'Environments'
    Add-Bullet 'An environment is one saved set of settings (a site, a customer, a domain ...). The app ships with Config\Environments.json.'
    Add-Bullet 'Admin password / developer build: New, edit and Save on the Environment tab (saved per machine in Settings\Environments.json). User password: pick only.'
    Add-Bullet 'Developer build: Save also stages them in Config\Environments.json, so the next build ships them.'
    Add-Bullet 'If the picked environment names a reachable shared path, logs and data go there - otherwise local AppData.'

    Add-Section 'Module tiers'
    Add-Bullet 'Base - always loaded (services, theme, the tab registrar, Overview, Environment).'
    Add-Bullet 'Lite - everyone (the Tab 1-4 work tabs).'
    Add-Bullet 'Admin - admin only (empty by default; add admin-tier tabs here).'
    Add-Bullet 'One function per module keeps the Function Map meaningful.'

    Add-Section 'Lists and filters'
    Add-Bullet 'Every filter box takes wildcards anywhere: * = any text, ? = one character; plain text = contains. Case-insensitive.'
    Add-Bullet 'Use Register-ListFilter + Select-FilterMatch (Base\Services_Filter.psm1); Tab 2 shows the pattern.'
    Add-Bullet 'Filter as I type (Environment > General) filters after a short pause; off = filter on Enter. Esc clears.'

    Add-Section 'Requirements'
    Add-Bullet 'A tab names what it needs (Register-AppRequirement -Module / -Command). Checked once at start and logged; when missing, the tab says so instead of failing.'

    Add-Section 'Logging'
    Add-Bullet 'Per-environment Logs\<ENV>.log plus a shared Session.log.'
    Add-Bullet 'Machine/UTC stamped and size-capped (FIFO).'
    Add-Bullet 'Every start logs the machine: Windows, PowerShell and .NET versions, 32/64-bit. Session.log is the one file to ask for.'
    Add-Bullet 'Written to the resolved data root; never packed back into the EXE.'

    Add-Section 'Build and update (developer build)'
    Add-Bullet 'Build-App.exe (or Build-App.cmd, which compiles it) - first build or recovery; needs no PowerShell scripts. Builds the developer EXE and its Lite EXE.'
    Add-Bullet 'Update folder beside the EXE - drop update zips there; Update and Update Template open it.'
    Add-Bullet 'Update - apply a zip or a folder, preview the changes, recompile.'
    Add-Bullet 'Update Template - pick the template''s source zip: the engine files move to the newer template (checked and previewed first), project files stay.'
    Add-Bullet 'Build Lite - make <ExeName>Lite.exe, the sealed build to hand out (asks for the user and admin passwords).'
    Add-Bullet 'Build Lite - rebuild <ExeName>Lite.exe now (test passwords: admin a, user u).'
    Add-Bullet 'Extract - write the whole project out now (with FunctionMap.txt and Environment.txt) for hand-off.'
    Add-Bullet 'Open - the app folder (Archive, Update, Lite EXE), the Logs in use, or AppData (Settings, Extract).'

    Add-Section 'Make it your own'
    Add-Bullet 'New project: set AppName, ExeName and AppDataFolder in AppIdentity.json; AppHost.cs and the builder read it.'
    Add-Bullet 'Template-owned files stay identical in every project (TEMPLATE_FILES.txt); the status bar shows the template version and any changed engine files.'
    Add-Bullet 'See README.md for the full checklist.'

    # Dock order: Fill first (back), then the Top bands.
    $Page.Controls.Add($panel)
    $Page.Controls.Add($sub)
    $Page.Controls.Add($header)
}
