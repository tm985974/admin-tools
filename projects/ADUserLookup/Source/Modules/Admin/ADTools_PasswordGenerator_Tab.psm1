#region -- ADTools.PasswordGenerator.Tab.psm1 --------------------------------
# Concern : Build-PwGenTab - constructs the Password Generator sub-tab with
#           display label, Generate/Copy buttons, and 3 editable multi-line
#           textboxes (Phrase, Symbol, Number) backed by
#           .\Config\PasswordGenerator.json. A single Update button saves all
#           three lists at once. Wires all button events.
# Load order: 115 - depends on ADTools.PasswordGenerator.Engine (New-CustomPassword,
#                                                                  script scope),
#                            Services.PasswordWordLists (Get-PasswordWordLists,
#                                                        Set-PasswordWordLists),
#                            Services.AD.Reporting (New-SectionPanel, New-StdButton)
# Split from: ADTools.Tab.psm1
# Changes   : Generate 10 button and Batch Generated Passwords list box removed.
#             Options panel (Word pool combo / Symbol textbox / Year NUD range)
#             replaced with 3 side-by-side editable multi-line textboxes, one
#             per list, pre-populated from Get-PasswordWordLists. Paste
#             multiple lines in, click Update, and all three lists save at
#             once (all-or-nothing - see Set-PasswordWordLists).
#endregion

