#region -- ADUserActions.CreateUser.PasteQueue.psm1 --------------------------
# Concern : Paste Import panel (right column of the Account Management tab).
#           Hosts the paste textbox, the parsed user queue, and the logic that
#           loads one queued record at a time into the Create New User panel
#           and advances to the next record after each successful create.
# Load order: 39a - depends on ADUserActions.Banner (script scope, UA-Log),
#                             ADUserActions.CreateUser.PasteParse
#                               (ConvertFrom-PastedUserText),
#                             ADUserActions.CreateUser.Tab (field references,
#                               $script:UABuildAccountName,
#                               $script:UABuildDisplay,
#                               $script:UAClearCreateFields),
#                             Services.AD.Reporting (New-StdButton).
#
# Workflow:
#   1. Operator pastes business-domain user blocks and clicks Parse.
#   2. The first Pending record loads into First Name, Last Name, Phone and
#      Email (plus Job Title / Department / Company / Office when the paste
#      contains them). Display Name and Logon Name build from the domain
#      naming convention as usual.
#   3. Operator edits anything else (Job Details, Other, Password, Target
#      OU, Copy Groups From, Notification) and clicks Create User.
#   4. On success, ADUserActions.CreateUser.Tab calls
#      Invoke-PasteQueueAdvance, which marks the record Created, optionally
#      restores Job Details / Other (carry-over checkbox), and loads the
#      next Pending record. On validation failure nothing advances.
#
# Account name (business domain) -> Logon Name:
#   Set-CreateUserFromPasteRecord stores the pasted account name in
#   $script:UAPasteAccountBase BEFORE writing First/Last. The account-name
#   builder in ADUserActions.CreateUser.Tab uses it in place of
#   LastSlug + FirstInitial when non-blank, then applies the domain's
#   Logon Prefix/Suffix pattern (jsmith -> JSMITH_IPCS). A blank pasted
#   account name falls back to the normal convention.
#
# Batch tracking:
#   $script:UAPasteIndex        - queue index of the record currently loaded
#                                 (-1 = none).
#   $script:UAPasteLoadedActive - $true from load until the Create User
#                                 panel's shared clear runs. Lets the
#                                 success path tell "the loaded record was
#                                 just created" apart from "operator cleared
#                                 the form and created an unrelated user",
#                                 so the queue never marks the wrong record.
#   Get-PasteCarryOverValues must therefore be called BEFORE the shared
#   clear runs; Invoke-PasteQueueAdvance AFTER it.
#
# Carry-over ($script:UAPasteChkCarry, default unchecked):
#   When checked during an active batch, Job Title, Department, Company,
#   Office, Manager, Description and the Copy Groups From selection survive
#   the post-create clear. Values present in the next pasted record still
#   override the carried ones. Target OU already survives the clear
#   natively; Password always regenerates.
#
# Record status values: Pending, Loaded, Created, Skipped, Invalid.
#   Created and Invalid records cannot be loaded. Skipped records can be
#   reloaded manually (Load Selected / double-click).
#
# Windows Forms: fixed explicit positioning, no Dock/Anchor, Segoe UI,
#   border/header styling matches Build-CreateUserPanel.
#
# Reset on tab leave (Clear-PasteQueue):
#   ADUserActions.Register-UserActionsTab calls Clear-PasteQueue whenever the
#   operator switches away from the Account Management tab, so a stale queue
#   (e.g. a record still marked Created after that account was deleted on
#   the Users tab) never survives a tab switch. Clear-PasteQueue empties the
#   paste box, queue, summary and status line without prompting, and
#   returns $true when a queue record was loaded in the Create User form at
#   the time - the caller then clears that form too. The Clear Queue button
#   keeps its confirmation prompt and then calls the same function, so it
#   now also empties the paste box.
#endregion

