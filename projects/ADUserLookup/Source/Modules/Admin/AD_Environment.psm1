# AD_Environment.psm1   (ADMIN TIER)
#
# The AD pages of the Environment tab (registered by AD_Core with
# Register-EnvironmentSection; the template's General page comes first):
#
#   Domain    Domain (DNS name), Domain controller / LDAP server, and the live
#             connection (status, DC, DN, forest) with a Test button
#   Accounts  New-user naming (display / logon prefix + suffix + pattern, account
#             name case), new-user defaults (UPN suffix, home drive, new-user
#             OU), offboarding (disabled OU), bulk onboarding (OU + patterns)
#   Mail      SMTP server, port, mail from
#   Messages  New Account Welcome + the four Additional Info messages (rich
#             text, links, pictures) - the 1.6.1 editor, unchanged
#
# These were the 1.6.1 "Domain Defaults" tab. Every value lives in the
# environment's record (Settings\Environments.json); Services_DomainDefaults_
# Config reads them from there, so Create User, Offboard, Bulk Onboard, mail and
# logging use the selected environment's values. Each page follows the template
# contract: it returns Load / Collect / Validate, and the Environment tab's Save
# writes all pages at once. Values pass through Get-CleanDomainDefaults (1.6.1's
# validation) on the way in.

# ---- shared layout helpers (plain functions: safe to call from any closure) ----
$script:ADEnvLX = 12      # label column
$script:ADEnvFX = 240     # field column
$script:ADEnvFW = 340     # field width

function Add-ADEnvHeader {
    param($Parent, [string]$Text, [int]$Y)
    $h = New-Object System.Windows.Forms.Label
    $h.Text = $Text; $h.Location = New-Object System.Drawing.Point(12, $Y); $h.AutoSize = $true
    $h.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $h.ForeColor = [System.Drawing.Color]::FromArgb(28, 92, 168)
    $Parent.Controls.Add($h)
    $line = New-Object System.Windows.Forms.Panel
    $line.Location = New-Object System.Drawing.Point(12, ($Y + 22)); $line.Size = New-Object System.Drawing.Size(860, 1)
    $line.BackColor = [System.Drawing.Color]::FromArgb(210, 220, 235)
    $Parent.Controls.Add($line)
}

function Add-ADEnvLabel {
    param($Parent, [string]$Text, [int]$Y)
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Text + ':'; $l.Location = New-Object System.Drawing.Point(12, ($Y + 3)); $l.Size = New-Object System.Drawing.Size(225, 20)
    $Parent.Controls.Add($l)
}

function Add-ADEnvText {
    param($Parent, [string]$Caption, [int]$Y, [int]$W = 340)
    Add-ADEnvLabel -Parent $Parent -Text $Caption -Y $Y
    $tb = New-Object System.Windows.Forms.TextBox
    $tb.Location = New-Object System.Drawing.Point(240, $Y); $tb.Width = $W
    $Parent.Controls.Add($tb)
    return $tb
}

function Add-ADEnvHint {
    param($Parent, [string]$Text, [int]$Y, [int]$X = 240, [int]$W = 620, [int]$H = 18)
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Text; $l.Location = New-Object System.Drawing.Point($X, $Y); $l.Size = New-Object System.Drawing.Size($W, $H)
    $l.Font = New-Object System.Drawing.Font('Segoe UI', 8); $l.ForeColor = [System.Drawing.Color]::DimGray
    $Parent.Controls.Add($l)
    return $l
}

# Combo whose items are the LABELS of an ordered key->label map.
function Add-ADEnvCombo {
    param($Parent, [string]$Caption, [int]$Y, [System.Collections.Specialized.OrderedDictionary]$Map)
    Add-ADEnvLabel -Parent $Parent -Text $Caption -Y $Y
    $c = New-Object System.Windows.Forms.ComboBox
    $c.DropDownStyle = 'DropDownList'; $c.Location = New-Object System.Drawing.Point(240, $Y); $c.Width = 340
    foreach ($v in $Map.Values) { [void]$c.Items.Add($v) }
    $Parent.Controls.Add($c)
    return $c
}

