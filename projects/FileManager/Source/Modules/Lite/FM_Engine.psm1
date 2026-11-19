# FM_Engine.psm1   (LITE TIER)
#
# The File Manager engine: one catalog (SQLite, using winsqlite3.dll that ships
# with Windows 10 1607+ and Windows 11 - nothing to install) and the background
# work (scan, content check, duplicate analysis, moves, undo, re-checked deletes,
# copy verification). It is C# compiled once per session with Add-Type, so the
# heavy loops run at native speed and never block the window.
#
#   Get-FmCatalog  -App $App          the one catalog for this session
#   Get-FmSettings -App $App          Settings\FileManager.json (ignore lists ...)
#   Save-FmSettings -App $App -Settings $s
#   New-FmOptions  -App $App [-ContentCheck] [-HashAllSameSize] [-IncludeQuick]
#
# Where things are: the catalog is <LocalAppData>\FileManagerData\Catalog\FileManager.db
# (always local - a database on a network share is slow and fragile).

$script:FmEngineSource = @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using Microsoft.Win32.SafeHandles;

// FileManager engine. C# 5 only (compiled by Windows PowerShell 5.1 Add-Type),
// mscorlib only (no System.Core / System.dll types), so it compiles anywhere.
namespace FileManagerEngine
{
    // =====================================================================
    //  SQLite: winsqlite3.dll ships with Windows 10 (1607+) and 11.
    // =====================================================================
    internal static class SqliteNative
    {
        const string Lib = "winsqlite3.dll";
        const CallingConvention CC = CallingConvention.StdCall;
        [DllImport(Lib, CallingConvention = CC, CharSet = CharSet.Unicode)] public static extern int sqlite3_open16(string filename, out IntPtr db);
        [DllImport(Lib, CallingConvention = CC)] public static extern int sqlite3_close_v2(IntPtr db);
        [DllImport(Lib, CallingConvention = CC)] public static extern int sqlite3_busy_timeout(IntPtr db, int ms);
        [DllImport(Lib, CallingConvention = CC)] public static extern int sqlite3_prepare16_v2(IntPtr db, IntPtr sql, int nByte, out IntPtr stmt, out IntPtr tail);
        [DllImport(Lib, CallingConvention = CC)] public static extern int sqlite3_step(IntPtr stmt);
        [DllImport(Lib, CallingConvention = CC)] public static extern int sqlite3_reset(IntPtr stmt);
        [DllImport(Lib, CallingConvention = CC)] public static extern int sqlite3_clear_bindings(IntPtr stmt);
        [DllImport(Lib, CallingConvention = CC)] public static extern int sqlite3_finalize(IntPtr stmt);
        [DllImport(Lib, CallingConvention = CC)] public static extern int sqlite3_bind_int64(IntPtr stmt, int index, long value);
        [DllImport(Lib, CallingConvention = CC)] public static extern int sqlite3_bind_double(IntPtr stmt, int index, double value);
        [DllImport(Lib, CallingConvention = CC)] public static extern int sqlite3_bind_null(IntPtr stmt, int index);
        [DllImport(Lib, CallingConvention = CC, CharSet = CharSet.Unicode)] public static extern int sqlite3_bind_text16(IntPtr stmt, int index, string value, int nBytes, IntPtr destructor);
        [DllImport(Lib, CallingConvention = CC)] public static extern int sqlite3_column_count(IntPtr stmt);
        [DllImport(Lib, CallingConvention = CC)] public static extern int sqlite3_column_type(IntPtr stmt, int col);
        [DllImport(Lib, CallingConvention = CC)] public static extern long sqlite3_column_int64(IntPtr stmt, int col);
        [DllImport(Lib, CallingConvention = CC)] public static extern double sqlite3_column_double(IntPtr stmt, int col);
        [DllImport(Lib, CallingConvention = CC)] public static extern IntPtr sqlite3_column_text16(IntPtr stmt, int col);
        [DllImport(Lib, CallingConvention = CC)] public static extern int sqlite3_column_bytes16(IntPtr stmt, int col);
        [DllImport(Lib, CallingConvention = CC)] public static extern IntPtr sqlite3_errmsg16(IntPtr db);
        [DllImport(Lib, CallingConvention = CC)] public static extern long sqlite3_last_insert_rowid(IntPtr db);
        [DllImport(Lib, CallingConvention = CC)] public static extern int sqlite3_changes(IntPtr db);
    }

    public sealed class Db : IDisposable
    {
        IntPtr _h;

        public Db(string path)
        {
            int rc = SqliteNative.sqlite3_open16(path, out _h);
            if (rc != 0)
            {
                string m = ErrorText();
                Dispose();
                throw new InvalidOperationException("Cannot open the catalog database " + path + ": " + m);
            }
            SqliteNative.sqlite3_busy_timeout(_h, 60000);
        }

        internal string ErrorText()
        {
            if (_h == IntPtr.Zero) return "unknown error";
            IntPtr p = SqliteNative.sqlite3_errmsg16(_h);
            return p == IntPtr.Zero ? "unknown error" : Marshal.PtrToStringUni(p);
        }

        public Stmt Prepare(string sql)
        {
            IntPtr mem = Marshal.StringToHGlobalUni(sql);
            try
            {
                IntPtr st, tail;
                int rc = SqliteNative.sqlite3_prepare16_v2(_h, mem, -1, out st, out tail);
                if (rc != 0) throw new InvalidOperationException("Database error: " + ErrorText() + "  (" + sql + ")");
                return new Stmt(this, st);
            }
            finally { Marshal.FreeHGlobal(mem); }
        }

        // One or more statements without parameters.
        public void Exec(string sql)
        {
            IntPtr mem = Marshal.StringToHGlobalUni(sql);
            try
            {
                IntPtr cur = mem;
                while (true)
                {
                    IntPtr st, tail;
                    int rc = SqliteNative.sqlite3_prepare16_v2(_h, cur, -1, out st, out tail);
                    if (rc != 0) throw new InvalidOperationException("Database error: " + ErrorText());
                    if (st == IntPtr.Zero) break;
                    try
                    {
                        int s;
                        while ((s = SqliteNative.sqlite3_step(st)) == 100) { }
                        if (s != 101) throw new InvalidOperationException("Database error: " + ErrorText());
                    }
                    finally { SqliteNative.sqlite3_finalize(st); }
                    if (tail == IntPtr.Zero || tail == cur) break;
                    cur = tail;
                    if (Marshal.ReadInt16(cur) == 0) break;
                }
            }
            finally { Marshal.FreeHGlobal(mem); }
        }

        public int Run(string sql, params object[] args)
        {
            using (Stmt s = Prepare(sql)) { s.Bind(args); s.Step(); }
            return SqliteNative.sqlite3_changes(_h);
        }

        public object Scalar(string sql, params object[] args)
        {
            using (Stmt s = Prepare(sql)) { s.Bind(args); return s.Step() ? s.Value(0) : null; }
        }

        public long ScalarLong(string sql, params object[] args) { return Util.L(Scalar(sql, args)); }

        public List<object[]> Rows(string sql, params object[] args)
        {
            List<object[]> list = new List<object[]>();
            using (Stmt s = Prepare(sql)) { s.Bind(args); while (s.Step()) list.Add(s.Row()); }
            return list;
        }

        public long LastId { get { return SqliteNative.sqlite3_last_insert_rowid(_h); } }
        public void Begin() { Exec("BEGIN IMMEDIATE"); }
        public void Commit() { Exec("COMMIT"); }
        public void Rollback() { try { Exec("ROLLBACK"); } catch { } }

        public void Dispose()
        {
            if (_h != IntPtr.Zero) { SqliteNative.sqlite3_close_v2(_h); _h = IntPtr.Zero; }
        }
    }

    public sealed class Stmt : IDisposable
    {
        readonly Db _db;
        IntPtr _h;
        static readonly IntPtr Transient = new IntPtr(-1);

        internal Stmt(Db db, IntPtr h) { _db = db; _h = h; }

        public void Bind(params object[] args)
        {
            SqliteNative.sqlite3_reset(_h);
            SqliteNative.sqlite3_clear_bindings(_h);
            if (args == null) return;
            for (int i = 0; i < args.Length; i++) BindOne(i + 1, args[i]);
        }

        void BindOne(int i, object v)
        {
            int rc;
            if (v == null || v is DBNull) rc = SqliteNative.sqlite3_bind_null(_h, i);
            else if (v is string) rc = SqliteNative.sqlite3_bind_text16(_h, i, (string)v, -1, Transient);
            else if (v is bool) rc = SqliteNative.sqlite3_bind_int64(_h, i, ((bool)v) ? 1 : 0);
            else if (v is double || v is float || v is decimal) rc = SqliteNative.sqlite3_bind_double(_h, i, Convert.ToDouble(v));
            else if (v is long || v is int || v is short || v is byte || v is uint || v is ulong || v is ushort || v is sbyte) rc = SqliteNative.sqlite3_bind_int64(_h, i, Convert.ToInt64(v));
            else rc = SqliteNative.sqlite3_bind_text16(_h, i, v.ToString(), -1, Transient);
            if (rc != 0) throw new InvalidOperationException("Database bind error: " + _db.ErrorText());
        }

        public bool Step()
        {
            int rc = SqliteNative.sqlite3_step(_h);
            if (rc == 100) return true;
            if (rc == 101) return false;
            string m = _db.ErrorText();
            SqliteNative.sqlite3_reset(_h);
            throw new InvalidOperationException("Database error: " + m);
        }

        public void Exec(params object[] args) { Bind(args); Step(); }
        public int Columns { get { return SqliteNative.sqlite3_column_count(_h); } }
        public bool IsNull(int c) { return SqliteNative.sqlite3_column_type(_h, c) == 5; }
        public long Long(int c) { return SqliteNative.sqlite3_column_int64(_h, c); }

        public string Text(int c)
        {
            IntPtr p = SqliteNative.sqlite3_column_text16(_h, c);
            if (p == IntPtr.Zero) return null;
            int n = SqliteNative.sqlite3_column_bytes16(_h, c);
            return Marshal.PtrToStringUni(p, n / 2);
        }

        public object Value(int c)
        {
            switch (SqliteNative.sqlite3_column_type(_h, c))
            {
                case 1: return Long(c);
                case 2: return SqliteNative.sqlite3_column_double(_h, c);
                case 5: return null;
                default: return Text(c);
            }
        }

        public object[] Row()
        {
            int n = Columns;
            object[] r = new object[n];
            for (int i = 0; i < n; i++) r[i] = Value(i);
            return r;
        }

        public void Dispose()
        {
            if (_h != IntPtr.Zero) { SqliteNative.sqlite3_finalize(_h); _h = IntPtr.Zero; }
        }
    }

