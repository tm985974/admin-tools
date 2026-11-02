#region -- ADComputers.StatusCards.UI.psm1 ------------------------------------
# Concern : Build-StatusCards - creates the five connectivity status card panels
#           (PING, RDP, SMB, Radmin, WinRM) on the Connectivity tab.
#           Returns a hashtable keyed by card name for Invoke-ComputerCheck to update.
# Load order: 81 - depends on ADComputers.Connectivity.TestPort (script scope)
# Split from: ADComputers.Tab.psm1
#endregion

#region -- Build-StatusCards --------------------------------------------------
function Build-StatusCards {
    param([System.Windows.Forms.TabPage]$Tab, [int]$Y)
    $PAD  = 8
    $TW   = $script:_TW
    $F_BIG = New-Object System.Drawing.Font('Segoe UI', 14, [System.Drawing.FontStyle]::Bold)
    $F_SM  = New-Object System.Drawing.Font('Segoe UI', 8)

    $cardW = [int](($TW - ($PAD*6)) / 5)
    $cardH = 84

    $cardDefs = @(
        @{ Key='ping';   Label='PING';          Color=[System.Drawing.Color]::FromArgb(230,240,255) }
        @{ Key='rdp';    Label='RDP (3389)';    Color=[System.Drawing.Color]::FromArgb(230,240,255) }
        @{ Key='smb';    Label='SMB (445)';     Color=[System.Drawing.Color]::FromArgb(230,240,255) }
        @{ Key='radmin'; Label='Radmin (4899)'; Color=[System.Drawing.Color]::FromArgb(230,240,255) }
        @{ Key='winrm';  Label='WinRM (5985)';  Color=[System.Drawing.Color]::FromArgb(230,240,255) }
    )

    $cards = @{}
    $x = $PAD
    foreach ($cd in $cardDefs) {
        $panel             = New-Object System.Windows.Forms.Panel
        $panel.Location    = New-Object System.Drawing.Point($x, $Y)
        $panel.Size        = New-Object System.Drawing.Size($cardW, $cardH)
        $panel.BackColor   = $cd.Color
        $panel.BorderStyle = 'FixedSingle'
        $Tab.Controls.Add($panel)

        $lLbl           = New-Object System.Windows.Forms.Label
        $lLbl.Text      = $cd.Label
        $lLbl.Location  = New-Object System.Drawing.Point(4,4)
        $lLbl.Size      = New-Object System.Drawing.Size(($cardW-8), 18)
        $lLbl.Font      = $F_SM
        $lLbl.ForeColor = [System.Drawing.Color]::DimGray
        $lLbl.TextAlign = 'MiddleCenter'
        $panel.Controls.Add($lLbl)

        $lVal           = New-Object System.Windows.Forms.Label
        $lVal.Text      = '-'
        $lVal.Location  = New-Object System.Drawing.Point(4,22)
        $lVal.Size      = New-Object System.Drawing.Size(($cardW-8), 36)
        $lVal.Font      = $F_BIG
        $lVal.ForeColor = [System.Drawing.Color]::DimGray
        $lVal.TextAlign = 'MiddleCenter'
        $panel.Controls.Add($lVal)

        $lMs            = New-Object System.Windows.Forms.Label
        $lMs.Text       = ''
        $lMs.Location   = New-Object System.Drawing.Point(4,58)
        $lMs.Size       = New-Object System.Drawing.Size(($cardW-8), 18)
        $lMs.Font       = $F_SM
        $lMs.ForeColor  = [System.Drawing.Color]::DimGray
        $lMs.TextAlign  = 'MiddleCenter'
        $panel.Controls.Add($lMs)

        $cards[$cd.Key] = @{ Panel=$panel; Value=$lVal; Ms=$lMs }
        $x += $cardW + $PAD
    }
    return $cards
}
#endregion

Export-ModuleMember -Function Build-StatusCards
