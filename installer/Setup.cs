// Minimal installer and uninstaller for Windows, built by installer/build.sh with the C# compiler that ships
// with Windows (.NET Framework 4). The same source is compiled twice:
//   uninstall.exe  no embedded payload, so it runs as the uninstaller
//   Setup.exe      embeds payload.zip (the app) and uninstall.exe
// Setup unpacks the app into a folder, adds a Start menu shortcut (and a desktop one if asked), copies
// uninstall.exe next to the app and registers it in Windows' list of installed apps, all per user (no admin).
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using System.Text;
using System.Windows.Forms;
using Microsoft.Win32;

[assembly: AssemblyTitle("Biblioth\u00e9ca-viva Setup")]
[assembly: AssemblyProduct("Biblioth\u00e9ca-viva")]

static class Setup
{
    const string AppName = "Biblioth\u00e9ca-viva";
    const string ExeName = "bibliotheca-viva.exe";
    const string UninstallerName = "uninstall.exe";
    // Lists every file Setup unpacked, so the uninstaller removes only those, even if the folder holds other things.
    const string FileListName = "uninstall.files";
    const string ShortcutName = AppName + ".lnk";
    const string UninstallKey = @"Software\Microsoft\Windows\CurrentVersion\Uninstall\bibliotheca-viva";
    // The app's library and settings (Godot's custom user dir, see project.godot).
    const string DataDirName = "bibliotheca-viva";

    [STAThread]
    static int Main(string[] args)
    {
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        bool isSetup = Assembly.GetExecutingAssembly().GetManifestResourceInfo("payload.zip") != null;
        return isSetup ? RunSetup(args) : RunUninstall(args);
    }

    static bool HasArg(string[] args, string name)
    {
        foreach (string arg in args)
            if (string.Equals(arg, name, StringComparison.OrdinalIgnoreCase)) return true;
        return false;
    }

    // === Setup ========================================================================

    static int RunSetup(string[] args)
    {
        // Silent mode for scripts: Setup.exe "/dir=C:\some\folder" [/desktop]
        foreach (string arg in args)
        {
            if (arg.StartsWith("/dir=", StringComparison.OrdinalIgnoreCase))
            {
                try { Install(arg.Substring(5).Trim('"'), HasArg(args, "/desktop") ? true : (bool?)null); return 0; }
                catch (Exception e) { Console.Error.WriteLine(e.Message); return 2; }
            }
        }

        // An update goes to the folder of the existing install by default.
        string defaultDir = RegisteredInstallDir() ?? Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs", AppName);
        bool desktop = File.Exists(DesktopShortcut());
        string target = AskFolder(defaultDir, ref desktop);
        if (target == null)
            return 1;

        try
        {
            Install(target, desktop);
        }
        catch (Exception e)
        {
            MessageBox.Show("Installation failed:\n\n" + e.Message, AppName + " Setup",
                MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 2;
        }

        var answer = MessageBox.Show(
            AppName + " was installed to:\n" + target + "\n\n" +
            "Start " + AppName + " now?",
            AppName + " Setup", MessageBoxButtons.YesNo, MessageBoxIcon.Information);
        if (answer == DialogResult.Yes)
            Process.Start(new ProcessStartInfo(Path.Combine(target, ExeName)) { WorkingDirectory = target });
        return 0;
    }

    static Form MakeDialog(string title, int height)
    {
        return new Form
        {
            Text = title,
            FormBorderStyle = FormBorderStyle.FixedDialog,
            MaximizeBox = false,
            MinimizeBox = false,
            StartPosition = FormStartPosition.CenterScreen,
            AutoScaleMode = AutoScaleMode.Dpi,
            Font = SystemFonts.MessageBoxFont,
            ClientSize = new Size(520, height),
            Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath),
        };
    }

