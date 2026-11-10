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

## Project folder layout (template 1.1)

Only the files you open sit at the top of a project folder; everything else is in
sub folders:

```
<Project>\
  <ExeName>.exe          developer build
  <ExeName>Lite.exe      sealed test build (admin "a", user "u")
  Build-App.cmd          builds the two EXEs from Source\
  Source\                the source: AppHost.cs, _AppLauncher.ps1, AppIdentity.json,
                         VERSION.txt, CHANGELOG.txt, TEMPLATE_*.txt, README.md,
                         Config\, Modules\, Build-App.cs, Build-App.ps1
  Build\                 Build-App.exe (written by Build-App.cmd and the developer EXE)
  Archive\  Update\      made by the developer EXE (see below)
```

Paths inside the app do not change: update zips, `Archive\Zip` zips, Extract and
`TEMPLATE_FILES.txt` use paths inside `Source\` (`AppHost.cs`, `Config/...`,
`Modules/...`), plus `Build-App.cmd`. Update and Update Template also accept a whole
project folder, or a zip of one (its `Source\` is read). A pre-1.1 flat folder (the
source at the top, no `Source\`) still builds and runs.

## First build (on Windows)

In the project folder, run one of these - they all do the same build:

| Builder | When |
|---|---|
| `Build-App.cmd` | double-click. Compiles `Source\Build-App.cs` into `Build\Build-App.exe` with the machine's `csc.exe`, then runs it. |
| `Build\Build-App.exe` | double-click. The developer EXE writes it after every update, so a machine that has one never needs the script. |
| `Source\Build-App.ps1` | where PowerShell scripts may run. Same as the `.cmd`. |

To build from an Extract (a zip of `Source\` contents), unzip it into a `Source`
folder, put `Build-App.cmd` beside that folder (it is in the zip too) and run it.

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
  Session.log size, diagnostics) and **Commands** (all environments: when the
  command window is shown before running). Then one sub-tab per page a project adds
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

## Engine helpers for module code (v1.0.21)

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
| Hover help on a button / menu item / tab (v1.0.21) | an entry in `Config\ToolTips.json` - nothing to call (see *Hover help*). In code: `Set-AppToolTip -Control $c -Text '...'` |
| Run a command and let the user see / copy its exact syntax first (v1.0.21) | build the code as text with `Format-AppCommandValue`, then `Invoke-AppCommand -App $App -Title ... -Kind Change -Code $code` (or `-Kind Read`) (confirm + log + run that text) or `Confirm-AppCommand` (confirm + log only). Right-click Show / Copy command on a button: `Register-AppCommand -App $App -Control $btn -Code { <code text> }` (`Services_Commands.psm1`; Tab 1 "Open data root" is the example) |

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

### Hover help (template rule, v1.0.21)

Everything you can click - buttons, check boxes, radio buttons, link labels,
menu items (right-click menus too) and tabs - should say what clicking it does.
The texts are kept in one catalog, not in the modules:

- engine entries in `Base\Services_ToolTips.psm1` (developer buttons,
  Environment tab, common buttons such as OK / Cancel / Close / Export CSV);
- `Config\ToolTips.json` (project-owned) for the project's own controls. An
  entry there wins over an engine entry.

```json
{ "ToolTips": {
    "Refresh":                  "any 'Refresh' button without a more specific entry",
    "Computers > Refresh":      "the Refresh button on the Computers tab",
    "Tools > Ping List > Ping": "a button on a sub-tab",
    "Ping Computers > Copy":    "a button in the dialog titled 'Ping Computers'",
    "Tools > Ping List":        "the sub-tab itself"
} }
```

The key is the control's text, optionally preceded by where it is (tab / sub-tab
/ group box titles, outermost first, or the dialog title). Case, `&` and a
trailing `...` are ignored; the most specific key wins and any "where" part may
be left out. Menu items take the place of the control the menu belongs to. The
launcher starts it once (`Start-AppToolTips`); a light timer picks up dialogs,
lazy tabs and menus as they appear - modules call nothing. `Set-AppToolTip` sets
one in code. **Developer build:** every clickable control with no entry is
listed, ready to paste, in `<data root>\Logs\ToolTips_missing.txt` (and counted
in Session.log), so coverage can be completed as features are added.

### Showing the exact command (template rule, v1.0.21)

Anything that runs a script builds the PowerShell it will run **as text with
the real values** and goes through `Services_Commands.psm1`:

```powershell
$code = 'Unlock-ADAccount -Identity {0} -Server {1}' -f (Format-AppCommandValue $sam), (Format-AppCommandValue $dc)
$r = Invoke-AppCommand -App $App -Title 'Unlock Account' -Kind Change -Code $code -Summary "Unlock $sam?"
if ($r.Ran -and $r.Errors.Count -eq 0) { ... }
```

`Invoke-AppCommand` shows the command window when it should, logs the command
and runs **that same text**, so what was shown is what ran. The window has the
title, the summary, the code (read-only, selectable), **Copy** and **Run /
Cancel** - for a change it is the confirmation itself (replace a module's own
confirm dialog with it rather than adding a second popup; Enter never runs a
change). `Confirm-AppCommand` is the same without the run step, for code an
engine function runs itself. When it shows (Environment > General > Commands,
app-wide): **Always** (default, v1.0.22), **Changes** (only actions passed `-Kind Change`),
or **Never**; **Shift+click** shows it first whatever the setting.
`Register-AppCommand` gives a button a right-click **Show command... / Copy
command** (nothing is run) and its tooltip says so. Every confirmed command is
logged (`[Command] Run : <title>`; the code as DIAG with diagnostics on).

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

1. Change files in the project's `Source\` folder.
2. Zip **only the changed files**, with paths from inside `Source\`
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

## Template rules (every project)

Every project built on this template follows these rules. `tools\Test-Template.ps1`
(run on every push in the admin-tools repository) checks them, and a push that breaks
one fails the check.

### 1. Every action shows its code first

Anything that runs a command against the system goes through the command engine
(`Base\Services_Commands.psm1`): a script, cmdlet or program that changes something,
starts something (RDP, Explorer, a console, an elevated copy), or reaches another
computer or server. The command window shows the exact PowerShell, with the real values
filled in, plus Copy and Run / Cancel, and the command is logged.

| Use | When |
|---|---|
| `Invoke-AppCommand -Code $text` | the action IS the code shown: it runs that same text |
| `Confirm-AppCommand -Code $text`, then run | the work happens in tested module code (retries, progress, waits); `$text` is the equivalent PowerShell |
| `-Kind Change` / `-Kind Read` | changes something / only reads or launches (Environment > Commands decides when each kind is shown) |
| `-Always` | always ask, whatever the setting: deletes, reboots, anything that used to have its own Yes/No box |

- Build the text with `Format-AppCommandValue`, so it runs exactly as shown.
- **Never put a secret in the code.** A password or key appears as a placeholder:
  `Format-AppCommandValue` turns a SecureString into a `Read-Host` prompt.
- The command window replaces the action's own Yes/No box, so there is never a second
  popup. A `MessageBox` with YesNo / OKCancel buttons is flagged by the check. When one
  is not about running a command (a list edit, an overwrite question, a gate before
  the command window), end its line with `# not-a-command: <why>`.
