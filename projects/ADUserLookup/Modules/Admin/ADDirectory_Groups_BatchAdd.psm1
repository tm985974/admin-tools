#region -- ADDirectory.Groups.BatchAdd.psm1 -----------------------------------
# Concern : Build-BatchAddGroupsPage - builds the "Bulk Add Groups" page of
#           the Bulk Operations tab: paste a list of group names, pick a
#           single target OU and a Scope/Category applied to every group in
#           the batch, create them all, one per-name OK/FAIL result.
# Load order: 24a - depends on ADDirectory.Groups.Load (Add-CachedGroup),
#                            ADUserActions.OUPicker.Dialog (Show-OUPicker),
#                            Services.AD.Reporting (Confirm-Action, New-StdButton),
#                            Services.Logging (Write-OperationLog)
# Split from: (new module)
# Notes     : Every closure below captures the cross-module functions it
#             needs (Confirm-Action, Write-OperationLog, Show-OUPicker,
#             Add-CachedGroup) as ${function:Name} BEFORE the closure is
#             built, and invokes them via & inside it - a bare-name call to a
#             dot-sourced project function from inside a .GetNewClosure()
#             block is unreliable in this codebase (see
#             ADDirectory.Register-DirectoryTab for the fuller explanation).
#             Native AD cmdlets (New-ADGroup, Get-ADGroup) are unaffected and
#             are called directly.
# Changes   : RELOCATED from a standalone popup dialog (Show-
#             BatchAddGroupsDialog, launched from a "Batch Add..." button on
#             the Groups tab) to an embedded page on the new Bulk Operations
#             tab (ADBulkOps.Register-BulkOpsTab), as part of consolidating
#             every bulk action (add/delete users, groups, computers) into
#             one place with a consistent look. The Groups tab's "Batch
#             Add..." button is gone - this is the only entry point now.
#             Behavior is otherwise unchanged: same fields, same New-ADGroup
#             call, same cache-patch via Add-CachedGroup. The dialog chrome
#             (title panel, own Form, Close button) is gone - this now
#             builds directly into a TabPage using $script:_TW / $script:_TH,
#             the same sizing convention every other Bulk Operations /
#             Tools / Infrastructure sub-page already uses.
#             Tab-leave reset: registers a reset scriptblock on this page's
#             TabPage Tag['Resets'] that clears the group-name box, the
#             Results log and the status label. Target OU, Scope and
#             Category are kept. Run by ADBulkOps.Register-BulkOpsTab
#             whenever this page is left (sub-tab switch or leaving the
#             Bulk Operations tab).
#endregion