#region -- Write-PasteStatus --------------------------------------------------
function Write-PasteStatus {
    <#
    .SYNOPSIS
        Sets the Paste Import panel's status line text and colour.
    #>
    param(
        [string]$Text,
        [ValidateSet('info','ok','warn','err')][string]$Level = 'info'
    )
    if (-not $script:UAPasteStatus) { return }
    $script:UAPasteStatus.Text = $Text
    $script:UAPasteStatus.ForeColor = switch ($Level) {
        'ok'    { [System.Drawing.Color]::FromArgb(0, 120, 0) }
        'warn'  { [System.Drawing.Color]::FromArgb(160, 100, 0) }
        'err'   { [System.Drawing.Color]::FromArgb(180, 0, 0) }
        default { [System.Drawing.Color]::DimGray }
    }
}
#endregion

#region -- Update-PasteQueueView ----------------------------------------------
function Update-PasteQueueView {
    <#
    .SYNOPSIS
        Redraws the queue ListView and the summary label from
        $script:UAPasteQueue. Highlights and scrolls to the loaded record.
    #>
    if (-not $script:UAPasteList) { return }

    $lv = $script:UAPasteList
    $lv.BeginUpdate()
    $lv.Items.Clear()

    $nPending = 0; $nCreated = 0; $nSkipped = 0; $nInvalid = 0
    $total = 0
    if ($script:UAPasteQueue) { $total = $script:UAPasteQueue.Count }

    for ($i = 0; $i -lt $total; $i++) {
        $r    = $script:UAPasteQueue[$i]
        $item = New-Object System.Windows.Forms.ListViewItem([string]($i + 1))
        [void]$item.SubItems.Add([string]$r.FirstName)
        [void]$item.SubItems.Add([string]$r.LastName)
        [void]$item.SubItems.Add([string]$r.AccountName)
        [void]$item.SubItems.Add([string]$r.Status)
        $item.Tag         = $i
        $item.ToolTipText = [string]$r.Issue

        switch ($r.Status) {
            'Loaded'  {
                $item.ForeColor = [System.Drawing.Color]::FromArgb(0, 80, 160)
                $item.BackColor = [System.Drawing.Color]::FromArgb(225, 236, 250)
                $nPending++
            }
            'Created' { $item.ForeColor = [System.Drawing.Color]::FromArgb(0, 120, 0);   $nCreated++ }
            'Skipped' { $item.ForeColor = [System.Drawing.Color]::Gray;                  $nSkipped++ }
            'Invalid' { $item.ForeColor = [System.Drawing.Color]::FromArgb(180, 0, 0);   $nInvalid++ }
            default   { $item.ForeColor = [System.Drawing.Color]::FromArgb(40, 40, 40);  $nPending++ }
        }
        [void]$lv.Items.Add($item)
    }
    $lv.EndUpdate()

    if ($script:UAPasteIndex -ge 0 -and $script:UAPasteIndex -lt $lv.Items.Count) {
        $lv.Items[$script:UAPasteIndex].Selected = $true
        $lv.Items[$script:UAPasteIndex].EnsureVisible()
    }

    if ($script:UAPasteSummary) {
        if ($total -eq 0) {
            $script:UAPasteSummary.Text = 'Queue empty.'
        } else {
            $script:UAPasteSummary.Text = "Total $total  |  Pending $nPending  |  Created $nCreated  |  Skipped $nSkipped  |  Invalid $nInvalid"
        }
    }
}
#endregion

#region -- Get-PasteNextPendingIndex ------------------------------------------
function Get-PasteNextPendingIndex {
    <#
    .SYNOPSIS
        Returns the queue index of the next Pending record after -After,
        wrapping to the start of the queue. Returns -1 when none remain.
    #>
    param([int]$After = -1)

    if (-not $script:UAPasteQueue -or $script:UAPasteQueue.Count -eq 0) { return -1 }
    $count = $script:UAPasteQueue.Count

    for ($i = $After + 1; $i -lt $count; $i++) {
        if ($script:UAPasteQueue[$i].Status -eq 'Pending') { return $i }
    }
    $stop = [Math]::Min($After, $count - 1)
    for ($i = 0; $i -le $stop; $i++) {
        if ($script:UAPasteQueue[$i].Status -eq 'Pending') { return $i }
    }
    return -1
}
#endregion

