# SCCM App Manager

Application lifecycle, collections and devices for one or more ConfigMgr sites,
as one portable EXE (`SCCMAppManagerLite.exe`). Built on AppTemplate; it
replaces `SCCM_App_Lifecycle_Manager.ps1` v8.4.

| Tab | What it does |
|---|---|
| Overview | How the tool works |
| Update Pipeline | Incoming -> Pull -> Update JSON -> Upload -> Create -> Deploy, per application, for the active site |
| Software | Every application: deployments + targeted / installed / failed counts; deploy, status, export, content |
| Collections | Every collection: members + deployment counts; members with install status, add devices, deploy here |
| Devices | Every device: collection + targeted-deployment counts; multi-select -> Add to collection |
| Environment | One environment per site (A30, CA1); the SCCM Site page holds the site's settings |

- **Multi-site:** pick the environment (site) on the Environment tab. JSON files
  carry a `SiteCode`; the pipeline shows the active site's files. Exports are
  named `<AppBaseName>_<SITE>.json`. *Copy JSON to environment* re-points a JSON
  to another site (repository, content, icon, command paths) after a review.
- **Admin password** adds the destructive actions (remove members, delete
  deployments / applications / collections / device records, retire, new /
  rename collection, clear PXE). User password: everything else.
- **Requirements:** reading uses CIM (DCOM) to the SMS Provider. Create, deploy,
  export and content actions need the ConfigMgr console (its PowerShell module
  is loaded on first use).
- **Logs:** `<data root>\Logs\Session.log`, `<environment>.log` (every change
  made in SCCM), `perf.csv` (timings), `Robocopy\`.

The rest of this file is the template's guide (builds, sealing, updates).

## Engine (AppTemplate)

Building, the Dev / Lite EXEs, passwords, environments, tiers, logging, hover help
and the command window are the template's and the same in every tool: see
[`template/Source/README.md`](../../../template/Source/README.md) in the admin-tools
repository. Build with `Build-App.cmd` in the project folder: it makes
`SCCMAppManagerDev.exe` (developer build, never hand it out) and, with the passwords you
type, `SCCMAppManagerLite.exe` (the sealed build to hand out).