    // =====================================================================
    //  File system: Win32 calls with \\?\ paths (no 260-character limit).
    // =====================================================================
    internal static class NativeFs
    {
        [StructLayout(LayoutKind.Sequential)]
        public struct FILETIME { public uint Low; public uint High; }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        public struct WIN32_FIND_DATA
        {
            public uint Attributes;
            public FILETIME Created;
            public FILETIME Accessed;
            public FILETIME Written;
            public uint SizeHigh;
            public uint SizeLow;
            public uint Reserved0;
            public uint Reserved1;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string Name;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 14)] public string AltName;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] public static extern IntPtr FindFirstFileExW(string name, int infoLevel, out WIN32_FIND_DATA data, int searchOp, IntPtr filter, int flags);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] public static extern bool FindNextFileW(IntPtr h, out WIN32_FIND_DATA data);
        [DllImport("kernel32.dll", SetLastError = true)] public static extern bool FindClose(IntPtr h);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] public static extern SafeFileHandle CreateFileW(string name, uint access, uint share, IntPtr sec, uint disposition, uint flags, IntPtr template);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] public static extern bool MoveFileExW(string from, string to, uint flags);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] public static extern bool CreateDirectoryW(string name, IntPtr sec);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] public static extern bool RemoveDirectoryW(string name);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] public static extern bool DeleteFileW(string name);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] public static extern uint GetFileAttributesW(string name);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] public static extern bool SetFileAttributesW(string name, uint attrs);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] public static extern bool GetVolumeInformationW(string root, StringBuilder volName, int volNameSize, out uint serial, out uint maxComp, out uint fsFlags, StringBuilder fsName, int fsNameSize);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] public static extern bool GetDiskFreeSpaceExW(string dir, out ulong freeToCaller, out ulong total, out ulong totalFree);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] public static extern uint GetDriveTypeW(string root);
    }

    public sealed class FsEntry
    {
        public string Name;
        public bool IsDir;
        public bool IsReparse;
        public uint Attributes;
        public long Size;
        public long Written;   // FILETIME (UTC, 100 ns since 1601)
    }

    public static class Fs
    {
        public const uint ReadOnly = 0x1, Hidden = 0x2, SystemAttr = 0x4, DirAttr = 0x10, Reparse = 0x400, Offline = 0x1000, RecallOnOpen = 0x40000, RecallOnData = 0x400000;
        const uint Invalid = 0xFFFFFFFF;
        static readonly IntPtr BadHandle = new IntPtr(-1);

        public static string Long(string p)
        {
            if (p.StartsWith(@"\\?\")) return p;
            if (p.StartsWith(@"\\")) return @"\\?\UNC\" + p.Substring(2);
            return @"\\?\" + p;
        }

        public static string Join(string a, string b)
        {
            if (string.IsNullOrEmpty(a)) return b;
            if (string.IsNullOrEmpty(b)) return a;
            return a.EndsWith("\\") ? a + b : a + "\\" + b;
        }

        public static string Parent(string p)
        {
            string t = p.TrimEnd('\\');
            int i = t.LastIndexOf('\\');
            if (i < 0) return null;
            if (i == 2 && t.Length > 1 && t[1] == ':') return t.Substring(0, 3);
            return t.Substring(0, i);
        }

        public static string LastPart(string p)
        {
            string t = p.TrimEnd('\\');
            int i = t.LastIndexOf('\\');
            return i < 0 ? t : t.Substring(i + 1);
        }

        public static string ErrText(int code)
        {
            try
            {
                Exception e = Marshal.GetExceptionForHR(unchecked((int)0x80070000 | code));
                return e != null ? e.Message.Trim() + " (" + code + ")" : "Windows error " + code;
            }
            catch { return "Windows error " + code; }
        }

        public static bool Exists(string p) { return NativeFs.GetFileAttributesW(Long(p)) != Invalid; }

        public static bool IsDir(string p)
        {
            uint a = NativeFs.GetFileAttributesW(Long(p));
            return a != Invalid && (a & DirAttr) != 0;
        }

        public static List<FsEntry> ListDir(string dir, out int error)
        {
            List<FsEntry> list = new List<FsEntry>();
            error = 0;
            NativeFs.WIN32_FIND_DATA d;
            IntPtr h = NativeFs.FindFirstFileExW(Long(Join(dir, "*")), 1, out d, 0, IntPtr.Zero, 2);
            if (h == BadHandle)
            {
                int e = Marshal.GetLastWin32Error();
                if (e != 2 && e != 18) error = e;
                return list;
            }
            try
            {
                do
                {
                    if (d.Name == "." || d.Name == "..") continue;
                    FsEntry en = new FsEntry();
                    en.Name = d.Name;
                    en.Attributes = d.Attributes;
                    en.IsDir = (d.Attributes & DirAttr) != 0;
                    en.IsReparse = (d.Attributes & Reparse) != 0;
                    en.Size = ((long)d.SizeHigh << 32) | d.SizeLow;
                    en.Written = ((long)d.Written.High << 32) | d.Written.Low;
                    list.Add(en);
                } while (NativeFs.FindNextFileW(h, out d));
            }
            finally { NativeFs.FindClose(h); }
            return list;
        }

        // One file or folder (no wildcard); null when it does not exist.
        public static FsEntry Info(string path)
        {
            NativeFs.WIN32_FIND_DATA d;
            IntPtr h = NativeFs.FindFirstFileExW(Long(path.TrimEnd('\\')), 1, out d, 0, IntPtr.Zero, 0);
            if (h == BadHandle) return null;
            NativeFs.FindClose(h);
            FsEntry en = new FsEntry();
            en.Name = d.Name;
            en.Attributes = d.Attributes;
            en.IsDir = (d.Attributes & DirAttr) != 0;
            en.IsReparse = (d.Attributes & Reparse) != 0;
            en.Size = ((long)d.SizeHigh << 32) | d.SizeLow;
            en.Written = ((long)d.Written.High << 32) | d.Written.Low;
            return en;
        }

        public static void EnsureDir(string p)
        {
            if (IsDir(p)) return;
            string parent = Parent(p);
            if (parent != null && !string.Equals(parent, p, StringComparison.OrdinalIgnoreCase)) EnsureDir(parent);
            if (!NativeFs.CreateDirectoryW(Long(p), IntPtr.Zero))
            {
                int e = Marshal.GetLastWin32Error();
                if (e != 183) throw new IOException("Cannot create folder " + p + ": " + ErrText(e));
            }
        }

        // Same-drive move (a rename). Never copies: a move to another drive fails.
        public static void Move(string from, string to)
        {
            if (!NativeFs.MoveFileExW(Long(from), Long(to), 0))
                throw new IOException("Cannot move " + from + " to " + to + ": " + ErrText(Marshal.GetLastWin32Error()));
        }

        public static FileStream OpenRead(string path)
        {
            SafeFileHandle h = NativeFs.CreateFileW(Long(path), 0x80000000, 0x7, IntPtr.Zero, 3, 0x08000000, IntPtr.Zero);
            if (h.IsInvalid)
            {
                int e = Marshal.GetLastWin32Error();
                h.Dispose();
                throw new IOException(ErrText(e));
            }
            return new FileStream(h, FileAccess.Read, 65536, false);
        }

        public static void WriteText(string path, string text)
        {
            SafeFileHandle h = NativeFs.CreateFileW(Long(path), 0x40000000, 0, IntPtr.Zero, 2, 0x80, IntPtr.Zero);
            if (h.IsInvalid)
            {
                int e = Marshal.GetLastWin32Error();
                h.Dispose();
                throw new IOException("Cannot write " + path + ": " + ErrText(e));
            }
            using (FileStream fs = new FileStream(h, FileAccess.Write))
            {
                byte[] b = Encoding.UTF8.GetBytes(text);
                fs.Write(b, 0, b.Length);
            }
        }

        public static void DeleteFile(string path)
        {
            string lp = Long(path);
            uint a = NativeFs.GetFileAttributesW(lp);
            if (a != Invalid && (a & ReadOnly) != 0) NativeFs.SetFileAttributesW(lp, a & ~ReadOnly);
            if (!NativeFs.DeleteFileW(lp)) throw new IOException("Cannot delete " + path + ": " + ErrText(Marshal.GetLastWin32Error()));
        }

        public static bool TryRemoveDir(string path)
        {
            string lp = Long(path);
            uint a = NativeFs.GetFileAttributesW(lp);
            if (a != Invalid && (a & ReadOnly) != 0) NativeFs.SetFileAttributesW(lp, a & ~ReadOnly);
            return NativeFs.RemoveDirectoryW(lp);
        }

        // Deletes a folder and everything in it. A junction / link inside is
        // removed as a link only (never followed).
        public static void DeleteTree(string path, Job job)
        {
            int err;
            foreach (FsEntry e in ListDir(path, out err))
            {
                if (job != null) job.Check();
                string full = Join(path, e.Name);
                if (e.IsDir && !e.IsReparse) DeleteTree(full, job);
                else if (e.IsDir) { if (!TryRemoveDir(full)) throw new IOException("Cannot remove link " + full + ": " + ErrText(Marshal.GetLastWin32Error())); }
                else DeleteFile(full);
            }
            if (err != 0) throw new IOException("Cannot read " + path + ": " + ErrText(err));
            if (!TryRemoveDir(path)) throw new IOException("Cannot remove " + path + ": " + ErrText(Marshal.GetLastWin32Error()));
        }
    }

    // =====================================================================
    //  Hashing and small helpers
    // =====================================================================
    public static class Hasher
    {
        public static string Algorithm = "MD5";
        [ThreadStatic] static byte[] _buf;
        [ThreadStatic] static HashAlgorithm _text;
        [ThreadStatic] static string _textAlg;

        public static HashAlgorithm Create()
        {
            if (Algorithm == "SHA1") return SHA1.Create();
            return MD5.Create();
        }

        // MD5 is fastest; machines with the FIPS policy refuse it, so use SHA-1 there.
        public static string Detect()
        {
            try { using (HashAlgorithm m = MD5.Create()) { m.ComputeHash(new byte[1]); } return "MD5"; }
            catch { return "SHA1"; }
        }

        public static string Hex(byte[] h)
        {
            StringBuilder sb = new StringBuilder(h.Length * 2);
            foreach (byte b in h) sb.Append(b.ToString("x2"));
            return sb.ToString();
        }

        public static string OfText(string s)
        {
            if (_text == null || _textAlg != Algorithm) { _text = Create(); _textAlg = Algorithm; }
            return Hex(_text.ComputeHash(Encoding.UTF8.GetBytes(s)));
        }

        public static string Empty()
        {
            using (HashAlgorithm a = Create()) return Hex(a.ComputeHash(new byte[0]));
        }

        public static string OfFile(string path, Job job)
        {
            if (_buf == null) _buf = new byte[1 << 20];
            using (FileStream fs = Fs.OpenRead(path))
            using (HashAlgorithm a = Create())
            {
                int n;
                while ((n = fs.Read(_buf, 0, _buf.Length)) > 0)
                {
                    a.TransformBlock(_buf, 0, n, null, 0);
                    if (job != null)
                    {
                        Interlocked.Add(ref job.BytesDone, n);
                        if (job.CancelRequested) throw new OperationCanceledException();
                    }
                }
                a.TransformFinalBlock(_buf, 0, 0);
                return Hex(a.Hash);
            }
        }

        // Folder fingerprints. The same rules are used by the scan, the
        // re-check before deleting and the verify step:
        //   quick   = the sizes of its files + its sub folders' quick prints
        //   content = the hashes of its files + its sub folders' content prints
        // Names and dates are never part of a fingerprint. Empty sub folders are left out.
        public static string QuickSig(List<long> sizes, List<string> kids)
        {
            sizes.Sort();
            kids.Sort(StringComparer.Ordinal);
            StringBuilder sb = new StringBuilder("Q|");
            for (int i = 0; i < sizes.Count; i++) { if (i > 0) sb.Append(','); sb.Append(sizes[i]); }
            sb.Append('|');
            sb.Append(string.Join(",", kids.ToArray()));
            return OfText(sb.ToString());
        }

        public static string ContentSig(List<string> hashSizes, List<string> kids)
        {
            hashSizes.Sort(StringComparer.Ordinal);
            kids.Sort(StringComparer.Ordinal);
            return OfText("C|" + string.Join(",", hashSizes.ToArray()) + "|" + string.Join(",", kids.ToArray()));
        }
    }

    public static class Wild
    {
        public static string[] Prepare(string[] patterns)
        {
            List<string> l = new List<string>();
            if (patterns != null) foreach (string p in patterns) { if (p != null && p.Trim().Length > 0) l.Add(p.Trim().ToLowerInvariant()); }
            return l.ToArray();
        }

        // * = any run of characters, ? = one character; s and p are lower case.
        public static bool Match(string s, string p)
        {
            int si = 0, pi = 0, star = -1, mark = 0;
            while (si < s.Length)
            {
                if (pi < p.Length && (p[pi] == '?' || p[pi] == s[si])) { si++; pi++; }
                else if (pi < p.Length && p[pi] == '*') { star = pi++; mark = si; }
                else if (star >= 0) { pi = star + 1; si = ++mark; }
                else return false;
            }
            while (pi < p.Length && p[pi] == '*') pi++;
            return pi == p.Length;
        }

        public static bool Any(string lowerName, string[] prepared)
        {
            for (int i = 0; i < prepared.Length; i++) if (Match(lowerName, prepared[i])) return true;
            return false;
        }
    }

    public static class Util
    {
        public static long L(object o) { return o == null ? 0 : Convert.ToInt64(o); }
        public static string S(object o) { return o == null ? "" : Convert.ToString(o); }
        public static string Now() { return DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss"); }

        public static string Date(long fileTime)
        {
            if (fileTime <= 0) return "";
            try { return DateTime.FromFileTimeUtc(fileTime).ToLocalTime().ToString("yyyy-MM-dd"); } catch { return ""; }
        }

        public static string Size(long b)
        {
            double v = b;
            string[] u = { "bytes", "KB", "MB", "GB", "TB" };
            int i = 0;
            while (v >= 1024 && i < u.Length - 1) { v /= 1024; i++; }
            return i == 0 ? b + " bytes" : v.ToString(v >= 100 ? "0" : "0.0") + " " + u[i];
        }

        // SQLite counts characters (code points); C# counts UTF-16 units.
        public static int CodePoints(string s)
        {
            int n = 0;
            for (int i = 0; i < s.Length; i++) if (!char.IsLowSurrogate(s[i])) n++;
            return n;
        }

        // A literal for the PowerShell shown in the command window.
        public static string Q(string s) { return "'" + s.Replace("'", "''") + "'"; }

        public static string StripClean(string rel)
        {
            if (rel.StartsWith(Catalog.CleanName + "\\", StringComparison.OrdinalIgnoreCase)) return rel.Substring(Catalog.CleanName.Length + 1);
            return rel;
        }

        public static bool InClean(string rel)
        {
            return rel.StartsWith(Catalog.CleanName + "\\", StringComparison.OrdinalIgnoreCase);
        }

        public static string Csv(string s)
        {
            if (s == null) return "";
            if (s.IndexOfAny(new char[] { ',', '"', '\r', '\n' }) >= 0) return "\"" + s.Replace("\"", "\"\"") + "\"";
            return s;
        }

        public static string Html(string s)
        {
            if (s == null) return "";
            return s.Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;").Replace("\"", "&quot;");
        }
    }

    // =====================================================================
    //  A background task. The UI polls it with a timer.
    // =====================================================================
    public class Job
    {
        public string Name = "";
        public volatile string Phase = "Starting";
        public volatile string Current = "";
        public long FilesDone, FilesTotal, BytesDone, BytesTotal, Folders, Errors;
        public volatile bool Finished, Failed, Cancelled, CancelRequested;
        public volatile string Error = "";
        public volatile string Summary = "";
        public DateTime StartedUtc = DateTime.UtcNow;
        public DateTime PhaseStartedUtc = DateTime.UtcNow;
        public long ResultId;
        readonly List<string> _log = new List<string>();
        readonly List<string> _all = new List<string>();
        readonly object _lock = new object();

        public void Log(string s)
        {
            string line = DateTime.Now.ToString("HH:mm:ss") + "  " + s;
            lock (_lock) { _log.Add(line); if (_all.Count < 5000) _all.Add(line); }
        }

        public string[] TakeLog() { lock (_lock) { string[] a = _log.ToArray(); _log.Clear(); return a; } }
        public string[] FullLog() { lock (_lock) { return _all.ToArray(); } }
        public void Cancel() { CancelRequested = true; }
        public double Seconds { get { return (DateTime.UtcNow - StartedUtc).TotalSeconds; } }
        public double PhaseSeconds { get { return (DateTime.UtcNow - PhaseStartedUtc).TotalSeconds; } }
        public void Check() { if (CancelRequested) throw new OperationCanceledException(); }

        public void NewPhase(string phase, long filesTotal, long bytesTotal)
        {
            Phase = phase;
            FilesDone = 0; BytesDone = 0; FilesTotal = filesTotal; BytesTotal = bytesTotal;
            PhaseStartedUtc = DateTime.UtcNow;
        }
    }

    // =====================================================================
    //  Rows handed to the UI
    // =====================================================================
    public class ScanOptions
    {
        public bool ContentCheck;
        public bool HashAllSameSize;
        public bool IncludeQuick;
        public string[] IgnoreFiles = new string[0];
        public string[] IgnoreFolders = new string[0];
        public long MinGroupBytes = 1;
    }

    public class VolumeRow
    {
        public string Letter, Root, Label, FileSystem, Serial, Key, Display;
        public long TotalBytes, FreeBytes, DriveId;
        public bool IsSystem;
        public override string ToString() { return Display; }
    }

    public class DriveRow
    {
        public long Id, TotalBytes, FreeBytes, Priority, Folders, Files, Bytes, Hashed;
        public string Key, Serial, Label, FileSystem, Letter, LastScan, Added;
        public bool Connected, NeedsRescan;
    }

    public class GroupRow
    {
        public long Id, Copies, Files, Bytes, Reclaim, KeeperDriveId;
        public string Name, Keeper, Status, QSig, CSig;
        public bool Confirmed;
    }

    public class MemberRow
    {
        public long Id, GroupId, FolderId, DriveId, Files, Bytes;
        public string Role, Drive, Path, Oldest, Reason, FullPath;
        public bool Connected;
    }

    public class ScanRow
    {
        public long Id, Folders, Files, Bytes, Hashed, HashedBytes, Errors;
        public string Drive, Kind, Started, Finished, Status, Note;
    }

    public class BatchRow
    {
        public long Id, Items, Done, Failed, Deleted, Undone, Bytes;
        public string Created, Applied, Status, Note;
    }

    public class ActionRow
    {
        public long Id, BatchId, Seq, DriveId, Bytes, Files;
        public string Kind, Drive, Root, Src, Dst, Status, Done, Error, KeeperPath;
        public bool Confirmed, IsDir;
    }

    public class ContainedRow
    {
        public long Id, Files, Bytes, InFiles;
        public string Drive, Path, InDrive, InPath;
    }

    public class VerifyRunRow
    {
        public long Id, Ok, Missing, Different, Errors, Removed;
        public string Source, Target, Started, Finished, Status;
    }

    public class VerifyRow
    {
        public long Id, Size;
        public string Rel, Status, Note;
    }

    public class CheckRun
    {
        public long Id, Folders, Files, Bytes, HaveFiles, Probable, NewFiles, NewBytes, Unreadable, HaveFolders;
        public string Folder, Started, Finished, Status;
    }

    public class CheckRow
    {
        public long Files, Found, Bytes, NewBytes;
        public string Kind, Rel, Status, Matched;
    }

    public class WorkflowInfo
    {
        public long Drives, Scanned, ToCheckFiles, ToCheckBytes, Groups, Reclaim, QuickGroups, Batches, PlannedSteps, MovedDuplicates, MovedDuplicateBytes, DeletedDuplicates, VerifyRuns, Checks;
        public List<string> NotScanned = new List<string>(), NeedRescan = new List<string>(), ToCheck = new List<string>(), NotCleaned = new List<string>();
    }

    public class PlanSummary
    {
        public long BatchId;
        public int DupItems, CleanItems, Skipped, Offline, Unconfirmed;
        public long DupBytes;
        public string Script = "";
        public List<string> Notes = new List<string>();
        public string NotesText { get { return string.Join(Environment.NewLine, Notes.ToArray()); } }
    }

    // =====================================================================
    //  The catalog: one SQLite file with every drive, folder and file.
    // =====================================================================
    public partial class Catalog
    {
        public const string CleanName = "_Clean";
        public const string DupName = "_Duplicates";
        public const string OriginFile = "_origin.txt";
        static readonly string[] RootSkip = { "_Duplicates", "System Volume Information", "$RECYCLE.BIN", "RECYCLER", "$Recycle.Bin", "Config.Msi" };

        const string Schema = @"
CREATE TABLE IF NOT EXISTS meta(k TEXT PRIMARY KEY, v TEXT);
CREATE TABLE IF NOT EXISTS drives(id INTEGER PRIMARY KEY, dkey TEXT UNIQUE, serial TEXT, label TEXT, fs TEXT,
    total INTEGER NOT NULL DEFAULT 0, free INTEGER NOT NULL DEFAULT 0, priority INTEGER NOT NULL DEFAULT 100, letter TEXT,
    last_scan TEXT, needs_rescan INTEGER NOT NULL DEFAULT 0, folders INTEGER NOT NULL DEFAULT 0, files INTEGER NOT NULL DEFAULT 0,
    bytes INTEGER NOT NULL DEFAULT 0, hashed INTEGER NOT NULL DEFAULT 0, added TEXT);
CREATE TABLE IF NOT EXISTS folders(id INTEGER PRIMARY KEY, drive_id INTEGER NOT NULL, parent_id INTEGER NOT NULL DEFAULT 0,
    path TEXT NOT NULL, name TEXT, depth INTEGER NOT NULL DEFAULT 0, files INTEGER NOT NULL DEFAULT 0, bytes INTEGER NOT NULL DEFAULT 0,
    own_files INTEGER NOT NULL DEFAULT 0, oldest INTEGER NOT NULL DEFAULT 0, qsig TEXT, csig TEXT);
CREATE INDEX IF NOT EXISTS ix_folders_path ON folders(drive_id, path);
CREATE INDEX IF NOT EXISTS ix_folders_parent ON folders(parent_id);
CREATE INDEX IF NOT EXISTS ix_folders_qsig ON folders(qsig);
CREATE TABLE IF NOT EXISTS files(id INTEGER PRIMARY KEY, drive_id INTEGER NOT NULL, folder_id INTEGER NOT NULL, path TEXT NOT NULL,
    size INTEGER NOT NULL DEFAULT 0, mtime INTEGER NOT NULL DEFAULT 0, hash TEXT, err TEXT);
CREATE INDEX IF NOT EXISTS ix_files_path ON files(drive_id, path);
CREATE INDEX IF NOT EXISTS ix_files_folder ON files(folder_id);
CREATE INDEX IF NOT EXISTS ix_files_size ON files(size);
CREATE TABLE IF NOT EXISTS scans(id INTEGER PRIMARY KEY, drive_id INTEGER, kind TEXT, started TEXT, finished TEXT, status TEXT,
    folders INTEGER NOT NULL DEFAULT 0, files INTEGER NOT NULL DEFAULT 0, bytes INTEGER NOT NULL DEFAULT 0, hashed INTEGER NOT NULL DEFAULT 0,
    hashed_bytes INTEGER NOT NULL DEFAULT 0, errors INTEGER NOT NULL DEFAULT 0, note TEXT);
CREATE TABLE IF NOT EXISTS dgroups(id INTEGER PRIMARY KEY, gkey TEXT, qsig TEXT, csig TEXT, confirmed INTEGER NOT NULL DEFAULT 0,
    name TEXT, copies INTEGER NOT NULL DEFAULT 0, files INTEGER NOT NULL DEFAULT 0, bytes INTEGER NOT NULL DEFAULT 0,
    reclaim INTEGER NOT NULL DEFAULT 0, keeper_drive INTEGER NOT NULL DEFAULT 0, keeper_path TEXT);
CREATE TABLE IF NOT EXISTS dmembers(id INTEGER PRIMARY KEY, group_id INTEGER NOT NULL, folder_id INTEGER NOT NULL, drive_id INTEGER NOT NULL,
    path TEXT, oldest INTEGER NOT NULL DEFAULT 0, role TEXT, reason TEXT);
CREATE INDEX IF NOT EXISTS ix_dmembers_group ON dmembers(group_id);
CREATE TABLE IF NOT EXISTS keeper_pick(sig TEXT PRIMARY KEY, drive_id INTEGER NOT NULL, path TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS contained(id INTEGER PRIMARY KEY, drive_id INTEGER, path TEXT, files INTEGER NOT NULL DEFAULT 0,
    bytes INTEGER NOT NULL DEFAULT 0, in_drive INTEGER, in_path TEXT, in_files INTEGER NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS batches(id INTEGER PRIMARY KEY, created TEXT, applied TEXT, status TEXT, note TEXT, script TEXT);
CREATE TABLE IF NOT EXISTS actions(id INTEGER PRIMARY KEY, batch_id INTEGER NOT NULL, seq INTEGER NOT NULL, kind TEXT, drive_id INTEGER NOT NULL,
    root TEXT, src TEXT, dst TEXT, isdir INTEGER NOT NULL DEFAULT 1, qsig TEXT, csig TEXT, confirmed INTEGER NOT NULL DEFAULT 0,
    keeper_drive INTEGER NOT NULL DEFAULT 0, keeper_path TEXT, keeper_rel TEXT, dupn INTEGER NOT NULL DEFAULT 0,
    bytes INTEGER NOT NULL DEFAULT 0, files INTEGER NOT NULL DEFAULT 0, status TEXT, done TEXT, error TEXT);
CREATE INDEX IF NOT EXISTS ix_actions_batch ON actions(batch_id);
CREATE TABLE IF NOT EXISTS dupnum(keeper TEXT PRIMARY KEY, n INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS vruns(id INTEGER PRIMARY KEY, src TEXT, dst TEXT, started TEXT, finished TEXT, status TEXT,
    ok INTEGER NOT NULL DEFAULT 0, missing INTEGER NOT NULL DEFAULT 0, different INTEGER NOT NULL DEFAULT 0,
    errors INTEGER NOT NULL DEFAULT 0, removed INTEGER NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS vrows(id INTEGER PRIMARY KEY, run_id INTEGER NOT NULL, rel TEXT, size INTEGER NOT NULL DEFAULT 0, status TEXT, note TEXT);
CREATE INDEX IF NOT EXISTS ix_vrows_run ON vrows(run_id, status);
CREATE TABLE IF NOT EXISTS checks(id INTEGER PRIMARY KEY, folder TEXT, started TEXT, finished TEXT, status TEXT,
    folders INTEGER NOT NULL DEFAULT 0, files INTEGER NOT NULL DEFAULT 0, bytes INTEGER NOT NULL DEFAULT 0,
    have_files INTEGER NOT NULL DEFAULT 0, probable INTEGER NOT NULL DEFAULT 0, new_files INTEGER NOT NULL DEFAULT 0,
    new_bytes INTEGER NOT NULL DEFAULT 0, unreadable INTEGER NOT NULL DEFAULT 0, have_folders INTEGER NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS checkrows(id INTEGER PRIMARY KEY, check_id INTEGER NOT NULL, kind TEXT, rel TEXT, status TEXT,
    files INTEGER NOT NULL DEFAULT 0, found INTEGER NOT NULL DEFAULT 0, bytes INTEGER NOT NULL DEFAULT 0,
    new_bytes INTEGER NOT NULL DEFAULT 0, matched TEXT);
CREATE INDEX IF NOT EXISTS ix_checkrows ON checkrows(check_id, kind);
";

        public string DbPath { get; private set; }
        public string HashAlgorithm { get; private set; }
        public ScanOptions Options = new ScanOptions();
        readonly Db _db;
        Job _current;

        public Job CurrentJob { get { return _current; } }
        public bool Busy { get { return _current != null && !_current.Finished; } }

        public Catalog(string dbPath)
        {
            DbPath = dbPath;
            string dir = System.IO.Path.GetDirectoryName(dbPath);
            if (!System.IO.Directory.Exists(dir)) System.IO.Directory.CreateDirectory(dir);
            _db = Open();
            _db.Exec(Schema);
            string alg = _db.Scalar("SELECT v FROM meta WHERE k='hash'") as string;
            if (string.IsNullOrEmpty(alg))
            {
                alg = Hasher.Detect();
                _db.Run("INSERT OR REPLACE INTO meta(k,v) VALUES('hash',?)", alg);
            }
            HashAlgorithm = alg;
            Hasher.Algorithm = alg;
            // A task that was running when the app closed is not running any more.
            _db.Run("UPDATE scans SET status='interrupted' WHERE status='running'");
            _db.Run("UPDATE batches SET status='partial' WHERE status IN ('applying','undoing','deleting')");
            _db.Run("UPDATE vruns SET status='interrupted' WHERE status='running'");
            // Leftovers of a folder scan that was cut off: the catalog was never changed, just drop them.
            _db.Run("DELETE FROM folders WHERE drive_id<=?", -Staging);
            _db.Run("DELETE FROM files WHERE drive_id<=?", -Staging);
            _db.Run("UPDATE checks SET status='interrupted' WHERE status='running'");
            // Leftovers of a drive scan that was cut off: put the earlier catalog back.
            foreach (object[] r in _db.Rows("SELECT DISTINCT drive_id FROM folders WHERE drive_id<0 AND drive_id>?", -Staging))
            {
                long neg = Util.L(r[0]);
                _db.Begin();
                _db.Run("DELETE FROM folders WHERE drive_id=?", -neg);
                _db.Run("DELETE FROM files WHERE drive_id=?", -neg);
                _db.Run("UPDATE folders SET drive_id=? WHERE drive_id=?", -neg, neg);
                _db.Run("UPDATE files SET drive_id=? WHERE drive_id=?", -neg, neg);
                _db.Commit();
            }
        }

        // Closes the catalog file (the app keeps it open for the whole session).
        public void Close()
        {
            if (Busy) throw new InvalidOperationException("Wait for the running task to finish first.");
            _db.Dispose();
        }

        internal Db Open()
        {
            Db d = new Db(DbPath);
            d.Exec("PRAGMA encoding='UTF-8'; PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA temp_store=MEMORY; PRAGMA cache_size=-65536;");
            return d;
        }

        // ------------------------------------------------------------ tasks

        public delegate void Work(Job job, Db db);

        Job StartJob(string name, Work work)
        {
            if (Busy) throw new InvalidOperationException("Another task is still running (" + _current.Name + "). Stop it or wait for it to finish.");
            Job job = new Job();
            job.Name = name;
            _current = job;
            Thread t = new Thread(new ThreadStart(delegate()
            {
                Db db = null;
                try
                {
                    db = Open();
                    work(job, db);
                    if (job.CancelRequested) job.Cancelled = true;
                }
                catch (OperationCanceledException) { job.Cancelled = true; job.Log("Stopped. Work done so far is saved."); }
                catch (Exception ex) { job.Failed = true; job.Error = ex.Message; job.Log("ERROR: " + ex.Message); }
                finally
                {
                    if (db != null) { try { db.Rollback(); } catch { } db.Dispose(); }
                    job.Phase = job.Failed ? "Failed" : (job.Cancelled ? "Stopped" : "Done");
                    job.Current = "";
                    job.Finished = true;
                }
            }));
            t.IsBackground = true;
            t.Start();
            return job;
        }

        // ------------------------------------------------------------ drives

        internal static List<VolumeRow> ReadVolumes(Db db)
        {
            List<VolumeRow> list = new List<VolumeRow>();
            string sys = (Environment.GetEnvironmentVariable("SystemDrive") ?? "C:").TrimEnd('\\').ToUpperInvariant();
            foreach (string root in Environment.GetLogicalDrives())
            {
                uint type = NativeFs.GetDriveTypeW(root);
                if (type != 2 && type != 3) continue;
                StringBuilder vol = new StringBuilder(261), fs = new StringBuilder(261);
                uint serial, maxc, flags;
                if (!NativeFs.GetVolumeInformationW(root, vol, vol.Capacity, out serial, out maxc, out flags, fs, fs.Capacity)) continue;
                ulong free, total, tfree;
                if (!NativeFs.GetDiskFreeSpaceExW(root, out free, out total, out tfree)) { free = 0; total = 0; }
                VolumeRow v = new VolumeRow();
                v.Root = root.Substring(0, 2).ToUpperInvariant() + "\\";
                v.Letter = root.Substring(0, 2).ToUpperInvariant();
                v.Label = vol.ToString();
                v.FileSystem = fs.ToString();
                v.Serial = serial.ToString("X8");
                v.TotalBytes = (long)total;
                v.FreeBytes = (long)free;
                v.Key = v.Serial + ":" + v.TotalBytes;
                v.IsSystem = v.Letter == sys;
                v.DriveId = db == null ? 0 : db.ScalarLong("SELECT id FROM drives WHERE dkey=?", v.Key);
                v.Display = v.Letter + "  " + (v.Label.Length > 0 ? v.Label : "(no label)") + "  -  " + v.FileSystem + ", " + Util.Size(v.TotalBytes) +
                            " (" + Util.Size(v.FreeBytes) + " free)" + (v.IsSystem ? "  [Windows drive]" : "") + (v.DriveId > 0 ? "" : "  [new]");
                list.Add(v);
            }
            return list;
        }

        public List<VolumeRow> GetVolumes() { return ReadVolumes(_db); }

        internal static Dictionary<long, string> ConnectedRoots(Db db)
        {
            Dictionary<long, string> map = new Dictionary<long, string>();
            foreach (VolumeRow v in ReadVolumes(db)) if (v.DriveId > 0 && !v.IsSystem) map[v.DriveId] = v.Root;
            return map;
        }

        internal static long RegisterDrive(Db db, VolumeRow v)
        {
            if (v.IsSystem) throw new InvalidOperationException("The Windows drive (" + v.Letter + ") is not managed by this tool.");
            long id = db.ScalarLong("SELECT id FROM drives WHERE dkey=?", v.Key);
            if (id > 0)
            {
                db.Run("UPDATE drives SET label=?, fs=?, total=?, free=?, letter=? WHERE id=?", v.Label, v.FileSystem, v.TotalBytes, v.FreeBytes, v.Letter, id);
                return id;
            }
            long prio = db.ScalarLong("SELECT ifnull(max(priority),0) FROM drives") + 1;
            if (prio > 99) prio = 99;
            db.Run("INSERT INTO drives(dkey, serial, label, fs, total, free, priority, letter, added) VALUES(?,?,?,?,?,?,?,?,?)",
                v.Key, v.Serial, v.Label, v.FileSystem, v.TotalBytes, v.FreeBytes, prio, v.Letter, Util.Now());
            return db.LastId;
        }

        public long Register(string root)
        {
            foreach (VolumeRow v in ReadVolumes(_db))
                if (string.Equals(v.Root, root, StringComparison.OrdinalIgnoreCase)) return RegisterDrive(_db, v);
            throw new InvalidOperationException("Drive " + root + " is not connected.");
        }

        public List<DriveRow> GetDrives()
        {
            Dictionary<long, string> roots = ConnectedRoots(_db);
            List<DriveRow> list = new List<DriveRow>();
            foreach (object[] r in _db.Rows("SELECT id, dkey, serial, label, fs, total, free, priority, letter, last_scan, needs_rescan, folders, files, bytes, hashed, added FROM drives ORDER BY priority, id"))
            {
                DriveRow d = new DriveRow();
                d.Id = Util.L(r[0]); d.Key = Util.S(r[1]); d.Serial = Util.S(r[2]); d.Label = Util.S(r[3]); d.FileSystem = Util.S(r[4]);
                d.TotalBytes = Util.L(r[5]); d.FreeBytes = Util.L(r[6]); d.Priority = Util.L(r[7]); d.LastScan = Util.S(r[9]);
                d.NeedsRescan = Util.L(r[10]) != 0; d.Folders = Util.L(r[11]); d.Files = Util.L(r[12]); d.Bytes = Util.L(r[13]);
                d.Hashed = Util.L(r[14]); d.Added = Util.S(r[15]);
                string root;
                d.Connected = roots.TryGetValue(d.Id, out root);
                d.Letter = d.Connected ? root.Substring(0, 2) : Util.S(r[8]);
                list.Add(d);
            }
            return list;
        }

        public void SetPriority(long driveId, long priority) { _db.Run("UPDATE drives SET priority=? WHERE id=?", priority, driveId); }

        public void ForgetDrive(long driveId)
        {
            if (Busy) throw new InvalidOperationException("Wait for the running task to finish first.");
            _db.Begin();
            _db.Run("DELETE FROM files WHERE drive_id=? OR drive_id=?", driveId, -driveId);
            _db.Run("DELETE FROM folders WHERE drive_id=? OR drive_id=?", driveId, -driveId);
            _db.Run("DELETE FROM drives WHERE id=?", driveId);
            _db.Run("DELETE FROM dmembers WHERE drive_id=?", driveId);
            _db.Run("DELETE FROM keeper_pick WHERE drive_id=?", driveId);
            _db.Commit();
        }

        string DriveName(Db db, long id)
        {
            object[] r = null;
            foreach (object[] x in db.Rows("SELECT label, letter FROM drives WHERE id=?", id)) r = x;
            if (r == null) return "drive " + id;
            string label = Util.S(r[0]);
            return (label.Length > 0 ? label : "(no label)") + " [" + Util.S(r[1]) + "]";
        }

        // ------------------------------------------------------------ scan

        sealed class PendingDir
        {
            public string Rel; public long Parent; public int Depth;
            public PendingDir(string rel, long parent, int depth) { Rel = rel; Parent = parent; Depth = depth; }
        }

        public Job StartScan(string root, ScanOptions o)
        {
            if (o == null) o = Options;
            Options = o;
            return StartJob("Scan " + root, delegate(Job j, Db db)
            {
                DoScan(j, db, root, o);
                if (o.ContentCheck) DoContentCheck(j, db, o);
                DoAnalyze(j, db, o);
            });
        }

        public Job StartContentCheck(ScanOptions o)
        {
            if (o == null) o = Options;
            Options = o;
            return StartJob("Content check", delegate(Job j, Db db)
            {
                DoContentCheck(j, db, o);
                DoAnalyze(j, db, o);
            });
        }

        void DoScan(Job j, Db db, string root, ScanOptions o)
        {
            VolumeRow v = null;
            foreach (VolumeRow x in ReadVolumes(db)) if (string.Equals(x.Root, root, StringComparison.OrdinalIgnoreCase)) v = x;
            if (v == null) throw new InvalidOperationException("Drive " + root + " is not connected.");
            long d = RegisterDrive(db, v);
            j.NewPhase("Quick scan: reading folders", 0, 0);
            j.Log("Quick scan of " + v.Letter + " " + v.Label + " (" + v.FileSystem + ", " + Util.Size(v.TotalBytes) + ") started.");
            db.Run("INSERT INTO scans(drive_id, kind, started, status) VALUES(?,?,?,?)", d, "Quick scan", Util.Now(), "running");
            long scanId = db.LastId;

            // Park the earlier catalog of this drive; it comes back if the scan stops.
            db.Begin();
            db.Run("DELETE FROM folders WHERE drive_id=?", -d);
            db.Run("DELETE FROM files WHERE drive_id=?", -d);
            db.Run("UPDATE folders SET drive_id=? WHERE drive_id=?", -d, d);
            db.Run("UPDATE files SET drive_id=? WHERE drive_id=?", -d, d);
            db.Commit();

            bool ok = false;
            try
            {
                Enumerate(j, db, d, v.Root, "", 0, 0, o);
                ok = true;
            }
            finally
            {
                if (!ok)
                {
                    db.Rollback();
                    db.Begin();
                    db.Run("DELETE FROM folders WHERE drive_id=?", d);
                    db.Run("DELETE FROM files WHERE drive_id=?", d);
                    db.Run("UPDATE folders SET drive_id=? WHERE drive_id=?", d, -d);
                    db.Run("UPDATE files SET drive_id=? WHERE drive_id=?", d, -d);
                    db.Run("UPDATE scans SET finished=?, status=?, folders=?, files=?, errors=? WHERE id=?", Util.Now(),
                        j.CancelRequested ? "stopped" : "failed", j.Folders, j.FilesDone, j.Errors, scanId);
                    db.Commit();
                    j.Log("The earlier catalog of this drive was kept.");
                }
            }

            j.NewPhase("Quick scan: keeping earlier hashes", 0, 0);
            db.Begin();
            db.Run("UPDATE files SET hash=(SELECT o.hash FROM files o WHERE o.drive_id=? AND o.path=files.path AND o.size=files.size AND o.mtime=files.mtime AND o.hash IS NOT NULL LIMIT 1) WHERE drive_id=?", -d, d);
            db.Run("DELETE FROM files WHERE drive_id=?", -d);
            db.Run("DELETE FROM folders WHERE drive_id=?", -d);
            db.Run("UPDATE files SET hash=? WHERE drive_id=? AND size=0", Hasher.Empty(), d);
            db.Commit();

            j.NewPhase("Quick scan: building folder fingerprints", 0, 0);
            Recompute(db, d);
            long files = db.ScalarLong("SELECT files FROM drives WHERE id=?", d);
            long bytes = db.ScalarLong("SELECT bytes FROM drives WHERE id=?", d);
            long hashed = db.ScalarLong("SELECT hashed FROM drives WHERE id=?", d);
            db.Run("UPDATE drives SET last_scan=?, needs_rescan=0 WHERE id=?", Util.Now(), d);
            db.Run("UPDATE scans SET finished=?, status='done', folders=?, files=?, bytes=?, hashed=?, errors=? WHERE id=?",
                Util.Now(), j.Folders, files, bytes, hashed, j.Errors, scanId);
            j.Log("Quick scan done: " + j.Folders.ToString("N0") + " folders, " + files.ToString("N0") + " files, " + Util.Size(bytes) +
                  (hashed > 0 ? " (" + hashed.ToString("N0") + " files already have a content hash)" : "") +
                  (j.Errors > 0 ? ", " + j.Errors + " folders could not be read" : "") + ".");
            j.Summary = "Scanned " + v.Letter + " " + v.Label + ": " + files.ToString("N0") + " files, " + Util.Size(bytes) + ".";
        }

        // Lists everything under rootPath\startRel into the catalog as drive d (a staging id for folder scans).
        void Enumerate(Job j, Db db, long d, string rootPath, string startRel, long startParent, int startDepth, ScanOptions o)
        {
            string[] ignF = Wild.Prepare(o.IgnoreFiles), ignD = Wild.Prepare(o.IgnoreFolders);
            using (Stmt insDir = db.Prepare("INSERT INTO folders(drive_id, parent_id, path, name, depth) VALUES(?,?,?,?,?)"))
            using (Stmt insFile = db.Prepare("INSERT INTO files(drive_id, folder_id, path, size, mtime) VALUES(?,?,?,?,?)"))
            {
                db.Begin();
                int pending = 0;
                List<PendingDir> stack = new List<PendingDir>();
                stack.Add(new PendingDir(startRel, startParent, startDepth));
                while (stack.Count > 0)
                {
                    j.Check();
                    PendingDir pd = stack[stack.Count - 1];
                    stack.RemoveAt(stack.Count - 1);
                    string full = pd.Rel.Length == 0 ? rootPath : Fs.Join(rootPath, pd.Rel);
                    insDir.Exec(d, pd.Parent, pd.Rel, pd.Rel.Length == 0 ? rootPath : Fs.LastPart(pd.Rel), pd.Depth);
                    long fid = db.LastId;
                    j.Folders++;
                    j.Current = full;
                    int err;
                    List<FsEntry> entries = Fs.ListDir(full, out err);
                    if (err != 0) { j.Errors++; j.Log("Cannot read " + full + ": " + Fs.ErrText(err)); }
                    foreach (FsEntry e in entries)
                    {
                        string lname = e.Name.ToLowerInvariant();
                        if (e.IsDir)
                        {
                            if (e.IsReparse) continue;
                            if (pd.Depth == 0 && IsRootSkip(e.Name)) continue;
                            if (Wild.Any(lname, ignD)) continue;
                            stack.Add(new PendingDir(Fs.Join(pd.Rel, e.Name), fid, pd.Depth + 1));
                        }
                        else
                        {
                            if ((e.Attributes & (Fs.Reparse | Fs.Offline | Fs.RecallOnOpen | Fs.RecallOnData)) != 0) continue;
                            if (Wild.Any(lname, ignF)) continue;
                            insFile.Exec(d, fid, Fs.Join(pd.Rel, e.Name), e.Size, e.Written);
                            j.FilesDone++;
                            j.BytesDone += e.Size;
                            pending++;
                        }
                    }
                    pending++;
                    if (pending >= 20000) { db.Commit(); db.Begin(); pending = 0; }
                }
                db.Commit();
            }
        }

        // ------------------------------------------------------------ folder scan (one folder of a drive)

        const long Staging = 1000000000L;

        internal static void ResolveFolder(Db db, string folder, out VolumeRow v, out string rel)
        {
            string full = (folder ?? "").Trim();
            if (full.Length == 2 && full[1] == ':') full += "\\";
            v = null;
            foreach (VolumeRow x in ReadVolumes(db)) if (full.StartsWith(x.Root, StringComparison.OrdinalIgnoreCase)) v = x;
            if (v == null) throw new InvalidOperationException("That folder is not on a connected local drive: " + folder);
            rel = full.Substring(v.Root.Length).TrimEnd('\\');
        }

        static long EnsureRoot(Db db, long d, string rootPath)
        {
            long id = db.ScalarLong("SELECT id FROM folders WHERE drive_id=? AND path=''", d);
            if (id > 0) return id;
            db.Run("INSERT INTO folders(drive_id, parent_id, path, name, depth) VALUES(?,0,'',?,0)", d, rootPath);
            return db.LastId;
        }

        public Job StartScanFolder(string folder, ScanOptions o)
        {
            if (o == null) o = Options;
            Options = o;
            return StartJob("Scan " + folder, delegate(Job j, Db db)
            {
                DoScanFolder(j, db, folder, o);
                if (o.ContentCheck) DoContentCheck(j, db, o);
                DoAnalyze(j, db, o);
            });
        }

        void DoScanFolder(Job j, Db db, string folder, ScanOptions o)
        {
            VolumeRow v;
            string rel;
            ResolveFolder(db, folder, out v, out rel);
            if (rel.Length == 0) { DoScan(j, db, v.Root, o); return; }
            if (v.IsSystem) throw new InvalidOperationException("The Windows drive (" + v.Letter + ") is not managed by this tool. Use Check only for a folder there.");
            if (string.Equals(rel, DupName, StringComparison.OrdinalIgnoreCase) || Under(rel, DupName)) throw new InvalidOperationException("_Duplicates is never scanned.");
            string full = Fs.Join(v.Root, rel);
            if (!Fs.IsDir(full)) throw new InvalidOperationException("Not found: " + full);
            long d = RegisterDrive(db, v);
            long stage = -(d + Staging);
            j.NewPhase("Folder scan: reading folders", 0, 0);
            j.Log("Folder scan of " + full + " started (the rest of " + v.Letter + " in the catalog is kept).");
            db.Run("INSERT INTO scans(drive_id, kind, started, status, note) VALUES(?,?,?,?,?)", d, "Folder scan", Util.Now(), "running", rel);
            long scanId = db.LastId;
            db.Run("DELETE FROM folders WHERE drive_id=?", stage);
            db.Run("DELETE FROM files WHERE drive_id=?", stage);
            db.Begin();
            EnsureRoot(db, d, v.Root);
            string parentRel = rel.IndexOf('\\') < 0 ? "" : rel.Substring(0, rel.LastIndexOf('\\'));
            long parentId = FolderRow(db, d, parentRel);
            db.Commit();
            bool ok = false;
            try
            {
                Enumerate(j, db, stage, v.Root, rel, parentId, rel.Split('\\').Length, o);
                ok = true;
            }
            finally
            {
                if (!ok)
                {
                    db.Rollback();
                    db.Run("DELETE FROM folders WHERE drive_id=?", stage);
                    db.Run("DELETE FROM files WHERE drive_id=?", stage);
                    db.Run("UPDATE scans SET finished=?, status=?, folders=?, files=? WHERE id=?", Util.Now(), j.CancelRequested ? "stopped" : "failed", j.Folders, j.FilesDone, scanId);
                    j.Log("The catalog was not changed.");
                }
            }
            j.NewPhase("Folder scan: updating the catalog", 0, 0);
            db.Begin();
            db.Run("UPDATE files SET hash=(SELECT o.hash FROM files o WHERE o.drive_id=? AND o.path=files.path AND o.size=files.size AND o.mtime=files.mtime AND o.hash IS NOT NULL LIMIT 1) WHERE drive_id=?", d, stage);
            DeleteSubtree(db, d, rel);
            db.Run("UPDATE folders SET drive_id=? WHERE drive_id=?", d, stage);
            db.Run("UPDATE files SET drive_id=? WHERE drive_id=?", d, stage);
            db.Run("UPDATE files SET hash=? WHERE drive_id=? AND size=0 AND hash IS NULL", Hasher.Empty(), d);
            db.Commit();
            j.NewPhase("Folder scan: building folder fingerprints", 0, 0);
            Recompute(db, d);
            long files = j.FilesDone, bytes = j.BytesDone;
            db.Run("UPDATE scans SET finished=?, status='done', folders=?, files=?, bytes=?, errors=? WHERE id=?", Util.Now(), j.Folders, files, bytes, j.Errors, scanId);
            j.Summary = "Scanned " + full + ": " + files.ToString("N0") + " files, " + Util.Size(bytes) + ".";
            j.Log(j.Summary);
        }

        static bool IsRootSkip(string name)
        {
            foreach (string s in RootSkip) if (string.Equals(s, name, StringComparison.OrdinalIgnoreCase)) return true;
            return false;
        }

        // ------------------------------------------------------------ fingerprints (from the catalog, no disk access)

        sealed class FNode
        {
            public long Id, Parent, Files, Bytes, OwnFiles, OwnBytes, Oldest;
            public int Depth;
            public List<int> Kids = new List<int>();
            public List<long> Sizes = new List<long>();
            public List<string> Hashes = new List<string>();
            public bool OwnHashed = true;
            public string Q, C;
        }

        internal void Recompute(Db db, long d)
        {
            List<FNode> nodes = new List<FNode>();
            Dictionary<long, int> index = new Dictionary<long, int>();
            using (Stmt s = db.Prepare("SELECT id, parent_id FROM folders WHERE drive_id=?"))
            {
                s.Bind(d);
                while (s.Step()) { FNode n = new FNode(); n.Id = s.Long(0); n.Parent = s.Long(1); index[n.Id] = nodes.Count; nodes.Add(n); }
            }
            using (Stmt s = db.Prepare("SELECT folder_id, size, mtime, hash FROM files WHERE drive_id=?"))
            {
                s.Bind(d);
                while (s.Step())
                {
                    int i;
                    if (!index.TryGetValue(s.Long(0), out i)) continue;
                    FNode n = nodes[i];
                    long size = s.Long(1), mt = s.Long(2);
                    n.Sizes.Add(size);
                    n.OwnFiles++;
                    n.OwnBytes += size;
                    if (s.IsNull(3)) n.OwnHashed = false; else n.Hashes.Add(s.Text(3) + ":" + size);
                    if (mt > 0 && (n.Oldest == 0 || mt < n.Oldest)) n.Oldest = mt;
                }
            }
            List<int> order = new List<int>(nodes.Count);
            for (int i = 0; i < nodes.Count; i++)
            {
                int p;
                if (nodes[i].Parent != 0 && index.TryGetValue(nodes[i].Parent, out p) && p != i) nodes[p].Kids.Add(i);
                else order.Add(i);
            }
            for (int k = 0; k < order.Count; k++)
            {
                FNode n = nodes[order[k]];
                foreach (int c in n.Kids) { nodes[c].Depth = n.Depth + 1; order.Add(c); }
            }
            long totalFiles = 0, totalBytes = 0;
            for (int k = order.Count - 1; k >= 0; k--)
            {
                FNode n = nodes[order[k]];
                n.Files = n.OwnFiles;
                n.Bytes = n.OwnBytes;
                List<string> kq = new List<string>(), kc = new List<string>();
                bool all = n.OwnHashed;
                foreach (int c in n.Kids)
                {
                    FNode m = nodes[c];
                    n.Files += m.Files;
                    n.Bytes += m.Bytes;
                    if (m.Oldest > 0 && (n.Oldest == 0 || m.Oldest < n.Oldest)) n.Oldest = m.Oldest;
                    if (m.Files == 0) continue;
                    kq.Add(m.Q);
                    if (m.C == null) all = false; else kc.Add(m.C);
                }
                if (n.Files > 0)
                {
                    n.Q = Hasher.QuickSig(n.Sizes, kq);
                    n.C = all ? Hasher.ContentSig(n.Hashes, kc) : null;
                }
                n.Sizes = null;
                n.Hashes = null;
                if (n.Depth == 0) { totalFiles += n.Files; totalBytes += n.Bytes; }
            }
            db.Begin();
            using (Stmt u = db.Prepare("UPDATE folders SET depth=?, files=?, bytes=?, own_files=?, oldest=?, qsig=?, csig=? WHERE id=?"))
            {
                foreach (int k in order)
                {
                    FNode n = nodes[k];
                    u.Exec(n.Depth, n.Files, n.Bytes, n.OwnFiles, n.Oldest, n.Q, n.C, n.Id);
                }
            }
            long hashed = db.ScalarLong("SELECT count(*) FROM files WHERE drive_id=? AND hash IS NOT NULL", d);
            db.Run("UPDATE drives SET folders=?, files=?, bytes=?, hashed=? WHERE id=?", nodes.Count, totalFiles, totalBytes, hashed, d);
            db.Commit();
        }

        // ------------------------------------------------------------ content check (hashing)

        sealed class HashItem
        {
            public long Id, Drive, Size; public string Full;
            public HashItem(long id, long drive, string full, long size) { Id = id; Drive = drive; Full = full; Size = size; }
        }

        void DoContentCheck(Job j, Db db, ScanOptions o)
        {
            j.NewPhase("Content check: finding files to check", 0, 0);
            db.Run("UPDATE files SET hash=? WHERE drive_id>0 AND size=0 AND hash IS NULL", Hasher.Empty());
            Dictionary<long, string> roots = ConnectedRoots(db);
            Dictionary<long, bool> stale = new Dictionary<long, bool>();
            foreach (object[] r in db.Rows("SELECT id FROM drives WHERE needs_rescan<>0")) stale[Util.L(r[0])] = true;

            // Folders whose quick fingerprint matches another folder's.
            Dictionary<string, bool> shared = new Dictionary<string, bool>();
            foreach (object[] r in db.Rows("SELECT qsig FROM folders WHERE drive_id>0 AND depth>0 AND files>0 AND qsig IS NOT NULL GROUP BY qsig HAVING count(*)>1"))
                shared[Util.S(r[0])] = true;
            List<object[]> cand = new List<object[]>();
            Dictionary<long, bool> isShared = new Dictionary<long, bool>();
            using (Stmt s = db.Prepare("SELECT id, parent_id, drive_id, path, qsig FROM folders WHERE drive_id>0 AND depth>0 AND files>0 AND qsig IS NOT NULL"))
            {
                s.Bind();
                while (s.Step())
                {
                    if (!shared.ContainsKey(s.Text(4))) continue;
                    cand.Add(new object[] { s.Long(0), s.Long(1), s.Long(2), s.Text(3) });
                    isShared[s.Long(0)] = true;
                }
            }
            List<HashItem> todo = new List<HashItem>();
            Dictionary<long, bool> seen = new Dictionary<long, bool>();
            Dictionary<long, bool> offline = new Dictionary<long, bool>();
            using (Stmt s = db.Prepare("SELECT id, path, size FROM files WHERE drive_id=? AND hash IS NULL AND path>? AND path<?"))
            {
                foreach (object[] c in cand)
                {
                    if (isShared.ContainsKey((long)c[1])) continue;   // its parent is checked as a whole
                    long dr = (long)c[2];
                    if (stale.ContainsKey(dr)) continue;
                    string root;
                    if (!roots.TryGetValue(dr, out root)) { offline[dr] = true; continue; }
                    string p = (string)c[3];
                    s.Bind(dr, p + "\\", p + "]");
                    while (s.Step())
                    {
                        long id = s.Long(0);
                        if (seen.ContainsKey(id)) continue;
                        seen[id] = true;
                        todo.Add(new HashItem(id, dr, Fs.Join(root, s.Text(1)), s.Long(2)));
                    }
                }
            }
            if (o.HashAllSameSize)
            {
                using (Stmt s = db.Prepare("SELECT id, drive_id, path, size FROM files WHERE drive_id>0 AND hash IS NULL AND size>0 AND size IN (SELECT size FROM files WHERE drive_id>0 AND size>0 GROUP BY size HAVING count(*)>1)"))
                {
                    s.Bind();
                    while (s.Step())
                    {
                        long id = s.Long(0), dr = s.Long(1);
                        if (seen.ContainsKey(id) || stale.ContainsKey(dr)) continue;
                        string root;
                        if (!roots.TryGetValue(dr, out root)) { offline[dr] = true; continue; }
                        seen[id] = true;
                        todo.Add(new HashItem(id, dr, Fs.Join(root, s.Text(2)), s.Long(3)));
                    }
                }
            }
            foreach (long dr in offline.Keys) j.Log("Not connected, checked later: " + DriveName(db, dr) + ".");
            todo.Sort(delegate(HashItem a, HashItem b)
            {
                int c = a.Drive.CompareTo(b.Drive);
                return c != 0 ? c : string.CompareOrdinal(a.Full, b.Full);
            });
            long total = 0;
            foreach (HashItem h in todo) total += h.Size;
            j.Log("Content check: " + todo.Count.ToString("N0") + " files, " + Util.Size(total) + " to read.");
            j.NewPhase("Content check: reading files", todo.Count, total);

            Dictionary<long, bool> touched = new Dictionary<long, bool>();
            long hashedBytes = 0, hashedFiles = 0, errors = 0;
            bool stopped = false;
            DateTime lastCommit = DateTime.UtcNow;
            db.Run("INSERT INTO scans(drive_id, kind, started, status) VALUES(0, 'Content check', ?, 'running')", Util.Now());
            long scanId = db.LastId;
            db.Begin();
            using (Stmt up = db.Prepare("UPDATE files SET hash=?, err=NULL WHERE id=?"))
            using (Stmt ue = db.Prepare("UPDATE files SET err=? WHERE id=?"))
            {
                try
                {
                    foreach (HashItem h in todo)
                    {
                        j.Check();
                        j.Current = h.Full;
                        try
                        {
                            string hx = Hasher.OfFile(h.Full, j);
                            up.Exec(hx, h.Id);
                            hashedFiles++;
                            hashedBytes += h.Size;
                        }
                        catch (OperationCanceledException) { throw; }
                        catch (Exception ex)
                        {
                            errors++;
                            j.Errors++;
                            ue.Exec(ex.Message, h.Id);
                            j.Log("Cannot read " + h.Full + ": " + ex.Message);
                        }
                        touched[h.Drive] = true;
                        j.FilesDone++;
                        if ((DateTime.UtcNow - lastCommit).TotalSeconds > 3) { db.Commit(); db.Begin(); lastCommit = DateTime.UtcNow; }
                    }
                }
                catch (OperationCanceledException) { stopped = true; }
            }
            db.Commit();
            j.NewPhase("Content check: building content fingerprints", 0, 0);
            foreach (long dr in touched.Keys) Recompute(db, dr);
            db.Run("UPDATE scans SET finished=?, status=?, hashed=?, hashed_bytes=?, errors=? WHERE id=?",
                Util.Now(), stopped ? "stopped" : "done", hashedFiles, hashedBytes, errors, scanId);
            j.Log("Content check " + (stopped ? "stopped" : "done") + ": " + hashedFiles.ToString("N0") + " files (" + Util.Size(hashedBytes) + ") read" +
                  (errors > 0 ? ", " + errors + " could not be read" : "") + ".");
            if (stopped) throw new OperationCanceledException();
        }

        // ------------------------------------------------------------ duplicate folders

        sealed class ANode
        {
            public long Id, Parent, Drive, Files, Bytes, Oldest, Prio;
            public string Path, Name, Q, C;
            public int Depth, ParentIdx = -1, Role;   // Role: 0 none, 1 keep, 2 duplicate
            public bool HoldsKeeper;
        }

        sealed class GroupWork
        {
            public string Key; public List<int> Members = new List<int>(); public long Bytes; public int MinDepth = int.MaxValue;
        }

        public Job StartAnalyze(ScanOptions o)
        {
            if (o == null) o = Options;
            Options = o;
            return StartJob("Find duplicates", delegate(Job j, Db db) { DoAnalyze(j, db, o); });
        }

        static bool UnderRole(List<ANode> nodes, int i, int role)
        {
            for (int p = nodes[i].ParentIdx; p >= 0; p = nodes[p].ParentIdx) if (nodes[p].Role == role) return true;
            return false;
        }

        void DoAnalyze(Job j, Db db, ScanOptions o)
        {
            j.NewPhase("Finding duplicate folders", 0, 0);
            Dictionary<long, long> prio = new Dictionary<long, long>();
            Dictionary<long, bool> stale = new Dictionary<long, bool>();
            foreach (object[] r in db.Rows("SELECT id, priority, needs_rescan FROM drives"))
            {
                prio[Util.L(r[0])] = Util.L(r[1]);
                if (Util.L(r[2]) != 0) stale[Util.L(r[0])] = true;
            }
            List<ANode> nodes = new List<ANode>();
            Dictionary<long, int> index = new Dictionary<long, int>();
            using (Stmt s = db.Prepare("SELECT id, parent_id, drive_id, path, name, depth, files, bytes, oldest, qsig, csig FROM folders WHERE drive_id>0 AND files>0"))
            {
                s.Bind();
                while (s.Step())
                {
                    long drive = s.Long(2);
                    if (stale.ContainsKey(drive)) continue;
                    ANode n = new ANode();
                    n.Id = s.Long(0); n.Parent = s.Long(1); n.Drive = drive; n.Path = s.Text(3); n.Name = s.Text(4);
                    n.Depth = (int)s.Long(5); n.Files = s.Long(6); n.Bytes = s.Long(7); n.Oldest = s.Long(8);
                    n.Q = s.IsNull(9) ? null : s.Text(9); n.C = s.IsNull(10) ? null : s.Text(10);
                    long pr; n.Prio = prio.TryGetValue(drive, out pr) ? pr : 100;
                    index[n.Id] = nodes.Count;
                    nodes.Add(n);
                }
            }
            foreach (ANode n in nodes) { int p; if (n.Parent != 0 && index.TryGetValue(n.Parent, out p)) n.ParentIdx = p; }

            Dictionary<string, GroupWork> byKey = new Dictionary<string, GroupWork>();
            for (int i = 0; i < nodes.Count; i++)
            {
                ANode n = nodes[i];
                if (n.Depth == 0 || n.Bytes < Math.Max(1, o.MinGroupBytes)) continue;
                if (string.Equals(n.Path, CleanName, StringComparison.OrdinalIgnoreCase)) continue;
                string key = o.IncludeQuick ? n.Q : n.C;
                if (key == null) continue;
                GroupWork g;
                if (!byKey.TryGetValue(key, out g)) { g = new GroupWork(); g.Key = key; byKey[key] = g; }
                g.Members.Add(i);
                g.Bytes = n.Bytes;
                if (n.Depth < g.MinDepth) g.MinDepth = n.Depth;
            }
            List<GroupWork> groups = new List<GroupWork>();
            foreach (GroupWork g in byKey.Values) if (g.Members.Count > 1) groups.Add(g);
            groups.Sort(delegate(GroupWork a, GroupWork b)
            {
                int c = b.Bytes.CompareTo(a.Bytes);
                return c != 0 ? c : a.MinDepth.CompareTo(b.MinDepth);
            });

            Dictionary<string, object[]> picks = new Dictionary<string, object[]>();
            foreach (object[] r in db.Rows("SELECT sig, drive_id, path FROM keeper_pick")) picks[Util.S(r[0])] = r;

            int groupCount = 0, dupCount = 0, quickOnly = 0;
            long reclaim = 0;
            db.Begin();
            db.Exec("DELETE FROM dmembers; DELETE FROM dgroups;");
            using (Stmt insG = db.Prepare("INSERT INTO dgroups(gkey, qsig, csig, confirmed, name, copies, files, bytes, reclaim, keeper_drive, keeper_path) VALUES(?,?,?,?,?,?,?,?,?,?,?)"))
            using (Stmt insM = db.Prepare("INSERT INTO dmembers(group_id, folder_id, drive_id, path, oldest, role, reason) VALUES(?,?,?,?,?,?,?)"))
            {
                foreach (GroupWork g in groups)
                {
                    List<int> live = new List<int>();
                    foreach (int m in g.Members)
                    {
                        if (nodes[m].Role != 0) continue;
                        if (UnderRole(nodes, m, 2)) continue;   // moves with a parent that is a duplicate
                        live.Add(m);
                    }
                    if (live.Count < 2) continue;

                    ANode first = nodes[live[0]];
                    bool confirmed = true;
                    foreach (int m in live) if (nodes[m].C == null || nodes[m].C != first.C) confirmed = false;

                    // The keeper: your pick; else a copy already in _Clean (or inside a keeper);
                    // else the copy with the oldest files; then drive priority; then the shortest path.
                    int keeper = -1;
                    string reason = "";
                    object[] pick = null;
                    if ((first.C != null && picks.TryGetValue(first.C, out pick)) || picks.TryGetValue(first.Q ?? "", out pick))
                    {
                        foreach (int m in live)
                            if (nodes[m].Drive == Util.L(pick[1]) && string.Equals(nodes[m].Path, Util.S(pick[2]), StringComparison.OrdinalIgnoreCase)) { keeper = m; reason = "Your pick"; }
                    }
                    if (keeper < 0)
                    {
                        foreach (int m in live)
                        {
                            if (keeper < 0) { keeper = m; continue; }
                            if (Better(nodes, m, keeper)) keeper = m;
                        }
                        ANode k = nodes[keeper];
                        if (Util.InClean(k.Path)) reason = "Already in _Clean";
                        else if (UnderRole(nodes, keeper, 1)) reason = "Inside a kept folder";
                        else reason = "Oldest files" + (k.Oldest > 0 ? " (" + Util.Date(k.Oldest) + ")" : "") + ", drive priority " + k.Prio;
                    }
                    List<int> dups = new List<int>();
                    List<int> held = new List<int>();
                    foreach (int m in live)
                    {
                        if (m == keeper) continue;
                        if (nodes[m].HoldsKeeper) held.Add(m); else dups.Add(m);
                    }
                    if (dups.Count == 0) continue;

                    nodes[keeper].Role = 1;
                    for (int p = keeper; p >= 0; p = nodes[p].ParentIdx) nodes[p].HoldsKeeper = true;
                    foreach (int m in dups) nodes[m].Role = 2;

                    ANode kn = nodes[keeper];
                    long rec = kn.Bytes * dups.Count;
                    insG.Exec(g.Key, kn.Q, kn.C, confirmed ? 1 : 0, kn.Name, live.Count, kn.Files, kn.Bytes, rec, kn.Drive, kn.Path);
                    long gid = db.LastId;
                    insM.Exec(gid, kn.Id, kn.Drive, kn.Path, kn.Oldest, "Keep", reason);
                    foreach (int m in dups) insM.Exec(gid, nodes[m].Id, nodes[m].Drive, nodes[m].Path, nodes[m].Oldest, "Duplicate", confirmed ? "Same content" : "Same sizes (quick match only)");
                    foreach (int m in held) insM.Exec(gid, nodes[m].Id, nodes[m].Drive, nodes[m].Path, nodes[m].Oldest, "Stays", "Holds a folder that is kept elsewhere in the list");
                    groupCount++;
                    dupCount += dups.Count;
                    reclaim += rec;
                    if (!confirmed) quickOnly++;
                }
            }
            db.Commit();
            string staleNote = stale.Count > 0 ? " " + stale.Count + " drive(s) need a new quick scan and were left out." : "";
            j.Summary = groupCount.ToString("N0") + " duplicate groups, " + dupCount.ToString("N0") + " duplicate folders, " + Util.Size(reclaim) + " to reclaim" +
                        (quickOnly > 0 ? " (" + quickOnly + " groups are quick matches only)" : "") + "." + staleNote;
            j.Log(j.Summary);
        }

        // true when a is the better keeper than b
        static bool Better(List<ANode> nodes, int a, int b)
        {
            ANode x = nodes[a], y = nodes[b];
            int sx = (Util.InClean(x.Path) || UnderRole(nodes, a, 1)) ? 0 : 1;
            int sy = (Util.InClean(y.Path) || UnderRole(nodes, b, 1)) ? 0 : 1;
            if (sx != sy) return sx < sy;
            long ox = x.Oldest > 0 ? x.Oldest : long.MaxValue, oy = y.Oldest > 0 ? y.Oldest : long.MaxValue;
            if (ox != oy) return ox < oy;
            if (x.Prio != y.Prio) return x.Prio < y.Prio;
            if (x.Depth != y.Depth) return x.Depth < y.Depth;
            if (x.Path.Length != y.Path.Length) return x.Path.Length < y.Path.Length;
            if (x.Drive != y.Drive) return x.Drive < y.Drive;
            return x.Id < y.Id;
        }

        public List<GroupRow> GetGroups(int limit)
        {
            Dictionary<long, string> names = new Dictionary<long, string>();
            foreach (object[] r in _db.Rows("SELECT id, label, letter FROM drives")) names[Util.L(r[0])] = Util.S(r[2]) + " " + Util.S(r[1]);
            List<GroupRow> list = new List<GroupRow>();
            foreach (object[] r in _db.Rows("SELECT id, name, copies, files, bytes, reclaim, confirmed, keeper_drive, keeper_path, qsig, csig FROM dgroups ORDER BY reclaim DESC LIMIT ?", limit))
            {
                GroupRow g = new GroupRow();
                g.Id = Util.L(r[0]); g.Name = Util.S(r[1]); g.Copies = Util.L(r[2]); g.Files = Util.L(r[3]); g.Bytes = Util.L(r[4]);
                g.Reclaim = Util.L(r[5]); g.Confirmed = Util.L(r[6]) != 0; g.KeeperDriveId = Util.L(r[7]);
                string dn; names.TryGetValue(g.KeeperDriveId, out dn);
                g.Keeper = (dn ?? "?") + "  \\" + Util.S(r[8]);
                g.QSig = Util.S(r[9]); g.CSig = Util.S(r[10]);
                g.Status = g.Confirmed ? "Content checked" : "Quick match only";
                list.Add(g);
            }
            return list;
        }

        public long GroupCount() { return _db.ScalarLong("SELECT count(*) FROM dgroups"); }
        public long ReclaimTotal() { return _db.ScalarLong("SELECT ifnull(sum(reclaim),0) FROM dgroups"); }

        public List<MemberRow> GetMembers(long groupId)
        {
            Dictionary<long, string> roots = ConnectedRoots(_db);
            List<MemberRow> list = new List<MemberRow>();
            foreach (object[] r in _db.Rows("SELECT m.id, m.group_id, m.folder_id, m.drive_id, m.path, m.oldest, m.role, m.reason, d.label, d.letter, g.files, g.bytes FROM dmembers m LEFT JOIN drives d ON d.id=m.drive_id LEFT JOIN dgroups g ON g.id=m.group_id WHERE m.group_id=? ORDER BY CASE m.role WHEN 'Keep' THEN 0 WHEN 'Duplicate' THEN 1 ELSE 2 END, m.drive_id, m.path", groupId))
            {
                MemberRow m = new MemberRow();
                m.Id = Util.L(r[0]); m.GroupId = Util.L(r[1]); m.FolderId = Util.L(r[2]); m.DriveId = Util.L(r[3]); m.Path = Util.S(r[4]);
                m.Oldest = Util.Date(Util.L(r[5])); m.Role = Util.S(r[6]); m.Reason = Util.S(r[7]);
                string root;
                m.Connected = roots.TryGetValue(m.DriveId, out root);
                m.Drive = (m.Connected ? root.Substring(0, 2) : Util.S(r[9])) + " " + Util.S(r[8]);
                m.FullPath = m.Connected ? Fs.Join(root, m.Path) : "";
                m.Files = Util.L(r[10]); m.Bytes = Util.L(r[11]);
                list.Add(m);
            }
            return list;
        }

        // Make this copy the keeper. Takes effect at the next "Find duplicates".
        public void SetKeeper(long memberId)
        {
            foreach (object[] r in _db.Rows("SELECT g.qsig, g.csig, m.drive_id, m.path FROM dmembers m JOIN dgroups g ON g.id=m.group_id WHERE m.id=?", memberId))
            {
                if (Util.S(r[1]).Length > 0) _db.Run("INSERT OR REPLACE INTO keeper_pick(sig, drive_id, path) VALUES(?,?,?)", Util.S(r[1]), Util.L(r[2]), Util.S(r[3]));
                if (Util.S(r[0]).Length > 0) _db.Run("INSERT OR REPLACE INTO keeper_pick(sig, drive_id, path) VALUES(?,?,?)", Util.S(r[0]), Util.L(r[2]), Util.S(r[3]));
            }
        }

        public void ClearKeeperPicks() { _db.Run("DELETE FROM keeper_pick"); }
        public long KeeperPickCount() { return _db.ScalarLong("SELECT count(*) FROM keeper_pick"); }

        public string Stats()
        {
            long drives = _db.ScalarLong("SELECT count(*) FROM drives");
            long files = _db.ScalarLong("SELECT ifnull(sum(files),0) FROM drives");
            long bytes = _db.ScalarLong("SELECT ifnull(sum(bytes),0) FROM drives");
            long hashed = _db.ScalarLong("SELECT ifnull(sum(hashed),0) FROM drives");
            return drives + " drives in the catalog  |  " + files.ToString("N0") + " files, " + Util.Size(bytes) + "  |  " + hashed.ToString("N0") +
                   " files content-checked  |  hash: " + HashAlgorithm + "  |  " + DbPath;
        }

        // ------------------------------------------------------------ plans (what will move where)

        // Builds a batch of moves for the connected drives in driveIds. Nothing moves
        // here: the batch is shown first (as PowerShell) and applied by StartApply.
        public PlanSummary BuildPlan(bool moveDups, bool moveClean, long[] driveIds, bool includeQuick)
        {
            return BuildPlan(moveDups, moveClean, driveIds, includeQuick, null);
        }

        // scopeFolder: only this folder (its duplicates, and the folder itself to _Clean); null = the whole drives in driveIds.
        public PlanSummary BuildPlan(bool moveDups, bool moveClean, long[] driveIds, bool includeQuick, string scopeFolder)
        {
            if (Busy) throw new InvalidOperationException("Wait for the running task to finish first.");
            PlanSummary ps = new PlanSummary();
            Dictionary<long, string> roots = ConnectedRoots(_db);
            Dictionary<long, bool> chosen = new Dictionary<long, bool>();
            string scopeRel = null;
            if (!string.IsNullOrEmpty(scopeFolder))
            {
                VolumeRow sv;
                ResolveFolder(_db, scopeFolder, out sv, out scopeRel);
                if (sv.DriveId <= 0) throw new InvalidOperationException("Scan that drive or folder first: " + scopeFolder);
                driveIds = new long[] { sv.DriveId };
                if (scopeRel.Length == 0) scopeRel = null;
                else if (_db.ScalarLong("SELECT count(*) FROM folders WHERE drive_id=? AND path=?", sv.DriveId, scopeRel) == 0)
                    throw new InvalidOperationException("That folder is not in the catalog yet. Scan it first (Scan tab > One folder): " + scopeFolder);
            }
            if (driveIds != null) foreach (long id in driveIds) chosen[id] = true;
            Dictionary<long, bool> stale = new Dictionary<long, bool>();
            foreach (object[] r in _db.Rows("SELECT id FROM drives WHERE needs_rescan<>0")) stale[Util.L(r[0])] = true;
            foreach (long id in chosen.Keys)
            {
                if (!roots.ContainsKey(id)) ps.Notes.Add("Not connected, left out: " + DriveName(_db, id) + ".");
                else if (stale.ContainsKey(id)) ps.Notes.Add("Needs a new quick scan first, left out: " + DriveName(_db, id) + ".");
            }

            List<object[]> items = new List<object[]>();   // kind, drive, root, src, dst, isdir, qsig, csig, confirmed, kdrive, kpath, krel, n, bytes, files
            Dictionary<string, bool> dupSources = new Dictionary<string, bool>();
            Dictionary<string, long> nextN = new Dictionary<string, long>(StringComparer.OrdinalIgnoreCase);
            Dictionary<string, bool> usedDst = new Dictionary<string, bool>(StringComparer.OrdinalIgnoreCase);
            StringBuilder sb = new StringBuilder();
            sb.AppendLine("# File Manager - batch of moves, built " + Util.Now());
            sb.AppendLine("# Every move stays on its own drive (a rename: instant, no copying).");
            sb.AppendLine("# The tool runs the same moves itself (long paths included) and records each one, so the batch can be undone.");

            if (moveDups)
            {
                List<object[]> rows = _db.Rows(@"SELECT m.drive_id, m.path, g.qsig, g.csig, g.confirmed, g.keeper_drive, g.keeper_path, g.bytes, g.files
                    FROM dmembers m JOIN dgroups g ON g.id=m.group_id WHERE m.role='Duplicate' ORDER BY g.reclaim DESC, m.drive_id, m.path");
                bool header = false;
                foreach (object[] r in rows)
                {
                    long d = Util.L(r[0]);
                    if (!chosen.ContainsKey(d) || stale.ContainsKey(d)) continue;
                    string root;
                    if (!roots.TryGetValue(d, out root)) { ps.Offline++; continue; }
                    bool confirmed = Util.L(r[4]) != 0;
                    if (!confirmed && !includeQuick) { ps.Unconfirmed++; continue; }
                    string src = Util.S(r[1]);
                    if (scopeRel != null && !string.Equals(src, scopeRel, StringComparison.OrdinalIgnoreCase) && !Under(src, scopeRel)) continue;
                    if (!Fs.IsDir(Fs.Join(root, src))) { ps.Skipped++; ps.Notes.Add("Not found any more, skipped: " + Fs.Join(root, src)); continue; }
                    string kpath = Util.S(r[6]);
                    string krel = Util.StripClean(kpath);
                    string kname = Fs.LastPart(krel);
                    string baseDir = DupName + "\\" + krel;
                    long n;
                    if (!nextN.TryGetValue(krel, out n)) n = _db.ScalarLong("SELECT n FROM dupnum WHERE keeper=?", krel);
                    string dst;
                    do { n++; dst = baseDir + "\\" + kname + " (" + n + ")"; }
                    while (usedDst.ContainsKey(root + dst) || Fs.Exists(Fs.Join(root, dst)));
                    nextN[krel] = n;
                    usedDst[root + dst] = true;
                    items.Add(new object[] { "dup", d, root, src, dst, 1, r[2], r[3], confirmed ? 1 : 0, Util.L(r[5]), kpath, krel, n, Util.L(r[7]), Util.L(r[8]) });
                    dupSources[d + "|" + src.ToLowerInvariant()] = true;
                    if (!header) { sb.AppendLine(); sb.AppendLine("# 1. Duplicate folders -> _Duplicates\\<keeper path>\\<keeper name> (n)"); header = true; }
                    sb.AppendLine("New-Item -ItemType Directory -Force -Path " + Util.Q(Fs.Join(root, baseDir)) + " | Out-Null");
                    sb.AppendLine("Move-Item -LiteralPath " + Util.Q(Fs.Join(root, src)) + " -Destination " + Util.Q(Fs.Join(root, dst)));
                    sb.AppendLine("Set-Content -LiteralPath " + Util.Q(OriginPath(Fs.Join(root, dst))) + " -Value " +
                                  Util.Q("Original: " + Fs.Join(root, src) + " | Keeper: " + DriveName(_db, Util.L(r[5])) + " \\" + kpath));
                    ps.DupItems++;
                    ps.DupBytes += Util.L(r[7]);
                }
            }

            if (moveClean)
            {
                foreach (long d in chosen.Keys)
                {
                    string root;
                    if (!roots.TryGetValue(d, out root) || stale.ContainsKey(d)) continue;
                    sb.AppendLine();
                    sb.AppendLine("# 2. Keepers and unique folders on " + root + " -> " + Fs.Join(root, CleanName) + " (paths kept; a folder already in _Clean is merged)");
                    sb.AppendLine("New-Item -ItemType Directory -Force -Path " + Util.Q(Fs.Join(root, CleanName)) + " | Out-Null");
                    int before = ps.CleanItems;
                    if (scopeRel != null)
                    {
                        if (string.Equals(scopeRel, CleanName, StringComparison.OrdinalIgnoreCase) || Util.InClean(scopeRel)) ps.Notes.Add("That folder is already in _Clean.");
                        else AddCleanMoves(items, sb, ps, d, root, scopeRel, true, 0, dupSources, 0);
                    }
                    else
                    {
                        int err;
                        List<FsEntry> entries = Fs.ListDir(root, out err);
                        entries.Sort(delegate(FsEntry a, FsEntry b) { return string.Compare(a.Name, b.Name, StringComparison.OrdinalIgnoreCase); });
                        foreach (FsEntry e in entries)
                        {
                            if (string.Equals(e.Name, CleanName, StringComparison.OrdinalIgnoreCase) || IsRootSkip(e.Name)) continue;
                            if (e.Name.StartsWith("$") || e.IsReparse) continue;
                            if ((e.Attributes & Fs.Hidden) != 0 && (e.Attributes & Fs.SystemAttr) != 0) continue;
                            if (!e.IsDir && string.Equals(e.Name, "autorun.inf", StringComparison.OrdinalIgnoreCase)) continue;
                            AddCleanMoves(items, sb, ps, d, root, e.Name, e.IsDir, e.Size, dupSources, 0);
                        }
                    }
                    if (ps.CleanItems == before) sb.AppendLine("# (nothing to move to _Clean on " + root + ")");
                }
            }
            if (ps.Offline > 0) ps.Notes.Add(ps.Offline + " duplicate folder(s) are on drives that are not connected or not chosen; connect them and build another batch.");
            if (ps.Unconfirmed > 0) ps.Notes.Add(ps.Unconfirmed + " duplicate folder(s) are quick matches only (not content-checked) and were left out.");
            ps.Script = sb.ToString();
            if (items.Count == 0) return ps;

            _db.Begin();
            _db.Run("INSERT INTO batches(created, status, note, script) VALUES(?, 'planned', ?, ?)", Util.Now(),
                ps.DupItems + " duplicate folders, " + ps.CleanItems + " moves to _Clean", ps.Script);
            long bid = _db.LastId;
            // Steps an older plan never ran are replaced by this plan (they were worked out from an older catalog).
            List<object[]> older = _db.Rows("SELECT DISTINCT batch_id FROM actions WHERE status IN ('planned','failed') AND batch_id<>?", bid);
            _db.Run("UPDATE actions SET status='replaced', error=? WHERE status IN ('planned','failed') AND batch_id<>?", "Not run; replaced by plan " + bid, bid);
            foreach (object[] o in older) SetBatchStatus(_db, Util.L(o[0]));
            if (older.Count > 0) ps.Notes.Add("Steps that older plans never ran were replaced by this plan (" + older.Count + " plan(s)).");
            using (Stmt ins = _db.Prepare(@"INSERT INTO actions(batch_id, seq, kind, drive_id, root, src, dst, isdir, qsig, csig, confirmed, keeper_drive, keeper_path, keeper_rel, dupn, bytes, files, status)
                                           VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,'planned')"))
            {
                int seq = 0;
                foreach (object[] it in items)
                {
                    seq++;
                    ins.Exec(bid, seq, it[0], it[1], it[2], it[3], it[4], it[5], it[6], it[7], it[8], it[9], it[10], it[11], it[12], it[13], it[14]);
                }
            }
            _db.Commit();
            ps.BatchId = bid;
            return ps;
        }

        // One item for _Clean. When _Clean already has a folder with that name (an earlier folder
        // was cleaned into it), the contents are merged: whatever is not there yet moves in.
        void AddCleanMoves(List<object[]> items, StringBuilder sb, PlanSummary ps, long d, string root, string rel, bool isDir, long size, Dictionary<string, bool> dupSources, int depth)
        {
            if (dupSources.ContainsKey(d + "|" + rel.ToLowerInvariant())) return;
            string dst = CleanName + "\\" + rel;
            string dstFull = Fs.Join(root, dst);
            if (Fs.Exists(dstFull))
            {
                if (isDir && Fs.IsDir(dstFull) && depth < 40)
                {
                    int err;
                    List<FsEntry> kids = Fs.ListDir(Fs.Join(root, rel), out err);
                    kids.Sort(delegate(FsEntry a, FsEntry b) { return string.Compare(a.Name, b.Name, StringComparison.OrdinalIgnoreCase); });
                    foreach (FsEntry e in kids)
                    {
                        if (e.IsReparse) continue;
                        AddCleanMoves(items, sb, ps, d, root, rel + "\\" + e.Name, e.IsDir, e.Size, dupSources, depth + 1);
                    }
                    return;
                }
                ps.Skipped++;
                ps.Notes.Add("_Clean already has a different item with this name, left in place: " + Fs.Join(root, rel));
                return;
            }
            long cb = size, cf = 1;
            if (isDir)
            {
                cb = 0; cf = 0;
                foreach (object[] fr in _db.Rows("SELECT files, bytes FROM folders WHERE drive_id=? AND path=?", d, rel)) { cf = Util.L(fr[0]); cb = Util.L(fr[1]); }
            }
            items.Add(new object[] { "clean", d, root, rel, dst, isDir ? 1 : 0, null, null, 0, 0L, null, null, 0L, cb, cf });
            sb.AppendLine("Move-Item -LiteralPath " + Util.Q(Fs.Join(root, rel)) + " -Destination " + Util.Q(dstFull));
            ps.CleanItems++;
        }

        public void CancelBatch(long batchId) { _db.Run("UPDATE batches SET status='cancelled' WHERE id=? AND status='planned'", batchId); }

        // ------------------------------------------------------------ apply / undo (all steps, or the ones you ticked)

        // The origin note sits BESIDE the copy (X (1)_origin.txt), so the copy itself stays identical to the kept folder.
        public static string OriginPath(string dupFull) { return dupFull + OriginFile; }

        // true only for the note File Manager 1.0.x wrote INSIDE a duplicate (never a file of yours with that name)
        static bool IsOldNote(string path)
        {
            try
            {
                FsEntry e = Fs.Info(path);
                if (e == null || e.IsDir || e.Size > 4096) return false;
                using (FileStream fs = Fs.OpenRead(path))
                {
                    byte[] b = new byte[64];
                    int n = fs.Read(b, 0, b.Length);
                    return Encoding.UTF8.GetString(b, 0, n).StartsWith("This folder is a duplicate. File Manager", StringComparison.Ordinal);
                }
            }
            catch { return false; }
        }

        static Dictionary<long, bool> ToSet(long[] ids)
        {
            if (ids == null) return null;
            Dictionary<long, bool> set = new Dictionary<long, bool>();
            foreach (long i in ids) set[i] = true;
            return set;
        }

        static bool Under(string path, string folder)
        {
            return path.StartsWith(folder + "\\", StringComparison.OrdinalIgnoreCase);
        }

        // Moving a folder to _Clean also needs the duplicates inside it moved first;
        // returns the ticked steps plus those (null = every step that is still to do).
        public long[] ExpandForMove(long batchId, long[] ids)
        {
            List<object[]> rows = _db.Rows("SELECT id, kind, drive_id, src, isdir FROM actions WHERE batch_id=? AND status IN ('planned','failed') ORDER BY seq", batchId);
            Dictionary<long, bool> set = ToSet(ids);
            List<long> res = new List<long>();
            foreach (object[] r in rows)
            {
                long id = Util.L(r[0]);
                bool take = set == null || set.ContainsKey(id);
                if (!take && Util.S(r[1]) == "dup")
                {
                    foreach (object[] c in rows)
                        if (set.ContainsKey(Util.L(c[0])) && Util.S(c[1]) == "clean" && Util.L(c[4]) != 0 && Util.L(c[2]) == Util.L(r[2]) && Under(Util.S(r[3]), Util.S(c[3]))) take = true;
                }
                if (take) res.Add(id);
            }
            return res.ToArray();
        }

        // Moving a duplicate back needs the folder it came from back first (it may be in _Clean now).
        public long[] ExpandForUndo(long batchId, long[] ids)
        {
            List<object[]> rows = _db.Rows("SELECT id, kind, drive_id, src, isdir FROM actions WHERE batch_id=? AND status='done' ORDER BY seq", batchId);
            Dictionary<long, bool> set = ToSet(ids);
            List<long> res = new List<long>();
            foreach (object[] r in rows)
            {
                long id = Util.L(r[0]);
                bool take = set == null || set.ContainsKey(id);
                if (!take && Util.S(r[1]) == "clean" && Util.L(r[4]) != 0)
                {
                    foreach (object[] c in rows)
                        if (set.ContainsKey(Util.L(c[0])) && Util.S(c[1]) == "dup" && Util.L(c[2]) == Util.L(r[2]) && Under(Util.S(c[3]), Util.S(r[3]))) take = true;
                }
                if (take) res.Add(id);
            }
            return res.ToArray();
        }

        public long[] DeletableDuplicates(long batchId, long[] ids)
        {
            Dictionary<long, bool> set = ToSet(ids);
            List<long> res = new List<long>();
            foreach (object[] r in _db.Rows("SELECT id FROM actions WHERE batch_id=? AND kind='dup' AND status='done' ORDER BY seq", batchId))
                if (set == null || set.ContainsKey(Util.L(r[0]))) res.Add(Util.L(r[0]));
            return res.ToArray();
        }

        public string MoveScript(long batchId, long[] ids)
        {
            Dictionary<long, bool> set = ToSet(ids);
            StringBuilder sb = new StringBuilder();
            sb.AppendLine("# File Manager - batch " + batchId + ": the moves you ticked. Every move stays on its own drive (a rename).");
            sb.AppendLine("# Nothing is deleted. The tool runs the same moves itself (long paths included) and records each one for undo.");
            foreach (object[] r in _db.Rows("SELECT id, kind, root, src, dst, keeper_path FROM actions WHERE batch_id=? AND status IN ('planned','failed') ORDER BY seq", batchId))
            {
                if (set != null && !set.ContainsKey(Util.L(r[0]))) continue;
                string root = Util.S(r[2]), from = Fs.Join(root, Util.S(r[3])), to = Fs.Join(root, Util.S(r[4]));
                sb.AppendLine("New-Item -ItemType Directory -Force -Path " + Util.Q(Fs.Parent(to)) + " | Out-Null");
                sb.AppendLine("Move-Item -LiteralPath " + Util.Q(from) + " -Destination " + Util.Q(to));
                if (Util.S(r[1]) == "dup")
                    sb.AppendLine("Set-Content -LiteralPath " + Util.Q(OriginPath(to)) + " -Value " + Util.Q("Original: " + from + " | Kept copy: \\" + Util.S(r[5])));
            }
            return sb.ToString();
        }

        public Job StartApply(long batchId) { return StartApply(batchId, null); }

        public Job StartApply(long batchId, long[] ids)
        {
            long[] sel = ids == null ? null : ExpandForMove(batchId, ids);
            return StartJob("Apply batch " + batchId, delegate(Job j, Db db) { DoApply(j, db, batchId, ToSet(sel)); DoAnalyze(j, db, Options); });
        }

        static string OriginText(string fromFull, string driveName, string keeperDrive, string keeperPath, string sig)
        {
            StringBuilder sb = new StringBuilder();
            sb.AppendLine("The folder next to this note is a duplicate. File Manager moved it here on " + Util.Now() + ".");
            sb.AppendLine();
            sb.AppendLine("Original location : " + fromFull);
            sb.AppendLine("Original drive    : " + driveName);
            sb.AppendLine("Kept copy         : " + keeperDrive + "  \\" + keeperPath + "   (in _Clean once that drive is cleaned)");
            sb.AppendLine("Fingerprint       : " + sig);
            return sb.ToString();
        }

        void DoApply(Job j, Db db, long batchId, Dictionary<long, bool> sel)
        {
            Dictionary<long, string> roots = ConnectedRoots(db);
            List<object[]> all = db.Rows(@"SELECT id, kind, drive_id, root, src, dst, isdir, keeper_drive, keeper_path, keeper_rel, dupn, csig, qsig, confirmed
                                          FROM actions WHERE batch_id=? AND status IN ('planned','failed') ORDER BY seq", batchId);
            List<object[]> rows = new List<object[]>();
            foreach (object[] r in all) if (sel == null || sel.ContainsKey(Util.L(r[0]))) rows.Add(r);
            foreach (object[] r in rows)
            {
                string root;
                long d = Util.L(r[2]);
                if (!roots.TryGetValue(d, out root)) throw new InvalidOperationException(DriveName(db, d) + " is not connected. Connect it, or build a new plan.");
                if (!string.Equals(root, Util.S(r[3]), StringComparison.OrdinalIgnoreCase))
                    throw new InvalidOperationException(DriveName(db, d) + " is now " + root + " (it was " + Util.S(r[3]) + " when the plan was built). Build a new plan so the commands you see match.");
            }
            db.Run("UPDATE batches SET status='applying', applied=ifnull(applied, ?) WHERE id=?", Util.Now(), batchId);
            j.NewPhase("Moving folders", rows.Count, 0);
            Dictionary<long, bool> touched = new Dictionary<long, bool>();
            int done = 0, failed = 0;
            try
            {
                foreach (object[] r in rows)
                {
                    j.Check();
                    long id = Util.L(r[0]), d = Util.L(r[2]);
                    string kind = Util.S(r[1]), root = Util.S(r[3]), src = Util.S(r[4]), dst = Util.S(r[5]);
                    string from = Fs.Join(root, src), to = Fs.Join(root, dst);
                    j.Current = from;
                    try
                    {
                        if (!Fs.Exists(from)) throw new IOException("Not found: " + from);
                        if (Fs.Exists(to)) throw new IOException("Already exists: " + to);
                        Fs.EnsureDir(Fs.Parent(to));
                        Fs.Move(from, to);
                        db.Begin();
                        if (kind == "dup")
                        {
                            DeleteSubtree(db, d, src);
                            db.Run("INSERT OR IGNORE INTO dupnum(keeper, n) VALUES(?, 0)", Util.S(r[9]));
                            db.Run("UPDATE dupnum SET n=max(n, ?) WHERE keeper=?", Util.L(r[10]), Util.S(r[9]));
                        }
                        else MoveSubtree(db, d, src, dst, Util.L(r[6]) != 0);
                        db.Run("UPDATE actions SET status='done', done=?, error=NULL WHERE id=?", Util.Now(), id);
                        db.Commit();
                        if (kind == "dup")
                        {
                            try
                            {
                                string sig = Util.L(r[13]) != 0 ? Util.S(r[11]) : Util.S(r[12]);
                                Fs.WriteText(OriginPath(to), OriginText(from, DriveName(db, d), DriveName(db, Util.L(r[7])), Util.S(r[8]), sig));
                            }
                            catch (Exception ex) { j.Log("Moved, but could not write " + OriginPath(to) + ": " + ex.Message); }
                        }
                        touched[d] = true;
                        done++;
                        j.Log("Moved " + from + "  ->  " + to);
                    }
                    catch (OperationCanceledException) { throw; }
                    catch (Exception ex)
                    {
                        db.Rollback();
                        failed++;
                        j.Errors++;
                        db.Run("UPDATE actions SET status='failed', error=? WHERE id=?", Explain(ex), id);
                        j.Log("FAILED " + from + ": " + Explain(ex));
                    }
                    j.FilesDone++;
                }
            }
            finally
            {
                foreach (long d in touched.Keys) Recompute(db, d);
                SetBatchStatus(db, batchId);
                long left = db.ScalarLong("SELECT count(*) FROM actions WHERE batch_id=? AND status IN ('planned','failed')", batchId);
                j.Summary = "Batch " + batchId + ": " + done + " moved" + (failed > 0 ? ", " + failed + " failed (the reason is on each row)" : "") +
                            (left > 0 ? ", " + left + " not moved yet" : "") + ".";
                j.Log(j.Summary);
            }
        }

        // A plainer reason for the errors people actually hit.
        static string Explain(Exception ex)
        {
            string m = ex.Message;
            if (m.IndexOf("(5)", StringComparison.Ordinal) >= 0 || m.IndexOf("(32)", StringComparison.Ordinal) >= 0)
                m += " - a file or folder inside is open (Explorer window, a program, antivirus or indexing). Close it and try again.";
            return m;
        }

        static void SetBatchStatus(Db db, long batchId)
        {
            long planned = db.ScalarLong("SELECT count(*) FROM actions WHERE batch_id=? AND status IN ('planned','failed')", batchId);
            long done = db.ScalarLong("SELECT count(*) FROM actions WHERE batch_id=? AND status='done'", batchId);
            long deleted = db.ScalarLong("SELECT count(*) FROM actions WHERE batch_id=? AND status='deleted'", batchId);
            long undone = db.ScalarLong("SELECT count(*) FROM actions WHERE batch_id=? AND status='undone'", batchId);
            string st;
            if (done == 0 && deleted == 0 && planned == 0) st = undone > 0 ? "undone" : "cancelled";
            else if (done == 0 && deleted == 0) st = undone > 0 ? "partly undone" : "planned";
            else if (planned > 0 || undone > 0) st = "partial";
            else if (done == 0) st = "duplicates deleted";
            else st = "applied";
            db.Run("UPDATE batches SET status=? WHERE id=?", st, batchId);
        }

        // Range of paths under a folder: rel + "\" ... rel + "]" ('\' is 0x5C, ']' is 0x5D).
        static void DeleteSubtree(Db db, long d, string rel)
        {
            db.Run("DELETE FROM files WHERE drive_id=? AND path>? AND path<?", d, rel + "\\", rel + "]");
            db.Run("DELETE FROM folders WHERE drive_id=? AND (path=? OR (path>? AND path<?))", d, rel, rel + "\\", rel + "]");
        }

        static long FolderRow(Db db, long d, string rel)
        {
            long id = db.ScalarLong("SELECT id FROM folders WHERE drive_id=? AND path=?", d, rel);
            if (id > 0 || rel.Length == 0) return id;
            string parentRel = rel.IndexOf('\\') < 0 ? "" : rel.Substring(0, rel.LastIndexOf('\\'));
            long parent = FolderRow(db, d, parentRel);
            db.Run("INSERT INTO folders(drive_id, parent_id, path, name, depth) VALUES(?,?,?,?,?)", d, parent, rel, Fs.LastPart(rel), rel.Split('\\').Length);
            return db.LastId;
        }

        // Updates the catalog after a folder (or a file) moved on the same drive.
        static void MoveSubtree(Db db, long d, string from, string to, bool isDir)
        {
            string toParent = to.IndexOf('\\') < 0 ? "" : to.Substring(0, to.LastIndexOf('\\'));
            long parentId = FolderRow(db, d, toParent);
            if (!isDir)
            {
                db.Run("UPDATE files SET path=?, folder_id=? WHERE drive_id=? AND path=?", to, parentId, d, from);
                return;
            }
            int cut = Util.CodePoints(from) + 1;
            db.Run("UPDATE files SET path=? || substr(path, ?) WHERE drive_id=? AND path>? AND path<?", to, cut, d, from + "\\", from + "]");
            db.Run("UPDATE folders SET path=? || substr(path, ?) WHERE drive_id=? AND (path=? OR (path>? AND path<?))", to, cut, d, from, from + "\\", from + "]");
            db.Run("UPDATE folders SET parent_id=?, name=? WHERE drive_id=? AND path=?", parentId, Fs.LastPart(to), d, to);
        }

        public Job StartUndo(long batchId) { return StartUndo(batchId, null); }

        public Job StartUndo(long batchId, long[] ids)
        {
            long[] sel = ids == null ? null : ExpandForUndo(batchId, ids);
            return StartJob("Undo batch " + batchId, delegate(Job j, Db db) { DoUndo(j, db, batchId, ToSet(sel)); DoAnalyze(j, db, Options); });
        }

        public string UndoScript(long batchId) { return UndoScript(batchId, null); }

        public string UndoScript(long batchId, long[] ids)
        {
            Dictionary<long, bool> set = ToSet(ids);
            StringBuilder sb = new StringBuilder();
            sb.AppendLine("# File Manager - undo in batch " + batchId + ": the ticked moves go back, newest first.");
            foreach (object[] r in _db.Rows("SELECT id, kind, root, src, dst FROM actions WHERE batch_id=? AND status='done' ORDER BY seq DESC", batchId))
            {
                if (set != null && !set.ContainsKey(Util.L(r[0]))) continue;
                string root = Util.S(r[2]);
                string from = Fs.Join(root, Util.S(r[4])), to = Fs.Join(root, Util.S(r[3]));
                if (Util.S(r[1]) == "dup") sb.AppendLine("Remove-Item -LiteralPath " + Util.Q(OriginPath(from)) + " -ErrorAction SilentlyContinue");
                sb.AppendLine("Move-Item -LiteralPath " + Util.Q(from) + " -Destination " + Util.Q(to));
            }
            return sb.ToString();
        }

        void DoUndo(Job j, Db db, long batchId, Dictionary<long, bool> sel)
        {
            Dictionary<long, string> roots = ConnectedRoots(db);
            List<object[]> rows = new List<object[]>();
            foreach (object[] r in db.Rows("SELECT id, kind, drive_id, root, src, dst, isdir FROM actions WHERE batch_id=? AND status='done' ORDER BY seq DESC", batchId))
                if (sel == null || sel.ContainsKey(Util.L(r[0]))) rows.Add(r);
            db.Run("UPDATE batches SET status='undoing' WHERE id=?", batchId);
            j.NewPhase("Undoing moves", rows.Count, 0);
            Dictionary<long, bool> touched = new Dictionary<long, bool>(), rescan = new Dictionary<long, bool>();
            int done = 0, failed = 0;
            try
            {
                foreach (object[] r in rows)
                {
                    j.Check();
                    long id = Util.L(r[0]), d = Util.L(r[2]);
                    string kind = Util.S(r[1]), root;
                    if (!roots.TryGetValue(d, out root) || !string.Equals(root, Util.S(r[3]), StringComparison.OrdinalIgnoreCase))
                    {
                        failed++;
                        string why = "Undo skipped: the drive is not connected as " + Util.S(r[3]);
                        db.Run("UPDATE actions SET error=? WHERE id=?", why, id);
                        j.Log(why + ": " + Util.S(r[5]));
                        continue;
                    }
                    string back = Fs.Join(root, Util.S(r[4])), now = Fs.Join(root, Util.S(r[5]));
                    j.Current = now;
                    try
                    {
                        if (!Fs.Exists(now)) throw new IOException("Not found: " + now);
                        if (Fs.Exists(back)) throw new IOException("Something is already at " + back);
                        Fs.EnsureDir(Fs.Parent(back));
                        Fs.Move(now, back);
                        if (kind == "dup")
                        {
                            try { if (Fs.Exists(OriginPath(now))) Fs.DeleteFile(OriginPath(now)); } catch { }
                            try { string inside = Fs.Join(back, OriginFile); if (IsOldNote(inside)) Fs.DeleteFile(inside); } catch { }   // 1.0.x put it inside
                        }
                        db.Begin();
                        if (kind == "dup") rescan[d] = true;
                        else { MoveSubtree(db, d, Util.S(r[5]), Util.S(r[4]), Util.L(r[6]) != 0); touched[d] = true; }
                        db.Run("UPDATE actions SET status='undone', done=?, error=NULL WHERE id=?", Util.Now(), id);
                        db.Commit();
                        done++;
                        j.Log("Moved back " + now + "  ->  " + back);
                        if (kind == "dup")
                        {
                            string p = Fs.Parent(now);
                            string stop = Fs.Join(root, DupName);
                            while (p != null && p.Length > stop.Length && Fs.TryRemoveDir(p)) p = Fs.Parent(p);
                        }
                    }
                    catch (OperationCanceledException) { throw; }
                    catch (Exception ex)
                    {
                        db.Rollback();
                        failed++;
                        j.Errors++;
                        db.Run("UPDATE actions SET error=? WHERE id=?", "Undo failed: " + Explain(ex), id);
                        j.Log("FAILED " + now + ": " + Explain(ex));
                    }
                    j.FilesDone++;
                }
            }
            finally
            {
                foreach (long d in touched.Keys) if (!rescan.ContainsKey(d)) Recompute(db, d);
                foreach (long d in rescan.Keys) db.Run("UPDATE drives SET needs_rescan=1 WHERE id=?", d);
                SetBatchStatus(db, batchId);
                j.Summary = "Undo in batch " + batchId + ": " + done + " moved back" + (failed > 0 ? ", " + failed + " not (the reason is on each row)" : "") + "." +
                            (rescan.Count > 0 ? " Run a quick scan of " + rescan.Count + " drive(s) so the catalog sees the folders again." : "");
                j.Log(j.Summary);
            }
        }

        // ------------------------------------------------------------ delete duplicates (after a re-check)

        public string DeleteScript(long batchId) { return DeleteScript(batchId, null); }

        public string DeleteScript(long batchId, long[] ids)
        {
            Dictionary<long, bool> set = ToSet(ids);
            StringBuilder sb = new StringBuilder();
            sb.AppendLine("# File Manager - delete the ticked duplicate folders of batch " + batchId + ".");
            sb.AppendLine("# Before each delete the tool reads every file again and compares it with the kept copy;");
            sb.AppendLine("# a folder that differs in any way, or whose kept copy cannot be found, is NOT deleted.");
            foreach (object[] r in _db.Rows("SELECT id, root, dst FROM actions WHERE batch_id=? AND kind='dup' AND status='done' ORDER BY seq", batchId))
            {
                if (set != null && !set.ContainsKey(Util.L(r[0]))) continue;
                string full = Fs.Join(Util.S(r[1]), Util.S(r[2]));
                sb.AppendLine("Remove-Item -LiteralPath " + Util.Q(full) + " -Recurse -Force");
                sb.AppendLine("Remove-Item -LiteralPath " + Util.Q(OriginPath(full)) + " -ErrorAction SilentlyContinue");
            }
            return sb.ToString();
        }

        public Job StartDeleteDuplicates(long batchId) { return StartDeleteDuplicates(batchId, null); }

        public Job StartDeleteDuplicates(long batchId, long[] ids)
        {
            long[] sel = ids == null ? null : DeletableDuplicates(batchId, ids);
            return StartJob("Delete duplicates of batch " + batchId, delegate(Job j, Db db) { DoDeleteDuplicates(j, db, batchId, ToSet(sel)); });
        }

        sealed class LiveSig { public string Q, C; public long Files, Bytes; }

        // Fingerprints of a folder on disk, with the same rules as the scan.
        LiveSig ComputeLive(string full, bool content, string[] ignF, string[] ignD, bool top, Job j)
        {
            j.Check();
            int err;
            List<FsEntry> entries = Fs.ListDir(full, out err);
            if (err != 0) throw new IOException("Cannot read " + full + ": " + Fs.ErrText(err));
            List<long> sizes = new List<long>();
            List<string> hashes = new List<string>(), kq = new List<string>(), kc = new List<string>();
            LiveSig res = new LiveSig();
            bool all = true;
            foreach (FsEntry e in entries)
            {
                string lname = e.Name.ToLowerInvariant();
                if (e.IsDir)
                {
                    if (e.IsReparse || Wild.Any(lname, ignD)) continue;
                    LiveSig k = ComputeLive(Fs.Join(full, e.Name), content, ignF, ignD, false, j);
                    res.Files += k.Files; res.Bytes += k.Bytes;
                    if (k.Files == 0) continue;
                    kq.Add(k.Q);
                    if (k.C == null) all = false; else kc.Add(k.C);
                }
                else
                {
                    if ((e.Attributes & (Fs.Reparse | Fs.Offline | Fs.RecallOnOpen | Fs.RecallOnData)) != 0) continue;
                    if (Wild.Any(lname, ignF)) continue;
                    if (top && string.Equals(e.Name, OriginFile, StringComparison.OrdinalIgnoreCase) && IsOldNote(Fs.Join(full, e.Name))) continue;   // 1.0.x put it inside
                    sizes.Add(e.Size);
                    res.Files++; res.Bytes += e.Size;
                    if (content)
                    {
                        string fp = Fs.Join(full, e.Name);
                        j.Current = fp;
                        hashes.Add((e.Size == 0 ? Hasher.Empty() : Hasher.OfFile(fp, j)) + ":" + e.Size);
                    }
                }
            }
            if (res.Files > 0)
            {
                res.Q = Hasher.QuickSig(sizes, kq);
                res.C = content && all ? Hasher.ContentSig(hashes, kc) : null;
            }
            return res;
        }

        void DoDeleteDuplicates(Job j, Db db, long batchId, Dictionary<long, bool> sel)
        {
            Dictionary<long, string> roots = ConnectedRoots(db);
            string[] ignF = Wild.Prepare(Options.IgnoreFiles), ignD = Wild.Prepare(Options.IgnoreFolders);
            List<object[]> rows = new List<object[]>();
            foreach (object[] r in db.Rows(@"SELECT id, drive_id, root, dst, confirmed, qsig, csig, keeper_drive, keeper_path, keeper_rel, bytes
                                            FROM actions WHERE batch_id=? AND kind='dup' AND status='done' ORDER BY seq", batchId))
                if (sel == null || sel.ContainsKey(Util.L(r[0]))) rows.Add(r);
            long total = 0;
            foreach (object[] r in rows) total += Util.L(r[10]);
            db.Run("UPDATE batches SET status='deleting' WHERE id=?", batchId);
            j.NewPhase("Re-checking and deleting duplicates", rows.Count, total);
            int deleted = 0, kept = 0;
            long freed = 0;
            try
            {
                foreach (object[] r in rows)
                {
                    j.Check();
                    long id = Util.L(r[0]), d = Util.L(r[1]), kd = Util.L(r[7]);
                    string root, kroot;
                    string dupFull = Fs.Join(Util.S(r[2]), Util.S(r[3]));
                    try
                    {
                        if (!roots.TryGetValue(d, out root) || !string.Equals(root, Util.S(r[2]), StringComparison.OrdinalIgnoreCase))
                            throw new IOException("its drive is not connected as " + Util.S(r[2]));
                        if (!roots.TryGetValue(kd, out kroot)) throw new IOException("the drive with the kept copy (" + DriveName(db, kd) + ") is not connected");
                        if (!Fs.IsDir(dupFull)) throw new IOException("not found");
                        string keeper = Fs.Join(kroot, Util.S(r[8]));
                        if (!Fs.IsDir(keeper)) keeper = Fs.Join(kroot, CleanName + "\\" + Util.S(r[9]));
                        if (!Fs.IsDir(keeper)) throw new IOException("the kept copy was not found (" + Util.S(r[8]) + ")");
                        j.Log("Checking " + dupFull + " against " + keeper);
                        LiveSig dup = ComputeLive(dupFull, true, ignF, ignD, true, j);
                        if (dup.C == null) throw new IOException("some files could not be read");
                        bool same = false;
                        if (Util.L(r[4]) != 0 && dup.C == Util.S(r[6]))
                        {
                            // unchanged since the scan: a quick look at the kept copy is enough
                            LiveSig kq = ComputeLive(keeper, false, ignF, ignD, false, j);
                            same = kq.Q == dup.Q;
                        }
                        if (!same)
                        {
                            // compare both copies as they are now (also covers changed ignore settings)
                            LiveSig k = ComputeLive(keeper, true, ignF, ignD, false, j);
                            if (k.C == null) throw new IOException("some files of the kept copy could not be read (" + keeper + ")");
                            if (k.C != dup.C) throw new IOException("it is not identical to the kept copy (" + keeper + ") - a file differs, or one has a file the other has not");
                        }
                        Fs.DeleteTree(dupFull, null);   // never stopped halfway
                        try { if (Fs.Exists(OriginPath(dupFull))) Fs.DeleteFile(OriginPath(dupFull)); } catch { }
                        string p = Fs.Parent(dupFull);
                        string stop = Fs.Join(root, DupName);
                        while (p != null && p.Length > stop.Length && Fs.TryRemoveDir(p)) p = Fs.Parent(p);
                        db.Run("UPDATE actions SET status='deleted', done=?, error=NULL WHERE id=?", Util.Now(), id);
                        deleted++;
                        freed += dup.Bytes;
                        j.Log("Deleted " + dupFull + " (" + Util.Size(dup.Bytes) + ")");
                    }
                    catch (OperationCanceledException) { throw; }
                    catch (Exception ex)
                    {
                        kept++;
                        j.Errors++;
                        db.Run("UPDATE actions SET error=? WHERE id=?", "Not deleted: " + Explain(ex), id);
                        j.Log("NOT deleted " + dupFull + ": " + Explain(ex));
                    }
                    j.FilesDone++;
                }
            }
            finally
            {
                SetBatchStatus(db, batchId);
                j.Summary = "Deleted " + deleted + " duplicate folder(s), " + Util.Size(freed) + " freed" + (kept > 0 ? "; " + kept + " kept (the reason is on each row)" : "") + ".";
                j.Log(j.Summary);
            }
        }

        // ------------------------------------------------------------ start fresh

        // Empties the catalog. Nothing on any drive changes. keepBatches keeps the
        // batch history (and the duplicate numbers), so moves already made can
        // still be undone and their duplicates deleted after a new scan.
        public void Reset(bool keepBatches)
        {
            if (Busy) throw new InvalidOperationException("Wait for the running task to finish first.");
            _db.Begin();
            _db.Exec("DELETE FROM files; DELETE FROM folders; DELETE FROM dgroups; DELETE FROM dmembers; DELETE FROM contained; DELETE FROM keeper_pick; DELETE FROM scans; DELETE FROM checks; DELETE FROM checkrows;");
            if (keepBatches) _db.Exec("UPDATE drives SET folders=0, files=0, bytes=0, hashed=0, last_scan=NULL, needs_rescan=0;");
            else _db.Exec("DELETE FROM drives; DELETE FROM batches; DELETE FROM actions; DELETE FROM dupnum; DELETE FROM vruns; DELETE FROM vrows;");
            _db.Commit();
            _db.Exec("VACUUM;");
        }

        // ------------------------------------------------------------ check only (compare a folder with the catalog; add nothing)

        sealed class KNode
        {
            public string Rel; public int ParentIdx = -1;
            public List<int> Kids = new List<int>();
            public List<KFile> Own = new List<KFile>();
            public long Files, Found, Probable, Unreadable, Bytes, NewBytes;
            public string C; public bool AllRead = true;
            public string Status, Matched;
        }

        sealed class KFile
        {
            public string Rel, Full, Hash, Status, Matched; public long Size;
        }

        public Job StartCheck(string folder)
        {
            ScanOptions o = Options;
            return StartJob("Check " + folder, delegate(Job j, Db db) { DoCheck(j, db, folder, o); });
        }

        void DoCheck(Job j, Db db, string folder, ScanOptions o)
        {
            string top = (folder ?? "").Trim();
            if (top.Length == 2 && top[1] == ':') top += "\\";
            if (top.Length > 3) top = top.TrimEnd('\\');
            if (!Fs.IsDir(top)) throw new InvalidOperationException("Not found: " + folder);
            // When the folder itself is in the catalog, its own entries are not "found elsewhere".
            long selfDrive = 0; string selfRel = null;
            try { VolumeRow sv; ResolveFolder(db, top, out sv, out selfRel); selfDrive = sv.DriveId; } catch { }
            string[] ignF = Wild.Prepare(o.IgnoreFiles), ignD = Wild.Prepare(o.IgnoreFolders);

            db.Run("INSERT INTO checks(folder, started, status) VALUES(?,?,'running')", top, Util.Now());
            long checkId = db.LastId;
            j.ResultId = checkId;

            // 1. list the folder
            j.NewPhase("Check: listing files", 0, 0);
            List<KNode> nodes = new List<KNode>();
            List<KFile> files = new List<KFile>();
            KNode rootNode = new KNode(); rootNode.Rel = "";
            nodes.Add(rootNode);
            for (int k = 0; k < nodes.Count; k++)
            {
                j.Check();
                KNode n = nodes[k];
                string full = n.Rel.Length == 0 ? top : Fs.Join(top, n.Rel);
                int err;
                List<FsEntry> entries = Fs.ListDir(full, out err);
                if (err != 0) { j.Errors++; n.AllRead = false; j.Log("Cannot read " + full + ": " + Fs.ErrText(err)); }
                foreach (FsEntry e in entries)
                {
                    string lname = e.Name.ToLowerInvariant();
                    if (e.IsDir)
                    {
                        if (e.IsReparse || Wild.Any(lname, ignD)) continue;
                        if (n.Rel.Length == 0 && full.Length <= 3 && IsRootSkip(e.Name)) continue;
                        KNode c = new KNode(); c.Rel = Fs.Join(n.Rel, e.Name); c.ParentIdx = k;
                        n.Kids.Add(nodes.Count); nodes.Add(c);
                        j.Folders++;
                    }
                    else
                    {
                        if ((e.Attributes & (Fs.Reparse | Fs.Offline | Fs.RecallOnOpen | Fs.RecallOnData)) != 0) continue;
                        if (Wild.Any(lname, ignF)) continue;
                        KFile f = new KFile(); f.Rel = Fs.Join(n.Rel, e.Name); f.Full = Fs.Join(full, e.Name); f.Size = e.Size;
                        n.Own.Add(f); files.Add(f);
                        j.FilesDone++; j.BytesDone += e.Size;
                    }
                }
            }

            // 2. read every file of the folder
            long total = 0;
            foreach (KFile f in files) total += f.Size;
            j.NewPhase("Check: reading the folder's files", files.Count, total);
            foreach (KFile f in files)
            {
                j.Check();
                j.Current = f.Full;
                try { f.Hash = f.Size == 0 ? Hasher.Empty() : Hasher.OfFile(f.Full, j); }
                catch (OperationCanceledException) { throw; }
                catch (Exception ex) { f.Status = "Unreadable"; f.Matched = ex.Message; j.Errors++; j.Log("Cannot read " + f.Full + ": " + ex.Message); }
                j.FilesDone++;
            }

            // 3. look each file up in the catalog (same size, then same hash)
            Dictionary<long, string> roots = ConnectedRoots(db);
            Dictionary<long, string> names = new Dictionary<long, string>();
            foreach (object[] r in db.Rows("SELECT id, label, letter FROM drives")) names[Util.L(r[0])] = Util.S(r[2]) + " " + Util.S(r[1]);
            j.NewPhase("Check: comparing with the catalog", files.Count, 0);
            using (Stmt q = db.Prepare("SELECT id, drive_id, path, hash FROM files WHERE drive_id>0 AND size=? LIMIT 5000"))
            using (Stmt up = db.Prepare("UPDATE files SET hash=? WHERE id=?"))
            {
                foreach (KFile f in files)
                {
                    j.Check();
                    j.FilesDone++;
                    if (f.Status == "Unreadable") continue;
                    q.Bind(f.Size);
                    List<object[]> cands = new List<object[]>();
                    while (q.Step()) cands.Add(new object[] { q.Long(0), q.Long(1), q.Text(2), q.IsNull(3) ? null : q.Text(3) });
                    string hit = null, maybe = null;
                    foreach (object[] c in cands)
                    {
                        long cd = (long)c[1]; string cp = (string)c[2];
                        if (cd == selfDrive && selfRel != null && (selfRel.Length == 0 || string.Equals(cp, selfRel, StringComparison.OrdinalIgnoreCase) || Under(cp, selfRel))) continue;
                        string ch = (string)c[3];
                        string where = (names.ContainsKey(cd) ? names[cd] : "?") + "  \\" + cp;
                        if (ch == null)
                        {
                            string croot;
                            if (roots.TryGetValue(cd, out croot))
                            {
                                try { j.Current = Fs.Join(croot, cp); ch = Hasher.OfFile(Fs.Join(croot, cp), null); up.Exec(ch, (long)c[0]); }
                                catch { ch = null; }
                            }
                        }
                        if (ch == null) { if (maybe == null) maybe = where; continue; }
                        if (ch == f.Hash) { hit = where; break; }
                    }
                    if (hit != null) { f.Status = "Have"; f.Matched = hit; }
                    else if (maybe != null) { f.Status = "Probably"; f.Matched = "same size, not content-checked: " + maybe; }
                    else f.Status = "New";
                }
            }

            // 4. folders, deepest first: content fingerprint (same rule as the scan) and counts
            for (int k = nodes.Count - 1; k >= 0; k--)
            {
                KNode n = nodes[k];
                List<string> hs = new List<string>(), kc = new List<string>();
                bool all = n.AllRead;
                foreach (KFile f in n.Own)
                {
                    n.Files++; n.Bytes += f.Size;
                    if (f.Status == "Have") n.Found++;
                    else if (f.Status == "Probably") n.Probable++;
                    else if (f.Status == "Unreadable") { n.Unreadable++; all = false; }
                    if (f.Status == "New" || f.Status == "Probably" || f.Status == "Unreadable") n.NewBytes += f.Size;
                    if (f.Hash != null) hs.Add(f.Hash + ":" + f.Size);
                }
                foreach (int c in n.Kids)
                {
                    KNode m = nodes[c];
                    n.Files += m.Files; n.Found += m.Found; n.Probable += m.Probable; n.Unreadable += m.Unreadable; n.Bytes += m.Bytes; n.NewBytes += m.NewBytes;
                    if (m.Files == 0) continue;
                    if (m.C == null) all = false; else kc.Add(m.C);
                }
                n.C = (n.Files > 0 && all) ? Hasher.ContentSig(hs, kc) : null;
            }
            using (Stmt q = db.Prepare("SELECT drive_id, path FROM folders WHERE drive_id>0 AND csig=? LIMIT 20"))
            {
                foreach (KNode n in nodes)
                {
                    if (n.Files == 0) { n.Status = "Empty"; continue; }
                    if (n.C != null)
                    {
                        q.Bind(n.C);
                        while (q.Step())
                        {
                            long cd = q.Long(0); string cp = q.Text(1);
                            if (cd == selfDrive && selfRel != null && (selfRel.Length == 0 || string.Equals(cp, selfRel, StringComparison.OrdinalIgnoreCase) || Under(cp, selfRel))) continue;
                            n.Status = "Already have it"; n.Matched = (names.ContainsKey(cd) ? names[cd] : "?") + "  \\" + cp;
                            break;
                        }
                        q.Bind();
                    }
                    if (n.Status != null) continue;
                    if (n.Found == n.Files) n.Status = "All files found elsewhere";
                    else if (n.Found + n.Probable == n.Files) n.Status = "Probably all found";
                    else if (n.Found + n.Probable > 0) n.Status = "Partly";
                    else n.Status = "New";
                }
            }

            // 5. results: folders top-down (not below one that is fully accounted for), then the files still needed
            long haveFolders = 0;
            db.Begin();
            using (Stmt ins = db.Prepare("INSERT INTO checkrows(check_id, kind, rel, status, files, found, bytes, new_bytes, matched) VALUES(?,?,?,?,?,?,?,?,?)"))
            {
                for (int k = 0; k < nodes.Count; k++)
                {
                    KNode n = nodes[k];
                    bool hidden = false;
                    for (int p = n.ParentIdx; p >= 0; p = nodes[p].ParentIdx)
                        if (nodes[p].Status == "Already have it" || nodes[p].Status == "All files found elsewhere") { hidden = true; break; }
                    if (hidden || n.Status == "Empty") continue;
                    if (n.Status == "Already have it" || n.Status == "All files found elsewhere") haveFolders++;
                    ins.Exec(checkId, "folder", n.Rel.Length == 0 ? "(the folder itself)" : n.Rel, n.Status, n.Files, n.Found, n.Bytes, n.NewBytes, n.Matched);
                }
                foreach (KFile f in files)
                    if (f.Status != "Have") ins.Exec(checkId, "file", f.Rel, f.Status, 1, 0, f.Size, f.Size, f.Matched);
            }
            db.Commit();
            KNode r0 = nodes[0];
            long newFiles = 0, newBytes = 0;
            foreach (KFile f in files) if (f.Status == "New") { newFiles++; newBytes += f.Size; }
            db.Run(@"UPDATE checks SET finished=?, status='done', folders=?, files=?, bytes=?, have_files=?, probable=?, new_files=?, new_bytes=?, unreadable=?, have_folders=? WHERE id=?",
                Util.Now(), nodes.Count, r0.Files, r0.Bytes, r0.Found, r0.Probable, newFiles, newBytes, r0.Unreadable, haveFolders, checkId);
            j.Summary = top + ": " + r0.Found.ToString("N0") + " of " + r0.Files.ToString("N0") + " files already in the catalog" +
                        (r0.Probable > 0 ? ", " + r0.Probable.ToString("N0") + " probably (same size, not content-checked)" : "") +
                        ", " + newFiles.ToString("N0") + " new (" + Util.Size(newBytes) + ")" + (r0.Unreadable > 0 ? ", " + r0.Unreadable + " unreadable" : "") + ".";
            j.Log(j.Summary);
        }

        public CheckRun GetCheck(long checkId)
        {
            foreach (object[] r in _db.Rows("SELECT id, folder, started, finished, status, folders, files, bytes, have_files, probable, new_files, new_bytes, unreadable, have_folders FROM checks WHERE id=?", checkId))
            {
                CheckRun c = new CheckRun();
                c.Id = Util.L(r[0]); c.Folder = Util.S(r[1]); c.Started = Util.S(r[2]); c.Finished = Util.S(r[3]); c.Status = Util.S(r[4]);
                c.Folders = Util.L(r[5]); c.Files = Util.L(r[6]); c.Bytes = Util.L(r[7]); c.HaveFiles = Util.L(r[8]); c.Probable = Util.L(r[9]);
                c.NewFiles = Util.L(r[10]); c.NewBytes = Util.L(r[11]); c.Unreadable = Util.L(r[12]); c.HaveFolders = Util.L(r[13]);
                return c;
            }
            return null;
        }

        public List<CheckRow> GetCheckRows(long checkId, string kind, int limit)
        {
            List<CheckRow> list = new List<CheckRow>();
            foreach (object[] r in _db.Rows("SELECT rel, status, files, found, bytes, new_bytes, matched FROM checkrows WHERE check_id=? AND kind=? ORDER BY id LIMIT ?", checkId, kind, limit))
            {
                CheckRow c = new CheckRow();
                c.Kind = kind; c.Rel = Util.S(r[0]); c.Status = Util.S(r[1]); c.Files = Util.L(r[2]); c.Found = Util.L(r[3]);
                c.Bytes = Util.L(r[4]); c.NewBytes = Util.L(r[5]); c.Matched = Util.S(r[6]);
                list.Add(c);
            }
            return list;
        }

        public int ExportCheckCsv(long checkId, string path)
        {
            CheckRun run = GetCheck(checkId);
            StringBuilder sb = new StringBuilder();
            sb.AppendLine("Kind,Path (inside " + Util.Csv(run == null ? "" : run.Folder).Trim('"') + "),Result,Files,Found elsewhere,Size (bytes),Not found (bytes),Where");
            int n = 0;
            foreach (string kind in new string[] { "folder", "file" })
                foreach (CheckRow c in GetCheckRows(checkId, kind, int.MaxValue))
                {
                    sb.AppendLine(string.Join(",", new string[] { kind, Util.Csv(c.Rel), Util.Csv(c.Status), c.Files.ToString(), c.Found.ToString(), c.Bytes.ToString(), c.NewBytes.ToString(), Util.Csv(c.Matched) }));
                    n++;
                }
            System.IO.File.WriteAllText(path, sb.ToString(), new UTF8Encoding(true));
            return n;
        }

        // ------------------------------------------------------------ workflow (where you are in the recommended steps)

        public WorkflowInfo GetWorkflow()
        {
            WorkflowInfo w = new WorkflowInfo();
            Dictionary<long, string> roots = ConnectedRoots(_db);
            foreach (DriveRow d in GetDrives())
            {
                w.Drives++;
                if (d.Folders > 0) w.Scanned++; else w.NotScanned.Add(d.Letter + " " + d.Label);
                if (d.NeedsRescan) w.NeedRescan.Add(d.Letter + " " + d.Label);
                if (d.Folders == 0) continue;
                long loose = _db.ScalarLong("SELECT count(*) FROM folders WHERE drive_id=? AND depth=1 AND path<>?", d.Id, CleanName) +
                             _db.ScalarLong("SELECT count(*) FROM files f JOIN folders r ON r.id=f.folder_id WHERE r.drive_id=? AND r.depth=0", d.Id);
                if (loose > 0) w.NotCleaned.Add(d.Letter + " " + d.Label + " (" + loose.ToString("N0") + " items outside _Clean)");
            }
            foreach (object[] r in _db.Rows(@"SELECT f.drive_id, count(*), ifnull(sum(f.size),0) FROM files f JOIN folders fo ON fo.id=f.folder_id
                    WHERE f.drive_id>0 AND f.hash IS NULL AND fo.qsig IN (SELECT qsig FROM folders WHERE drive_id>0 AND depth>0 AND files>0 AND qsig IS NOT NULL GROUP BY qsig HAVING count(*)>1)
                    GROUP BY f.drive_id"))
            {
                w.ToCheckFiles += Util.L(r[1]); w.ToCheckBytes += Util.L(r[2]);
                w.ToCheck.Add(DriveName(_db, Util.L(r[0])) + ": " + Util.L(r[1]).ToString("N0") + " files, " + Util.Size(Util.L(r[2])));
            }
            w.Groups = GroupCount();
            w.Reclaim = ReclaimTotal();
            w.QuickGroups = _db.ScalarLong("SELECT count(*) FROM dgroups WHERE confirmed=0");
            w.Batches = _db.ScalarLong("SELECT count(*) FROM batches");
            w.PlannedSteps = _db.ScalarLong("SELECT count(*) FROM actions WHERE status IN ('planned','failed')");
            w.MovedDuplicates = _db.ScalarLong("SELECT count(*) FROM actions WHERE kind='dup' AND status='done'");
            w.MovedDuplicateBytes = _db.ScalarLong("SELECT ifnull(sum(bytes),0) FROM actions WHERE kind='dup' AND status='done'");
            w.DeletedDuplicates = _db.ScalarLong("SELECT count(*) FROM actions WHERE status='deleted'");
            w.VerifyRuns = _db.ScalarLong("SELECT count(*) FROM vruns WHERE status='done'");
            w.Checks = _db.ScalarLong("SELECT count(*) FROM checks WHERE status='done'");
            return w;
        }

        // ------------------------------------------------------------ "contained in" report

        sealed class CNode
        {
            public long Id, Drive, Files, Bytes; public string Path; public int Depth, ParentIdx = -1;
            public List<int> Kids = new List<int>(); public List<long> Own = new List<long>();
            public bool Unhashed, Complete, Skip;
        }

        public Job StartContained()
        {
            return StartJob("Find contained folders", delegate(Job j, Db db) { DoContained(j, db); });
        }

        static long HashKey(string h) { return Convert.ToInt64(h.Substring(0, 16), 16); }

        void DoContained(Job j, Db db)
        {
            j.NewPhase("Contained folders: loading the catalog", 0, 0);
            List<CNode> nodes = new List<CNode>();
            Dictionary<long, int> index = new Dictionary<long, int>();
            List<long> parents = new List<long>();
            foreach (object[] r in db.Rows("SELECT f.id, f.parent_id, f.drive_id, f.path, f.depth, f.files, f.bytes FROM folders f JOIN drives d ON d.id=f.drive_id WHERE f.files>0 AND d.needs_rescan=0"))
            {
                CNode n = new CNode();
                n.Id = Util.L(r[0]); n.Drive = Util.L(r[2]); n.Path = Util.S(r[3]); n.Depth = (int)Util.L(r[4]); n.Files = Util.L(r[5]); n.Bytes = Util.L(r[6]);
                index[n.Id] = nodes.Count; nodes.Add(n); parents.Add(Util.L(r[1]));
            }
            for (int i = 0; i < nodes.Count; i++) { int p; if (index.TryGetValue(parents[i], out p) && p != i) { nodes[i].ParentIdx = p; nodes[p].Kids.Add(i); } }
            foreach (object[] r in db.Rows("SELECT m.folder_id FROM dmembers m WHERE m.role='Duplicate'")) { int i; if (index.TryGetValue(Util.L(r[0]), out i)) nodes[i].Skip = true; }

            Dictionary<long, List<int>> occ = new Dictionary<long, List<int>>();
            using (Stmt s = db.Prepare("SELECT folder_id, hash FROM files WHERE drive_id>0"))
            {
                s.Bind();
                while (s.Step())
                {
                    int i;
                    if (!index.TryGetValue(s.Long(0), out i)) continue;
                    if (s.IsNull(1)) { nodes[i].Unhashed = true; continue; }
                    long k = HashKey(s.Text(1));
                    nodes[i].Own.Add(k);
                    List<int> l;
                    if (!occ.TryGetValue(k, out l)) { l = new List<int>(); occ[k] = l; }
                    if (l.Count == 0 || l[l.Count - 1] != i) l.Add(i);
                }
            }
            // complete = every file in the subtree has a hash (children before parents)
            List<int> byDepth = new List<int>();
            for (int i = 0; i < nodes.Count; i++) byDepth.Add(i);
            byDepth.Sort(delegate(int a, int b) { return nodes[b].Depth.CompareTo(nodes[a].Depth); });
            foreach (int i in byDepth)
            {
                bool ok = !nodes[i].Unhashed;
                foreach (int c in nodes[i].Kids) if (!nodes[c].Complete) ok = false;
                nodes[i].Complete = ok;
            }
            byDepth.Reverse();

            Dictionary<int, Dictionary<long, bool>> cache = new Dictionary<int, Dictionary<long, bool>>();
            Dictionary<int, bool> reported = new Dictionary<int, bool>();
            List<int[]> found = new List<int[]>();
            j.NewPhase("Contained folders: comparing", byDepth.Count, 0);
            foreach (int x in byDepth)
            {
                j.Check();
                j.FilesDone++;
                CNode X = nodes[x];
                if (X.Depth < 1 || X.Depth > 4 || !X.Complete || X.Skip || X.Files < 2 || X.Files > 50000) continue;
                if (Util.InClean(X.Path) && X.Depth == 1) continue;
                bool under = false;
                for (int p = X.ParentIdx; p >= 0; p = nodes[p].ParentIdx) if (reported.ContainsKey(p) || nodes[p].Skip) under = true;
                if (under) continue;
                Dictionary<long, bool> sx = SubtreeSet(nodes, x);
                long rare = 0; int rareCount = int.MaxValue;
                foreach (long h in sx.Keys) { List<int> l; if (occ.TryGetValue(h, out l) && l.Count < rareCount) { rareCount = l.Count; rare = h; } }
                if (rareCount == int.MaxValue || rareCount < 2) continue;
                List<int> cands = new List<int>();
                Dictionary<int, bool> seenC = new Dictionary<int, bool>();
                foreach (int f in occ[rare])
                {
                    for (int a = f; a >= 0 && cands.Count < 60; a = nodes[a].ParentIdx)
                    {
                        CNode A = nodes[a];
                        if (A.Depth < 1) break;
                        if (seenC.ContainsKey(a)) continue;
                        seenC[a] = true;
                        if (A.Files <= X.Files || A.Files > 200000) continue;
                        if (IsAncestor(nodes, a, x) || IsAncestor(nodes, x, a) || a == x) continue;
                        cands.Add(a);
                    }
                }
                cands.Sort(delegate(int a, int b) { return nodes[a].Files.CompareTo(nodes[b].Files); });
                foreach (int a in cands)
                {
                    Dictionary<long, bool> sa;
                    if (!cache.TryGetValue(a, out sa))
                    {
                        if (cache.Count > 300) cache.Clear();
                        sa = SubtreeSet(nodes, a);
                        cache[a] = sa;
                    }
                    bool all = true;
                    foreach (long h in sx.Keys) if (!sa.ContainsKey(h)) { all = false; break; }
                    if (all) { found.Add(new int[] { x, a }); reported[x] = true; break; }
                }
            }
            db.Begin();
            db.Exec("DELETE FROM contained");
            foreach (int[] f in found)
            {
                CNode X = nodes[f[0]], A = nodes[f[1]];
                db.Run("INSERT INTO contained(drive_id, path, files, bytes, in_drive, in_path, in_files) VALUES(?,?,?,?,?,?,?)", X.Drive, X.Path, X.Files, X.Bytes, A.Drive, A.Path, A.Files);
            }
            db.Commit();
            j.Summary = found.Count + " folder(s) have all their files inside another, bigger folder.";
            j.Log(j.Summary);
        }

        static bool IsAncestor(List<CNode> nodes, int a, int x)
        {
            for (int p = nodes[x].ParentIdx; p >= 0; p = nodes[p].ParentIdx) if (p == a) return true;
            return false;
        }

        static Dictionary<long, bool> SubtreeSet(List<CNode> nodes, int root)
        {
            Dictionary<long, bool> set = new Dictionary<long, bool>();
            List<int> stack = new List<int>();
            stack.Add(root);
            while (stack.Count > 0)
            {
                int i = stack[stack.Count - 1];
                stack.RemoveAt(stack.Count - 1);
                foreach (long h in nodes[i].Own) set[h] = true;
                foreach (int c in nodes[i].Kids) stack.Add(c);
            }
            return set;
        }

        public List<ContainedRow> GetContained(int limit)
        {
            Dictionary<long, string> names = new Dictionary<long, string>();
            foreach (object[] r in _db.Rows("SELECT id, label, letter FROM drives")) names[Util.L(r[0])] = Util.S(r[2]) + " " + Util.S(r[1]);
            List<ContainedRow> list = new List<ContainedRow>();
            foreach (object[] r in _db.Rows("SELECT id, drive_id, path, files, bytes, in_drive, in_path, in_files FROM contained ORDER BY bytes DESC LIMIT ?", limit))
            {
                ContainedRow c = new ContainedRow();
                string n1, n2;
                names.TryGetValue(Util.L(r[1]), out n1); names.TryGetValue(Util.L(r[5]), out n2);
                c.Id = Util.L(r[0]); c.Drive = n1 ?? ""; c.Path = Util.S(r[2]); c.Files = Util.L(r[3]); c.Bytes = Util.L(r[4]);
                c.InDrive = n2 ?? ""; c.InPath = Util.S(r[6]); c.InFiles = Util.L(r[7]);
                list.Add(c);
            }
            return list;
        }

        // ------------------------------------------------------------ history

        public List<ScanRow> GetScans(int limit)
        {
            List<ScanRow> list = new List<ScanRow>();
            foreach (object[] r in _db.Rows("SELECT s.id, s.kind, s.started, s.finished, s.status, s.folders, s.files, s.bytes, s.hashed, s.hashed_bytes, s.errors, s.note, d.label, d.letter FROM scans s LEFT JOIN drives d ON d.id=s.drive_id ORDER BY s.id DESC LIMIT ?", limit))
            {
                ScanRow s = new ScanRow();
                s.Id = Util.L(r[0]); s.Kind = Util.S(r[1]); s.Started = Util.S(r[2]); s.Finished = Util.S(r[3]); s.Status = Util.S(r[4]);
                s.Folders = Util.L(r[5]); s.Files = Util.L(r[6]); s.Bytes = Util.L(r[7]); s.Hashed = Util.L(r[8]); s.HashedBytes = Util.L(r[9]);
                s.Errors = Util.L(r[10]); s.Note = Util.S(r[11]);
                s.Drive = r[12] == null ? "All connected drives" : Util.S(r[13]) + " " + Util.S(r[12]);
                list.Add(s);
            }
            return list;
        }

        public List<BatchRow> GetBatches(int limit)
        {
            List<BatchRow> list = new List<BatchRow>();
            foreach (object[] r in _db.Rows(@"SELECT b.id, b.created, b.applied, b.status, b.note, count(a.id),
                    sum(CASE WHEN a.status IN ('done','deleted') THEN 1 ELSE 0 END), sum(CASE WHEN a.status='failed' THEN 1 ELSE 0 END),
                    sum(CASE WHEN a.status='deleted' THEN 1 ELSE 0 END), sum(CASE WHEN a.status='undone' THEN 1 ELSE 0 END), ifnull(sum(a.bytes),0)
                    FROM batches b LEFT JOIN actions a ON a.batch_id=b.id GROUP BY b.id ORDER BY b.id DESC LIMIT ?", limit))
            {
                BatchRow b = new BatchRow();
                b.Id = Util.L(r[0]); b.Created = Util.S(r[1]); b.Applied = Util.S(r[2]); b.Status = Util.S(r[3]); b.Note = Util.S(r[4]);
                b.Items = Util.L(r[5]); b.Done = Util.L(r[6]); b.Failed = Util.L(r[7]); b.Deleted = Util.L(r[8]); b.Undone = Util.L(r[9]); b.Bytes = Util.L(r[10]);
                list.Add(b);
            }
            return list;
        }

        public List<ActionRow> GetActions(long batchId, int limit)
        {
            List<ActionRow> list = new List<ActionRow>();
            foreach (object[] r in _db.Rows(@"SELECT a.id, a.batch_id, a.seq, a.kind, a.drive_id, a.root, a.src, a.dst, a.status, a.done, a.error, a.bytes, a.files, a.confirmed, a.isdir, a.keeper_path, d.label
                    FROM actions a LEFT JOIN drives d ON d.id=a.drive_id WHERE a.batch_id=? ORDER BY a.seq LIMIT ?", batchId, limit))
            {
                ActionRow a = new ActionRow();
                a.Id = Util.L(r[0]); a.BatchId = Util.L(r[1]); a.Seq = Util.L(r[2]); a.Kind = Util.S(r[3]) == "dup" ? "Duplicate" : "To _Clean";
                a.DriveId = Util.L(r[4]); a.Root = Util.S(r[5]); a.Src = Fs.Join(a.Root, Util.S(r[6])); a.Dst = Fs.Join(a.Root, Util.S(r[7]));
                a.Status = Util.S(r[8]); a.Done = Util.S(r[9]); a.Error = Util.S(r[10]); a.Bytes = Util.L(r[11]); a.Files = Util.L(r[12]);
                a.Confirmed = Util.L(r[13]) != 0; a.IsDir = Util.L(r[14]) != 0; a.KeeperPath = Util.S(r[15]); a.Drive = a.Root.TrimEnd('\\') + " " + Util.S(r[16]);
                list.Add(a);
            }
            return list;
        }

        public string BatchScript(long batchId) { return Util.S(_db.Scalar("SELECT script FROM batches WHERE id=?", batchId)); }
        public long BatchDoneDuplicates(long batchId) { return _db.ScalarLong("SELECT count(*) FROM actions WHERE batch_id=? AND kind='dup' AND status='done'", batchId); }
        public long BatchDone(long batchId) { return _db.ScalarLong("SELECT count(*) FROM actions WHERE batch_id=? AND status='done'", batchId); }
        public long BatchPending(long batchId) { return _db.ScalarLong("SELECT count(*) FROM actions WHERE batch_id=? AND status IN ('planned','failed')", batchId); }

        public string PendingScript(long batchId)
        {
            StringBuilder sb = new StringBuilder();
            sb.AppendLine("# File Manager - the moves of batch " + batchId + " that are still to do.");
            foreach (object[] r in _db.Rows("SELECT kind, root, src, dst FROM actions WHERE batch_id=? AND status IN ('planned','failed') ORDER BY seq", batchId))
            {
                string root = Util.S(r[1]);
                string to = Fs.Join(root, Util.S(r[3]));
                sb.AppendLine("New-Item -ItemType Directory -Force -Path " + Util.Q(Fs.Parent(to)) + " | Out-Null");
                sb.AppendLine("Move-Item -LiteralPath " + Util.Q(Fs.Join(root, Util.S(r[2]))) + " -Destination " + Util.Q(to));
            }
            return sb.ToString();
        }

        // ------------------------------------------------------------ consolidate: verify a copy, then remove the source

        public Job StartVerifyCopy(string source, string target)
        {
            return StartJob("Verify copy", delegate(Job j, Db db) { DoVerify(j, db, source, target); });
        }

        void DoVerify(Job j, Db db, string source, string target)
        {
            if (!Fs.IsDir(source)) throw new InvalidOperationException("Not found: " + source);
            if (!Fs.IsDir(target)) throw new InvalidOperationException("Not found: " + target);
            j.NewPhase("Verify: listing files", 0, 0);
            List<object[]> files = new List<object[]>();   // rel, size
            List<string> stack = new List<string>();
            stack.Add("");
            while (stack.Count > 0)
            {
                j.Check();
                string rel = stack[stack.Count - 1];
                stack.RemoveAt(stack.Count - 1);
                int err;
                foreach (FsEntry e in Fs.ListDir(Fs.Join(source, rel), out err))
                {
                    if (e.IsReparse) continue;
                    string r2 = Fs.Join(rel, e.Name);
                    if (e.IsDir) stack.Add(r2); else files.Add(new object[] { r2, e.Size });
                }
                if (err != 0) { j.Errors++; j.Log("Cannot read " + Fs.Join(source, rel) + ": " + Fs.ErrText(err)); }
            }
            long total = 0;
            foreach (object[] f in files) total += (long)f[1];
            db.Run("INSERT INTO vruns(src, dst, started, status) VALUES(?,?,?,'running')", source, target, Util.Now());
            long run = db.LastId;
            j.ResultId = run;
            j.NewPhase("Verify: comparing both copies", files.Count, total * 2);
            long ok = 0, missing = 0, diff = 0, errors = 0;
            bool stopped = false;
            DateTime last = DateTime.UtcNow;
            db.Begin();
            using (Stmt ins = db.Prepare("INSERT INTO vrows(run_id, rel, size, status, note) VALUES(?,?,?,?,?)"))
            {
                try
                {
                    foreach (object[] f in files)
                    {
                        j.Check();
                        string rel = (string)f[0];
                        long size = (long)f[1];
                        string s = Fs.Join(source, rel), t = Fs.Join(target, rel);
                        j.Current = s;
                        string status, note = null;
                        try
                        {
                            FsEntry te = Fs.Info(t);
                            if (te == null || te.IsDir) { status = "Missing"; missing++; Interlocked.Add(ref j.BytesDone, size * 2); }
                            else if (te.Size != size) { status = "Different"; note = "size " + Util.Size(te.Size) + " in the target"; diff++; Interlocked.Add(ref j.BytesDone, size * 2); }
                            else
                            {
                                string hs = size == 0 ? "" : Hasher.OfFile(s, j);
                                string ht = size == 0 ? "" : Hasher.OfFile(t, j);
                                if (hs == ht) { status = "OK"; ok++; } else { status = "Different"; note = "same size, different content"; diff++; }
                            }
                        }
                        catch (OperationCanceledException) { throw; }
                        catch (Exception ex) { status = "Error"; note = ex.Message; errors++; j.Errors++; }
                        ins.Exec(run, rel, size, status, note);
                        if (status != "OK") j.Log(status + ": " + rel + (note != null ? " (" + note + ")" : ""));
                        j.FilesDone++;
                        if ((DateTime.UtcNow - last).TotalSeconds > 3) { db.Commit(); db.Begin(); last = DateTime.UtcNow; }
                    }
                }
                catch (OperationCanceledException) { stopped = true; }
            }
            db.Commit();
            db.Run("UPDATE vruns SET finished=?, status=?, ok=?, missing=?, different=?, errors=? WHERE id=?", Util.Now(), stopped ? "stopped" : "done", ok, missing, diff, errors, run);
            j.Summary = "Verify " + (stopped ? "stopped" : "done") + ": " + ok.ToString("N0") + " files match, " + missing + " missing, " + diff + " different, " + errors + " errors.";
            j.Log(j.Summary);
            if (stopped) throw new OperationCanceledException();
        }

        public List<VerifyRunRow> GetVerifyRuns(int limit)
        {
            List<VerifyRunRow> list = new List<VerifyRunRow>();
            foreach (object[] r in _db.Rows("SELECT id, src, dst, started, finished, status, ok, missing, different, errors, removed FROM vruns ORDER BY id DESC LIMIT ?", limit))
            {
                VerifyRunRow v = new VerifyRunRow();
                v.Id = Util.L(r[0]); v.Source = Util.S(r[1]); v.Target = Util.S(r[2]); v.Started = Util.S(r[3]); v.Finished = Util.S(r[4]); v.Status = Util.S(r[5]);
                v.Ok = Util.L(r[6]); v.Missing = Util.L(r[7]); v.Different = Util.L(r[8]); v.Errors = Util.L(r[9]); v.Removed = Util.L(r[10]);
                list.Add(v);
            }
            return list;
        }

        public List<VerifyRow> GetVerifyProblems(long runId, int limit)
        {
            List<VerifyRow> list = new List<VerifyRow>();
            foreach (object[] r in _db.Rows("SELECT id, rel, size, status, note FROM vrows WHERE run_id=? AND status NOT IN ('OK','Removed') ORDER BY rel LIMIT ?", runId, limit))
            {
                VerifyRow v = new VerifyRow();
                v.Id = Util.L(r[0]); v.Rel = Util.S(r[1]); v.Size = Util.L(r[2]); v.Status = Util.S(r[3]); v.Note = Util.S(r[4]);
                list.Add(v);
            }
            return list;
        }

        public string RemoveVerifiedScript(long runId)
        {
            object[] run = null;
            foreach (object[] r in _db.Rows("SELECT src, dst, ok FROM vruns WHERE id=?", runId)) run = r;
            if (run == null) return "";
            StringBuilder sb = new StringBuilder();
            sb.AppendLine("# File Manager - remove the " + Util.L(run[2]).ToString("N0") + " source files that verify run " + runId + " found identical in the target.");
            sb.AppendLine("# Missing, different and unreadable files are left where they are. Empty folders are removed afterwards.");
            sb.AppendLine("$source = " + Util.Q(Util.S(run[0])));
            sb.AppendLine("$target = " + Util.Q(Util.S(run[1])));
            int n = 0;
            foreach (object[] r in _db.Rows("SELECT rel FROM vrows WHERE run_id=? AND status='OK' ORDER BY rel", runId))
            {
                if (n++ >= 2000) { sb.AppendLine("# ... and the rest of the verified files (the full list is in the catalog, verify run " + runId + ")"); break; }
                sb.AppendLine("Remove-Item -LiteralPath (Join-Path $source " + Util.Q(Util.S(r[0])) + ") -Force");
            }
            return sb.ToString();
        }

        public Job StartRemoveVerified(long runId)
        {
            return StartJob("Remove verified source files", delegate(Job j, Db db) { DoRemoveVerified(j, db, runId); });
        }

        void DoRemoveVerified(Job j, Db db, long runId)
        {
            object[] run = null;
            foreach (object[] r in db.Rows("SELECT src, dst, status FROM vruns WHERE id=?", runId)) run = r;
            if (run == null) throw new InvalidOperationException("Verify run " + runId + " not found.");
            if (Util.S(run[2]) != "done") throw new InvalidOperationException("Verify run " + runId + " did not finish. Run Verify copy again first.");
            string source = Util.S(run[0]), target = Util.S(run[1]);
            List<object[]> rows = db.Rows("SELECT id, rel, size FROM vrows WHERE run_id=? AND status='OK'", runId);
            j.NewPhase("Removing verified source files", rows.Count, 0);
            long removed = 0;
            Dictionary<string, bool> dirs = new Dictionary<string, bool>(StringComparer.OrdinalIgnoreCase);
            DateTime last = DateTime.UtcNow;
            db.Begin();
            try
            {
                foreach (object[] r in rows)
                {
                    j.Check();
                    string rel = Util.S(r[1]);
                    string s = Fs.Join(source, rel), t = Fs.Join(target, rel);
                    j.Current = s;
                    try
                    {
                        FsEntry se = Fs.Info(s), tt = Fs.Info(t);
                        if (tt == null || tt.Size != Util.L(r[2])) throw new IOException("the target copy is gone or changed");
                        if (se == null || se.Size != Util.L(r[2])) throw new IOException("the source file changed since the verify");
                        Fs.DeleteFile(s);
                        db.Run("UPDATE vrows SET status='Removed' WHERE id=?", Util.L(r[0]));
                        removed++;
                        string p = Fs.Parent(s);
                        if (p != null) dirs[p] = true;
                    }
                    catch (OperationCanceledException) { throw; }
                    catch (Exception ex) { j.Errors++; j.Log("Not removed " + s + ": " + ex.Message); }
                    j.FilesDone++;
                    if ((DateTime.UtcNow - last).TotalSeconds > 3) { db.Commit(); db.Begin(); last = DateTime.UtcNow; }
                }
            }
            finally
            {
                db.Commit();
                // remove folders left empty, deepest first; the source folder itself stays if anything is left in it
                List<string> list = new List<string>(dirs.Keys);
                list.Sort(delegate(string a, string b) { return b.Length.CompareTo(a.Length); });
                foreach (string dpath in list)
                {
                    string p = dpath;
                    while (p != null && p.Length > source.TrimEnd('\\').Length && Fs.TryRemoveDir(p)) p = Fs.Parent(p);
                }
                Fs.TryRemoveDir(source);
                db.Run("UPDATE vruns SET removed=removed+? WHERE id=?", removed, runId);
                foreach (VolumeRow v in ReadVolumes(db))
                    if (v.DriveId > 0 && source.StartsWith(v.Root, StringComparison.OrdinalIgnoreCase)) db.Run("UPDATE drives SET needs_rescan=1 WHERE id=?", v.DriveId);
                j.Summary = "Removed " + removed.ToString("N0") + " verified source files. Run a quick scan of the source drive so the catalog matches.";
                j.Log(j.Summary);
            }
        }

        // ------------------------------------------------------------ exports

        public int ExportDuplicatesCsv(string path)
        {
            StringBuilder sb = new StringBuilder();
            sb.AppendLine("Group,Folder name,Status,Copies,Files,Size (bytes),Reclaim (bytes),Role,Drive,Path,Oldest file,Reason");
            int n = 0;
            foreach (object[] r in _db.Rows(@"SELECT g.id, g.name, g.confirmed, g.copies, g.files, g.bytes, g.reclaim, m.role, d.letter, d.label, m.path, m.oldest, m.reason
                    FROM dgroups g JOIN dmembers m ON m.group_id=g.id LEFT JOIN drives d ON d.id=m.drive_id ORDER BY g.reclaim DESC, g.id, CASE m.role WHEN 'Keep' THEN 0 WHEN 'Duplicate' THEN 1 ELSE 2 END, m.path"))
            {
                sb.AppendLine(string.Join(",", new string[] {
                    Util.S(r[0]), Util.Csv(Util.S(r[1])), Util.L(r[2]) != 0 ? "Content checked" : "Quick match only", Util.S(r[3]), Util.S(r[4]), Util.S(r[5]), Util.S(r[6]),
                    Util.Csv(Util.S(r[7])), Util.Csv(Util.S(r[8]) + " " + Util.S(r[9])), Util.Csv(Util.S(r[10])), Util.Date(Util.L(r[11])), Util.Csv(Util.S(r[12])) }));
                n++;
            }
            System.IO.File.WriteAllText(path, sb.ToString(), new UTF8Encoding(true));
            return n;
        }

        public int ExportBatchCsv(long batchId, string path)
        {
            StringBuilder sb = new StringBuilder();
            sb.AppendLine("Batch,Step,Kind,Drive,From,To,Status,Done,Size (bytes),Error");
            int n = 0;
            foreach (ActionRow a in GetActions(batchId, int.MaxValue))
            {
                sb.AppendLine(string.Join(",", new string[] { a.BatchId.ToString(), a.Seq.ToString(), a.Kind, Util.Csv(a.Drive), Util.Csv(a.Src), Util.Csv(a.Dst),
                    a.Status, a.Done, a.Bytes.ToString(), Util.Csv(a.Error) }));
                n++;
            }
            System.IO.File.WriteAllText(path, sb.ToString(), new UTF8Encoding(true));
            return n;
        }

        public void ExportHtml(string path, int maxGroups)
        {
            StringBuilder sb = new StringBuilder();
            sb.Append("<!doctype html><html><head><meta charset='utf-8'><title>File Manager report</title><style>");
            sb.Append("body{font-family:Segoe UI,Arial,sans-serif;margin:24px;color:#20262e}h1{color:#1f4e8c}h2{color:#1c5ca8;margin-top:28px}");
            sb.Append("table{border-collapse:collapse;width:100%;font-size:13px}th,td{border:1px solid #c5ced9;padding:4px 8px;text-align:left;vertical-align:top}");
            sb.Append("th{background:#d6e3f5}tr:nth-child(even){background:#f7f9fc}.keep{color:#1a7f37;font-weight:600}.dup{color:#b42318}.muted{color:#6c7682}");
            sb.Append("</style></head><body>");
            sb.Append("<h1>File Manager report</h1><p class='muted'>" + Util.Html(Util.Now()) + "  |  " + Util.Html(Stats()) + "</p>");
            sb.Append("<h2>Drives</h2><table><tr><th>Priority</th><th>Drive</th><th>Format</th><th>Size</th><th>Files</th><th>Data</th><th>Content-checked</th><th>Last scan</th></tr>");
            foreach (DriveRow d in GetDrives())
                sb.Append("<tr><td>" + d.Priority + "</td><td>" + Util.Html(d.Letter + " " + d.Label) + "</td><td>" + Util.Html(d.FileSystem) + "</td><td>" + Util.Size(d.TotalBytes) +
                          "</td><td>" + d.Files.ToString("N0") + "</td><td>" + Util.Size(d.Bytes) + "</td><td>" + d.Hashed.ToString("N0") + "</td><td>" + Util.Html(d.LastScan) + "</td></tr>");
            sb.Append("</table>");
            sb.Append("<h2>Duplicate folders</h2><p>" + GroupCount().ToString("N0") + " groups, " + Util.Size(ReclaimTotal()) + " to reclaim.</p>");
            sb.Append("<table><tr><th>Folder</th><th>Status</th><th>Copies</th><th>Size each</th><th>Reclaim</th><th>Copies (keep first)</th></tr>");
            foreach (GroupRow g in GetGroups(maxGroups))
            {
                StringBuilder m = new StringBuilder();
                foreach (MemberRow x in GetMembers(g.Id))
                    m.Append("<div class='" + (x.Role == "Keep" ? "keep" : (x.Role == "Duplicate" ? "dup" : "muted")) + "'>" + Util.Html(x.Role + ": " + x.Drive + "  \\" + x.Path) + "</div>");
                sb.Append("<tr><td>" + Util.Html(g.Name) + "</td><td>" + Util.Html(g.Status) + "</td><td>" + g.Copies + "</td><td>" + Util.Size(g.Bytes) + "</td><td>" + Util.Size(g.Reclaim) + "</td><td>" + m + "</td></tr>");
            }
            sb.Append("</table>");
            sb.Append("<h2>Batches</h2><table><tr><th>Batch</th><th>Built</th><th>Applied</th><th>Status</th><th>Moves</th><th>Done</th><th>Failed</th><th>Deleted</th><th>Undone</th></tr>");
            foreach (BatchRow b in GetBatches(200))
                sb.Append("<tr><td>" + b.Id + "</td><td>" + Util.Html(b.Created) + "</td><td>" + Util.Html(b.Applied) + "</td><td>" + Util.Html(b.Status) + "</td><td>" + b.Items +
                          "</td><td>" + b.Done + "</td><td>" + b.Failed + "</td><td>" + b.Deleted + "</td><td>" + b.Undone + "</td></tr>");
            sb.Append("</table></body></html>");
            System.IO.File.WriteAllText(path, sb.ToString(), new UTF8Encoding(false));
        }
    }
}
'@

function Get-FmCatalog {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $App)
    if ($script:FmCatalog) { return $script:FmCatalog }
    $dll = Join-Path $env:windir 'System32\winsqlite3.dll'
    if (-not (Test-Path -LiteralPath $dll)) {
        throw "File Manager needs Windows 10 (version 1607 or later) or Windows 11: $dll was not found."
    }
    if (-not ('FileManagerEngine.Catalog' -as [type])) {
        try { Add-Type -TypeDefinition $script:FmEngineSource -Language CSharp -ErrorAction Stop }
        catch {
            $App.Log('ERROR', 'FileManager', "The engine did not compile: $($_.Exception.Message)")
            throw
        }
    }
    $dir = Join-Path ([string]$App.LocalAppData) 'Catalog'
    $dbPath = Join-Path $dir 'FileManager.db'
    $cat = New-Object FileManagerEngine.Catalog -ArgumentList $dbPath
    $cat.Options = New-FmOptions -App $App
    $script:FmCatalog = $cat
    $App.Log('INFO', 'FileManager', "Catalog opened: $dbPath (file hash: $($cat.HashAlgorithm))")
    return $cat
}

function Get-FmSettings {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $App)
    # Default: compare EVERYTHING, so a copy only matches when its folder is identical.
    $s = [pscustomobject]@{
        SettingsVersion      = 2
        IgnoreFiles          = @()
        IgnoreFolders        = @()
        MinFolderKB          = 0
        ShowActionsAfterScan = $true
    }
    $path = Join-Path (Get-AppSettingsDir -App $App) 'FileManager.json'
    if (Test-Path -LiteralPath $path) {
        try {
            $j = [System.IO.File]::ReadAllText($path) | ConvertFrom-Json
            $v = $(if ($j.PSObject.Properties['SettingsVersion']) { [int]$j.SettingsVersion } else { 1 })
            foreach ($p in $s.PSObject.Properties) {
                if ($p.Name -eq 'SettingsVersion') { continue }
                # 1.0.x saved its default ignore lists; from 1.1 the default is to ignore nothing.
                if ($v -lt 2 -and ($p.Name -eq 'IgnoreFiles' -or $p.Name -eq 'IgnoreFolders')) { continue }
                if ($j.PSObject.Properties[$p.Name]) { $s.($p.Name) = $j.($p.Name) }
            }
        }
        catch { $App.Log('WARN', 'FileManager', "Settings file not readable, using defaults: $($_.Exception.Message)") }
    }
    $s.IgnoreFiles = @($s.IgnoreFiles | ForEach-Object { [string]$_ } | Where-Object { $_.Trim() })
    $s.IgnoreFolders = @($s.IgnoreFolders | ForEach-Object { [string]$_ } | Where-Object { $_.Trim() })
    return $s
}

function Save-FmSettings {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $App, [Parameter(Mandatory)] $Settings)
    $path = Join-Path (Get-AppSettingsDir -App $App) 'FileManager.json'
    [System.IO.File]::WriteAllText($path, ($Settings | ConvertTo-Json -Depth 4), (New-Object System.Text.UTF8Encoding($false)))
    if ($script:FmCatalog) { $script:FmCatalog.Options = New-FmOptions -App $App }
    $App.Log('INFO', 'FileManager', "Settings saved: $path")
}

function New-FmOptions {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $App, [switch]$ContentCheck, [switch]$HashAllSameSize, [switch]$IncludeQuick)
    $s = Get-FmSettings -App $App
    $o = New-Object FileManagerEngine.ScanOptions
    $o.ContentCheck = [bool]$ContentCheck
    $o.HashAllSameSize = [bool]$HashAllSameSize
    $o.IncludeQuick = [bool]$IncludeQuick
    $o.IgnoreFiles = [string[]]@($s.IgnoreFiles)
    $o.IgnoreFolders = [string[]]@($s.IgnoreFolders)
    $o.MinGroupBytes = [long]([Math]::Max(1, [double]$s.MinFolderKB * 1024))
    return $o
}
