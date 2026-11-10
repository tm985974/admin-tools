#region -- ADComputers.Connectivity.Details.psm1 -----------------------------
# Concern : Read-ComputerDetails - retrieves AD computer properties and
#           populates the details RichTextBox on the Connectivity tab.
# Load order: 79 - depends on ADComputers.Connectivity.TestPort (script scope)
# Split from: ADComputers.Actions.psm1
#endregion

#region -- Read-ComputerDetails -----------------------------------------------
function Read-ComputerDetails {
    param([string]$Target)
    if (-not $script:CompRtbDetails) { return }
    $rtb = $script:CompRtbDetails
    $rtb.Clear()
    try {
        $comp = Get-ADComputer -Identity $Target `
                    -Properties Name,DNSHostName,IPv4Address,OperatingSystem,OperatingSystemVersion,`
                                 LastLogonDate,whenCreated,Description,DistinguishedName,Enabled `
                    -Server $script:CompCtx.TargetDC -ErrorAction Stop
        $lines = @(
            "Name            : $($comp.Name)"
            "DNS Hostname    : $($comp.DNSHostName)"
            "IP Address      : $($comp.IPv4Address)"
            "OS              : $($comp.OperatingSystem)  $($comp.OperatingSystemVersion)"
            "Last Logon      : $(if ($comp.LastLogonDate) { $comp.LastLogonDate.ToString('yyyy-MM-dd HH:mm') } else { 'Never' })"
            "Created         : $(if ($comp.whenCreated) { $comp.whenCreated.ToString('yyyy-MM-dd') } else { '' })"
            "Enabled         : $($comp.Enabled)"
            "Description     : $($comp.Description)"
            "DN              : $($comp.DistinguishedName)"
        )
        $rtb.Text = $lines -join "`n"
    } catch {
        $rtb.Text = "Could not load AD details for $Target : $($_.Exception.Message)"
    }
}
#endregion

Export-ModuleMember -Function Read-ComputerDetails
