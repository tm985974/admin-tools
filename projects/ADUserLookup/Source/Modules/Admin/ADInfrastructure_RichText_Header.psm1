#region -- ADInfrastructure.RichText.Header.psm1 -----------------------------
# Concern : RTB-Header and RTB-Line - RichTextBox formatting helpers used by
#           Read-ForestDomainInfo to render structured text in the Level tab.
#           Owns shared script-scope state for all ADInfrastructure sub-modules.
# Load order: 99 - no dependencies on other AD-Admin modules
# Split from: ADInfrastructure.Query.psm1
#endregion

#region -- Shared script-scope state ------------------------------------------
$script:InfraCtx   = $null
$script:InfraTab   = $null
$script:InfraPages = @{}
$script:_TW        = 0
$script:_TH        = 0

$script:DCGrid     = $null
$script:TrustGrid  = $null
$script:DNSTbQuery = $null
$script:DNSCmbType = $null
$script:DNSTbSrv   = $null
$script:DNSGrid    = $null
$script:DHCPTbSrv  = $null
$script:DHCPTbFlt  = $null
$script:DHCPGrid   = $null
$script:DHCPData   = $null
$script:GPOTbOU    = $null
$script:GPOGrid    = $null
$script:GPOData    = $null
$script:LevelRtb   = $null
$script:LevelData  = $null
#endregion

#region -- RTB-Header ---------------------------------------------------------
function RTB-Header {
    param([string]$T)
    if (-not $script:LevelRtb) { return }
    $script:LevelRtb.SelectionFont  = New-Object System.Drawing.Font('Consolas', 10, [System.Drawing.FontStyle]::Bold)
    $script:LevelRtb.SelectionColor = [System.Drawing.Color]::FromArgb(0,80,160)
    $script:LevelRtb.AppendText("`n=== $T ===`n")
    $script:LevelRtb.SelectionFont  = New-Object System.Drawing.Font('Consolas', 9)
    $script:LevelRtb.SelectionColor = [System.Drawing.Color]::FromArgb(40,40,40)
}
#endregion

#region -- RTB-Line -----------------------------------------------------------
function RTB-Line {
    param([string]$L)
    if (-not $script:LevelRtb) { return }
    $script:LevelRtb.SelectionFont  = New-Object System.Drawing.Font('Consolas', 9)
    $script:LevelRtb.SelectionColor = [System.Drawing.Color]::FromArgb(40,40,40)
    $script:LevelRtb.AppendText("  $L`n")
}
#endregion

Export-ModuleMember -Function RTB-Header, RTB-Line