#region -- Build-PwGenTab -----------------------------------------------------
function Build-PwGenTab {
    param([System.Windows.Forms.TabPage]$Tab)
    $PAD    = 8
    $F_UI   = New-Object System.Drawing.Font('Segoe UI', 9)
    $F_UI_B = New-Object System.Drawing.Font('Segoe UI', 9,  [System.Drawing.FontStyle]::Bold)
    $F_MONO = New-Object System.Drawing.Font('Consolas',  10)
    $F_BIG  = New-Object System.Drawing.Font('Consolas',  14, [System.Drawing.FontStyle]::Bold)
    $TW     = $script:_TW
    $TH     = $script:_TH

    $CW = 500; $CX = [int](($TW - $CW) / 2); $Y = 24

    $lTitle           = New-Object System.Windows.Forms.Label
    $lTitle.Text      = 'Password Generator'
    $lTitle.Location  = New-Object System.Drawing.Point($CX, $Y)
    $lTitle.Size      = New-Object System.Drawing.Size($CW, 28)
    $lTitle.Font      = $F_UI_B; $lTitle.ForeColor = [System.Drawing.Color]::FromArgb(0,80,160)
    $lTitle.TextAlign = 'MiddleCenter'
    $Tab.Controls.Add($lTitle); $Y += 36

    $pPwPanel              = New-Object System.Windows.Forms.Panel
    $pPwPanel.Location     = New-Object System.Drawing.Point($CX, $Y)
    $pPwPanel.Size         = New-Object System.Drawing.Size($CW, 56)
    $pPwPanel.BackColor    = [System.Drawing.Color]::White
    $pPwPanel.BorderStyle  = 'FixedSingle'
    $Tab.Controls.Add($pPwPanel)

    $script:PwDisplayLbl           = New-Object System.Windows.Forms.Label
    $script:PwDisplayLbl.Text      = 'Click Generate'
    $script:PwDisplayLbl.Dock      = 'Fill'
    $script:PwDisplayLbl.Font      = $F_BIG
    $script:PwDisplayLbl.ForeColor = [System.Drawing.Color]::FromArgb(0,80,160)
    $script:PwDisplayLbl.TextAlign = 'MiddleCenter'
    $pPwPanel.Controls.Add($script:PwDisplayLbl); $Y += 64

    $btnGen      = New-StdButton -Text 'Generate'          -X $CX       -Y $Y -W 180 -H 32 -Parent $Tab
    $btnGen.Font = $F_UI_B
    $btnCopy     = New-StdButton -Text 'Copy to Clipboard' -X ($CX+188) -Y $Y -W 200 -H 32 -Parent $Tab
    $Y += 44

    # -- Editable word lists (Phrase / Symbol / Number), 3 columns spanning
    #    the full tab width. Each is a multi-line textbox - paste several
    #    items in (one per line), then click Update to save all three.
    $UPDATE_H  = 32
    $LISTS_Y   = $Y
    $LISTS_X   = $PAD
    $LISTS_W   = $TW - ($PAD * 2)
    $UPDATE_Y  = $TH - $UPDATE_H - ($PAD * 3)
    $LISTS_H   = $UPDATE_Y - $LISTS_Y - $PAD

    $GAP    = $PAD
    $COL_W  = [int](($LISTS_W - ($GAP * 2)) / 3)
    $COL_X0 = $LISTS_X
    $COL_X1 = $COL_X0 + $COL_W + $GAP
    $COL_X2 = $COL_X1 + $COL_W + $GAP

    $lists = Get-PasswordWordLists

    $secPhrase = New-SectionPanel -Parent $Tab -Title 'Phrase' -X $COL_X0 -Y $LISTS_Y -W $COL_W -H $LISTS_H
    $script:PwTbPhrase              = New-Object System.Windows.Forms.TextBox
    $script:PwTbPhrase.Location     = New-Object System.Drawing.Point(4, 4)
    $script:PwTbPhrase.Size         = New-Object System.Drawing.Size(($COL_W - 12), ($LISTS_H - 33))
    $script:PwTbPhrase.Multiline    = $true
    $script:PwTbPhrase.ScrollBars   = 'Vertical'
    $script:PwTbPhrase.WordWrap     = $false
    $script:PwTbPhrase.Font         = $F_MONO
    $script:PwTbPhrase.BorderStyle  = 'None'
    $script:PwTbPhrase.Text         = ($lists.Phrase -join "`r`n")
    $secPhrase.Controls.Add($script:PwTbPhrase)

    $secSymbol = New-SectionPanel -Parent $Tab -Title 'Symbol' -X $COL_X1 -Y $LISTS_Y -W $COL_W -H $LISTS_H
    $script:PwTbSymbol              = New-Object System.Windows.Forms.TextBox
    $script:PwTbSymbol.Location     = New-Object System.Drawing.Point(4, 4)
    $script:PwTbSymbol.Size         = New-Object System.Drawing.Size(($COL_W - 12), ($LISTS_H - 33))
    $script:PwTbSymbol.Multiline    = $true
    $script:PwTbSymbol.ScrollBars   = 'Vertical'
    $script:PwTbSymbol.WordWrap     = $false
    $script:PwTbSymbol.Font         = $F_MONO
    $script:PwTbSymbol.BorderStyle  = 'None'
    $script:PwTbSymbol.Text         = ($lists.Symbol -join "`r`n")
    $secSymbol.Controls.Add($script:PwTbSymbol)

    $secNumber = New-SectionPanel -Parent $Tab -Title 'Number' -X $COL_X2 -Y $LISTS_Y -W $COL_W -H $LISTS_H
    $script:PwTbNumber              = New-Object System.Windows.Forms.TextBox
    $script:PwTbNumber.Location     = New-Object System.Drawing.Point(4, 4)
    $script:PwTbNumber.Size         = New-Object System.Drawing.Size(($COL_W - 12), ($LISTS_H - 33))
    $script:PwTbNumber.Multiline    = $true
    $script:PwTbNumber.ScrollBars   = 'Vertical'
    $script:PwTbNumber.WordWrap     = $false
    $script:PwTbNumber.Font         = $F_MONO
    $script:PwTbNumber.BorderStyle  = 'None'
    $script:PwTbNumber.Text         = ($lists.Number -join "`r`n")
    $secNumber.Controls.Add($script:PwTbNumber)

    $btnUpdate      = New-StdButton -Text 'Update' -X ([int](($TW - 140) / 2)) -Y $UPDATE_Y -W 140 -H $UPDATE_H -Parent $Tab
    $btnUpdate.Font = $F_UI_B

    $btnGen.Add_Click({
        $pw = New-CustomPassword; $script:PwDisplayLbl.Text = $pw
        Set-Status "Password generated. Click Copy to Clipboard to use it." 'info'
    })
    $btnCopy.Add_Click({
        $pw = $script:PwDisplayLbl.Text
        if ($pw -and $pw -ne 'Click Generate') {
            [System.Windows.Forms.Clipboard]::SetText($pw); Set-Status "Password copied to clipboard." 'ok'
        }
    })
    $btnUpdate.Add_Click({
        $phraseLines = @($script:PwTbPhrase.Text -split "`r`n|`n")
        $symbolLines = @($script:PwTbSymbol.Text -split "`r`n|`n")
        $numberLines = @($script:PwTbNumber.Text -split "`r`n|`n")

        $result = Set-PasswordWordLists -Phrase $phraseLines -Symbol $symbolLines -Number $numberLines
        if ($result.Success) {
            $script:PwTbPhrase.Text = ($result.Lists.Phrase -join "`r`n")
            $script:PwTbSymbol.Text = ($result.Lists.Symbol -join "`r`n")
            $script:PwTbNumber.Text = ($result.Lists.Number -join "`r`n")
            Set-Status ("Lists updated: $($result.Lists.Phrase.Count) phrase, " +
                        "$($result.Lists.Symbol.Count) symbol, " +
                        "$($result.Lists.Number.Count) number.") 'ok'
        } else {
            Set-Status "Update failed: $($result.Message)" 'warn'
        }
    })
}
#endregion

Export-ModuleMember -Function Build-PwGenTab
