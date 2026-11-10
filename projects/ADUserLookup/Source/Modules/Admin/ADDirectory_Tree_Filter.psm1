#region -- ADDirectory.Tree.Filter.psm1 ---------------------------------------
# Concern : Exposes Get-DirOUFilter so ADDirectory grid modules can read the
#           authoritative $script:DirOUFilter value written by AfterSelect in
#           ADDirectory.Tree.Register, rather than maintaining an isolated copy.
# Load order: 9 - depends on ADDirectory.Tree.Register (script scope)
# Split from: ADDirectory.Tree.psm1
#endregion

#region -- Get-DirOUFilter ----------------------------------------------------
function Get-DirOUFilter {
    <#
    .SYNOPSIS
        Returns the current OU filter DN from the tree module's script scope.
        Called by ADDirectory grid filter functions so they scope results to
        the OU selected in the persistent left-column tree.
        Returns empty string when the root / no filter is active.
    #>
    return $script:DirOUFilter
}
#endregion

Export-ModuleMember -Function Get-DirOUFilter