#region -- Set-CreateUserFromPasteRecord --------------------------------------
function Set-CreateUserFromPasteRecord {
    <#
    .SYNOPSIS
        Loads one queued record into the Create New User panel.
    .DESCRIPTION
        Writes First Name, Last Name, Phone and Email (always), and Job Title,
        Department, Company, Office (only when the record has a value, so
        carried-over values are not wiped by a blank). Re-enables both
        "Use naming convention" checkboxes and rebuilds Display/Logon Name
        using the pasted account name as the logon base.
        Never touches Password, Target OU, Manager, Description, Copy Groups
        From or Notification.
    .OUTPUTS
        [bool] $true when the record was loaded.
    #>
    param([int]$Index)

    if (-not $script:UAPasteQueue) { return $false }
    if ($Index -lt 0 -or $Index -ge $script:UAPasteQueue.Count) { return $false }
    if (-not $script:UANewFirst) {
        Write-PasteStatus -Text 'Create User panel is not available.' -Level 'err'
        return $false
    }

    $rec = $script:UAPasteQueue[$Index]
    if ($rec.Status -eq 'Created') {
        Write-PasteStatus -Text "Record #$($Index + 1) has already been created." -Level 'warn'
        return $false
    }
    if ($rec.Status -eq 'Invalid') {
        Write-PasteStatus -Text "Record #$($Index + 1) is invalid: $($rec.Issue)" -Level 'err'
        return $false
    }

    # Return any previously loaded record to Pending
    if ($script:UAPasteIndex -ge 0 -and $script:UAPasteIndex -ne $Index -and
        $script:UAPasteIndex -lt $script:UAPasteQueue.Count) {
        $prev = $script:UAPasteQueue[$script:UAPasteIndex]
        if ($prev.Status -eq 'Loaded') { $prev.Status = 'Pending' }
    }

    # Logon base must be set before First/Last so the builder picks it up
    $script:UAPasteAccountBase = [string]$rec.AccountName

    if ($script:UAChkAccountAuto) { $script:UAChkAccountAuto.Checked = $true }
    if ($script:UAChkDisplayAuto) { $script:UAChkDisplayAuto.Checked = $true }

    $script:UANewFirst.Text = [string]$rec.FirstName
    $script:UANewLast.Text  = [string]$rec.LastName
    if ($script:UANewPhone) { $script:UANewPhone.Text = [string]$rec.Telephone }
    if ($script:UANewEmail) { $script:UANewEmail.Text = [string]$rec.Email }

    if ($rec.Title      -and $script:UANewTitle)   { $script:UANewTitle.Text   = [string]$rec.Title }
    if ($rec.Department -and $script:UANewDept)    { $script:UANewDept.Text    = [string]$rec.Department }
    if ($rec.Company    -and $script:UANewCompany) { $script:UANewCompany.Text = [string]$rec.Company }
    if ($rec.Office     -and $script:UANewOffice)  { $script:UANewOffice.Text  = [string]$rec.Office }

    # Explicit rebuild - TextChanged does not fire if First/Last are unchanged
    if ($script:UABuildAccountName) { & $script:UABuildAccountName }
    if ($script:UABuildDisplay)     { & $script:UABuildDisplay }

    $rec.Status                 = 'Loaded'
    $script:UAPasteIndex        = $Index
    $script:UAPasteLoadedActive = $true
    Update-PasteQueueView

    $total = $script:UAPasteQueue.Count
    $msg   = "Loaded #$($Index + 1) of ${total}: $($rec.FirstName) $($rec.LastName). Review, then click Create User."
    if ($rec.Issue) {
        Write-PasteStatus -Text "$msg  Note: $($rec.Issue)" -Level 'warn'
    } else {
        Write-PasteStatus -Text $msg -Level 'info'
    }
    UA-Log "Paste Import: loaded record #$($Index + 1) ($($rec.FirstName) $($rec.LastName))." 'info'
    return $true
}
#endregion

