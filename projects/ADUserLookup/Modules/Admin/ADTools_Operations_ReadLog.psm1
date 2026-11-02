#region -- ADTools.Operations.ReadLog.psm1 ------------------------------------
# Concern : Read-OpLog - loads operation log entries via Get-OperationLog for
#           the configured day window and triggers Select-OpLog to populate the grid.
# Load order: 120 - depends on ADTools.Operations.SelectLog (Select-OpLog),
#                            ADTools.PasswordGenerator.Engine (script scope),
#                            Services.Logging (Get-OperationLog)
# Split from: ADTools.Actions.psm1
#endregion

#region -- Read-OpLog ---------------------------------------------------------
function Read-OpLog {
    $days    = [int]$script:LogNud.Value
    $entries = Get-OperationLog -Context $script:ToolsCtx -LastNDays $days
    $script:LogAllEntries = $entries
    Select-OpLog
    Set-Status "Operation log: $($entries.Count) entries from last $days day(s)." 'ok'
}
#endregion

Export-ModuleMember -Function Read-OpLog
