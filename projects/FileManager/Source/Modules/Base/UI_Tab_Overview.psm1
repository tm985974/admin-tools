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
    Add-Bullet 'Finds folders that are copies of each other across all your drives (only the content counts, not names or dates).'
    Add-Bullet 'Keeps one copy in X:\_Clean\<Name>\<Name>_n and moves the others to X:\_Duplicates\<Name>\<Name>_n\<Name>_n (k), so you can check them before anything is deleted.'
    Add-Bullet 'Folders with the same name (all your Desktop folders, say) end up side by side: _Clean\Desktop\Desktop_1, Desktop_2 ... A _sources.txt in each <Name> folder says where each one came from.'
    Add-Bullet 'Remembers every drive in one hash database, so you can scan one drive, unplug it, and plug in the next.'

    Add-Section 'How to use it (File Manager tab)'
    Add-Bullet 'The blue Next banner above the list always says what to do now, with a button that shows and ticks those rows. You still check them and click Move selected yourself.'
    Add-Bullet '1. Pick a drive and click Scan. Every file is read once into the hash database (hours for a big drive; Stop is safe, it carries on).'
    Add-Bullet '2. The list shows the folders at the top of the drive, biggest reward (space you get back) first. Click a column to sort by size, files or folders.'
    Add-Bullet '3. Tick the rows you want, then Move selected. You see the exact moves first. Every move stays on its drive and can be undone (Undo last).'
    Add-Bullet '4. Look through _Duplicates if you like, then Delete duplicates (each one is read again and compared with its kept copy first).'
    Add-Bullet 'Scan every drive before moving much: the oldest copy may be on a drive you have not scanned yet.'

    Add-Section 'What the list says'
    Add-Bullet 'Duplicate - the same content is kept elsewhere (Note says where). Move -> _Duplicates\<Name>\<Name>_n\<Name>_n (k), next to the kept copy''s number.'
    Add-Bullet 'Older copy found - older than the copy already in _Clean. Move swaps them: this one into _Clean, that one into _Duplicates. Select all leaves these out (setting: Ask).'
    Add-Bullet 'Keep (has copies) - this copy is the one kept (oldest files). Move -> _Clean; its copies show as Duplicate on their drives.'
    Add-Bullet 'Partly - some folders inside have copies. Double-click to look inside (Up one level to go back), or move the whole folder to _Clean.'
    Add-Bullet 'Unique - no copy anywhere in the database. Move -> _Clean.'
    Add-Bullet 'Loose files - files directly at the top of the drive. Move -> _Clean.'

    Add-Section 'Which copy is kept'
    Add-Bullet 'The copy with the oldest files (dates within 2 hours count as the same - FAT32 and time zones). Then a copy already in _Clean, then the drive priority (More > Drives), then the shortest path.'
    Add-Bullet 'Dates before 1980 or in the future (wrong clocks) are ignored.'

    Add-Section 'More (button on the page)'
    Add-Bullet 'Drives and priority - every drive in the database, priority, health check, forget a drive, Start fresh.'
    Add-Bullet 'History - every move: undo or delete just the ones you tick.'
    Add-Bullet 'Check a folder - is a folder (for example on a thumb drive) already in the database? Nothing is added or moved.'
    Add-Bullet 'Reorganize _Clean - one time: puts what earlier versions put in _Clean into the new layout.'
    Add-Bullet 'Consolidate - later: copy each _Clean to one NTFS drive, verify, remove the verified source files. Numbers are unique across drives, so nothing clashes.'

    Add-Section 'Settings (Environment tab > File Manager)'
    Add-Bullet 'Older copy than the one in _Clean (Ask / On / Off), same-date tolerance, hash every file, smallest folder to list, ignore lists (empty: everything counts).'

    Add-Section 'Good to know'
    Add-Bullet 'The database is one file: %LOCALAPPDATA%\FileManagerData\Catalog\FileManager.db (SQLite built into Windows 10/11; nothing to install).'
    Add-Bullet 'Long paths (over 260 characters) work. NTFS, exFAT and FAT32 all work. The Windows drive (C:) is never changed.'
    Add-Bullet 'Old drives can fail under long reads: More > Drives > Health check, and copy anything irreplaceable off first.'

    Add-Section 'Developer build'
    Add-Bullet 'Build-App.cmd - builds FileManagerDev.exe and, with the passwords you type, FileManagerLite.exe (the one to hand out). Never hand out the developer build.'

    # Dock order: Fill first (back), then the Top bands.
    $Page.Controls.Add($panel)
    $Page.Controls.Add($sub)
    $Page.Controls.Add($header)
}
