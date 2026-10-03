param([Parameter(Mandatory)] [string] $Source, [Parameter(Mandatory)] [string] $Destination)
$ErrorActionPreference = 'Stop'
Copy-Item -LiteralPath $Source -Destination $Destination
Add-Type @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
public static class RuntimeSfxLayout {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr BeginUpdateResource(string path, bool deleteExisting);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool UpdateResource(IntPtr update, IntPtr type, IntPtr name, ushort language, IntPtr data, uint size);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool EndUpdateResource(IntPtr update, bool discard);
    public static void UseAutomaticLayout(string path) {
        IntPtr update = BeginUpdateResource(path, false);
        if (update == IntPtr.Zero) throw new Win32Exception();
        try {
            // The bundled module's fixed English extraction/help templates ignore
            // text length and ExtractDialogWidth. Their absence selects its built-in
            // layout, which measures text and uses the current Windows dialog font.
            foreach (int id in new int[] { 2004, 2006 }) {
                if (!UpdateResource(update, new IntPtr(5), new IntPtr(id), 1033, IntPtr.Zero, 0))
                    throw new Win32Exception();
            }
            if (!EndUpdateResource(update, false)) throw new Win32Exception();
            update = IntPtr.Zero;
        } finally { if (update != IntPtr.Zero) EndUpdateResource(update, true); }
    }
}
'@
[RuntimeSfxLayout]::UseAutomaticLayout([IO.Path]::GetFullPath($Destination))
