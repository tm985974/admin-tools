#region -- ADDirectory.Context.Common.psm1 ------------------------------------
# Concern : Shared script-scope state for all ADDirectory context/menu modules.
#           New-MenuItem factory helper used by all menu builders.
#           Invoke-SetStatus shim for menu action handlers.
# Load order: 24 - no ADDirectory dependencies; depends on Services.AD.Reporting
# Split from: ADDirectory.Menus.psm1
#endregion

#region -- Shared script-scope state ------------------------------------------
# $script:DirContext is written by Register-DirectoryTab and read by all
# menu/dialog handlers in this group via the shared module scope.
$script:DirContext = $null
#endregion

#region -- New-MenuItem -------------------------------------------------------
function New-MenuItem {
    param([string]$Text, [scriptblock]$Action, [bool]$Separator = $false)
    if ($Separator) { return New-Object System.Windows.Forms.ToolStripSeparator }
    $item = New-Object System.Windows.Forms.ToolStripMenuItem
    $item.Text = $Text; $item.Add_Click($Action)
    return $item
}
#endregion

Export-ModuleMember -Function New-MenuItem