function Get-ADEnvMapLabel { param($Map, [string]$Key) if ($Map.Contains($Key)) { return $Map[$Key] }; return ($Map.Values | Select-Object -First 1) }
function Get-ADEnvMapKey   { param($Map, [string]$Label) foreach ($k in $Map.Keys) { if ($Map[$k] -eq $Label) { return $k } }; return ($Map.Keys | Select-Object -First 1) }

# OU field: read-only box + Browse (the 1.6.1 OU picker, against this environment's domain).
function Add-ADEnvOU {
    param($Parent, [string]$Caption, [int]$Y)
    Add-ADEnvLabel -Parent $Parent -Text $Caption -Y $Y
    $tb = New-Object System.Windows.Forms.TextBox
    $tb.Location = New-Object System.Drawing.Point(240, $Y); $tb.Width = 520; $tb.ReadOnly = $true
    $tb.BackColor = [System.Drawing.Color]::FromArgb(245, 245, 245)
    $Parent.Controls.Add($tb)
    $btn = New-Object System.Windows.Forms.Button
    $btn.Text = 'Browse...'; $btn.Location = New-Object System.Drawing.Point(766, ($Y - 1)); $btn.Size = New-Object System.Drawing.Size(76, 24)
    $Parent.Controls.Add($btn)
    $clr = New-Object System.Windows.Forms.Button
    $clr.Text = 'Clear'; $clr.Location = New-Object System.Drawing.Point(846, ($Y - 1)); $clr.Size = New-Object System.Drawing.Size(52, 24)
    $Parent.Controls.Add($clr)
    $btn.Add_Click({
        $ctx = Get-ADEnvironmentContext
        if (-not $ctx.DomainDN) {
            [System.Windows.Forms.MessageBox]::Show('Set the Domain on the Domain page first.', 'Browse OU', 'OK', 'Information') | Out-Null; return
        }
        $picked = Show-OUPicker -Context $ctx
        if ($picked) { $tb.Text = [string]$picked }
    }.GetNewClosure())
    $clr.Add_Click({ $tb.Text = '' }.GetNewClosure())
    return $tb
}

# A context pointing at the SELECTED environment's domain (for OU Browse),
# whether or not that is the domain currently connected.
function Get-ADEnvironmentContext {
    $app  = $script:ADApp
    $real = Get-ADSharedContext -App $app -NoConnect
    $key  = Get-ADSettingsKey -App $app
    $ctx  = $real.PSObject.Copy()
    if ($key -and -not ((Test-ADSharedConnected) -and $real.Domain -ieq $key)) {
        $ctx.Domain   = $key
        $ctx.DomainDN = 'DC=' + (($key -split '\.') -join ',DC=')
        $srv = [string]$app.GetSetting('Server')
        $ctx.TargetDC = if ($srv) { $srv } else { $key }
    }
    return $ctx
}

function Get-ADEnvValue {
    param($Record, [string]$Key, $Default = '')
    if ($Record -and $Record.Contains($Key) -and $null -ne $Record[$Key]) { return $Record[$Key] }
    return $Default
}

