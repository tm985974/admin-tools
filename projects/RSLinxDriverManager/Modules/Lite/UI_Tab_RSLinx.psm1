# UI_Tab_RSLinx.psm1   (LITE TIER)
#
# The RSLinx tab: the RSLinx Classic control panel (RSLINXCP.EXE) shown inside
# this window, plus facts about this PC (IP, admin rights, installed Rockwell
# software). The control panel is started the first time the tab is opened and
# closed with the app.

$script:R = $null
$script:RSLinxCpPath = 'C:\Program Files (x86)\Rockwell Software\RSLinx\RSLINXCP.EXE'

function New-RSLinxTab {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Windows.Forms.TabPage]$Page,
        [Parameter(Mandatory)] $App
    )
    Set-LazyTabBuild -Page $Page -App $App -Build { param($Page, $App) Initialize-RSLinxTab -Page $Page -App $App }
}

function Initialize-RSLinxWin32 {
    if ('RSLinxDriverManager.Win32' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace RSLinxDriverManager {
public static class Win32 {
    [DllImport("user32.dll", SetLastError=true)] public static extern IntPtr SetParent(IntPtr hWndChild, IntPtr hWndNewParent);
    [DllImport("user32.dll", SetLastError=true)] public static extern bool MoveWindow(IntPtr hWnd, int X, int Y, int nWidth, int nHeight, bool bRepaint);
    [DllImport("user32.dll", SetLastError=true)] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll", SetLastError=true)] public static extern bool IsWindow(IntPtr hWnd);
    [DllImport("user32.dll", SetLastError=true)] public static extern int GetWindowLong(IntPtr hWnd, int nIndex);
    [DllImport("user32.dll", SetLastError=true)] public static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);
    public const int GWL_STYLE = -16;
    public const int WS_CAPTION = 0x00C00000;
    public const int WS_THICKFRAME = 0x00040000;
    public const int WS_MINIMIZEBOX = 0x00020000;
    public const int WS_MAXIMIZEBOX = 0x00010000;
    public const int SW_SHOW = 5;
}
}
'@
}

function Initialize-RSLinxTab {
    param($Page, $App)
    $T = $App.Theme
    $script:R = @{ App = $App; Page = $Page; Proc = $null; Hwnd = [IntPtr]::Zero }
    $Page.AutoScroll = $false
    $Page.Padding = New-Object System.Windows.Forms.Padding(8, 6, 8, 6)

    # ---- right: this PC ----
    $info = New-Object System.Windows.Forms.Panel
    $info.Dock = 'Right'; $info.Width = 400; $info.Padding = New-Object System.Windows.Forms.Padding(12, 0, 0, 0)
    $tbl = New-Object System.Windows.Forms.TableLayoutPanel
    $tbl.Dock = 'Top'; $tbl.AutoSize = $true; $tbl.ColumnCount = 2
    [void]$tbl.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 130)))
    [void]$tbl.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    $script:R.InfoTable = $tbl
    $bInfo = $T.MakeButton('Refresh')
    $bInfo.Add_Click({ Update-RSLinxInfo })
    $infoBar = New-RSLinxButtonBar -App $App -Buttons @($bInfo) -Dock 'Top' -Height 38
    $info.Controls.Add($infoBar)
    $info.Controls.Add($tbl)
    $info.Controls.Add((New-RSLinxHeader -App $App -Text 'This PC'))

    # ---- left: embedded control panel ----
    $left = New-Object System.Windows.Forms.Panel
    $left.Dock = 'Fill'
    $host1 = New-Object System.Windows.Forms.Panel
    $host1.Dock = 'Fill'; $host1.BorderStyle = 'FixedSingle'; $host1.BackColor = $T.Panel
    $script:R.Host = $host1
    $msg = New-Object System.Windows.Forms.Label
    $msg.Dock = 'Fill'; $msg.TextAlign = 'MiddleCenter'; $msg.ForeColor = $T.Muted
    $host1.Controls.Add($msg)
    $script:R.Msg = $msg
    $host1.Add_Resize({ Resize-RSLinxEmbedded })

    $bLaunch = $T.MakeButton('Start / re-attach control panel')
    $bDetach = $T.MakeButton('Open in its own window')
    $bLaunch.Add_Click({ Start-RSLinxEmbedded })
    $bDetach.Add_Click({ Close-RSLinxEmbedded -Release })
    $bar = New-RSLinxButtonBar -App $App -Buttons @($bLaunch, $bDetach) -Dock 'Top' -Height 38
    $left.Controls.Add($host1)
    $left.Controls.Add($bar)
    $left.Controls.Add((New-RSLinxHeader -App $App -Text 'RSLinx Classic'))

    $Page.Controls.Add($left)
    $Page.Controls.Add($info)

    $form = $Page.FindForm()
    if ($form) { $form.Add_FormClosing({ Close-RSLinxEmbedded }) }

    Update-RSLinxInfo
    Start-RSLinxEmbedded
}

function Update-RSLinxInfo {
    $tbl = $script:R.InfoTable
    $tbl.SuspendLayout()
    try {
        $tbl.Controls.Clear(); $tbl.RowStyles.Clear()
        $facts = Get-RSLinxSystemInfo
        $tbl.RowCount = $facts.Count
        $r = 0
        foreach ($k in $facts.Keys) {
            $a = New-Object System.Windows.Forms.Label; $a.Text = $k; $a.AutoSize = $true; $a.ForeColor = $script:R.App.Theme.Muted
            $a.Margin = New-Object System.Windows.Forms.Padding(0, 4, 4, 4)
            $b = New-Object System.Windows.Forms.Label; $b.Text = [string]$facts[$k]; $b.AutoSize = $true
            $b.MaximumSize = New-Object System.Drawing.Size(250, 0); $b.Margin = New-Object System.Windows.Forms.Padding(0, 4, 0, 4)
            if ($k -eq 'Administrator' -and $facts[$k] -ne 'Yes') { $b.ForeColor = [System.Drawing.Color]::Firebrick }
            $tbl.Controls.Add($a, 0, $r); $tbl.Controls.Add($b, 1, $r); $r++
        }
    } catch { $script:R.App.Log('WARN', 'RSLinx', "system info: $($_.Exception.Message)") }
    finally { $tbl.ResumeLayout() }
}

