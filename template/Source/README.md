# App Template — portable PowerShell project shell

A reusable starting point for self-contained PowerShell tools that compile to a
single, portable `.exe`. It is the engine extracted from a working admin tool,
with all of the domain-specific logic removed. Nothing here is tied to Active
Directory or any particular task — the placeholder names are expected to be
renamed when you start a real project.

---

## Two builds from one source

| | **Developer build** `<ExeName>Dev.exe` | **Sealed build** `<ExeName>Lite.exe` (the one to hand out) |
|---|---|---|
| How you get it | `Build-App.cmd` | `Build-App.cmd` (it asks for the passwords), or **Build Lite** in the developer build |
| Embedded C# source (`core.dat`) | yes | **no — omitted** |
| Module package | plaintext, all tiers | **two AES-256 bundles, per-tier** |
| Password to run | none | **yes — at launch** |
| Dev tooling (Build Lite / Version History / Open ▾ / More ▾) | yes | no |
| Requirement checks + machine facts in Session.log | yes | yes |
| Tabs (Overview, Tab 1-4, Environment) | yes | yes |
| Create / edit environments (Environment tab) | yes, saved in `Source\Config\Environments.json` | admin password only, saved on that machine (user password: pick only) |
| Admin-tier tabs/modules | yes (all tiers loaded) | only with the admin password |

**Never hand out the developer build** — it contains your source. Hand out only
`<ExeName>Lite.exe`, the sealed build. Its passwords are asked every time it is
built (there are no built-in test passwords; for testing, use simple ones).

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

Use distinct user and admin passwords (Build Lite enforces this).

---

## Project folder layout (template 1.1)

Only the files you open sit at the top of a project folder; everything else is in
sub folders:

```
<Project>\
  <ExeName>Dev.exe       developer build (no password)
  <ExeName>Lite.exe      sealed build to hand out (user / admin password)
  Build-App.cmd          builds the two EXEs from Source\
  Source\                the source: AppHost.cs, _AppLauncher.ps1, AppIdentity.json,
                         VERSION.txt, CHANGELOG.txt, TEMPLATE_*.txt, README.md,
                         Config\, Modules\, Build-App.cs
  Build\                 Build-App.exe (compiled by Build-App.cmd each time)
  Archive\  Update\      only if you use More > Archive / Update (see below)
```