    // "Install to: [path] [Browse...]  [x] Desktop shortcut  [Install] [Cancel]"
    static string AskFolder(string defaultDir, ref bool desktop)
    {
        var form = MakeDialog(AppName + " Setup", 160);
        var label = new Label { Text = "Install " + AppName + " to this folder:", Location = new Point(12, 14), AutoSize = true };
        var path = new TextBox { Text = defaultDir, Location = new Point(12, 38), Width = 400 };
        var browse = new Button { Text = "Browse...", Location = new Point(420, 36), Width = 88 };
        var shortcut = new CheckBox { Text = "Create a desktop shortcut", Location = new Point(12, 74), AutoSize = true, Checked = desktop };
        var install = new Button { Text = "Install", Location = new Point(324, 118), Width = 88, DialogResult = DialogResult.OK };
        var cancel = new Button { Text = "Cancel", Location = new Point(420, 118), Width = 88, DialogResult = DialogResult.Cancel };
        browse.Click += delegate
        {
            string picked = PickFolder(form.Handle, path.Text);
            if (picked != null) path.Text = picked;
        };
        form.Controls.AddRange(new Control[] { label, path, browse, shortcut, install, cancel });
        form.AcceptButton = install;
        form.CancelButton = cancel;

        if (form.ShowDialog() != DialogResult.OK || path.Text.Trim() == "")
            return null;
        desktop = shortcut.Checked;
        return path.Text.Trim().Trim('"');
    }

    // Modern Explorer-style folder picker (IFileOpenDialog with FOS_PICKFOLDERS).
    static string PickFolder(IntPtr owner, string start)
    {
        var dialog = (IFileOpenDialog)new FileOpenDialog();
        try
        {
            dialog.SetOptions(0x20 | 0x40 | 0x800); // PICKFOLDERS | FORCEFILESYSTEM | PATHMUSTEXIST
            dialog.SetTitle("Choose the install folder");
            // Start in the nearest folder that exists.
            string dir = start;
            while (!string.IsNullOrEmpty(dir) && !Directory.Exists(dir)) dir = Path.GetDirectoryName(dir);
            IShellItem folder;
            if (!string.IsNullOrEmpty(dir) &&
                SHCreateItemFromParsingName(dir, IntPtr.Zero, typeof(IShellItem).GUID, out folder) == 0)
                dialog.SetFolder(folder);

            if (dialog.Show(owner) != 0) return null; // cancelled
            IShellItem result;
            dialog.GetResult(out result);
            string picked;
            result.GetDisplayName(0x80058000, out picked); // SIGDN_FILESYSPATH
            return picked;
        }
        catch (COMException) { return null; }
        finally { Marshal.ReleaseComObject(dialog); }
    }

    // desktop: true adds a desktop shortcut, false removes it, null leaves it as it is.
    static void Install(string target, bool? desktop)
    {
        string root = Path.GetFullPath(target).TrimEnd('\\') + "\\";
        Directory.CreateDirectory(root);
        var assembly = Assembly.GetExecutingAssembly();

        // Keep the files of earlier versions in the list too, so uninstalling removes those as well.
        var files = new SortedSet<string>(StringComparer.OrdinalIgnoreCase);
        string listPath = root + FileListName;
        if (File.Exists(listPath))
            foreach (string line in File.ReadAllLines(listPath))
                if (line.Trim() != "") files.Add(line.Trim());

        long bytes = 0;
        using (Stream payload = assembly.GetManifestResourceStream("payload.zip"))
        using (var zip = new ZipArchive(payload, ZipArchiveMode.Read))
        {
            foreach (ZipArchiveEntry entry in zip.Entries)
            {
                string dest = Path.GetFullPath(Path.Combine(root, entry.FullName));
                if (!dest.StartsWith(root, StringComparison.OrdinalIgnoreCase))
                    continue; // ignore entries that would land outside the folder
                if (entry.FullName.EndsWith("/"))
                {
                    Directory.CreateDirectory(dest);
                    continue;
                }
                Directory.CreateDirectory(Path.GetDirectoryName(dest));
                entry.ExtractToFile(dest, true); // overwrite = update an existing install
                files.Add(dest.Substring(root.Length));
                bytes += entry.Length;
            }
        }

        using (Stream uninstaller = assembly.GetManifestResourceStream(UninstallerName))
        using (Stream file = File.Create(root + UninstallerName))
        {
            uninstaller.CopyTo(file);
            bytes += file.Length;
        }
        File.WriteAllLines(listPath, files);

        string exe = root + ExeName;
        CreateShortcut(StartMenuShortcut(), exe, root);
        if (desktop == true) CreateShortcut(DesktopShortcut(), exe, root);
        else if (desktop == false) DeleteFile(DesktopShortcut());

        Register(root, bytes);
    }

