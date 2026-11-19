# UI_Tab_Overview.psm1   (BASE TIER)
#
# The Overview tab: a short, bulleted guide to File Manager.

function New-OverviewTab {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Windows.Forms.TabPage]$Page,
        [Parameter(Mandatory)] $App
    )

    $header = New-Object System.Windows.Forms.Label
    $header.Text = 'File Manager'; $header.Dock = 'Top'; $header.Height = 32
    if (Get-Command Set-HeaderStyle -ErrorAction SilentlyContinue) { Set-HeaderStyle -App $App -Label $header } else { $header.ForeColor = $App.Theme.Title }

    $sub = New-Object System.Windows.Forms.Label
    $sub.Dock = 'Top'; $sub.Height = 22; $sub.ForeColor = $App.Theme.Muted
    $sub.Text = 'Find duplicate folders across all your drives, keep one copy, and move the rest aside safely.'

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
    Add-Bullet 'Finds folders that are copies of each other across all your drives (names and dates do not matter, only the content).'
    Add-Bullet 'Keeps one copy and moves the others aside, so you can check them before anything is deleted.'
    Add-Bullet 'Remembers every drive in one catalog, so you can scan one drive, unplug it, and plug in the next.'

    Add-Section 'The steps'
    Add-Bullet 'The Workflow tab shows these steps as a checklist, with where you are and a button for each.'
    Add-Bullet '1. Scan - quick-scan every drive (names and sizes, minutes per drive). Then run the content check (reads only the files that might be duplicates).'
    Add-Bullet '2. Duplicates - review the groups, biggest saving first. Green = kept, red = moves. Pick a different keeper with Make keeper.'
    Add-Bullet '3. Actions > Build plan - lists every move with a tick box. Nothing moves yet.'
    Add-Bullet '4. Tick all, some or one, then Move selected. You see the exact commands first. Unticked steps wait for later (Reports > Open batch).'
    Add-Bullet '5. Check the _Duplicates folders by hand if you like. Then tick them and Delete selected duplicates (each one is re-checked first).'
    Add-Bullet '6. Later, when there is room: Consolidate - copy each drive''s _Clean to one NTFS drive, verify, and remove the verified source files.'

    Add-Section 'Scan modes (Scan tab)'
    Add-Bullet 'Whole drive - the usual scan.'
    Add-Bullet 'One folder - scan one folder; the rest of that drive in the catalog stays. Actions can then plan for just that folder.'
    Add-Bullet 'Check only - compare a folder (for example on a thumb drive) with the catalog: already have it, partly, or new. Nothing is added or moved.'

    Add-Section 'Where things go (on each drive)'
    Add-Bullet 'X:\_Clean\<original path>  - the kept copies and every folder that has no duplicate.'
    Add-Bullet 'X:\_Duplicates\<kept folder path>\<name>\<name> (1), (2) ...  - the copies, renamed after the kept folder, numbered across all drives.'
    Add-Bullet 'Next to each (n) folder: <name> (n)_origin.txt - where it came from and where the kept copy is. The copy itself is left exactly as it was.'
    Add-Bullet 'Moves stay on the same drive (a rename): instant, no free space needed, and every step can be undone (Reports > Open batch > Undo selected).'

    Add-Section 'Which copy is kept'
    Add-Bullet 'Your pick (Make keeper) wins. Otherwise: a copy already in _Clean, then the copy with the oldest files, then the drive with the lowest priority number (Drives tab), then the shortest path.'
    Add-Bullet 'Top-down: when a whole folder is a copy, its sub folders are not listed again. A duplicate inside a unique folder moves alone; the rest stays.'

    Add-Section 'Matching rules'
    Add-Bullet 'Quick match: the same file sizes in the same folder layout. Content match: the same file contents (hash) in the same layout.'
    Add-Bullet 'Only content matches move, unless you tick Include quick matches.'
    Add-Bullet 'Every file counts (default): folders only match when they are identical. Optional ignore lists are on the Scan tab. Empty folders hold no data and are not compared.'
    Add-Bullet 'Contained folders: a folder whose files are all inside another, bigger folder (an older backup of a folder that grew). Report only.'

    Add-Section 'Good to know'
    Add-Bullet 'The catalog is one file: %LOCALAPPDATA%\FileManagerData\Catalog\FileManager.db (SQLite built into Windows 10/11; nothing to install).'
    Add-Bullet 'Stop is safe at any time. Hashes made so far are kept; Content check only carries on where it stopped.'
    Add-Bullet 'Start fresh (Drives tab) empties the catalog to begin again; nothing on the drives changes.'
    Add-Bullet 'Long paths (over 260 characters) work. NTFS, exFAT and FAT32 all work. The Windows drive (C:) is never changed.'
    Add-Bullet 'Old drives can fail under long reads: use Health check (Drives tab) and copy anything irreplaceable off first.'
    Add-Bullet 'File hashes are saved during scans, so the next phase (duplicate files) will not need to read the drives again.'

    Add-Section 'Developer build'
    Add-Bullet 'Build-App.cmd - builds FileManagerDev.exe and, with the passwords you type, FileManagerLite.exe (the one to hand out).'
    Add-Bullet 'Never hand out the developer build: it contains the source.'

    # Dock order: Fill first (back), then the Top bands.
    $Page.Controls.Add($panel)
    $Page.Controls.Add($sub)
    $Page.Controls.Add($header)
}
