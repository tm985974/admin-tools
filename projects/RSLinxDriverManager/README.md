# RSLinx Driver Manager

Builds the RSLinx Classic Ethernet (AB_ETH) drivers on a PC from the device
registry. Rewrite of the old `RSLinx Utility.ps1` on AppTemplate v1.0.20.

- **Drivers** tab: paste the device-registry CSV rows (or load the file) ->
  **Build preview** -> pick sites / edit -> **Add to this PC** or **Overwrite
  this PC**. Allen-Bradley devices only; Primary and Secondary IPs; one driver
  per site (Lease) + VLAN, named `SITE(VLAN)DESCRIPTION` (max 15 characters),
  e.g. `BL(25)SCADA`. Subnets missing from the lookup get `SITE(3rd octet)SCADA`.
  Backups before every change; old `RSLinx.csv` / backups (Name,Node) load too.
- **VLAN Lookup** tab: the naming table (from `RSLinx.xlsx`, VlanLookup sheet),
  saved to `<data root>\Settings\VlanLookup.json`; shipped default
  `Config\VlanLookup.json`.
- **RSLinx** tab: the RSLinx Classic control panel embedded, plus PC facts.
- Changing drivers needs an elevated process (the Drivers tab offers
  **Restart as administrator**).

| Project file | What it holds |
|---|---|
| `Modules\Lite\UI_Tab_Drivers.psm1` | Drivers tab |
| `Modules\Lite\UI_Tab_VlanLookup.psm1` | VLAN Lookup tab |
| `Modules\Lite\UI_Tab_RSLinx.psm1` | RSLinx tab |
| `Modules\Lite\UI_RSLinxCommon.psm1` | shared grid / header / filter-bar builders |
| `Modules\Lite\Services_DeviceImport.psm1` | CSV / paste parsing -> driver rows |
| `Modules\Lite\Services_VlanLookup.psm1` | lookup table, naming, IP helpers |
| `Modules\Lite\Services_RSLinxRegistry.psm1` | read / plan / write AB_ETH drivers |
| `Modules\Lite\Services_RSLinxBackup.psm1` | backup folder, save / list / read |
| `Modules\Lite\Services_SystemInfo.psm1` | installed software, PC facts |
| `Config\VlanLookup.json` | default VLAN lookup table |

The rest of this file is the AppTemplate guide (building, sealing, updating).

---

# App Template — portable PowerShell project shell

A reusable starting point for self-contained PowerShell tools that compile to a
single, portable `.exe`. It is the engine extracted from a working admin tool,
with all of the domain-specific logic removed. Nothing here is tied to Active
Directory or any particular task — the placeholder names are expected to be
renamed when you start a real project.

---

## Two builds from one source

| | **Developer build** (default) | **Sealed build** (the distributable) |
|---|---|---|
| How you get it | `Build-App.exe` / `Build-App.cmd` | **Build Sealed** button in the dev build |
| Embedded C# source (`core.dat`) | yes | **no — omitted** |
| Module package | plaintext, all tiers | **two AES-256 bundles, per-tier** |
| Password to run | none | **yes — at launch** |
| Dev tooling (Update / Update Template / Build Sealed / Build Lite / Extract / Version History / Open ▾) | yes | no |
| Requirement checks + machine facts in Session.log | yes | yes |
| Tabs (Overview, Tab 1-4, Environment) | yes | yes |
| Create / edit environments (Environment tab) | yes | admin password only (user password: pick only) |
| Admin-tier tabs/modules | yes (all tiers loaded) | only with the admin password |

**Never distribute the developer build** — it contains your source. Distribute
only the sealed EXE produced by Build Sealed.

---

## How the sealed build protects code

The distributable embeds two sealed bundles:

- **UserBundle** = `Base` + `Lite` modules, AES-256 sealed with a key derived
  (PBKDF2) from the **user** password.
- **AdminBundle** = `Base` + `Lite` + `Admin` modules, sealed with a key derived
  from the **admin** password.

At launch it prompts for a password and simply tries to decrypt: the user
password opens the user bundle (lite features), the admin password opens the
admin bundle (full features). **No key is stored in the binary — the password
*is* the key.** Nothing decrypts without a correct password, and a user-tier
holder cannot read the admin modules (different key).

