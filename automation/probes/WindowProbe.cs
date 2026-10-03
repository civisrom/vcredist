using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Forms;

public class RuntimeWindow {
    public IntPtr Handle;
    public string Title;
    public string ClassName;
    public Rectangle Bounds;
}

public static class RuntimeWindowProbe {
    private delegate bool WindowCallback(IntPtr window, IntPtr parameter);
    [StructLayout(LayoutKind.Sequential)] private struct Rect { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] private static extern bool EnumWindows(WindowCallback callback, IntPtr parameter);
    [DllImport("user32.dll")] private static extern bool EnumChildWindows(IntPtr parent, WindowCallback callback, IntPtr parameter);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll")] private static extern bool GetWindowRect(IntPtr window, out Rect rectangle);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowText(IntPtr window, StringBuilder text, int maximum);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetClassName(IntPtr window, StringBuilder text, int maximum);
    [DllImport("user32.dll")] private static extern IntPtr SendMessage(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] private static extern bool PostMessage(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] private static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll")] private static extern bool PrintWindow(IntPtr window, IntPtr context, uint flags);
    [DllImport("user32.dll")] private static extern IntPtr GetDC(IntPtr window);
    [DllImport("user32.dll")] private static extern int ReleaseDC(IntPtr window, IntPtr context);
    [DllImport("gdi32.dll")] private static extern IntPtr SelectObject(IntPtr context, IntPtr value);
    [DllImport("gdi32.dll", CharSet = CharSet.Unicode)] private static extern int GetObject(IntPtr value, int size, byte[] data);
    [DllImport("gdi32.dll", CharSet = CharSet.Unicode)] private static extern IntPtr CreateFontIndirect(byte[] font);
    [DllImport("gdi32.dll")] private static extern bool DeleteObject(IntPtr value);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int DrawText(IntPtr context, string text, int count, ref Rect rectangle, uint format);

    private static RuntimeWindow Describe(IntPtr window) {
        var text = new StringBuilder(4096);
        GetWindowText(window, text, text.Capacity);
        var name = new StringBuilder(256);
        GetClassName(window, name, name.Capacity);
        Rect bounds;
        GetWindowRect(window, out bounds);
        return new RuntimeWindow { Handle = window, Title = text.ToString(), ClassName = name.ToString(),
            Bounds = Rectangle.FromLTRB(bounds.Left, bounds.Top, bounds.Right, bounds.Bottom) };
    }

    public static RuntimeWindow[] Windows(IntPtr parent) {
        var windows = new List<RuntimeWindow>();
        WindowCallback callback = (window, parameter) => { if (IsWindowVisible(window)) windows.Add(Describe(window)); return true; };
        if (parent == IntPtr.Zero) EnumWindows(callback, IntPtr.Zero);
        else EnumChildWindows(parent, callback, IntPtr.Zero);
        return windows.ToArray();
    }

    public static void Click(IntPtr window) { PostMessage(window, 0x00F5, IntPtr.Zero, IntPtr.Zero); }

    public static void Capture(RuntimeWindow window, string path) {
        SetForegroundWindow(window.Handle);
        System.Threading.Thread.Sleep(120);
        using (var bitmap = new Bitmap(window.Bounds.Width, window.Bounds.Height)) {
            using (var graphics = Graphics.FromImage(bitmap)) {
                IntPtr dc = graphics.GetHdc();
                bool printed;
                try { printed = PrintWindow(window.Handle, dc, 2); }
                finally { graphics.ReleaseHdc(dc); }
                if (!printed) graphics.CopyFromScreen(window.Bounds.Location, Point.Empty, bitmap.Size);
            }
            bitmap.Save(path, ImageFormat.Png);
        }
    }

    public static void AssertTextFits(RuntimeWindow window) {
        var title = TextRenderer.MeasureText(window.Title, SystemFonts.CaptionFont);
        if (title.Width > window.Bounds.Width - 130) throw new Exception("Clipped window title: " + window.Title);
        foreach (var child in Windows(window.Handle)) {
            if (String.IsNullOrWhiteSpace(child.Title)) continue;
            string kind = child.ClassName.ToLowerInvariant();
            if (!(kind.Contains("static") || kind.Contains("button") || kind.Contains("richedit"))) continue;
            if (!window.Bounds.Contains(child.Bounds)) throw new Exception("Control outside window: " + child.Title);
            Control managed = Control.FromHandle(child.Handle);
            if (managed is Label || managed is Button) {
                // Owner-painted WinForms controls do not expose their font through
                // WM_GETFONT. In-process tests can use their actual layout engine.
                Size preferred = managed.GetPreferredSize(new Size(managed.Width, 0));
                if (preferred.Height > managed.Height + 1 ||
                    (managed is Button && managed.GetPreferredSize(Size.Empty).Width > managed.Width + 1))
                    throw new Exception("Clipped control text: " + child.Title + " (WinForms preferred " + preferred + ", control " + managed.Size + ")");
                continue;
            }
            IntPtr handle = SendMessage(child.Handle, 0x0031, IntPtr.Zero, IntPtr.Zero);
            // In a different process these owner-painted controls expose geometry,
            // but not text metrics. Test-Interface checks them in-process at four
            // font sizes; Test-InteractiveInstall also captures every real stage.
            if (handle == IntPtr.Zero && kind.StartsWith("windowsforms")) continue;
            // SFX dialogs also use raster fonts, which Font.FromHfont cannot represent.
            // Measure with the actual native font rather than substituting a TrueType font.
            IntPtr dc = GetDC(child.Handle);
            if (dc == IntPtr.Zero) throw new Exception("Cannot measure control: " + child.Title);
            IntPtr previous = IntPtr.Zero;
            IntPtr localFont = IntPtr.Zero;
            string fontDescription = "default SYSTEM_FONT (WM_GETFONT returned zero)";
            try {
                if (handle != IntPtr.Zero) {
                    // A font handle from WM_GETFONT belongs to the other process.
                    // Read its LOGFONT and create a font owned by this probe.
                    var description = new byte[92]; // LOGFONTW
                    if (GetObject(handle, description.Length, description) == 0)
                        throw new Exception("Cannot read control font: " + child.Title);
                    fontDescription = Encoding.Unicode.GetString(description, 28, 64).TrimEnd('\0') + ", height " + BitConverter.ToInt32(description, 0);
                    localFont = CreateFontIndirect(description);
                    if (localFont == IntPtr.Zero) throw new Exception("Cannot create measurement font.");
                    previous = SelectObject(dc, localFont);
                    if (previous == IntPtr.Zero) throw new Exception("Cannot select measurement font.");
                }
                var measured = new Rect { Right = Math.Max(1, child.Bounds.Width - (kind.Contains("button") ? 6 : 0)) };
                uint flags = 0x0400 | 0x0010; // DT_CALCRECT | DT_WORDBREAK
                if (!kind.Contains("button")) flags |= 0x0800; // DT_NOPREFIX
                if (DrawText(dc, child.Title, child.Title.Length, ref measured, flags) == 0)
                    throw new Exception("Cannot measure control text: " + child.Title);
                if (measured.Bottom > child.Bounds.Height + 3 || measured.Right > child.Bounds.Width)
                    throw new Exception("Clipped control text: " + child.Title + " (measured " + measured.Right + "x" + measured.Bottom + ", control " + child.Bounds.Size + ", font " + fontDescription + ", class " + child.ClassName + ")");
            } finally {
                if (previous != IntPtr.Zero) SelectObject(dc, previous);
                if (localFont != IntPtr.Zero) DeleteObject(localFont);
                ReleaseDC(child.Handle, dc);
            }
        }
    }
}
