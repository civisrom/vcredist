param()
$ErrorActionPreference = 'Stop'
$env:PSModulePath = Join-Path $PSHOME 'Modules'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -Path "$PSScriptRoot/probes/WindowProbe.cs" -ReferencedAssemblies System, System.Drawing, System.Windows.Forms
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class NativeTextFixture {
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr CreateWindowEx(uint exStyle, string className, string text, uint style,
        int x, int y, int width, int height, IntPtr parent, IntPtr menu, IntPtr instance, IntPtr parameter);
    [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);
    [DllImport("gdi32.dll")] public static extern IntPtr GetStockObject(int index);
    [DllImport("user32.dll")] public static extern bool DestroyWindow(IntPtr window);
}
'@

$form = New-Object Windows.Forms.Form
$form.Text = 'Font measurement regression'
$form.ClientSize = New-Object Drawing.Size(600, 300)
try {
    $form.Show()
    [Windows.Forms.Application]::DoEvents()
    $window = [RuntimeWindowProbe]::Windows([IntPtr]::Zero) | Where-Object Handle -eq $form.Handle
    # SYSTEM_FONT is a real raster font; DEFAULT_GUI_FONT is the modern UI font.
    foreach ($fontId in @(13, 17)) {
        foreach ($height in @(120, 4)) {
            $control = [NativeTextFixture]::CreateWindowEx(0, 'STATIC', 'Native font measurement with multiple words wrapping onto several lines.',
                0x50000000, 10, 10, 200, $height, $form.Handle, [IntPtr]::Zero, [IntPtr]::Zero, [IntPtr]::Zero)
            if ($control -eq [IntPtr]::Zero) { throw 'Cannot create the native text fixture.' }
            try {
                $null = [NativeTextFixture]::SendMessage($control, 0x0030, [NativeTextFixture]::GetStockObject($fontId), [IntPtr]::Zero)
                $clipped = $false
                try { [RuntimeWindowProbe]::AssertTextFits($window) }
                catch {
                    if ($_.Exception.ToString() -notlike '*Clipped control text:*') { throw }
                    $clipped = $true
                }
                if ($clipped -ne ($height -eq 4)) { throw "Incorrect text measurement: font $fontId, height $height" }
                Write-Host "PASS: native text measurement, font $fontId, height $height"
            } finally { $null = [NativeTextFixture]::DestroyWindow($control) }
        }
    }
} finally { $form.Dispose() }
