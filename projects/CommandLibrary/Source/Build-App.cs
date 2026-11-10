// Build-App.cs -- the AppTemplate builder (template-owned). Compiles to Build-App.exe,
// so a project can be built where PowerShell scripts are not allowed to run.
//
// Project folder (template 1.1) - only these three files at the top:
//   <ExeName>.exe  <ExeName>Lite.exe  Build-App.cmd
//   Source\   the source (AppHost.cs, _AppLauncher.ps1, AppIdentity.json, VERSION.txt,
//             Config\, Modules\, Build-App.cs, Build-App.ps1, ...)
//   Build\    Build-App.exe            Archive\, Update\   made by the developer EXE
// A pre-1.1 flat folder (source at the top) still builds.
//
// How you get Build-App.exe (in Build\):
//   - the developer EXE writes it after every update (from the copy of this file
//     it embeds), or
//   - double-click Build-App.cmd: it compiles this file with the machine's
//     csc.exe and runs it, or
//   - Source\Build-App.ps1 does the same where PowerShell scripts may run.
//
// What it does (it finds the project from its own folder, or -Root: the project
// folder, its Source\ or its Build\ folder all work):
//   1. checks the source layout and reads AppIdentity.json and VERSION.txt
//   2. makes the Update folder (default place for update zips) if missing
//   3. packs the source into AppPackage.zip, packs AppHost.cs into core.dat
//   4. compiles the DEVELOPER build  <ExeName>.exe  with csc.exe
//   5. runs  <ExeName>.exe --build-lite  to make  <ExeName>Lite.exe  (sealed test
//      build: admin password "a", user password "u")
//
//   Build-App.exe [-Output <path\Name.exe>] [-Root <folder>] [-NoLite] [-NoPause]
//
// Requirements: .NET Framework 4.x (csc.exe) and Windows PowerShell 5.1 installed
// (its System.Management.Automation.dll is referenced, not run). C# 5 only.
// Packing rules match the developer EXE's Update engine (paths inside Source\, plus
// Build-App.cmd from the project folder): top-level text files,
// Config\*, Modules\<Base|Lite|Admin>\*.psm1|txt|md; never Archive\, Update\ or
// dot-folders; AppHost.cs, Build-App.ps1, Build-App.cs, UPDATE.txt and the
// generated Config\FunctionMap.txt / Config\Environment.txt are not packed
// (the first three are embedded as resources of their own).

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;

static class BuildApp
{
    static readonly string[] TextExt = { ".ps1", ".psm1", ".cs", ".json", ".txt", ".csv", ".xml", ".md", ".cmd" };
    static readonly string[] Excluded = { "AppHost.cs", "Build-App.ps1", "Build-App.cs", "UPDATE.txt",
                                          "Config/FunctionMap.txt", "Config/Environment.txt" };
    static readonly string[] BaseRefs = { "System.dll", "System.Core.dll", "System.Windows.Forms.dll", "System.Drawing.dll",
                                          "System.Data.dll", "System.Web.Extensions.dll",
                                          "System.IO.Compression.dll", "System.IO.Compression.FileSystem.dll" };
    static readonly UTF8Encoding Utf8 = new UTF8Encoding(false);

    static int Main(string[] args)
    {
        string root = AppDomain.CurrentDomain.BaseDirectory.TrimEnd('\\', '/'), output = null;
        bool lite = true, pause = true;
        for (int i = 0; i < args.Length; i++)
        {
            string a = args[i].TrimStart('-', '/').ToLowerInvariant();
            if ((a == "output" || a == "outputexe") && i + 1 < args.Length) output = args[++i];
            else if (a == "root" && i + 1 < args.Length) root = Path.GetFullPath(args[++i]).TrimEnd('\\', '/');
            else if (a == "nolite") lite = false;
            else if (a == "nopause") pause = false;
            else if (a == "?" || a == "h" || a == "help")
            {
                Console.WriteLine("Build-App.exe [-Output <path\\Name.exe>] [-Root <folder>] [-NoLite] [-NoPause]");
                return 0;
            }
            else { Fail("Unknown argument: " + args[i]); return 1; }
        }

        int rc;
        try { rc = Run(root, output, lite); }
        catch (Exception ex) { Fail(ex.Message); rc = 1; }
        if (pause)
        {
            Console.WriteLine();
            Console.Write("Press any key to close ...");
            try { Console.ReadKey(true); } catch { }
        }
        return rc;
    }

