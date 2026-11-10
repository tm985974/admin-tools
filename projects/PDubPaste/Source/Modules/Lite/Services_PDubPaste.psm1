# Services_PDubPaste.psm1   (LITE TIER)
#
# The engine behind PDubPaste:
#   * 5 password slots, saved to <LocalAppData>\<app>\Settings\PasswordSlots.json.
#     Secrets are encrypted with Windows DPAPI (CurrentUser scope) - only the same
#     Windows account on the same machine can decrypt them. They are always stored
#     LOCALLY (never on an environment's shared path) and never written to a log.
#   * System-wide hotkeys (Win32 RegisterHotKey) on a hidden message window.
#   * On a hotkey, waits for the modifier keys to be released, then sends the
#     password to whatever window has focus:
#       Type      - injected as Unicode keystrokes (SendInput). Nothing touches the
#                   clipboard. Default.
#       Clipboard - for apps that ignore injected Unicode keys: put on the
#                   clipboard (flagged to stay out of Win+V history / cloud sync),
#                   send Ctrl+V, then restore the previous clipboard text.
#
# State shared with the tabs lives in $global:PwPaste (every module is imported
# in isolation). The tabs subscribe with Register-PwStateChangedHandler.

$script:PwSlotCount = 5

$script:PwNativeSource = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.WindowsRuntime;
using System.Security;
using System.Security.Principal;
using System.Threading;
using System.Windows.Forms;

namespace PwPaste
{
    public class HotkeyEventArgs : EventArgs
    {
        public int Id;
        public HotkeyEventArgs(int id) { Id = id; }
    }

    // Hidden message-only window that receives WM_HOTKEY.
    public sealed class HotkeyWindow : NativeWindow, IDisposable
    {
        [DllImport("user32.dll", SetLastError = true)] static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);
        [DllImport("user32.dll", SetLastError = true)] static extern bool UnregisterHotKey(IntPtr hWnd, int id);

        const int  WM_HOTKEY    = 0x0312;
        const uint MOD_NOREPEAT = 0x4000;

        public event EventHandler<HotkeyEventArgs> HotkeyPressed;
        public int LastError;

        public HotkeyWindow()
        {
            CreateParams cp = new CreateParams();
            cp.Parent = new IntPtr(-3);            // HWND_MESSAGE
            CreateHandle(cp);
        }

        readonly List<int> _ids = new List<int>();
        bool _closed;

        public bool Register(int id, uint modifiers, uint vk)
        {
            LastError = 0;
            if (_closed) return false;
            bool ok = RegisterHotKey(Handle, id, modifiers | MOD_NOREPEAT, vk);
            if (!ok) LastError = Marshal.GetLastWin32Error();
            else if (!_ids.Contains(id)) _ids.Add(id);
            return ok;
        }

        public void Unregister(int id) { UnregisterHotKey(Handle, id); _ids.Remove(id); }

        public void UnregisterAll()
        {
            foreach (int id in _ids.ToArray()) UnregisterHotKey(Handle, id);
            _ids.Clear();
        }

        // Release every hotkey from C# the moment the owner window closes - this
        // does not depend on any PowerShell handler running at shutdown.
        public void AttachOwner(Form owner)
        {
            owner.FormClosed += delegate { _closed = true; UnregisterAll(); Dispose(); };
        }

        protected override void WndProc(ref Message m)
        {
            if (m.Msg == WM_HOTKEY)
            {
                if (_closed) return;
                EventHandler<HotkeyEventArgs> h = HotkeyPressed;
                if (h != null) { try { h(this, new HotkeyEventArgs(m.WParam.ToInt32())); } catch { } }
                return;
            }
            base.WndProc(ref m);
        }