Paths inside the app do not change: update zips, Extract zips and
`TEMPLATE_FILES.txt` use paths inside `Source\` (`AppHost.cs`, `Config/...`,
`Modules/...`), plus `Build-App.cmd`. A pre-1.1 flat folder (the source at the top,
no `Source\`) still builds and runs.

## Building (on Windows)

Double-click `Build-App.cmd` in the project folder - the one way to build (template
1.2 removed `Build-App.ps1`). It compiles `Source\Build-App.cs` into
`Build\Build-App.exe` with the machine's `csc.exe` and runs it:

1. builds `<ExeName>Dev.exe`, the developer build;
2. asks for the Lite user and admin passwords, each twice (press Enter at the first
   prompt to skip), and builds `<ExeName>Lite.exe`, the sealed build.

Options (passed on to `Build-App.exe`): `-Output <path\Name.exe> -NoLite -NoPause`.
`Build-App.exe -All <projects folder>` builds every project in the folder and asks
for the passwords once (the repository's `Build-All.cmd` uses it). A caller can pass
the passwords in the environment variables `APPTEMPLATE_LITE_USER` /
`APPTEMPLATE_LITE_ADMIN` (ToolBox does, for Build all).

Requirements: .NET Framework 4.x (`csc.exe`) and Windows PowerShell 5.1
installed (its DLL is referenced; no script runs). If AV quarantines the fresh
EXE, exclude the output folder from real-time scanning.

### Make the distributable

1. Run `Build-App.cmd` and type the passwords, or click **Build Lite** in
   `<ExeName>Dev.exe`.
2. Either writes `<ExeName>Lite.exe` in the project folder.
3. Hand that EXE out. Give operators the user password; keep the admin password.

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

## Environments: where they are saved

One file per EXE (template 1.2):

| EXE | Saved in | Notes |
|---|---|---|
| `<ExeName>Dev.exe` | `Source\Config\Environments.json` | The project's own file: New / Save / Delete on the Environment tab write it directly. Commit it; the next Build Lite ships it. |
| `<ExeName>Lite.exe`, admin password | `%LOCALAPPDATA%\<AppDataFolder>\Settings\Environments.json` | Per machine (a sealed EXE cannot change itself), over the built-in set. Built-in environments deleted here are listed under `Removed`. |
| `<ExeName>Lite.exe`, user password | - | Pick only. |

Before 1.2 the developer build kept its own copy in AppData and also wrote a
`Config\Environments.json` beside the EXE. On its first start, the 1.2 developer
build moves a leftover `<Project>\Config\Environments.json` into
`Source\Config\` (keeping the replaced file as `Environments.json.bak`) and
removes the empty folder; review the change with git and commit it.

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
meaningful. It is `Config\FunctionMap.txt` in every Extract and Archive
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

## Everyday work

The source lives in git (the admin-tools repository). Edit `Source\`, bump
`VERSION.txt` and add a `CHANGELOG.txt` entry, build with `Build-App.cmd` (or
ToolBox), commit. Engine changes are made in `template\` and synced to every
project with `tools\Sync-Template.ps1` (see the repository README).

The developer toolbar: **Build Lite**, **Version History**, **Open ▾** (the app
folder, the Source folder, the Logs folder in use, AppData) and **More ▾**.

## The zip tools: More ▾ (developer build, manual)

From before git; kept for when you need them. Nothing here runs on its own.

- **Update from a zip or folder...** - apply changed source files and recompile
  this EXE. Zip only the changed files with paths from inside `Source\`
  (`Modules/Admin/X.psm1`, `VERSION.txt`, `CHANGELOG.txt` ...). Optional `UPDATE.txt`
  lines: `Delete: <path>` removes a file; `Mode: Partial` / `Mode: Full` (a zip
  holding `_AppLauncher.ps1` is a full replace unless it says `Partial`). A zip
  whose entries all sit under one folder is read as if zipped from inside it; a
  whole project folder (or a zip of one) works too. You see a preview (ADD /
  MODIFY / DELETE) before **Apply**; the old EXE goes to `Archive\Exe`. An update
  without `AppIdentity.json` keeps the project's identity; one that would change
  it asks first. The picker opens in the `Update` folder beside the EXE.
- **Update Template from a template zip...** - move this project's engine files to
  a newer AppTemplate (a zip of the template's source: its Extract or Archive zip).
  Only the files the template's `TEMPLATE_FILES.txt` lists change (engine files it
  no longer lists are deleted); `VERSION.txt` gets the next patch number and
  `CHANGELOG.txt` an `Engine synced vA -> vB` entry; then the EXE recompiles.
  Refused (nothing changes) when the zip is not template source or does not match
  its own manifest, is not newer, changes the contract (new major.minor, or a
  `Contract:` note), or this project's engine files differ from its manifest.
- **Extract source zip** - the full source of this build, plus
  `Config\FunctionMap.txt` and `Config\Environment.txt` (machine facts and the
  installed-module list), to `AppData\Extract`.
- **Archive this version** - `Archive\Exe\<ExeName>_v<ver>_t<template>.exe` (a copy
  of this EXE) and `Archive\Zip\<ExeName>_v<ver>_t<template>.zip` (its source).
  Git keeps every version, so this is only for a copy outside git. (Before 1.2
  this ran automatically on every start after a change.)

Versioning: `1.x.y` patch releases are engine-only; a new major.minor marks a
contract change.

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
  on. Shown in the status bar (e.g. `v1.2.9  (template 1.2.0)`), the Version
  History title, Environment.txt, FunctionMap.txt, and logged at every start.
- `TEMPLATE_FILES.txt` - every template-owned file with its SHA-256 for that
  version. Template-owned files are byte-identical in every project, `AppHost.cs`
  included (the project's names live in `AppIdentity.json`).
- Drift (a changed engine file in a project) is caught by the check on every push
  to GitHub (`tools\Test-Template.ps1`). Before 1.2 the developer EXE also checked
  on every start; that duplicate is gone. Update Template still refuses to run over
  local engine edits.
- A contract change (new major.minor, or a `Contract:` note) is a manual sync:
  replace the template-owned files, adapt project files as the CHANGELOG says, and
  update both TEMPLATE_* files.

---

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
  Config\          read-only mirror of the built-in config (refreshed each launch)
  Logs\            Session.log + <ENV>.log   (or on the shared path if reachable)
  Settings\        settings modules save at runtime (Get-AppSettingsDir); persistent.
                   Lite EXE: also Environments.json (what an admin saved here)
  Extract\         More > Extract output
  active.env       the environment you last picked on this machine (just a name)
```

The only things ever written on a runtime machine are the **picked environment**,
the **logs/data** under the resolved root and, with the admin password, the
**environments** saved there. The EXEs are written only by `Build-App.cmd`, Build
Lite and More > Update.