    // The project folder and its source folder, from wherever we were started:
    // <project>\Build-App.exe (old), <project>\Build\Build-App.exe, -Root <project>,
    // -Root <project>\Source. Returns the project folder; src = where AppHost.cs is.
    static string FindProject(string start, out string src)
    {
        string dir = start;
        for (int up = 0; up < 3 && !string.IsNullOrEmpty(dir); up++)
        {
            if (File.Exists(Path.Combine(dir, "Source", "AppHost.cs"))) { src = Path.Combine(dir, "Source"); return dir; }
            if (File.Exists(Path.Combine(dir, "AppHost.cs")))
            {
                string parent = Path.GetDirectoryName(dir);
                bool isSource = Path.GetFileName(dir).Equals("Source", StringComparison.OrdinalIgnoreCase) && !string.IsNullOrEmpty(parent);
                src = dir;
                return isSource ? parent : dir;                    // a pre-1.1 flat folder: project = source
            }
            dir = Path.GetDirectoryName(dir);
        }
        src = start;
        return start;
    }

    static int Run(string start, string output, bool buildLite)
    {
        string root;
        string project = FindProject(start, out root);             // root = the source folder from here on
        string sourceCs = Path.Combine(root, "AppHost.cs");
        string versionTxt = Path.Combine(root, "VERSION.txt");
        if (!File.Exists(sourceCs)) throw new Exception("AppHost.cs not found in " + Path.Combine(start, "Source") + " (run Build-App.cmd from the project folder).");
        if (!File.Exists(Path.Combine(root, "_AppLauncher.ps1"))) throw new Exception("_AppLauncher.ps1 not found in " + root + ".");
        if (!Directory.Exists(Path.Combine(root, "Modules"))) throw new Exception("Modules\\ not found in " + root + ".");
        if (!File.Exists(versionTxt)) throw new Exception("VERSION.txt not found in " + root + " (one line, e.g. 1.0.0).");

        Version parsed;
        string verText = File.ReadAllText(versionTxt).Trim().TrimStart('v', 'V');
        if (!Version.TryParse(verText, out parsed)) throw new Exception("VERSION.txt does not hold a version (found '" + verText + "'). Expected e.g. 1.0.0");
        int build = Math.Max(parsed.Build, 0);
        string version = parsed.Major + "." + parsed.Minor + "." + build;
        string version4 = version + ".0";

        string appName, exeName, dataFolder;
        ReadIdentity(root, sourceCs, out appName, out exeName, out dataFolder);
        if (string.IsNullOrEmpty(output)) output = Path.Combine(project, exeName + ".exe");
        output = Path.GetFullPath(output);

        Console.WriteLine();
        Say("Application   : " + appName + "  (" + exeName + ".exe, AppData: " + dataFolder + ")", ConsoleColor.Yellow);
        Say("Version       : v" + version, ConsoleColor.Yellow);
        string tv = Path.Combine(root, "TEMPLATE_VERSION.txt");
        if (File.Exists(tv)) Say("Template      : v" + File.ReadAllText(tv).Trim(), ConsoleColor.Yellow);
        Say("Source        : " + root, ConsoleColor.Yellow);
        Say("Output target : " + output, ConsoleColor.Yellow);

        string update = Path.Combine(project, "Update");
        if (!Directory.Exists(update)) { Directory.CreateDirectory(update); Console.WriteLine("  Created " + update + " (default place for update zips)"); }

        Console.WriteLine();
        Say("Locating build tools...", ConsoleColor.Cyan);
        string csc = FindCsc(); if (csc == null) throw new Exception("csc.exe not found under %WINDIR%\\Microsoft.NET. .NET Framework 4.x is required.");
        string sma = FindSma(); if (sma == null) throw new Exception("System.Management.Automation.dll not found. Windows PowerShell 5.1 must be installed.");
        Console.WriteLine("  Compiler : " + csc);
        Console.WriteLine("  SMA      : " + sma);

        string temp = Path.Combine(Path.GetTempPath(), "AppBuild_" + Guid.NewGuid().ToString("N").Substring(0, 12));
        Directory.CreateDirectory(temp);
        try
        {
            // ---- AppPackage.zip ----
            Console.WriteLine();
            Say("Building AppPackage.zip...", ConsoleColor.Cyan);
            var pack = new List<KeyValuePair<string, string>>();   // key, full path
            var skipped = new List<string>();
            foreach (var f in Directory.GetFiles(root, "*", SearchOption.AllDirectories))
            {
                string key = f.Substring(root.Length).TrimStart('\\', '/').Replace('\\', '/');
                if (key.StartsWith("Archive/", StringComparison.OrdinalIgnoreCase) || key.StartsWith("Update/", StringComparison.OrdinalIgnoreCase)) continue;
                if (key.Split('/').Any(s => s.StartsWith("."))) continue;
                if (!TextExt.Contains(Path.GetExtension(key).ToLowerInvariant())) continue;
                if (Excluded.Any(x => x.Equals(key, StringComparison.OrdinalIgnoreCase))) continue;
                bool isTop = key.IndexOf('/') < 0;
                bool isConfig = key.StartsWith("Config/", StringComparison.OrdinalIgnoreCase) && key.Split('/').Length == 2;
                bool isModule = Regex.IsMatch(key, @"^Modules/(Base|Lite|Admin)/[^/]+\.(psm1|txt|md)$", RegexOptions.IgnoreCase);
                if (!(isTop || isConfig || isModule)) { skipped.Add(key); continue; }
                pack.Add(new KeyValuePair<string, string>(key, f));
            }
            string cmdTop = Path.Combine(project, "Build-App.cmd");
            if (!project.Equals(root, StringComparison.OrdinalIgnoreCase) && File.Exists(cmdTop) &&
                !pack.Any(kv => kv.Key.Equals("Build-App.cmd", StringComparison.OrdinalIgnoreCase)))
                pack.Add(new KeyValuePair<string, string>("Build-App.cmd", cmdTop));
            pack.Sort((x, y) => string.Compare(x.Key, y.Key, StringComparison.OrdinalIgnoreCase));
            if (skipped.Count > 0) Say("  (left out " + skipped.Count + " file(s) outside the project layout, e.g. " + skipped[0] + ")", ConsoleColor.Yellow);

            string zipPath = Path.Combine(temp, "AppPackage.zip");
            int modCount = 0;
            using (var fs = File.Create(zipPath))
            using (var za = new ZipArchive(fs, ZipArchiveMode.Create))
                foreach (var kv in pack)
                {
                    var entry = za.CreateEntry(kv.Key);
                    using (var dst = entry.Open())
                    using (var src = File.OpenRead(kv.Value)) src.CopyTo(dst);
                    if (kv.Key.StartsWith("Modules/", StringComparison.OrdinalIgnoreCase) && kv.Key.EndsWith(".psm1", StringComparison.OrdinalIgnoreCase)) modCount++;
                    else Console.WriteLine("  + " + kv.Key);
                }
            Console.WriteLine("  + Modules/ (" + modCount + " modules)");
            Console.WriteLine("  ZIP : " + Math.Round(new FileInfo(zipPath).Length / 1024.0, 1) + " KB  (" + pack.Count + " files)");

            // ---- sources and resources ----
            string srcText = File.ReadAllText(sourceCs, Utf8);
            string tempCs = Path.Combine(temp, "AppHost.cs"); File.WriteAllText(tempCs, srcText, Utf8);
            string core = Path.Combine(temp, "core.dat"); File.WriteAllBytes(core, PackSource(srcText));
            string idPath = Path.Combine(temp, "AppIdentity.json");
            File.WriteAllText(idPath, IdentityJson(appName, exeName, dataFolder), Utf8);
            string verCs = Path.Combine(temp, "AssemblyVersionInfo.cs");
            File.WriteAllText(verCs,
                "// Generated at build time from VERSION.txt -- do not edit.\r\n" +
                "[assembly: System.Reflection.AssemblyTitle(" + CsString(appName) + ")]\r\n" +
                "[assembly: System.Reflection.AssemblyProduct(" + CsString(appName) + ")]\r\n" +
                "[assembly: System.Reflection.AssemblyVersion(\"" + version4 + "\")]\r\n" +
                "[assembly: System.Reflection.AssemblyFileVersion(\"" + version4 + "\")]\r\n" +
                "[assembly: System.Reflection.AssemblyInformationalVersion(\"" + version + "\")]\r\n", Encoding.ASCII);

            var extraRefs = new List<string>();
            foreach (var line in srcText.Replace("\r\n", "\n").Split('\n'))
            {
                var m = Regex.Match(line, @"^\s*//\s*@reference:\s*(.+)$");
                if (!m.Success) continue;
                string r = m.Groups[1].Value.Trim().Trim('"');
                if (r.Length > 0 && !BaseRefs.Contains(r) && !extraRefs.Contains(r)) { extraRefs.Add(r); Console.WriteLine("  Extra reference : " + r); }
            }

            var rsp = new List<string> { "/nologo", "/target:winexe", "/optimize+", "/out:\"" + output + "\"" };
            foreach (var r in BaseRefs) rsp.Add("/reference:" + r);
            rsp.Add("/reference:\"" + sma + "\"");
            foreach (var r in extraRefs) rsp.Add("/reference:\"" + r + "\"");
            rsp.Add("/resource:\"" + zipPath + "\",AppPackage.zip");
            rsp.Add("/resource:\"" + core + "\",core.dat");
            foreach (var res in new[] { "Build-App.ps1", "Build-App.cs" })
            {
                string p = Path.Combine(root, res);
                if (!File.Exists(p)) continue;
                string copy = Path.Combine(temp, "res_" + res);
                File.Copy(p, copy, true);
                rsp.Add("/resource:\"" + copy + "\"," + res);
            }
            rsp.Add("/resource:\"" + idPath + "\",AppIdentity.json");
            rsp.Add("\"" + tempCs + "\"");
            rsp.Add("\"" + verCs + "\"");
            string rspPath = Path.Combine(temp, "build.rsp"); File.WriteAllLines(rspPath, rsp, Encoding.ASCII);

            // ---- compile ----
            Console.WriteLine();
            Say("Compiling...", ConsoleColor.Cyan);
            string outText; int code = RunProcess(csc, "@\"" + rspPath + "\"", root, 600000, out outText);
            if (outText.Trim().Length > 0) Console.WriteLine(outText.Trim());
            if (code != 0)
            {
                if (outText.IndexOf("CS0016", StringComparison.Ordinal) >= 0)
                    Say("The output EXE is probably running. Close " + Path.GetFileName(output) + " and build again.", ConsoleColor.Yellow);
                throw new Exception("Compilation failed (exit " + code + "). See the output above.");
            }
            if (!File.Exists(output))
            {
                Say("csc.exe finished but the EXE is not there: " + output, ConsoleColor.Red);
                Say("This is almost always antivirus quarantine. Check Windows Security > Protection history.", ConsoleColor.Yellow);
                return 1;
            }
            Console.WriteLine();
            Say("Build complete: v" + version, ConsoleColor.Green);
            Console.WriteLine("  Output : " + output);
            Console.WriteLine("  Size   : " + Math.Round(new FileInfo(output).Length / 1024.0, 1) + " KB");
            Say("This is a DEVELOPER build (embedded source + full tooling). Do NOT distribute it.", ConsoleColor.Cyan);
            Say("Use its Build Sealed button for the distributable with real user/admin passwords.", ConsoleColor.Cyan);
        }
        finally { try { Directory.Delete(temp, true); } catch { } }

        // ---- the Lite EXE, built by the developer EXE itself (same code as its Build Lite button) ----
        if (!buildLite) return 0;
        Console.WriteLine();
        Say("Building " + exeName + "Lite.exe (sealed test build)...", ConsoleColor.Cyan);
        string lite = Path.Combine(Path.GetDirectoryName(output), exeName + "Lite.exe");
        string liteOut; int liteCode;
        try { liteCode = RunProcess(output, "--build-lite \"" + lite + "\"", Path.GetDirectoryName(output), 600000, out liteOut); }
        catch (Exception ex) { liteCode = -1; liteOut = ex.Message; }
        if (liteCode == 0 && File.Exists(lite))
        {
            Say("  " + lite, ConsoleColor.Green);
            Console.WriteLine("  Passwords: admin 'a', user 'u' (testing only).");
            return 0;
        }
        Say(exeName + "Lite.exe was not built (exit " + liteCode + "):", ConsoleColor.Yellow);
        if (liteOut.Trim().Length > 0) Console.WriteLine(liteOut.Trim());
        Say("The developer EXE builds it on its first start, or use its Build Lite button.", ConsoleColor.Yellow);
        return 0;   // the developer build itself succeeded
    }

