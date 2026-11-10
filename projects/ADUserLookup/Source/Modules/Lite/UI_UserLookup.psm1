# UI_UserLookup.psm1   (LITE TIER)
#
# The AD User Lookup, matching the original tool's proven query: a plain
# DirectorySearcher against the CURRENT domain (no server targeting). If the
# active environment names a Server it is tried first and falls back to the
# current domain on any failure. No RSAT needed.
#
# Copy/Export read values straight from the grid cells, and the column lists are
# LOCAL variables captured by the handlers (not $script:), so they resolve
# reliably when a button fires from the event thread.

Add-Type -AssemblyName System.DirectoryServices -ErrorAction SilentlyContinue

function Get-ULProp($r, [string]$name) {
    if ($r.Properties.Contains($name) -and $r.Properties[$name].Count -gt 0) { return [string]$r.Properties[$name][0] }
    return ''
}
function Get-ULLong($r, [string]$name) {
    if (-not $r.Properties.Contains($name) -or $r.Properties[$name].Count -eq 0) { return [int64]0 }
    try { return [int64]$r.Properties[$name][0] } catch { return [int64]0 }
}
function ConvertTo-ULFileTime([int64]$ft, [string]$empty) {
    if ($ft -le 0 -or $ft -eq [int64]::MaxValue) { return $empty }
    try { return [DateTime]::FromFileTime($ft).ToString('yyyy-MM-dd HH:mm') } catch { return $empty }
}
function Get-ULou([string]$dn) {
    if ([string]::IsNullOrEmpty($dn)) { return '' }
    $parts = $dn -split '(?<!\\),'
    $path = @()
    for ($i = 1; $i -lt $parts.Count; $i++) {
        $p = $parts[$i]; $eq = $p.IndexOf('=')
        if ($eq -lt 0) { continue }
        $type = $p.Substring(0, $eq).Trim().ToUpperInvariant()
        if ($type -eq 'OU' -or $type -eq 'CN') { $path += $p.Substring($eq + 1) }
    }
    return ($path -join ' / ')
}

# One full query + map, exactly like the original (plain searcher = current domain).
function Get-ULRows([string]$server) {
    $rows = New-Object System.Collections.Generic.List[object]
    if (-not [string]::IsNullOrWhiteSpace($server)) {
        $searcher = New-Object System.DirectoryServices.DirectorySearcher(
            (New-Object System.DirectoryServices.DirectoryEntry("LDAP://$server")))
    } else {
        $searcher = New-Object System.DirectoryServices.DirectorySearcher   # current domain
    }
    $searcher.Filter = '(&(objectCategory=person)(objectClass=user))'
    $searcher.PageSize = 1000
    foreach ($p in @('givenName','sn','sAMAccountName','displayName','userPrincipalName',
                     'telephoneNumber','mobile','mail','userAccountControl','lockoutTime',
                     'lastLogonTimestamp','pwdLastSet','accountExpires','whenCreated','distinguishedName')) {
        [void]$searcher.PropertiesToLoad.Add($p)
    }
    $results = $searcher.FindAll()
    try {
        foreach ($r in $results) {
            try {
                $uac         = [int](Get-ULLong $r 'userAccountControl')
                $lockoutTime = Get-ULLong $r 'lockoutTime'
                $pwdLastSet  = Get-ULLong $r 'pwdLastSet'
                $created = ''
                if ($r.Properties.Contains('whenCreated') -and $r.Properties['whenCreated'].Count -gt 0) {
                    try { $created = ([DateTime]$r.Properties['whenCreated'][0]).ToLocalTime().ToString('yyyy-MM-dd HH:mm') } catch { }
                }
                [void]$rows.Add(@(
                    (Get-ULProp $r 'givenName'), (Get-ULProp $r 'sn'), (Get-ULProp $r 'sAMAccountName'),
                    (Get-ULProp $r 'displayName'), (Get-ULProp $r 'userPrincipalName'),
                    (Get-ULProp $r 'telephoneNumber'), (Get-ULProp $r 'mobile'), (Get-ULProp $r 'mail'),
                    $(if (($uac -band 0x2) -eq 0) { 'Yes' } else { 'No' }),
                    $(if ($lockoutTime -gt 0) { 'Yes' } else { 'No' }),
                    (ConvertTo-ULFileTime (Get-ULLong $r 'lastLogonTimestamp') 'Never'),
                    $(if ($pwdLastSet -eq 0) { 'Must change at next logon' } else { ConvertTo-ULFileTime $pwdLastSet 'Never' }),
                    $(if (($uac -band 0x10000) -ne 0) { 'Yes' } else { 'No' }),
                    (ConvertTo-ULFileTime (Get-ULLong $r 'accountExpires') 'Never'),
                    $created,
                    (Get-ULou (Get-ULProp $r 'distinguishedName'))
                ))
            }
            catch { continue }
        }
    }
    finally { if ($results) { $results.Dispose() } }
    return ,$rows
}

