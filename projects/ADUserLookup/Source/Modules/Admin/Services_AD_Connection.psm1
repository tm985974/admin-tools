#region -- Services.AD.Connection.psm1 ----------------------------------------
# Concern : Domain authentication, capability detection, default domain
#           connect, and domain picker UI dialog.
# Load order: 2 - depends on Services.AD.Reporting (Set-Placeholder, New-StdButton)
# Split from: ADConnect.psm1
#   Services.AD.Connection.psm1       <- this file  (auth + UI)
#   Services.AD.Connection.Query.psm1 <- OU tree building, Get-Domain* fetchers
#endregion

#region -- AD module helpers --------------------------------------------------
# v1.2.20: answered once per session. Get-Module -ListAvailable reads every
# folder on PSModulePath (seconds on some machines, more when it includes a
# network path) and every user / group / computer query asked again.
$script:ADModuleAvailable = $null
function Test-ADModule {
    if ($null -eq $script:ADModuleAvailable) {
        $script:ADModuleAvailable = [bool](Get-Module -Name ActiveDirectory) -or
            [bool](Get-Module -ListAvailable -Name ActiveDirectory -ErrorAction SilentlyContinue)
    }
    return $script:ADModuleAvailable
}

function Import-ADModuleSafe {
    try { Import-Module ActiveDirectory -ErrorAction Stop; return $true } catch { return $false }
}
#endregion

