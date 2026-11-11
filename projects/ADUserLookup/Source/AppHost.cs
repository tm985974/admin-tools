// @reference: System.Web.Extensions.dll

using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Forms;
using System.Management.Automation;
using System.Management.Automation.Runspaces;

namespace AppTemplate
{
    // =====================================================================
    //  Palette + Theme  (ported from the sample so new projects start styled)
    // =====================================================================
    static class Palette
    {
        public static readonly Color Title     = Color.FromArgb(31, 78, 140);
        public static readonly Color Section    = Color.FromArgb(28, 92, 168);
        public static readonly Color Header     = Color.FromArgb(214, 227, 245);
        public static readonly Color AdminRow   = Color.FromArgb(228, 236, 248);
        public static readonly Color Panel      = Color.FromArgb(236, 238, 242);
        public static readonly Color Surface    = Color.White;
        public static readonly Color Border     = Color.FromArgb(165, 178, 196);
        public static readonly Color AltRow     = Color.FromArgb(247, 249, 252);
        public static readonly Color Pressed    = Color.FromArgb(190, 210, 238);
        public static readonly Color Select     = Color.FromArgb(204, 224, 247);
        public static readonly Color GridLine   = Color.FromArgb(225, 230, 237);
        public static readonly Color Text       = Color.FromArgb(32, 38, 46);
        public static readonly Color Muted      = Color.FromArgb(108, 118, 130);
    }

    // Exposed to PowerShell as $App.Theme so tabs can match the host styling.
    public class Theme
    {
        public string FontName     { get; internal set; }
        public float  FontSizePt   { get; internal set; }
        public string MonoFontName { get; internal set; }
        public Color Title    { get; internal set; }
        public Color Section  { get; internal set; }
        public Color Header   { get; internal set; }
        public Color Panel    { get; internal set; }
        public Color Surface  { get; internal set; }
        public Color Border   { get; internal set; }
        public Color AltRow   { get; internal set; }
        public Color Pressed  { get; internal set; }
        public Color Select   { get; internal set; }
        public Color Text     { get; internal set; }
        public Color Muted    { get; internal set; }

        public static Theme Default()
        {
            return new Theme
            {
                FontName = "Segoe UI", FontSizePt = 9f, MonoFontName = "Consolas",
                Title = Palette.Title, Section = Palette.Section, Header = Palette.Header,
                Panel = Palette.Panel, Surface = Palette.Surface, Border = Palette.Border,
                AltRow = Palette.AltRow, Pressed = Palette.Pressed, Select = Palette.Select,
                Text = Palette.Text, Muted = Palette.Muted
            };
        }

        // A styled flat button, matching the host's dev-row buttons.
        public Button MakeButton(string text)
        {
            var b = new Button { Text = text, AutoSize = true };
            StyleButton(b);
            return b;
        }

        public void StyleButton(Button b)
        {
            b.FlatStyle = FlatStyle.Flat;
            b.UseVisualStyleBackColor = false;
            b.BackColor = Surface;
            b.ForeColor = Title;
            b.FlatAppearance.BorderColor = Border;
            b.FlatAppearance.MouseOverBackColor = Header;
            b.FlatAppearance.MouseDownBackColor = Pressed;
            b.AutoSize = true;
            b.MinimumSize = new Size(80, 26);
            b.Padding = new Padding(6, 0, 6, 0);
            b.Margin = new Padding(3, 3, 3, 3);
            b.Font = new Font(FontName, FontSizePt);
        }
    }

    // =====================================================================
    //  App context handed to the PowerShell launcher ($App)
    // =====================================================================
    public class AppContext
    {
        internal MainForm Owner;

        public string ExePath        { get; internal set; }
        public string LocalAppData   { get; internal set; }
        public string DataRoot       { get; internal set; }
        public string DataRootStatus { get; internal set; }  // Network | LocalFallback | LocalOnly
        public string Version        { get; internal set; }
        public string TemplateVersion { get; internal set; }   // TEMPLATE_VERSION.txt: the AppTemplate engine this build is on
        public string Tier           { get; internal set; }  // Developer | Admin | User
        public bool   Diagnostics    { get; internal set; }
        public bool   CanEditDefaults{ get; internal set; }
        public Theme  Theme          { get; internal set; }
        public string ActiveName     { get; internal set; }
        public string ActiveLabel    { get; internal set; }
        public string SharedPath     { get; internal set; }

        internal Dictionary<string, object> ActiveEnv;

        public string GetSetting(string key)
        {
            if (ActiveEnv != null && key != null && ActiveEnv.ContainsKey(key) && ActiveEnv[key] != null)
                return ActiveEnv[key].ToString();
            return "";
        }

        // ---- environment selection (used by the Environment tab) ----
        public string[] EnvironmentLabels()   { return Owner != null ? Owner.EnvLabels() : new string[0]; }
        public int      ActiveEnvironmentIndex() { return Owner != null ? Owner.ActiveIndex() : 0; }
        public void     SelectEnvironmentIndex(int i) { if (Owner != null) Owner.SelectIndex(i); }
        public string[] EnvironmentNames()    { return Owner != null ? Owner.EnvNames() : new string[0]; }
        public bool     SelectEnvironment(string name)
        {
            if (Owner == null || name == null) return false;
            var names = Owner.EnvNames();
            for (int i = 0; i < names.Length; i++)
                if (string.Equals(names[i], name, StringComparison.OrdinalIgnoreCase)) { Owner.SelectIndex(i); return true; }
            return false;
        }
        // The ONE file the environments are saved in (Environment tab: New / Save /
        // Delete). Developer build: Source\Config\Environments.json - the set that
        // is built into the Lite EXE. Lite EXE (admin password): per machine, in
        // <LocalAppData>\<app>\Settings\Environments.json, over the built-in set.
        // PowerShell writes it, then calls ReloadEnvironments().
        public string EnvironmentStorePath { get { return MainForm.EnvironmentStorePath(); } }
        public bool   EnvironmentsAreSource { get { return MainForm.EnvironmentsAreSource; } }
        public void   ReloadEnvironments() { if (Owner != null) Owner.ReloadEnvironmentList(); }

        // ---- editing (developer build only) ----
        public void SetActiveEnvField(string key, string value) { if (Owner != null) Owner.SetActiveField(key, value); }

        // ---- logging ----
        public void Log(string level, string source, string text) { AppHostLog.WriteSession(DataRoot, level, source, text, Diagnostics); }
        public void LogAction(string text)
        {
            int kb; if (!int.TryParse(GetSetting("LogMaxKB"), out kb) || kb < 64) kb = 5120;   // per environment (Environment > General)
            AppHostLog.WriteEnv(DataRoot, ActiveName, text, kb);
        }
        public void Diag(string source, string text) { if (Diagnostics) AppHostLog.WriteSession(DataRoot, "DIAG", source, text, true); }

        // ---- status bar message (right-hand side of the bottom bar) ----
        // level: info | ok | warn | err. Repaints immediately, so progress text
        // is visible during long synchronous work in a tab.
        public void SetStatus(string text) { SetStatus(text, "info"); }
        public void SetStatus(string text, string level) { if (Owner != null) Owner.ShowStatusMessage(text, level); }

        // ---- logging settings saved at runtime (Settings\Logging.json) ----
        // Applied by the PowerShell side at start-up and after a save on the
        // Environment tab's Logging page: diagnostics on/off, Session.log cap.
        public void ConfigureLogging(bool diagnostics, int sessionLogMaxKb)
        {
            Diagnostics = diagnostics;
            if (sessionLogMaxKb >= 64) AppHostLog.SessionLogMaxKb = sessionLogMaxKb;
        }
    }

    // =====================================================================
    //  Logging -- written to the resolved data root; never packed into the EXE
    // =====================================================================
    static class AppHostLog
    {
        static readonly object _gate = new object();
        internal static int SessionLogMaxKb = 10240;   // set via $App.ConfigureLogging

        static string Stamp()
        {
            DateTime now = DateTime.Now;
            return now.ToString("yyyy-MM-dd HH:mm:ss") + " " + now.ToString("zzz") + " [" + Environment.MachineName + "]";
        }

        static void AppendFifo(string path, string line, int maxKb)
        {
            try
            {
                string dir = Path.GetDirectoryName(path);
                if (!Directory.Exists(dir)) Directory.CreateDirectory(dir);
                lock (_gate)
                {
                    File.AppendAllText(path, line + Environment.NewLine, new UTF8Encoding(false));
                    var fi = new FileInfo(path);
                    long limit = (long)maxKb * 1024L;
                    if (maxKb > 0 && fi.Length > limit)
                    {
                        // Trim to 90% of the cap, not to the cap itself: trimming to exactly
                        // the cap left the file full, so EVERY later line read and rewrote
                        // the whole log (10 MB by default; far slower on a network share).
                        string[] all = File.ReadAllLines(path);
                        long size = fi.Length, target = limit / 10 * 9; int i = 0;
                        while (i < all.Length && size > target) { size -= Encoding.UTF8.GetByteCount(all[i]) + Environment.NewLine.Length; i++; }
                        if (i > 0 && i < all.Length) File.WriteAllLines(path, all.Skip(i).ToArray(), new UTF8Encoding(false));
                    }
                }
            }
            catch { }
        }

        public static void WriteSession(string dataRoot, string level, string source, string text, bool diag)
        {
            if (string.Equals(level, "DIAG", StringComparison.OrdinalIgnoreCase) && !diag) return;
            AppendFifo(Path.Combine(dataRoot, "Logs", "Session.log"),
                Stamp() + "  " + (level ?? "INFO").PadRight(5) + " [" + (source ?? "-") + "] " + (text ?? ""), SessionLogMaxKb);
        }

        public static void WriteEnv(string dataRoot, string envName, string text, int maxKb)
        {
            string name = string.IsNullOrEmpty(envName) ? "NO-ENV" : SanitizeName(envName);
            AppendFifo(Path.Combine(dataRoot, "Logs", name + ".log"), Stamp() + "  " + (text ?? ""), maxKb);
        }

        static string SanitizeName(string s)
        {
            foreach (char c in Path.GetInvalidFileNameChars()) s = s.Replace(c, '_');
            return s.Replace(' ', '_');
        }
    }

    // =====================================================================
    //  Bundle sealing -- AES-256-CBC, key = PBKDF2(password). Password is the key.
    //     "SEAL"(4) | salt(16) | iter(4,LE) | iv(16) | AES( "APKG"(4) | zip )
    // =====================================================================
    static class Bundles
    {
        static readonly byte[] Magic = Encoding.ASCII.GetBytes("SEAL");
        static readonly byte[] Inner = Encoding.ASCII.GetBytes("APKG");
        public const int DefaultIterations = 310000;

        public static byte[] Seal(byte[] plainZip, string password, int iterations)
        {
            byte[] salt = new byte[16];
            using (var rng = RandomNumberGenerator.Create()) rng.GetBytes(salt);
            byte[] key;
            using (var kdf = new Rfc2898DeriveBytes(password, salt, iterations)) key = kdf.GetBytes(32);
            using (var aes = Aes.Create())
            {
                aes.KeySize = 256; aes.Key = key; aes.GenerateIV();
                byte[] inner = new byte[Inner.Length + plainZip.Length];
                Array.Copy(Inner, 0, inner, 0, Inner.Length);
                Array.Copy(plainZip, 0, inner, Inner.Length, plainZip.Length);
                byte[] ct;
                using (var enc = aes.CreateEncryptor()) ct = enc.TransformFinalBlock(inner, 0, inner.Length);
                using (var ms = new MemoryStream())
                {
                    ms.Write(Magic, 0, Magic.Length);
                    ms.Write(salt, 0, salt.Length);
                    ms.Write(BitConverter.GetBytes(iterations), 0, 4);
                    ms.Write(aes.IV, 0, aes.IV.Length);
                    ms.Write(ct, 0, ct.Length);
                    return ms.ToArray();
                }
            }
        }

        public static byte[] UnsealZip(byte[] blob, string password)
        {
            if (blob == null || blob.Length < Magic.Length + 16 + 4 + 16) return null;
            for (int i = 0; i < Magic.Length; i++) if (blob[i] != Magic[i]) return null;
            int off = Magic.Length;
            byte[] salt = new byte[16]; Array.Copy(blob, off, salt, 0, 16); off += 16;
            int iter = BitConverter.ToInt32(blob, off); off += 4;
            byte[] iv = new byte[16]; Array.Copy(blob, off, iv, 0, 16); off += 16;
            int ctLen = blob.Length - off;
            if (iter < 1 || ctLen <= 0) return null;
            byte[] key;
            using (var kdf = new Rfc2898DeriveBytes(password, salt, iter)) key = kdf.GetBytes(32);
            try
            {
                using (var aes = Aes.Create())
                {
                    aes.KeySize = 256; aes.Key = key; aes.IV = iv;
                    byte[] inner;
                    using (var dec = aes.CreateDecryptor()) inner = dec.TransformFinalBlock(blob, off, ctLen);
                    if (inner.Length < Inner.Length) return null;
                    for (int i = 0; i < Inner.Length; i++) if (inner[i] != Inner[i]) return null;
                    byte[] zip = new byte[inner.Length - Inner.Length];
                    Array.Copy(inner, Inner.Length, zip, 0, zip.Length);
                    return zip;
                }
            }
            catch { return null; }
        }

        public static Dictionary<string, string> ZipBytesToDict(byte[] zip)
        {
            var d = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            using (var ms = new MemoryStream(zip))
            using (var za = new ZipArchive(ms, ZipArchiveMode.Read))
                foreach (var e in za.Entries)
                {
                    if (string.IsNullOrEmpty(e.Name)) continue;
                    using (var r = new StreamReader(e.Open(), Encoding.UTF8)) d[e.FullName.Replace('\\', '/')] = r.ReadToEnd();
                }
            return d;
        }

        public static byte[] DictToZipBytes(Dictionary<string, string> files)
        {
            using (var ms = new MemoryStream())
            {
                using (var za = new ZipArchive(ms, ZipArchiveMode.Create, true))
                    foreach (var kv in files)
                    {
                        var entry = za.CreateEntry(kv.Key.Replace('\\', '/'));
                        using (var w = new StreamWriter(entry.Open(), new UTF8Encoding(false))) w.Write(kv.Value);
                    }
                return ms.ToArray();
            }
        }
    }

    // =====================================================================
    //  Project identity -- AppIdentity.json (project-owned, source root)
    //     { "AppName": "...", "ExeName": "...", "AppDataFolder": "..." }
    //  AppName = window title, dialogs, EXE product name; ExeName = <ExeName>Dev.exe / <ExeName>Lite.exe
    //  and the archive / Extract names; AppDataFolder = %LOCALAPPDATA%\<folder>.
    //  This file has no project-specific lines, so it is byte-identical in
    //  every project. Read from the plain AppIdentity.json resource (builds made
    //  by Build-App.exe, Update, Build Lite since template 1.0.17), else from
    //  the developer package (a build compiled by an older Update engine).
    // =====================================================================
    static class ProjectIdentity
    {
        public const string FileName = "AppIdentity.json";
        public static readonly string AppName, ExeName, AppDataFolder;
        public static readonly string Source;     // resource | package | missing | invalid (...)
        public static bool Ok { get { return Source == "resource" || Source == "package"; } }

