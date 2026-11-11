# RSLinx Driver Manager

Builds the RSLinx Classic Ethernet (AB_ETH) drivers on a PC from the device
registry. Rewrite of the old `RSLinx Utility.ps1` on AppTemplate v1.0.20.

- **Drivers** tab: paste the device-registry CSV rows (or load the file) ->
  **Build preview** -> pick sites / edit -> **Add to this PC** or **Overwrite
  this PC**. Allen-Bradley devices only; Primary and Secondary IPs; one driver
  per site (Lease name -> 2-letter code, **Site Codes** tab) + VLAN, named `SITE(VLAN)DESCRIPTION` (max 15 characters),
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
| `Modules\Lite\UI_Tab_SiteCodes.psm1` | Site Codes tab |
| `Modules\Lite\UI_Tab_VlanLookup.psm1` | VLAN Lookup tab |
| `Modules\Lite\UI_Tab_RSLinx.psm1` | RSLinx tab |
| `Modules\Lite\UI_RSLinxCommon.psm1` | shared grid / header / filter-bar builders |
| `Modules\Lite\Services_DeviceImport.psm1` | CSV / paste parsing -> driver rows |
| `Modules\Lite\Services_SiteCodes.psm1` | Lease name -> site code table |
| `Modules\Lite\Services_VlanLookup.psm1` | lookup table, naming, IP helpers |
| `Modules\Lite\Services_RSLinxRegistry.psm1` | read / plan / write AB_ETH drivers |
| `Modules\Lite\Services_RSLinxBackup.psm1` | backup folder, save / list / read |
| `Modules\Lite\Services_SystemInfo.psm1` | installed software, PC facts |
| `Config\VlanLookup.json` | default VLAN lookup table |
| `Config\SiteCodes.json` | default site codes |

## Engine (AppTemplate)

Building, the Dev / Lite EXEs, passwords, environments, tiers, logging, hover help
and the command window are the template's and the same in every tool: see
[`template/Source/README.md`](../../../template/Source/README.md) in the admin-tools
repository. Build with `Build-App.cmd` in the project folder: it makes
`RSLinxDriverManagerDev.exe` (developer build, never hand it out) and, with the passwords you
type, `RSLinxDriverManagerLite.exe` (the sealed build to hand out).
