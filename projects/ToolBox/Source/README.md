# ToolBox

One place to run, build and update the admin tools in `admin-tools\projects`.
Built on AppTemplate (see `template\Source\README.md` for the engine).

| Tab | What it does |
|---|---|
| **Tools** | Every tool with its version. **Launch** runs the tool's sealed EXE when the environment's *Sealed EXE folder* holds `<ExeName>.exe`, otherwise its Lite (test) EXE. |
| **Developer** | Source version vs the built developer EXE, and whether a tool needs a build. **Build selected / Build all** run each tool's `Build-App.cmd` here, one at a time, output in the log pane. Running tools are skipped; ToolBox cannot rebuild itself while it runs. |
| **Update** | **Open zip...** a zip of the repository downloaded from GitHub, see what changes, **Apply update** (each tool's `Source\` replaced, the old one kept in `_Backup\Update_<time>`), then build all. **Pull (git)** when the folder is a git clone. |

Environment fields: **Projects folder** (blank = the folder ToolBox is in, i.e.
`admin-tools\projects`) and **Sealed EXE folder** (optional).

First build: double-click `Build-App.cmd` in this folder (or `Build-All.cmd` at the
top of the repository). After that, ToolBox builds the other tools; to rebuild
ToolBox itself, close it and run its `Build-App.cmd`.
