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
            IntPtr handle = SendMessage(child.Handle, 0x0031, IntPtr.Zero, IntPtr.Zero);
            using (var font = handle == IntPtr.Zero ? (Font)SystemFonts.MessageBoxFont.Clone() : Font.FromHfont(handle)) {
                var measured = TextRenderer.MeasureText(child.Title, font,
                    new Size(Math.Max(1, child.Bounds.Width - 6), Int32.MaxValue), TextFormatFlags.WordBreak | TextFormatFlags.NoPrefix);
                if (measured.Height > child.Bounds.Height + 3) throw new Exception("Clipped control text: " + child.Title);
            }
        }
    }
}