#region -- Get-ADCapabilities -------------------------------------------------
function Get-ADCapabilities {
    $c = [PSCustomObject]@{
        ADModule     = $false
        RSAT_DNS     = $false
        RSAT_DHCP    = $false
        RSAT_GPO     = $false
        LAPS_Present = $false
        LAPS_Version = ''
        LAPS_New     = $false
        PS_Version   = $PSVersionTable.PSVersion.ToString()
        PS_Major     = $PSVersionTable.PSVersion.Major
        OS_Caption   = ''
        WinRM        = $false
        IsElevated   = $false
    }
    $c.ADModule  = Test-ADModule
    $c.RSAT_DNS  = [bool](Get-Module -ListAvailable -Name DnsServer   -ErrorAction SilentlyContinue)
    $c.RSAT_DHCP = [bool](Get-Module -ListAvailable -Name DhcpServer  -ErrorAction SilentlyContinue)
    $c.RSAT_GPO  = [bool](Get-Module -ListAvailable -Name GroupPolicy  -ErrorAction SilentlyContinue)
    try { $c.OS_Caption = (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).Caption } catch {
        try { $c.OS_Caption = (Get-WmiObject Win32_OperatingSystem -ErrorAction Stop).Caption } catch { }
    }
    try {
        $svc     = Get-Service WinRM -ErrorAction Stop
        $c.WinRM = ($svc.Status -eq 'Running')
    } catch { }
    try {
        $id        = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object System.Security.Principal.WindowsPrincipal($id)
        $c.IsElevated = $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { }
    try {
        $newLaps = Get-Module -ListAvailable -Name LAPS -ErrorAction SilentlyContinue
        if ($newLaps) {
            $c.LAPS_Present = $true; $c.LAPS_New = $true
            $c.LAPS_Version = "Windows LAPS ($($newLaps.Version))"
        } else {
            $lp  = "$env:ProgramFiles\LAPS\CSE\AdmPwd.dll"
            $lp2 = "${env:ProgramFiles(x86)}\LAPS\CSE\AdmPwd.dll"
            if ((Test-Path $lp) -or (Test-Path $lp2)) {
                $c.LAPS_Present = $true; $c.LAPS_Version = 'Legacy LAPS (AdmPwd)'
            }
        }
    } catch { }
    return $c
}
#endregion

#region -- Connect-DefaultDomain ----------------------------------------------
function Connect-DefaultDomain {
    if (-not (Import-ADModuleSafe)) { return $null }
    try {
        $domain = Get-ADDomain -ErrorAction Stop
        $forest = Get-ADForest -ErrorAction Stop
        return [PSCustomObject]@{
            Domain     = $domain.DNSRoot
            DomainDN   = $domain.DistinguishedName
            ForestRoot = $forest.RootDomain
            TargetDC   = $domain.PDCEmulator
        }
    } catch { return $null }
}
#endregion

#region -- Show-DomainPicker --------------------------------------------------
function Show-DomainPicker {
    param([PSCustomObject]$CurrentContext)
    $FW = 580; $FH = 530
    $F_UI     = New-Object System.Drawing.Font('Segoe UI', 9)
    $F_UI_B   = New-Object System.Drawing.Font('Segoe UI', 9,  [System.Drawing.FontStyle]::Bold)
    $F_UI_13B = New-Object System.Drawing.Font('Segoe UI', 13, [System.Drawing.FontStyle]::Bold)
    $C_TITLE  = [System.Drawing.Color]::FromArgb(0, 99, 177)
    $C_BG     = [System.Drawing.Color]::FromArgb(235,238,242)
    $C_WHITE  = [System.Drawing.Color]::White
    $C_DIM    = [System.Drawing.Color]::DimGray

    $dlg                 = New-Object System.Windows.Forms.Form
    $dlg.Text            = 'Select Domain'
    $dlg.ClientSize      = New-Object System.Drawing.Size($FW, $FH)
    $dlg.FormBorderStyle = 'FixedSingle'
    $dlg.MaximizeBox     = $false
    $dlg.StartPosition   = 'CenterParent'
    $dlg.BackColor       = $C_BG
    $dlg.Font            = $F_UI

    $pTitle              = New-Object System.Windows.Forms.Panel
    $pTitle.Dock         = 'Top'; $pTitle.Height = 48
    $pTitle.BackColor    = $C_TITLE
    $dlg.Controls.Add($pTitle)

    $lTitle              = New-Object System.Windows.Forms.Label
    $lTitle.Text         = '   Select Domain / Forest'
    $lTitle.Dock         = 'Fill'; $lTitle.Font = $F_UI_13B
    $lTitle.ForeColor    = $C_WHITE; $lTitle.TextAlign = 'MiddleLeft'
    $pTitle.Controls.Add($lTitle)

    $lTree               = New-Object System.Windows.Forms.Label
    $lTree.Text          = 'Forest / Domain Tree'
    $lTree.Location      = New-Object System.Drawing.Point(12, 60)
    $lTree.Size          = New-Object System.Drawing.Size(300, 20)
    $lTree.Font          = $F_UI_B
    $dlg.Controls.Add($lTree)

    $tree                = New-Object System.Windows.Forms.TreeView
    $tree.Location       = New-Object System.Drawing.Point(12, 83)
    $tree.Size           = New-Object System.Drawing.Size(554, 200)
    $tree.Font           = $F_UI; $tree.BackColor = $C_WHITE
    $tree.BorderStyle    = 'FixedSingle'
    $tree.ShowLines      = $true; $tree.ShowPlusMinus = $true
    $dlg.Controls.Add($tree)

    $lDC                 = New-Object System.Windows.Forms.Label
    $lDC.Text            = 'Target Domain Controller'
    $lDC.Location        = New-Object System.Drawing.Point(12, 296)
    $lDC.Size            = New-Object System.Drawing.Size(300, 20); $lDC.Font = $F_UI_B
    $dlg.Controls.Add($lDC)

    $cmbDC               = New-Object System.Windows.Forms.ComboBox
    $cmbDC.Location      = New-Object System.Drawing.Point(12, 318)
    $cmbDC.Size          = New-Object System.Drawing.Size(554, 26)
    $cmbDC.DropDownStyle = 'DropDownList'; $cmbDC.Font = $F_UI
    $dlg.Controls.Add($cmbDC)

    $lCred               = New-Object System.Windows.Forms.Label
    $lCred.Text          = 'Alternate credentials  (leave blank to use current session)'
    $lCred.Location      = New-Object System.Drawing.Point(12, 356)
    $lCred.Size          = New-Object System.Drawing.Size(554, 20)
    $lCred.Font          = $F_UI; $lCred.ForeColor = $C_DIM
    $dlg.Controls.Add($lCred)

    $tbUser              = New-Object System.Windows.Forms.TextBox
    $tbUser.Location     = New-Object System.Drawing.Point(12, 378)
    $tbUser.Size         = New-Object System.Drawing.Size(268, 24); $tbUser.Font = $F_UI
    Set-Placeholder -TextBox $tbUser -Text 'DOMAIN\username'
    $dlg.Controls.Add($tbUser)

    $tbPass              = New-Object System.Windows.Forms.TextBox
    $tbPass.Location     = New-Object System.Drawing.Point(288, 378)
    $tbPass.Size         = New-Object System.Drawing.Size(278, 24); $tbPass.Font = $F_UI
    $tbPass.UseSystemPasswordChar = $true
    Set-Placeholder -TextBox $tbPass -Text 'Password'
    $dlg.Controls.Add($tbPass)

    $lStatus             = New-Object System.Windows.Forms.Label
    $lStatus.Location    = New-Object System.Drawing.Point(12, 414)
    $lStatus.Size        = New-Object System.Drawing.Size(554, 20)
    $lStatus.Font        = $F_UI; $lStatus.ForeColor = $C_DIM
    $dlg.Controls.Add($lStatus)

    $btnOK               = New-Object System.Windows.Forms.Button
    $btnOK.Text          = 'Connect'
    $btnOK.Location      = New-Object System.Drawing.Point(348, 454)
    $btnOK.Size          = New-Object System.Drawing.Size(100, 30)
    $btnOK.Font          = $F_UI_B; $btnOK.FlatStyle = 'Standard'; $btnOK.Enabled = $false
    $dlg.Controls.Add($btnOK)

    $btnCancel           = New-Object System.Windows.Forms.Button
    $btnCancel.Text      = 'Cancel'
    $btnCancel.Location  = New-Object System.Drawing.Point(456, 454)
    $btnCancel.Size      = New-Object System.Drawing.Size(100, 30)
    $btnCancel.Font      = $F_UI; $btnCancel.FlatStyle = 'Standard'
    $dlg.Controls.Add($btnCancel)

    $script:PickerResult = $null

    $dlg.Add_Shown({
        $lStatus.Text = 'Discovering forest structure...'; $dlg.Refresh()
        try {
            $forest   = Get-ADForest -ErrorAction Stop
            $rootNode = New-Object System.Windows.Forms.TreeNode
            $rootNode.Text = "[Forest]  $($forest.RootDomain)"; $rootNode.Tag = $null
            foreach ($dn2 in ($forest.Domains | Sort-Object)) {
                $dn3 = New-Object System.Windows.Forms.TreeNode
                $dn3.Text = $dn2; $dn3.Tag = $dn2
                [void]$rootNode.Nodes.Add($dn3)
            }
            [void]$tree.Nodes.Add($rootNode); $tree.ExpandAll()
            $lStatus.Text = 'Select a domain then choose a DC.'
        } catch {
            $lStatus.Text = 'Auto-discovery failed. Adding current domain.'
            $manual = New-Object System.Windows.Forms.TreeNode
            $manual.Text = $env:USERDNSDOMAIN; $manual.Tag = $env:USERDNSDOMAIN
            [void]$tree.Nodes.Add($manual)
        }
    })

    $tree.Add_AfterSelect({
        $sel = $tree.SelectedNode
        if (-not $sel -or -not $sel.Tag) { $btnOK.Enabled = $false; return }
        $selDomain = [string]$sel.Tag
        $cmbDC.Items.Clear(); $btnOK.Enabled = $false
        $lStatus.Text = "Loading DCs for $selDomain ..."; $dlg.Refresh()
        try {
            $cred = $null
            if ($tbUser.Text.Trim() -ne '' -and $tbPass.Text -ne '') {
                $cred = New-Object System.Management.Automation.PSCredential(
                    $tbUser.Text.Trim(),
                    ($tbPass.Text | ConvertTo-SecureString -AsPlainText -Force))
            }
            $dcP = @{ Filter='*'; Server=$selDomain; ErrorAction='Stop' }
            if ($cred) { $dcP.Credential = $cred }
            $dcs = (Get-ADDomainController @dcP).HostName | Sort-Object
            foreach ($dc in $dcs) { [void]$cmbDC.Items.Add($dc) }
            if ($cmbDC.Items.Count -gt 0) {
                $pdcP = @{ Server=$selDomain; ErrorAction='SilentlyContinue' }
                if ($cred) { $pdcP.Credential = $cred }
                $pdc = (Get-ADDomain @pdcP).PDCEmulator
                $idx = $cmbDC.Items.IndexOf($pdc)
                $cmbDC.SelectedIndex = if ($idx -ge 0) { $idx } else { 0 }
                $btnOK.Enabled = $true
                $lStatus.Text  = "$($dcs.Count) DC(s) found. PDC pre-selected."
            }
        } catch { $lStatus.Text = "DC enumeration failed: $($_.Exception.Message)" }
    })

    $btnOK.Add_Click({
        $sel = $tree.SelectedNode
        if (-not $sel -or -not $sel.Tag) { $lStatus.Text = 'Select a domain first.'; return }
        $domainName = [string]$sel.Tag
        $dc         = $cmbDC.Text
        if (-not $dc) { $lStatus.Text = 'Select a DC first.'; return }
        $lStatus.Text = "Connecting to $domainName via $dc ..."; $dlg.Refresh()
        try {
            $cred = $null
            if ($tbUser.Text.Trim() -ne '' -and $tbPass.Text -ne '') {
                $cred = New-Object System.Management.Automation.PSCredential(
                    $tbUser.Text.Trim(),
                    ($tbPass.Text | ConvertTo-SecureString -AsPlainText -Force))
            }
            $dP = @{ Server=$dc; ErrorAction='Stop' }; if ($cred) { $dP.Credential = $cred }
            $dom = Get-ADDomain @dP
            $fP  = @{ Server=$dc; ErrorAction='Stop' }; if ($cred) { $fP.Credential = $cred }
            $frt = (Get-ADForest @fP).RootDomain
            $script:PickerResult = [PSCustomObject]@{
                Domain=$dom.DNSRoot; DomainDN=$dom.DistinguishedName
                ForestRoot=$frt; TargetDC=$dc; Credential=$cred
            }
            $dlg.DialogResult = [System.Windows.Forms.DialogResult]::OK; $dlg.Close()
        } catch { $lStatus.Text = "Connection failed: $($_.Exception.Message)" }
    })

    $btnCancel.Add_Click({
        $dlg.DialogResult = [System.Windows.Forms.DialogResult]::Cancel; $dlg.Close()
    })

    $dlg.ShowDialog() | Out-Null
    return $script:PickerResult
}
#endregion

Export-ModuleMember -Function `
    Test-ADModule, `
    Import-ADModuleSafe, `
    Get-ADCapabilities, `
    Connect-DefaultDomain, `
    Show-DomainPicker