        public void Dispose() { try { DestroyHandle(); } catch { } }
    }

    public static class Sender
    {
        [StructLayout(LayoutKind.Sequential)]
        struct MOUSEINPUT { public int dx; public int dy; public uint mouseData; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
        [StructLayout(LayoutKind.Sequential)]
        struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
        [StructLayout(LayoutKind.Explicit)]
        struct InputUnion { [FieldOffset(0)] public MOUSEINPUT mi; [FieldOffset(0)] public KEYBDINPUT ki; }
        [StructLayout(LayoutKind.Sequential)]
        struct INPUT { public uint type; public InputUnion u; }

        [DllImport("user32.dll", SetLastError = true)] static extern uint SendInput(uint n, INPUT[] inputs, int size);
        [DllImport("user32.dll")] static extern short GetAsyncKeyState(int vk);
        [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
        [DllImport("user32.dll")] static extern uint GetClipboardSequenceNumber();

        const uint INPUT_KEYBOARD   = 1;
        const uint KEYEVENTF_KEYUP  = 0x0002;
        const uint KEYEVENTF_UNICODE = 0x0004;
        const ushort VK_RETURN = 0x0D, VK_CONTROL = 0x11, VK_V = 0x56;
        static readonly int[] Modifiers = { 0x10, 0x11, 0x12, 0x5B, 0x5C };   // Shift, Ctrl, Alt, LWin, RWin

        public static int LastError;

        // Process id of the window that currently has focus (0 if none).
        public static int ForegroundProcessId()
        {
            uint pid = 0;
            IntPtr h = GetForegroundWindow();
            if (h == IntPtr.Zero) return 0;
            GetWindowThreadProcessId(h, out pid);
            return (int)pid;
        }

        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, string lParam);

        public static bool IsWinDown() { return (GetAsyncKeyState(0x5B) & 0x8000) != 0 || (GetAsyncKeyState(0x5C) & 0x8000) != 0; }

        // Grey hint text shown in an empty TextBox (EM_SETCUEBANNER), also while focused.
        public static void SetCue(IntPtr textBox, string text) { SendMessage(textBox, 0x1501, new IntPtr(1), text ?? ""); }

        public static bool AnyModifierDown()
        {
            foreach (int vk in Modifiers) if ((GetAsyncKeyState(vk) & 0x8000) != 0) return true;
            return false;
        }

        // The hotkey's own Ctrl/Alt/Shift/Win are still held when it fires; keys
        // sent while they are down would turn into shortcuts. Wait for release.
        public static bool WaitForModifiersUp(int timeoutMs)
        {
            int waited = 0;
            while (AnyModifierDown())
            {
                if (waited >= timeoutMs) return false;
                System.Threading.Thread.Sleep(15);
                waited += 15;
            }
            System.Threading.Thread.Sleep(30);
            return true;
        }

        static INPUT Key(ushort vk, ushort scan, uint flags)
        {
            INPUT i = new INPUT();
            i.type = INPUT_KEYBOARD;
            i.u.ki.wVk = vk; i.u.ki.wScan = scan; i.u.ki.dwFlags = flags;
            return i;
        }

        static bool Send(INPUT[] inputs)
        {
            LastError = 0;
            uint sent = SendInput((uint)inputs.Length, inputs, Marshal.SizeOf(typeof(INPUT)));
            if (sent != inputs.Length) LastError = Marshal.GetLastWin32Error();
            return sent == inputs.Length;
        }

        // Type the secret as Unicode keystrokes. The plain text only ever exists in
        // an unmanaged buffer and the INPUT array, and both are wiped afterwards.
        public static bool TypeSecure(SecureString secret, bool pressEnter)
        {
            if (secret == null) return false;
            IntPtr p = IntPtr.Zero;
            INPUT[] inputs = null;
            try
            {
                p = Marshal.SecureStringToGlobalAllocUnicode(secret);
                int len = secret.Length;
                inputs = new INPUT[(len + 1) * 2];
                int n = 0;
                for (int i = 0; i < len; i++)
                {
                    char c = (char)Marshal.ReadInt16(p, i * 2);
                    if (c == '\r' || c == '\n')
                    {
                        inputs[n++] = Key(VK_RETURN, 0, 0);
                        inputs[n++] = Key(VK_RETURN, 0, KEYEVENTF_KEYUP);
                    }
                    else
                    {
                        inputs[n++] = Key(0, c, KEYEVENTF_UNICODE);
                        inputs[n++] = Key(0, c, KEYEVENTF_UNICODE | KEYEVENTF_KEYUP);
                    }
                }
                if (pressEnter)
                {
                    inputs[n++] = Key(VK_RETURN, 0, 0);
                    inputs[n++] = Key(VK_RETURN, 0, KEYEVENTF_KEYUP);
                }
                INPUT[] exact = new INPUT[n];
                Array.Copy(inputs, exact, n);
                bool ok = Send(exact);
                Array.Clear(exact, 0, exact.Length);
                return ok;
            }
            finally
            {
                if (inputs != null) Array.Clear(inputs, 0, inputs.Length);
                if (p != IntPtr.Zero) Marshal.ZeroFreeGlobalAllocUnicode(p);
            }
        }

        // Clipboard route: secret on the clipboard (excluded from clipboard history
        // and cloud clipboard), Ctrl+V, then the previous clipboard text is put back
        // after restoreMs - unless something else changed the clipboard meanwhile.
        public static bool PasteViaClipboard(SecureString secret, bool pressEnter, int restoreMs)
        {
            if (secret == null) return false;
            string previous = null;
            try { if (Clipboard.ContainsText()) previous = Clipboard.GetText(); } catch { }

            IntPtr p = IntPtr.Zero;
            try
            {
                p = Marshal.SecureStringToGlobalAllocUnicode(secret);
                string plain = Marshal.PtrToStringUni(p, secret.Length);
                DataObject d = new DataObject();
                d.SetData(DataFormats.UnicodeText, plain);
                d.SetData("ExcludeClipboardContentFromMonitorProcessing", new System.IO.MemoryStream(new byte[] { 1, 0, 0, 0 }));
                d.SetData("CanIncludeInClipboardHistory",               new System.IO.MemoryStream(new byte[] { 0, 0, 0, 0 }));
                d.SetData("CanUploadToCloudClipboard",                  new System.IO.MemoryStream(new byte[] { 0, 0, 0, 0 }));
                Clipboard.SetDataObject(d, false, 5, 50);
            }
            catch { return false; }
            finally { if (p != IntPtr.Zero) Marshal.ZeroFreeGlobalAllocUnicode(p); }

            uint ours = GetClipboardSequenceNumber();
            System.Collections.Generic.List<INPUT> keys = new System.Collections.Generic.List<INPUT>();
            keys.Add(Key(VK_CONTROL, 0, 0)); keys.Add(Key(VK_V, 0, 0));
            keys.Add(Key(VK_V, 0, KEYEVENTF_KEYUP)); keys.Add(Key(VK_CONTROL, 0, KEYEVENTF_KEYUP));
            if (pressEnter) { keys.Add(Key(VK_RETURN, 0, 0)); keys.Add(Key(VK_RETURN, 0, KEYEVENTF_KEYUP)); }
            bool ok = Send(keys.ToArray());

            System.Windows.Forms.Timer t = new System.Windows.Forms.Timer();
            t.Interval = Math.Max(100, restoreMs);
            t.Tick += delegate
            {
                t.Stop(); t.Dispose();
                try
                {
                    if (GetClipboardSequenceNumber() != ours) return;   // the user copied something else meanwhile
                    if (previous != null) Clipboard.SetText(previous); else Clipboard.Clear();
                }
                catch { }
            };
            t.Start();
            return ok;
        }
    }

    // One copy per Windows session. A second launch signals the first to show
    // itself and exits.
    public static class SingleInstance
    {
        static Mutex _mutex;
        static EventWaitHandle _show;

        public static bool TryClaim(string name)
        {
            bool created;
            Mutex m = new Mutex(true, "Local\\" + name + ".instance", out created);
            if (!created) { m.Dispose(); return false; }
            _mutex = m;
            _show = new EventWaitHandle(false, EventResetMode.AutoReset, "Local\\" + name + ".show");
            return true;
        }

        [DllImport("user32.dll")] static extern bool AllowSetForegroundWindow(int processId);

        // Returns false if the running copy could not be reached.
        public static bool SignalExisting(string name)
        {
            // This launch has focus (the user just started it); hand the right to
            // come to the front over to the running copy before waking it.
            try { AllowSetForegroundWindow(-1); } catch { }   // ASFW_ANY
            try { using (EventWaitHandle ev = EventWaitHandle.OpenExisting("Local\\" + name + ".show")) ev.Set(); return true; }
            catch { return false; }
        }

        // onShow runs on the UI thread (BeginInvoke) each time another launch signals.
        public static void Listen(Control ui, EventHandler onShow)
        {
            if (_show == null) return;
            Thread t = new Thread(delegate ()
            {
                while (true)
                {
                    try { _show.WaitOne(); } catch { return; }
                    if (ui.IsDisposed) return;
                    try { ui.BeginInvoke(onShow, ui, EventArgs.Empty); } catch { }
                }
            });
            t.IsBackground = true;
            t.Start();
        }
    }

    public static class Lifetime
    {
        [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
        [DllImport("user32.dll")] static extern bool BringWindowToTop(IntPtr h);
        [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
        [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
        [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, IntPtr pid);
        [DllImport("user32.dll")] static extern bool AttachThreadInput(uint a, uint b, bool attach);
        [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();

        // Bring a window to the front even when this process is in the background
        // (Windows otherwise only flashes it on the taskbar).
        public static bool BringToFront(IntPtr h)
        {
            if (h == IntPtr.Zero) return false;
            if (IsIconic(h)) ShowWindow(h, 9);                 // SW_RESTORE
            if (SetForegroundWindow(h)) return true;
            uint me = GetCurrentThreadId();
            uint fg = GetWindowThreadProcessId(GetForegroundWindow(), IntPtr.Zero);
            bool ok = false;
            if (fg != 0 && fg != me && AttachThreadInput(me, fg, true))
            {
                BringWindowToTop(h);
                ok = SetForegroundWindow(h);
                AttachThreadInput(me, fg, false);
            }
            return ok;
        }

        // After the main window closes, make sure the process really ends (a
        // lingering process would keep hotkeys alive).
        public static void ExitAfterClose(Form owner, int graceMs)
        {
            owner.FormClosed += delegate
            {
                Thread t = new Thread(delegate () { Thread.Sleep(graceMs); Environment.Exit(0); });
                t.IsBackground = true;
                t.Start();
            };
        }

        [StructLayout(LayoutKind.Sequential)] struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
        [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);

        // Seconds since the last keyboard/mouse input anywhere in this session.
        public static int IdleSeconds()
        {
            LASTINPUTINFO li = new LASTINPUTINFO();
            li.cbSize = (uint)Marshal.SizeOf(typeof(LASTINPUTINFO));
            if (!GetLastInputInfo(ref li)) return 0;
            return (int)(unchecked((uint)Environment.TickCount - li.dwTime) / 1000);
        }
    }

    // Verifies a password against the Windows account that is running this app.
    public static class WinAuth
    {
        [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        static extern bool LogonUser(string user, string domain, IntPtr password, int logonType, int provider, out IntPtr token);
        [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);

        const int LOGON32_LOGON_INTERACTIVE = 2, LOGON32_LOGON_NETWORK = 3, ERROR_LOGON_TYPE_NOT_GRANTED = 1385;

        public static int LastError;

        public static string CurrentUserName() { return WindowsIdentity.GetCurrent().Name; }

        public static bool VerifyCurrentUser(SecureString password)
        {
            LastError = 0;
            if (password == null || password.Length == 0) return false;
            WindowsIdentity me = WindowsIdentity.GetCurrent();
            string full = me.Name;
            string domain = ".", user = full;
            int slash = full.IndexOf('\\');
            if (slash >= 0) { domain = full.Substring(0, slash); user = full.Substring(slash + 1); }

            IntPtr pw = IntPtr.Zero, token = IntPtr.Zero;
            try
            {
                pw = Marshal.SecureStringToGlobalAllocUnicode(password);
                bool ok = LogonUser(user, domain, pw, LOGON32_LOGON_INTERACTIVE, 0, out token);
                if (!ok)
                {
                    LastError = Marshal.GetLastWin32Error();
                    if (LastError == ERROR_LOGON_TYPE_NOT_GRANTED)
                    {
                        ok = LogonUser(user, domain, pw, LOGON32_LOGON_NETWORK, 0, out token);
                        LastError = ok ? 0 : Marshal.GetLastWin32Error();
                    }
                }
                if (!ok) return false;
                using (WindowsIdentity who = new WindowsIdentity(token))
                    return who.User != null && who.User.Equals(me.User);   // must be THIS account
            }
            finally
            {
                if (token != IntPtr.Zero) CloseHandle(token);
                if (pw != IntPtr.Zero) Marshal.ZeroFreeGlobalAllocUnicode(pw);
            }
        }
    }

    // Windows Hello from a desktop window: the interop that parents the Hello
    // prompt to our window (so it opens in front of it).
    [ComImport, Guid("39E050C3-4E74-441A-8DC0-B81104DF949C"), InterfaceType(ComInterfaceType.InterfaceIsIInspectable)]
    public interface IUserConsentVerifierInterop
    {
        IntPtr RequestVerificationForWindowAsync(IntPtr appWindow, [MarshalAs(UnmanagedType.HString)] string message, [In] ref Guid riid);
    }

    public static class Hello
    {
        // verifierType = [Windows.Security.Credentials.UI.UserConsentVerifier];
        // riid = IID of IAsyncOperation<UserConsentVerificationResult>.
        // Returns the IAsyncOperation as a COM object for PowerShell to await.
        public static object RequestForWindow(Type verifierType, IntPtr hwnd, string message, Guid riid)
        {
            object factory = WindowsRuntimeMarshal.GetActivationFactory(verifierType);
            IUserConsentVerifierInterop interop = (IUserConsentVerifierInterop)factory;
            IntPtr op = interop.RequestVerificationForWindowAsync(hwnd, message, ref riid);
            try { return Marshal.GetObjectForIUnknown(op); }
            finally { Marshal.Release(op); }
        }
    }
}
'@

# ---------------------------------------------------------------------------
# state
# ---------------------------------------------------------------------------
function Get-PwState {
    if (-not $global:PwPaste) {
        $global:PwPaste = @{
            Window   = $null      # PwPaste.HotkeyWindow
            Slots    = @()        # pscustomobjects (see New-PwSlot)
            Status   = @{}        # index -> 'Active' | 'Off' | 'No hotkey' | 'In use by another app' ...
            Paused   = $false
            Suspended = $false    # true while a hotkey box on the config tab has focus
            Unlocked = $false     # hotkeys start only after the first Windows sign-in check
            WindowLocked = $true  # the window's contents are hidden until verified
            Options  = [pscustomobject]@{ MinimizeToTray = $true; StartPaused = $false; LockAfterMinutes = 5 }
            Handlers = New-Object System.Collections.Generic.List[scriptblock]
            Ready    = $false
            LastMessage = ''
        }
    }
    return $global:PwPaste
}

function Register-PwStateChangedHandler {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [scriptblock]$Handler)
    $st = Get-PwState
    [void]$st.Handlers.Add($Handler)
}

function Invoke-PwStateChanged {
    [CmdletBinding()]
    param($App)
    $st = Get-PwState
    foreach ($h in @($st.Handlers)) {
        try { & $h } catch { if ($App) { $App.Log('ERROR', 'PwPaste', "state handler failed: $($_.Exception.Message)") } }
    }
}

# ---------------------------------------------------------------------------
# hotkey text  <->  modifiers + virtual key
# ---------------------------------------------------------------------------
# RegisterHotKey modifier flags
$script:MOD_ALT = 1; $script:MOD_CONTROL = 2; $script:MOD_SHIFT = 4; $script:MOD_WIN = 8

function Format-PwHotkey {
    [CmdletBinding()]
    param([int]$Modifiers, [int]$Key)
    if ($Key -le 0) { return '' }
    $parts = @()
    if ($Modifiers -band $script:MOD_CONTROL) { $parts += 'Ctrl' }
    if ($Modifiers -band $script:MOD_ALT)     { $parts += 'Alt' }
    if ($Modifiers -band $script:MOD_SHIFT)   { $parts += 'Shift' }
    if ($Modifiers -band $script:MOD_WIN)     { $parts += 'Win' }
    $k = [System.Windows.Forms.Keys]$Key
    $name = switch -regex ($k.ToString()) {
        '^D(\d)$'      { $Matches[1]; break }
        '^NumPad(\d)$' { 'Num ' + $Matches[1]; break }
        '^Oem'         { $k.ToString() -replace '^Oem', ''; break }
        default        { $k.ToString() }
    }
    $parts += $name
    return ($parts -join '+')
}

# Convert a KeyDown event's KeyData into a hotkey. Returns $null while only
# modifier keys are held. Win is read from the keyboard (KeyData doesn't carry it).
function ConvertFrom-PwKeyData {
    [CmdletBinding()]
    param([System.Windows.Forms.Keys]$KeyData, [bool]$WinDown = $false)
    $code = [int]($KeyData -band [System.Windows.Forms.Keys]::KeyCode)
    $codeKey = [System.Windows.Forms.Keys]$code
    $modOnly = @('ShiftKey','ControlKey','Menu','LWin','RWin','LShiftKey','RShiftKey','LControlKey','RControlKey','LMenu','RMenu','None')
    if ($modOnly -contains $codeKey.ToString()) { return $null }
    $m = 0
    if ($KeyData -band [System.Windows.Forms.Keys]::Control) { $m = $m -bor $script:MOD_CONTROL }
    if ($KeyData -band [System.Windows.Forms.Keys]::Alt)     { $m = $m -bor $script:MOD_ALT }
    if ($KeyData -band [System.Windows.Forms.Keys]::Shift)   { $m = $m -bor $script:MOD_SHIFT }
    if ($WinDown)                                            { $m = $m -bor $script:MOD_WIN }
    return [pscustomobject]@{ Modifiers = $m; Key = $code }
}

# A hotkey must have Ctrl or Alt or Win (Shift alone would steal normal typing),
# unless it is F13-F24 / Pause / Scroll Lock which nothing types.
function Test-PwHotkeyAllowed {
    [CmdletBinding()]
    param([int]$Modifiers, [int]$Key)
    if ($Key -le 0) { return $true }
    $strong = $script:MOD_CONTROL -bor $script:MOD_ALT -bor $script:MOD_WIN
    if ($Modifiers -band $strong) { return $true }
    $k = ([System.Windows.Forms.Keys]$Key).ToString()
    return ($k -match '^F(1[3-9]|2[0-4])$' -or $k -in @('Pause','Scroll'))
}

# ---------------------------------------------------------------------------
# storage (always local AppData; DPAPI CurrentUser)
# ---------------------------------------------------------------------------
function Get-PwStorePath {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $App)
    $dir = Join-Path ([string]$App.LocalAppData) 'Settings'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $path = Join-Path $dir 'PasswordSlots.json'
    if (-not (Test-Path -LiteralPath $path)) { Copy-PwLegacyStore -App $App -Target $path }
    return $path
}

# One-time carry-over from before the rename (v1.2.0): the app was "Password
# Paster" with its data in <LocalAppData>\PasswordPasterData. Copy (never move)
# that PasswordSlots.json when this app has none yet. DPAPI CurrentUser is tied
# to the Windows account, not the path, so the copied secrets still decrypt.
function Copy-PwLegacyStore {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $App, [Parameter(Mandatory)] [string]$Target)
    try {
        $parent = Split-Path -Parent ([string]$App.LocalAppData)
        if (-not $parent) { return }
        $legacy = Join-Path $parent 'PasswordPasterData\Settings\PasswordSlots.json'
        if ([string]::Equals($legacy, $Target, [StringComparison]::OrdinalIgnoreCase)) { return }
        if (-not (Test-Path -LiteralPath $legacy)) { return }
        Copy-Item -LiteralPath $legacy -Destination $Target -ErrorAction Stop
        $App.Log('INFO', 'PwPaste', "Copied saved slots from the Password Paster data folder ($legacy).")
    }
    catch { $App.Log('WARN', 'PwPaste', "Could not copy saved slots from Password Paster: $($_.Exception.Message)") }
}

function New-PwSlot {
    [CmdletBinding()]
    param([int]$Index)
    [pscustomobject]@{
        Index     = $Index
        Name      = "Password $Index"
        Secret    = $null            # [SecureString] or $null
        Modifiers = $script:MOD_CONTROL -bor $script:MOD_ALT
        Key       = [int][System.Windows.Forms.Keys]("D$Index")   # Ctrl+Alt+1 .. 5
        Enabled   = $false
        SendEnter = $false
        Method    = 'Type'           # Type | Clipboard
    }
}

function Read-PwSlots {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $App)
    $st = Get-PwState
    $slots = @(1..$script:PwSlotCount | ForEach-Object { New-PwSlot -Index $_ })
    $path = Get-PwStorePath -App $App
    if (Test-Path -LiteralPath $path) {
        try {
            $j = [System.IO.File]::ReadAllText($path) | ConvertFrom-Json -ErrorAction Stop
            if ($j.Options) {
                if ($null -ne $j.Options.MinimizeToTray) { $st.Options.MinimizeToTray = [bool]$j.Options.MinimizeToTray }
                if ($null -ne $j.Options.StartPaused)    { $st.Options.StartPaused    = [bool]$j.Options.StartPaused }
                if ($null -ne $j.Options.LockAfterMinutes) { $st.Options.LockAfterMinutes = [Math]::Max(0, [int]$j.Options.LockAfterMinutes) }
            }
            foreach ($s in @($j.Slots)) {
                $i = [int]$s.Index
                if ($i -lt 1 -or $i -gt $script:PwSlotCount) { continue }
                $slot = $slots[$i - 1]
                if ($null -ne $s.Name)      { $slot.Name      = [string]$s.Name }
                if ($null -ne $s.Modifiers) { $slot.Modifiers = [int]$s.Modifiers }
                if ($null -ne $s.Key)       { $slot.Key       = [int]$s.Key }
                if ($null -ne $s.Enabled)   { $slot.Enabled   = [bool]$s.Enabled }
                if ($null -ne $s.SendEnter) { $slot.SendEnter = [bool]$s.SendEnter }
                if ($s.Method -in @('Type','Clipboard')) { $slot.Method = [string]$s.Method }
                if ($s.Secret) {
                    try { $slot.Secret = ConvertTo-SecureString -String ([string]$s.Secret) -ErrorAction Stop }
                    catch {
                        $slot.Secret = $null; $slot.Enabled = $false
                        $App.Log('WARN', 'PwPaste', "Slot $i password could not be decrypted (saved by another Windows user or machine). It was cleared and disabled.")
                    }
                }
            }
        }
        catch { $App.Log('ERROR', 'PwPaste', "PasswordSlots.json could not be read: $($_.Exception.Message)") }
    }
    $st.Slots = $slots
    return $slots
}

function Save-PwSlots {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $App, [Parameter(Mandatory)] $Slots)
    $st = Get-PwState
    $out = foreach ($s in $Slots) {
        [ordered]@{
            Index     = $s.Index
            Name      = $s.Name
            Secret    = $(if ($s.Secret -and $s.Secret.Length -gt 0) { ConvertFrom-SecureString -SecureString $s.Secret } else { '' })
            Modifiers = $s.Modifiers
            Key       = $s.Key
            Enabled   = $s.Enabled
            SendEnter = $s.SendEnter
            Method    = $s.Method
        }
    }
    $doc = [ordered]@{
        _note   = 'Secrets are DPAPI-encrypted for this Windows user on this machine. Copying this file elsewhere will not reveal them.'
        Options = [ordered]@{ MinimizeToTray = [bool]$st.Options.MinimizeToTray; StartPaused = [bool]$st.Options.StartPaused
                              LockAfterMinutes = [int]$st.Options.LockAfterMinutes }
        Slots   = @($out)
    }
    $path = Get-PwStorePath -App $App
    $tmp = "$path.tmp"
    [System.IO.File]::WriteAllText($tmp, ($doc | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $path -Force
    $st.Slots = @($Slots)
    $App.Log('INFO', 'PwPaste', 'Password slots saved (secrets not logged).')
    $App.LogAction('Password slots saved.')
}

# ---------------------------------------------------------------------------
# hotkeys
# ---------------------------------------------------------------------------
# Compile the native helpers once per process.
function Import-PwNative {
    [CmdletBinding()]
    param()
    if (-not ('PwPaste.HotkeyWindow' -as [type])) {
        Add-Type -TypeDefinition $script:PwNativeSource -ReferencedAssemblies System.Windows.Forms, System.Drawing -ErrorAction Stop
    }
}

# Name for the single-instance lock (per Windows user; 'Local\' = per session).
function Get-PwInstanceName { 'PDubPaste.' + [Environment]::UserName }

function Initialize-PwPaste {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $App)
    $st = Get-PwState
    if ($st.Ready) { return }

    Import-PwNative
    $st.Window = New-Object PwPaste.HotkeyWindow
    if ($global:AppForm) {
        $st.Window.AttachOwner($global:AppForm)              # hotkeys die with the window, from C#
        [PwPaste.Lifetime]::ExitAfterClose($global:AppForm, 3000)   # and so does the process
    }
    $st.Window.add_HotkeyPressed({
        param($sender, $e)
        try { Invoke-PwSlot -App $App -Index $e.Id }
        catch { $App.Log('ERROR', 'PwPaste', "hotkey $($e.Id): $($_.Exception.Message)") }
    }.GetNewClosure())

    [void](Read-PwSlots -App $App)
    $st.Paused = [bool]$st.Options.StartPaused
    $st.Ready = $true
    Update-PwHotkeys -App $App
}

# (Re)register every slot's hotkey from $global:PwPaste.Slots.
function Update-PwHotkeys {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $App)
    $st = Get-PwState
    if (-not $st.Window) { return }
    foreach ($i in 1..$script:PwSlotCount) { $st.Window.Unregister($i) }
    $st.Status = @{}
    $seen = @{}
    $others = $null
    foreach ($s in $st.Slots) {
        $combo = Format-PwHotkey -Modifiers $s.Modifiers -Key $s.Key
        if     (-not $st.Unlocked)                                { $st.Status[$s.Index] = $(if ($s.Enabled) { 'Locked' } else { 'Off' }) }
        elseif (-not $s.Enabled)                                  { $st.Status[$s.Index] = 'Off' }
        elseif ($s.Key -le 0)                                     { $st.Status[$s.Index] = 'No hotkey' }
        elseif (-not $s.Secret -or $s.Secret.Length -eq 0)        { $st.Status[$s.Index] = 'No password' }
        elseif ($st.Paused)                                       { $st.Status[$s.Index] = 'Paused' }
        elseif ($st.Suspended)                                    { $st.Status[$s.Index] = 'Editing' }
        elseif ($seen.ContainsKey("$($s.Modifiers):$($s.Key)"))   { $st.Status[$s.Index] = "Same hotkey as slot $($seen["$($s.Modifiers):$($s.Key)"])" }
        elseif ($st.Window.Register($s.Index, [uint32]$s.Modifiers, [uint32]$s.Key)) {
            $st.Status[$s.Index] = 'Active'
            $seen["$($s.Modifiers):$($s.Key)"] = $s.Index
        }
        else {
            $err = $st.Window.LastError
            if ($err -eq 1409) {
                if ($null -eq $others) { $others = @(Get-PwOtherCopies) }
                $st.Status[$s.Index] = $(if ($others.Count -gt 0) { 'In use by another PDubPaste copy' } else { 'Hotkey in use by another app' })
            }
            else { $st.Status[$s.Index] = "Register failed ($err)" }
            $App.Log('WARN', 'PwPaste', "Slot $($s.Index) hotkey $combo not registered: Win32 error $err")
        }
    }
    Invoke-PwStateChanged -App $App
}