# =============================================================================
# Domain
# =============================================================================
function New-ADDomainPage {
    param([System.Windows.Forms.TabPage]$Page, $App)
    $y = 12
    Add-ADEnvHeader -Parent $Page -Text 'Domain' -Y $y; $y += 34
    $tbDomain = Add-ADEnvText -Parent $Page -Caption 'Domain (DNS name)' -Y $y; $y += 26
    [void](Add-ADEnvHint -Parent $Page -Text 'e.g. contoso.com. Names this environment''s domain; also the connection target when no domain controller is set below. Blank = the domain this machine is joined to.' -Y $y -H 30); $y += 38
    $tbServer = Add-ADEnvText -Parent $Page -Caption 'Domain controller / LDAP server' -Y $y; $y += 26
    [void](Add-ADEnvHint -Parent $Page -Text 'Optional. A specific DC to use (e.g. dc01.contoso.com). Blank = any DC of the domain above.' -Y $y); $y += 34

    Add-ADEnvHeader -Parent $Page -Text 'Connection' -Y $y; $y += 34
    $info = [ordered]@{}
    foreach ($k in @('Status', 'Connected domain', 'Domain controller', 'Distinguished name', 'Forest')) {
        Add-ADEnvLabel -Parent $Page -Text $k -Y $y
        $v = New-Object System.Windows.Forms.Label
        $v.Location = New-Object System.Drawing.Point(240, ($y + 3)); $v.Size = New-Object System.Drawing.Size(620, 20)
        $Page.Controls.Add($v); $info[$k] = $v
        $y += 24
    }
    $btnTest = New-Object System.Windows.Forms.Button
    $btnTest.Text = 'Test connection'; $btnTest.Location = New-Object System.Drawing.Point(240, ($y + 6)); $btnTest.Size = New-Object System.Drawing.Size(130, 28)
    $Page.Controls.Add($btnTest)
    [void](Add-ADEnvHint -Parent $Page -Text 'Tests the Domain / DC typed above without saving or switching. Saving a changed Domain or DC reconnects the app.' -Y ($y + 12) -X 380 -W 520)

    $showLive = {
        $ctx = Get-ADSharedContext -App $App -NoConnect
        if (Test-ADSharedConnected) {
            $info['Status'].Text = 'Connected'; $info['Status'].ForeColor = [System.Drawing.Color]::FromArgb(0, 97, 0)
            $info['Connected domain'].Text = [string]$ctx.Domain; $info['Domain controller'].Text = [string]$ctx.TargetDC
            $info['Distinguished name'].Text = [string]$ctx.DomainDN; $info['Forest'].Text = [string]$ctx.ForestRoot
        } else {
            $info['Status'].Text = 'Not connected yet (opens with the first AD tab)'; $info['Status'].ForeColor = [System.Drawing.Color]::DimGray
            foreach ($k in @('Connected domain', 'Domain controller', 'Distinguished name', 'Forest')) { $info[$k].Text = '' }
        }
    }.GetNewClosure()

    $btnTest.Add_Click({
        $target = $tbServer.Text.Trim(); if (-not $target) { $target = $tbDomain.Text.Trim() }
        $frm = $Page.FindForm(); if ($frm) { $frm.Cursor = [System.Windows.Forms.Cursors]::WaitCursor }
        try {
            try { Import-Module ActiveDirectory -ErrorAction Stop } catch { }
            $d = if ($target) { Get-ADDomain -Server $target -ErrorAction Stop } else { Get-ADDomain -ErrorAction Stop }
            $f = try { if ($target) { Get-ADForest -Server $target -ErrorAction Stop } else { Get-ADForest -ErrorAction Stop } } catch { $null }
            $info['Status'].Text = "Test OK  ($(if ($target) { $target } else { 'current domain' }))"; $info['Status'].ForeColor = [System.Drawing.Color]::FromArgb(0, 97, 0)
            $info['Connected domain'].Text = [string]$d.DNSRoot; $info['Domain controller'].Text = [string]$d.PDCEmulator
            $info['Distinguished name'].Text = [string]$d.DistinguishedName; $info['Forest'].Text = $(if ($f) { [string]$f.RootDomain } else { '' })
        }
        catch {
            $info['Status'].Text = "Test failed: $($_.Exception.Message)"; $info['Status'].ForeColor = [System.Drawing.Color]::FromArgb(156, 0, 6)
            foreach ($k in @('Connected domain', 'Domain controller', 'Distinguished name', 'Forest')) { $info[$k].Text = '' }
        }
        finally { if ($frm) { $frm.Cursor = [System.Windows.Forms.Cursors]::Default } }
    }.GetNewClosure())

    return @{
        Load    = { param($Record) $tbDomain.Text = [string](Get-ADEnvValue $Record 'Domain'); $tbServer.Text = [string](Get-ADEnvValue $Record 'Server'); & $showLive }.GetNewClosure()
        Collect = { param($Record) [ordered]@{ Domain = $tbDomain.Text.Trim(); Server = $tbServer.Text.Trim() } }.GetNewClosure()
    }
}