    // --- Windows' list of installed apps (per user) ---------------------------------------

    static void Register(string root, long bytes)
    {
        string uninstaller = "\"" + root + UninstallerName + "\"";
        using (RegistryKey key = Registry.CurrentUser.CreateSubKey(UninstallKey))
        {
            key.SetValue("DisplayName", AppName);
            key.SetValue("DisplayVersion", BuildInfo.Version);
            key.SetValue("Publisher", "alsderda");
            key.SetValue("URLInfoAbout", "https://github.com/alsderda/bibliotheca-viva");
            key.SetValue("DisplayIcon", "\"" + root + ExeName + "\",0");
            key.SetValue("InstallLocation", root.TrimEnd('\\'));
            key.SetValue("InstallDate", DateTime.Now.ToString("yyyyMMdd"));
            key.SetValue("UninstallString", uninstaller);
            key.SetValue("QuietUninstallString", uninstaller + " /silent");
            key.SetValue("EstimatedSize", (int)(bytes / 1024), RegistryValueKind.DWord); // in KB
            key.SetValue("NoModify", 1, RegistryValueKind.DWord);
            key.SetValue("NoRepair", 1, RegistryValueKind.DWord);
        }
    }

    static string RegisteredInstallDir()
    {
        using (RegistryKey key = Registry.CurrentUser.OpenSubKey(UninstallKey))
        {
            string dir = key == null ? null : key.GetValue("InstallLocation") as string;
            return string.IsNullOrEmpty(dir) ? null : dir;
        }
    }

    // --- shortcuts ------------------------------------------------------------------------

