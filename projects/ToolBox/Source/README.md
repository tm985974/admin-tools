# ToolBox

One place to run, build and update the admin tools in `admin-tools\projects`.
Built on AppTemplate (see `template\Source\README.md` for the engine).

| Tab | What it does |
|---|---|
| **Tools** | Every tool's `<ExeName>Lite.exe`, the sealed build (asks for the user or admin password). **Launch** starts it. |
| **Developer** | Source version vs the built developer EXE (`<ExeName>Dev.exe`), and whether a tool needs a build. The Lite passwords are asked once per batch. **Build selected / Build all** run each tool's `Build-App.cmd` here, one at a time, output in the log pane. Running tools are skipped; ToolBox cannot rebuild itself while it runs. |
| **Update** | **Open zip...** a zip of the repository downloaded from GitHub, see what changes, **Apply update** (each tool's `Source\` replaced, the old one kept in `_Backup\Update_<time>`), then build all. **Pull (git)** when the folder is a git clone. |

Environment field: **Projects folder** (blank = the folder ToolBox is in, i.e.
`admin-tools\projects`).

First build: double-click `Build-App.cmd` in this folder (or `Build-All.cmd` at the
top of the repository). After that, ToolBox builds the other tools; to rebuild
ToolBox itself, close it and run its `Build-App.cmd`.
