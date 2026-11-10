#region -- ADInfrastructure.ForestInfo.Query.psm1 ----------------------------
# Concern : Read-ForestDomainInfo - loads forest, domain, and password policy
#           info, renders structured text to LevelRtb, and stores structured
#           data in $script:LevelData for HTML export.
# Load order: 111 - depends on ADInfrastructure.RichText.Header (RTB-Header,
#                                                                  RTB-Line,
#                                                                  script scope),
#                             Services.AD.Reporting (Write-OperationLog)
# Split from: ADInfrastructure.Query.psm1
#endregion

#region -- Read-ForestDomainInfo ----------------------------------------------
function Read-ForestDomainInfo {
    $srv = $script:InfraCtx.TargetDC
    $rtb = $script:LevelRtb
    $rtb.Clear()
    $results = [System.Collections.Generic.List[PSCustomObject]]::new()

    try {
        $forest = Get-ADForest -Server $srv -ErrorAction Stop
        RTB-Header 'FOREST'
        RTB-Line "Name                    : $($forest.Name)"
        RTB-Line "Forest Mode             : $($forest.ForestMode)"
        RTB-Line "Root Domain             : $($forest.RootDomain)"
        RTB-Line "Schema Master           : $($forest.SchemaMaster)"
        RTB-Line "Domain Naming Master    : $($forest.DomainNamingMaster)"
        RTB-Line "Domains in Forest       : $($forest.Domains -join ', ')"
        RTB-Line "Global Catalog Servers  : $($forest.GlobalCatalogs -join ', ')"
        RTB-Line "Sites                   : $($forest.Sites -join ', ')"
        $results.Add([PSCustomObject]@{ Category='Forest'; Property='Name';               Value=$forest.Name })
        $results.Add([PSCustomObject]@{ Category='Forest'; Property='ForestMode';         Value=[string]$forest.ForestMode })
        $results.Add([PSCustomObject]@{ Category='Forest'; Property='RootDomain';         Value=$forest.RootDomain })
        $results.Add([PSCustomObject]@{ Category='Forest'; Property='SchemaMaster';       Value=$forest.SchemaMaster })
        $results.Add([PSCustomObject]@{ Category='Forest'; Property='DomainNamingMaster'; Value=$forest.DomainNamingMaster })
    } catch { RTB-Line "Could not load forest info: $($_.Exception.Message)" }

    try {
        $domain = Get-ADDomain -Server $srv -ErrorAction Stop
        RTB-Header 'DOMAIN'
        RTB-Line "Name                    : $($domain.DNSRoot)"
        RTB-Line "Domain Mode             : $($domain.DomainMode)"
        RTB-Line "Distinguished Name      : $($domain.DistinguishedName)"
        RTB-Line "PDC Emulator            : $($domain.PDCEmulator)"
        RTB-Line "RID Master              : $($domain.RIDMaster)"
        RTB-Line "Infrastructure Master   : $($domain.InfrastructureMaster)"
        RTB-Line "Child Domains           : $(if ($domain.ChildDomains) { $domain.ChildDomains -join ', ' } else { 'None' })"
        $results.Add([PSCustomObject]@{ Category='Domain'; Property='Name';                Value=$domain.DNSRoot })
        $results.Add([PSCustomObject]@{ Category='Domain'; Property='DomainMode';          Value=[string]$domain.DomainMode })
        $results.Add([PSCustomObject]@{ Category='Domain'; Property='PDCEmulator';         Value=$domain.PDCEmulator })
        $results.Add([PSCustomObject]@{ Category='Domain'; Property='RIDMaster';           Value=$domain.RIDMaster })
        $results.Add([PSCustomObject]@{ Category='Domain'; Property='InfrastructureMaster';Value=$domain.InfrastructureMaster })
    } catch { RTB-Line "Could not load domain info: $($_.Exception.Message)" }

    try {
        $pwPolicy = Get-ADDefaultDomainPasswordPolicy -Server $srv -ErrorAction Stop
        RTB-Header 'DEFAULT PASSWORD POLICY'
        RTB-Line "Max Password Age        : $($pwPolicy.MaxPasswordAge)"
        RTB-Line "Min Password Age        : $($pwPolicy.MinPasswordAge)"
        RTB-Line "Min Password Length     : $($pwPolicy.MinPasswordLength)"
        RTB-Line "Password History        : $($pwPolicy.PasswordHistoryCount)"
        RTB-Line "Lockout Threshold       : $($pwPolicy.LockoutThreshold)"
        RTB-Line "Lockout Duration        : $($pwPolicy.LockoutDuration)"
        RTB-Line "Lockout Observation Win : $($pwPolicy.LockoutObservationWindow)"
        RTB-Line "Complexity Enabled      : $($pwPolicy.ComplexityEnabled)"
        RTB-Line "Reversible Encryption   : $($pwPolicy.ReversibleEncryptionEnabled)"
        $results.Add([PSCustomObject]@{ Category='PasswordPolicy'; Property='MaxPasswordAge';    Value=[string]$pwPolicy.MaxPasswordAge })
        $results.Add([PSCustomObject]@{ Category='PasswordPolicy'; Property='LockoutThreshold';  Value=[string]$pwPolicy.LockoutThreshold })
        $results.Add([PSCustomObject]@{ Category='PasswordPolicy'; Property='LockoutDuration';   Value=[string]$pwPolicy.LockoutDuration })
        $results.Add([PSCustomObject]@{ Category='PasswordPolicy'; Property='ComplexityEnabled'; Value=[string]$pwPolicy.ComplexityEnabled })
    } catch { RTB-Line "Could not load password policy: $($_.Exception.Message)" }

    $script:LevelData = $results
    Set-Status 'Forest / domain info loaded.' 'ok'
    Write-OperationLog -Context $script:InfraCtx -Action 'FOREST-INFO' -Target $srv -Result 'OK'
}
#endregion

Export-ModuleMember -Function Read-ForestDomainInfo
