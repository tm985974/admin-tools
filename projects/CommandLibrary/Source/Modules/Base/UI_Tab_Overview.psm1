# UI_Tab_Overview.psm1   (BASE TIER, project-owned)
#
# The Overview tab: what Command Library does and how to use it.

function New-OverviewTab {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Windows.Forms.TabPage]$Page,
        [Parameter(Mandatory)] $App
    )

    $header = New-Object System.Windows.Forms.Label
    $header.Text = 'Command Library'; $header.Dock = 'Top'; $header.Height = 32
    if (Get-Command Set-HeaderStyle -ErrorAction SilentlyContinue) { Set-HeaderStyle -App $App -Label $header } else { $header.ForeColor = $App.Theme.Title }

    $sub = New-Object System.Windows.Forms.Label
    $sub.Dock = 'Top'; $sub.Height = 22; $sub.ForeColor = $App.Theme.Muted
    $sub.Text = 'Every command and function worth keeping, in one place: searchable, explained, and runnable with a prompt for its settings.'

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

    Add-Section 'What it is'
    Add-Bullet 'A library of PowerShell commands you have needed before - from past chats and from the modules of your other projects.'
    Add-Bullet 'Each entry has a description, how to use it, where to run it, what it needs, and the code itself.'
    Add-Bullet 'Two kinds of entry. Commands (marked "syntax"): one command or short script with fields - a syntax builder that shows the exact line as you fill it in, ready to copy or run.'
    Add-Bullet 'Functions: bigger tasks that combine several commands (health reports, comparisons, installs). Run... reads their parameters and asks for them.'
    Add-Bullet 'Every command a function uses is also its own command entry, so you can run or copy just that step. Nothing launches a .ps1 or another PowerShell.'

    Add-Section 'Library tab'
    Add-Bullet 'Type in Search: it looks at the name and keywords only, by whole words (every word must match; "ping" finds Ping, not "mapping"). Tick "Search descriptions too" for a wider search. Filter by category.'
    Add-Bullet 'Status says whether an entry will work on THIS computer: Ready, Ready - via a fallback, Not on a domain, Missing (software) or Needs admin. Details shows what is missing and the fix. "Runnable here only" hides the ones that would fail.'
    Add-Bullet 'Details shows the description, how to use, where to run, requirements, parameters and an example. Code shows exactly what runs.'
    Add-Bullet 'Run... (or double-click / Enter) opens a prompt built from the parameters: text boxes, drop-downs for fixed choices, check boxes for switches, one-per-line lists, Set... for credentials.'
    Add-Bullet 'For commands, the Command box below the fields is the syntax guide: options you leave empty or unticked are left out of the line. Copy command puts it on the clipboard for a PowerShell window, a script or a GPO.'
    Add-Bullet 'Values start from your last run of that entry, then from the active environment (a parameter named Domain, Server or SearchBase takes the environment value).'
    Add-Bullet 'The exact command is shown before it runs. Entries that change things are marked, ask for confirmation, and offer WhatIf when the function supports it.'
    Add-Bullet 'Run on this computer, or on a list of computers through remoting (Invoke-Command), optionally with other credentials. Credentials are never saved.'
    Add-Bullet 'Before a run, the computers in target fields (or the remote list) are checked: DNS and the port the command uses. One that does not answer is reported in a second instead of after a timeout; remote runs skip it. Check now tests without running.'
    Add-Bullet 'Some entries have fallbacks (e.g. an LDAP query when RSAT is not installed). The first method that can run here is used; read-only entries move on to the next method if one fails for an environment reason.'
    Add-Bullet 'The run happens in the background: Results (as the console shows them), Grid, and Messages (errors, warnings, verbose, Write-Host). Stop, Copy, Export CSV. A failure ends with a WHY line: software, connectivity, rights, credentials, input or policy.'

    Add-Section 'Import tab (admin)'
    Add-Bullet 'Pick another project (an Extract zip, an Archive\Zip file, a folder) or module files and Scan. Files are parsed, never run.'
    Add-Bullet 'Each function is checked: helpers it calls are bundled with it; anything tied to its project (the UI, $App, module $script: state, launching a .ps1) marks it Blocked.'
    Add-Bullet 'Ready = runs on its own. Review = read the note first (input prompts, undefined variables, unknown commands). Blocked = cannot be checked.'
    Add-Bullet 'Imported code is a snapshot with its source, version and hash. Scan the same project later: changed functions show as Changed, and Update changed refreshes the code and keeps your descriptions.'

    Add-Section 'Adding your own'
    Add-Bullet 'New... > Command (admin) - write the command with {Field} where a value goes and [[ ... ]] around optional parts, e.g.  gpupdate[[ /target:{Target}]][[ /force{Force}]]  - then "Add missing fields" and set their types.'
    Add-Bullet 'New... > Function (admin) - paste a function from a chat into Code, click Analyze, then Fill from help or write the description. Save.'
    Add-Bullet 'Ask Claude for "a library entry for this": a function with comment help (.SYNOPSIS, .EXAMPLE, .PARAMETER) fills most fields for you.'

    Add-Section 'Where the library lives'
    Add-Bullet 'Settings\Library.json under the data root. Give an environment a shared "Log & data path" and everyone using it shares one library.'
    Add-Bullet 'The EXE ships a starting set (Config\Library.json). New shipped entries are added on start; ones you deleted stay deleted; ones you edited are left alone.'
    Add-Bullet 'Every run is written to the environment action log (Logs\<ENV>.log) with the command line - never credentials.'

    Add-Section 'Tiers'
    Add-Bullet 'User password: search, read and run.'
    Add-Bullet 'Admin password / developer build: also New / Edit / Delete and the Import tab.'

    # Dock order: Fill first (back), then the Top bands.
    $Page.Controls.Add($panel)
    $Page.Controls.Add($sub)
    $Page.Controls.Add($header)
}