#region -- Build-BatchAddGroupsPage --------------------------------------------
function Build-BatchAddGroupsPage {
    <#
    .SYNOPSIS
        Builds the Bulk Add Groups page: paste group names (one per line),
        pick a target OU + Scope + Category, create them all, and show a
        per-name OK/FAIL results log.
    .PARAMETER Tab
        The TabPage to build into (a page of the Bulk Operations sub-tab).
    .PARAMETER Context
        Shared context object (TargetDC, AdminAccount, Domain).
    #>
    param(
        [System.Windows.Forms.TabPage]$Tab,
        [PSCustomObject]$Context
    )

    $F_UI   = New-Object System.Drawing.Font('Segoe UI', 9)
    $F_UI_B = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $F_MONO = New-Object System.Drawing.Font('Consolas', 9)
    $PAD    = 8
    $TW     = $script:_TW
    $TH     = $script:_TH
    $CW     = $TW - ($PAD * 2)

    # Capture before any closure is built - see module header.
    $capturedContext  = $Context
    $confirmActionFn  = ${function:Confirm-Action}
    $writeOpLogFn     = ${function:Write-OperationLog}
    $showOUPickerFn   = ${function:Show-OUPicker}
    $addCachedGroupFn = ${function:Add-CachedGroup}

    $lNames           = New-Object System.Windows.Forms.Label
    $lNames.Text      = 'Group names (one per line):'
    $lNames.Location  = New-Object System.Drawing.Point($PAD, $PAD)
    $lNames.Size      = New-Object System.Drawing.Size(300, 20)
    $lNames.Font      = $F_UI
    $Tab.Controls.Add($lNames)

    $tbNames               = New-Object System.Windows.Forms.TextBox
    $tbNames.Location      = New-Object System.Drawing.Point($PAD, ($PAD + 22))
    $tbNames.Size          = New-Object System.Drawing.Size($CW, 170)
    $tbNames.Font          = $F_MONO
    $tbNames.Multiline     = $true
    $tbNames.ScrollBars    = 'Vertical'
    $tbNames.AcceptsReturn = $true
    $Tab.Controls.Add($tbNames)

    $ROW_Y = $PAD + 22 + 170 + 12

    $lOU              = New-Object System.Windows.Forms.Label
    $lOU.Text         = 'Target OU:'
    $lOU.Location     = New-Object System.Drawing.Point($PAD, ($ROW_Y + 2))
    $lOU.Size         = New-Object System.Drawing.Size(90, 24)
    $lOU.Font         = $F_UI
    $Tab.Controls.Add($lOU)

    $OU_BOX_W = $CW - 90 - 8 - 76 - 8
    $tbOU               = New-Object System.Windows.Forms.TextBox
    $tbOU.Location      = New-Object System.Drawing.Point(($PAD + 90), $ROW_Y)
    $tbOU.Size          = New-Object System.Drawing.Size($OU_BOX_W, 24)
    $tbOU.Font          = $F_UI
    $tbOU.ReadOnly      = $true
    $tbOU.BackColor     = [System.Drawing.Color]::FromArgb(245,245,245)
    $Tab.Controls.Add($tbOU)

    $btnBrowseOU = New-StdButton -Text 'Browse...' -X ($PAD + 90 + $OU_BOX_W + 8) -Y $ROW_Y -W 76 -H 24 -Parent $Tab

    $ROW_Y2 = $ROW_Y + 34

    $lScope           = New-Object System.Windows.Forms.Label
    $lScope.Text      = 'Group Scope:'
    $lScope.Location  = New-Object System.Drawing.Point($PAD, ($ROW_Y2 + 2))
    $lScope.Size      = New-Object System.Drawing.Size(90, 24)
    $lScope.Font      = $F_UI
    $Tab.Controls.Add($lScope)

    $cmbScope               = New-Object System.Windows.Forms.ComboBox
    $cmbScope.Location      = New-Object System.Drawing.Point(($PAD + 90), $ROW_Y2)
    $cmbScope.Size          = New-Object System.Drawing.Size(160, 24)
    $cmbScope.Font          = $F_UI
    $cmbScope.DropDownStyle = 'DropDownList'
    @('Global','Universal','DomainLocal') | ForEach-Object { [void]$cmbScope.Items.Add($_) }
    $cmbScope.SelectedIndex = 0
    $Tab.Controls.Add($cmbScope)

    $lCategory           = New-Object System.Windows.Forms.Label
    $lCategory.Text      = 'Category:'
    $lCategory.Location  = New-Object System.Drawing.Point(($PAD + 264), ($ROW_Y2 + 2))
    $lCategory.Size      = New-Object System.Drawing.Size(70, 24)
    $lCategory.Font      = $F_UI
    $Tab.Controls.Add($lCategory)

    $cmbCategory               = New-Object System.Windows.Forms.ComboBox
    $cmbCategory.Location      = New-Object System.Drawing.Point(($PAD + 338), $ROW_Y2)
    $cmbCategory.Size          = New-Object System.Drawing.Size(160, 24)
    $cmbCategory.Font          = $F_UI
    $cmbCategory.DropDownStyle = 'DropDownList'
    @('Security','Distribution') | ForEach-Object { [void]$cmbCategory.Items.Add($_) }
    $cmbCategory.SelectedIndex = 0
    $Tab.Controls.Add($cmbCategory)

    $ROW_Y3 = $ROW_Y2 + 34

    $lResults           = New-Object System.Windows.Forms.Label
    $lResults.Text      = 'Results:'
    $lResults.Location  = New-Object System.Drawing.Point($PAD, $ROW_Y3)
    $lResults.Size      = New-Object System.Drawing.Size(300, 18)
    $lResults.Font      = $F_UI_B
    $Tab.Controls.Add($lResults)

    $RESULTS_Y = $ROW_Y3 + 20
    $RESULTS_H = $TH - $RESULTS_Y - $PAD - 44

    $tbResults              = New-Object System.Windows.Forms.RichTextBox
    $tbResults.Location     = New-Object System.Drawing.Point($PAD, $RESULTS_Y)
    $tbResults.Size         = New-Object System.Drawing.Size($CW, $RESULTS_H)
    $tbResults.Font         = $F_MONO
    $tbResults.ReadOnly     = $true
    $tbResults.BackColor    = [System.Drawing.Color]::White
    $tbResults.BorderStyle  = 'FixedSingle'
    $Tab.Controls.Add($tbResults)

    $BTN_Y = $RESULTS_Y + $RESULTS_H + 8

    $lStatus            = New-Object System.Windows.Forms.Label
    $lStatus.Location   = New-Object System.Drawing.Point($PAD, ($BTN_Y + 6))
    $lStatus.Size       = New-Object System.Drawing.Size(($CW - 160), 24)
    $lStatus.Font       = $F_UI
    $lStatus.ForeColor  = [System.Drawing.Color]::DimGray
    $Tab.Controls.Add($lStatus)

    # Wider right-edge margin than the usual $PAD (8px) - see
    # ADBulkOps.AddUsersToGroups.Tab's identical fix for the same
    # flush-against-the-estimated-edge pattern (confirmed clipped there in
    # testing; this button uses the identical formula and carries the same
    # risk even though it wasn't separately observed).
    $btnCreate           = New-StdButton -Text 'Create Groups' -X ($CW - 150 - 32) -Y $BTN_Y -W 150 -H 30 -Parent $Tab
    $btnCreate.Font      = $F_UI_B

    $btnBrowseOU.Add_Click({
        if ($showOUPickerFn) {
            $picked = & $showOUPickerFn -Context $capturedContext
            if ($picked) { $tbOU.Text = $picked }
        }
    }.GetNewClosure())

    $btnCreate.Add_Click({
        $ouDN = $tbOU.Text.Trim()
        if (-not $ouDN) {
            $lStatus.ForeColor = [System.Drawing.Color]::FromArgb(156,0,6)
            $lStatus.Text      = 'Select a target OU first.'
            return
        }
        $names = @(
            $tbNames.Text -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique
        )
        if ($names.Count -eq 0) {
            $lStatus.ForeColor = [System.Drawing.Color]::FromArgb(156,0,6)
            $lStatus.Text      = 'Paste at least one group name.'
            return
        }

        $scope    = [string]$cmbScope.SelectedItem
        $category = [string]$cmbCategory.SelectedItem
        $msg = "Create $($names.Count) group(s) in:`n$ouDN`n`nScope: $scope   Category: $category"
        $confirmed = if ($confirmActionFn) { & $confirmActionFn -Title 'Bulk Add Groups' -Message $msg -ActionLabel 'Create' } else { $true }
        if (-not $confirmed) { return }

        $srvParam = if ($capturedContext -and $capturedContext.TargetDC) { @{ Server = $capturedContext.TargetDC } } else { @{} }
        $ok = 0; $fail = 0
        $tbResults.Clear()
        foreach ($name in $names) {
            try {
                New-ADGroup -Name $name -GroupScope $scope -GroupCategory $category -Path $ouDN @srvParam -ErrorAction Stop
                if ($writeOpLogFn) { & $writeOpLogFn -Context $capturedContext -Action 'CREATE-GROUP' -Target $name -Result 'OK' -Detail "OU=$ouDN Scope=$scope Category=$category" }
                $tbResults.SelectionColor = [System.Drawing.Color]::FromArgb(0,97,0)
                $tbResults.AppendText("OK    $name`r`n")
                $ok++
                if ($addCachedGroupFn) {
                    & $addCachedGroupFn -Group ([PSCustomObject]@{
                        Name              = $name
                        GroupType         = $category
                        Scope             = $scope
                        Description       = ''
                        ManagedBy         = ''
                        Created           = (Get-Date -Format 'yyyy-MM-dd')
                        OU                = ''
                        DistinguishedName = "CN=$name,$ouDN"
                    })
                }
            } catch {
                if ($writeOpLogFn) { & $writeOpLogFn -Context $capturedContext -Action 'CREATE-GROUP' -Target $name -Result 'FAIL' -Detail $_.Exception.Message }
                $tbResults.SelectionColor = [System.Drawing.Color]::FromArgb(156,0,6)
                $tbResults.AppendText("FAIL  $name : $($_.Exception.Message)`r`n")
                $fail++
            }
        }
        $lStatus.ForeColor = if ($fail -gt 0) { [System.Drawing.Color]::FromArgb(156,0,6) } else { [System.Drawing.Color]::FromArgb(0,97,0) }
        $lStatus.Text      = "Done. Created: $ok  Failed: $fail"
    }.GetNewClosure())

    # Tab-leave reset (see module header) - captured control locals only.
    if (-not ($Tab.Tag -is [hashtable])) { $Tab.Tag = @{} }
    if (-not $Tab.Tag.ContainsKey('Resets')) {
        $Tab.Tag['Resets'] = New-Object System.Collections.Generic.List[scriptblock]
    }
    $Tab.Tag['Resets'].Add({
        $tbNames.Text      = ''
        $tbResults.Clear()
        $lStatus.Text      = ''
        $lStatus.ForeColor = [System.Drawing.Color]::DimGray
    }.GetNewClosure())
}
#endregion

Export-ModuleMember -Function Build-BatchAddGroupsPage