function Invoke-ULQuery($App) {
    # The environment's Server (a DC), else its Domain; blank = the current domain.
    $server = ''
    if ($null -ne $App) { $server = [string]$App.GetSetting('Server'); if (-not $server) { $server = [string]$App.GetSetting('Domain') } }
    try { return (Get-ULRows $server) }
    catch {
        if (-not [string]::IsNullOrWhiteSpace($server)) { return (Get-ULRows '') }
        throw
    }
}

function New-UserLookupTab {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Windows.Forms.TabPage]$Page,
        [Parameter(Mandatory)] $App
    )

    # LOCAL column lists - captured by the handlers via .GetNewClosure().
    $cols = @(
        'First name','Last name','Account name','Display name','UPN',
        'Telephone','Mobile','Email',
        'Enabled','Locked out','Last logon','Password last set',
        'Password never expires','Account expires','Created','OU'
    )
    $copyCols = @('First name','Last name','Account name','Telephone','Email')

    $top = New-Object System.Windows.Forms.FlowLayoutPanel
    $top.Dock = 'Top'; $top.Height = 38; $top.WrapContents = $false; $top.Padding = New-Object System.Windows.Forms.Padding(2,4,2,2)

    $lbl = New-Object System.Windows.Forms.Label; $lbl.Text = 'Search:'; $lbl.AutoSize = $true; $lbl.Margin = '0,8,4,0'
    $search = New-Object System.Windows.Forms.TextBox; $search.Width = 240; $search.Margin = '0,4,12,0'
    $btnClear   = $App.Theme.MakeButton('Clear filters')
    $btnCopy    = $App.Theme.MakeButton('Copy selected')
    $btnExpVis  = $App.Theme.MakeButton('Export visible...')
    $btnExpSel  = $App.Theme.MakeButton('Export selected...')
    $btnRefresh = $App.Theme.MakeButton('Refresh from AD')
    $top.Controls.AddRange(@($lbl, $search, $btnClear, $btnCopy, $btnExpVis, $btnExpSel, $btnRefresh))

    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Dock = 'Fill'; $grid.ReadOnly = $true; $grid.AllowUserToAddRows = $false; $grid.AllowUserToDeleteRows = $false
    $grid.SelectionMode = 'FullRowSelect'; $grid.MultiSelect = $true; $grid.RowHeadersVisible = $false
    $grid.AutoSizeColumnsMode = 'DisplayedCells'; $grid.BackgroundColor = $App.Theme.Surface
    $grid.AlternatingRowsDefaultCellStyle.BackColor = $App.Theme.AltRow
    $grid.Font = New-Object System.Drawing.Font($App.Theme.FontName, $App.Theme.FontSizePt)

    $status = New-Object System.Windows.Forms.Label; $status.Dock = 'Bottom'; $status.Height = 20
    $status.ForeColor = $App.Theme.Muted; $status.Text = 'Not loaded. Click Refresh from AD.'

    $copyBox = New-Object System.Windows.Forms.TextBox
    $copyBox.Multiline = $true; $copyBox.ReadOnly = $true; $copyBox.ScrollBars = 'Vertical'
    $copyBox.Dock = 'Bottom'; $copyBox.Height = 96; $copyBox.Visible = $false
    $copyBox.Font = New-Object System.Drawing.Font($App.Theme.MonoFontName, 9)

    $dt = New-Object System.Data.DataTable 'Users'
    foreach ($c in $cols) { [void]$dt.Columns.Add($c, [string]) }
    $dv = New-Object System.Data.DataView($dt)
    $grid.DataSource = $dv

    $updateCount = { $status.Text = "{0} shown / {1} loaded" -f $dv.Count, $dt.Rows.Count }.GetNewClosure()

    $applyFilter = {
        $t = [string]$search.Text
        if ([string]::IsNullOrWhiteSpace($t)) { $dv.RowFilter = '' }
        else {
            $esc = $t.Replace("'","''").Replace('[','[[]').Replace('%','[%]').Replace('*','[*]')
            $clauses = $cols | ForEach-Object { "[$_] LIKE '%$esc%'" }
            $dv.RowFilter = '(' + ($clauses -join ' OR ') + ')'
        }
        & $updateCount
    }.GetNewClosure()
    $search.Add_TextChanged($applyFilter)

    # ---- load ----
    $doLoad = {
        $frm = $Page.FindForm(); if ($frm) { $frm.Cursor = [System.Windows.Forms.Cursors]::WaitCursor }
        $status.Text = 'Loading accounts from Active Directory...'
        try {
            $rows = Invoke-ULQuery $App
            $dt.BeginLoadData(); $dt.Rows.Clear()
            foreach ($r in $rows) { [void]$dt.Rows.Add([object[]]$r) }
            $dt.EndLoadData()
            & $applyFilter
            $App.Log('INFO','UserLookup',"Loaded $($dt.Rows.Count) accounts.")
        }
        catch {
            $srv  = [string]$App.GetSetting('Server'); if (-not $srv) { $srv = [string]$App.GetSetting('Domain') }; $base = $_.Exception.GetBaseException()
            $App.Log('ERROR','UserLookup', "server='$srv' :: $($_.Exception.ToString()) :: at $($_.ScriptStackTrace)")
            $where = if ($srv) { "The environment targets '$srv' (it also tried the current domain)." } else { "Queried the current domain." }
            [System.Windows.Forms.MessageBox]::Show($frm,
                "Could not query Active Directory.`n`n$where`n`nRoot cause: [$($base.GetType().Name)] $($base.Message)`n`nFull details were written to Session.log.",
                'AD Error','OK','Error') | Out-Null
            $status.Text = 'Query failed.'
        }
        finally { if ($frm) { $frm.Cursor = [System.Windows.Forms.Cursors]::Default } }
    }.GetNewClosure()
    $btnRefresh.Add_Click($doLoad)
    $Page.Tag = @{ OnActivate = $doLoad }   # auto-populate on first view

    # ---- clear filters ----
    $btnClear.Add_Click({
        $search.Text = ''
        try { $grid.ClearSelection() } catch { }
        & $updateCount
    }.GetNewClosure())

    # ---- copy selected (reads grid cells directly) ----
    $copySel = {
        $n = 0; $sb = New-Object System.Text.StringBuilder
        foreach ($row in $grid.SelectedRows) {
            $parts = foreach ($c in $copyCols) {
                $v = ''; try { if ($null -ne $row.Cells[$c].Value) { $v = [string]$row.Cells[$c].Value } } catch { }
                "{0}: {1}" -f $c, $v
            }
            [void]$sb.AppendLine(($parts -join "`r`n")); [void]$sb.AppendLine(''); $n++
        }
        if ($n -gt 0) {
            $text = $sb.ToString().TrimEnd()
            try { [System.Windows.Forms.Clipboard]::SetText($text) } catch { }
            $copyBox.Text = $text; $copyBox.Visible = $true
            $status.Text = "Copied $n selected (shown below, and on the clipboard)."
        } else { $status.Text = 'Select one or more rows first.' }
    }.GetNewClosure()
    $btnCopy.Add_Click($copySel)

    # Ctrl+C copies the selection too.
    $grid.Add_KeyDown({ if ($_.Control -and $_.KeyCode -eq [System.Windows.Forms.Keys]::C) { & $copySel; $_.Handled = $true } }.GetNewClosure())

    # ---- export (reads grid cells directly) ----
    $exportFn = {
        param([bool]$SelectedOnly)
        try {
            $rows = @()
            if ($SelectedOnly) { foreach ($row in $grid.SelectedRows) { $rows += $row } }
            else               { foreach ($row in $grid.Rows) { if (-not $row.IsNewRow) { $rows += $row } } }
            if ($rows.Count -eq 0) { $status.Text = 'Nothing to export.'; return }

            $sfd = New-Object System.Windows.Forms.SaveFileDialog
            $sfd.Filter = 'CSV files (*.csv)|*.csv'
            $sfd.FileName = 'ADUsers_' + (Get-Date -Format 'yyyyMMdd_HHmm') + '.csv'
            if ($sfd.ShowDialog($Page.FindForm()) -ne [System.Windows.Forms.DialogResult]::OK) { return }

            $sb = New-Object System.Text.StringBuilder
            [void]$sb.AppendLine(($cols | ForEach-Object { '"' + $_ + '"' }) -join ',')
            foreach ($row in $rows) {
                $line = foreach ($c in $cols) {
                    $v = ''; try { if ($null -ne $row.Cells[$c].Value) { $v = [string]$row.Cells[$c].Value } } catch { }
                    '"' + $v.Replace('"','""') + '"'
                }
                [void]$sb.AppendLine($line -join ',')
            }
            [System.IO.File]::WriteAllText($sfd.FileName, $sb.ToString(), (New-Object System.Text.UTF8Encoding($true)))
            $App.LogAction("Exported $($rows.Count) user rows to $($sfd.FileName)")
            $status.Text = "Exported $($rows.Count) rows to $($sfd.FileName)"
        }
        catch {
            $App.Log('ERROR','UserLookup',"export: $($_.Exception.ToString())")
            [System.Windows.Forms.MessageBox]::Show($Page.FindForm(),"Export failed:`n$($_.Exception.Message)",'Export','OK','Error') | Out-Null
        }
    }.GetNewClosure()
    $btnExpVis.Add_Click({ & $exportFn $false }.GetNewClosure())
    $btnExpSel.Add_Click({ & $exportFn $true }.GetNewClosure())

    $Page.Controls.Add($grid)
    $Page.Controls.Add($copyBox)
    $Page.Controls.Add($status)
    $Page.Controls.Add($top)
}
