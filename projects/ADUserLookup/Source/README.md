# AD User Lookup — on the portable template

AD Admin 1.6.1 rebuilt on the portable template. It builds `ADUserLookupDev.exe`
and `ADUserLookupLite.exe` (see *Engine* below); the AD specifics are:

- **User Lookup** tab (Lite tier) — the AD user search; what the **user
  password** gets.
- **Users / Groups / Account Management / Computers / Bulk Operations /
  Infrastructure / Tools / Audit** (Admin tier) — every AD Admin 1.6.1 area,
  ported with its modules unchanged; what the **admin password** gets.
- **Environment** — the 1.6.1 Domain Defaults: one saved environment per
  domain. Sub-tabs **General** (name, log & data path, filter-as-you-type,
  log sizes, diagnostics), **Domain** (DNS name, optional DC, live connection
  + Test), **Accounts** (naming, UPN, home drive, OUs, bulk patterns),
  **Mail** (SMTP server / port / from) and **Messages** (welcome + 4
  Additional Info). New / Delete / Save with the admin password.
- **Environments = domains** (`Config\Environments.json` ships AERAIPCS.COM
  and CA1-OG.ADS with their 1.6.1 settings; the developer build saves into it,
  a Lite EXE with the admin password saves per machine).
- Identity in `AppIdentity.json`: AppName `AD User Lookup`, ExeName
  `ADUserLookup`, AppData folder `ADUserLookupData`.
- Logs: `Logs\Session.log` (through the host, like every tool) plus one action
  log per domain, `Logs\<DOMAIN>.log` (Write-OperationLog; the Audit views read it).

### How the port is wired

- The 1.6.1 modules live in `Modules\Admin` **verbatim** (one rename:
  `Services_Logging` → `Services_ADLogging`, because the template already has a
  `Services_Logging`). They are combined into one shared-scope module in the
  original load order (`$SharedScopeOrder` in `_AppLauncher.ps1`).
- `AD_Core.psm1` replaces the old launcher: paths, logging start-up,
  `Set-Status` (→ status bar), one shared `$Context` for every AD tab
  (`Get-ADSharedContext`), mail defaults, and reconnect on environment change.
  It connects right after the window opens and builds Users, Groups, Account
  Management and Computers in the background.
- `AD_Environment.psm1` builds the Environment tab's Domain / Accounts / Mail /
  Messages pages. `Services_DomainDefaults_Config` (1.6.1) now reads and
  writes the environment records, so every 1.6.1 caller (Create User,
  Offboard, Bulk Onboard, mail, logging, filters) uses the selected
  environment's values.
- `UI_*.psm1` in `Modules\Admin` are thin hosts that call the original
  `Register-*Tab` functions.
- Saved settings (environment settings, password word lists, logging) live in
  `<data root>\Settings`. Admin actions log to `Logs\<DOMAIN>.log` (Tools >
  Operation Log), as before.

The rest of this file is the template's generic guide (names shown as
`AppTemplate` map to `ADUserLookup` here).

## Engine (AppTemplate)

Building, the Dev / Lite EXEs, passwords, environments, tiers, logging, hover help
and the command window are the template's and the same in every tool: see
[`template/Source/README.md`](../../../template/Source/README.md) in the admin-tools
repository. Build with `Build-App.cmd` in the project folder: it makes
`ADUserLookupDev.exe` (developer build, never hand it out) and, with the passwords you
type, `ADUserLookupLite.exe` (the sealed build to hand out).
