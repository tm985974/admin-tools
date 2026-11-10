#region -- ADTools.SetDns.Tab.psm1 ----------------------------------------------
# Concern : Build-SetDnsTab - Tools > Set DNS: paste a list of computer names,
#           enter the DNS servers, and apply them to every physical "Up" adapter
#           on each computer (Invoke-SetRemoteDns / ADTools.SetDns.Engine over
#           WinRM). Replaces the old standalone RemoteDNSChange.ps1.
#           Every OK/FAIL line reaches the shared Activity Log automatically
#           (Write-OperationLog, called inside Invoke-SetRemoteDns) - no separate
#           results grid on this page, same as Abort Remote Reboot.
# Load order: before ADTools.Register-ToolsTab (126), which calls Build-SetDnsTab
#             directly. Depends on ADTools.SetDns.Engine (Invoke-SetRemoteDns,
#             Get-SetDnsCommandText), Services.AD.Reporting (New-StdButton),
#             Base\Services_Commands (Confirm-AppCommand).
# Layout   : left column (paste box of computer names) laid out exactly like
#            Abort Remote Reboot's single column; to its right, the DNS fields
#            and the Apply button. Sized from $script:_TW / $script:_TH like
#            every Tools sub-tab.
# Notes     : The Apply button confirms through the command engine (Confirm-
#             AppCommand, Kind Change) so the exact Invoke-Command text is shown
#             (per the setting / Shift) before anything runs. Dot-sourced
#             functions captured via ${function:} and $script:ToolsCtx captured
#             into a local BEFORE .GetNewClosure() - the closure-scope rule used
#             throughout this codebase (see ADTools.AbortReboot.Tab header).
#             PS 5.1 compatible.
#endregion

