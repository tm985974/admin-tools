Admin tier modules go here.

Any .psm1 you drop in this folder ships ONLY in the admin bundle of a
sealed build (and in the developer build). A user-tier launch never
receives these files -- they stay encrypted under the admin password.

Add a tab by defining a function (e.g. New-MyAdminTab -Page -App) and
listing it in Base\UI_Register-Tabs.psm1 under $adminDefs. It appears
only when its module is present (admin password or developer build).