    // AppIdentity.json, or (sources older than template 1.0.17) the PROJECT
    // IDENTITY constants in AppHost.cs.
    static void ReadIdentity(string root, string sourceCs, out string appName, out string exeName, out string dataFolder)
    {
        appName = exeName = dataFolder = "";
        string idFile = Path.Combine(root, "AppIdentity.json");
        if (File.Exists(idFile))
        {
            Dictionary<string, object> o;
            try { o = new JavaScriptSerializer().DeserializeObject(File.ReadAllText(idFile, Encoding.UTF8)) as Dictionary<string, object>; }
            catch (Exception ex) { throw new Exception("AppIdentity.json is not valid JSON: " + ex.Message); }
            if (o == null) throw new Exception("AppIdentity.json must be a JSON object.");
            appName = Field(o, "AppName"); exeName = Field(o, "ExeName"); dataFolder = Field(o, "AppDataFolder");
        }
        else
        {
            string cs = File.ReadAllText(sourceCs);
            var m = Regex.Match(cs, "const string AppName\\s*=\\s*\"([^\"]+)\"");       if (m.Success) appName = m.Groups[1].Value;
            m = Regex.Match(cs, "const string ExeName\\s*=\\s*\"([^\"]+)\"");           if (m.Success) exeName = m.Groups[1].Value;
            m = Regex.Match(cs, "const string AppDataFolder\\s*=\\s*\"([^\"]+)\"");     if (m.Success) dataFolder = m.Groups[1].Value;
            if (appName == "" || exeName == "") throw new Exception("AppIdentity.json not found in " + root + ".");
            Say("No AppIdentity.json: names read from the PROJECT IDENTITY block in AppHost.cs (pre-1.0.17 source).", ConsoleColor.Yellow);
        }
        appName = appName.Trim(); exeName = exeName.Trim(); dataFolder = dataFolder.Trim();
        if (appName == "" || exeName == "" || dataFolder == "") throw new Exception("AppIdentity.json needs AppName, ExeName and AppDataFolder.");
        var bad = Path.GetInvalidFileNameChars();
        if (exeName.IndexOfAny(bad) >= 0 || dataFolder.IndexOfAny(bad) >= 0) throw new Exception("AppIdentity.json: ExeName and AppDataFolder must be valid file names.");
    }

