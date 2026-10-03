# Reproduce the original MSI + KB2565063 installation before the slower VM matrix.
. "$PSScriptRoot/Common.ps1"
if ($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted') {
    throw 'Destructive upgrade tests require a disposable GitHub-hosted runner.'
}
. "$PSScriptRoot/../installer/Install.ps1"
$work = Join-Path (Split-Path $PSScriptRoot) '.build'
$payload = Join-Path $work 'payload'
$manifest = Get-Content "$payload/manifest.json" -Raw | ConvertFrom-Json
$packages = @($manifest.packages | Where-Object family -eq '2010')
if ($packages.Count -ne 2) { throw 'Expected both VC2010 architectures.' }
$directory = Join-Path $work 'vc2010-upgrade'
$null = New-Item -ItemType Directory $directory
$sources = Get-Content "$PSScriptRoot/upgrade-sources.json" -Raw | ConvertFrom-Json

function Invoke-Vc2010Process([string] $File, [string] $Arguments) {
    $process = Start-Process $File -ArgumentList $Arguments -NoNewWindow -PassThru
    if (-not $process.WaitForExit(600000)) {
        & taskkill.exe /pid $process.Id /t /f | Out-Host
        throw "VC2010 process timed out: $File"
    }
    $process.Refresh()
    if ($process.ExitCode -notin @(0, 3010)) { throw "VC2010 process failed: $File ($($process.ExitCode))" }
}

$engine = New-Object -ComObject WindowsInstaller.Installer
try {
    foreach ($package in $packages) {
        if ($engine.ProductState($package.productCode) -eq 5) {
            Invoke-Vc2010Process msiexec.exe "/x $($package.productCode) /qn /norestart /L*v `"$directory/remove-$($package.arch).log`""
        }
        $source = $sources | Where-Object id -eq "vc2010-$($package.arch)"
        $path = Join-Path $directory ($source.id + '.exe')
        $null = Save-Download $source.url $path -Microsoft -Sha256 $source.sha256
        Invoke-Vc2010Process $path '/q /norestart'
        $version = Get-InstalledVersion $engine $package
        if ($version -ne [version]'10.0.40219.325' -or @(Get-SupersededMsiPatches $engine $package).Count -ne 1) {
            throw "Original VC2010 + KB2565063 baseline was not established: $($package.arch) $version"
        }
        Write-Host "PASS: patched VC2010 baseline $($package.arch) $version"
    }
    Invoke-Vc2010Process powershell.exe "-NoProfile -ExecutionPolicy Bypass -File `"$payload/Install.ps1`" -Components vc2010 -Quiet"
    foreach ($package in $packages) {
        $version = Get-InstalledVersion $engine $package
        if ($version -ne [version]$package.version -or @(Get-SupersededMsiPatches $engine $package).Count) {
            throw "VC2010 patched upgrade failed: $($package.arch) $version"
        }
        Write-Host "PASS: VC2010 $($package.arch) .325 -> .473; obsolete patch retired"
    }
    Invoke-Vc2010Process powershell.exe "-NoProfile -ExecutionPolicy Bypass -File `"$payload/Install.ps1`" -Components vc2010 -Quiet"
    $reportFile = Get-ChildItem "$env:ProgramData/civisrom/VisualCppRedist/logs" -Filter report.json -Recurse |
        Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
    $report = Get-Content $reportFile.FullName -Raw | ConvertFrom-Json
    if (-not $report.success -or @($report.packages | Where-Object { $null -ne $_.exitCode }).Count) {
        throw 'Equal VC2010 versions were not skipped without child installers.'
    }
    $dll = "$env:SystemRoot/SysWOW64/msvcr100.dll"
    $hash = Get-Sha256 $dll
    Remove-Item $dll
    Invoke-Vc2010Process powershell.exe "-NoProfile -ExecutionPolicy Bypass -File `"$payload/Install.ps1`" -Components vc2010 -Mode repair -Quiet"
    if ((Get-Sha256 $dll) -ne $hash) { throw 'VC2010 repair restored a different DLL version.' }
    foreach ($package in $packages) {
        if ((Get-InstalledVersion $engine $package) -ne [version]$package.version) { throw 'VC2010 repair regressed the patch level.' }
    }
    Write-Host 'PASS: upgraded VC2010 skips equal versions and repairs .473 without reapplying .325'
} finally { $null = [Runtime.InteropServices.Marshal]::FinalReleaseComObject($engine) }
