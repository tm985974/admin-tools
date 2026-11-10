# Services_Logging.psm1
#
# Thin wrappers over the host's logging ($App.Log / $App.LogAction), so module
# code has a PowerShell-native way to log. The actual writing, FIFO size caps,
# machine/UTC stamping and the resolved data root all live in the host; these
# functions just forward to it. Logs are written to the resolved data root
# (shared network path if reachable, else local AppData) and are NEVER packed
# back into the EXE -- the runtime stays sealed.

function Write-AppLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $App,
        [ValidateSet('INFO','WARN','ERROR','DIAG')] [string]$Level = 'INFO',
        [string]$Source = 'App',
        [Parameter(Mandatory)] [string]$Text
    )
    if ($null -ne $App) { $App.Log($Level, $Source, $Text) }
}

function Write-ActionLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $App,
        [Parameter(Mandatory)] [string]$Text
    )
    # One line in the active environment's own log (Logs\<ENV>.log).
    if ($null -ne $App) { $App.LogAction($Text) }
}