function Get-RSLinxMainWindow {
    param([System.Diagnostics.Process]$Process, [int]$TimeoutMs = 15000)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        try {
            $Process.Refresh()
            if ($Process.HasExited) { break }
            if ($Process.MainWindowHandle -ne [IntPtr]::Zero) { return $Process.MainWindowHandle }
        } catch { }
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 150
    }
    return [IntPtr]::Zero
}

function Start-RSLinxEmbedded {
    $App = $script:R.App
    if ($script:R.Hwnd -ne [IntPtr]::Zero) {
        try { if ([RSLinxDriverManager.Win32]::IsWindow($script:R.Hwnd)) { Resize-RSLinxEmbedded; return } } catch { }
        $script:R.Hwnd = [IntPtr]::Zero
    }
    if (-not (Test-Path -LiteralPath $script:RSLinxCpPath)) {
        $script:R.Msg.Text = "RSLinx Classic control panel not found:`r`n$($script:RSLinxCpPath)"
        $script:R.Msg.Visible = $true
        $App.Log('WARN', 'RSLinx', "RSLINXCP.EXE not found at $($script:RSLinxCpPath)")
        return
    }
    try {
        Initialize-RSLinxWin32
        $script:R.Msg.Text = 'Starting the RSLinx Classic control panel...'; $script:R.Msg.Visible = $true
        if (-not $script:R.Proc -or $script:R.Proc.HasExited) { $script:R.Proc = Start-Process -FilePath $script:RSLinxCpPath -PassThru }
        $h = Get-RSLinxMainWindow -Process $script:R.Proc
        if ($h -eq [IntPtr]::Zero) { $script:R.Msg.Text = 'The control panel started but its window was not found. Try Start / re-attach.'; return }
        [void][RSLinxDriverManager.Win32]::SetParent($h, $script:R.Host.Handle)
        $style = [RSLinxDriverManager.Win32]::GetWindowLong($h, [RSLinxDriverManager.Win32]::GWL_STYLE)
        $style = $style -band (-bnot ([RSLinxDriverManager.Win32]::WS_CAPTION -bor [RSLinxDriverManager.Win32]::WS_THICKFRAME -bor
                                       [RSLinxDriverManager.Win32]::WS_MINIMIZEBOX -bor [RSLinxDriverManager.Win32]::WS_MAXIMIZEBOX))
        [void][RSLinxDriverManager.Win32]::SetWindowLong($h, [RSLinxDriverManager.Win32]::GWL_STYLE, $style)
        [void][RSLinxDriverManager.Win32]::ShowWindow($h, [RSLinxDriverManager.Win32]::SW_SHOW)
        $script:R.Hwnd = $h
        $script:R.Msg.Visible = $false
        Resize-RSLinxEmbedded
        $App.Log('INFO', 'RSLinx', "Control panel embedded (PID $($script:R.Proc.Id)).")
    }
    catch {
        $script:R.Msg.Text = "Could not show the control panel:`r`n$($_.Exception.Message)"; $script:R.Msg.Visible = $true
        $App.Log('ERROR', 'RSLinx', "embed failed: $($_.Exception.ToString())")
    }
}

function Resize-RSLinxEmbedded {
    if (-not $script:R -or $script:R.Hwnd -eq [IntPtr]::Zero) { return }
    try {
        $c = $script:R.Host.ClientSize
        [void][RSLinxDriverManager.Win32]::MoveWindow($script:R.Hwnd, 0, 0, $c.Width, $c.Height, $true)
    } catch { }
}

# -Release: hand the window back to the desktop and keep it running.
# Otherwise: close the control panel (used when the app closes).
function Close-RSLinxEmbedded {
    param([switch]$Release)
    if (-not $script:R) { return }
    try {
        if ($Release) {
            if ($script:R.Hwnd -ne [IntPtr]::Zero) {
                $h = $script:R.Hwnd
                $style = [RSLinxDriverManager.Win32]::GetWindowLong($h, [RSLinxDriverManager.Win32]::GWL_STYLE)
                $style = $style -bor [RSLinxDriverManager.Win32]::WS_CAPTION -bor [RSLinxDriverManager.Win32]::WS_THICKFRAME -bor
                         [RSLinxDriverManager.Win32]::WS_MINIMIZEBOX -bor [RSLinxDriverManager.Win32]::WS_MAXIMIZEBOX
                [void][RSLinxDriverManager.Win32]::SetWindowLong($h, [RSLinxDriverManager.Win32]::GWL_STYLE, $style)
                [void][RSLinxDriverManager.Win32]::SetParent($h, [IntPtr]::Zero)
                [void][RSLinxDriverManager.Win32]::MoveWindow($h, 100, 100, 900, 650, $true)
                $script:R.Hwnd = [IntPtr]::Zero
                $script:R.Proc = $null          # no longer ours to close
                $script:R.Msg.Text = 'The control panel is in its own window. Start / re-attach brings a new one here.'
                $script:R.Msg.Visible = $true
            }
            return
        }
        if ($script:R.Proc -and -not $script:R.Proc.HasExited) {
            [void]$script:R.Proc.CloseMainWindow()
            if (-not $script:R.Proc.WaitForExit(2000)) { $script:R.Proc.Kill() }
        }
    } catch { }
}