        static ProjectIdentity()
        {
            string json = null, src = "missing";
            try { json = ReadResource(FileName); if (json != null) src = "resource"; } catch { }
            if (json == null)
                try { json = ReadFromPackage(); if (json != null) src = "package"; } catch { }
            string a = null, x = null, d = null, why;
            if (json != null && !TryParse(json, out a, out x, out d, out why)) src = "invalid (" + why + ")";
            if (src == "resource" || src == "package") { AppName = a; ExeName = x; AppDataFolder = d; }
            else { AppName = "App Template"; ExeName = "AppTemplate"; AppDataFolder = "AppTemplateData"; }
            Source = src;
        }

        static string ReadResource(string name)
        {
            using (Stream s = Assembly.GetExecutingAssembly().GetManifestResourceStream(name))
            {
                if (s == null) return null;
                using (var r = new StreamReader(s, Encoding.UTF8)) return r.ReadToEnd();
            }
        }

        static string ReadFromPackage()
        {
            using (Stream s = Assembly.GetExecutingAssembly().GetManifestResourceStream("AppPackage.zip"))
            {
                if (s == null) return null;
                using (var za = new ZipArchive(s, ZipArchiveMode.Read))
                    foreach (var e in za.Entries)
                        if (string.Equals(e.FullName, FileName, StringComparison.OrdinalIgnoreCase))
                            using (var r = new StreamReader(e.Open(), Encoding.UTF8)) return r.ReadToEnd();
            }
            return null;
        }

        // Parse and validate an AppIdentity.json text. All three names are
        // required; ExeName and AppDataFolder must be valid file names.
        public static bool TryParse(string json, out string appName, out string exeName, out string dataFolder, out string why)
        {
            appName = exeName = dataFolder = null; why = null;
            Dictionary<string, object> o;
            try { o = new JavaScriptSerializer().DeserializeObject(json ?? "") as Dictionary<string, object>; }
            catch (Exception ex) { why = "not valid JSON: " + ex.Message; return false; }
            if (o == null) { why = "not a JSON object"; return false; }
            appName = Field(o, "AppName"); exeName = Field(o, "ExeName"); dataFolder = Field(o, "AppDataFolder");
            if (appName == "" || exeName == "" || dataFolder == "") { why = "AppName, ExeName and AppDataFolder are all required"; return false; }
            foreach (char c in Path.GetInvalidFileNameChars())
                if (exeName.IndexOf(c) >= 0 || dataFolder.IndexOf(c) >= 0) { why = "ExeName / AppDataFolder contain a character not allowed in a file name"; return false; }
            return true;
        }

        static string Field(Dictionary<string, object> o, string key)
        {
            foreach (var kv in o)
                if (string.Equals(kv.Key, key, StringComparison.OrdinalIgnoreCase) && kv.Value != null) return kv.Value.ToString().Trim();
            return "";
        }

        // The canonical file text for a set of names (embedded by every build).
        public static string ToJson(string appName, string exeName, string dataFolder)
        {
            var js = new JavaScriptSerializer();
            return "{\r\n" +
                   "    \"AppName\": " + js.Serialize(appName) + ",\r\n" +
                   "    \"ExeName\": " + js.Serialize(exeName) + ",\r\n" +
                   "    \"AppDataFolder\": " + js.Serialize(dataFolder) + "\r\n" +
                   "}\r\n";
        }

        public static string CurrentJson() { return ToJson(AppName, ExeName, AppDataFolder); }
    }

    // =====================================================================
    //  System facts -- cheap, logged on the Session.log start line of every
    //  build (sealed included), so Session.log alone describes the machine.
    //  Each read is guarded: a value that cannot be read says "unknown".
    // =====================================================================
    static class SystemFacts
    {
        static string _line;

        // "os='Windows Server 2019 Standard 1809 build 17763.6414' ps=5.1.17763.6414 net=4.8 x64/x64"
        public static string Line()
        {
            if (_line == null)
                _line = "os='" + Windows() + "' ps=" + PowerShell() + " net=" + DotNet() + " " + Bitness();
            return _line;
        }

        // Product name + release + build from the registry (Environment.OSVersion
        // reports 6.2 on every Windows since 8 for an EXE without a manifest).
        public static string Windows()
        {
            try
            {
                using (var k = Microsoft.Win32.Registry.LocalMachine.OpenSubKey(@"SOFTWARE\Microsoft\Windows NT\CurrentVersion"))
                {
                    if (k == null) return Environment.OSVersion.ToString();
                    string name = Convert.ToString(k.GetValue("ProductName") ?? "Windows");
                    string rel  = Convert.ToString(k.GetValue("DisplayVersion") ?? k.GetValue("ReleaseId") ?? "");
                    string build = Convert.ToString(k.GetValue("CurrentBuild") ?? k.GetValue("CurrentBuildNumber") ?? "");
                    object ubr = k.GetValue("UBR");
                    return (name + (rel == "" ? "" : " " + rel) + (build == "" ? "" : " build " + build + (ubr == null ? "" : "." + ubr))).Trim();
                }
            }
            catch { return "unknown"; }
        }

        // $PSVersionTable.PSVersion, read from System.Management.Automation without
        // starting a runspace.
        public static string PowerShell()
        {
            try
            {
                var t = typeof(System.Management.Automation.PowerShell).Assembly.GetType("System.Management.Automation.PSVersionInfo");
                if (t != null)
                {
                    var p = t.GetProperty("PSVersion", BindingFlags.Static | BindingFlags.Public | BindingFlags.NonPublic);
                    object v = p != null ? p.GetValue(null, null) : null;
                    if (v != null) return v.ToString();
                }
            }
            catch { }
            return "unknown";
        }

        // The installed .NET Framework 4.x release (Environment.Version says
        // 4.0.30319 for every 4.x).
        public static string DotNet()
        {
            try
            {
                using (var k = Microsoft.Win32.Registry.LocalMachine.OpenSubKey(@"SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full"))
                {
                    object o = k == null ? null : k.GetValue("Release");
                    if (o == null) return "4.x (" + Environment.Version + ")";
                    int r = Convert.ToInt32(o);
                    string v = r >= 533320 ? "4.8.1" : r >= 528040 ? "4.8" : r >= 461808 ? "4.7.2" : r >= 461308 ? "4.7.1" :
                               r >= 460798 ? "4.7" : r >= 394802 ? "4.6.2" : r >= 394254 ? "4.6.1" : r >= 393295 ? "4.6" : "4.5.x";
                    return v;
                }
            }
            catch { return "unknown"; }
        }

        // "process/OS", e.g. x64/x64; x86/x64 = a 32-bit process on 64-bit Windows.
        public static string Bitness()
        {
            return (Environment.Is64BitProcess ? "x64" : "x86") + "/" + (Environment.Is64BitOperatingSystem ? "x64" : "x86");
        }
    }

    // =====================================================================
    //  Main form
    // =====================================================================
    class MainForm : Form
    {
        // Project identity: from AppIdentity.json (see ProjectIdentity above).
        internal static readonly string AppName       = ProjectIdentity.AppName;
        internal static readonly string ExeName       = ProjectIdentity.ExeName;
        internal static readonly string AppDataFolder = ProjectIdentity.AppDataFolder;

        // Window size the app is laid out for: the remote-server session these
        // tools run in (Win32_VideoController 1885 x 1020). On a screen that size
        // or smaller the window opens maximized; on a bigger one it opens at this
        // size, centred. Change both numbers to re-target every project built
        // from this source.
        const int TargetScreenWidth  = 1885;
        const int TargetScreenHeight = 1020;

        // resource names
        const string PackageResource = "AppPackage.zip"; // developer build only
        const string SourceResource  = "core.dat";       // developer build only
        const string BuilderResource = "Build-App.cs";   // developer build only: source of Build-App.exe
        const string UpdateFolderName = "Update";        // beside the developer EXE: default place for update zips
        const string SourceFile      = "AppHost.cs";

        readonly Dictionary<string, string> _runFiles;
        readonly string _tier;
        readonly Theme _theme = Theme.Default();

        TabControl _tabs;
        Label      _statusLabel;
        Label      _msgLabel;     // $App.SetStatus() messages (right of the bottom bar)
        FlowLayoutPanel _devRow;
        AppContext _ctx;
        Runspace   _rs;   // kept open for the form's lifetime so PS event handlers can run

        string _localRoot, _dataRoot, _dataRootStatus, _version, _activeName, _activeDefault;
        string _templateVersion = "";
        bool   _diagnostics;
        List<Dictionary<string, object>> _environments = new List<Dictionary<string, object>>();

        public MainForm(Dictionary<string, string> runFiles, string tier)
        {
            _runFiles = runFiles ?? new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            _tier = tier ?? "User";

            StartPosition = FormStartPosition.CenterScreen;
            Size = new Size(1020, 700);
            MinimumSize = new Size(820, 520);
            FitToTargetScreen();
            Font = new Font(_theme.FontName, _theme.FontSizePt);
            BackColor = _theme.Surface;
            ForeColor = _theme.Text;

            _version = ReadVersion();
            _templateVersion = _runFiles.ContainsKey("TEMPLATE_VERSION.txt") ? _runFiles["TEMPLATE_VERSION.txt"].Trim().TrimStart('v', 'V') : "";
            Text = AppName + "  --  " + _tier;

            BuildUi();
            ResolveStartup();
        }

        // Size the window for TargetScreenWidth x TargetScreenHeight (see above).
        void FitToTargetScreen()
        {
            try
            {
                Rectangle wa = Screen.PrimaryScreen.WorkingArea;
                if (wa.Width <= TargetScreenWidth || wa.Height <= TargetScreenHeight)
                {
                    StartPosition = FormStartPosition.Manual;
                    Bounds = wa;                                   // restore size = the whole work area
                    WindowState = FormWindowState.Maximized;
                }
                else
                {
                    StartPosition = FormStartPosition.CenterScreen;
                    Size = new Size(TargetScreenWidth, TargetScreenHeight);
                }
            }
            catch { }
        }

        // ---------------- UI ----------------
        void BuildUi()
        {
            _devRow = new FlowLayoutPanel
            {
                Dock = DockStyle.Top, Height = 40, Padding = new Padding(8, 6, 8, 6),
                WrapContents = false, BackColor = _theme.Panel
            };
#if !SEALED
            // Developer tooling -- present only in the developer build.
            // Everyday: Build Lite, Version History, Open. The zip-based tools from
            // before git (Update, Update Template, Extract, Archive) are kept for
            // manual use under More - nothing runs on its own.
            _devRow.Controls.Add(StyledButton("Build Lite",      delegate { BuildLiteNow(); }));
            _devRow.Controls.Add(StyledButton("Version History", delegate { ShowVersionHistory(); }));
            Button open = null;
            open = StyledButton("Open \u25BE", delegate { ShowOpenMenu(open); });
            _devRow.Controls.Add(open);
            Button more = null;
            more = StyledButton("More \u25BE", delegate { ShowMoreMenu(more); });
            _devRow.Controls.Add(more);
#else
            // Sealed (runtime) build: no developer tooling.
            _devRow.Visible = false;
            _devRow.Height = 0;
#endif

            var bottom = new Panel { Dock = DockStyle.Bottom, Height = 26, BackColor = _theme.Header };
            _statusLabel = new Label { Dock = DockStyle.Fill, ForeColor = _theme.Title, Padding = new Padding(10, 5, 10, 0), AutoEllipsis = true };
            bottom.Controls.Add(_statusLabel);
            _msgLabel = new Label { Dock = DockStyle.Right, Width = 560, ForeColor = _theme.Muted, Padding = new Padding(10, 5, 10, 0),
                                    AutoEllipsis = true, TextAlign = ContentAlignment.TopRight };
            bottom.Controls.Add(_msgLabel);

            _tabs = new TabControl { Dock = DockStyle.Fill, Font = new Font(_theme.FontName, _theme.FontSizePt) };

            Controls.Add(_tabs);
            Controls.Add(bottom);
            Controls.Add(_devRow);
        }

        // Run the WinForms message loop THROUGH the runspace, so a PowerShell
        // pipeline is active for the whole UI lifetime. Without this, script-block
        // event handlers that use try/catch/finally throw a NullReferenceException
        // in SuspendStoppingPipeline (no pipeline on the event thread). This is how
        // the message loop was hosted in the source tool. Called by Program.Main
        // instead of Application.Run().
        public void RunMessageLoop()
        {
            if (_rs == null) { Application.Run(this); return; }   // fallback if the runspace never opened
            try
            {
                using (PowerShell ps = PowerShell.Create())
                {
                    ps.Runspace = _rs;
                    ps.AddScript("[System.Windows.Forms.Application]::Run($AppForm)");
                    ps.Invoke();
                }
            }
            finally
            {
                try { if (Runspace.DefaultRunspace == _rs) Runspace.DefaultRunspace = null; } catch { }
                try { _rs.Close(); _rs.Dispose(); _rs = null; } catch { }
            }
        }

        Button StyledButton(string text, EventHandler onClick)
        {
            var b = _theme.MakeButton(text);
            // Grows to fit its text on one line (a fixed width wrapped "Update
            // Template" and clipped its second line); never narrower than 118.
            b.AutoSize = true; b.AutoSizeMode = AutoSizeMode.GrowOnly;
            b.MinimumSize = new Size(118, 28); b.MaximumSize = new Size(0, 28);
            if (onClick != null) b.Click += onClick;
            return b;
        }

        // ---------------- startup resolution ----------------
        void ResolveStartup()
        {
            _localRoot = GetLocalAppDataRoot();
            try { if (!Directory.Exists(_localRoot)) Directory.CreateDirectory(_localRoot); } catch { }

            _diagnostics = ReadDiagnostics(_runFiles);
#if !SEALED
            MoveStrayEnvironments();
#endif
            LoadEnvironments(_runFiles);
            WriteConfigMirror(_runFiles, _localRoot);

            _activeName = ReadActivePick();
            if (!_environments.Any(en => NameOf(en) == _activeName)) _activeName = DefaultEnvName();

            var env = ActiveEnvDict();
            ResolveDataRootFor(env);

            _ctx = new AppContext
            {
                Owner = this,
                ExePath = Application.ExecutablePath, LocalAppData = _localRoot,
                Version = _version, TemplateVersion = _templateVersion, Tier = _tier, Diagnostics = _diagnostics,
                CanEditDefaults = (_tier != "User"), Theme = _theme     // admin password + developer build edit environments
            };
            FillContext(env);
            _ctx.Log("INFO", "Startup", "Launched tier=" + _tier + " v" + _version + " template=" + (_templateVersion == "" ? "unknown" : _templateVersion) +
                                        " env='" + _activeName + "' root=" + _dataRootStatus);
            _ctx.Log("INFO", "Startup", "System: " + SystemFacts.Line());
            if (!ProjectIdentity.Ok)
                _ctx.Log("WARN", "Identity", ProjectIdentity.FileName + " " + ProjectIdentity.Source +
                         " - running as '" + AppName + "' (AppData folder " + AppDataFolder + "). Add " + ProjectIdentity.FileName + " to the project root and rebuild.");
#if !SEALED
            if (_strayEnvNote != null) _ctx.Log("INFO", "Environment", _strayEnvNote);
#endif

            BuildTabs();
#if !SEALED
            if (!ProjectIdentity.Ok)
                ShowStatusMessage(ProjectIdentity.FileName + " " + ProjectIdentity.Source + " - using template names (see Session.log).", "err");
#endif
        }

