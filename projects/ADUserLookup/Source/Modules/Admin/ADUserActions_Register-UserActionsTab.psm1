#region -- ADUserActions.Register-UserActionsTab.psm1 -------------------------
# Concern : Register-UserActionsTab - builds the Account Management tab by
#           calling Build-CreateUserPanel as a single column, adding the
#           Action Results log RTB below it.
# Load order: 49 - depends on all ADUserActions.* modules,
#                            Services.AD.Reporting (New-SectionPanel)
# Split from: ADUserActions.psm1
# Changes   : Offboard relocated out of this tab entirely - it now lives as
#             its own page on the Bulk Operations tab
#             (ADBulkOps.Register-BulkOpsTab), since it already operates on
#             a multiselect target list (a bulk action in every sense) and
#             every other bulk-capable action in the app already lives
#             there. Only the Build-OffboardPanel call and its now-unused
#             $COL_OFF_X/$COL_OFF_W layout variables were removed - per
#             explicit instruction, Create User's own column width/position
#             ($COL_CREATE_X/$COL_CREATE_W, still 55% of tab width) is left
#             exactly as it was, NOT resized to fill the vacated space. The
#             right ~45% of the tab is simply empty now. $script:UAContext
#             is still set here (Create User and other ADUserActions.*
#             modules read it) - Build-OffboardPanel itself now separately
#             receives the same assignment from ADBulkOps.Register-
#             BulkOpsTab, mirroring how $script:ToolsCtx is already
#             harmlessly set by both the Tools and Bulk Operations
#             registrars against the same $Context object.
#             Paste Import: the vacated right column ($COL_OFF_X /
#             $COL_OFF_W) now hosts Build-CreateUserPastePanel
#             (ADUserActions.CreateUser.PasteQueue), guarded with
#             Get-Command. Create User's own width/position unchanged.
#             Reset on tab leave: the main TabControl's Deselected event
#             (wired once here - Register-UserActionsTab runs once per
#             session) calls Clear-PasteQueue and Reset-CreateUserPanelState
#             whenever THIS tab is the one being left. The page's own Leave
#             event is not used because it also fires when focus moves to
#             the tab strip while staying on this page. The Create User form
#             itself is cleared only when a Paste Import record was loaded.
#endregion

#region -- Register-UserActionsTab --------------------------------------------
function Register-UserActionsTab {
    param(
        [System.Windows.Forms.TabPage]$Tab,
        [PSCustomObject]$Context
    )
    $script:UAContext = $Context
    $script:UATab     = $Tab

    $PAD    = 8
    $F_MONO = New-Object System.Drawing.Font('Consolas', 9)

    $TW = $Context.TabW
    $TH = $Context.TabH

    $COL_CREATE_W = [int](($TW - ($PAD * 3)) * 0.55)
    $COL_OFF_W    = $TW - $COL_CREATE_W - ($PAD * 3)
    $COL_CREATE_X = $PAD
    $COL_OFF_X    = $PAD + $COL_CREATE_W + $PAD

    $LOG_H = 120
    $LOG_Y = $TH - $LOG_H - $PAD
    $COL_H = $LOG_Y - $PAD

    # Build Create User panel (left column) - width/position deliberately
    # unchanged from the two-column layout; Offboard moved out (see module
    # header).
    if (Get-Command Build-CreateUserPanel -ErrorAction SilentlyContinue) {
        Build-CreateUserPanel -Parent $Tab -X $COL_CREATE_X -Y $PAD -W $COL_CREATE_W -H $COL_H | Out-Null
    }

    # Paste Import panel (right column) - fills the ~45% vacated by
    # Offboard. Same top/height as Create User. Guarded: the tab still
    # builds if ADUserActions.CreateUser.PasteQueue is not loaded.
    if (Get-Command Build-CreateUserPastePanel -ErrorAction SilentlyContinue) {
        Build-CreateUserPastePanel -Parent $Tab -X $COL_OFF_X -Y $PAD -W $COL_OFF_W -H $COL_H | Out-Null
    }

    # Reset transient Account Management state when the operator switches
    # to another main tab (see module header).
    $mainTabCtl = $Tab.Parent
    if ($mainTabCtl -is [System.Windows.Forms.TabControl]) {
        $mainTabCtl.Add_Deselected({
            param($sender, $e)
            if (-not $script:UATab -or $e.TabPage -ne $script:UATab) { return }
            $hadPasteRecord = $false
            if (Get-Command Clear-PasteQueue -ErrorAction SilentlyContinue) {
                $hadPasteRecord = [bool](Clear-PasteQueue)
            }
            if (Get-Command Reset-CreateUserPanelState -ErrorAction SilentlyContinue) {
                Reset-CreateUserPanelState -ClearForm:$hadPasteRecord
            }
        })
    }

    # Action Results log - spans full tab width below the Create User column
    $logSection = New-SectionPanel -Parent $Tab -Title 'Action Results' `
        -X $PAD -Y $LOG_Y -W ($TW - ($PAD * 2)) -H $LOG_H

    $script:UARtb               = New-Object System.Windows.Forms.RichTextBox
    $script:UARtb.Dock          = 'Fill'
    $script:UARtb.Font          = $F_MONO
    $script:UARtb.ReadOnly      = $true
    $script:UARtb.BackColor     = [System.Drawing.Color]::FromArgb(245,248,252)
    $script:UARtb.BorderStyle   = 'None'
    $logSection.Controls.Add($script:UARtb)
}
#endregion

Export-ModuleMember -Function Register-UserActionsTab