# Other PDubPaste processes in THIS Windows session (dev build, Lite build,
# archived copies), including copies still named PasswordPaster (before v1.2).
# Copies from before v1.1 can linger after their window closed, still holding
# the hotkeys.
function Get-PwOtherCopies {
    [CmdletBinding()]
    param()
    try {
        $mine = (Get-Process -Id $PID).SessionId
        @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
            $_.Id -ne $PID -and $_.SessionId -eq $mine -and ($_.ProcessName -like 'PDubPaste*' -or $_.ProcessName -like 'PasswordPaster*') })
    } catch { @() }
}

# If hotkeys are blocked by another copy, offer to close it, then retry.
function Resolve-PwOtherCopies {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $App, $Owner)
    $st = Get-PwState
    if (-not ($st.Status.Values -contains 'In use by another PDubPaste copy')) { return }
    $others = @(Get-PwOtherCopies)
    if ($others.Count -eq 0) { return }
    $list = ($others | ForEach-Object { "  $($_.ProcessName).exe  (PID $($_.Id), started $($_.StartTime.ToString('HH:mm')))" }) -join "`r`n"
    # v1.2.2: the command window is the confirmation (template rule: every action shows its code).
    $ids = @($others | ForEach-Object { [int]$_.Id })
    $code = 'Stop-Process -Id ' + (Format-AppCommandValue $ids) + ' -Force -ErrorAction Stop'
    $r = Invoke-AppCommand -App $App -Title 'Close other PDubPaste copies' -Kind Change -RunLabel 'Close them' `
        -Summary ("Another copy of PDubPaste is still running and holding the hotkeys:`r`n$list`r`n" +
                  "It may be an older version left running after its window closed.") `
        -Code $code
    if (-not $r.Ran) { return }
    if ($r.Errors.Count) { $App.Log('WARN', 'PwPaste', "Could not close every other copy: $($r.Errors -join ' | ')") }
    else { $App.Log('INFO', 'PwPaste', "Closed other copies: PID $($ids -join ', ').") }
    Start-Sleep -Milliseconds 400
    Update-PwHotkeys -App $App
}