        Dictionary<string, object> ActiveEnvDict()
        {
            return _environments.FirstOrDefault(en => NameOf(en) == _activeName)
                   ?? (_environments.Count > 0 ? _environments[0] : new Dictionary<string, object>());
        }

        void ResolveDataRootFor(Dictionary<string, object> env)
        {
            string shared = FieldOf(env, "SharedPath");
            if (!string.IsNullOrWhiteSpace(shared))
            {
                string root = Path.Combine(shared, AppDataFolder);
                if (ProbeWritable(root, 1500)) { _dataRoot = root; _dataRootStatus = "Network"; }
                else                           { _dataRoot = _localRoot; _dataRootStatus = "LocalFallback"; }
            }
            else { _dataRoot = _localRoot; _dataRootStatus = "LocalOnly"; }
            try { Directory.CreateDirectory(Path.Combine(_dataRoot, "Logs")); } catch { }
        }

        // Update the shared context object in place (PowerShell holds the same reference).
        void FillContext(Dictionary<string, object> env)
        {
            _ctx.DataRoot = _dataRoot; _ctx.DataRootStatus = _dataRootStatus;
            _ctx.ActiveName = _activeName; _ctx.ActiveLabel = LabelOf(env);
            _ctx.SharedPath = FieldOf(env, "SharedPath"); _ctx.ActiveEnv = env;

            if (_statusLabel != null)
                _statusLabel.Text = "Environment: " + LabelOf(env) + "    Data: " +
                    (_dataRootStatus == "Network"       ? "shared (" + _ctx.SharedPath + ")" :
                     _dataRootStatus == "LocalFallback" ? "local fallback (share unreachable)" : "local") +
                    "    v" + _version + TemplateLabel() + "    [" + _tier + "]";
        }

        // ---- internal API used by $App (Environment tab) ----
        internal string[] EnvLabels() { return _environments.Select(LabelOf).ToArray(); }
        internal int ActiveIndex() { int i = _environments.FindIndex(en => NameOf(en) == _activeName); return i < 0 ? 0 : i; }

        internal void SelectIndex(int i)
        {
            if (i < 0 || i >= _environments.Count) return;
            var env = _environments[i];
            _activeName = NameOf(env);
            WriteActivePick(_activeName);
            ResolveDataRootFor(env);
            FillContext(env);
            _ctx.Log("INFO", "Environment", "Switched to '" + _activeName + "' root=" + _dataRootStatus);
        }

        internal void SetActiveField(string key, string value)
        {
            var env = ActiveEnvDict();
            if (env != null) env[key] = value;
        }

        // Project folder layout (template 1.1):
        //   <ExeName>Dev.exe, <ExeName>Lite.exe, Build-App.cmd  the only files at the top
        //   Source\    every source file (package paths: AppHost.cs, Config/..., Modules/...)
        //   Build\     Build-App.exe          Archive\, Update\  as before
        // A pre-1.1 flat folder (source beside the EXE) still works: no Source\ folder.
        internal static string SourceDir()
        {
            string exeDir = Path.GetDirectoryName(Application.ExecutablePath);
            string src = Path.Combine(exeDir, "Source");
            return Directory.Exists(src) ? src : exeDir;
        }

#if !SEALED
        // Template 1.1.x saved the developer's environments to Config\Environments.json
        // BESIDE the EXE (a path from before the Source\ folder), where nothing read
        // them. From 1.2 the developer build saves straight into Source\Config. On the
        // first start, a leftover file there is moved into Source\Config (the file it
        // replaces is kept as Environments.json.bak) and the empty folder removed.
        string _strayEnvNote;
        void MoveStrayEnvironments()
        {
            try
            {
                if (SourceDir().Equals(ExeDir(), StringComparison.OrdinalIgnoreCase)) return;   // pre-1.1 flat folder: same place
                string strayDir = Path.Combine(ExeDir(), "Config"), stray = Path.Combine(strayDir, "Environments.json");
                if (!File.Exists(stray)) return;
                string dest = EnvironmentStorePath();
                Directory.CreateDirectory(Path.GetDirectoryName(dest));
                if (File.Exists(dest)) File.Copy(dest, dest + ".bak", true);
                File.Copy(stray, dest, true);
                File.Delete(stray);
                if (Directory.GetFileSystemEntries(strayDir).Length == 0) Directory.Delete(strayDir);
                _runFiles["Config/Environments.json"] = File.ReadAllText(dest, Encoding.UTF8);
                _strayEnvNote = "Moved the environments saved beside the EXE (" + stray + ") into " + dest +
                                " (the previous file is " + Path.GetFileName(dest) + ".bak). Commit it to keep them.";
            }
            catch (Exception ex) { _strayEnvNote = "Could not move " + Path.Combine(ExeDir(), "Config", "Environments.json") + " into Source\\Config: " + ex.Message; }
        }
#endif

        // ---------------- PowerShell-built tabs ----------------
        void BuildTabs()
        {
            _tabs.TabPages.Clear();
            if (!_runFiles.ContainsKey("_AppLauncher.ps1")) { ShowFatalTab("_AppLauncher.ps1 not found in this tier's files."); return; }

            var modules = new Hashtable(StringComparer.OrdinalIgnoreCase);
            var dupes = new List<string>();
            // Only the project's own Modules/<tier>/*.psm1 - never a copy of the
            // project that ended up nested inside the source folder (e.g. an old
            // version unzipped into a subfolder), which would replace modules at random.
            var stray = new List<string>();
            foreach (var kv in _runFiles)
                if (kv.Key.EndsWith(".psm1", StringComparison.OrdinalIgnoreCase) &&
                    !kv.Key.StartsWith("Modules/", StringComparison.OrdinalIgnoreCase))
                    stray.Add(kv.Key);
            if (stray.Count > 0)
                _ctx.Log("WARN", "Launcher", "Ignored " + stray.Count + " module file(s) outside Modules/ (nested copies?): " + string.Join(", ", stray.Take(10).ToArray()));
            foreach (var kv in _runFiles)
                if (kv.Key.StartsWith("Modules/", StringComparison.OrdinalIgnoreCase) &&
                    kv.Key.EndsWith(".psm1", StringComparison.OrdinalIgnoreCase))
                {
                    string mn = Path.GetFileNameWithoutExtension(kv.Key);
                    if (modules.ContainsKey(mn)) dupes.Add(kv.Key);
                    modules[mn] = kv.Value;
                }
            // Modules are keyed by FILE NAME, so two files with the same name in
            // different tier folders would silently replace each other. Say so.
            if (dupes.Count > 0)
                _ctx.Log("ERROR", "Launcher", "Duplicate module file name(s); only one copy of each is loaded: " + string.Join(", ", dupes.ToArray()));

            try
            {
                var iss = InitialSessionState.CreateDefault();
                iss.ApartmentState  = ApartmentState.STA;
                iss.ThreadOptions   = PSThreadOptions.UseCurrentThread;
                iss.ExecutionPolicy = Microsoft.PowerShell.ExecutionPolicy.Bypass;

                // The runspace stays OPEN for the form's lifetime: tab event handlers
                // are PowerShell script blocks that need it when they fire. We set it as
                // this thread's DefaultRunspace; the message loop then runs THROUGH this
                // runspace in RunMessageLoop() (so a pipeline is always active), and it is
                // disposed there when the form closes.
                Runspace rs = RunspaceFactory.CreateRunspace(iss);
                rs.Open();
                Runspace.DefaultRunspace = rs;
                _rs = rs;

                rs.SessionStateProxy.SetVariable("App", _ctx);
                rs.SessionStateProxy.SetVariable("MainTabs", _tabs);
                rs.SessionStateProxy.SetVariable("AppForm", this);
                rs.SessionStateProxy.SetVariable("Modules", modules);
                using (PowerShell ps = PowerShell.Create())
                {
                    ps.Runspace = rs;
                    ps.AddScript(_runFiles["_AppLauncher.ps1"]);
                    ps.Invoke();
                    if (ps.Streams.Error.Count > 0)
                    {
                        var sb = new StringBuilder();
                        foreach (var err in ps.Streams.Error) sb.AppendLine(err.ToString());
                        _ctx.Log("ERROR", "Launcher", sb.ToString().Trim());
                    }
                }
            }
            catch (Exception ex) { ShowFatalTab("Launcher failed: " + ex.Message); _ctx.Log("ERROR", "Launcher", ex.ToString()); }

            if (_tabs.TabPages.Count == 0)
                ShowFatalTab("The launcher ran but added no tabs. Check Modules\\Base\\UI_Register-Tabs.psm1.");
        }

        // A developer EXE reads loose Config\*.json in its source folder (SourceDir) in
        // preference to its embedded copies (so edits are live). Those loose files are
        // the source's - and an update that changes
        // a config file would otherwise never be seen. So an update writes its
        // Config files over the loose copies too, keeping the old one as .bak.
        static void SyncLooseConfig(Dictionary<string, string> incoming)
        {
            try
            {
                string dir = Path.Combine(SourceDir(), "Config");
                if (!Directory.Exists(dir)) return;
                foreach (var kv in incoming)
                {
                    if (!kv.Key.StartsWith("Config/", StringComparison.OrdinalIgnoreCase) ||
                        !kv.Key.EndsWith(".json", StringComparison.OrdinalIgnoreCase)) continue;
                    string loose = Path.Combine(dir, Path.GetFileName(kv.Key));
                    if (!File.Exists(loose)) continue;
                    if (File.ReadAllText(loose, Encoding.UTF8) == kv.Value) continue;
                    File.Copy(loose, loose + ".bak", true);
                    File.WriteAllText(loose, kv.Value, new UTF8Encoding(false));
                }
            }
            catch { }
        }

        // "  (template 1.0.14)" for the status bar.
        string TemplateLabel()
        {
            if (string.IsNullOrEmpty(_templateVersion)) return "";
            return "  (template " + _templateVersion + ")";
        }

        // Template manifest helpers, used by Update Template. TEMPLATE_FILES.txt lists
        // every template-owned file with its SHA-256 (UTF-8 text, LF line endings, no
        // BOM, whole file). Engine drift itself is checked on every push to GitHub
        // (tools\Test-Template.ps1), not when the app starts (removed in 1.2).
        internal static string NormalizedHash(string path, string text)
        {
            string t = (text ?? "").Replace("\uFEFF", "").Replace("\r\n", "\n");
            using (var sha = SHA256.Create())
            {
                var h = sha.ComputeHash(new UTF8Encoding(false).GetBytes(t));
                var sb = new StringBuilder(); foreach (byte x in h) sb.Append(x.ToString("x2")); return sb.ToString();
            }
        }

        // TEMPLATE_FILES.txt -> (path, hash) pairs, in file order.
        internal static List<KeyValuePair<string, string>> ParseManifest(string text)
        {
            var list = new List<KeyValuePair<string, string>>();
            foreach (var raw in (text ?? "").Replace("\r\n", "\n").Split('\n'))
            {
                string ln = raw.Trim();
                if (ln.Length == 0 || ln.StartsWith("#")) continue;
                int sp = ln.IndexOf(' ');
                if (sp <= 0) continue;
                list.Add(new KeyValuePair<string, string>(ln.Substring(sp).Trim(), ln.Substring(0, sp).Trim().ToLowerInvariant()));
            }
            return list;
        }

        // Files listed in a manifest whose text differs from it. requireAll: a
        // listed file missing from the set counts as different (named "(missing)").
        internal static List<string> ManifestDifferences(string manifest, Dictionary<string, string> files, bool requireAll, out int checkedCount)
        {
            var diff = new List<string>(); checkedCount = 0;
            foreach (var kv in ParseManifest(manifest))
            {
                if (!files.ContainsKey(kv.Key)) { if (requireAll) diff.Add(kv.Key + " (missing)"); continue; }
                checkedCount++;
                if (NormalizedHash(kv.Key, files[kv.Key]) != kv.Value) diff.Add(kv.Key);
            }
            return diff;
        }

        // Backs $App.SetStatus(). Colors match the source tool's status bar.
        internal void ShowStatusMessage(string text, string level)
        {
            if (_msgLabel == null) return;
            if (_msgLabel.InvokeRequired) { _msgLabel.BeginInvoke((MethodInvoker)delegate { ShowStatusMessage(text, level); }); return; }
            string lv = (level ?? "").Trim().ToLowerInvariant();
            Color c = _theme.Muted;
            if (lv == "ok") c = Color.FromArgb(0, 97, 0);
            else if (lv == "warn" || lv == "warning") c = Color.FromArgb(130, 90, 0);
            else if (lv == "err" || lv == "error") c = Color.FromArgb(156, 0, 6);
            _msgLabel.ForeColor = c;
            _msgLabel.Text = (text ?? "").Trim();
            try { _msgLabel.Refresh(); } catch { }
        }

        void ShowFatalTab(string message)
        {
            var tp = new TabPage("Startup");
            tp.Controls.Add(new Label { Text = message, Dock = DockStyle.Fill, Padding = new Padding(16), ForeColor = Color.Firebrick });
            _tabs.TabPages.Add(tp);
        }

        // =================================================================
        //  Embedded resource helpers
        // =================================================================
        static byte[] ReadEmbeddedBytes(string name)
        {
            using (Stream s = Assembly.GetExecutingAssembly().GetManifestResourceStream(name))
            {
                if (s == null) return null;
                using (var ms = new MemoryStream()) { s.CopyTo(ms); return ms.ToArray(); }
            }
        }

        static string ReadEmbeddedText(string name)
        {
            byte[] b = ReadEmbeddedBytes(name);
            return b == null ? null : new UTF8Encoding(false).GetString(b);
        }

        string ReadVersion()
        {
            try
            {
                var fvi = FileVersionInfo.GetVersionInfo(Application.ExecutablePath);
                if (!string.IsNullOrEmpty(fvi.ProductVersion)) return fvi.ProductVersion.Trim();
            }
            catch { }
            if (_runFiles.ContainsKey("VERSION.txt")) return _runFiles["VERSION.txt"].Trim().TrimStart('v', 'V');
            return "0.0.0";
        }