- Not covered: the app's own data (saving settings, editing its tables or lists),
  filtering, selecting, copying to the clipboard, and read-only loads of the data a
  tab shows.

### 2. Every clickable control has hover help

Every button, check box, radio button, link, menu item and tab has a tooltip from the
catalog: the engine entries in `Base\Services_ToolTips.psm1` plus the project's
`Config\ToolTips.json` (required in every project).

- The key is the control's text, optionally with where it is (`Tab > Sub-tab > Text`, or
  `Dialog title > Text`). In a key, `&&` is a literal `&` and a trailing `...` is ignored.
- A control text cannot contain `>` (it separates places in a key).
- A control without text, or one whose text changes at run time, gets its tooltip in
  code with `Set-AppToolTip`. A menu that belongs to no control, such as a tray icon
  menu, is handed to the engine with `Register-AppToolTipMenu` once the catalog is
  loaded (see PDubPaste's `UI_PwWindow.psm1`).
- An empty entry (`"Some button": ""`) means "no tooltip on purpose".
- The check reads every caption written as a literal in the modules. The developer
  build also lists controls it met with no entry in `<data root>\Logs\ToolTips_missing.txt`.

---

## Making it your own (new project)

Set the project's names in `Source\AppIdentity.json` (project-owned):

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
| `Config\ToolTips.json` | hover help for the project's buttons, menu items and tabs |

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
bar shows progress - in its project folder:

```
<ExeName>.exe                                developer build (this one)
<ExeName>Lite.exe                            sealed TEST build - admin password "a", user password "u"
Build\Build-App.exe                          the builder (from Build-App.cs; rebuilt when that changes)
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
