# UI_Env_Radmin.psm1   (LITE TIER)
#
# The "Radmin" page on the Environment tab: the per-environment settings the
# This Machine and Fleet tabs use (saved in the environment record as Radmin<Key>,
# read with Get-RadminSettings). Editable with the admin password or in the
# developer build; read-only with the user password - so the license key is set
# once by an admin and shipped in Config\Environments.json or saved per machine.

function Register-RadminEnvironmentPage {
    [CmdletBinding()]
    param()
    Register-EnvironmentSection -Title 'Radmin' -Order 10 -Build {
        param($Page, $App)
        $defaults = Get-RadminDefaults
        $fields = @(
            @{ K = 'LicenseKey';       C = 'License key';                 W = 300; Mask = $true
               H = 'The Radmin Server 3 license key (30 characters with dashes). Used by Save request / Collect requests. It only travels to a machine when a request is made.' }
            @{ K = 'TransferFolder';   C = 'Transfer folder';             W = 520
               H = 'Where Requests\, Licenses\ and Done\ live - a USB stick or a share. Blank = <data root>\Transfer. A PC can override it (Change... on its tab), e.g. for a different USB drive letter. %VARIABLES% allowed.' }
            @{ K = 'DeviceFolder';     C = 'Folder on each device';       W = 300
               H = 'Where rserver3.exe writes <NAME>.request and reads <NAME>.license on the machine being licensed.' }
            @{ K = 'RserverPath';      C = 'rserver3.exe path';           W = 520
               H = 'Blank = auto: %windir%\SysWOW64\rserver30\rserver3.exe, then %windir%\System32\rserver30\rserver3.exe.' }
            @{ K = 'LicensedRegKey';   C = 'Licensed registry key (HKLM)'; W = 520
               H = 'Licensed = this key exists (checked in the 64- and 32-bit registry views). No key = not licensed.' }
            @{ K = 'SaveRequestArgs';  C = 'Save-request arguments';      W = 520
               H = '{Key} and {File} are filled in. If this form does not produce the file, /requestfile:"{File}" and /requestfile"{File}" are tried next.' }
            @{ K = 'UseLicenseArgs';   C = 'Use-license arguments';       W = 520
               H = '{File} is filled in. If the registry key does not appear, /licensefile:"{File}" and /licensefile"{File}" are tried next.' }
            @{ K = 'CallTimeoutSec';   C = 'rserver3 timeout (seconds)';  W = 80
               H = 'How long one rserver3.exe call may take before it is stopped. 10 or more.' }
            @{ K = 'ParallelMachines'; C = 'Machines at a time (Fleet)';  W = 80
               H = 'How many remote machines the Fleet tab works on at once. 1 - 64.' }
            @{ K = 'Transport';        C = 'Fleet connects via';          W = 200; Choices = @('Auto', 'WinRM', 'SMB')
               H = 'Auto = WinRM, and over the admin share + WMI when WinRM cannot connect. WinRM = PowerShell remoting only (TCP 5985). SMB = admin share (C$, TCP 445) + WMI (TCP 135 / RPC) only. The Fleet tab can change it for a run.' }
        )

        $ctl = @{}
        $y = 14
        $hdr = New-Object System.Windows.Forms.Label
        $hdr.Text = 'Radmin Server 3 licensing'; $hdr.Location = New-Object System.Drawing.Point(12, $y)
        Set-SectionStyle -App $App -Label $hdr
        $Page.Controls.Add($hdr); $y += 30
        foreach ($f in $fields) {
            $l = New-Object System.Windows.Forms.Label
            $l.Text = $f.C; $l.Location = New-Object System.Drawing.Point(12, ($y + 3)); $l.Size = New-Object System.Drawing.Size(220, 20)
            if ($f.Choices) {
                $t = New-Object System.Windows.Forms.ComboBox
                $t.DropDownStyle = 'DropDownList'; [void]$t.Items.AddRange([object[]]$f.Choices)
            } else { $t = New-Object System.Windows.Forms.TextBox }
            $t.Location = New-Object System.Drawing.Point(240, $y); $t.Width = $f.W
            if ($f.K -like '*Args' -or $f.K -eq 'LicensedRegKey') { $t.Font = New-Object System.Drawing.Font($App.Theme.MonoFontName, 9) }
            $Page.Controls.Add($l); $Page.Controls.Add($t)
            if ($f.Mask) {
                $t.UseSystemPasswordChar = $true
                $show = New-Object System.Windows.Forms.CheckBox
                $show.Text = 'Show'; $show.AutoSize = $true; $show.Location = New-Object System.Drawing.Point((250 + $f.W), ($y + 1))
                $tb = $t
                $show.Add_CheckedChanged({ $tb.UseSystemPasswordChar = -not $show.Checked }.GetNewClosure())
                $Page.Controls.Add($show)
            }
            $ctl[$f.K] = $t
            $y += 26
            $h = New-Object System.Windows.Forms.Label
            $h.Text = $f.H; $h.Location = New-Object System.Drawing.Point(240, $y); $h.AutoSize = $true
            $h.MaximumSize = New-Object System.Drawing.Size(640, 0); $h.ForeColor = $App.Theme.Muted
            $Page.Controls.Add($h)
            $y += $(if ($f.H.Length -gt 110) { 40 } else { 24 })
        }
        $btnDef = $App.Theme.MakeButton('Reset command settings to defaults')
        $btnDef.Location = New-Object System.Drawing.Point(240, ($y + 4))
        $btnDef.Add_Click({
            foreach ($k in @('DeviceFolder', 'RserverPath', 'LicensedRegKey', 'SaveRequestArgs', 'UseLicenseArgs', 'CallTimeoutSec', 'ParallelMachines')) { $ctl[$k].Text = [string]$defaults[$k] }
            $ctl.Transport.SelectedIndex = 0
        }.GetNewClosure())
        $Page.Controls.Add($btnDef)

        @{
            Load = {
                param($Record)
                foreach ($k in @($ctl.Keys)) {
                    $rk = 'Radmin' + $k
                    $v = $(if ($Record.Contains($rk) -and $null -ne $Record[$rk] -and [string]$Record[$rk] -ne '') { [string]$Record[$rk] } else { [string]$defaults[$k] })
                    if ($ctl[$k] -is [System.Windows.Forms.ComboBox]) {
                        $ix = $ctl[$k].Items.IndexOf($v); $ctl[$k].SelectedIndex = $(if ($ix -ge 0) { $ix } else { 0 })
                    } else { $ctl[$k].Text = $v }
                }
            }.GetNewClosure()
            Collect = {
                param($Record)
                $h = [ordered]@{}
                foreach ($k in @($ctl.Keys)) {
                    $v = $(if ($ctl[$k] -is [System.Windows.Forms.ComboBox]) { [string]$ctl[$k].SelectedItem } else { $ctl[$k].Text.Trim() })
                    $n = 0
                    if ($k -in @('CallTimeoutSec', 'ParallelMachines') -and [int]::TryParse($v, [ref]$n)) { $h['Radmin' + $k] = $n } else { $h['Radmin' + $k] = $v }
                }
                return $h
            }.GetNewClosure()
            Validate = {
                param($Record)
                $n = 0
                if (-not [int]::TryParse($ctl.CallTimeoutSec.Text.Trim(), [ref]$n) -or $n -lt 10) { return 'Radmin: the rserver3 timeout must be a whole number of seconds, 10 or more.' }
                if (-not [int]::TryParse($ctl.ParallelMachines.Text.Trim(), [ref]$n) -or $n -lt 1 -or $n -gt 64) { return 'Radmin: machines at a time must be 1 - 64.' }
                if ($ctl.SaveRequestArgs.Text -and ($ctl.SaveRequestArgs.Text -notmatch '\{File\}' -or $ctl.SaveRequestArgs.Text -notmatch '\{Key\}')) { return 'Radmin: the save-request arguments need {Key} and {File}.' }
                if ($ctl.UseLicenseArgs.Text -and $ctl.UseLicenseArgs.Text -notmatch '\{File\}') { return 'Radmin: the use-license arguments need {File}.' }
                $key = $ctl.LicenseKey.Text.Trim()
                if ($key -and $key.Length -ne 30) {
                    $q = "The license key '$($key.Substring(0, [Math]::Min(6, $key.Length)))...' does not look like a 30-character Radmin key. Save it anyway?"
                    if ([System.Windows.Forms.MessageBox]::Show($q, 'Radmin', 'YesNo', 'Question') -ne 'Yes') { return 'Radmin: check the license key.' }   # not-a-command: settings check
                }
                return ''
            }.GetNewClosure()
        }
    }
}
