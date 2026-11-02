#region -- ADInfrastructure.RichText.Line.psm1 --------------------------------
# Concern : Structural boundary module for the RichText.Line split node in the
#           target tree. RTB-Line is defined and exported by
#           ADInfrastructure.RichText.Header.psm1 which owns the full RTB helper
#           set. This module satisfies the tree boundary without duplicating code.
# Load order: 100 - depends on ADInfrastructure.RichText.Header (RTB-Line defined there)
# Split from: ADInfrastructure.Query.psm1
#endregion

# RTB-Line is defined and exported by ADInfrastructure.RichText.Header.psm1.
Export-ModuleMember