**What it does and doesn't hide — read this:**

- ✅ With no password, none of the PowerShell modules are readable — they're
  ciphertext at rest.
- ✅ A user-tier holder cannot read the admin modules.
- ⚠️ The compiled **host IL is always decompilable** (true of any .NET EXE). But
  it only contains the lock (the prompt and the AES routine), not the key, so it
  doesn't help without a password.
- ⚠️ Anyone holding the EXE holds the ciphertext, so they can attempt an
  **offline brute-force / dictionary attack** on a bundle. This is the real
  boundary; it's made expensive, not impossible. **Use strong passwords** — the
  admin password especially. PBKDF2 iterations (310k by default) slow each guess.

Use distinct user and admin passwords (Build Sealed enforces this).

---

## First build (on Windows)

From the root of this folder (an unzipped Extract has exactly this layout),
run one of these - they all do the same build:

| Builder | When |
|---|---|
| `Build-App.exe` | double-click. The developer EXE writes it beside itself after every update, so a machine that has one never needs a script. |
| `Build-App.cmd` | double-click. Compiles `Build-App.cs` into `Build-App.exe` with the machine's `csc.exe`, then runs it. For a new machine. |
| `Build-App.ps1` | where PowerShell scripts may run. Same as the `.cmd`. |

It makes the `Update` folder if missing, builds `AppTemplate.exe` (the
DEVELOPER build) and then `AppTemplateLite.exe` (sealed test build: admin
password `a`, user password `u`). Options: `Build-App.exe -Output <path\Name.exe>
-NoLite -NoPause`.

Requirements: .NET Framework 4.x (`csc.exe`) and Windows PowerShell 5.1
installed (its DLL is referenced; no script runs). If AV quarantines the fresh
EXE, exclude the output folder from real-time scanning.

### Make the distributable

1. Run the developer `AppTemplate.exe`.
2. Click **Build Sealed**, set a **user** password and an **admin** password.
3. It writes the sealed distributable to `…\AppTemplateData\Extract\AppTemplate.exe`.
4. Hand that EXE out. Give operators the user password; keep the admin password.

---

## Tabs

