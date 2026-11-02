#region -- ADComputers.Connectivity.Scan.psm1 --------------------------------
# Concern : Invoke-ComputerCheck - single computer ping + port card update.
#           Read-ConnComputers - loads the full domain computer list into
#           $script:AllConnComputers for the Connectivity Check sub-tab's own
#           grid. Self-contained: always whole-domain, independent of the
#           Directory tab's OU tree/scope.
# Load order: 78 - depends on ADComputers.Connectivity.TestPort (script scope, Test-TCPPort),
#                            ADComputers.Connectivity.Details (Read-ComputerDetails),
#                            Services.AD.Connection.Query (Get-DomainComputers, Get-OUFromDN)
# Split from: ADComputers.Actions.psm1
# Changes   : Read-ConnComputers now takes a -Force switch and tracks
#             $script:ConnCompLoaded. Called without -Force (the tab's
#             Add_Enter path) it reuses the cached list and just re-renders
#             the grid once already loaded, instead of re-querying every
#             domain computer on every visit to the Computers tab. The
#             Refresh button (ADComputers.Connectivity.Tab) calls it with
#             -Force to get a real reload. Matches the same -Force pattern
#             already used by Read-OffboardTargetUsers.
#endregion

#region -- Shared script-scope state (Connectivity computers cache) ----------
$script:AllConnComputers = [System.Collections.Generic.List[PSCustomObject]]::new()
$script:ConnCompLoaded   = $false
#endregion

#region -- Read-ConnComputers -------------------------------------------------
function Read-ConnComputers {
    <#
    .SYNOPSIS
        Loads every domain computer (whole domain, no OU scoping) into
        $script:AllConnComputers and refreshes the Connectivity sub-tab grid.
        Uses the cached list unless -Force is passed (first load, manual
        Refresh click, or any caller that needs a guaranteed re-query) - safe
        to call on every tab Add_Enter without re-hitting AD each time.
    #>
    param([switch]$Force)

    if ($script:ConnCompLoaded -and -not $Force) {
        if (Get-Command Update-ConnCompGrid -ErrorAction SilentlyContinue) { Update-ConnCompGrid }
        return
    }

    if (Get-Command Set-Status -ErrorAction SilentlyContinue) { Set-Status 'Loading computers...' }
    $script:AllConnComputers.Clear()
    $srvParam = if ($script:CompCtx -and $script:CompCtx.TargetDC) { @{ Server = $script:CompCtx.TargetDC } } else { @{} }
    try {
        $raw = Get-DomainComputers @srvParam -IncludeDisabled
        foreach ($c in $raw) {
            [void]$script:AllConnComputers.Add([PSCustomObject]@{
                Name              = [string]$c.Name
                Enabled           = [string]$c.Enabled
                OperatingSystem   = [string]$c.OperatingSystem
                OSVersion         = [string]$c.OperatingSystemVersion
                LastLogon         = if ($c.LastLogonDate) { $c.LastLogonDate.ToString('yyyy-MM-dd') } else { 'Never' }
                IPv4Address       = [string]$c.IPv4Address
                Created           = if ($c.whenCreated) { $c.whenCreated.ToString('yyyy-MM-dd') } else { '' }
                Description       = [string]$c.Description
                OU                = if (Get-Command Get-OUFromDN -ErrorAction SilentlyContinue) { Get-OUFromDN -DN ([string]$c.DistinguishedName) } else { '' }
                DistinguishedName = [string]$c.DistinguishedName
            })
        }
        $script:ConnCompLoaded = $true
        if (Get-Command Update-ConnCompGrid -ErrorAction SilentlyContinue) { Update-ConnCompGrid }
        if (Get-Command Set-Status -ErrorAction SilentlyContinue) { Set-Status "$($script:AllConnComputers.Count) computers loaded." 'ok' }
    } catch {
        $script:ConnCompLoaded = $false
        if (Get-Command Set-Status -ErrorAction SilentlyContinue) { Set-Status "Computer load failed: $($_.Exception.Message)" 'err' }
    }
}
#endregion

#region -- Invoke-ComputerCheck -----------------------------------------------
function Invoke-ComputerCheck {
    param([string]$Target, [string]$ExtraPorts = '')
    $C_OK      = [System.Drawing.Color]::FromArgb(198,239,206)
    $C_FAIL    = [System.Drawing.Color]::FromArgb(255,199,206)
    $C_UNKN    = [System.Drawing.Color]::FromArgb(230,240,255)
    $C_OK_FG   = [System.Drawing.Color]::FromArgb(0,97,0)
    $C_FAIL_FG = [System.Drawing.Color]::FromArgb(156,0,6)
    $C_DIM     = [System.Drawing.Color]::DimGray

    foreach ($key in $script:CompCards.Keys) {
        $script:CompCards[$key].Panel.BackColor = $C_UNKN
        $script:CompCards[$key].Value.Text      = '...'
        $script:CompCards[$key].Value.ForeColor = $C_DIM
        $script:CompCards[$key].Ms.Text         = ''
    }
    Set-Status "Checking $Target ..."

    $sw   = [System.Diagnostics.Stopwatch]::StartNew()
    $ping = Test-Connection -ComputerName $Target -Count 1 -Quiet -ErrorAction SilentlyContinue
    $sw.Stop()
    $ms   = $sw.ElapsedMilliseconds
    if ($ping) {
        $script:CompCards['ping'].Panel.BackColor = $C_OK
        $script:CompCards['ping'].Value.Text      = 'UP'
        $script:CompCards['ping'].Value.ForeColor = $C_OK_FG
        $script:CompCards['ping'].Ms.Text         = "${ms}ms"
    } else {
        $script:CompCards['ping'].Panel.BackColor = $C_FAIL
        $script:CompCards['ping'].Value.Text      = 'DOWN'
        $script:CompCards['ping'].Value.ForeColor = $C_FAIL_FG
    }

    $portMap = @{ rdp=3389; smb=445; radmin=4899; winrm=5985 }
    foreach ($key in $portMap.Keys) {
        $open = Test-TCPPort -Target $Target -Port $portMap[$key] -TimeoutMS 1000
        $script:CompCards[$key].Panel.BackColor = if ($open) { $C_OK }    else { $C_FAIL }
        $script:CompCards[$key].Value.Text      = if ($open) { 'OPEN' }   else { 'CLOSED' }
        $script:CompCards[$key].Value.ForeColor = if ($open) { $C_OK_FG } else { $C_FAIL_FG }
    }

    Read-ComputerDetails -Target $Target
    Set-Status "Check complete: $Target  |  Ping: $(if ($ping) {'UP'} else {'DOWN'})" $(if ($ping) {'ok'} else {'warn'})
}
#endregion

Export-ModuleMember -Function `
    Invoke-ComputerCheck, `
    Read-ConnComputers
