using System;
using System.Runtime.InteropServices;

class NativeProbe
{
    [DllImport("kernel32", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr LoadLibrary(string path);
    [DllImport("kernel32")]
    static extern bool FreeLibrary(IntPtr module);

    static int Main()
    {
        string[] libraries = { "msvcr80.dll", "msvcp80.dll", "msvcr90.dll", "msvcp90.dll",
            "msvcr100.dll", "msvcp100.dll", "msvcr110.dll", "msvcp110.dll", "msvcr120.dll",
            "msvcp120.dll", "vcruntime140.dll", "msvcp140.dll",
            "mfc100.dll", "mfc110.dll", "mfc120.dll", "mfc140.dll",
            "vcomp100.dll", "vcomp110.dll", "vcomp120.dll", "vcomp140.dll" };
        foreach (var library in libraries) Check(library);
        if (IntPtr.Size == 4)
            foreach (var library in new[] { "msvcr70.dll", "msvcr71.dll", "msvbvm50.dll", "mscomctl.ocx" }) Check(library);
        return 0;
    }

    static void Check(string library)
    {
        var module = LoadLibrary(library);
        if (module == IntPtr.Zero)
            throw new Exception("LoadLibrary " + library + ": " + Marshal.GetLastWin32Error());
        FreeLibrary(module);
        Console.WriteLine("PASS: native " + library + " " + (IntPtr.Size * 8));
    }
}
