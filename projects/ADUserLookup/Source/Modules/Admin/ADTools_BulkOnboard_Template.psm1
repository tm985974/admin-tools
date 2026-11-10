#region -- ADTools.BulkOnboard.Template.psm1 ----------------------------------
# Concern : Save-BulkTemplate - opens a SaveFileDialog and writes a starter
#           CSV template with correct column headers and one sample row.
# Load order: 116 - depends on ADTools.BulkOnboard.Log (Write-BulkLog),
#                            ADTools.PasswordGenerator.Engine (script scope),
#                            Services.DomainDefaults.Config (Get-DomainDefaults)
#                              [4d] - soft dependency, guarded
# Split from: ADTools.Actions.psm1
# Changes   : The sample row's OU and UPN suffix now come from the currently
#             connected domain's saved defaults (Default Bulk Onboard OU,
#             UPN Suffix - Tools > Domain Defaults) when configured, instead
#             of always showing the generic "domain.com" placeholder -
#             gives a usable, copy-paste-ready example for THIS domain
#             rather than one that needs hand-editing before it means
#             anything. Falls back to the original generic placeholders
#             when nothing is configured (no domain connected, Services.
#             DomainDefaults.Config not loaded, or this domain has no saved
#             defaults yet) - never throws, same soft-dependency contract
#             as every other consumer of Get-DomainDefaults in this app.
#             UPN Suffix is normalized to always start with '@' in the
#             sample regardless of whether the admin saved it with or
#             without the leading '@' on the Domain Defaults tab.
#             Column set replaced (breaking change from any previously
#             downloaded template - nothing else in this app persists an
#             old-format CSV, so this is a one-time, low-risk rename):
#               OLD: FirstName,LastName,SamAccountName,OU,UPN,Description,
#                    Department,Title,TemplateUser
#               NEW: FirstName,LastName,DisplayCustomText,LogonCustomText,
#                    UpnSuffix,TargetOU,Phone,Email,CopyGroupsFrom,Password
#             Description/Department/Title/Company/Office/Manager are
#             deliberately NOT included - this environment never populates
#             them on user creation, so they'd be dead columns every time.
#             SamAccountName/OU/UPN/TemplateUser are renamed to
#             LogonName-equivalent/TargetOU/UpnSuffix/CopyGroupsFrom to match
#             the Domain Defaults / Create User field names. DisplayCustomText
#             and LogonCustomText are new - see ADTools.BulkOnboard.Engine's
#             header for how they combine with this domain's Bulk Addition
#             naming convention (Services.DomainDefaults.Config's
#             BulkDisplayNamePattern/BulkAccountNamePattern, edited on Tools >
#             Domain Defaults) to build each row's actual Display Name/Logon
#             Name at preview time - NOT done here, this function only writes
#             the column headers and one illustrative sample row. Password is
#             new - blank means Invoke-BulkOnboard randomizes it (unchanged
#             default behavior), a supplied value is used as-is for that row.
#             DisplayPrefix/DisplaySuffix/LogonPrefix/LogonSuffix are
#             deliberately NOT columns here - they are domain-wide (Tools >
#             Domain Defaults > New User Defaults, already used by the
#             single-Create-User patterns too), applied automatically to
#             every row rather than repeated per row.
#endregion

#region -- Save-BulkTemplate --------------------------------------------------
function Save-BulkTemplate {
    # Resolve the connected domain's saved Default Bulk Onboard OU / UPN
    # Suffix (Tools > Domain Defaults) so the sample row shows real,
    # usable values for THIS domain when available - see module header.
    # Never throws; falls back to the original generic placeholders.
    $sampleOU  = 'OU=Users,DC=domain,DC=com'
    $sampleUPN = '@domain.com'
    if ($script:ToolsCtx -and $script:ToolsCtx.Domain -and (Get-Command Get-DomainDefaults -ErrorAction SilentlyContinue)) {
        try {
            $dd = Get-DomainDefaults -Domain $script:ToolsCtx.Domain
            if ($dd -and [string]$dd.DefaultBulkOnboardOU) {
                $sampleOU = [string]$dd.DefaultBulkOnboardOU
            }
            if ($dd -and [string]$dd.UpnSuffix) {
                $suffix    = [string]$dd.UpnSuffix
                $sampleUPN = if ($suffix.StartsWith('@')) { $suffix } else { "@$suffix" }
            }
        } catch { }
    }

    try {
        $sfd          = New-Object System.Windows.Forms.SaveFileDialog
        $sfd.Filter   = 'CSV Files (*.csv)|*.csv'
        $sfd.FileName = 'BulkUserTemplate.csv'
        if ($sfd.ShowDialog() -eq 'OK') {
            $header = 'FirstName,LastName,DisplayCustomText,LogonCustomText,UpnSuffix,TargetOU,Phone,Email,CopyGroupsFrom,Password'
            $sample = "John,Doe,`"Doe, John`",JDOE,$sampleUPN,`"$sampleOU`",,,,"
            [System.IO.File]::WriteAllLines($sfd.FileName, @($header,$sample), [System.Text.Encoding]::UTF8)
            Write-BulkLog "Template saved: $($sfd.FileName)" 'ok'
        }
    } catch {
        Write-BulkLog "Save failed: $($_.Exception.Message)" 'err'
    }
}
#endregion

Export-ModuleMember -Function Save-BulkTemplate
