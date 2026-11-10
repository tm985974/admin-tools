#region -- ADUserActions.Banner.psm1 ------------------------------------------
# Concern : Shared script-scope state for all ADUserActions sub-modules.
#           UA-Log - appends timestamped coloured entries to the action log RTB
#           and (v1.2.0) records the same message in Logs\Session.log via
#           Write-SessionLog (Services.Logging), source tag "UserActions".
# Load order: 27 - depends on Services.AD.Reporting (no direct call, but
#                  logging pattern mirrors Write-OperationLog)
# Split from: ADUserActions.psm1
# Changes   : Added $script:UANewLogonPrefix - was already read/written by
#             ADUserActions.CreateUser.Tab and ADUserActions.CreateUser.Account
#             but never declared here; declaring it alongside its siblings
#             for consistency (this module is the documented single place
#             all UA* script-scope state is declared/tracked).
#             Added $script:UANewDisplayPrefix - field reference for the new
#             Display Prefix textbox on the Create New User panel (paired
#             with the existing $script:UANewDnSuffix, now understood as
#             "Display Suffix").
#             Added $script:UAChkDisplayAuto / $script:UAChkAccountAuto -
#             CheckBox references for the "Use naming convention" toggles on
#             the Display Name and Account/Logon Name fields respectively.
#             Replaces $script:UALogonManual (removed) - the old one-way
#             KeyDown-latch lock on the Logon Name field is retired in favor
#             of an explicit, reversible checkbox for both fields.
#             Added $script:UAPaste* - batch state and control references for
#             the Paste Import panel (ADUserActions.CreateUser.PasteQueue).
#             UAPasteAccountBase and UAPasteLoadedActive are also read/reset
#             by ADUserActions.CreateUser.Tab (account-name builder, shared
#             clear).
#endregion

#region -- Shared script-scope state ------------------------------------------
$script:UAContext     = $null
$script:UATab         = $null
$script:UARtb         = $null          # RichTextBox: Action Results log

# Create User field references (set by Register-UserActionsTab)
$script:UANewFirst          = $null
$script:UANewLast           = $null
$script:UANewDisplayPrefix  = $null
$script:UANewDnSuffix       = $null
$script:UANewDisplay        = $null
$script:UAChkDisplayAuto    = $null
$script:UANewLogonPrefix    = $null
$script:UANewLogonSuffix    = $null
$script:UANewLogon          = $null
$script:UAChkAccountAuto    = $null
$script:UALogonHint         = $null
$script:UANewUPN            = $null
$script:UANewPhone       = $null
$script:UAPhoneTel       = $null
$script:UAPhoneHome      = $null
$script:UAPhonePager     = $null
$script:UAPhoneMobile    = $null
$script:UANewNotes       = $null
$script:UANewTitle       = $null
$script:UANewDept        = $null
$script:UANewCompany     = $null
$script:UANewOffice      = $null
$script:UANewManager     = $null
$script:UANewDesc        = $null
$script:UANewOUBox            = $null
$script:UANewCopyGroupsFrom   = $null   # ComboBox: user whose groups to duplicate (optional)
$script:UACrPwBox             = $null
$script:UACrStatus            = $null
$script:UAPhoneUpdating       = $false
$script:UAAccountCase         = 'AsTyped' # Account Name Case rule in force (Domain Defaults)
$script:UASetAccountCase      = $null     # ScriptBlock: applies a case rule to the Logon Name field

# Paste Import state / control references (set by Build-CreateUserPastePanel)
$script:UAPasteQueue        = $null    # List[object]: parsed records (ConvertFrom-PastedUserText)
$script:UAPasteIndex        = -1       # Queue index of the loaded record (-1 = none)
$script:UAPasteAccountBase  = ''       # Business-domain account name used as logon base
$script:UAPasteLoadedActive = $false   # True from record load until the shared clear runs
$script:UAPasteText         = $null    # TextBox: paste area
$script:UAPasteList         = $null    # ListView: queue
$script:UAPasteSummary      = $null    # Label: queue counts
$script:UAPasteStatus       = $null    # Label: status line
$script:UAPasteChkCarry     = $null    # CheckBox: keep Job Details / Other between users

# Offboard field references
$script:UAOffOUBox       = $null
$script:UAOffNote        = $null
$script:UAOffUserLbl     = $null
#endregion

#region -- UA-Log -------------------------------------------------------------
function UA-Log {
    param([string]$Message, [string]$Level = 'info')
    # Persist first, so the message is kept even before the panel exists.
    if ($script:SessionLogReady) {
        try { Write-SessionLog -Text $Message -Level $Level -Source 'UserActions' } catch { }
    }
    if (-not $script:UARtb) { return }
    $ts    = Get-Date -Format 'HH:mm:ss'
    $color = switch ($Level) {
        'ok'    { [System.Drawing.Color]::FromArgb(0,120,0)   }
        'warn'  { [System.Drawing.Color]::FromArgb(160,100,0) }
        'err'   { [System.Drawing.Color]::FromArgb(180,0,0)   }
        default { [System.Drawing.Color]::FromArgb(50,50,50)  }
    }
    $script:UARtb.SelectionStart  = $script:UARtb.TextLength
    $script:UARtb.SelectionLength = 0
    $script:UARtb.SelectionColor  = [System.Drawing.Color]::DimGray
    $script:UARtb.AppendText("[$ts]  ")
    $script:UARtb.SelectionColor  = $color
    $script:UARtb.AppendText("$Message`n")
    $script:UARtb.ScrollToCaret()
}
#endregion

Export-ModuleMember -Function UA-Log
