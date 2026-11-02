#region -- ADDirectory.Users.Grid.psm1 ----------------------------------------
# Concern : Update-UserGrid - pushes filtered user data into the Users grid
#           with disabled-row dimming and locked-out row highlight.
# Load order: 12 - depends on ADDirectory.Users.Filter (Get-FilteredUsers),
#                            ADDirectory.Users.Load (script scope),
#                            Services.AD.Reporting (Set-GridData)
# Split from: ADDirectory.Tab.psm1
# Changes   : New column set / order for the Users grid: Display Name, SAM
#             Account Name, Created, Enabled, Locked Out, Pw Never Expires, PW
#             Last Set, Last Logon, Email, Pager, Mobile, Description. UPN,
#             Department, Title, and OU columns removed from view (the fields
#             remain on the cached object for filtering/sorting elsewhere).
#             After the data push, friendly header text is applied locally
#             (Set-GridData is a shared helper that headers by raw property
#             name, so it is left untouched) and column autosizing is set so
#             every column sizes to its widest content while Description
#             takes the remaining width (with a minimum so it never collapses;
#             a horizontal scrollbar appears if no width is left over).
#             The sort-column order in Get-FilteredUsers is kept identical to
#             this display order so header-click sorting maps correctly.
#endregion

#region -- Update-UserGrid ----------------------------------------------------
function Update-UserGrid {
    if (-not $script:UserGrid) { return }
    $data = Get-FilteredUsers
    $cols = @('DisplayName','SamAccountName','Created','Enabled','LockedOut',
              'PwNeverExpires','PasswordLastSet','LastLogon','Email','Pager','Mobile','Description')
    Set-GridData -Grid $script:UserGrid -Data $data -Columns $cols

    # Set-GridData headers by raw property name and rebuilds columns on every
    # call (and returns early with no columns when $data is empty), so friendly
    # headers and autosizing are re-applied here each refresh, guarded for the
    # empty-grid case.
    if ($script:UserGrid.Columns.Count -gt 0) {
        $headers = [ordered]@{
            DisplayName     = 'Display Name'
            SamAccountName  = 'SAM Account Name'
            Created         = 'Created'
            Enabled         = 'Enabled'
            LockedOut       = 'Locked Out'
            PwNeverExpires  = 'Pw Never Expires'
            PasswordLastSet = 'PW Last Set'
            LastLogon       = 'Last Logon'
            Email           = 'Email'
            Pager           = 'Pager'
            Mobile          = 'Mobile'
            Description     = 'Description'
        }
        foreach ($key in $headers.Keys) {
            if ($script:UserGrid.Columns.Contains($key)) {
                $script:UserGrid.Columns[$key].HeaderText = $headers[$key]
            }
        }

        # Autosize each column to the widest header/content, then let
        # Description consume any remaining width.
        #
        # PERFORMANCE FIX: was 'AllCells', which forces WinForms to measure
        # the rendered text width of every cell in EVERY row on EVERY grid
        # refresh (~10,000 GDI+ measurements at 836 users x 12 columns,
        # clocked at ~86s in diagnostics). Update-UserGrid runs on every
        # column-header click (see Add_ColumnHeaderMouseClick in
        # ADDirectory.Register-DirectoryTab), so every sort paid this cost.
        # 'DisplayedCells' keeps the same size-to-content look but only
        # measures rows currently scrolled into view - Groups/Computers
        # grids already use the cheap default and were never affected.
        $script:UserGrid.AutoSizeColumnsMode = 'DisplayedCells'
        if ($script:UserGrid.Columns.Contains('Description')) {
            $descCol = $script:UserGrid.Columns['Description']
            $descCol.AutoSizeMode = 'Fill'
            $descCol.MinimumWidth = 160
        }
    }

    foreach ($row in $script:UserGrid.Rows) {
        if ($row.Cells['Enabled'].Value -eq 'False') {
            $row.DefaultCellStyle.ForeColor = [System.Drawing.Color]::FromArgb(160,160,160)
        }
        if ($row.Cells['LockedOut'].Value -eq 'True') {
            $row.DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(255,235,156)
        }
    }
    if ($script:LblUserCount) { $script:LblUserCount.Text = "$($data.Count) of $($script:AllUsers.Count)" }
}
#endregion

Export-ModuleMember -Function Update-UserGrid
