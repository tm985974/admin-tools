# Command Library

Every PowerShell command or function worth keeping, in one place: searchable,
explained (what it does, how to use it, where to run it, what it needs), and
runnable with a prompt for its settings. Built on AppTemplate 1.0.20 (the
engine sections below are the template's own documentation).

## Two kinds of entry

- **Commands** (flag *syntax*) - one command or a short script with fields: a
  syntax builder. The Run prompt shows the exact line as you fill it in;
  optional parts drop out when their field is empty or unticked. Copy it into a
  PowerShell window, a script or a GPO, or Run it here. The starting library has
  a command entry for every command the function entries use, plus a broad set
  for network, computer management and troubleshooting.
- **Functions** - bigger tasks that combine several commands (health reports,
  comparisons, installs, imports from your projects).

### Command template syntax

```
gpupdate[[ /target:{Target}]][[ /force{Force}]]
```

| In the template | Means |
|---|---|
| `{Name}` | the field's value; quoted only when needed (double quotes when safe, so the line also works in cmd) |
| `{Name:raw}` | the value exactly as typed |
| `{Name:q}` | always quoted - for a value used inside a PowerShell expression; empty gives `''` |
| `{Name:join=,}` | a one-per-line list joined with `,` (default `, `, a PowerShell array) |
| `[[ ... ]]` | optional part: left out when a field inside it is empty, or a switch inside it is off. A switch writes nothing itself: `[[ /force{Force}]]` adds ` /force` when ticked. A literal `]]` (as in `[byte[]]`) must sit outside it. |

The fields are a `param()` block (types, `[ValidateSet()]`, `[Parameter(Mandatory)]`,
defaults, `.PARAMETER` help in a comment above it) - the same inputs functions get.
When a command ends in `| Format-Table ...` the run uses `Select-Object` with the
same columns, so Grid and Export CSV get real columns while Results still shows
the table.

## Using it

- **Library tab** - type in Search, or pick a category. Search looks at the
  **name and keywords only** (keywords = tags + the command name), by whole
  words: every word you type must start a word of the name or a keyword, so
  `ping` finds *Ping* but not *mapping*. Best matches come first. Tick *Search
  descriptions too* to also search descriptions, notes and code. Details shows
  the description, status, how to use, where to run, requirements, parameters
  and an example; Code shows exactly what runs.
- **Status column** - will the entry work on THIS computer? Worked out in the
  background when the tab opens (a few seconds; the list shows *Checking...*):
  - *Ready* (green) - everything it calls is installed and the rights are there.
  - *Ready - via ...* (blue) - the main command is not installed here, but a
    fallback is (e.g. *LDAP query (no RSAT)* instead of `Get-ADUser`).
  - *Not on a domain* (amber) - AD commands on a workgroup computer; fill in
    Server / Domain.
  - *Missing: ...* / *Needs admin* (red) - it would fail. Details says what is
    missing and how to fix it (e.g. the RSAT capability to add).
  Tick *Runnable here only* to hide the red ones. Reload re-checks.
- **Run...** (or double-click / Enter) - a prompt built from the function's
  `param()` block. Mandatory parameters are bold with `*`. Values start from your
  last run of that entry, then from the active environment (parameters named
  `Domain`, `Server`/`DomainController`, `SearchBase` take the Environment tab
  values). The exact command is previewed; entries that change things ask first
  and tick WhatIf when the function supports it.
- **Run on these computers** - runs the entry through `Invoke-Command` on a list
  of computers (WinRM), optionally with other credentials; results get a
  `PSComputerName` column. Tip: run *Domain servers*, copy the
  names, paste them here.
- **Checks before a run** - the Run prompt shows a strip under the title: ready,
  which fallback it will use, or why it will fail (you can still *Run anyway*).
  *Check the target answers before running* (on by default) tests the computers
  typed into target fields (ComputerName, Server, DC ...) or the remote list
  first: DNS, then the TCP port the command uses - AD cmdlets 9389 (AD Web
  Services), CIM / remoting 5985, WMI / event logs 135, services / registry 445,
  LDAP 389. A host that does not answer is reported in about a second instead
  of a 30-90 second timeout; in a remote run it is skipped and the rest run.
  **Check now** does the same test without running anything. Commands whose
  job is testing connectivity (ping, Test-NetConnection, nslookup, nltest ...)
  are never blocked by it.
- **Fallbacks** - some entries carry other ways to do the same thing (*Fallback:*
  in Details). The first method whose commands exist here - and whose port
  answers on the target - runs. A read-only entry whose method fails for an
  environment reason (not installed, unreachable, access denied) moves on to the
  next; an entry that changes things never retries. Messages shows `[CHECK]` and
  `[METHOD]` lines saying what was tested and which method ran.
- **Output** - Results (as the console shows them), Grid, Messages (errors,
  warnings, verbose, Write-Host, WhatIf). Stop, Copy, Export CSV. A failure
  ends with a `[WHY]` line in plain words: *Software* (not installed),
  *Connectivity* (port / DNS / WinRM / RPC), *Rights* (access denied, needs
  admin), *Auth* (credentials / Kerberos), *Input* (a value matched nothing),
  *Policy* (execution policy).

Nothing ever launches a `.ps1` or another PowerShell: each run is a fresh
background runspace inside the app. `Read-Host`, `Get-Credential` and `-Confirm`
prompts fail with a clear message instead of hanging - give those values as
parameters.

## Adding to the library (admin password / developer build)

- **Import tab** - pick another project (its Extract zip, an `Archive\Zip\*.zip`,
  the folder) or module files and **Scan**. Files are parsed, never run. Each
  top-level function is shown as:
  - **Ready** - runs on its own; any helper functions it calls are bundled in.
  - **Review** - read the note first (waits for input, uses a variable it never
    defines, calls a command not found on this machine, calls `exit`).
  - **Blocked** - tied to its project: builds UI, uses `$App`, reads module
    `$script:` state it never sets, or launches a `.ps1`. Cannot be checked.
  Check entries, pick a category, **Add checked to library**. Imported code is a
  snapshot (project, version, file, hash). Scan again after the project changes:
  entries show **Changed**, and **Update changed** replaces the code but keeps
  your descriptions.
- **New... > Command** - write the template, click *Add missing fields*, set
  each field's type / choices / default and its `.PARAMETER` help; the preview
  fills the template with the defaults.
- **New... > Function / Edit...** - paste a function (from a chat, say) into Code, click
  **Analyze**, then **Fill from help** or write the description. A function with
  comment-based help (`.SYNOPSIS`, `.DESCRIPTION`, `.PARAMETER`, `.EXAMPLE`,
  `.NOTES`) fills most fields. Asking Claude for "a Command Library entry for
  this" gets you exactly that.

### Fallbacks and readiness fields (in Library.json)

| Field | Means |
|---|---|
| `Methods` | fallbacks, tried in order: `[{ "Label": "LDAP query (no RSAT)", "Template": "..." }]`. A template using the entry's own fields (same syntax as a command template). |
| `Elevation` | `""` = worked out from the commands and *Where to run*; `"Required"` or `"No"` to override. |
| `Ports` | extra TCP ports to check on the target, when the commands alone do not say. |

Everything else (which commands an entry calls, which module or tool provides
them, which port they use) is read from the code itself - a new entry gets a
status without any extra fields.

## Where the library lives

| File | What |
|---|---|
| `<data root>\Settings\Library.json` | the library. The data root follows the environment: give it a shared *Log & data path* and the team shares one library. A `.bak` of the previous save sits beside it. |
| `Config\Library.json` (in the EXE) | the starting set. On start, shipped entries you do not have are added; ones you deleted stay deleted; a shipped entry with a higher Revision replaces yours unless you edited it. |
| `%LOCALAPPDATA%\CommandLibraryData\Settings\LibraryLastValues.json` | the Run prompt's last values, per user. Never credentials. |
| `Logs\<ENV>.log` | one line per run with the command line (never credentials), plus library edits. |

## Project files

| File | Tier | What |
|---|---|---|
| `Modules\Lite\Services_FunctionAnalysis.psm1` | Lite | parameters / help / call text from the parser (AST) |
| `Modules\Lite\Services_Library.psm1` | Lite | Library.json store, search, shipped-set merge, last values |
| `Modules\Lite\Services_CommandTemplate.psm1` | Lite | command entries: template rendering, field handling, entry-kind helpers |
| `Modules\Lite\Services_Runner.psm1` | Lite | background runspace runner + capturing host, fallback / pre-check plan |
| `Modules\Lite\Services_Readiness.psm1` | Lite | will it run here: software / rights / domain scan, target port checks, fallback choice, failure reasons |
| `Modules\Lite\UI_Tab_Library.psm1` | Lite | the Library tab |
| `Modules\Lite\UI_RunDialog.psm1` | Lite | the Run prompt and credential dialog |
| `Modules\Admin\Services_Extractor.psm1` | Admin | reads projects, bundles helpers, Ready/Review/Blocked |
| `Modules\Admin\UI_Tab_Import.psm1` | Admin | the Import tab |
| `Modules\Admin\UI_EntryEditor.psm1` | Admin | New / Edit function entry dialog |
| `Modules\Admin\UI_CommandEditor.psm1` | Admin | New / Edit command entry dialog (template, fields, preview) |
| `Config\Library.json` | - | starting library |
| `AppIdentity.json` | - | the project's names: AppName, ExeName, AppDataFolder (read by `AppHost.cs` and the builder) |

## Engine (AppTemplate)

Building, the Dev / Lite EXEs, passwords, environments, tiers, logging, hover help
and the command window are the template's and the same in every tool: see
[`template/Source/README.md`](../../../template/Source/README.md) in the admin-tools
repository. Build with `Build-App.cmd` in the project folder: it makes
`CommandLibraryDev.exe` (developer build, never hand it out) and, with the passwords you
type, `CommandLibraryLite.exe` (the sealed build to hand out).
