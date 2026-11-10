#region -- ADTools.PasswordGenerator.Engine.psm1 -----------------------------
# Concern : New-CustomPassword - generates a password. Delegates to
#           New-GeneratedPassword (ADUserActions.PasswordGenerator), which
#           draws from the shared Config-backed word lists owned by
#           Services.PasswordWordLists. Kept as a distinct function (rather
#           than removed) because ADTools.BulkOnboard.Engine calls it by name.
#           Owns shared script-scope state for all ADTools sub-modules.
# Load order: 114 - depends on ADUserActions.PasswordGenerator
#                                                    (New-GeneratedPassword)
# Split from: ADTools.Actions.psm1
# Changes   : Removed $script:PwCmbPool / PwTbSymbols / PwNudFrom / PwNudTo /
#             PwListBox (old Options panel + batch-list controls, no longer
#             built by Build-PwGenTab). Added $script:PwTbPhrase / PwTbSymbol
#             / PwTbNumber for the new 3-textbox editable list UI. The old
#             fallback logic (New-CustomPassword checking Get-Command
#             New-GeneratedPassword before using tab-configured options) is
#             removed - both functions now always read the same unified list
#             source, so there is nothing left to fall back from.
#endregion

#region -- Shared script-scope state ------------------------------------------
$script:ToolsCtx      = $null
$script:ToolsTab      = $null
$script:ToolsPages    = @{}
$script:_TW           = 0
$script:_TH           = 0

$script:PwDisplayLbl  = $null
$script:PwTbPhrase    = $null
$script:PwTbSymbol    = $null
$script:PwTbNumber    = $null
$script:BulkTbFile    = $null
$script:BulkTbOU      = $null
$script:BulkPreviewGrid = $null
$script:BulkRtb       = $null
$script:LogNud        = $null
$script:LogTbFilter   = $null
$script:LogGrid       = $null
$script:LogAllEntries = $null
$script:EnvGrid       = $null
$script:EnvRtb        = $null
$script:EnvData       = $null
#endregion

#region -- New-CustomPassword -------------------------------------------------
function New-CustomPassword {
    return New-GeneratedPassword
}
#endregion

Export-ModuleMember -Function New-CustomPassword
