using System;
using System.Windows.Controls;

class DesktopProbe
{
    [STAThread]
    static int Main(string[] args)
    {
        if (Environment.Version.Major != int.Parse(args[0]) || IntPtr.Size * 8 != int.Parse(args[1]))
            throw new Exception("Wrong runtime or architecture: " + Environment.Version + "/" + IntPtr.Size);
        var wpf = new Button { Content = "WPF" };
        using (var forms = new System.Windows.Forms.Button { Text = "WinForms" })
        {
            if ((string)wpf.Content != "WPF" || forms.Text != "WinForms") return 1;
            forms.CreateControl();
        }
        Console.WriteLine("PASS: CoreCLR + WPF + WinForms " + Environment.Version + " " + (IntPtr.Size * 8));
        return 0;
    }
}
