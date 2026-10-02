param([string] $WorkDirectory = (Join-Path (Split-Path $PSScriptRoot) '.build'))
. "$PSScriptRoot/Common.ps1"
$work = [IO.Path]::GetFullPath($WorkDirectory)
$payload = Join-Path $work 'payload'
$exe = Join-Path $work 'dist/Runtimes_AIO_x86_x64.exe'
$manifest = Get-Content (Join-Path $payload 'manifest.json') -Raw | ConvertFrom-Json
. "$PSScriptRoot/../installer/Install.ps1"
$engine = New-Object -ComObject WindowsInstaller.Installer

function Assert-Installed {
    foreach ($package in $manifest.packages) {
        if ($package.family -eq 'vstor' -and $package.arch -eq 'x86') { continue }
        $actual = Get-InstalledVersion $engine $package
        if (-not $actual -or $actual -lt [version] $package.version) {
            throw "Not installed: $($package.id), expected $($package.version), actual $actual"
        }
        Write-Host "PASS: $($package.id) $actual"
    }
    foreach ($file in @('msvcp100.dll', 'msvcp110.dll', 'msvcp120.dll', 'msvcp140.dll')) {
        foreach ($system in @('System32', 'SysWOW64')) {
            if (-not (Test-Path "$env:SystemRoot/$system/$file")) { throw "Runtime DLL missing: $system/$file" }
        }
    }
    foreach ($file in @('msvcr70.dll', 'msvcr71.dll', 'msvbvm50.dll', 'mscomctl.ocx')) {
        if (-not (Test-Path "$env:SystemRoot/SysWOW64/$file")) { throw "Legacy DLL missing: $file" }
    }
}

try {
    # Exercise the actual SFX + native PowerShell launcher, not only extracted MSI.
    foreach ($round in @(1, 2)) {
        $process = Start-Process $exe -ArgumentList '/ai /gm2' -Wait -PassThru
        if ($process.ExitCode -notin @(0, 3010)) { throw "SFX run $round failed: $($process.ExitCode)" }
        Assert-Installed
    }
    # A corrupt payload must be rejected even in the read-only preflight mode.
    $script = Join-Path $payload 'Install.ps1'
    $target = Join-Path $payload $manifest.packages[0].path
    $original = [IO.File]::ReadAllBytes($target)
    try {
        [IO.File]::WriteAllBytes($target, [byte[]] @(0, 1, 2))
        $process = Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$script`" -Mode check" -Wait -PassThru
        if ($process.ExitCode -eq 0) { throw 'Corrupt MSI was accepted.' }
    } finally { [IO.File]::WriteAllBytes($target, $original) }
    $process = Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$script`" -Mode update -Quiet" -Wait -PassThru
    if ($process.ExitCode -notin @(0, 3010)) { throw "Update failed: $($process.ExitCode)" }
    Assert-Installed
    Write-Host 'SFX installation, repeat run, integrity rejection and update passed.'
} finally { $null = [Runtime.InteropServices.Marshal]::FinalReleaseComObject($engine) }