        // =================================================================
        //  Environment resolution helpers
        // =================================================================
        static bool ProbeWritable(string root, int timeoutMs)
        {
            bool ok = false;
            var t = new Thread(delegate ()
            {
                try
                {
                    Directory.CreateDirectory(root);
                    string marker = Path.Combine(root, ".probe_" + Guid.NewGuid().ToString("N").Substring(0, 8));
                    File.WriteAllText(marker, "ok"); File.Delete(marker); ok = true;
                }
                catch { ok = false; }
            });
            t.IsBackground = true; t.Start();
            if (!t.Join(timeoutMs)) return false;
            return ok;
        }

        static string GetLocalAppDataRoot()
        {
            return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), AppDataFolder);
        }

        string ReadActivePick()
        {
            try { string p = Path.Combine(_localRoot, "active.env"); if (File.Exists(p)) return File.ReadAllText(p).Trim(); }
            catch { }
            return null;
        }

        void WriteActivePick(string name)
        {
            try { File.WriteAllText(Path.Combine(_localRoot, "active.env"), name ?? "", new UTF8Encoding(false)); } catch { }
        }

        // Environments are saved in ONE file per EXE (template 1.2):
        //   Developer build: Source\Config\Environments.json - the project's own file,
        //     edited on the Environment tab, committed to git, built into the Lite EXE.
        //   Lite EXE: the built-in set, plus what an admin saves on this machine in
        //     <LocalAppData>\<app>\Settings\Environments.json (a sealed EXE cannot
        //     change itself). Built-in environments missing from that file are added -
        //     unless it lists them under "Removed" (deleted on purpose).
        // MaxJsonLength is raised: message pictures make the file larger than the
        // serializer's 2 MB default, which would otherwise silently drop every environment.
#if SEALED
        internal const bool EnvironmentsAreSource = false;
        internal static string EnvironmentStorePath()
        {
            return Path.Combine(GetLocalAppDataRoot(), "Settings", "Environments.json");
        }
#else
        internal const bool EnvironmentsAreSource = true;
        internal static string EnvironmentStorePath()
        {
            return Path.Combine(SourceDir(), "Config", "Environments.json");
        }
#endif

        void LoadEnvironments(Dictionary<string, string> files)
        {
            _environments.Clear(); _activeDefault = null;
            var js = new JavaScriptSerializer { MaxJsonLength = int.MaxValue };
            var embedded = new List<Dictionary<string, object>>();
            string embDefault = null;
            try { if (files.ContainsKey("Config/Environments.json")) ParseEnvironmentList(js, files["Config/Environments.json"], embedded, out embDefault, null); }
            catch (Exception ex) { LogEarly("ERROR", "Embedded Config/Environments.json could not be read: " + ex.Message); }

            var removed = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            bool haveStore = false;
            string store = EnvironmentStorePath();
            try
            {
                if (File.Exists(store))
                {
                    string sDef;
                    haveStore = ParseEnvironmentList(js, File.ReadAllText(store, Encoding.UTF8), _environments, out sDef, removed);
                    _activeDefault = sDef;
                }
            }
            catch (Exception ex)
            {
                haveStore = false; _environments.Clear();
                LogEarly("ERROR", "Environment store " + store + " could not be read (using the embedded set): " + ex.Message);
            }
            if (!haveStore) { _environments.AddRange(embedded); _activeDefault = embDefault; return; }
            if (EnvironmentsAreSource) return;            // developer build: the store IS the project's file
            foreach (var e in embedded)
            {
                string n = NameOf(e);
                if (removed.Contains(n) || _environments.Any(x => string.Equals(NameOf(x), n, StringComparison.OrdinalIgnoreCase))) continue;
                _environments.Add(e);
            }
            if (string.IsNullOrEmpty(_activeDefault)) _activeDefault = embDefault;
        }

        static bool ParseEnvironmentList(JavaScriptSerializer js, string json, List<Dictionary<string, object>> into,
                                         out string activeDefault, HashSet<string> removed)
        {
            activeDefault = null;
            var root = js.DeserializeObject(json) as Dictionary<string, object>;
            if (root == null) return false;
            if (root.ContainsKey("ActiveDefault") && root["ActiveDefault"] != null) activeDefault = root["ActiveDefault"].ToString();
            var arr = root.ContainsKey("Environments") ? root["Environments"] as object[] : null;
            if (arr != null)
                foreach (var o in arr) { var d = o as Dictionary<string, object>; if (d != null && !string.IsNullOrEmpty(NameOf(d))) into.Add(d); }
            if (removed != null && root.ContainsKey("Removed"))
            {
                var r = root["Removed"] as object[];
                if (r != null) foreach (var x in r) if (x != null) removed.Add(x.ToString());
            }
            return true;
        }

        // Before $App exists: write straight to the local Session.log.
        void LogEarly(string level, string text)
        {
            try { AppHostLog.WriteSession(_localRoot ?? GetLocalAppDataRoot(), level, "Environment", text, true); } catch { }
        }

        // Re-read the store after the Environment tab saved it (new / edited /
        // deleted environment) and re-apply the active one.
        internal void ReloadEnvironmentList()
        {
            LoadEnvironments(_runFiles);
            if (!_environments.Any(en => NameOf(en) == _activeName)) { _activeName = DefaultEnvName(); WriteActivePick(_activeName); }
            var env = ActiveEnvDict();
            ResolveDataRootFor(env);
            FillContext(env);
        }

        internal string[] EnvNames() { return _environments.Select(NameOf).ToArray(); }

        static bool ReadDiagnostics(Dictionary<string, string> files)
        {
            try
            {
                if (files.ContainsKey("Config/Logging.json"))
                {
                    var d = new JavaScriptSerializer().DeserializeObject(files["Config/Logging.json"]) as Dictionary<string, object>;
                    if (d != null && d.ContainsKey("DiagnosticsEnabled")) return Convert.ToBoolean(d["DiagnosticsEnabled"]);
                }
            }
            catch { }
            return false;
        }

        string DefaultEnvName()
        {
            if (!string.IsNullOrEmpty(_activeDefault) && _environments.Any(en => NameOf(en) == _activeDefault)) return _activeDefault;
            var def = _environments.FirstOrDefault(en => en.ContainsKey("IsDefault") && Convert.ToBoolean(en["IsDefault"]));
            if (def != null) return NameOf(def);
            return _environments.Count > 0 ? NameOf(_environments[0]) : "";
        }

        static string NameOf(Dictionary<string, object> env) { return FieldOf(env, "Name"); }
        static string LabelOf(Dictionary<string, object> env)
        {
            string l = FieldOf(env, "Label");
            return string.IsNullOrEmpty(l) ? FieldOf(env, "Name") : l;
        }
        static string FieldOf(Dictionary<string, object> env, string key)
        {
            if (env != null && env.ContainsKey(key) && env[key] != null) return env[key].ToString();
            return "";
        }

        static void WriteConfigMirror(Dictionary<string, string> files, string root)
        {
            try
            {
                Directory.CreateDirectory(Path.Combine(root, "Config"));
                foreach (var kv in files)
                    if (kv.Key.StartsWith("Config/", StringComparison.OrdinalIgnoreCase) && kv.Key.EndsWith(".json", StringComparison.OrdinalIgnoreCase))
                    {
                        string dest = Path.Combine(root, kv.Key.Replace('/', Path.DirectorySeparatorChar));
                        Directory.CreateDirectory(Path.GetDirectoryName(dest));
                        File.WriteAllText(dest, kv.Value, new UTF8Encoding(false));
                    }
            }
            catch { }
        }

        // Overlay any loose Config\*.json in the source folder (SourceDir) onto a file set.
        // Lets the developer build read live-edited defaults, and Build Lite /
        // Extract embed them. A distributed sealed EXE has no loose Config.
        static void OverlayLooseConfig(Dictionary<string, string> files)
        {
            try
            {
                string dir = Path.Combine(SourceDir(), "Config");
                if (!Directory.Exists(dir)) return;
                foreach (var f in Directory.GetFiles(dir, "*.json"))
                    files["Config/" + Path.GetFileName(f)] = File.ReadAllText(f, Encoding.UTF8);
            }
            catch { }
        }

        static string IndentJson(string json)
        {
            var sb = new StringBuilder(); int indent = 0; bool inStr = false;
            for (int i = 0; i < json.Length; i++)
            {
                char c = json[i];
                if (inStr) { sb.Append(c); if (c == '\\' && i + 1 < json.Length) sb.Append(json[++i]); else if (c == '"') inStr = false; continue; }
                switch (c)
                {
                    case '"': inStr = true; sb.Append(c); break;
                    case '{': case '[': sb.Append(c); indent++; sb.Append('\n').Append(new string(' ', indent * 4)); break;
                    case '}': case ']': indent--; sb.Append('\n').Append(new string(' ', indent * 4)); sb.Append(c); break;
                    case ',': sb.Append(c); sb.Append('\n').Append(new string(' ', indent * 4)); break;
                    case ':': sb.Append(": "); break;
                    default: if (!char.IsWhiteSpace(c)) sb.Append(c); break;
                }
            }
            return sb.ToString();
        }

