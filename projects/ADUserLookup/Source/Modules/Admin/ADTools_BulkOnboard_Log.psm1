#region -- ADTools.BulkOnboard.Log.psm1 --------------------------------------
# Concern : Write-BulkLog - appends a timestamped, colour-coded line to BulkRtb
#           and (v1.2.0) records the same message in Logs\Session.log via
#           Write-SessionLog (Services.Logging), source tag "BulkOnboard".
# Load order: 117 - depends on ADTools.PasswordGenerator.Engine (script scope)
# Split from: ADTools.Actions.psm1
#endregion

#region -- Write-BulkLog ------------------------------------------------------
function Write-BulkLog {
    param([string]$Message, [string]$Level = 'info')
    # Persist first, so the message is kept even before the panel exists.
    if ($script:SessionLogReady) {
        try { Write-SessionLog -Text $Message -Level $Level -Source 'BulkOnboard' } catch { }
    }
    if (-not $script:BulkRtb) { return }
    $ts    = Get-Date -Format 'HH:mm:ss'
    $color = switch ($Level) {
        'ok'    { [System.Drawing.Color]::FromArgb(0,120,0)   }
        'warn'  { [System.Drawing.Color]::FromArgb(160,100,0) }
        'err'   { [System.Drawing.Color]::FromArgb(180,0,0)   }
        default { [System.Drawing.Color]::FromArgb(50,50,50)  }
    }
    $script:BulkRtb.SelectionStart  = $script:BulkRtb.TextLength
    $script:BulkRtb.SelectionLength = 0
    $script:BulkRtb.SelectionColor  = [System.Drawing.Color]::DimGray
    $script:BulkRtb.AppendText("[$ts]  ")
    $script:BulkRtb.SelectionColor  = $color
    $script:BulkRtb.AppendText("$Message`n")
    $script:BulkRtb.ScrollToCaret()
}
#endregion

Export-ModuleMember -Function Write-BulkLog
