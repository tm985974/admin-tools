# CCM Client Troubleshooter

Built on AppTemplate v1.0.20 (template documentation follows below).

**Discovery** (everyone, read-only) finds the exact state of the Configuration
Manager client and the Windows pieces under it, gives a verdict, the steps to
run in order, and whether an install would succeed. **Repair Steps** (admin
password) runs those steps one at a time. **Logs** reads the client, ccmsetup,
CBS and DISM logs like CMTrace.

| Phase | Steps |
|---|---|
| 1 Prepare | Run as administrator; resync clock; repair required services (KeyIso, WMI, BITS, CryptSvc, msiserver ...) |
| 2 Windows health | chkdsk /scan; WMI verify / salvage; DISM ScanHealth; **DISM RestoreHealth from a healthy PC (/Source /LimitAccess)**; RestoreHealth via WU/WSUS; sfc /scannow; StartComponentCleanup; WU component reset; WU troubleshooter |
| 3 Client repair | restart SMS Agent Host; run client actions; reset policy; ccmrepair; reset identity (SMSCFG.ini + SMS certs) |
| 4 Client reinstall | uninstall; remove leftovers; remove TPM client key; clear the device on the server (manual); install from local source / site share (gated) |
| 5 Verify | run discovery again |

Configure per environment (Environment tab): **Site code**, **Management
point**, **Client source** (full copy of `\\<MP>\SMS_<site>\Client`),
**Repair source** (`\\HEALTHY-PC\C$\Windows` on the same build, or
`wim:E:\install.wim:1`).

Run it as administrator.

## Engine (AppTemplate)

Building, the Dev / Lite EXEs, passwords, environments, tiers, logging, hover help
and the command window are the template's and the same in every tool: see
[`template/Source/README.md`](../../../template/Source/README.md) in the admin-tools
repository. Build with `Build-App.cmd` in the project folder: it makes
`CCMClientTSDev.exe` (developer build, never hand it out) and, with the passwords you
type, `CCMClientTSLite.exe` (the sealed build to hand out).