#if !SEALED
        // =================================================================
        //  Developer tooling (compiled out of sealed builds)
        // =================================================================
        static Dictionary<string, string> LoadPackage()
        {
            byte[] zip = ReadEmbeddedBytes(PackageResource);
            if (zip == null) throw new Exception(PackageResource + " resource missing.");
            var files = Bundles.ZipBytesToDict(zip);
            OverlayLooseConfig(files);   // live-edited defaults win
            return files;
        }

        static string ReadEmbeddedSource()
        {
            byte[] core = ReadEmbeddedBytes(SourceResource);
            if (core == null) return null;
            using (var ms = new MemoryStream(core))
            using (var gz = new GZipStream(ms, CompressionMode.Decompress))
            using (var outMs = new MemoryStream()) { gz.CopyTo(outMs); return new UTF8Encoding(false).GetString(outMs.ToArray()); }
        }

        void ExtractEmbedded()
        {
            try
            {
                string outDir = Path.Combine(GetLocalAppDataRoot(), "Extract"); Directory.CreateDirectory(outDir);
                string zipPath = Path.Combine(outDir, ExeName + "_v" + _version + ".zip");
                WriteExtractZip(zipPath);
                _ctx.Log("INFO", "Extract", "Wrote " + zipPath + " (with FunctionMap + Environment)");
                MessageBox.Show(this, "Extracted to:\n" + zipPath + "\n\nIncludes FunctionMap.txt and Environment.txt for review.",
                    "Extract", MessageBoxButtons.OK, MessageBoxIcon.Information);
            }
            catch (Exception ex) { Err("Extract", ex); }
        }

        // The full source of this build as a zip: the package (with loose config),
        // AppHost.cs, Build-App.cs, FunctionMap.txt and Environment.txt. No UI.
        void WriteExtractZip(string zipPath) { WriteExtractZip(zipPath, true); }

        void WriteExtractZip(string zipPath, bool fullEnvironment)
        {
            var files = LoadPackage();
            string tmp = zipPath + ".tmp";
            if (File.Exists(tmp)) File.Delete(tmp);
            using (var fs = File.Create(tmp))
            using (var za = new ZipArchive(fs, ZipArchiveMode.Create))
            {
                foreach (var kv in files) AddZipText(za, kv.Key, kv.Value);
                string src = ReadEmbeddedSource(); if (src != null && !files.ContainsKey(SourceFile)) AddZipText(za, SourceFile, src);
                string builder = ReadEmbeddedText(BuilderResource); if (builder != null && !files.ContainsKey(BuilderResource)) AddZipText(za, BuilderResource, builder);
                AddZipText(za, "Config/FunctionMap.txt", BuildFunctionMapText(files));
                AddZipText(za, "Config/Environment.txt", BuildEnvironmentText(fullEnvironment));
            }
            if (File.Exists(zipPath)) File.Delete(zipPath);
            File.Move(tmp, zipPath);
        }

        // ---------------- Archive this version (More menu; manual since 1.2) ----------------
        //   Archive\Exe\<ExeName>_v<ver>_t<template>.exe   copy of this developer EXE
        //   Archive\Zip\<ExeName>_v<ver>_t<template>.zip   full source (as Extract)
        // Git keeps every version now; this is for a copy outside git when wanted.
        string ArchiveBaseName()
        {
            return ExeName + "_v" + _version + (string.IsNullOrEmpty(_templateVersion) ? "" : "_t" + _templateVersion);
        }

        void ArchiveNow()
        {
            try
            {
                Cursor = Cursors.WaitCursor;
                string arch = Path.Combine(ExeDir(), "Archive"), name = ArchiveBaseName();
                string exeCopy = Path.Combine(arch, "Exe", name + ".exe"), zipCopy = Path.Combine(arch, "Zip", name + ".zip");
                Directory.CreateDirectory(Path.GetDirectoryName(exeCopy)); Directory.CreateDirectory(Path.GetDirectoryName(zipCopy));
                File.Copy(Application.ExecutablePath, exeCopy, true);
                WriteExtractZip(zipCopy, false);
                _ctx.Log("INFO", "Archive", "v" + _version + " -> " + exeCopy + " and " + zipCopy);
                ShowStatusMessage("Archived v" + _version + " in " + arch, "ok");
            }
            catch (Exception ex) { Err("Archive", ex); }
            finally { Cursor = Cursors.Default; }
        }

        // ---- More \u25BE : the zip-based tools from before git, for manual use ----
        void ShowMoreMenu(Control anchor)
        {
            var menu = new ContextMenuStrip { Font = Font };
            menu.Items.Add("Update from a zip or folder...", null, delegate { StartUpdate(); });
            menu.Items.Add("Update Template from a template zip...", null, delegate { StartTemplateUpdate(); });
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add("Extract source zip (AppData\\Extract)", null, delegate { ExtractEmbedded(); });
            menu.Items.Add("Archive this version (Archive\\Exe, Archive\\Zip)", null, delegate { ArchiveNow(); });
            menu.Closed += delegate { BeginInvoke((MethodInvoker)delegate { menu.Dispose(); }); };
            if (anchor != null) menu.Show(anchor, new Point(0, anchor.Height));
            else menu.Show(Cursor.Position);
        }

        // ---- Open \u25BE : the folders a developer needs ----
        void ShowOpenMenu(Control anchor)
        {
            var menu = new ContextMenuStrip { Font = Font };
            AddOpenItem(menu, "App folder  (Lite EXE, Build-App.cmd)", ExeDir());
            if (!SourceDir().Equals(ExeDir(), StringComparison.OrdinalIgnoreCase)) AddOpenItem(menu, "Source folder  (Config, Modules, VERSION, CHANGELOG)", SourceDir());
            AddOpenItem(menu, "Logs  (" + (_dataRootStatus == "Network" ? "shared" : "local") + ")", Path.Combine(_dataRoot ?? GetLocalAppDataRoot(), "Logs"));
            AddOpenItem(menu, "AppData  (Settings, Extract)", GetLocalAppDataRoot());
            menu.Closed += delegate { BeginInvoke((MethodInvoker)delegate { menu.Dispose(); }); };
            if (anchor != null) menu.Show(anchor, new Point(0, anchor.Height));
            else menu.Show(Cursor.Position);
        }

        void AddOpenItem(ContextMenuStrip menu, string text, string folder)
        {
            menu.Items.Add(text, null, delegate
            {
                try
                {
                    Directory.CreateDirectory(folder);
                    Process.Start("explorer.exe", "\"" + folder + "\"");
                }
                catch (Exception ex) { Err("Open", ex); }
            });
        }

        static string ExeDir() { return Path.GetDirectoryName(Application.ExecutablePath); }

        static string LitePath() { return Path.Combine(ExeDir(), ExeName + "Lite.exe"); }

        // ---- Update folder: <EXE folder>\Update, the default place for update zips ----
        // Made when Update / Update Template is used; their pickers open there.
        internal static string UpdateFolderPath() { return Path.Combine(ExeDir(), UpdateFolderName); }

        static void EnsureUpdateFolder(AppContext ctx)
        {
            string p = UpdateFolderPath();
            try
            {
                if (Directory.Exists(p)) return;
                Directory.CreateDirectory(p);
                if (ctx != null) ctx.Log("INFO", "Update", "Created " + p + " (default place for update zips).");
            }
            catch (Exception ex) { if (ctx != null) ctx.Log("WARN", "Update", "Could not create " + p + ": " + ex.Message); }
        }

        // The picker's starting folder: the Update folder when it exists.
        static string UpdatePickerFolder()
        {
            try { string p = UpdateFolderPath(); if (Directory.Exists(p)) return p; } catch { }
            return ExeDir();
        }

        // ---- Build-App.cs: source of Build-App.exe (Build-App.cmd compiles it) ----
        // Embedded as its own resource so Update / Extract carry the whole source; a
        // build made by an older Update engine has it in the package instead.
        static string ReadBuilderSource()
        {
            string s = ReadEmbeddedText(BuilderResource);
            if (s != null) return s;
            try
            {
                byte[] zip = ReadEmbeddedBytes(PackageResource);
                if (zip == null) return null;
                string v; return Bundles.ZipBytesToDict(zip).TryGetValue(BuilderResource, out v) ? v : null;
            }
            catch { return null; }
        }

        // ---- Build Lite: <ExeName>Lite.exe beside this EXE - the SEALED build to hand
        //      out (source left out, modules sealed per tier). Asks for the user and
        //      admin passwords every time (template 1.1.2: no built-in test passwords).
        void BuildLiteNow()
        {
            string userPw, adminPw;
            if (!PromptTwoPasswords(out userPw, out adminPw)) return;
            string lite = LitePath();
            Cursor = Cursors.WaitCursor;
            ShowStatusMessage("Building " + ExeName + "Lite.exe ...", "info");
            string err;
            var sw = Stopwatch.StartNew();
            try { err = BuildSealedTo(userPw, adminPw, lite, _version); }
            catch (Exception ex) { err = ex.ToString(); }
            finally { Cursor = Cursors.Default; }
            if (err != null)
            {
                _ctx.Log("WARN", "BuildLite", ExeName + "Lite.exe not built: " + err);
                ShowStatusMessage(ExeName + "Lite.exe not built (see Session.log).", "err");
                MessageBox.Show(this, ExeName + "Lite.exe was not built:\n\n" + err, "Build Lite", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return;
            }
            _ctx.Log("INFO", "BuildLite", ExeName + "Lite.exe -> " + lite + " (" + sw.ElapsedMilliseconds + " ms)");
            ShowStatusMessage(ExeName + "Lite.exe built - the sealed build to hand out.", "ok");
            MessageBox.Show(this, "Built " + lite + "\n\nSource left out; modules sealed per tier.\nGive users the USER password; keep the ADMIN password private.",
                "Build Lite", MessageBoxButtons.OK, MessageBoxIcon.Information);
        }

        // ---- headless:  <ExeName>Dev.exe --build-lite ["out.exe"] ----
        // Used by Build-App.exe right after it compiles the developer EXE. The user /
        // admin passwords come in the environment variables APPTEMPLATE_LITE_USER /
        // APPTEMPLATE_LITE_ADMIN, which Build-App.exe sets for this process only.
        // No window, no launcher; exit code 0 = built, errors on stderr.
        internal static int HeadlessBuildLite(string outExe)
        {
            try
            {
                string userPw = Environment.GetEnvironmentVariable("APPTEMPLATE_LITE_USER");
                string adminPw = Environment.GetEnvironmentVariable("APPTEMPLATE_LITE_ADMIN");
                if (string.IsNullOrEmpty(userPw) || string.IsNullOrEmpty(adminPw)) { WriteStdErr("No Lite passwords given (APPTEMPLATE_LITE_USER / APPTEMPLATE_LITE_ADMIN)."); return 3; }
                if (userPw == adminPw) { WriteStdErr("The user and admin passwords must differ."); return 3; }
                if (string.IsNullOrEmpty(outExe)) outExe = LitePath();
                string version = VersionOf(LoadPackage());
                string err = BuildSealedTo(userPw, adminPw, outExe, version);
                if (err != null) { WriteStdErr(err); return 1; }
                return 0;
            }
            catch (Exception ex) { WriteStdErr(ex.ToString()); return 2; }
        }

        static void WriteStdErr(string text) { try { Console.Error.WriteLine(text); Console.Error.Flush(); } catch { } }

        // The version a file set (or this EXE) carries.
        static string VersionOf(Dictionary<string, string> files)
        {
            try
            {
                var fvi = FileVersionInfo.GetVersionInfo(Application.ExecutablePath);
                if (!string.IsNullOrEmpty(fvi.ProductVersion)) return fvi.ProductVersion.Trim();
            }
            catch { }
            string v;
            return files != null && files.TryGetValue("VERSION.txt", out v) ? v.Trim().TrimStart('v', 'V') : "0.0.0";
        }

        static void AddZipText(ZipArchive za, string entryName, string text)
        {
            var entry = za.CreateEntry(entryName.Replace('\\', '/'));
            using (var w = new StreamWriter(entry.Open(), new UTF8Encoding(false))) w.Write(text);
        }

        string BuildFunctionMapText(Dictionary<string, string> files)
        {
            var map = new List<string>();
            foreach (var kv in files)
            {
                if (kv.Key.IndexOf("Modules/", StringComparison.OrdinalIgnoreCase) < 0) continue;
                string module = Path.GetFileNameWithoutExtension(kv.Key);
                foreach (var line in kv.Value.Split('\n'))
                {
                    var m = System.Text.RegularExpressions.Regex.Match(line, @"^\s*function\s+([A-Za-z][\w\-]*)",
                                System.Text.RegularExpressions.RegexOptions.IgnoreCase);
                    if (m.Success) map.Add(m.Groups[1].Value.PadRight(52) + " --> " + module);
                }
            }
            map.Sort();
            var sb = new StringBuilder();
            sb.AppendLine("# FunctionMap.txt"); sb.AppendLine("# Version   : v" + _version); sb.AppendLine("# Template  : v" + _templateVersion);
            sb.AppendLine("# Generated : " + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss"));
            sb.AppendLine("# Format    : FunctionName --> Module"); sb.AppendLine();
            foreach (var l in map) sb.AppendLine(l);
            return sb.ToString();
        }

        // includeModules = false skips "Get-Module -ListAvailable" (slow on servers
        // with many modules) - used by the background archive.
        string BuildEnvironmentText(bool includeModules)
        {
            var sb = new StringBuilder();
            sb.AppendLine("# Environment capture");
            sb.AppendLine("Generated         : " + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss"));
            sb.AppendLine("Machine           : " + Environment.MachineName);
            sb.AppendLine("User              : " + Environment.UserName);
            sb.AppendLine("Windows           : " + SystemFacts.Windows());
            sb.AppendLine("PowerShell        : " + SystemFacts.PowerShell());
            sb.AppendLine(".NET Framework    : " + SystemFacts.DotNet());
            sb.AppendLine("Process / OS      : " + SystemFacts.Bitness());
            sb.AppendLine("App version       : v" + _version);
            sb.AppendLine("Template version  : " + (_templateVersion == "" ? "unknown" : "v" + _templateVersion) +
                          "");
            sb.AppendLine("Resolved data root: " + _dataRoot + "  (" + _dataRootStatus + ")");
            sb.AppendLine();
            try { using (PowerShell ps = PowerShell.Create()) { ps.AddScript("$PSVersionTable | Out-String"); foreach (var r in ps.Invoke()) sb.AppendLine(r.ToString()); } }
            catch (Exception ex) { sb.AppendLine("PSVersionTable: " + ex.Message); }
            if (includeModules) try
            {
                sb.AppendLine("Installed modules (name / version):");
                using (PowerShell ps = PowerShell.Create())
                {
                    ps.AddScript("Get-Module -ListAvailable | Select-Object Name,Version | Sort-Object Name | Format-Table -AutoSize | Out-String");
                    foreach (var r in ps.Invoke()) sb.AppendLine(r.ToString());
                }
            }
            catch (Exception ex) { sb.AppendLine("Get-Module: " + ex.Message); }
            return sb.ToString();
        }

        // A parsed CHANGELOG entry.
        class VerEntry { public string Version; public string Date; public string Title; public List<string> Changes = new List<string>(); }

        static List<VerEntry> ParseChangelog(string text)
        {
            var entries = new List<VerEntry>();
            VerEntry cur = null;
            foreach (var raw in (text ?? "").Replace("\r\n", "\n").Split('\n'))
            {
                var m = System.Text.RegularExpressions.Regex.Match(raw, @"^v(\S+)\s+\(([^)]*)\)\s*(.*)$");
                if (m.Success)
                {
                    cur = new VerEntry { Version = m.Groups[1].Value, Date = m.Groups[2].Value, Title = m.Groups[3].Value.Trim() };
                    entries.Add(cur);
                }
                else if (cur != null)
                {
                    string t = raw.Trim();
                    if (t.Length > 0 && !t.StartsWith("#")) cur.Changes.Add(t);
                }
            }
            return entries;
        }

        void ShowVersionHistory()
        {
            string text = "(CHANGELOG.txt not found)";
            try { var files = LoadPackage(); if (files.ContainsKey("CHANGELOG.txt")) text = files["CHANGELOG.txt"]; } catch { }
            var entries = ParseChangelog(text);

            using (var dlg = new Form { Text = "Version History  -  v" + _version + (_templateVersion == "" ? "" : "   (template v" + _templateVersion + ")"), Size = new Size(760, 580), StartPosition = FormStartPosition.CenterParent, Font = Font, BackColor = _theme.Surface })
            {
                var split = new SplitContainer { Dock = DockStyle.Fill, Orientation = Orientation.Horizontal, Panel1MinSize = 150, Panel2MinSize = 120 };

                var list = new ListView { Dock = DockStyle.Fill, View = View.Details, FullRowSelect = true, GridLines = true, MultiSelect = false, HideSelection = false };
                list.Columns.Add("Version", 90);
                list.Columns.Add("Date", 110);
                list.Columns.Add("Summary", 500);
                foreach (var e in entries)
                {
                    var it = new ListViewItem(new[] { "v" + e.Version, e.Date, e.Title });
                    it.Tag = e;
                    list.Items.Add(it);
                }

                var detail = new TextBox { Dock = DockStyle.Fill, Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Vertical,
                    BorderStyle = BorderStyle.None, BackColor = _theme.Surface, Font = new Font(_theme.FontName, _theme.FontSizePt) };

                list.SelectedIndexChanged += delegate
                {
                    if (list.SelectedItems.Count == 0) { detail.Text = ""; return; }
                    var e = (VerEntry)list.SelectedItems[0].Tag;
                    var sb = new StringBuilder();
                    sb.AppendLine("v" + e.Version + "   (" + e.Date + ")   " + e.Title);
                    sb.AppendLine();
                    foreach (var c in e.Changes)
                    {
                        // "Fixed   : text" -> "\u2022 Fixed - text"
                        var cm = System.Text.RegularExpressions.Regex.Match(c, @"^([A-Za-z]+)\s*:\s*(.*)$");
                        if (cm.Success) sb.AppendLine("  \u2022 " + cm.Groups[1].Value + " - " + cm.Groups[2].Value);
                        else            sb.AppendLine("    " + c);
                    }
                    detail.Text = sb.ToString();
                };

                split.Panel1.Controls.Add(list);
                split.Panel2.Controls.Add(detail);
                dlg.Controls.Add(split);
                dlg.Shown += delegate { try { split.SplitterDistance = 230; } catch { } };
                if (list.Items.Count > 0) list.Items[0].Selected = true;
                dlg.ShowDialog(this);
            }
        }

        // ---- Update: recompile the DEVELOPER build from a zip OR a folder ----
        void StartUpdate()
        {
            bool isFolder;
            EnsureUpdateFolder(_ctx);
            string source = ChooseUpdateSource(out isFolder);
            if (source == null) return;
            try
            {
                var incoming = FromProjectLayout(StripCommonRootFolder(ReadSourceToDict(source)));
                var current  = LoadPackage();
                if (!incoming.ContainsKey(SourceFile))
                {
                    string src = ReadEmbeddedSource();
                    if (src == null) { MessageBox.Show(this, "No " + SourceFile + " in the update and none embedded.", "Update"); return; }
                    incoming[SourceFile] = src;
                }
                // UPDATE.txt directives:  "Mode: Partial" / "Mode: Full" (default: full
                // when the package carries _AppLauncher.ps1), and "Delete: <path>"
                // lines that remove files in a partial update.
                string mode = null; var deletes = new List<string>();
                string updTxt;
                if (incoming.TryGetValue("UPDATE.txt", out updTxt))
                    foreach (var raw in updTxt.Split('\n'))
                    {
                        string ln = raw.Trim();
                        if (ln.StartsWith("Mode:", StringComparison.OrdinalIgnoreCase)) mode = ln.Substring(5).Trim();
                        else if (ln.StartsWith("Delete:", StringComparison.OrdinalIgnoreCase))
                        { string dp = ln.Substring(7).Trim().Replace('\\', '/'); if (dp.Length > 0) deletes.Add(dp); }
                    }
                bool full = mode != null ? mode.Equals("Full", StringComparison.OrdinalIgnoreCase)
                                         : incoming.ContainsKey("_AppLauncher.ps1");
                var result = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
                if (full) foreach (var kv in incoming) result[kv.Key] = kv.Value;
                else
                {
                    foreach (var kv in current) result[kv.Key] = kv.Value;
                    foreach (var kv in incoming) result[kv.Key] = kv.Value;
                    foreach (var dp in deletes) result.Remove(dp);
                }
                result.Remove("UPDATE.txt");
                if (!result.ContainsKey(SourceFile)) result[SourceFile] = incoming[SourceFile];
                if (!CheckIdentity(result)) return;

                if (!PreviewAndConfirm(current, result)) return;
                string newVersion = result.ContainsKey("VERSION.txt") ? result["VERSION.txt"].Trim().TrimStart('v', 'V') : _version;
                SyncLooseConfig(incoming);
                RecompileDeveloper(result, newVersion);
            }
            catch (Exception ex) { Err("Update", ex); }
        }

        // The AppIdentity.json text a build of these files embeds: the file in the
        // set when it is valid, else this build's own identity.
        static string IdentityJsonOf(Dictionary<string, string> files)
        {
            string t, a, x, d, why;
            if (files != null && files.TryGetValue(ProjectIdentity.FileName, out t) && ProjectIdentity.TryParse(t, out a, out x, out d, out why))
                return ProjectIdentity.ToJson(a, x, d);
            return ProjectIdentity.CurrentJson();
        }

        // A file set plus this build's embedded AppHost.cs and Build-App.cs (not in
        // the package): every engine file of the running project.
        static Dictionary<string, string> EngineView(Dictionary<string, string> files)
        {
            var d = new Dictionary<string, string>(files, StringComparer.OrdinalIgnoreCase);
            string src = ReadEmbeddedSource(); if (src != null) d[SourceFile] = src;
            string builder = ReadEmbeddedText(BuilderResource); if (builder != null) d[BuilderResource] = builder;
            return d;
        }

        // ---- Update Template: move this project's engine to a newer AppTemplate ----
        // Input: the TEMPLATE's full source zip (its Archive\Zip zip, or an Extract).
        // Only the files its TEMPLATE_FILES.txt lists are taken; project files are
        // never touched. Refused (nothing changes) when:
        //   - the zip is not template source, or does not match its own manifest
        //   - it is not newer than this project's TEMPLATE_VERSION.txt
        //   - the jump changes the contract: a different major.minor version, or a
        //     "Contract:" note in a template CHANGELOG entry newer than this project
        //   - this project's engine files differ from its own TEMPLATE_FILES.txt
        //     (local engine edits, which the sync would overwrite)
        // Otherwise: preview, then the engine files + TEMPLATE_* files are replaced,
        // engine files the template dropped are deleted, VERSION.txt gets the next
        // patch number and CHANGELOG.txt an "Engine synced vA -> vB" entry, and the
        // developer EXE recompiles itself as with Update.
        class TemplateSyncPlan
        {
            public Dictionary<string, string> Current, Result, EngineFiles;
            public string NewVersion, Note, LogText;
        }

        void StartTemplateUpdate()
        {
            string zip;
            EnsureUpdateFolder(_ctx);
            using (var ofd = new OpenFileDialog { Title = "Update Template - choose the AppTemplate source zip (its Archive\\Zip zip or an Extract)",
                                                  Filter = "Zip packages (*.zip)|*.zip", InitialDirectory = UpdatePickerFolder() })
            {
                if (ofd.ShowDialog(this) != DialogResult.OK) return;
                zip = ofd.FileName;
            }
            try
            {
                var tpl = FromProjectLayout(StripCommonRootFolder(ReadSourceToDict(zip)));
                string why;
                var plan = PlanTemplateSync(tpl, out why);
                if (plan == null)
                {
                    _ctx.Log("WARN", "TemplateSync", Path.GetFileName(zip) + ": " + why.Replace("\n", " "));
                    MessageBox.Show(this, why, "Update Template", MessageBoxButtons.OK, MessageBoxIcon.Information);
                    return;
                }
                if (!PreviewAndConfirm(plan.Current, plan.Result, plan.Note)) return;
                _ctx.Log("INFO", "TemplateSync", plan.LogText + " (from " + zip + ")");
                SyncLooseConfig(plan.EngineFiles);
                RecompileDeveloper(plan.Result, plan.NewVersion);
            }
            catch (Exception ex) { Err("Update Template", ex); }
        }

        static Version ParseVer(string s)
        {
            Version v;
            if (!Version.TryParse((s ?? "").Trim().TrimStart('v', 'V'), out v)) return null;
            return new Version(v.Major, v.Minor, Math.Max(v.Build, 0));
        }

        static string Fmt(Version v) { return v.ToString(3); }

        // Files a template manifest must never list: they belong to the project.
        static bool IsProjectOwned(string path)
        {
            string p = path.Replace('\\', '/');
            foreach (var f in new[] { "VERSION.txt", "CHANGELOG.txt", "README.md", ProjectIdentity.FileName,
                                      "Modules/Base/UI_Register-Tabs.psm1", "Modules/Base/UI_Tab_Overview.psm1",
                                      "Config/Environments.json", "Config/EnvironmentFields.json", "Config/SharedScope.json" })
                if (p.Equals(f, StringComparison.OrdinalIgnoreCase)) return true;
            return p.StartsWith("Modules/Lite/", StringComparison.OrdinalIgnoreCase) || p.StartsWith("Modules/Admin/", StringComparison.OrdinalIgnoreCase);
        }

        // CHANGELOG entries with from < version <= to.
        static List<VerEntry> EntriesBetween(string changelog, Version from, Version to)
        {
            return ParseChangelog(changelog).Where(e => { var v = ParseVer(e.Version); return v != null && v > from && v <= to; }).ToList();
        }

        TemplateSyncPlan PlanTemplateSync(Dictionary<string, string> tpl, out string why)
        {
            why = null;
            string tplManifest, tplVerText;
            if (!tpl.TryGetValue("TEMPLATE_FILES.txt", out tplManifest) || !tpl.TryGetValue("TEMPLATE_VERSION.txt", out tplVerText))
            {
                why = "This zip has no TEMPLATE_FILES.txt / TEMPLATE_VERSION.txt, so it is not AppTemplate source.\n\n" +
                      "Choose the template's Archive\\Zip zip (or an Extract of the template).";
                return null;
            }
            Version newTv = ParseVer(tplVerText), curTv = ParseVer(_templateVersion);
            if (newTv == null) { why = "TEMPLATE_VERSION.txt in the zip is not a version ('" + tplVerText.Trim() + "')."; return null; }
            if (curTv == null)
            {
                why = "This project has no TEMPLATE_VERSION.txt, so where its engine starts is unknown.\n\n" +
                      "Bring it to the template once with a manual template sync; Update Template works after that.";
                return null;
            }
            if (newTv <= curTv)
            {
                why = "This project is already on template v" + Fmt(curTv) + " (the zip holds v" + Fmt(newTv) + ").\n\nNothing to do.";
                return null;
            }

            var newList = ParseManifest(tplManifest);
            var owned = newList.Where(kv => IsProjectOwned(kv.Key)).Select(kv => kv.Key).ToList();
            if (newList.Count == 0 || owned.Count > 0)
            {
                why = newList.Count == 0 ? "TEMPLATE_FILES.txt in the zip lists no files."
                    : "TEMPLATE_FILES.txt in the zip lists project-owned files, which a sync must never replace:\n\n  " + string.Join("\n  ", owned.ToArray());
                return null;
            }

            // 1. the template zip must match its own manifest
            int n;
            var bad = ManifestDifferences(tplManifest, tpl, true, out n);
            if (bad.Count > 0)
            {
                why = "The template zip does not match its own TEMPLATE_FILES.txt:\n\n  " + string.Join("\n  ", bad.Take(12).ToArray()) +
                      "\n\nFix the template first (regenerate TEMPLATE_FILES.txt), then use its new Archive\\Zip zip.";
                return null;
            }

            // 2. contract changes are adapted by hand
            string tplLog = tpl.ContainsKey("CHANGELOG.txt") ? tpl["CHANGELOG.txt"] : "";
            var newer = EntriesBetween(tplLog, curTv, newTv);
            var contracts = new List<string>();
            foreach (var e in newer)
                foreach (var c in e.Changes)
                    if (System.Text.RegularExpressions.Regex.IsMatch(c, @"^Contract\s*:", System.Text.RegularExpressions.RegexOptions.IgnoreCase))
                        contracts.Add("v" + e.Version + "  " + c);
            if (newTv.Major != curTv.Major || newTv.Minor != curTv.Minor || contracts.Count > 0)
            {
                why = "Template v" + Fmt(curTv) + " -> v" + Fmt(newTv) + " changes the project contract, so project files must be adapted by hand:\n\n  " +
                      (contracts.Count > 0 ? string.Join("\n  ", contracts.Take(10).ToArray()) : "(a new major or minor template version)") +
                      "\n\nDo a manual template sync for this project instead. Nothing was changed.";
                return null;
            }

            // 3. this project's engine files must match its own manifest
            var cur = EngineView(LoadPackage());
            string curManifest;
            if (!cur.TryGetValue("TEMPLATE_FILES.txt", out curManifest)) { why = "This project has no TEMPLATE_FILES.txt."; return null; }
            var drift = ManifestDifferences(curManifest, cur, false, out n);
            if (drift.Count > 0)
            {
                why = "Engine files in this project were changed locally (they differ from its TEMPLATE_FILES.txt):\n\n  " +
                      string.Join("\n  ", drift.ToArray()) +
                      "\n\nMove those changes into the template (or revert them) first; Update Template would overwrite them.";
                return null;
            }

            // 4. the new file set: engine files from the template, everything else kept
            var result = new Dictionary<string, string>(cur, StringComparer.OrdinalIgnoreCase);
            var engine = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            var newPaths = new HashSet<string>(newList.Select(kv => kv.Key), StringComparer.OrdinalIgnoreCase);
            int replaced = 0, added = 0;
            foreach (var p in newPaths)
            {
                if (!cur.ContainsKey(p)) added++;
                else if (NormalizedHash(p, cur[p]) != NormalizedHash(p, tpl[p])) replaced++;
                result[p] = tpl[p]; engine[p] = tpl[p];
            }
            var dropped = ParseManifest(curManifest).Select(kv => kv.Key).Where(p => !newPaths.Contains(p) && !IsProjectOwned(p)).ToList();
            foreach (var p in dropped) result.Remove(p);
            result["TEMPLATE_FILES.txt"]   = tplManifest;
            result["TEMPLATE_VERSION.txt"] = tplVerText;
            if (!result.ContainsKey(ProjectIdentity.FileName)) result[ProjectIdentity.FileName] = ProjectIdentity.CurrentJson();

            // 5. project version + changelog entry
            var av = ParseVer(_version) ?? new Version(1, 0, 0);
            string newVer = av.Major + "." + av.Minor + "." + (av.Build + 1);
            result["VERSION.txt"] = newVer + "\n";
            var entry = new StringBuilder();
            entry.Append("v" + newVer + " (" + DateTime.Now.ToString("yyyy-MM-dd") + ")  Engine synced v" + Fmt(curTv) + " -> v" + Fmt(newTv) + "\n");
            entry.Append("  Changed : AppTemplate engine v" + Fmt(curTv) + " -> v" + Fmt(newTv) + " (Update Template): " +
                         replaced + " file(s) replaced, " + added + " added, " + dropped.Count + " removed.\n");
            foreach (var e in newer) entry.Append("  Note    : template v" + e.Version + "  " + e.Title + "\n");
            entry.Append("\n");
            string log;
            result["CHANGELOG.txt"] = InsertChangelogEntry(cur.TryGetValue("CHANGELOG.txt", out log) ? log : "", entry.ToString());

            return new TemplateSyncPlan
            {
                Current = cur, Result = result, EngineFiles = engine, NewVersion = newVer,
                Note = "Template v" + Fmt(curTv) + "  ->  v" + Fmt(newTv) + "          " + AppName + " v" + _version + "  ->  v" + newVer + "\n" +
                       "Engine files only: " + replaced + " replaced, " + added + " added, " + dropped.Count + " removed. Project files are not touched.\n" +
                       "VERSION.txt and CHANGELOG.txt get the sync entry. Apply recompiles and restarts the app.",
                LogText = "Template v" + Fmt(curTv) + " -> v" + Fmt(newTv) + ", app v" + _version + " -> v" + newVer + ": " +
                          replaced + " replaced, " + added + " added, " + dropped.Count + " removed"
            };
        }

        // Put a new entry above the newest one (below the header comments).
        static string InsertChangelogEntry(string changelog, string entry)
        {
            string nl = changelog.Contains("\r\n") ? "\r\n" : "\n";
            var lines = changelog.Replace("\r\n", "\n").Split('\n').ToList();
            int at = lines.FindIndex(l => System.Text.RegularExpressions.Regex.IsMatch(l, @"^v\S+\s+\("));
            if (at < 0) { at = lines.Count; while (at > 0 && lines[at - 1].Trim() == "") at--; if (at > 0) { lines.Insert(at, ""); at++; } }
            lines.InsertRange(at, entry.TrimEnd('\n').Split('\n').Concat(new[] { "" }));
            return string.Join(nl, lines.ToArray());
        }

        // Small chooser: zip file or folder (an unzipped update or Extract). Null = cancel.
        string ChooseUpdateSource(out bool isFolder)
        {
            string chosen = null; bool folder = false;
            using (var dlg = new Form { Text = "Update", ClientSize = new Size(448, 182), FormBorderStyle = FormBorderStyle.FixedSingle,
                       MaximizeBox = false, MinimizeBox = false, StartPosition = FormStartPosition.CenterParent, Font = Font, BackColor = _theme.Panel })
            {
                var hdr = new Label { Text = "Apply an update to v" + _version, Location = new Point(16, 14), Size = new Size(416, 20),
                    ForeColor = _theme.Title, Font = new Font(_theme.FontName, _theme.FontSizePt, FontStyle.Bold) };
                var body = new Label { Location = new Point(16, 40), Size = new Size(416, 80), Text =
                    "\u2022  Zip file:  an update zip (changed files) or a full Extract zip (opens in Update\\).\n" +
                    "\u2022  Folder:  an unzipped update or full source folder.\n\n" +
                    "You will see a preview of every change before anything is applied." };
                var btnZip = _theme.MakeButton("Zip file..."); btnZip.AutoSize = false; btnZip.Size = new Size(100, 28); btnZip.Location = new Point(16, 138);
                var btnFolder = _theme.MakeButton("Folder..."); btnFolder.AutoSize = false; btnFolder.Size = new Size(100, 28); btnFolder.Location = new Point(124, 138);
                var btnCancel = _theme.MakeButton("Cancel"); btnCancel.AutoSize = false; btnCancel.Size = new Size(90, 28); btnCancel.Location = new Point(342, 138);
                btnZip.Click += delegate
                {
                    using (var ofd = new OpenFileDialog { Title = "Select update package", Filter = "Zip packages (*.zip)|*.zip", InitialDirectory = UpdatePickerFolder() })
                        if (ofd.ShowDialog(dlg) == DialogResult.OK) { chosen = ofd.FileName; folder = false; dlg.DialogResult = DialogResult.OK; }
                };
                btnFolder.Click += delegate
                {
                    using (var fbd = new FolderBrowserDialog { Description = "Select an unzipped update or source folder", SelectedPath = UpdatePickerFolder() })
                        if (fbd.ShowDialog(dlg) == DialogResult.OK) { chosen = fbd.SelectedPath; folder = true; dlg.DialogResult = DialogResult.OK; }
                };
                btnCancel.Click += delegate { dlg.DialogResult = DialogResult.Cancel; };
                dlg.CancelButton = btnCancel;
                dlg.Controls.AddRange(new Control[] { hdr, body, btnZip, btnFolder, btnCancel });
                dlg.ShowDialog(this);
            }
            isFolder = folder;
            return chosen;
        }

        // The result of an update must carry a valid AppIdentity.json. An update
        // without one keeps this build's identity (added to the result); one that
        // would CHANGE the identity (e.g. a template zip applied with Update
        // instead of Update Template) is confirmed first, because a new
        // AppDataFolder moves the saved environments and logs.
        bool CheckIdentity(Dictionary<string, string> result)
        {
            string text;
            if (!result.TryGetValue(ProjectIdentity.FileName, out text))
            {
                result[ProjectIdentity.FileName] = ProjectIdentity.CurrentJson();
                return true;
            }
            string a, x, d, why;
            if (!ProjectIdentity.TryParse(text, out a, out x, out d, out why))
            {
                MessageBox.Show(this, ProjectIdentity.FileName + " in this update is not usable: " + why + ".\n\nNothing was changed.",
                    "Update", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return false;
            }
            if (a == AppName && x == ExeName && d == AppDataFolder) return true;
            var r = MessageBox.Show(this,
                "This update CHANGES the project identity (" + ProjectIdentity.FileName + "):\n\n" +
                "  AppName        " + AppName + "  ->  " + a + "\n" +
                "  ExeName        " + ExeName + "  ->  " + x + "\n" +
                "  AppDataFolder  " + AppDataFolder + "  ->  " + d + "\n\n" +
                "A new AppDataFolder starts with no saved environments or logs.\n" +
                "To move a project to a newer template, use Update Template instead.\n\nContinue?",
                "Update", MessageBoxButtons.YesNo, MessageBoxIcon.Warning, MessageBoxDefaultButton.Button2);
            return r == DialogResult.Yes;
        }

        bool PreviewAndConfirm(Dictionary<string, string> current, Dictionary<string, string> result)
        {
            return PreviewAndConfirm(current, result, null);
        }

        // note: optional text shown above the list (Update Template's summary).
        bool PreviewAndConfirm(Dictionary<string, string> current, Dictionary<string, string> result, string note)
        {
            var added    = result.Keys.Where(k => !current.ContainsKey(k)).OrderBy(k => k).ToList();
            var removed  = current.Keys.Where(k => !result.ContainsKey(k)).OrderBy(k => k).ToList();
            var modified = result.Keys.Where(k => current.ContainsKey(k) && current[k] != result[k]).OrderBy(k => k).ToList();
            using (var dlg = new Form { Text = "Update preview", Size = new Size(660, 520), StartPosition = FormStartPosition.CenterParent, Font = Font, BackColor = _theme.Surface })
            {
                var list = new ListView { Dock = DockStyle.Fill, View = View.Details, FullRowSelect = true, GridLines = true };
                list.Columns.Add("Change", 90); list.Columns.Add("File", 530);
                foreach (var k in added)    list.Items.Add(new ListViewItem(new[] { "ADD", k })    { ForeColor = Color.ForestGreen });
                foreach (var k in modified) list.Items.Add(new ListViewItem(new[] { "MODIFY", k }));
                foreach (var k in removed)  list.Items.Add(new ListViewItem(new[] { "DELETE", k }) { ForeColor = Color.Firebrick });
                var panel = new Panel { Dock = DockStyle.Bottom, Height = 46, BackColor = _theme.Panel };
                var apply = _theme.MakeButton("Apply && Recompile"); apply.AutoSize = false; apply.Size = new Size(150, 28); apply.Location = new Point(350, 9); apply.DialogResult = DialogResult.OK;
                var cancel = _theme.MakeButton("Cancel"); cancel.AutoSize = false; cancel.Size = new Size(90, 28); cancel.Location = new Point(510, 9); cancel.DialogResult = DialogResult.Cancel;
                panel.Controls.Add(apply); panel.Controls.Add(cancel);
                dlg.AcceptButton = apply; dlg.CancelButton = cancel;
                dlg.Controls.Add(list); dlg.Controls.Add(panel);
                if (!string.IsNullOrEmpty(note))            // added last = docked first (top band)
                    dlg.Controls.Add(new Label { Dock = DockStyle.Top, Height = 78, Padding = new Padding(10, 8, 10, 4), Text = note,
                                                 BackColor = _theme.Panel, ForeColor = _theme.Title });
                return dlg.ShowDialog(this) == DialogResult.OK;
            }
        }

        void RecompileDeveloper(Dictionary<string, string> result, string newVersion)
        {
            string csc = FindCsc(); if (csc == null) { MessageBox.Show(this, "csc.exe not found.", "Update"); return; }
            string sma = FindSma(); if (sma == null) { MessageBox.Show(this, "SMA dll not found.", "Update"); return; }
            EnsureUpdateFolder(_ctx);
            string temp = Path.Combine(Path.GetTempPath(), "AppBuild_" + Guid.NewGuid().ToString("N").Substring(0, 12));
            Directory.CreateDirectory(temp);
            try
            {
                string zipPath = Path.Combine(temp, "AppPackage.zip");
                using (var fs = File.Create(zipPath))
                using (var za = new ZipArchive(fs, ZipArchiveMode.Create))
                    foreach (var kv in result)
                    {
                        if (kv.Key.Equals(SourceFile, StringComparison.OrdinalIgnoreCase)) continue;
                        if (kv.Key.Equals("Build-App.ps1", StringComparison.OrdinalIgnoreCase)) continue;   // removed in 1.2
                        if (kv.Key.Equals(BuilderResource, StringComparison.OrdinalIgnoreCase)) continue;   // own resource
                        if (kv.Key.Equals("UPDATE.txt", StringComparison.OrdinalIgnoreCase)) continue;
                        if (kv.Key.StartsWith("Config/FunctionMap", StringComparison.OrdinalIgnoreCase)) continue;
                        if (kv.Key.StartsWith("Config/Environment.txt", StringComparison.OrdinalIgnoreCase)) continue;
                        AddZipText(za, kv.Key, kv.Value);
                    }
                string csPath   = Path.Combine(temp, SourceFile); File.WriteAllText(csPath, result[SourceFile], new UTF8Encoding(false));
                string corePath = Path.Combine(temp, "core.dat"); File.WriteAllBytes(corePath, PackSource(result[SourceFile]));
                string verPath  = Path.Combine(temp, "AssemblyVersionInfo.cs"); File.WriteAllText(verPath, BuildVersionInfoSource(newVersion), Encoding.ASCII);
                string idPath   = Path.Combine(temp, ProjectIdentity.FileName);
                File.WriteAllText(idPath, IdentityJsonOf(result), new UTF8Encoding(false));
                string builderCs = result.ContainsKey(BuilderResource) ? result[BuilderResource] : ReadBuilderSource();
                string builderPath = Path.Combine(temp, BuilderResource); if (builderCs != null) File.WriteAllText(builderPath, builderCs, new UTF8Encoding(false));

                string outExe = Path.Combine(temp, ExeName + ".exe");
                var rsp = new List<string> { "/target:winexe", "/optimize+", "/out:\"" + outExe + "\"" };
                foreach (var r in BaseRefs()) rsp.Add("/reference:" + r);
                rsp.Add("/reference:\"" + sma + "\"");
                foreach (var r in ParseReferences(result[SourceFile])) rsp.Add("/reference:\"" + r + "\"");
                rsp.Add("/resource:\"" + zipPath + "\",AppPackage.zip");
                rsp.Add("/resource:\"" + corePath + "\",core.dat");
                if (builderCs != null) rsp.Add("/resource:\"" + builderPath + "\"," + BuilderResource);
                rsp.Add("/resource:\"" + idPath + "\"," + ProjectIdentity.FileName);
                rsp.Add("\"" + csPath + "\""); rsp.Add("\"" + verPath + "\"");
                string rspPath = Path.Combine(temp, "build.rsp"); File.WriteAllLines(rspPath, rsp, Encoding.ASCII);

                string cscErr;
                if (!RunCsc(csc, rspPath, out cscErr) || !File.Exists(outExe))
                { MessageBox.Show(this, "Compilation failed:\n\n" + cscErr, "Update", MessageBoxButtons.OK, MessageBoxIcon.Error); return; }
                SwapExe(outExe, newVersion);
            }
            finally { try { Directory.Delete(temp, true); } catch { } }
        }

        void SwapExe(string newExe, string newVersion)
        {
            string cur = Application.ExecutablePath, dir = Path.GetDirectoryName(cur);
            string archive = Path.Combine(dir, "Archive", "Exe"); Directory.CreateDirectory(archive);
            string archived = Path.Combine(archive, ArchiveBaseName() + ".exe");      // same name Archive this version uses

            // Stage the freshly built EXE BESIDE the current one, so it survives the
            // caller's temp-dir cleanup (which runs the instant this method returns).
            // The .cmd then only moves files that are guaranteed to still exist.
            string staged = cur + ".new";
            File.Copy(newExe, staged, true);

            string cmd = Path.Combine(Path.GetTempPath(), "appswap_" + Guid.NewGuid().ToString("N").Substring(0, 8) + ".cmd");
            string script =
                "@echo off\r\n" +
                "ping -n 3 127.0.0.1 >nul\r\n" +                                                 // let this process fully exit
                "if exist \"" + archived + "\" del \"" + archived + "\"\r\n" +
                "move \"" + cur + "\" \"" + archived + "\" >nul 2>&1\r\n" +                       // archive the old EXE
                "move \"" + staged + "\" \"" + cur + "\" >nul 2>&1\r\n" +                          // install the new EXE
                "if not exist \"" + cur + "\" move \"" + archived + "\" \"" + cur + "\" >nul 2>&1\r\n" + // restore on failure
                "start \"\" \"" + cur + "\"\r\n" +
                "del \"%~f0\"\r\n";
            File.WriteAllText(cmd, script, Encoding.ASCII);
            _ctx.Log("INFO", "Update", "Recompiled developer build v" + _version + " -> v" + newVersion + "; staged " + staged);
            Process.Start(new ProcessStartInfo("cmd.exe", "/c \"" + cmd + "\"") { CreateNoWindow = true, UseShellExecute = false });
            Application.Exit();
        }

        // Compile a sealed build of the current package to outExe. Returns null on
        // success, else the error. No UI - used by Build Lite and the headless
        // --build-lite mode. version = the EXE's version.
        static string BuildSealedTo(string userPw, string adminPw, string outExe, string version)
        {
            string csc = FindCsc(); if (csc == null) return "csc.exe not found.";
            string sma = FindSma(); if (sma == null) return "System.Management.Automation.dll not found.";
            string source = ReadEmbeddedSource(); if (source == null) return "No embedded source (already sealed?).";

            string temp = Path.Combine(Path.GetTempPath(), "AppSeal_" + Guid.NewGuid().ToString("N").Substring(0, 12));
            Directory.CreateDirectory(temp);
            try
            {
                var all = LoadPackage();   // plaintext, all tiers, with loose config overlaid
                foreach (var dev in new[] { BuilderResource, "Build-App.cmd" }) all.Remove(dev);   // developer tooling, not runtime
                var userFiles  = all.Where(kv => kv.Key.IndexOf("Modules/Admin/", StringComparison.OrdinalIgnoreCase) < 0)
                                    .ToDictionary(kv => kv.Key, kv => kv.Value, StringComparer.OrdinalIgnoreCase);
                var adminFiles = new Dictionary<string, string>(all, StringComparer.OrdinalIgnoreCase);

                byte[] userDat  = Bundles.Seal(Bundles.DictToZipBytes(userFiles),  userPw,  Bundles.DefaultIterations);
                byte[] adminDat = Bundles.Seal(Bundles.DictToZipBytes(adminFiles), adminPw, Bundles.DefaultIterations);
                string userPath = Path.Combine(temp, "UserBundle.dat");  File.WriteAllBytes(userPath, userDat);
                string adminPath= Path.Combine(temp, "AdminBundle.dat"); File.WriteAllBytes(adminPath, adminDat);
                // Plain (not sealed): the password prompt shows AppName before any bundle is opened.
                string idPath   = Path.Combine(temp, ProjectIdentity.FileName); File.WriteAllText(idPath, IdentityJsonOf(all), new UTF8Encoding(false));

                string csPath  = Path.Combine(temp, SourceFile); File.WriteAllText(csPath, source, new UTF8Encoding(false));
                string verPath = Path.Combine(temp, "AssemblyVersionInfo.cs"); File.WriteAllText(verPath, BuildVersionInfoSource(version), Encoding.ASCII);
                string tmpExe  = Path.Combine(temp, "sealed.exe");

                var rsp = new List<string> { "/target:winexe", "/optimize+", "/define:SEALED", "/out:\"" + tmpExe + "\"" };
                foreach (var r in BaseRefs()) rsp.Add("/reference:" + r);
                rsp.Add("/reference:\"" + sma + "\"");
                foreach (var r in ParseReferences(source)) rsp.Add("/reference:\"" + r + "\"");
                rsp.Add("/resource:\"" + userPath + "\",UserBundle.dat");
                rsp.Add("/resource:\"" + adminPath + "\",AdminBundle.dat");
                rsp.Add("/resource:\"" + idPath + "\"," + ProjectIdentity.FileName);
                rsp.Add("\"" + csPath + "\""); rsp.Add("\"" + verPath + "\"");
                string rspPath = Path.Combine(temp, "build.rsp"); File.WriteAllLines(rspPath, rsp, Encoding.ASCII);

                string err;
                if (!RunCsc(csc, rspPath, out err) || !File.Exists(tmpExe)) return string.IsNullOrEmpty(err) ? "csc produced no EXE." : err;
                try { File.Copy(tmpExe, outExe, true); }
                catch (IOException ex) { return "Could not write " + outExe + " (is it running?): " + ex.Message; }
                return null;
            }
            catch (Exception ex) { return ex.Message; }
            finally { try { Directory.Delete(temp, true); } catch { } }
        }

        bool PromptTwoPasswords(out string userPw, out string adminPw)
        {
            userPw = null; adminPw = null;
            using (var dlg = new Form { Text = "Build Lite -- passwords for the sealed build", Size = new Size(400, 330),
                       FormBorderStyle = FormBorderStyle.FixedDialog, StartPosition = FormStartPosition.CenterParent,
                       MinimizeBox = false, MaximizeBox = false, Font = Font, BackColor = _theme.Panel })
            {
                var l1 = new Label { Text = "User password (user features):", AutoSize = true, Location = new Point(14, 14) };
                var t1 = new TextBox { UseSystemPasswordChar = true, Location = new Point(14, 34), Width = 356 };
                var t1b = new TextBox { UseSystemPasswordChar = true, Location = new Point(14, 62), Width = 356 };
                var l2 = new Label { Text = "Admin password (all features):", AutoSize = true, Location = new Point(14, 100) };
                var t2 = new TextBox { UseSystemPasswordChar = true, Location = new Point(14, 120), Width = 356 };
                var t2b = new TextBox { UseSystemPasswordChar = true, Location = new Point(14, 148), Width = 356 };
                var hint = new Label { Text = "Each password twice. Give users the user password; keep the admin password private.",
                                       AutoSize = false, Size = new Size(356, 36), Location = new Point(14, 184), ForeColor = _theme.Muted };
                var ok = _theme.MakeButton("Build"); ok.AutoSize = false; ok.Size = new Size(84, 28); ok.Location = new Point(196, 240);
                var cancel = _theme.MakeButton("Cancel"); cancel.AutoSize = false; cancel.Size = new Size(84, 28); cancel.Location = new Point(286, 240); cancel.DialogResult = DialogResult.Cancel;
                ok.Click += delegate
                {
                    string why = null;
                    if (t1.Text.Length == 0 || t2.Text.Length == 0) why = "Both passwords are required.";
                    else if (t1.Text != t1b.Text) why = "The two user passwords differ.";
                    else if (t2.Text != t2b.Text) why = "The two admin passwords differ.";
                    else if (t1.Text == t2.Text) why = "Use different user and admin passwords.";
                    if (why != null) { MessageBox.Show(dlg, why, "Build Lite"); return; }
                    dlg.DialogResult = DialogResult.OK;
                };
                dlg.Controls.AddRange(new Control[] { l1, t1, t1b, l2, t2, t2b, hint, ok, cancel });
                dlg.AcceptButton = ok; dlg.CancelButton = cancel;
                if (dlg.ShowDialog(this) != DialogResult.OK) return false;
                userPw = t1.Text; adminPw = t2.Text; return true;
            }
        }

        static byte[] PackSource(string source)
        {
            var lines = source.Replace("\r\n", "\n").Split('\n');
            var kept = new List<string>(); int idx = 0;
            while (idx < lines.Length)
            {
                string t = lines[idx].Trim();
                if (t.Length == 0) { idx++; continue; }
                if (t.StartsWith("//")) { if (t.ToLowerInvariant().Contains("@reference:")) kept.Add(lines[idx]); idx++; continue; }
                break;
            }
            var sb = new StringBuilder();
            foreach (var k in kept) sb.Append(k).Append("\r\n");
            if (kept.Count > 0) sb.Append("\r\n");
            for (int j = idx; j < lines.Length; j++) { sb.Append(lines[j]); if (j < lines.Length - 1) sb.Append("\r\n"); }
            byte[] raw = new UTF8Encoding(false).GetBytes(sb.ToString());
            using (var ms = new MemoryStream())
            {
                using (var gz = new GZipStream(ms, CompressionMode.Compress, true)) gz.Write(raw, 0, raw.Length);
                return ms.ToArray();
            }
        }

        static string[] BaseRefs()
        {
            return new[]
            {
                "System.dll", "System.Core.dll", "System.Windows.Forms.dll", "System.Drawing.dll",
                "System.Data.dll", "System.Web.Extensions.dll",
                "System.IO.Compression.dll", "System.IO.Compression.FileSystem.dll"
            };
        }

        static List<string> ParseReferences(string source)
        {
            var refs = new List<string>();
            foreach (var line in source.Split('\n'))
            {
                var m = System.Text.RegularExpressions.Regex.Match(line, @"^\s*//\s*@reference:\s*(.+)$");
                if (m.Success)
                {
                    string r = m.Groups[1].Value.Trim().Trim('"');
                    if (r.Length > 0 && !BaseRefs().Contains(r) && !refs.Contains(r)) refs.Add(r);
                }
            }
            return refs;
        }

        static string BuildVersionInfoSource(string version)
        {
            var p = version.TrimStart('v', 'V').Split('.');
            string v4 = (p.Length > 0 ? p[0] : "0") + "." + (p.Length > 1 ? p[1] : "0") + "." + (p.Length > 2 ? p[2] : "0") + ".0";
            var sb = new StringBuilder();
            sb.AppendLine("// Generated at build time -- do not edit.");
            sb.AppendLine("[assembly: System.Reflection.AssemblyTitle(\"" + AppName + "\")]");
            sb.AppendLine("[assembly: System.Reflection.AssemblyProduct(\"" + AppName + "\")]");
            sb.AppendLine("[assembly: System.Reflection.AssemblyVersion(\"" + v4 + "\")]");
            sb.AppendLine("[assembly: System.Reflection.AssemblyFileVersion(\"" + v4 + "\")]");
            sb.AppendLine("[assembly: System.Reflection.AssemblyInformationalVersion(\"" + version.TrimStart('v', 'V') + "\")]");
            return sb.ToString();
        }

        static string FindCsc()
        {
            string win = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
            foreach (var rel in new[] { @"Microsoft.NET\Framework64\v4.0.30319\csc.exe", @"Microsoft.NET\Framework\v4.0.30319\csc.exe" })
            { string p = Path.Combine(win, rel); if (File.Exists(p)) return p; }
            return null;
        }

        static string FindSma()
        {
            try { string loc = typeof(PowerShell).Assembly.Location; if (!string.IsNullOrEmpty(loc) && File.Exists(loc)) return loc; } catch { }
            string win = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
            string gac = Path.Combine(win, @"Microsoft.NET\assembly\GAC_MSIL\System.Management.Automation");
            if (Directory.Exists(gac))
            {
                var hit = Directory.GetFiles(gac, "System.Management.Automation.dll", SearchOption.AllDirectories).FirstOrDefault();
                if (hit != null) return hit;
            }
            return null;
        }

        static bool RunCsc(string csc, string rspPath, out string err)
        {
            var psi = new ProcessStartInfo(csc, "@\"" + rspPath + "\"")
            { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
            using (var p = Process.Start(psi))
            {
                string so = p.StandardOutput.ReadToEnd(); string se = p.StandardError.ReadToEnd();
                p.WaitForExit();
                err = (so + "\n" + se).Trim();
                return p.ExitCode == 0;
            }
        }

        // An update zipped with its folder ("MyApp/VERSION.txt", ...) is read as if
        // zipped from inside it: when EVERY entry shares one top-level folder that
        // is not itself part of the layout (Modules/Config/Archive), drop it.
        static Dictionary<string, string> StripCommonRootFolder(Dictionary<string, string> d)
        {
            if (d.Count == 0) return d;
            string root = null;
            foreach (var k in d.Keys)
            {
                int i = k.IndexOf('/');
                if (i <= 0) return d;                                 // a file at the top: nothing to strip
                string r = k.Substring(0, i);
                if (root == null) root = r;
                else if (!root.Equals(r, StringComparison.OrdinalIgnoreCase)) return d;
            }
            if (root == null || root.Equals("Modules", StringComparison.OrdinalIgnoreCase) ||
                root.Equals("Config", StringComparison.OrdinalIgnoreCase)) return d;
            var o = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            foreach (var kv in d) o[kv.Key.Substring(root.Length + 1)] = kv.Value;
            return o;
        }

        // A project folder (or a zip of one) in the 1.1 layout -> package paths:
        // Source/<path> -> <path>, Build-App.cmd stays, Build/ is left out. Anything
        // else (an update zipped from inside Source\, an Extract, a pre-1.1 folder)
        // already uses package paths and is returned as it is.
        static Dictionary<string, string> FromProjectLayout(Dictionary<string, string> d)
        {
            bool layout = d.Keys.Any(k => k.StartsWith("Source/", StringComparison.OrdinalIgnoreCase)) &&
                          !d.ContainsKey(SourceFile) && !d.ContainsKey("_AppLauncher.ps1") && !d.ContainsKey("VERSION.txt");
            if (!layout) return d;
            var o = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            foreach (var kv in d)
            {
                if (kv.Key.StartsWith("Source/", StringComparison.OrdinalIgnoreCase)) o[kv.Key.Substring(7)] = kv.Value;
                else if (kv.Key.StartsWith("Build/", StringComparison.OrdinalIgnoreCase)) continue;
                else if (kv.Key.IndexOf('/') < 0) o[kv.Key] = kv.Value;           // Build-App.cmd (and any other top-level file)
            }
            return o;
        }

        // Text files an update or a source folder may carry. Anything else (the
        // EXEs beside a source folder, zips in Update\, images ...) is not read.
        static readonly string[] SourceTextExt = { ".ps1", ".psm1", ".cs", ".json", ".txt", ".csv", ".xml", ".md", ".cmd" };

        static bool IsSourceText(string key)
        {
            string ext = Path.GetExtension(key) ?? "";
            return SourceTextExt.Any(x => x.Equals(ext, StringComparison.OrdinalIgnoreCase));
        }

        static Dictionary<string, string> ReadSourceToDict(string path)
        {
            var d = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            if (path == null) return d;
            if (Directory.Exists(path))
            {
                foreach (var f in Directory.GetFiles(path, "*", SearchOption.AllDirectories))
                {
                    string key = f.Substring(path.TrimEnd('\\').Length + 1).Replace('\\', '/');
                    if (key.StartsWith("Archive/", StringComparison.OrdinalIgnoreCase)) continue;
                    if (key.StartsWith(UpdateFolderName + "/", StringComparison.OrdinalIgnoreCase)) continue;
                    if (key.Split('/').Any(seg => seg.StartsWith("."))) continue;
                    if (!IsSourceText(key)) continue;
                    d[key] = File.ReadAllText(f, Encoding.UTF8);
                }
                return d;
            }
            using (var fs = File.OpenRead(path))
            using (var za = new ZipArchive(fs, ZipArchiveMode.Read))
                foreach (var e in za.Entries)
                {
                    if (string.IsNullOrEmpty(e.Name) || !IsSourceText(e.FullName)) continue;
                    using (var r = new StreamReader(e.Open(), Encoding.UTF8)) d[e.FullName.Replace('\\', '/')] = r.ReadToEnd();
                }
            return d;
        }

        void Err(string where, Exception ex)
        {
            try { _ctx.Log("ERROR", where, ex.ToString()); } catch { }
            MessageBox.Show(this, where + " failed:\n\n" + ex.Message, where, MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
#endif
    }

    // =====================================================================
    //  Entry point
    // =====================================================================
    static class Program
    {
        [STAThread]
        static int Main(string[] args)
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);

#if SEALED
            var run = PromptSealed();
            if (run == null) return 0;
            new MainForm(run.Item1, run.Item2).RunMessageLoop();
            return 0;
#else
            // Headless helper for Build-App.exe:  <ExeName>Dev.exe --build-lite ["<out.exe>"]
            if (args != null && args.Length > 0 && string.Equals(args[0], "--build-lite", StringComparison.OrdinalIgnoreCase))
                return MainForm.HeadlessBuildLite(args.Length > 1 ? args[1] : null);

            Dictionary<string, string> files;
            try
            {
                using (var s = Assembly.GetExecutingAssembly().GetManifestResourceStream("AppPackage.zip"))
                using (var ms = new MemoryStream()) { s.CopyTo(ms); files = Bundles.ZipBytesToDict(ms.ToArray()); }
            }
            catch (Exception ex)
            {
                MessageBox.Show("Could not read embedded package:\n" + ex.Message, MainForm.AppName, MessageBoxButtons.OK, MessageBoxIcon.Error);
                return 1;
            }
            OverlayLooseConfigPublic(files);
            new MainForm(files, "Developer").RunMessageLoop();
            return 0;
#endif
        }

#if !SEALED
        // Developer build reads live-edited Config\*.json in the source folder (SourceDir).
        static void OverlayLooseConfigPublic(Dictionary<string, string> files)
        {
            try
            {
                string dir = Path.Combine(MainForm.SourceDir(), "Config");
                if (!Directory.Exists(dir)) return;
                foreach (var f in Directory.GetFiles(dir, "*.json"))
                    files["Config/" + Path.GetFileName(f)] = File.ReadAllText(f, Encoding.UTF8);
            }
            catch { }
        }
#endif

#if SEALED
        static byte[] Res(string name)
        {
            using (var s = Assembly.GetExecutingAssembly().GetManifestResourceStream(name))
            {
                if (s == null) return null;
                using (var ms = new MemoryStream()) { s.CopyTo(ms); return ms.ToArray(); }
            }
        }

        static Tuple<Dictionary<string, string>, string> PromptSealed()
        {
            byte[] userDat = Res("UserBundle.dat");
            byte[] adminDat = Res("AdminBundle.dat");
            for (int attempt = 0; attempt < 3; attempt++)
            {
                string pw = AskPassword(attempt);
                if (pw == null) return null;
                byte[] zip = Bundles.UnsealZip(userDat, pw);
                if (zip != null) return Tuple.Create(Bundles.ZipBytesToDict(zip), "User");
                zip = Bundles.UnsealZip(adminDat, pw);
                if (zip != null) return Tuple.Create(Bundles.ZipBytesToDict(zip), "Admin");
                MessageBox.Show("Incorrect password.", MainForm.AppName, MessageBoxButtons.OK, MessageBoxIcon.Warning);
            }
            return null;
        }

        static string AskPassword(int attempt)
        {
            using (var dlg = new Form { Text = MainForm.AppName, Size = new Size(360, 150),
                       FormBorderStyle = FormBorderStyle.FixedDialog, StartPosition = FormStartPosition.CenterScreen,
                       MinimizeBox = false, MaximizeBox = false, Font = new Font("Segoe UI", 9f), BackColor = Palette.Panel })
            {
                var lbl = new Label { Text = attempt == 0 ? "Password:" : "Password (retry):", AutoSize = true, Location = new Point(14, 18), ForeColor = Palette.Title };
                var txt = new TextBox { UseSystemPasswordChar = true, Location = new Point(14, 42), Width = 316 };
                var ok  = new Button { Text = "OK", DialogResult = DialogResult.OK, Location = new Point(174, 78), Size = new Size(72, 26) };
                var cancel = new Button { Text = "Exit", DialogResult = DialogResult.Cancel, Location = new Point(256, 78), Size = new Size(72, 26) };
                dlg.Controls.AddRange(new Control[] { lbl, txt, ok, cancel });
                dlg.AcceptButton = ok; dlg.CancelButton = cancel;
                return dlg.ShowDialog() == DialogResult.OK ? txt.Text : null;
            }
        }
#endif
    }
}
