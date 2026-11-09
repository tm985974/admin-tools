# admin-tools

PowerShell admin tools that compile to single portable EXEs, all built on one shared
engine, **AppTemplate**. Every tool's engine files are byte-identical to the template
version it is on. The template's `TEMPLATE_FILES.txt` lists those files with their hashes,
and an automatic check on every push makes sure that stays true.

```
template/                 AppTemplate - the engine every project is based on
projects/
  ADUserLookup/           AD user lookup and audit
  CCMClientTS/            CCM client troubleshooting
  CommandLibrary/         script / command library
  PDubPaste/              password paste tool
  RadminLicense/          Radmin license management (OldScript/ = the original scripts)
  RSLinxDriverManager/    RSLinx driver manager
  SCCMAppManager/         SCCM application manager
tools/                    repo tools (PowerShell 5.1+)
.github/workflows/        automatic checks
```

Each folder has the same layout as an Extract, so `Build-App.cmd` / `Build-App.exe` and the
developer EXE work straight from the checkout. Each project's own `README.md` and
`template/README.md` describe the engine in detail.

## What lives where

| | Where |
|---|---|
| Source (current) | this repo, `main` |
| Every past version | git history; tags like `ADUserLookup/v1.2.17`, `template/v1.0.23` |
| Developer EXE, Lite EXE, `Archive\`, `Update\` | on your machine only (ignored by git) |
| Sealed distributable | build it with **Build Sealed**; attach to a GitHub Release if you want a copy here |

Never commit or upload a developer EXE: it contains the source. Never put the sealed
passwords in the repo.

## Everyday work on a project

1. Edit files in `projects/<Name>/`.
2. Bump `VERSION.txt` and add a `CHANGELOG.txt` entry (newest first, `vX.Y.Z (date)  title`).
3. Build with `Build-App.cmd` (or the developer EXE's **Update** > Folder pointed at the project folder).
4. Commit and tag the release:

   ```
   git commit -am "ADUserLookup v1.2.18: <what changed>"
   git tag -a ADUserLookup/v1.2.18 -m "ADUserLookup v1.2.18"
   git push --follow-tags
   ```

To update a developer EXE on a machine without git, make an update zip from what changed
since the last tag and use it with the **Update** button as before:

```
powershell -ExecutionPolicy Bypass -File tools\New-UpdateZip.ps1 -Project ADUserLookup
```

## Improving the engine (template)

Engine files are only ever changed in `template/`. A change made in a project is drift: the
check fails, and the next sync would overwrite it.

1. Edit the template-owned files in `template/`. Bump `template/VERSION.txt` **and**
   `template/TEMPLATE_VERSION.txt`, and add a `CHANGELOG.txt` entry. Use `1.0.x` for engine-only
   changes. Use a new major.minor, or a `Contract:` line in the entry, when projects must change too.
2. Regenerate the manifest (never edit hashes by hand):

   ```
   powershell -ExecutionPolicy Bypass -File tools\Update-TemplateManifest.ps1
   ```

   Add `-Add Modules/Base/NewThing.psm1` to start owning a new engine file.
3. Sync every project in the same change:

   ```
   powershell -ExecutionPolicy Bypass -File tools\Sync-Template.ps1 -DryRun
   powershell -ExecutionPolicy Bypass -File tools\Sync-Template.ps1
   ```

   This is what the developer EXE's **Update Template** does, for all projects at once. It
   skips (with the reason) projects with local engine edits and contract changes.
4. Check, rebuild the projects you use, then commit the template and the syncs together and tag:

   ```
   powershell -ExecutionPolicy Bypass -File tools\Test-Template.ps1
   ```

## Automatic checks (GitHub Actions)

- **Template check** (every push): `tools/Test-Template.ps1`. It fails on a stale template
  manifest, engine drift in any project, version / changelog mismatches, or two projects
  sharing an ExeName or AppDataFolder. Projects behind the template are listed as warnings.
  The run summary shows a table of every project and its template version.
- **Build** (code pushed to `main`, or by hand from the Actions tab): compiles every
  developer EXE on Windows to prove the source builds. Nothing is published.

## Starting a new project

1. Copy `template/` to `projects/<ExeName>/`.
2. Set `AppIdentity.json` (AppName, ExeName, AppDataFolder - unique per project).
3. Set `VERSION.txt` to `1.0.0` and start `CHANGELOG.txt` with
   `v1.0.0 (date)  Created from AppTemplate v<x>`.
4. Replace the template's example tabs in `Modules/Lite/`, `UI_Register-Tabs.psm1`,
   `UI_Tab_Overview.psm1` and `Config/*.json` (see `template/README.md`, "Making it your own").