- **Overview** — a guide to the template (replace with your project's overview).
- **Tab 1** — a wired example (reads the active environment, writes a log line).
- **Tab 2** — a filterable grid: the reference for every list with a filter
  box (wildcards in any position, see *Lists and filters*).
- **Tab 3 / 4** — empty placeholders to build on.
- **Environment** — every saved environment in a picker with **New... / Delete
  / Save**, then sub-tabs. **General** (template, every project): the text
  fields in `Config\EnvironmentFields.json` (default: Environment name, Log &
  data path, Variable 1-4), **Lists & logs** (Filter as I type, this
  environment's action-log size) and **Logging** (all environments:
  Session.log size, diagnostics). Then one sub-tab per page a project adds
  with `Register-EnvironmentSection`. Save writes every page at once; leaving
  an environment with unsaved changes asks first. Editable with the admin
  password and in the developer build; read-only with the user password.

## Look and feel

Fonts (Segoe UI / Consolas), the blue palette and the flat buttons from the
sample are baked in and applied to the window, tabs, status bar and dialogs.
They're exposed to module code as `$App.Theme` (colors, fonts, `MakeButton()`),
and `Base\Services_Theme.psm1` has helpers (`New-StyledButton`, `Set-HeaderStyle`,
`Initialize-TabPage`) so your tabs match without hard-coding colors.

## Module tiers

```
Modules\
  Base\    always loaded  (services, theme, the tab registrar, Overview, Environment)
  Lite\    everyone       (Tab 1 wired example; Tab 2 filter grid; Tab 3-4 placeholders)
  Admin\   admin only     (empty by default; add admin-tier tabs here)
```

Which tier a module lands in is decided purely by its folder. `Base`+`Lite` go
in the user bundle; `Base`+`Lite`+`Admin` go in the admin bundle. Add a module
to a folder, list its tab function in `Base\UI_Register-Tabs.psm1`, and rebuild.
The registrar builds a tab only if its function is present, so admin tabs simply
don't appear in a user-tier session.

One function per module keeps the **Function Map** (function → module)
meaningful. It is `Config\FunctionMap.txt` in every Extract and `Archive\Zip`
zip, beside `Config\Environment.txt` (the machine facts; Extract adds the
installed-module list).

---

## Engine helpers for module code (v1.0.17)

| Need | Use |
|---|---|
| Show progress / a result in the status bar | `$App.SetStatus('text', 'info'|'ok'|'warn'|'err')` |
| Save settings that survive a restart | `Get-AppSettingsDir -App $App` → `<data root>\Settings` (seeded from `Config\*.json`). **Never write to `Config\`** — it is rewritten from the EXE every launch. |
| Lay a fixed-layout tab out to fill the window | `Get-TabPageArea -Tabs $MainTabs` at build time (window targets 1885 x 1020: `TargetScreenWidth/Height` in `AppHost.cs`) |
| Build a tab on first view | `Set-LazyTabBuild -Page $Page -App $App -Build { param($Page,$App) ... }` |
| Tabs that depend on each other's controls | `Invoke-LazyTabWarmup -Tabs $MainTabs -App $App -Titles ...` (builds them in the background) |
| Add a page of per-environment settings to the Environment tab | `Register-EnvironmentSection -Title ... -Order n -Build { param($Page,$App) ...; @{ Load = {param($Record)}; Collect = {param($Record) @{...}}; Validate = {...} } }` - the tab saves (see `Services_Environment.psm1`) |
| Read / write saved environments | `Read-AppEnvironmentStore`, `Get-AppEnvironmentRecord`, `Save-AppEnvironmentRecord`, `New-` / `Remove-AppEnvironmentRecord` (`Services_EnvironmentStore.psm1`) |
| A typed value of the active environment | `Get-AppEnvironmentValue -App $App -Key FilterAsYouType -Default $true` |
| Key to store per-environment settings under | `Get-AppEnvironmentKey -App $App` (Domain, else Name) |
| App-wide logging settings | `Get-AppLoggingSettings` / `Set-AppLoggingSettings` (Environment > Logging) |
| Choose the fields the Environment tab shows | `Config\EnvironmentFields.json` (`Key` + `Caption`) |
| Host code that needs a `[TabPage]`, without a tab strip | `New-EmbeddedTabPage -Parent ... -Width ... -Height ...` |
| React to the user switching environment | `Register-EnvironmentChangedHandler -Handler { param($App) ... }` |
| Port a tool whose files share one `$script:` scope | `Config\SharedScope.json` (`Modules`, `Order`), plus an optional `Initialize-SharedScope -App` |
| Say what a tab needs on the machine (module / command) | `if (-not (Register-AppRequirement -App $App -Page $Page -For 'User Lookup' -Module ActiveDirectory -Hint '...')) { return }` at the top of `New-<Tab>` (`Services_Requirements.psm1`; Tab 1 shows it). `-Command` for programs/cmdlets, `-MinimumVersion`; `Get-AppRequirementStatus` lists all |
| Filter a list, grid or tree (wildcards anywhere) | `Register-ListFilter -App $App -TextBox $box -OnFilter { param($Regex,$Text) ... }` + `Select-FilterMatch -Items $all -Regex $Regex -Property ...` (`Services_Filter.psm1`; Tab 2 is the example) |

### Lists and filters (template rule)

Every filter box accepts wildcards **in any position**: `*` = any run of
characters, `?` = exactly one character. Plain text means "contains". Matching
is case-insensitive and never anchored, and every other character is literal:

| Filter | Matches |
|---|---|
| `sql` | anything containing "sql" |
| `lon*01` | `LON-APP-01`, `LON-SQL-01`, ... |
| `web-0?` | `WEB-01` .. `WEB-09` |
| `par*2022` | values with "2022" somewhere after "par" |

Keep the full data set in a variable, wire the box with `Register-ListFilter`
and refill the control from `Select-FilterMatch` in `-OnFilter` (any listed
property may match). The environment's **Filter as I type** decides whether it
filters after a short pause in typing or on Enter; Esc clears. Call
`& $filter.Apply` after loading data. `Modules\Lite\UI_Tab2.psm1` is the
reference.

Lazy tabs replay their first activation after building (main TabControl
`Selected`/`SelectedIndexChanged`, then focus into the page so `Enter` fires), so
handlers wired during the build still see the first visit. Session.log warns
when two modules define the same function, or two module files share a name.

---

## Day-to-day: the Update button (developer build)

The developer EXE keeps an `Update` folder beside itself (made on every start
and every compile): drop update zips there; the Update and Update Template
pickers open in it. **Build Lite** rebuilds `<ExeName>Lite.exe` on demand (e.g.
after saving environments in the developer EXE). **Open ▾** opens the app
folder (Archive, Update, Lite EXE), the Logs folder in use, or AppData
(Settings, Extract, Build Sealed output).

1. Change files in the source folder (an unzipped Extract).
2. Zip **only the changed files**, with paths from the project root
   (`Modules/Admin/X.psm1`, `VERSION.txt`, `CHANGELOG.txt` ...). Include
   `VERSION.txt` and `CHANGELOG.txt` so the title and Version History move on.
   Optional `UPDATE.txt` directives:
   - `Delete: Modules/Admin/Old.psm1` — remove a file (one line per file).
   - `Mode: Partial` — merge even if `_AppLauncher.ps1` is in the zip (without
     it, a zip containing `_AppLauncher.ps1` is treated as a FULL package and
     replaces everything). `Mode: Full` forces a full replace.
   A zip whose entries all sit under one folder (`MyApp/...`) is read as if
   zipped from inside that folder.
3. In the dev EXE: **Update** → choose a **zip file** or a **folder** (an
   unzipped update or Extract) → review the preview (ADD / MODIFY / DELETE) →
   **Apply**. The developer EXE recompiles itself and archives the old one.
   Then run **Build Sealed** again to mint an updated distributable.

Bump `VERSION.txt` for anything you want tracked in titles/history.

An update that has no `AppIdentity.json` keeps the project's identity; one that
would change it asks first (a new AppDataFolder starts without the saved
environments and logs).

## Moving a project to a newer template: Update Template (developer build)

1. In the **template's** developer EXE, the newest `Archive\Zip\AppTemplate_v<ver>_t<ver>.zip`
   is the template source (written automatically after every template update).
2. In the **project's** developer EXE: **Update Template** → choose that zip →
   review the summary and the preview → **Apply**.

Only the files the template's `TEMPLATE_FILES.txt` lists are replaced
(engine files the template no longer lists are deleted); `TEMPLATE_FILES.txt`
and `TEMPLATE_VERSION.txt` are copied. `VERSION.txt` gets the next patch number
and `CHANGELOG.txt` an `Engine synced vA -> vB` entry; then the EXE recompiles
and restarts as with Update. Project files are never touched.

It refuses (and changes nothing) when:

- the zip is not template source, or does not match its own `TEMPLATE_FILES.txt`;
- the zip is not newer than the project's template version;
- the step changes the contract: a new major or minor template version, or a
  `Contract:` note in a template CHANGELOG entry newer than the project's
  version. Those are manual syncs (project files must be adapted);
- the project's engine files differ from its own `TEMPLATE_FILES.txt` (local
  engine edits, which the sync would overwrite). Move them into the template
  or revert them first.

Versioning: `1.0.x` releases are engine-only and go through Update Template; a
new major.minor marks a contract change.

---

## Making it your own (new project)

Set the project's names in `AppIdentity.json` (project-owned, at the root):

```json
{
    "AppName": "App Template",
    "ExeName": "AppTemplate",
    "AppDataFolder": "AppTemplateData"
}
```

`AppName` is the window title, dialog title and EXE product name; `ExeName`
names the EXE, the archive and Extract zips; `AppDataFolder` is
`%LOCALAPPDATA%\<AppDataFolder>` (it can be an innocuous name). `AppHost.cs`
and the builder read it; nothing else needs renaming. Then make the
project's own files:

| Project-owned file | What goes in it |
|---|---|
| `AppIdentity.json` | AppName, ExeName, AppDataFolder |
| `VERSION.txt`, `CHANGELOG.txt` | 1.0.0, "Created from AppTemplate vX" |
| `Modules\Lite\*`, `Modules\Admin\*` | the features (user / admin tier) |
| `Modules\Base\UI_Register-Tabs.psm1` | the tab list and order |
| `Modules\Base\UI_Tab_Overview.psm1` | the Overview text |
| `Config\Environments.json` | the starting environments |
| `Config\EnvironmentFields.json` | the General page's text fields |
| `Config\SharedScope.json` | only when porting a tool whose modules shared one `$script:` scope |

Keep `TEMPLATE_VERSION.txt` and `TEMPLATE_FILES.txt` as they come from the
template. Keep the `// @reference:` lines at the top of `AppHost.cs` for any
extra DLLs.

## Template version and drift

- `TEMPLATE_VERSION.txt` - the AppTemplate version this project's engine is
  on. Shown in the status bar (e.g. `v1.2.9  (template 1.0.15)`), the Version
  History title, Environment.txt, FunctionMap.txt, and logged at every start.
- `TEMPLATE_FILES.txt` - every template-owned file with its SHA-256 for that
  version. The developer build checks them on every start; a changed
  template-owned file shows as `(template 1.0.14, N changed)` in the status
  bar and is listed in Session.log. That change belongs in the template (or
  should be reverted) - it would be overwritten by the next template sync.
- Template-owned files are byte-identical in every project, `AppHost.cs`
  included (the project's names live in `AppIdentity.json`). The check covers
  every listed file; `AppHost.cs`, `Build-App.ps1` and `Build-App.cs` through
  the copies embedded in the developer EXE.
- To bring a project up to a newer template, use **Update Template** (above).
  A contract change (new major.minor, or a `Contract:` note) is a manual sync:
  replace the template-owned files, adapt project files as the CHANGELOG
  says, and update both TEMPLATE_* files.

---

## After every update (developer build, automatic)

A few seconds after the developer EXE starts, if it changed since the last
run (an Update or a Build-App rebuild), it writes - in the background, status
bar shows progress - beside itself:

```
<ExeName>.exe                                developer build (this one)
<ExeName>Lite.exe                            sealed TEST build - admin password "a", user password "u"
Build-App.exe                                the builder (from Build-App.cs; rebuilt when that changes)
Update\                                      default place for update zips
Archive\Exe\<ExeName>_v<ver>_t<template>.exe  copy of each version's developer EXE (rollback)
Archive\Zip\<ExeName>_v<ver>_t<template>.zip  full source of each version (upload this to Claude)
Archive\archive.state                        what was archived / built last
```

Same version + template = same name, so a rebuild of the same version
overwrites; a new version or template adds a file. The Lite EXE shares the
developer build's AppData (environments, logs) - handy for testing; for a real
distributable use **Build Sealed** with real passwords. If `<ExeName>Lite.exe`
is running it cannot be replaced; that is logged and retried on the next start.
Each step is saved as it finishes, so closing the app mid-way (it asks first)
resumes on the next start; Session.log lines are tagged `[Archive]`.

## Troubleshooting a user's machine

Ask for `Session.log` (`<data root>\Logs`, usually
`%LOCALAPPDATA%\<AppDataFolder>\Logs`). Every start writes two lines:

```
[Startup] Launched tier=User v1.2.3 template=1.0.19 env='Default' root=Network
[Startup] System: os='Windows Server 2019 Standard 1809 build 17763.6414' ps=5.1.17763.6414 net=4.8 x64/x64
```

then one `[Requirements]` line per declared dependency (`OK ActiveDirectory
1.0.1.0 (User Lookup)` or `MISSING ...` with the reason and the fix), and any
errors with their full detail.

## Where things live at runtime

```
%LOCALAPPDATA%\AppTemplateData\
  Config\          read-only mirror of the embedded config (refreshed each launch)
  Logs\            Session.log + <ENV>.log   (or on the shared path if reachable)
  Settings\        Environments.json (the saved environments, per machine) and
                   settings modules save at runtime (Get-AppSettingsDir); persistent
  Extract\         Extract and Build Sealed outputs
  active.env       the environment you last picked on this machine (just a name)
```

The only things ever written on a runtime machine are the **picked environment**
and the **logs/data** under the resolved root. The EXE is written only by the
developer actions (first build, Update, Build Sealed).
