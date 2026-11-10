#region -- ADUserActions.PasswordGenerator.psm1 ------------------------------
# Concern : New-GeneratedPassword - produces a memorable password from
#           the shared Config-backed word lists (Phrase + Symbol + Number),
#           owned by Services.PasswordWordLists. Used as the default password
#           for Create User, Password Reset, and Offboarding password randomize.
# Load order: 29 - depends on Services.PasswordWordLists (Get-PasswordWordLists),
#                            load order 4a.
# Split from: ADUserActions.psm1
# Changes   : Local $script:PwTitles/PwPhrases/PwSymbols/PwYears arrays removed.
#             Word data now lives in .\Config\PasswordGenerator.json, unified
#             with ADTools.PasswordGenerator.Engine (New-CustomPassword) so a
#             single edit surface (the Password Generator tab) controls both.
#endregion

#region -- New-GeneratedPassword ----------------------------------------------
function New-GeneratedPassword {
    <#
    .SYNOPSIS
        Builds a password as Phrase + Symbol + Number, each chosen at random
        from the shared, Config-backed word lists (see
        Services.PasswordWordLists.Get-PasswordWordLists).
    #>
    $lists = Get-PasswordWordLists
    $word  = $lists.Phrase | Get-Random
    $sym   = $lists.Symbol | Get-Random
    $num   = $lists.Number | Get-Random
    return "$word$sym$num"
}
#endregion

Export-ModuleMember -Function New-GeneratedPassword
