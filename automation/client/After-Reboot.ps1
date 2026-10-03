$root = Split-Path (Split-Path $PSScriptRoot)
. "$root/automation/Common.ps1"
. "$root/installer/Install.ps1"
$before = [datetime]::Parse((Get-Content "$root/reboot-pending.txt" -Raw))
if ((Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime() -le $before.ToUniversalTime()) { throw 'A real reboot was not observed.' }
$manifest = Get-Content "$root/.build/payload/manifest.json" -Raw | ConvertFrom-Json
$engine = New-Object -ComObject WindowsInstaller.Installer
try {
    foreach ($package in $manifest.packages | Where-Object { $_.family -ne 'vstor' -or $_.arch -eq 'x64' }) {
        $actual = Get-InstalledVersion $engine $package
        if (-not $actual -or $actual -lt [version] $package.version) { throw "Missing after reboot: $($package.id)" }
        if ($package.type -eq 'windowsdesktop') {
            $directory = if ($package.arch -eq 'x86') { ${env:ProgramFiles(x86)} } else { $env:ProgramFiles }
            $bits = if ($package.arch -eq 'x86') { '32' } else { '64' }
            Invoke-Checked "$directory\dotnet\dotnet.exe" @('exec', '--runtimeconfig', "$root/.build/probes/$($package.id).json",
                "$root/.build/probes/DesktopProbe.dll", $package.channel.Split('.')[0], $bits)
        }
    }
    foreach ($arch in @('x86', 'x64')) { Invoke-Checked "$root/.build/probes/NativeProbe-$arch.exe" @() }
    Write-Host 'PASS: all runtimes and applications after reboot'
} finally { $null = [Runtime.InteropServices.Marshal]::FinalReleaseComObject($engine) }
