# UI_Tab_Overview.psm1   (BASE TIER, project-owned)
#
# Overview: what the tool is for, how to work through it, and the complete
# step sequence (from the step catalog) in order.

function New-OverviewTab {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Windows.Forms.TabPage]$Page,
        [Parameter(Mandatory)] $App
    )
    $Th = $App.Theme

    $header = New-Object System.Windows.Forms.Label
    $header.Text = 'CCM Client Troubleshooter'; $header.Dock = 'Top'
    Set-HeaderStyle -App $App -Label $header; $header.AutoSize = $false; $header.Height = 34

    $sub = New-Object System.Windows.Forms.Label
    $sub.Dock = 'Top'; $sub.Height = 22; $sub.ForeColor = $Th.Muted
    $sub.Text = 'Find out exactly what state the Configuration Manager client is in, then fix it one step at a time - including the Windows repairs a client install depends on.'

    $n = [Environment]::NewLine
    $guide = New-Object System.Windows.Forms.TextBox
    $guide.Dock = 'Top'; $guide.Height = 250; $guide.Multiline = $true; $guide.ReadOnly = $true; $guide.BorderStyle = 'None'
    $guide.BackColor = $Th.Surface; $guide.ScrollBars = 'Vertical'
    $guide.Text = (
        "HOW TO USE IT" + $n +
        "  1. Run the tool as administrator (the Discovery banner says so if it is not)." + $n +
        "  2. Discovery tab: every check runs on open. The banner gives the verdict (Healthy, Not installed, Remnants, Cannot create certificates," + $n +
        "     Registration rejected, Waiting for approval, No policy ...), the recommended steps in order, and whether an install would succeed." + $n +
        "  3. Repair Steps tab (admin): 'Select next recommended', read what the step does, 'Run selected step'. Long tools (SFC, DISM, chkdsk," + $n +
        "     ccmsetup) open in their own console window so you can watch them; the result lands in the table. Run discovery again between steps." + $n +
        "  4. Steps marked Reboot ask to restart when they finish. Progress is saved per computer, so after the reboot reopen the tool and carry on." + $n +
        "  5. Logs tab: the client, setup, CBS and DISM logs parsed like CMTrace. Tick Follow on ClientIDManagerStartup.log to watch registration live." + $n +
        $n +
        "WHY INSTALLS 'RARELY WORK'" + $n +
        "  ccmsetup only succeeds when Windows underneath is sound. The install step is gated: it is offered only when discovery finds no blockers" + $n +
        "  (no client remnants, no pending reboot, key storage / KeyIso working, WMI consistent, services enabled, MP reachable and answering, clock" + $n +
        "  in sync, complete client source). Lessons built in: KeyIso disabled = 0x800706d9 = no certificates = no registration; 'Server rejected" + $n +
        "  registration request: 3' is fixed on the SERVER first; on an air-gapped network DISM must repair from a healthy PC on the same build." + $n +
        $n +
        "TIERS AND SAFETY" + $n +
        "  User password: Overview, Discovery and Logs (read-only - nothing on the machine changes). Admin password: adds Repair Steps." + $n +
        "  Kept clear of security-tool triggers: no encoded or hidden PowerShell, no Add-Type, no downloads, no certutil / msdt / regsvr32 / nltest," + $n +
        "  services are only ever enabled, never disabled; only the configured MP (and a healthy PC you name) is contacted." + $n +
        $n +
        "THE STEPS, IN ORDER (below)  -  configure the site code, MP, client source and repair source on the Environment tab."
    )

    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Dock = 'Fill'
    $grid.ReadOnly = $true; $grid.AllowUserToAddRows = $false; $grid.AllowUserToDeleteRows = $false; $grid.AllowUserToResizeRows = $false
    $grid.RowHeadersVisible = $false; $grid.MultiSelect = $false; $grid.SelectionMode = 'FullRowSelect'
    $grid.BackgroundColor = $Th.Surface; $grid.BorderStyle = 'FixedSingle'; $grid.GridColor = $Th.Border
    $grid.EnableHeadersVisualStyles = $false
    $grid.ColumnHeadersDefaultCellStyle.BackColor = $Th.Header; $grid.ColumnHeadersDefaultCellStyle.ForeColor = $Th.Title
    $grid.DefaultCellStyle.SelectionBackColor = $Th.Select; $grid.DefaultCellStyle.SelectionForeColor = $Th.Text
    $grid.AlternatingRowsDefaultCellStyle.BackColor = $Th.AltRow
    $grid.DefaultCellStyle.WrapMode = 'True'; $grid.AutoSizeRowsMode = 'AllCells'
    foreach ($c in @(@('Order', '#', 34), @('Phase', 'Phase', 130), @('Title', 'Step', 400), @('Kind', 'Runs as', 64), @('Reboot', 'Reboot', 86), @('Risk', 'Risk', 60), @('Summary', 'What it does', 700))) {
        $i = $grid.Columns.Add($c[0], $c[1]); $grid.Columns[$i].Width = $c[2]
    }
    $grid.Columns['Summary'].AutoSizeMode = 'Fill'
    if (Get-Command Get-CcmStepCatalog -ErrorAction SilentlyContinue) {
        foreach ($s in (Get-CcmStepCatalog)) { [void]$grid.Rows.Add($s.Order, $s.Phase, $s.Title, $s.Kind, $s.Reboot, $s.Risk, $s.Summary) }
    }

    $Page.Controls.Add($grid)
    $Page.Controls.Add($guide)
    $Page.Controls.Add($sub)
    $Page.Controls.Add($header)
}