function Set-PwPaused {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $App, [bool]$Paused)
    $st = Get-PwState
    $st.Paused = $Paused
    Update-PwHotkeys -App $App
    $App.Log('INFO', 'PwPaste', $(if ($Paused) { 'Hotkeys paused.' } else { 'Hotkeys resumed.' }))
}

# While the user is typing a new combo into a hotkey box, our own hotkeys would
# fire instead of reaching the box - so they are released for the duration.
function Set-PwSuspended {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $App, [bool]$Suspended)
    $st = Get-PwState
    if ($st.Suspended -eq $Suspended) { return }
    $st.Suspended = $Suspended
    Update-PwHotkeys -App $App
}

function Invoke-PwSlot {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $App, [Parameter(Mandatory)] [int]$Index)
    $st = Get-PwState
    if ($st.Paused -or $st.Suspended -or -not $st.Unlocked) { return }
    $slot = $st.Slots | Where-Object { $_.Index -eq $Index } | Select-Object -First 1
    if (-not $slot -or -not $slot.Secret) { return }

    # Never type into this app's own window.
    if ([PwPaste.Sender]::ForegroundProcessId() -eq $PID) {
        Set-PwMessage -App $App -Text "'$($slot.Name)': switch to the target window first - nothing is pasted into this app." -Level 'warn'
        return
    }
    if (-not [PwPaste.Sender]::WaitForModifiersUp(2000)) {
        Set-PwMessage -App $App -Text "'$($slot.Name)': release the hotkey keys - nothing was sent." -Level 'warn'
        return
    }
    $ok = if ($slot.Method -eq 'Clipboard') { [PwPaste.Sender]::PasteViaClipboard($slot.Secret, [bool]$slot.SendEnter, 750) }
          else                              { [PwPaste.Sender]::TypeSecure($slot.Secret, [bool]$slot.SendEnter) }
    $when = (Get-Date).ToString('HH:mm:ss')
    if ($ok) {
        Set-PwMessage -App $App -Text "$when  Sent '$($slot.Name)' ($($slot.Method.ToLower()))." -Level 'ok'
        $App.LogAction("Sent slot $Index '$($slot.Name)' via $($slot.Method).")
    }
    else {
        Set-PwMessage -App $App -Text "$when  '$($slot.Name)' was blocked by Windows (the target may be running as administrator)." -Level 'err'
        $App.Log('WARN', 'PwPaste', "Slot $Index send failed, Win32 error $([PwPaste.Sender]::LastError).")
    }
}

function Set-PwMessage {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $App, [string]$Text, [string]$Level = 'info')
    $st = Get-PwState
    $st.LastMessage = $Text
    try { $App.SetStatus($Text, $Level) } catch { }
    Invoke-PwStateChanged -App $App
}

function Stop-PwPaste {
    [CmdletBinding()]
    param($App)
    $st = Get-PwState
    if ($st.Window) {
        foreach ($i in 1..$script:PwSlotCount) { try { $st.Window.Unregister($i) } catch { } }
        try { $st.Window.Dispose() } catch { }
        $st.Window = $null
    }
    $st.Ready = $false
}
