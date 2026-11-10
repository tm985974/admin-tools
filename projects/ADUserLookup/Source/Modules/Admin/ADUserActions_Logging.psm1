#region -- ADUserActions.Logging.psm1 -----------------------------------------
# Concern : Module boundary marker for the ADUserActions logging concern.
#           UA-Log is defined in ADUserActions.Banner.psm1 which owns the
#           shared script scope and the RichTextBox reference.
#           This module re-exports UA-Log so callers can import from either
#           module without caring which file physically owns the function.
# Load order: 28 - depends on ADUserActions.Banner (UA-Log defined there)
# Split from: ADUserActions.psm1
#endregion

# UA-Log is defined and exported by ADUserActions.Banner.psm1.
# No additional functions are defined here; the module satisfies the
# structural split boundary in the target tree.

Export-ModuleMember
