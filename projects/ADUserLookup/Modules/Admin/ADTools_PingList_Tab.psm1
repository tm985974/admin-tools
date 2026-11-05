#region -- ADTools.PingList.Tab.psm1 ---------------------------------------------
# Concern : Build-PingListTab - Tools > Ping List: paste a list of computer
#           names, then ping them all once or continuously. Same results grid
#           and toolbar as the Ping Computers dialog (New-PingGroupPanel,
#           ADComputers.Ping.Panel); each round reads the paste box again, so
#           the list can be edited between rounds (counters of computers still
#           on the list are kept).
#           Names may be one per line or separated by commas / semicolons /
#           spaces; "\\" prefixes, trailing "$" and '#' comment lines are
#           ignored (ConvertTo-ComputerNameList, ADComputers.Ping.Engine).
# Load order: after ADComputers.Ping.Engine / ADComputers.Ping.Panel; before
#             ADTools.Register-ToolsTab, which calls it.
# Layout   : left column (25%) = paste box like Abort Remote Reboot; the rest
#            = the ping panel. Sized from $script:_TW / $script:_TH like every
#            Tools sub-tab.
#endregion

#region -- Build-PingListTab ----------------------------------------------------
function Build-PingListTab {
    param([System.Windows.Forms.TabPage]$Tab)
    $PAD    = 8
    $F_UI_B = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $F_MONO = New-Object System.Drawing.Font('Consolas', 9)
    $TW     = $script:_TW; $TH = $script:_TH

    $lHint           = New-Object System.Windows.Forms.Label
    $lHint.Text      = 'Paste computer names (one per line, or separated by commas / spaces), then Ping once or Start continuous. Right-click a result row for RDP, Sessions, LAPS and the other computer actions.'
    $lHint.Location  = New-Object System.Drawing.Point($PAD, $PAD)
    $lHint.Size      = New-Object System.Drawing.Size(($TW - $PAD * 2), 18)
    $lHint.Font      = New-Object System.Drawing.Font('Segoe UI', 8)
    $lHint.ForeColor = [System.Drawing.Color]::DimGray
    $Tab.Controls.Add($lHint)

    $COL_Y = $PAD + 26
    $COL_H = $TH - $COL_Y - $PAD
    $COL_W = [int](($TW - ($PAD * 2)) * 0.22)
    $COL_X = $PAD

    $lHeader           = New-Object System.Windows.Forms.Label
    $lHeader.Text      = 'Computer Names'
    $lHeader.Location  = New-Object System.Drawing.Point($COL_X, $COL_Y)
    $lHeader.Size      = New-Object System.Drawing.Size($COL_W, 20)
    $lHeader.Font      = $F_UI_B
    $lHeader.ForeColor = [System.Drawing.Color]::FromArgb(0, 80, 160)
    $Tab.Controls.Add($lHeader)

    $BOTTOM_H = 18 + 4 + 30
    $tbH      = $COL_H - 22 - 8 - $BOTTOM_H

    $tbNames               = New-Object System.Windows.Forms.TextBox
    $tbNames.Location      = New-Object System.Drawing.Point($COL_X, ($COL_Y + 22))
    $tbNames.Size          = New-Object System.Drawing.Size($COL_W, $tbH)
    $tbNames.Font          = $F_MONO
    $tbNames.Multiline     = $true
    $tbNames.ScrollBars    = 'Vertical'
    $tbNames.AcceptsReturn = $true
    $Tab.Controls.Add($tbNames)

    $STATUS_Y         = $COL_Y + 22 + $tbH + 8
    $lCount           = New-Object System.Windows.Forms.Label
    $lCount.Location  = New-Object System.Drawing.Point($COL_X, $STATUS_Y)
    $lCount.Size      = New-Object System.Drawing.Size($COL_W, 18)
    $lCount.Font      = New-Object System.Drawing.Font('Segoe UI', 8)
    $lCount.ForeColor = [System.Drawing.Color]::DimGray
    $lCount.Text      = '0 computer(s)'
    $Tab.Controls.Add($lCount)

    $btnClear = New-StdButton -Text 'Clear List' -X $COL_X -Y ($STATUS_Y + 18 + 4) -W $COL_W -H 30 -Parent $Tab

    $host2         = New-Object System.Windows.Forms.Panel
    $host2.Location = New-Object System.Drawing.Point(($COL_X + $COL_W + $PAD * 2), $COL_Y)
    $host2.Size     = New-Object System.Drawing.Size(($TW - $COL_W - $PAD * 5), $COL_H)
    $host2.Anchor   = 'Top, Left, Right, Bottom'
    $Tab.Controls.Add($host2)

    $parseFn  = ${function:ConvertTo-ComputerNameList}
    $provider = { & $parseFn -Text $tbNames.Text }.GetNewClosure()     # unrolled; the panel wraps it with @()
    $capturedContext = $script:ToolsCtx
    $app = $script:ADApp
    $api = New-PingGroupPanel -Parent $host2 -NamesProvider $provider -App $app -Context $capturedContext -Title 'Ping List'

    $tbNames.Add_TextChanged({
        $n = @(& $parseFn -Text $tbNames.Text).Count
        $lCount.Text = "$n computer(s)"
    }.GetNewClosure())

    $stopFn = $api.Stop; $pState = $api.State; $pGrid = $api.Grid; $refreshFn = $api.Refresh
    $btnClear.Add_Click({
        & $stopFn
        $pState.Rows.Clear(); $pGrid.Rows.Clear(); $pState.RoundNo = 0
        & $refreshFn
        $tbNames.Clear()
        $tbNames.Focus() | Out-Null
    }.GetNewClosure())
}
#endregion