# =============================================================================
# Accounts
# =============================================================================
function New-ADAccountsPage {
    param([System.Windows.Forms.TabPage]$Page, $App)

    $displayMap = [ordered]@{
        AccountOnly = 'Account Name only'; PrefixAccount = 'Display Prefix + Account Name'
        PrefixAccountSuffix = 'Display Prefix + Account Name + Display Suffix'; AccountSuffix = 'Account Name + Display Suffix'
        LastFirst = 'Last, First'; PrefixLastFirst = 'Display Prefix + Last, First'
        PrefixLastFirstSuffix = 'Display Prefix + Last, First + Display Suffix'
    }
    $accountMap = [ordered]@{
        LastInitial = 'Last Name + First Initial'; PrefixLastInitial = 'Logon Prefix + Last Name + First Initial'
        PrefixLastInitialSuffix = 'Logon Prefix + Last Name + First Initial + Logon Suffix'
    }
    $customMap = [ordered]@{ CustomOnly = 'Custom Text only'; PrefixCustom = 'Prefix + Custom Text'; CustomSuffix = 'Custom Text + Suffix'; PrefixCustomSuffix = 'Prefix + Custom Text + Suffix' }
    $bulkDisplayMap = [ordered]@{}; foreach ($k in $displayMap.Keys) { $bulkDisplayMap[$k] = $displayMap[$k] }; foreach ($k in $customMap.Keys) { $bulkDisplayMap[$k] = $customMap[$k] }
    $bulkLogonMap   = [ordered]@{}; foreach ($k in $accountMap.Keys) { $bulkLogonMap[$k] = $accountMap[$k] }; foreach ($k in $customMap.Keys) { $bulkLogonMap[$k] = $customMap[$k] }
    $caseMap = [ordered]@{ AsTyped = 'As typed (mixed case allowed)'; Upper = 'ALL UPPER CASE'; Lower = 'all lower case' }

    $c = @{}
    $y = 12
    Add-ADEnvHeader -Parent $Page -Text 'New user naming' -Y $y; $y += 34
    $c.DisplayPrefix = Add-ADEnvText -Parent $Page -Caption 'Display Prefix' -Y $y; $y += 28
    $c.DisplaySuffix = Add-ADEnvText -Parent $Page -Caption 'Display Suffix' -Y $y; $y += 28
    $c.DisplayPattern = Add-ADEnvCombo -Parent $Page -Caption 'Display Name Pattern' -Y $y -Map $displayMap; $y += 26
    $c.DisplayPreview = Add-ADEnvHint -Parent $Page -Text '' -Y $y; $y += 24
    $c.LogonPrefix = Add-ADEnvText -Parent $Page -Caption 'Logon Prefix' -Y $y; $y += 28
    $c.LogonSuffix = Add-ADEnvText -Parent $Page -Caption 'Logon Suffix' -Y $y; $y += 28
    $c.AccountPattern = Add-ADEnvCombo -Parent $Page -Caption 'Account Name Pattern' -Y $y -Map $accountMap; $y += 26
    $c.AccountPreview = Add-ADEnvHint -Parent $Page -Text '' -Y $y; $y += 24
    $c.Case = Add-ADEnvCombo -Parent $Page -Caption 'Account Name Case' -Y $y -Map $caseMap; $y += 26
    [void](Add-ADEnvHint -Parent $Page -Text 'Applies to every new account (Create User and Bulk Onboard), including names typed by hand. Existing accounts are not changed.' -Y $y); $y += 30

    Add-ADEnvHeader -Parent $Page -Text 'New user defaults' -Y $y; $y += 34
    $c.Upn = Add-ADEnvText -Parent $Page -Caption 'UPN Suffix' -Y $y; $y += 26
    [void](Add-ADEnvHint -Parent $Page -Text 'e.g. @contoso.com' -Y $y); $y += 22
    $c.HomeDrive = Add-ADEnvText -Parent $Page -Caption 'Home Drive' -Y $y -W 80; $y += 28
    $c.NewUserOU = Add-ADEnvOU -Parent $Page -Caption 'Default New User OU' -Y $y; $y += 36

    Add-ADEnvHeader -Parent $Page -Text 'Offboarding' -Y $y; $y += 34
    $c.DisabledOU = Add-ADEnvOU -Parent $Page -Caption 'Default Disabled OU' -Y $y; $y += 36

    Add-ADEnvHeader -Parent $Page -Text 'Bulk onboarding  (Bulk Operations > Bulk Add Users)' -Y $y; $y += 34
    $c.BulkOU = Add-ADEnvOU -Parent $Page -Caption 'Default Bulk Onboard OU' -Y $y; $y += 32
    $c.BulkDisplay = Add-ADEnvCombo -Parent $Page -Caption 'Bulk Display Pattern' -Y $y -Map $bulkDisplayMap; $y += 26
    $c.BulkDisplayPreview = Add-ADEnvHint -Parent $Page -Text '' -Y $y; $y += 24
    $c.BulkLogon = Add-ADEnvCombo -Parent $Page -Caption 'Bulk Logon Pattern' -Y $y -Map $bulkLogonMap; $y += 26
    $c.BulkLogonPreview = Add-ADEnvHint -Parent $Page -Text '' -Y $y; $y += 24
    [void](Add-ADEnvHint -Parent $Page -Text 'Each CSV row supplies its own Display / Logon Custom Text; the pattern (with the prefixes and suffixes above) builds the row''s Display Name / Logon Name in the CSV preview, where it can still be edited per row.' -Y $y -H 30)

    # ---- example previews (fixed sample identity, never saved) ----
    $render = {
        $acct = 'smithj'; $lf = 'Smith, John'; $cust = 'CustomText'
        $case = Get-ADEnvMapKey $caseMap $c.Case.Text
        $cc = { param($n) if (Get-Command Convert-AccountNameCase -ErrorAction SilentlyContinue) { Convert-AccountNameCase -Name $n -Case $case } else { $n } }
        $dp = $c.DisplayPrefix.Text.Trim(); $ds = $c.DisplaySuffix.Text.Trim(); $sfx = if ($ds) { " $ds" } else { '' }
        $lp = $c.LogonPrefix.Text.Trim();   $ls = $c.LogonSuffix.Text.Trim()
        $a  = & $cc $acct
        $disp = switch (Get-ADEnvMapKey $displayMap $c.DisplayPattern.Text) {
            'AccountOnly' { $a } 'PrefixAccount' { $dp + $a } 'PrefixAccountSuffix' { $dp + $a + $sfx } 'AccountSuffix' { $a + $sfx }
            'LastFirst' { $lf } 'PrefixLastFirst' { $dp + $lf } default { $dp + $lf + $sfx } }
        $c.DisplayPreview.Text = "Example: $disp"
        $logon = switch (Get-ADEnvMapKey $accountMap $c.AccountPattern.Text) { 'PrefixLastInitial' { $lp + $acct } 'PrefixLastInitialSuffix' { $lp + $acct + $ls } default { $acct } }
        $c.AccountPreview.Text = "Example: $(& $cc $logon)"
        $bd = switch (Get-ADEnvMapKey $bulkDisplayMap $c.BulkDisplay.Text) {
            'AccountOnly' { $a } 'PrefixAccount' { $dp + $a } 'PrefixAccountSuffix' { $dp + $a + $sfx } 'AccountSuffix' { $a + $sfx }
            'LastFirst' { $lf } 'PrefixLastFirst' { $dp + $lf } 'PrefixLastFirstSuffix' { $dp + $lf + $sfx }
            'PrefixCustom' { $dp + $cust } 'CustomSuffix' { $cust + $sfx } 'PrefixCustomSuffix' { $dp + $cust + $sfx } default { $cust } }
        $c.BulkDisplayPreview.Text = "Example (John Smith, Display Custom Text '$cust'): $bd"
        $bl = switch (Get-ADEnvMapKey $bulkLogonMap $c.BulkLogon.Text) {
            'LastInitial' { $acct } 'PrefixLastInitial' { $lp + $acct } 'PrefixLastInitialSuffix' { $lp + $acct + $ls }
            'CustomOnly' { $cust } 'PrefixCustom' { $lp + $cust } 'CustomSuffix' { $cust + $ls } default { $lp + $cust + $ls } }
        $c.BulkLogonPreview.Text = "Example (John Smith, Logon Custom Text '$cust'): $(& $cc $bl)"
    }.GetNewClosure()
    foreach ($k in @('DisplayPrefix', 'DisplaySuffix', 'LogonPrefix', 'LogonSuffix')) { $c[$k].Add_TextChanged($render) }
    foreach ($k in @('DisplayPattern', 'AccountPattern', 'Case', 'BulkDisplay', 'BulkLogon')) { $c[$k].Add_SelectedIndexChanged($render) }

    return @{
        Load = {
            param($Record)
            $d = New-BlankDomainDefaults
            foreach ($p in @($d.PSObject.Properties.Name)) { if ($Record.Contains($p) -and $null -ne $Record[$p]) { $d.$p = $Record[$p] } }
            $c.DisplayPrefix.Text = [string]$d.DisplayPrefix; $c.DisplaySuffix.Text = [string]$d.DisplaySuffix
            $c.DisplayPattern.Text = Get-ADEnvMapLabel $displayMap ([string]$d.DisplayNamePattern)
            $c.LogonPrefix.Text = [string]$d.LogonPrefix; $c.LogonSuffix.Text = [string]$d.LogonSuffix
            $c.AccountPattern.Text = Get-ADEnvMapLabel $accountMap ([string]$d.AccountNamePattern)
            $c.Case.Text = Get-ADEnvMapLabel $caseMap ([string]$d.AccountNameCase)
            $c.Upn.Text = [string]$d.UpnSuffix; $c.HomeDrive.Text = [string]$d.HomeDrive
            $c.NewUserOU.Text = [string]$d.DefaultNewUserOU; $c.DisabledOU.Text = [string]$d.DefaultDisabledOU; $c.BulkOU.Text = [string]$d.DefaultBulkOnboardOU
            $c.BulkDisplay.Text = Get-ADEnvMapLabel $bulkDisplayMap ([string]$d.BulkDisplayNamePattern)
            $c.BulkLogon.Text = Get-ADEnvMapLabel $bulkLogonMap ([string]$d.BulkAccountNamePattern)
            & $render
        }.GetNewClosure()
        Collect = {
            param($Record)
            [ordered]@{
                DisplayPrefix = $c.DisplayPrefix.Text.Trim(); DisplaySuffix = $c.DisplaySuffix.Text.Trim()
                DisplayNamePattern = (Get-ADEnvMapKey $displayMap $c.DisplayPattern.Text)
                LogonPrefix = $c.LogonPrefix.Text.Trim(); LogonSuffix = $c.LogonSuffix.Text.Trim()
                AccountNamePattern = (Get-ADEnvMapKey $accountMap $c.AccountPattern.Text)
                AccountNameCase = (Get-ADEnvMapKey $caseMap $c.Case.Text)
                UpnSuffix = $c.Upn.Text.Trim(); HomeDrive = $c.HomeDrive.Text.Trim()
                DefaultNewUserOU = $c.NewUserOU.Text.Trim(); DefaultDisabledOU = $c.DisabledOU.Text.Trim(); DefaultBulkOnboardOU = $c.BulkOU.Text.Trim()
                BulkDisplayNamePattern = (Get-ADEnvMapKey $bulkDisplayMap $c.BulkDisplay.Text)
                BulkAccountNamePattern = (Get-ADEnvMapKey $bulkLogonMap $c.BulkLogon.Text)
            }
        }.GetNewClosure()
    }
}