    static string StartMenuShortcut()
    {
        return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Programs), ShortcutName);
    }

    static string DesktopShortcut()
    {
        return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory), ShortcutName);
    }

    static void CreateShortcut(string lnk, string exe, string workingDir)
    {
        var link = (IShellLinkW)new ShellLink();
        try
        {
            link.SetPath(exe);
            link.SetWorkingDirectory(workingDir.TrimEnd('\\'));
            link.SetIconLocation(exe, 0);
            link.SetDescription(AppName);
            Directory.CreateDirectory(Path.GetDirectoryName(lnk));
            ((IPersistFile)link).Save(lnk, true);
        }
        finally { Marshal.ReleaseComObject(link); }
    }

    // === Uninstall ====================================================================
    // uninstall.exe [/silent [/purge]]   /silent: no windows; /purge: also delete the library and settings

    static int RunUninstall(string[] args)
    {
        bool silent = HasArg(args, "/silent");
        bool purge = HasArg(args, "/purge");
        string root = Path.GetDirectoryName(Path.GetFullPath(Application.ExecutablePath)).TrimEnd('\\') + "\\";
        string dataDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), DataDirName);
        // Don't hold the install folder open, or it can't be removed.
        Directory.SetCurrentDirectory(Path.GetTempPath());

        if (!silent && !AskUninstall(root, dataDir, out purge))
            return 1;

        while (IsLocked(root + ExeName))
        {
            if (silent) { Console.Error.WriteLine(AppName + " is running."); return 3; }
            var retry = MessageBox.Show(AppName + " is still running. Close it, then click Retry.",
                AppName + " Uninstall", MessageBoxButtons.RetryCancel, MessageBoxIcon.Warning);
            if (retry != DialogResult.Retry) return 1;
        }

        try
        {
            Uninstall(root);
            if (purge && Directory.Exists(dataDir)) Directory.Delete(dataDir, true);
        }
        catch (Exception e)
        {
            if (silent) Console.Error.WriteLine(e.Message);
            else MessageBox.Show("Uninstalling failed:\n\n" + e.Message, AppName + " Uninstall",
                MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 2;
        }

        DeleteSelfLater(root);
        if (!silent)
            MessageBox.Show(AppName + " was removed from your computer.", AppName + " Uninstall",
                MessageBoxButtons.OK, MessageBoxIcon.Information);
        return 0;
    }

    static bool AskUninstall(string root, string dataDir, out bool purge)
    {
        var form = MakeDialog(AppName + " Uninstall", 150);
        var label = new Label
        {
            Text = "Remove " + AppName + " from " + root.TrimEnd('\\') + "?",
            Location = new Point(12, 14), MaximumSize = new Size(496, 0), AutoSize = true,
        };
        var data = new CheckBox
        {
            Text = "Also delete my library and settings (" + dataDir + ")",
            Location = new Point(12, 64), MaximumSize = new Size(496, 0), AutoSize = true,
            Enabled = Directory.Exists(dataDir),
        };
        var remove = new Button { Text = "Uninstall", Location = new Point(324, 108), Width = 88, DialogResult = DialogResult.OK };
        var cancel = new Button { Text = "Cancel", Location = new Point(420, 108), Width = 88, DialogResult = DialogResult.Cancel };
        form.Controls.AddRange(new Control[] { label, data, remove, cancel });
        form.AcceptButton = remove;
        form.CancelButton = cancel;
        bool ok = form.ShowDialog() == DialogResult.OK;
        purge = ok && data.Checked;
        return ok;
    }

    static bool IsLocked(string file)
    {
        if (!File.Exists(file)) return false;
        try { using (File.Open(file, FileMode.Open, FileAccess.ReadWrite, FileShare.None)) return false; }
        catch (IOException) { return true; }
    }

    static void Uninstall(string root)
    {
        var dirs = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        string listPath = root + FileListName;
        if (File.Exists(listPath))
        {
            foreach (string line in File.ReadAllLines(listPath))
            {
                if (line.Trim() == "") continue;
                string file = Path.GetFullPath(Path.Combine(root, line.Trim()));
                if (!file.StartsWith(root, StringComparison.OrdinalIgnoreCase)) continue;
                DeleteFile(file);
                for (string d = Path.GetDirectoryName(file); d.Length > root.Length; d = Path.GetDirectoryName(d))
                    dirs.Add(d);
            }
            File.Delete(listPath);
        }
        // The embedded browser (WebView2) keeps its cache next to the exe.
        string webCache = root + ExeName + ".WebView2";
        if (Directory.Exists(webCache)) Directory.Delete(webCache, true);

        // Remove the subfolders that are now empty, deepest first.
        var sorted = new List<string>(dirs);
        sorted.Sort((a, b) => b.Length.CompareTo(a.Length));
        foreach (string d in sorted)
            if (Directory.Exists(d) && Directory.GetFileSystemEntries(d).Length == 0)
                Directory.Delete(d);

        DeleteFile(StartMenuShortcut());
        DeleteFile(DesktopShortcut());
        Registry.CurrentUser.DeleteSubKeyTree(UninstallKey, false);
    }

    static void DeleteFile(string file)
    {
        if (File.Exists(file)) File.Delete(file);
    }

    // A running program can't delete its own exe, so a hidden cmd waits a moment, then removes
    // uninstall.exe and the install folder (rmdir only removes it if it's empty).
    static void DeleteSelfLater(string root)
    {
        string dir = root.TrimEnd('\\');
        Process.Start(new ProcessStartInfo("cmd.exe",
            "/c ping -n 3 127.0.0.1 >nul & del /f /q \"" + root + UninstallerName + "\" & rmdir \"" + dir + "\"")
        {
            CreateNoWindow = true,
            UseShellExecute = false,
            WindowStyle = ProcessWindowStyle.Hidden,
            WorkingDirectory = Path.GetTempPath(),
        });
    }

    // === COM interop ==================================================================

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = true)]
    static extern int SHCreateItemFromParsingName(string path, IntPtr pbc, [MarshalAs(UnmanagedType.LPStruct)] Guid riid, out IShellItem item);

    [ComImport, Guid("DC1C5A9C-E88A-4dde-A5A1-60F82A20AEF7")]
    class FileOpenDialog { }

    [ComImport, Guid("42f85136-db7e-439c-85f1-e4075d135fc8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IFileOpenDialog
    {
        [PreserveSig] int Show(IntPtr owner);
        void SetFileTypes(uint count, IntPtr specs);
        void SetFileTypeIndex(uint index);
        void GetFileTypeIndex(out uint index);
        void Advise(IntPtr events, out uint cookie);
        void Unadvise(uint cookie);
        void SetOptions(uint options);
        void GetOptions(out uint options);
        void SetDefaultFolder(IShellItem item);
        void SetFolder(IShellItem item);
        void GetFolder(out IShellItem item);
        void GetCurrentSelection(out IShellItem item);
        void SetFileName([MarshalAs(UnmanagedType.LPWStr)] string name);
        void GetFileName([MarshalAs(UnmanagedType.LPWStr)] out string name);
        void SetTitle([MarshalAs(UnmanagedType.LPWStr)] string title);
        void SetOkButtonLabel([MarshalAs(UnmanagedType.LPWStr)] string text);
        void SetFileNameLabel([MarshalAs(UnmanagedType.LPWStr)] string label);
        void GetResult(out IShellItem item);
        // (remaining methods unused)
    }

    [ComImport, Guid("43826D1E-E718-42EE-BC55-A1E261C37BFE"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IShellItem
    {
        void BindToHandler(IntPtr pbc, ref Guid bhid, ref Guid riid, out IntPtr ppv);
        void GetParent(out IShellItem parent);
        void GetDisplayName(uint sigdn, [MarshalAs(UnmanagedType.LPWStr)] out string name);
        void GetAttributes(uint mask, out uint attribs);
        void Compare(IShellItem other, uint hint, out int order);
    }

    [ComImport, Guid("00021401-0000-0000-C000-000000000046")]
    class ShellLink { }

    // All methods in vtable order; only the setters are used.
    [ComImport, Guid("000214F9-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IShellLinkW
    {
        void GetPath([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder file, int size, IntPtr findData, uint flags);
        void GetIDList(out IntPtr pidl);
        void SetIDList(IntPtr pidl);
        void GetDescription([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder name, int size);
        void SetDescription([MarshalAs(UnmanagedType.LPWStr)] string name);
        void GetWorkingDirectory([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder dir, int size);
        void SetWorkingDirectory([MarshalAs(UnmanagedType.LPWStr)] string dir);
        void GetArguments([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder args, int size);
        void SetArguments([MarshalAs(UnmanagedType.LPWStr)] string args);
        void GetHotkey(out short hotkey);
        void SetHotkey(short hotkey);
        void GetShowCmd(out int showCmd);
        void SetShowCmd(int showCmd);
        void GetIconLocation([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder path, int size, out int index);
        void SetIconLocation([MarshalAs(UnmanagedType.LPWStr)] string path, int index);
        void SetRelativePath([MarshalAs(UnmanagedType.LPWStr)] string path, uint reserved);
        void Resolve(IntPtr hwnd, uint flags);
        void SetPath([MarshalAs(UnmanagedType.LPWStr)] string file);
    }
}
