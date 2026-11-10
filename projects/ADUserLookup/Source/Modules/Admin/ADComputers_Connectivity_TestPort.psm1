#region -- ADComputers.Connectivity.TestPort.psm1 ----------------------------
# Concern : Test-TCPPort - async TCP port probe with configurable timeout.
#           Shared script-scope state for all ADComputers sub-modules.
# Load order: 77 - no dependencies on other AD-Admin modules
# Split from: ADComputers.Actions.psm1
#endregion

#region -- Shared script-scope state ------------------------------------------
$script:CompCtx        = $null
$script:CompTab        = $null
$script:CompCards      = $null
$script:CompRtbDetails = $null
$script:CompScanCache  = $null
$script:CompBulkProg   = $null
$script:CompBulkGrid   = $null
$script:CompTbTarget   = $null
$script:CompTbPorts    = $null
$script:CompBulkOU     = $null
$script:BitTbComp      = $null
$script:BitGrid        = $null
$script:LapsTbComp     = $null
$script:LapsResultGrid = $null
$script:_TW            = 0
$script:_TH            = 0
#endregion

#region -- Test-TCPPort -------------------------------------------------------
function Test-TCPPort {
    param([string]$Target, [int]$Port, [int]$TimeoutMS = 1000)
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $ar     = $client.BeginConnect($Target, $Port, $null, $null)
        $ok     = $ar.AsyncWaitHandle.WaitOne($TimeoutMS, $false)
        if ($ok -and $client.Connected) { $client.Close(); return $true }
        $client.Close(); return $false
    } catch { return $false }
}
#endregion

Export-ModuleMember -Function Test-TCPPort