#region -- Build-SetDnsTab ------------------------------------------------------
function Build-SetDnsTab {
    param([System.Windows.Forms.TabPage]$Tab)
    $PAD    = 8
    $F_UI   = New-Object System.Drawing.Font('Segoe UI', 9)
    $F_UI_B = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $F_MONO = New-Object System.Drawing.Font('Consolas', 9)
    $TW     = $script:_TW; $TH = $script:_TH

    $lHint           = New-Object System.Windows.Forms.Label
    $lHint.Text      = 'Paste computer names (one per line, or separated by commas / spaces), set the DNS servers, then Apply. Sets both DNS servers on every physical adapter that is Up, on each computer, over WinRM. Results are written to the Activity Log below.'
    $lHint.Location  = New-Object System.Drawing.Point($PAD, $PAD)
    $lHint.Size      = New-Object System.Drawing.Size(($TW - $PAD * 2), 32)
    $lHint.Font      = New-Object System.Drawing.Font('Segoe UI', 8)
    $lHint.ForeColor = [System.Drawing.Color]::DimGray
    $Tab.Controls.Add($lHint)

    # ----- Left column: computer-name paste box (matches Abort Remote Reboot) --
    $COL_Y = $PAD + 40
    $COL_H = $TH - $COL_Y - $PAD
    $COL_W = [int](($TW - ($PAD * 2)) * 0.25)
    $COL_X = $PAD

    $lHeader           = New-Object System.Windows.Forms.Label
    $lHeader.Text      = 'Computer Names'
    $lHeader.Location  = New-Object System.Drawing.Point($COL_X, $COL_Y)
    $lHeader.Size      = New-Object System.Drawing.Size($COL_W, 20)
    $lHeader.Font      = $F_UI_B
    $lHeader.ForeColor = [System.Drawing.Color]::FromArgb(0, 80, 160)
    $Tab.Controls.Add($lHeader)

    $lCountY = $COL_Y + 22
    $tbNames               = New-Object System.Windows.Forms.TextBox
    $tbNames.Location      = New-Object System.Drawing.Point($COL_X, $lCountY)
    $tbNames.Size          = New-Object System.Drawing.Size($COL_W, ($COL_H - 22 - 24))
    $tbNames.Font          = $F_MONO
    $tbNames.Multiline     = $true
    $tbNames.ScrollBars    = 'Vertical'
    $tbNames.AcceptsReturn = $true
    $Tab.Controls.Add($tbNames)

    $lCount           = New-Object System.Windows.Forms.Label
    $lCount.Location  = New-Object System.Drawing.Point($COL_X, ($lCountY + $tbNames.Height + 4))
    $lCount.Size      = New-Object System.Drawing.Size($COL_W, 18)
    $lCount.Font      = New-Object System.Drawing.Font('Segoe UI', 8)
    $lCount.ForeColor = [System.Drawing.Color]::DimGray
    $lCount.Text      = '0 computer(s)'
    $Tab.Controls.Add($lCount)

    # ----- Right side: DNS settings section -----------------------------------
    $RX = $COL_X + $COL_W + $PAD * 2
    $RW = ($TW - $PAD) - $RX
    $sec = New-SectionPanel -Parent $Tab -Title 'DNS Settings' -X $RX -Y $COL_Y -W $RW -ContentH 210

    $mk = {
        param($text, $x, $y, $w, $h, $font)
        $l = New-Object System.Windows.Forms.Label
        $l.Text = $text; $l.Location = New-Object System.Drawing.Point($x, $y)
        $l.Size = New-Object System.Drawing.Size($w, $h); $l.Font = $font
        $sec.Controls.Add($l); return $l
    }

    [void](& $mk 'Primary DNS:'   14 16 120 22 $F_UI)
    $tbPrimary          = New-Object System.Windows.Forms.TextBox
    $tbPrimary.Location = New-Object System.Drawing.Point(140, 14)
    $tbPrimary.Size     = New-Object System.Drawing.Size(200, 24)
    $tbPrimary.Font     = $F_UI
    $tbPrimary.Text     = '10.144.32.1'
    $sec.Controls.Add($tbPrimary)

    [void](& $mk 'Secondary DNS:' 14 48 120 22 $F_UI)
    $tbSecondary          = New-Object System.Windows.Forms.TextBox
    $tbSecondary.Location = New-Object System.Drawing.Point(140, 46)
    $tbSecondary.Size     = New-Object System.Drawing.Size(200, 24)
    $tbSecondary.Font     = $F_UI
    $tbSecondary.Text     = '10.144.32.2'
    $sec.Controls.Add($tbSecondary)

    $chkRegister          = New-Object System.Windows.Forms.CheckBox
    $chkRegister.Text     = "Register this connection's addresses in DNS"
    $chkRegister.Location  = New-Object System.Drawing.Point(16, 84)
    $chkRegister.Size      = New-Object System.Drawing.Size(360, 22)
    $chkRegister.Font      = $F_UI
    $chkRegister.Checked   = $true
    $sec.Controls.Add($chkRegister)

    $lStatus           = New-Object System.Windows.Forms.Label
    $lStatus.Location  = New-Object System.Drawing.Point(14, 150)
    $lStatus.Size      = New-Object System.Drawing.Size(($RW - 30), 40)
    $lStatus.Font      = $F_UI
    $lStatus.ForeColor = [System.Drawing.Color]::DimGray
    $sec.Controls.Add($lStatus)

    $btnApply = New-StdButton -Text 'Apply DNS Settings' -X 16 -Y 114 -W 200 -H 30 -Parent $sec
    $btnApply.Font = $F_UI_B

    # ----- captures (closure-scope rule) --------------------------------------
    $parseFn      = ${function:ConvertTo-ComputerNameList}
    $invSetDnsFn  = ${function:Invoke-SetRemoteDns}
    $cmdTextFn    = ${function:Get-SetDnsCommandText}
    $confirmCmdFn = ${function:Confirm-AppCommand}
    $capturedCtx  = $script:ToolsCtx
    $dnsApp       = $script:ADApp

    $tbNames.Add_TextChanged({
        $n = @(& $parseFn -Text $tbNames.Text).Count
        $lCount.Text = "$n computer(s)"
    }.GetNewClosure())

    $btnApply.Add_Click({
        $names = @(& $parseFn -Text $tbNames.Text)
        if ($names.Count -eq 0) {
            $lStatus.ForeColor = [System.Drawing.Color]::FromArgb(156, 0, 6)
            $lStatus.Text      = 'Paste at least one computer name.'
            return
        }
        $dns = @($tbPrimary.Text.Trim(), $tbSecondary.Text.Trim() | Where-Object { $_ })
        if ($dns.Count -eq 0) {
            $lStatus.ForeColor = [System.Drawing.Color]::FromArgb(156, 0, 6)
            $lStatus.Text      = 'Enter at least a primary DNS server.'
            return
        }
        if (-not $invSetDnsFn) {
            $lStatus.ForeColor = [System.Drawing.Color]::FromArgb(156, 0, 6)
            $lStatus.Text      = 'DNS engine module not loaded.'
            return
        }

        if ($confirmCmdFn -and $cmdTextFn) {
            $code = & $cmdTextFn -Names $names -Dns $dns -RegisterDynamic ([bool]$chkRegister.Checked)
            $ok = & $confirmCmdFn -App $dnsApp -Title 'Set DNS' -Kind Change -RunLabel 'Apply' `
                -Summary "Set DNS ($($dns -join ', ')) on $($names.Count) computer(s)." -Code $code
            if (-not $ok) { return }
        }

        $btnApply.Enabled  = $false
        $lStatus.ForeColor = [System.Drawing.Color]::DimGray
        $lStatus.Text      = 'Applying...'
        [System.Windows.Forms.Application]::DoEvents()

        $result = & $invSetDnsFn -Names $names -Dns $dns `
                      -RegisterDynamic ([bool]$chkRegister.Checked) -Context $capturedCtx
        $btnApply.Enabled = $true

        if (-not $result) { $lStatus.Text = 'Nothing to do.'; return }
        $lStatus.ForeColor = if ($result.FailCount -gt 0) { [System.Drawing.Color]::FromArgb(156, 0, 6) } else { [System.Drawing.Color]::FromArgb(0, 97, 0) }
        $lStatus.Text      = "Done. OK: $($result.OkCount)  Failed: $($result.FailCount) - see Activity Log below for detail."
    }.GetNewClosure())
}
#endregion

Export-ModuleMember -Function Build-SetDnsTab
