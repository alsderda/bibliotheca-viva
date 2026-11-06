// Minimal installer: asks for a folder and unpacks the embedded payload.zip into it.
// Built by installer/build.sh with the C# compiler that ships with Windows (.NET Framework 4).
using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Windows.Forms;

[assembly: AssemblyTitle("Biblioth\u00e9ca-viva Setup")]
[assembly: AssemblyProduct("Biblioth\u00e9ca-viva")]

static class Setup
{
    const string AppName = "Biblioth\u00e9ca-viva";
    const string ExeName = "bibliotheca-viva.exe";

    [STAThread]
    static int Main(string[] args)
    {
        // Silent mode for scripts: Setup.exe /dir="C:\some\folder"
        foreach (string arg in args)
        {
            if (arg.StartsWith("/dir=", StringComparison.OrdinalIgnoreCase))
            {
                try { Install(arg.Substring(5).Trim('"')); return 0; }
                catch (Exception e) { Console.Error.WriteLine(e.Message); return 2; }
            }
        }

        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);

        string defaultDir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs", "Biblioth\u00e9ca-viva");
        string target = AskFolder(defaultDir);
        if (target == null)
            return 1;

        try
        {
            Install(target);
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

    // --- the window: "Install to: [path] [Browse...]  [Install] [Cancel]" ----------

    static string AskFolder(string defaultDir)
    {
        var form = new Form
        {
            Text = AppName + " Setup",
            FormBorderStyle = FormBorderStyle.FixedDialog,
            MaximizeBox = false,
            MinimizeBox = false,
            StartPosition = FormStartPosition.CenterScreen,
            AutoScaleMode = AutoScaleMode.Dpi,
            Font = SystemFonts.MessageBoxFont,
            ClientSize = new Size(520, 130),
            Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath),
        };
        var label = new Label { Text = "Install " + AppName + " to this folder:", Location = new Point(12, 14), AutoSize = true };
        var path = new TextBox { Text = defaultDir, Location = new Point(12, 38), Width = 400 };
        var browse = new Button { Text = "Browse...", Location = new Point(420, 36), Width = 88 };
        var install = new Button { Text = "Install", Location = new Point(324, 88), Width = 88, DialogResult = DialogResult.OK };
        var cancel = new Button { Text = "Cancel", Location = new Point(420, 88), Width = 88, DialogResult = DialogResult.Cancel };
        browse.Click += delegate
        {
            string picked = PickFolder(form.Handle, path.Text);
            if (picked != null) path.Text = picked;
        };
        form.Controls.AddRange(new Control[] { label, path, browse, install, cancel });
        form.AcceptButton = install;
        form.CancelButton = cancel;

        if (form.ShowDialog() != DialogResult.OK || path.Text.Trim() == "")
            return null;
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

    // --- unpacking --------------------------------------------------------------------

    static void Install(string target)
    {
        string root = Path.GetFullPath(target).TrimEnd('\\') + "\\";
        Directory.CreateDirectory(root);
        using (Stream payload = Assembly.GetExecutingAssembly().GetManifestResourceStream("payload.zip"))
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
            }
        }
    }
}
