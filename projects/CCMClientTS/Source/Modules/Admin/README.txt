Admin tier modules (sealed under the ADMIN password; also in the developer build).

  Services_CcmJobs.psm1         runs long native tools in a visible console window, polled by a UI timer
  Services_CcmStepActions.psm1  the code behind every step (Invoke-CcmStep)
  UI_Tab_Repair.psm1            the Repair Steps tab (New-CcmRepairTab)

A user-tier launch never receives these files: it gets Overview, Discovery
and Logs only (read-only - nothing on the machine is changed).
To give everyone the Repair Steps tab, move these three files to Modules\Lite.