#region -- Get-PasteCarryOverValues -------------------------------------------
function Get-PasteCarryOverValues {
    <#
    .SYNOPSIS
        Snapshots batch state and (optionally) Job Details / Other values.
        MUST be called before the Create User panel's shared clear runs.
    .OUTPUTS
        PSCustomObject { BatchActive [bool]; CarryOver [hashtable or $null] }
    #>
    $snap = [PSCustomObject]@{ BatchActive = $false; CarryOver = $null }

    if ($script:UAPasteQueue -and $script:UAPasteQueue.Count -gt 0 -and
        $script:UAPasteIndex -ge 0 -and $script:UAPasteLoadedActive) {
        $snap.BatchActive = $true
    }

    if ($snap.BatchActive -and $script:UAPasteChkCarry -and $script:UAPasteChkCarry.Checked) {
        $cgIndex = -1
        $cgText  = ''
        if ($script:UANewCopyGroupsFrom) {
            $cgIndex = $script:UANewCopyGroupsFrom.SelectedIndex
            $cgText  = [string]$script:UANewCopyGroupsFrom.Text
        }
        $snap.CarryOver = @{
            Title           = [string]$script:UANewTitle.Text
            Department      = [string]$script:UANewDept.Text
            Company         = [string]$script:UANewCompany.Text
            Office          = [string]$script:UANewOffice.Text
            Manager         = [string]$script:UANewManager.Text
            Description     = [string]$script:UANewDesc.Text
            CopyGroupsIndex = $cgIndex
            CopyGroupsText  = $cgText
        }
    }
    return $snap
}
#endregion

#region -- Invoke-PasteQueueAdvance -------------------------------------------
function Invoke-PasteQueueAdvance {
    <#
    .SYNOPSIS
        Marks the loaded record (Created by default, or Skipped), restores
        carried-over fields, and loads the next Pending record.
        MUST be called after the Create User panel's shared clear runs.
        No-op when the snapshot shows no active batch.
    #>
    param(
        [object]$Snapshot,
        [ValidateSet('Created','Skipped')][string]$MarkAs = 'Created'
    )

    if (-not $Snapshot -or -not $Snapshot.BatchActive) { return }
    if (-not $script:UAPasteQueue) { return }

    $idx = $script:UAPasteIndex
    if ($idx -lt 0 -or $idx -ge $script:UAPasteQueue.Count) { return }

    $rec        = $script:UAPasteQueue[$idx]
    $rec.Status = $MarkAs
    $script:UAPasteLoadedActive = $false

    # Restore carried Job Details / Other before loading the next record,
    # so values present in the next record override the carried ones.
    if ($Snapshot.CarryOver) {
        $c = $Snapshot.CarryOver
        $script:UANewTitle.Text   = $c.Title
        $script:UANewDept.Text    = $c.Department
        $script:UANewCompany.Text = $c.Company
        $script:UANewOffice.Text  = $c.Office
        $script:UANewManager.Text = $c.Manager
        $script:UANewDesc.Text    = $c.Description
        if ($script:UANewCopyGroupsFrom) {
            if ($c.CopyGroupsIndex -ge 0 -and $c.CopyGroupsIndex -lt $script:UANewCopyGroupsFrom.Items.Count) {
                $script:UANewCopyGroupsFrom.SelectedIndex = $c.CopyGroupsIndex
            } elseif ($c.CopyGroupsText) {
                $script:UANewCopyGroupsFrom.Text = $c.CopyGroupsText
            }
        }
    }

    $next = Get-PasteNextPendingIndex -After $idx
    if ($next -ge 0) {
        [void](Set-CreateUserFromPasteRecord -Index $next)
        return
    }

    # Batch complete
    $script:UAPasteIndex       = -1
    $script:UAPasteAccountBase = ''
    if ($script:UABuildAccountName) { & $script:UABuildAccountName }
    Update-PasteQueueView

    $nCreated = @($script:UAPasteQueue | Where-Object { $_.Status -eq 'Created' }).Count
    $nSkipped = @($script:UAPasteQueue | Where-Object { $_.Status -eq 'Skipped' }).Count
    $nInvalid = @($script:UAPasteQueue | Where-Object { $_.Status -eq 'Invalid' }).Count
    $summary  = "Batch complete: $nCreated created, $nSkipped skipped, $nInvalid invalid."
    Write-PasteStatus -Text $summary -Level 'ok'
    UA-Log "Paste Import: $summary" 'ok'
}
#endregion

