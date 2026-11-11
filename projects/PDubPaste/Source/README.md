# PDubPaste

A small Windows tool that pastes saved passwords into whatever has the cursor,
using hotkeys you choose. Built on the AppTemplate engine (v1.0.20) - the
template documentation follows below.

## Use it

1. **Password Config** tab: for each of the 5 slots, tick **On**, give it a
   name, type the password, click the **Hotkey** box and press a combo
   (e.g. `Ctrl+Alt+1`; Backspace clears it). Click **Save**.
2. Click into the target field in any app and press the hotkey. The password is
   sent when you let go of the keys.
3. **Overview** shows which hotkeys are active and has **Pause hotkeys**. The
   tray icon has Open / Pause / Exit; minimizing hides to the tray (optional).

| Option | Meaning |
|---|---|
| Method **Type** (default) | Sent as Unicode keystrokes. Never touches the clipboard. |
| Method **Clipboard** | For apps that ignore typed keys (some remote consoles / VDI). Ctrl+V, kept out of Win+V history and cloud clipboard; the previous clipboard text is restored ~0.75 s later. |
| **Enter after** | Presses Enter after the password. |

## Unlocking (Windows sign-in)

The window opens on a lock screen. Unlock with **Windows Hello** (PIN,
fingerprint, face) or, if Hello isn't set up / isn't available (e.g. over
Remote Desktop) / is cancelled, with your **Windows password**. Windows checks
it, and it must be the account running the app. Hotkeys start only after the
first unlock. Bringing the window back from the tray or taskbar asks again;
minimizing or N idle minutes (Password Config) locks it again, while the
hotkeys keep working. Closing the window ends the app and its hotkeys.

Each wrong Windows password counts toward your account's lockout policy, so the
prompt closes after 3 wrong tries.

## Formerly Password Paster

Up to v1.1.5 this app was **Password Paster** (`PasswordPaster.exe`, data in
`%LOCALAPPDATA%\PasswordPasterData`). On its first start, PDubPaste copies the
saved `PasswordSlots.json` from that folder when it has none of its own, so
users keep their slots (same Windows account - DPAPI is tied to the account,
not the path). The old folder is left in place; delete it once you are happy.
The old folder's environments and logs are not carried over. A leftover
`PasswordPaster.exe` still holding the hotkeys is detected and offered for
closing, like any other copy.

## Building the distributable

Build Lite (or `Build-App.cmd`) asks for the two passwords. The **user**
password opens Overview + Password Config; the **admin** password adds the
Environment tab. Hand out `PDubPasteLite.exe`.

## Each user's own passwords

Give users the **sealed** EXE (`PDubPasteLite.exe`) only. Whatever a user saves goes to *their*
`%LOCALAPPDATA%\PDubPasteData\Settings\PasswordSlots.json`, encrypted for
*their* Windows account. Nothing is written into the EXE or the source, users
never see each other's slots, and a newer EXE (same name) keeps their
settings.

## Security notes

- Passwords are encrypted with Windows **DPAPI (CurrentUser)** and saved only in
  `%LOCALAPPDATA%\PDubPasteData\Settings\PasswordSlots.json` - never on an
  environment's shared path. Another user or machine can't decrypt that file.
- Saved passwords are **never loaded back into the form**; an empty box means
  "keep the saved one". In Type mode the plaintext only exists briefly in an
  unmanaged buffer that is zeroed after sending.
- Nothing is sent into this app's own window, and hotkeys are released while
  you're editing a hotkey box.
- Distribute the **sealed** build (`PDubPasteLite.exe`): it needs a password to launch,
  which also gates access to the hotkeys.
- Windows blocks sending keys into programs running as administrator unless
  this app also runs elevated.
- Anyone using your unlocked, logged-in session can press the hotkeys - pause
  or exit when you step away.

## Files

| File | Role |
|---|---|
| `Modules/Lite/Services_PDubPaste.psm1` | storage, hotkey registration, sending (embedded C# via Add-Type) |
| `Modules/Lite/UI_Tab_Passwords.psm1` | Password Config tab |
| `Modules/Lite/UI_PwWindow.psm1` | compact window, lock screen, tray icon, idle lock, shutdown |
| `Modules/Lite/Services_PwUnlock.psm1` | Windows Hello / Windows password unlock |
| `Modules/Lite/UI_PwUnlock.psm1` | Windows password prompt |
| `Modules/Base/UI_Tab_Overview.psm1` | Overview / status tab |
| `Modules/Base/UI_Register-Tabs.psm1` | starts the engine, tab list |
| `AppIdentity.json` | AppName / ExeName / AppDataFolder (`PDubPaste`, `PDubPaste`, `PDubPasteData`) |

## Engine (AppTemplate)

Building, the Dev / Lite EXEs, passwords, environments, tiers, logging, hover help
and the command window are the template's and the same in every tool: see
[`template/Source/README.md`](../../../template/Source/README.md) in the admin-tools
repository. Build with `Build-App.cmd` in the project folder: it makes
`PDubPasteDev.exe` (developer build, never hand it out) and, with the passwords you
type, `PDubPasteLite.exe` (the sealed build to hand out).