# =============================================================================
# Mail
# =============================================================================
function New-ADMailPage {
    param([System.Windows.Forms.TabPage]$Page, $App)
    $y = 12
    Add-ADEnvHeader -Parent $Page -Text 'Mail' -Y $y; $y += 34
    $tbServer = Add-ADEnvText -Parent $Page -Caption 'SMTP server' -Y $y; $y += 26
    [void](Add-ADEnvHint -Parent $Page -Text 'Relay used for notification mail after account actions (create, reset, disable, offboard, delete ...). IP or DNS name.' -Y $y); $y += 28
    $tbPort = Add-ADEnvText -Parent $Page -Caption 'SMTP port' -Y $y -W 80; $y += 26
    [void](Add-ADEnvHint -Parent $Page -Text '25 = standard anonymous relay.' -Y $y); $y += 28
    $tbFrom = Add-ADEnvText -Parent $Page -Caption 'Mail from' -Y $y; $y += 26
    [void](Add-ADEnvHint -Parent $Page -Text 'Sender address on notification mail, e.g. noreply@contoso.com.' -Y $y)
    return @{
        Load = {
            param($Record)
            $tbServer.Text = [string](Get-ADEnvValue $Record 'SmtpServer')
            $p = [string](Get-ADEnvValue $Record 'SmtpPort'); $tbPort.Text = $(if ($p) { $p } else { '25' })
            $tbFrom.Text = [string](Get-ADEnvValue $Record 'MailFrom')
        }.GetNewClosure()
        Collect = {
            param($Record)
            $port = 25; [void][int]::TryParse($tbPort.Text.Trim(), [ref]$port)
            [ordered]@{ SmtpServer = $tbServer.Text.Trim(); SmtpPort = $port; MailFrom = $tbFrom.Text.Trim() }
        }.GetNewClosure()
        Validate = {
            param($Record)
            $n = 0
            if ($tbPort.Text.Trim() -and (-not [int]::TryParse($tbPort.Text.Trim(), [ref]$n) -or $n -lt 1 -or $n -gt 65535)) { return 'SMTP port must be a number from 1 to 65535.' }
            return ''
        }.GetNewClosure()
    }
}

