# Radmin License Manager

Offline activation of **Radmin Server 3** on air-gapped machines, built on
AppTemplate v1.0.20 (engine section below).

## The round trip

```
 air-gapped network                          |  internet PC
 ------------------------------------------- | -------------------------------
 1. Collect   rserver3 /saverequest          |
              -> <Transfer>\Requests\NAME.request ===>  2. https://activate.famatech.com/
                                             |     upload NAME.request
 3. Apply     <Transfer>\Licenses\NAME.license <===     save NAME.license
              rserver3 /uselicense, verify   |
```

Licensed = `HKLM\SOFTWARE\WOW6432Node\Radmin\v3.0\Shared\Parameters\XferParam\2`
exists (checked in the 64- and 32-bit registry views; a value named `2` under
`XferParam` also counts). No key = unlicensed.

## Tabs

| Tab | Use |
|---|---|
| **This Machine** | The PC the app runs on: status, **Save request**, **Apply license** (finds `<NAME>.license` or browse), Restart as administrator. For machines the network can't reach. |
| **Fleet** | From one admin PC: machine list (add / paste / import .txt/.csv), **Check status**, **Collect requests** (unlicensed only), **Apply licenses** (where a `.license` is waiting). WinRM, background, N at a time. |
| **Environment > Radmin** | License key, transfer folder, device folder (`C:\FAS`), rserver3 path, registry key, argument forms, timeout, parallelism. Admin password / developer build to edit. |

## Transfer folder

```
<Transfer>\
  Requests\NAME.request     outstanding - upload these
  Requests\_requests.csv    what was collected, when, from where
  Licenses\NAME.license     save the website's downloads here (keep the name)
  Done\                     request + license of licensed machines
  README-ACTIVATION.txt     website steps for whoever does them
```

Set per environment; a PC can override it (Change...) since a USB stick gets
a different drive letter on every machine.

## Requirements

- Run elevated (rserver3 needs admin to save a request / apply a license).
- Fleet reaches each machine one of two ways (**Connect via**, default Auto):
  - **WinRM** - PowerShell remoting, TCP 5985.
  - **Admin share + WMI** - where WinRM is off: the job is copied to
    `\\PC\C$\FAS\_rlm\<id>\`, started with WMI `Win32_Process.Create`
    (TCP 135 + RPC), the result read back over the share, and the job folder
    deleted. Needs TCP 445 and 135/RPC.
  - **Auto** tries WinRM, falls back to the admin share when WinRM can't
    connect, and remembers the route that worked (Via column).
- An account that is admin on the targets (Credential... or the current
  login). Local (non-domain) accounts over the admin share also need
  `LocalAccountTokenFilterPolicy = 1` on the target.

## Project files

| File | What |
|---|---|
| `Modules\Lite\Services_Radmin.psm1` | the core script block (local + remote), settings, transfer folder, fleet list |
| `Modules\Lite\Services_RadminBatch.psm1` | parallel WinRM jobs polled by a UI timer |
| `Modules\Lite\UI_Tab_ThisMachine.psm1` | This Machine tab |
| `Modules\Lite\UI_Tab_Fleet.psm1` | Fleet tab |
| `Modules\Lite\UI_Env_Radmin.psm1` | Environment > Radmin page |
| `Modules\Base\UI_Register-Tabs.psm1`, `UI_Tab_Overview.psm1` | tab list, overview |

To make Fleet admin-only: move `UI_Tab_Fleet.psm1` and `Services_RadminBatch.psm1`
to `Modules\Admin` and its entry to `$adminDefs` in `UI_Register-Tabs.psm1`.

## Assumptions to confirm on a real device

- rserver3 argument syntax: the default is `/requestfile:"..."` / `/licensefile:"..."`;
  the no-colon forms from the old scripts are tried automatically if the first
  doesn't work. The working form is reported - set it on Environment > Radmin.
- The license takes effect without restarting the Radmin Server service.

## Engine (AppTemplate)

Building, the Dev / Lite EXEs, passwords, environments, tiers, logging, hover help
and the command window are the template's and the same in every tool: see
[`template/Source/README.md`](../../../template/Source/README.md) in the admin-tools
repository. Build with `Build-App.cmd` in the project folder: it makes
`RadminLicenseDev.exe` (developer build, never hand it out) and, with the passwords you
type, `RadminLicenseLite.exe` (the sealed build to hand out).
