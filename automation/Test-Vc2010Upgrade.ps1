# Reproduce the original VC2010 installations before the slower VM matrix.
. "$PSScriptRoot/Common.ps1"
if ($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted') {
    throw 'Destructive upgrade tests require a disposable GitHub-hosted runner.'
}
. "$PSScriptRoot/../installer/Install.ps1"
$work = Join-Path (Split-Path $PSScriptRoot) '.build'
$payload = Join-Path $work 'payload'
$manifestPath = Join-Path $payload 'manifest.json'
$manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
$packages = @($manifest.packages | Where-Object family -eq '2010')
if ($packages.Count -ne 2) { throw 'Expected both VC2010 architectures.' }
$directory = Join-Path $work 'vc2010-upgrade'
$null = New-Item -ItemType Directory $directory
$sources = @(Get-Content "$PSScriptRoot/upgrade-sources.json" -Raw | ConvertFrom-Json)
$sources += @(Get-Content "$PSScriptRoot/extra-upgrade-sources.json" -Raw | ConvertFrom-Json)

function Invoke-Vc2010Process([string] $File, [string] $Arguments) {
    $process = Start-Process $File -ArgumentList $Arguments -NoNewWindow -PassThru
    if (-not $process.WaitForExit(600000)) {
        & taskkill.exe /pid $process.Id /t /f | Out-Host
        throw "VC2010 process timed out: $File"
    }
    $process.Refresh()
    if ($process.ExitCode -notin @(0, 3010)) { throw "VC2010 process failed: $File ($($process.ExitCode))" }
}

function Install-Vc2010Baseline($Package, [string] $SourceId, [version] $Version, [int] $Patches) {
    if ($engine.ProductState($Package.productCode) -eq 5) {
        Invoke-Vc2010Process msiexec.exe "/x $($Package.productCode) /qn /norestart /L*v `"$directory/remove-$($Package.arch)-$([guid]::NewGuid().ToString('N')).log`""
    }
    $source = $sources | Where-Object id -eq $SourceId
    $path = Join-Path $directory ($source.id + '.exe')
    if (-not (Test-Path $path)) { $null = Save-Download $source.url $path -Microsoft -Sha256 $source.sha256 }
    Invoke-Vc2010Process $path '/q /norestart'
    $actual = Get-InstalledVersion $engine $Package
    if ($actual -ne $Version -or @(Get-SupersededMsiPatches $engine $Package -All).Count -ne $Patches) {
        throw "VC2010 baseline was not established: $SourceId $actual"
    }
    Write-Host "PASS: VC2010 baseline $SourceId $actual, patches: $Patches"
}

function Install-Vc2010 { Invoke-Vc2010Process powershell.exe "-NoProfile -ExecutionPolicy Bypass -File `"$payload/Install.ps1`" -Components vc2010 $args -Quiet" }

function Get-Vc2010Report {
    $file = Get-ChildItem "$env:ProgramData/civisrom/VisualCppRedist/logs" -Filter report.json -Recurse |
        Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
    [pscustomobject]@{ directory = $file.DirectoryName; data = (Get-Content $file.FullName -Raw | ConvertFrom-Json) }
}

function Assert-Vc2010Upgraded([object[]] $Upgraded, [string] $Message) {
    foreach ($package in $Upgraded) {
        $version = Get-InstalledVersion $engine $package
        if ($version -ne [version]$package.version -or @(Get-SupersededMsiPatches $engine $package -All).Count) {
            throw "$Message failed: $($package.arch) $version"
        }
    }
    if (-not (Get-Vc2010Report).data.success) { throw "$Message was not reported as successful." }
    Write-Host "PASS: $Message"
}

$engine = New-Object -ComObject WindowsInstaller.Installer
try {
    $x86 = $packages | Where-Object arch -eq 'x86'

    # The original SP1 release without any patch.
    Install-Vc2010Baseline $x86 'vc2010sp1-x86' ([version]'10.0.40219.1') 0
    Install-Vc2010
    Assert-Vc2010Upgraded @($x86) 'VC2010 x86 unpatched SP1 .1 -> .473'

    # A patch that the package does not list must not leave the old DLLs in place.
    Install-Vc2010Baseline $x86 'vc2010-x86' ([version]'10.0.40219.325') 1
    $original = [IO.File]::ReadAllBytes($manifestPath)
    try {
        foreach ($package in $manifest.packages | Where-Object family -eq '2010') { $package.supersededPatches = @('{00000000-0000-0000-0000-000000000000}') }
        $manifest | ConvertTo-Json -Depth 12 | Set-Content $manifestPath -Encoding utf8
        Install-Vc2010
    } finally { [IO.File]::WriteAllBytes($manifestPath, $original) }
    if (-not (Test-Path (Join-Path (Get-Vc2010Report).directory "$($x86.id)-2.log"))) { throw 'The unlisted patch was expected to require the recovery pass.' }
    Assert-Vc2010Upgraded @($x86) 'VC2010 x86 .325 -> .473 with an unlisted patch, recovered by retiring every patch'

    foreach ($package in $packages) { Install-Vc2010Baseline $package "vc2010-$($package.arch)" ([version]'10.0.40219.325') 1 }
    Install-Vc2010
    if (Test-Path (Join-Path (Get-Vc2010Report).directory "$($x86.id)-2.log")) { throw 'A listed patch must be retired without the recovery pass.' }
    Assert-Vc2010Upgraded $packages 'VC2010 x86/x64 .325 -> .473; obsolete patch retired'

    Install-Vc2010
    if (@((Get-Vc2010Report).data.packages | Where-Object { $null -ne $_.exitCode }).Count) {
        throw 'Equal VC2010 versions were not skipped without child installers.'
    }
    $dll = "$env:SystemRoot/SysWOW64/msvcr100.dll"
    $hash = Get-Sha256 $dll
    Remove-Item $dll
    # Same version, different contents: version rules alone would keep this file.
    $damaged = "$env:SystemRoot/SysWOW64/mfc100.dll"
    $damagedHash = Get-Sha256 $damaged
    $bytes = [IO.File]::ReadAllBytes($damaged)
    $bytes[$bytes.Length - 1] = $bytes[$bytes.Length - 1] -bxor 0xFF
    [IO.File]::WriteAllBytes($damaged, $bytes)
    if ((Get-Item $damaged).VersionInfo.FileVersionRaw -ne [version]$x86.version) { throw 'The damaged file must keep its version.' }
    Install-Vc2010 -Mode repair
    if ((Get-Sha256 $dll) -ne $hash) { throw 'VC2010 repair restored a different DLL version.' }
    if ((Get-Sha256 $damaged) -ne $damagedHash) { throw 'VC2010 repair kept a damaged file of the same version.' }
    foreach ($package in $packages) {
        if ((Get-InstalledVersion $engine $package) -ne [version]$package.version) { throw 'VC2010 repair regressed the patch level.' }
    }
    Write-Host 'PASS: upgraded VC2010 skips equal versions, restores a deleted DLL and rewrites a damaged one without reapplying .325'
} finally { $null = [Runtime.InteropServices.Marshal]::FinalReleaseComObject($engine) }
