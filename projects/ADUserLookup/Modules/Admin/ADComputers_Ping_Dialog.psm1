#region -- ADComputers.Ping.Dialog.psm1 ------------------------------------------
# Concern : Show-PingGroupDialog - "Ping Computers" window for the computers
#           selected in any computer list (right-click > Ping Selected...).
#           Hosts New-PingGroupPanel (ADComputers.Ping.Panel) with a fixed
#           name list and starts pinging continuously as soon as it opens
#           (Stop / Ping once / interval / timeout on its toolbar). Not modal,
#           so several can be open at once beside the main window; closing it
#           stops its timer.
# Load order: after ADComputers.Ping.Engine and ADComputers.Ping.Panel.
#endregion

#region -- Show-PingGroupDialog -------------------------------------------------
function Show-PingGroupDialog {
    <#
    .PARAMETER ComputerNames
        The computers to ping (duplicates and blanks are dropped).
    .PARAMETER Context
        Shared AD context, for the computer right-click menu on the rows.
    .PARAMETER Once
        Ping once instead of continuously when the window opens.
    .PARAMETER NoConfirm
        The caller already showed / confirmed the command (the first round
        is not confirmed again).
    #>
    param(
        [Parameter(Mandatory)] [string[]]$ComputerNames,
        [PSCustomObject]$Context = $null,
        $App = $null,
        [switch]$Once,
        [switch]$NoConfirm
    )
    if (-not $App) { $App = $script:ADApp }
    $names = @(ConvertTo-ComputerNameList -Text ($ComputerNames -join "`r`n"))
    if ($names.Count -eq 0) { return }

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'Ping Computers'
    $dlg.StartPosition = 'CenterScreen'
    $dlg.Size = New-Object System.Drawing.Size(1080, 560)
    $dlg.MinimumSize = New-Object System.Drawing.Size(760, 320)
    $dlg.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $dlg.ShowInTaskbar = $true

    $fixed = $names
    $provider = { $fixed }.GetNewClosure()     # unrolled; the panel wraps it with @()
    $api = New-PingGroupPanel -Parent $dlg -NamesProvider $provider -App $App -Context $Context -Title 'Ping Computers'

    $owner = $null
    try { $owner = [System.Windows.Forms.Form]::ActiveForm } catch { }

    $stopFn = $api.Stop; $timer = $api.Timer
    $dlg.Add_FormClosed({
        try { & $stopFn } catch { }
        try { $timer.Stop(); $timer.Dispose() } catch { }
    }.GetNewClosure())

    $onceFn = $api.Once; $startFn = $api.Start
    $doOnce = [bool]$Once; $skip = [bool]$NoConfirm
    $dlg.Add_Shown({
        if ($doOnce) { & $onceFn -NoConfirm:$skip } else { & $startFn -NoConfirm:$skip }
    }.GetNewClosure())

    if ($owner -and -not $owner.IsDisposed) { $dlg.Show($owner) } else { $dlg.Show() }
}
#endregion