    static string Field(Dictionary<string, object> o, string key)
    {
        foreach (var kv in o)
            if (string.Equals(kv.Key, key, StringComparison.OrdinalIgnoreCase) && kv.Value != null) return kv.Value.ToString();
        return "";
    }

    static string IdentityJson(string a, string x, string d)
    {
        var js = new JavaScriptSerializer();
        return "{\r\n    \"AppName\": " + js.Serialize(a) + ",\r\n    \"ExeName\": " + js.Serialize(x) +
               ",\r\n    \"AppDataFolder\": " + js.Serialize(d) + "\r\n}\r\n";
    }

    static string CsString(string s) { return "\"" + s.Replace("\\", "\\\\").Replace("\"", "\\\"") + "\""; }

    // gzip(AppHost.cs without its leading comment banner; "// @reference:" lines kept).
    // Same algorithm as the developer EXE's PackSource.
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
        byte[] raw = Utf8.GetBytes(sb.ToString());
        using (var ms = new MemoryStream())
        {
            using (var gz = new GZipStream(ms, CompressionMode.Compress, true)) gz.Write(raw, 0, raw.Length);
            return ms.ToArray();
        }
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
        string win = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
        foreach (var rel in new[] { @"System32\WindowsPowerShell\v1.0\System.Management.Automation.dll" })
        { string p = Path.Combine(win, rel); if (File.Exists(p)) return p; }
        string gac = Path.Combine(win, @"Microsoft.NET\assembly\GAC_MSIL\System.Management.Automation");
        if (Directory.Exists(gac))
        {
            var hit = Directory.GetFiles(gac, "System.Management.Automation.dll", SearchOption.AllDirectories).FirstOrDefault();
            if (hit != null) return hit;
        }
        return null;
    }

    // Run a process, capture stdout + stderr (read on their own threads, so a full
    // pipe never blocks it). Returns the exit code.
    static int RunProcess(string exe, string arguments, string workDir, int timeoutMs, out string output)
    {
        var psi = new ProcessStartInfo(exe, arguments)
        {
            UseShellExecute = false, CreateNoWindow = true, WorkingDirectory = workDir,
            RedirectStandardOutput = true, RedirectStandardError = true
        };
        var buf = new StringBuilder(); var gate = new object();
        using (var p = new Process { StartInfo = psi })
        {
            p.OutputDataReceived += (s, e) => { if (e.Data != null) lock (gate) buf.AppendLine(e.Data); };
            p.ErrorDataReceived  += (s, e) => { if (e.Data != null) lock (gate) buf.AppendLine(e.Data); };
            p.Start(); p.BeginOutputReadLine(); p.BeginErrorReadLine();
            if (!p.WaitForExit(timeoutMs)) { try { p.Kill(); } catch { } lock (gate) buf.AppendLine("(timed out)"); output = buf.ToString(); return -1; }
            p.WaitForExit();
            lock (gate) output = buf.ToString();
            return p.ExitCode;
        }
    }

    static void Say(string text, ConsoleColor color)
    {
        var old = Console.ForegroundColor;
        try { Console.ForegroundColor = color; Console.WriteLine(text); }
        finally { Console.ForegroundColor = old; }
    }

    static void Fail(string text) { Console.WriteLine(); Say("BUILD FAILED: " + text, ConsoleColor.Red); }
}