#region -- Clear-PasteQueue ---------------------------------------------------
function Clear-PasteQueue {
    <#
    .SYNOPSIS
        Resets the Paste Import panel without prompting: paste box, queue,
        summary, status line and batch tracking state.
    .OUTPUTS
        [bool] $true when a queue record was loaded in the Create User form
        at the time of the reset (caller decides whether to clear the form).
    #>
    $wasLoaded = [bool]($script:UAPasteLoadedActive -and $script:UAPasteIndex -ge 0)

    if ($script:UAPasteQueue) { $script:UAPasteQueue.Clear() }
    $script:UAPasteIndex        = -1
    $script:UAPasteLoadedActive = $false
    $script:UAPasteAccountBase  = ''
    if ($script:UAPasteText) { $script:UAPasteText.Text = '' }

    Update-PasteQueueView
    Write-PasteStatus -Text 'Paste user data, then click Parse.' -Level 'info'
    return $wasLoaded
}
#endregion

#region -- Build-CreateUserPastePanel -----------------------------------------
function Build-CreateUserPastePanel {
    <#
    .SYNOPSIS
        Constructs the Paste Import panel inside the provided parent control.
        Returns the panel border control.
    #>
    param(
        [System.Windows.Forms.Control]$Parent,
        [int]$X, [int]$Y, [int]$W, [int]$H
    )

    $F_UI   = New-Object System.Drawing.Font('Segoe UI', 9)
    $F_UI_B = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $F_SM   = New-Object System.Drawing.Font('Segoe UI', 8)
    $F_MONO = New-Object System.Drawing.Font('Consolas', 9)
    $HDR_H  = 25
    $PAD    = 6

    # ---- Batch state --------------------------------------------------------
    $script:UAPasteQueue        = New-Object System.Collections.Generic.List[object]
    $script:UAPasteIndex        = -1
    $script:UAPasteAccountBase  = ''
    $script:UAPasteLoadedActive = $false

    # ---- Outer border / header / content (matches Build-CreateUserPanel) ----
    $border           = New-Object System.Windows.Forms.Panel
    $border.Location  = New-Object System.Drawing.Point($X, $Y)
    $border.Size      = New-Object System.Drawing.Size($W, $H)
    $border.BackColor = [System.Drawing.Color]::FromArgb(160, 160, 160)
    $Parent.Controls.Add($border)

    $hdr              = New-Object System.Windows.Forms.Panel
    $hdr.Location     = New-Object System.Drawing.Point(1, 1)
    $hdr.Size         = New-Object System.Drawing.Size(($W - 2), $HDR_H)
    $hdr.BackColor    = [System.Drawing.Color]::FromArgb(210, 225, 245)
    $border.Controls.Add($hdr)

    $hdrLbl           = New-Object System.Windows.Forms.Label
    $hdrLbl.Text      = 'Paste Import (Business Domain)'
    $hdrLbl.Location  = New-Object System.Drawing.Point(4, 0)
    $hdrLbl.Size      = New-Object System.Drawing.Size(($W - 10), $HDR_H)
    $hdrLbl.Font      = $F_UI_B
    $hdrLbl.ForeColor = [System.Drawing.Color]::FromArgb(0, 80, 160)
    $hdrLbl.TextAlign = 'MiddleLeft'
    $hdr.Controls.Add($hdrLbl)

    $CW = $W - 2
    $CH = $H - $HDR_H - 2

    $sec              = New-Object System.Windows.Forms.Panel
    $sec.Location     = New-Object System.Drawing.Point(1, ($HDR_H + 1))
    $sec.Size         = New-Object System.Drawing.Size($CW, $CH)
    $sec.BackColor    = [System.Drawing.Color]::White
    $border.Controls.Add($sec)

    # ---- Vertical budget ----------------------------------------------------
    # Fixed rows: pad 6 + hint 20 + gap 6 + buttons 28 + gap 8 + gap 6 +
    #             buttons 28 + gap 6 + checkbox 22 + status 20 + pad 6 = 156
    $IW     = $CW - ($PAD * 2)
    $avail  = $CH - 156
    $pasteH = [int]($avail * 0.4)
    if ($pasteH -lt 80) { $pasteH = 80 }
    $listH  = $avail - $pasteH
    if ($listH -lt 80) { $listH = 80 }

    $y = $PAD

    # ---- Hint ---------------------------------------------------------------
    $lHint           = New-Object System.Windows.Forms.Label
    $lHint.Text      = 'Paste "Key: Value" user blocks from the business domain. Leave a blank line between users.'
    $lHint.Location  = New-Object System.Drawing.Point($PAD, $y)
    $lHint.Size      = New-Object System.Drawing.Size($IW, 18)
    $lHint.Font      = $F_SM
    $lHint.ForeColor = [System.Drawing.Color]::DimGray
    $sec.Controls.Add($lHint)
    $y += 20

    # ---- Paste textbox ------------------------------------------------------
    $script:UAPasteText               = New-Object System.Windows.Forms.TextBox
    $script:UAPasteText.Location      = New-Object System.Drawing.Point($PAD, $y)
    $script:UAPasteText.Size          = New-Object System.Drawing.Size($IW, $pasteH)
    $script:UAPasteText.Multiline     = $true
    $script:UAPasteText.AcceptsReturn = $true
    $script:UAPasteText.WordWrap      = $false
    $script:UAPasteText.ScrollBars    = 'Both'
    $script:UAPasteText.MaxLength     = 1048576
    $script:UAPasteText.Font          = $F_MONO
    $script:UAPasteText.BorderStyle   = 'FixedSingle'
    $script:UAPasteText.BackColor     = [System.Drawing.Color]::White
    $sec.Controls.Add($script:UAPasteText)
    $y += $pasteH + 6

    # ---- Parse / Clear Queue / summary --------------------------------------
    $btnParse      = New-StdButton -Text 'Parse' -X $PAD -Y $y -W 90 -H 28 -Parent $sec
    $btnParse.Font = $F_UI_B
    $btnClearQ     = New-StdButton -Text 'Clear Queue' -X ($PAD + 98) -Y $y -W 100 -H 28 -Parent $sec

    $SUM_X = $PAD + 206
    $script:UAPasteSummary           = New-Object System.Windows.Forms.Label
    $script:UAPasteSummary.Text      = 'Queue empty.'
    $script:UAPasteSummary.Location  = New-Object System.Drawing.Point($SUM_X, ($y + 6))
    $script:UAPasteSummary.Size      = New-Object System.Drawing.Size(($IW - 206), 18)
    $script:UAPasteSummary.Font      = $F_SM
    $script:UAPasteSummary.ForeColor = [System.Drawing.Color]::DimGray
    $sec.Controls.Add($script:UAPasteSummary)
    $y += 28 + 8

    # ---- Queue ListView -----------------------------------------------------
    $script:UAPasteList                  = New-Object System.Windows.Forms.ListView
    $script:UAPasteList.Location         = New-Object System.Drawing.Point($PAD, $y)
    $script:UAPasteList.Size             = New-Object System.Drawing.Size($IW, $listH)
    $script:UAPasteList.View             = 'Details'
    $script:UAPasteList.FullRowSelect    = $true
    $script:UAPasteList.GridLines        = $true
    $script:UAPasteList.MultiSelect      = $false
    $script:UAPasteList.HideSelection    = $false
    $script:UAPasteList.ShowItemToolTips = $true
    $script:UAPasteList.Font             = $F_UI
    $script:UAPasteList.BorderStyle      = 'FixedSingle'
    $sec.Controls.Add($script:UAPasteList)

    $COL_NUM = 36
    $COL_ST  = 72
    $COL_TXT = [int](($IW - $COL_NUM - $COL_ST - 24) / 3)
    if ($COL_TXT -lt 60) { $COL_TXT = 60 }
    [void]$script:UAPasteList.Columns.Add('#',       $COL_NUM)
    [void]$script:UAPasteList.Columns.Add('First',   $COL_TXT)
    [void]$script:UAPasteList.Columns.Add('Last',    $COL_TXT)
    [void]$script:UAPasteList.Columns.Add('Account', $COL_TXT)
    [void]$script:UAPasteList.Columns.Add('Status',  $COL_ST)
    $y += $listH + 6

    # ---- Load Selected / Skip -----------------------------------------------
    $btnLoad = New-StdButton -Text 'Load Selected' -X $PAD -Y $y -W 110 -H 28 -Parent $sec
    $btnSkip = New-StdButton -Text 'Skip'          -X ($PAD + 118) -Y $y -W 72 -H 28 -Parent $sec
    $y += 28 + 6

    # ---- Carry-over checkbox ------------------------------------------------
    $script:UAPasteChkCarry          = New-Object System.Windows.Forms.CheckBox
    $script:UAPasteChkCarry.Text     = 'Keep Job Details / Other between users'
    $script:UAPasteChkCarry.Location = New-Object System.Drawing.Point($PAD, $y)
    $script:UAPasteChkCarry.Size     = New-Object System.Drawing.Size($IW, 22)
    $script:UAPasteChkCarry.Font     = $F_UI
    $script:UAPasteChkCarry.Checked  = $false
    $sec.Controls.Add($script:UAPasteChkCarry)
    $y += 22

    # ---- Status line --------------------------------------------------------
    $script:UAPasteStatus           = New-Object System.Windows.Forms.Label
    $script:UAPasteStatus.Text      = 'Paste user data, then click Parse.'
    $script:UAPasteStatus.Location  = New-Object System.Drawing.Point($PAD, $y)
    $script:UAPasteStatus.Size      = New-Object System.Drawing.Size($IW, 18)
    $script:UAPasteStatus.Font      = $F_SM
    $script:UAPasteStatus.ForeColor = [System.Drawing.Color]::DimGray
    $sec.Controls.Add($script:UAPasteStatus)

    # =========================================================================
    # EVENT WIRING
    # =========================================================================

    $btnParse.Add_Click({
        $open = @($script:UAPasteQueue | Where-Object { $_.Status -eq 'Pending' -or $_.Status -eq 'Loaded' }).Count
        if ($open -gt 0) {
            $ans = [System.Windows.Forms.MessageBox]::Show(
                "The current queue still has $open unfinished record(s).`nReplace it with the newly parsed text?",
                'Paste Import',
                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Question)
            if ($ans -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        }

        $recs = @(ConvertFrom-PastedUserText -Text $script:UAPasteText.Text)

        $script:UAPasteQueue.Clear()
        foreach ($r in $recs) { $script:UAPasteQueue.Add($r) }
        $script:UAPasteIndex        = -1
        $script:UAPasteLoadedActive = $false
        $script:UAPasteAccountBase  = ''
        Update-PasteQueueView

        if ($recs.Count -eq 0) {
            if ($script:UABuildAccountName) { & $script:UABuildAccountName }
            Write-PasteStatus -Text 'No user records found. Expected lines like "First name: John".' -Level 'warn'
            UA-Log 'Paste Import: no user records found in pasted text.' 'warn'
            return
        }

        $nInvalid = @($recs | Where-Object { $_.Status -eq 'Invalid' }).Count
        $lvl = 'ok'
        if ($nInvalid -gt 0) { $lvl = 'warn' }
        UA-Log "Paste Import: parsed $($recs.Count) record(s), $nInvalid invalid." $lvl

        $first = Get-PasteNextPendingIndex -After -1
        if ($first -ge 0) {
            [void](Set-CreateUserFromPasteRecord -Index $first)
        } else {
            if ($script:UABuildAccountName) { & $script:UABuildAccountName }
            Write-PasteStatus -Text 'All parsed records are invalid. Hover a row for details.' -Level 'err'
        }
    })

    $btnClearQ.Add_Click({
        $open = @($script:UAPasteQueue | Where-Object { $_.Status -eq 'Pending' -or $_.Status -eq 'Loaded' }).Count
        if ($open -gt 0) {
            $ans = [System.Windows.Forms.MessageBox]::Show(
                "Discard the queue with $open unfinished record(s)?`nThe Create User form is not cleared.",
                'Paste Import',
                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Question)
            if ($ans -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        }
        [void](Clear-PasteQueue)
        if ($script:UABuildAccountName) { & $script:UABuildAccountName }
        Write-PasteStatus -Text 'Queue cleared.' -Level 'info'
    })

    $loadSelected = {
        if ($script:UAPasteList.SelectedItems.Count -eq 0) {
            Write-PasteStatus -Text 'Select a record to load.' -Level 'warn'
            return
        }
        $i = [int]$script:UAPasteList.SelectedItems[0].Tag
        [void](Set-CreateUserFromPasteRecord -Index $i)
    }
    $btnLoad.Add_Click($loadSelected)
    $script:UAPasteList.Add_DoubleClick($loadSelected)

    $btnSkip.Add_Click({
        $sel = -1
        if ($script:UAPasteList.SelectedItems.Count -gt 0) {
            $sel = [int]$script:UAPasteList.SelectedItems[0].Tag
        } elseif ($script:UAPasteIndex -ge 0) {
            $sel = $script:UAPasteIndex
        }
        if ($sel -lt 0 -or $sel -ge $script:UAPasteQueue.Count) {
            Write-PasteStatus -Text 'Select a record to skip.' -Level 'warn'
            return
        }

        $rec = $script:UAPasteQueue[$sel]
        if ($rec.Status -eq 'Created' -or $rec.Status -eq 'Invalid' -or $rec.Status -eq 'Skipped') {
            Write-PasteStatus -Text "Record #$($sel + 1) is already $($rec.Status)." -Level 'warn'
            return
        }

        UA-Log "Paste Import: skipped record #$($sel + 1) ($($rec.FirstName) $($rec.LastName))." 'warn'

        if ($sel -eq $script:UAPasteIndex -and $script:UAPasteLoadedActive) {
            # Skipping the loaded record: clear the form (keeping carry-over
            # values if enabled) and move to the next Pending record.
            $snap = Get-PasteCarryOverValues
            if ($script:UAClearCreateFields) { & $script:UAClearCreateFields }
            Invoke-PasteQueueAdvance -Snapshot $snap -MarkAs 'Skipped'
        } else {
            $rec.Status = 'Skipped'
            if ($sel -eq $script:UAPasteIndex) { $script:UAPasteIndex = -1 }
            Update-PasteQueueView
            Write-PasteStatus -Text "Record #$($sel + 1) skipped." -Level 'info'
        }
    })

    Update-PasteQueueView
    return $border
}
#endregion

Export-ModuleMember -Function Build-CreateUserPastePanel, Set-CreateUserFromPasteRecord, Get-PasteCarryOverValues, Invoke-PasteQueueAdvance, Update-PasteQueueView, Get-PasteNextPendingIndex, Write-PasteStatus, Clear-PasteQueue
