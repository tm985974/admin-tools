# UI_Env_FileManager.psm1   (LITE TIER)
#
# The "File Manager" page on the Environment tab: settings that rarely change
# (saved in the environment record as Fm<Key>, read with Get-FmSetting). Editable
# in the developer build and with the admin password; read-only with the user password.

function Register-FmEnvironmentPage {
    [CmdletBinding()]
    param()
    Register-EnvironmentSection -Title 'File Manager' -Order 10 -Build {
        param($Page, $App)
        $defaults = Get-FmDefaults
        $ctl = @{}
        $y = 14
        $add = {
            param([string]$Caption, $Control, [string]$Help, [int]$Width = 300)
            $l = New-Object System.Windows.Forms.Label
            $l.Text = $Caption; $l.Location = New-Object System.Drawing.Point(12, ($script:fmY + 3)); $l.Size = New-Object System.Drawing.Size(260, 20)
            $Control.Location = New-Object System.Drawing.Point(280, $script:fmY)
            if (-not ($Control -is [System.Windows.Forms.CheckBox])) { $Control.Width = $Width }
            $Page.Controls.Add($l); $Page.Controls.Add($Control)
            $script:fmY += 26
            $h = New-Object System.Windows.Forms.Label
            $h.Text = $Help; $h.Location = New-Object System.Drawing.Point(280, $script:fmY); $h.AutoSize = $true
            $h.MaximumSize = New-Object System.Drawing.Size(760, 0); $h.ForeColor = $App.Theme.Muted
            $Page.Controls.Add($h)
            $script:fmY += $(if ($Help.Length -gt 120) { 42 } else { 26 })
        }
        $script:fmY = $y

        $hdr = New-Object System.Windows.Forms.Label
        $hdr.Text = 'File Manager'; $hdr.Location = New-Object System.Drawing.Point(12, $script:fmY)
        Set-SectionStyle -App $App -Label $hdr
        $Page.Controls.Add($hdr); $script:fmY += 32

        $swap = New-Object System.Windows.Forms.ComboBox
        $swap.DropDownStyle = 'DropDownList'; [void]$swap.Items.AddRange([object[]]@('Ask', 'On', 'Off'))
        & $add 'Older copy than the one in _Clean' $swap ("Ask (default): such folders show as 'Older copy found'; Select all leaves them out, you tick them yourself. " +
            "On: they are treated like any other folder. Off: the copy in _Clean always stays.") 120
        $ctl.FmSwapOlder = $swap

        $tol = New-Object System.Windows.Forms.NumericUpDown
        $tol.Minimum = 0; $tol.Maximum = 48; $tol.DecimalPlaces = 1; $tol.Increment = 0.5
        & $add 'Same date within (hours)' $tol 'File dates this close count as the same when picking the oldest copy (FAT32 drives and time zones shift dates by whole hours). Default 2.' 80
        $ctl.FmToleranceHours = $tol

        $hash = New-Object System.Windows.Forms.CheckBox
        $hash.Text = 'Hash every file during a scan'
        $hash.AutoSize = $true
        & $add 'Scan' $hash 'On (default): every file is read once, so every match is confirmed and Check a folder works fully. Off: only files that might be duplicates are read (faster).'
        $ctl.FmHashEverything = $hash

        $min = New-Object System.Windows.Forms.NumericUpDown
        $min.Minimum = 0; $min.Maximum = 100000000
        & $add 'Smallest folder to list (KB)' $min '0 = list every folder that has files. Raise it (for example 10240 = 10 MB) to hide small matches such as program and settings folders.' 120
        $ctl.FmMinFolderKB = $min

        $igf = New-Object System.Windows.Forms.TextBox
        & $add 'Ignore files' $igf 'Wildcards, comma separated, for example Thumbs.db, desktop.ini, .DS_Store. Empty (default) = every file counts, so folders only match when identical. Applies to the next scan.' 520
        $ctl.FmIgnoreFiles = $igf

        $igd = New-Object System.Windows.Forms.TextBox
        & $add 'Ignore folders' $igd 'Wildcards, comma separated. Empty (default) = nothing is skipped (old Windows drives are shown in full, so you can decide).' 520
        $ctl.FmIgnoreFolders = $igd

        $btnDef = $App.Theme.MakeButton('Reset File Manager settings to defaults')
        $btnDef.Location = New-Object System.Drawing.Point(280, ($script:fmY + 4))
        $btnDef.Add_Click({
            $ctl.FmSwapOlder.SelectedItem = [string]$defaults.FmSwapOlder
            $ctl.FmToleranceHours.Value = [decimal]$defaults.FmToleranceHours
            $ctl.FmHashEverything.Checked = [bool]$defaults.FmHashEverything
            $ctl.FmMinFolderKB.Value = [decimal]$defaults.FmMinFolderKB
            $ctl.FmIgnoreFiles.Text = ''; $ctl.FmIgnoreFolders.Text = ''
        }.GetNewClosure())
        $Page.Controls.Add($btnDef)

        @{
            Load = {
                param($Record)
                $get = { param($k) if ($Record.Contains($k) -and $null -ne $Record[$k] -and [string]$Record[$k] -ne '') { $Record[$k] } else { $defaults[$k] } }
                $v = [string](& $get 'FmSwapOlder'); $ix = $ctl.FmSwapOlder.Items.IndexOf($v); $ctl.FmSwapOlder.SelectedIndex = $(if ($ix -ge 0) { $ix } else { 0 })
                $ctl.FmToleranceHours.Value = [decimal][Math]::Min(48, [Math]::Max(0, [double](& $get 'FmToleranceHours')))
                $ctl.FmHashEverything.Checked = [bool]::Parse([string](& $get 'FmHashEverything'))
                $ctl.FmMinFolderKB.Value = [decimal][Math]::Max(0, [double](& $get 'FmMinFolderKB'))
                $ctl.FmIgnoreFiles.Text = [string](& $get 'FmIgnoreFiles')
                $ctl.FmIgnoreFolders.Text = [string](& $get 'FmIgnoreFolders')
            }.GetNewClosure()
            Collect = {
                param($Record)
                return [ordered]@{
                    FmSwapOlder      = [string]$ctl.FmSwapOlder.SelectedItem
                    FmToleranceHours = [double]$ctl.FmToleranceHours.Value
                    FmHashEverything = [bool]$ctl.FmHashEverything.Checked
                    FmMinFolderKB    = [double]$ctl.FmMinFolderKB.Value
                    FmIgnoreFiles    = $ctl.FmIgnoreFiles.Text.Trim()
                    FmIgnoreFolders  = $ctl.FmIgnoreFolders.Text.Trim()
                }
            }.GetNewClosure()
            Validate = { param($Record) return '' }
        }
    }
}