# =============================================================================
# Messages
# =============================================================================
function New-ADMessagesPage {
    param([System.Windows.Forms.TabPage]$Page, $App)
    $w = 1000; $h = 700
    if ($global:MainTabs -and (Get-Command Get-TabPageArea -ErrorAction SilentlyContinue)) {
        $a = Get-TabPageArea -Tabs $global:MainTabs
        $w = [Math]::Max(760, [Math]::Min(1200, $a.Width - 40))
        $h = [Math]::Max(520, $a.Height - 46 - 30 - 60)      # picker bar, sub-tab strip, note + margins
    }
    $note = Add-ADEnvHint -Parent $Page -Text 'Added to notification mail. New Account Welcome opens every new-account email ({FirstName}, {DisplayName}, {Username} are filled in); the four Additional Info messages can be chosen per mail. Pictures: 600 px wide / 200 KB each.' -Y 10 -X 12 -W $w -H 30
    $panel = New-Object System.Windows.Forms.Panel
    $panel.Location = New-Object System.Drawing.Point(12, 44); $panel.Size = New-Object System.Drawing.Size($w, $h)
    $panel.BackColor = [System.Drawing.Color]::White; $panel.BorderStyle = 'FixedSingle'
    $Page.Controls.Add($panel)

    $ed = New-AdditionalInfoEditor -Parent $panel -W ($w - 2) -H ($h - 2)
    if (-not $ed) { return @{} }
    return @{
        Load = {
            param($Record)
            $d = New-BlankDomainDefaults
            foreach ($p in @($d.PSObject.Properties.Name)) { if ($Record.Contains($p) -and $null -ne $Record[$p]) { $d.$p = $Record[$p] } }
            try { & $ed.RefreshLibrary } catch { }
            & $ed.Load $d
        }.GetNewClosure()
        Collect = {
            param($Record)
            $raw = & $ed.Collect
            $clean = Get-CleanDomainDefaults -Settings $raw        # 1.6.1 rules: titles, only referenced pictures
            $o = [ordered]@{}
            foreach ($k in @($raw.Keys)) { $o[$k] = $clean.$k }
            return $o
        }.GetNewClosure()
        # Titles + plain text + picture ids: the browser re-serializes the HTML
        # after loading, so comparing HTML would report changes nobody made.
        Fingerprint = {
            param($Record)
            $raw = & $ed.Collect
            $parts = foreach ($k in @($raw.Keys | Where-Object { $_ -notlike '*Html' -and $_ -ne 'AdditionalInfoImages' } | Sort-Object)) { "$k=$(([string]$raw[$k]) -replace '\s+', ' ')" }
            $ids = if ($raw['AdditionalInfoImages']) { @($raw['AdditionalInfoImages'].Keys | Sort-Object) -join ',' } else { '' }
            return (($parts -join '|') + '|img=' + $ids)
        }.GetNewClosure()
    }
}
