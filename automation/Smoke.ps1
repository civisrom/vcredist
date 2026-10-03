param(
    [string] $WorkDirectory = (Join-Path (Split-Path $PSScriptRoot) '.build'),
    [ValidateSet('windows-10', 'windows-11')]
    [string] $ClientWindows
)
. "$PSScriptRoot/Common.ps1"
if ($ClientWindows) {
    if ($env:VCR_DISPOSABLE_VM -ne $ClientWindows -or
        -not (Test-Path 'C:\RuntimeTests\disposable-vm.txt') -or
        (Get-Content 'C:\RuntimeTests\disposable-vm.txt' -Raw).Trim() -ne $ClientWindows) { throw 'Not a disposable client VM.' }
    $os = Get-CimInstance Win32_OperatingSystem
    $images = Get-Content "$PSScriptRoot/client/images.json" -Raw | ConvertFrom-Json
    if ($os.ProductType -ne 1 -or [int] $os.BuildNumber -ne $images.$ClientWindows.build -or -not [Environment]::Is64BitOperatingSystem) {
        throw "Wrong client Windows image: $($os.Caption) $($os.BuildNumber)"
    }
    Write-Host "TEST OS: $($os.Caption), build $($os.BuildNumber), x64"
} elseif ($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted') {
    throw 'Destructive lifecycle tests are restricted to disposable GitHub-hosted runners.'
}
$work = [IO.Path]::GetFullPath($WorkDirectory)
$payload = Join-Path $work 'payload'
$exe = Join-Path $work 'dist/Runtimes_AIO_x86_x64.exe'
Invoke-Checked '7z.exe' @('x', '-y', '-bso0', "-o$payload", $exe)
$manifestPath = Join-Path $payload 'manifest.json'
$manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
. "$PSScriptRoot/../installer/Install.ps1"
$engine = New-Object -ComObject WindowsInstaller.Installer
$packages = @($manifest.packages | Where-Object { $_.family -ne 'vstor' -or $_.arch -eq 'x64' })
$desktop = @($packages | Where-Object type -eq 'windowsdesktop')
$msis = @($packages | Where-Object type -eq 'msi')
$probes = Join-Path $work 'probes'
$null = New-Item -ItemType Directory $probes -Force
. "$PSScriptRoot/Test-MixedState.ps1"

function Invoke-TestProcess([string] $File, [string] $Arguments, [int] $TimeoutSeconds = 600, [switch] $ExpectFailure) {
    Write-Host "RUN: $File $Arguments"
    $output = Join-Path $work ([guid]::NewGuid().ToString('N') + '-stdout.log')
    $errorOutput = $output.Replace('-stdout.log', '-stderr.log')
    $process = Start-Process $File -ArgumentList $Arguments -PassThru -NoNewWindow -RedirectStandardOutput $output -RedirectStandardError $errorOutput
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        Get-Process | Where-Object MainWindowTitle | Select-Object ProcessName, MainWindowTitle | Out-Host
        & taskkill.exe /pid $process.Id /t /f | Out-Host
        throw "Process timed out after ${TimeoutSeconds}s: $File"
    }
    $process.Refresh()
    Get-Content $output, $errorOutput | Write-Host
    if ($ExpectFailure) {
        if ($process.ExitCode -eq 0) { throw "Invalid input was accepted: $File" }
    } elseif ($process.ExitCode -notin @(0, 3010)) { throw "Exit $($process.ExitCode): $File" }
}

function Assert-Installed {
    foreach ($package in $packages) {
        $actual = Get-InstalledVersion $engine $package
        if (-not $actual -or $actual -lt [version] $package.version) {
            throw "Not installed: $($package.id), expected $($package.version), actual $actual"
        }
        Write-Host "PASS: installed $($package.id) $actual"
    }
}

function Get-DesktopBundles($Package) {
    $pattern = 'Windows Desktop Runtime (?:- )?' + [regex]::Escape($Package.version) + ' \(' + $Package.arch + '\)'
    foreach ($view in @('Registry64', 'Registry32')) {
        $hive = [Microsoft.Win32.RegistryKey]::OpenBaseKey('LocalMachine', $view)
        $uninstall = $hive.OpenSubKey('SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall')
        try {
            foreach ($name in $uninstall.GetSubKeyNames()) {
                $key = $uninstall.OpenSubKey($name)
                try { if ($key.GetValue('DisplayName') -match $pattern -and $key.GetValue('BundleCachePath')) { $name } }
                finally { $key.Dispose() }
            }
        } finally { $uninstall.Dispose(); $hive.Dispose() }
    }
}

function Register-TestSdk {
    # runner-images installs SDK ZIPs over the machine-wide .NET directory.
    # Register the latest SDK with its official installer so shared components
    # have a real owner during the Desktop uninstall/coexistence tests.
    $package = $desktop | Where-Object arch -eq 'x64' | Sort-Object { [version] $_.version } -Descending | Select-Object -First 1
    $metadataPath = Join-Path $work 'sdk-release.json'
    $null = Save-Download "https://dotnetcli.blob.core.windows.net/dotnet/release-metadata/$($package.channel)/releases.json" $metadataPath -Microsoft
    $metadata = Get-Content $metadataPath -Raw | ConvertFrom-Json
    $release = @($metadata.releases | Where-Object {
        $_.PSObject.Properties['windowsdesktop'] -and $_.windowsdesktop.version -eq $package.version
    })
    if ($release.Count -ne 1) { throw 'Ambiguous SDK test baseline.' }
    $sdk = $release[0].sdk
    $file = @($sdk.files | Where-Object { $_.rid -eq 'win-x64' -and $_.name -eq 'dotnet-sdk-win-x64.exe' })
    if ($file.Count -ne 1 -or $file[0].hash -notmatch '^[a-fA-F0-9]{128}$') { throw 'Invalid SDK test baseline.' }
    $path = Join-Path $work 'baseline-sdk.exe'
    $null = Save-Download $file[0].url $path -Microsoft
    if ((Get-FileHash $path -Algorithm SHA512).Hash -ne $file[0].hash) { throw 'SDK SHA512 mismatch.' }
    Assert-MicrosoftSignature $path
    Invoke-TestProcess $path "/install /quiet /norestart /log `"$work\baseline-sdk.log`"" 900
    Invoke-Checked "$env:ProgramFiles\dotnet\dotnet.exe" @('--list-sdks')
    Write-Host "PASS: registered SDK $($sdk.version) for shared-component ownership tests"
}

function New-Probes {
    # Compile against the oldest runtime; explicitly select each branch at runtime.
    $dotnet = "$env:ProgramFiles\dotnet\dotnet.exe"
    $sdk = Get-ChildItem "$env:ProgramFiles\dotnet\sdk" -Directory |
        Where-Object Name -Match '^\d+\.\d+\.\d+$' | Sort-Object { [version] $_.Name } -Descending | Select-Object -First 1
    $oldest = $desktop | Where-Object arch -eq 'x64' | Sort-Object { [version] $_.version } | Select-Object -First 1
    $referenceFiles = @{}
    foreach ($framework in @('Microsoft.NETCore.App', 'Microsoft.WindowsDesktop.App')) {
        Get-ChildItem "$env:ProgramFiles\dotnet\shared\$framework\$($oldest.version)" -Filter '*.dll' | ForEach-Object {
            $referenceFiles[$_.Name] = $_.FullName
        }
    }
    # Desktop supplies the real WindowsBase in place of Core's facade.
    $references = foreach ($path in $referenceFiles.Values | Sort-Object) {
        try { $null = [Reflection.AssemblyName]::GetAssemblyName($path); '-r:"' + $path + '"' }
        catch [BadImageFormatException] { }
    }
    $response = Join-Path $probes 'compile.rsp'
    (@('-nostdlib+', '-target:exe', ('-out:"' + $probes + '\DesktopProbe.dll"')) +
        @($references) + @('"' + $PSScriptRoot + '\probes\DesktopProbe.cs"')) | Set-Content $response
    Invoke-Checked $dotnet @((Join-Path $sdk.FullName 'Roslyn/bincore/csc.dll'), '-noconfig', "@$response")
    foreach ($package in $desktop) {
        @{ runtimeOptions = @{ tfm = "net$($package.channel)"; rollForward = 'Disable'; frameworks = @(
            @{ name = 'Microsoft.NETCore.App'; version = $package.version },
            @{ name = 'Microsoft.WindowsDesktop.App'; version = $package.version }
        ) } } | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $probes "$($package.id).json")
    }
    foreach ($arch in @('x86', 'x64')) {
        $processor = if ($arch -eq 'x64') { 'amd64' } else { 'x86' }
        $appManifest = Join-Path $probes "$arch.manifest"
        @"
<assembly xmlns="urn:schemas-microsoft-com:asm.v1" manifestVersion="1.0">
  <assemblyIdentity version="1.0.0.0" name="RuntimeProbe" type="win32" processorArchitecture="$processor"/>
  <dependency><dependentAssembly><assemblyIdentity type="win32" name="Microsoft.VC80.CRT" version="8.0.50727.6229" processorArchitecture="$processor" publicKeyToken="1fc8b3b9a1e18e3b"/></dependentAssembly></dependency>
  <dependency><dependentAssembly><assemblyIdentity type="win32" name="Microsoft.VC90.CRT" version="9.0.30729.7523" processorArchitecture="$processor" publicKeyToken="1fc8b3b9a1e18e3b"/></dependentAssembly></dependency>
</assembly>
"@ | Set-Content $appManifest
        $nativeSource = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'probes/NativeProbe.cs'))
        Invoke-Checked "$env:SystemRoot\Microsoft.NET\Framework\v4.0.30319\csc.exe" @('/nologo', '/target:exe', "/platform:$arch", "/win32manifest:$appManifest", "/out:$probes\NativeProbe-$arch.exe", $nativeSource)
    }
}

function Invoke-DesktopProbe($Package) {
    $directory = if ($Package.arch -eq 'x86') { ${env:ProgramFiles(x86)} } else { $env:ProgramFiles }
    $bits = if ($Package.arch -eq 'x86') { '32' } else { '64' }
    Invoke-Checked "$directory\dotnet\dotnet.exe" @('exec', '--runtimeconfig', (Join-Path $probes "$($Package.id).json"),
        (Join-Path $probes 'DesktopProbe.dll'), $Package.channel.Split('.')[0], $bits)
}

function Assert-Applications {
    foreach ($package in $desktop) { Invoke-DesktopProbe $package }
    foreach ($arch in @('x86', 'x64')) { Invoke-Checked (Join-Path $probes "NativeProbe-$arch.exe") @() }
}

function Install-PreviousPatch {
    $package = $desktop | Where-Object { $_.arch -eq 'x86' -and -not (Get-DesktopVersion $_) } | Select-Object -First 1
    if (-not $package) { throw 'No empty x86 .NET branch for the real patch-upgrade test.' }
    $metadataPath = Join-Path $work 'previous-release.json'
    $null = Save-Download "https://dotnetcli.blob.core.windows.net/dotnet/release-metadata/$($package.channel)/releases.json" $metadataPath -Microsoft
    $metadata = Get-Content $metadataPath -Raw | ConvertFrom-Json
    $previous = $metadata.releases | Where-Object {
        $_.PSObject.Properties['windowsdesktop'] -and $_.windowsdesktop.version -match '^\d+\.\d+\.\d+$' -and
        [version] $_.windowsdesktop.version -lt [version] $package.version
    } | Sort-Object { [version] $_.windowsdesktop.version } -Descending | Select-Object -First 1
    if (-not $previous) { throw 'No previous stable Desktop patch in Microsoft metadata.' }
    $file = @($previous.windowsdesktop.files | Where-Object { $_.rid -eq 'win-x86' -and $_.name -eq 'windowsdesktop-runtime-win-x86.exe' })
    if ($file.Count -ne 1 -or $file[0].hash -notmatch '^[a-fA-F0-9]{128}$') { throw 'Invalid previous .NET release.' }
    $path = Join-Path $work 'previous-desktop.exe'
    $null = Save-Download $file[0].url $path -Microsoft
    if ((Get-FileHash $path -Algorithm SHA512).Hash -ne $file[0].hash) { throw 'Previous patch SHA512 mismatch.' }
    Assert-MicrosoftSignature $path
    Invoke-TestProcess $path '/install /quiet /norestart'
    if ((Get-DesktopVersion $package) -ne [version] $previous.windowsdesktop.version) { throw 'Older patch was not installed.' }
    Write-Host "PASS: upgrade baseline $($package.id) $($previous.windowsdesktop.version) -> $($package.version)"
}

try {
    Invoke-TestProcess 'powershell.exe' "-NoProfile -STA -ExecutionPolicy Bypass -File `"$PSScriptRoot\Test-SelectionUi.ps1`" -PayloadRoot `"$payload`"" 120
    $mixedState = if ($ClientWindows) { Install-MixedBaseline } else { $null }
    Register-TestSdk
    Invoke-TestProcess 'powershell.exe' "-NoProfile -ExecutionPolicy Bypass -File `"$payload\Install.ps1`" -Mode check"
    Invoke-TestProcess $exe '/aiD /gm2' 120
    if ($ClientWindows) {
        Test-MixedUpdateOnly $mixedState
        Invoke-TestProcess 'powershell.exe' "-NoProfile -STA -ExecutionPolicy Bypass -File `"$PSScriptRoot\Test-InteractiveInstall.ps1`" -Installer `"$exe`" -ScreenshotDirectory `"$env:VCR_SCREENSHOT_DIRECTORY\first-install`"" 1800
        Assert-MixedUpgradeReport $mixedState
    } else {
        Install-PreviousPatch
        Invoke-TestProcess $exe '/ai /gm2' 900
    }
    Assert-Installed
    New-Probes
    Assert-Applications
    Invoke-TestProcess $exe '/ai /gm2' 900
    Assert-Installed
    $repeat = Get-LatestInstallationReport
    if (-not $repeat.data.success -or @($repeat.data.packages | Where-Object { $_.status -notin @('skipped', 'not-applicable') }).Count) {
        throw 'Repeat installation did not skip all equal versions.'
    }
    Assert-NoPackageProcess $repeat
    Write-Host 'PASS: repeated installation skipped every matching version without starting child installers'
    if ($ClientWindows) { Test-RealOlderOffer $mixedState }
    # Force real repairs instead of accepting a successful no-op.
    $repairDesktop = $desktop | Where-Object arch -eq 'x86' | Sort-Object { [version] $_.version } | Select-Object -First 1
    $damaged = @(
        "$env:SystemRoot\SysWOW64\msvcr70.dll",
        "${env:ProgramFiles(x86)}\dotnet\shared\Microsoft.WindowsDesktop.App\$($repairDesktop.version)\PresentationFramework.dll"
    )
    $repairHashes = @{}
    foreach ($path in $damaged) { $repairHashes[$path] = Get-Sha256 $path; Remove-Item -LiteralPath $path }
    Invoke-TestProcess $exe '/aiF /gm2' 1200
    foreach ($path in $damaged) { if ((Get-Sha256 $path) -ne $repairHashes[$path]) { throw "Repair did not restore $path" } }
    Assert-Installed
    Assert-Applications

    # Official removal must preserve every other branch and architecture.
    # Shared components still owned by an SDK may legitimately stay installed.
    foreach ($package in $desktop) {
        $path = Get-PayloadPath $payload $package.path
        if (-not @(Get-DesktopBundles $package).Count) { Invoke-TestProcess $path '/install /quiet /norestart' }
        if (@(Get-DesktopBundles $package).Count -ne 1) { throw "Expected one registered bundle: $($package.id)" }
        Invoke-TestProcess $path "/uninstall /quiet /norestart /log `"$work\remove-$($package.id).log`""
        if (@(Get-DesktopBundles $package).Count) { throw "Bundle was not removed: $($package.id)" }
        Write-Host "PASS: bundle removed $($package.id); remaining shared runtime: $(Get-DesktopVersion $package)"
        foreach ($other in $desktop | Where-Object id -ne $package.id) { Invoke-DesktopProbe $other }
        if ($package.id -eq $desktop[0].id) {
            Invoke-TestProcess 'powershell.exe' "-NoProfile -ExecutionPolicy Bypass -File `"$payload\Install.ps1`" -Components dotnet-$($package.channel) -Mode repair -Quiet" 900
            $latest = Get-ChildItem "$env:ProgramData\civisrom\VisualCppRedist\logs" -Directory | Sort-Object Name -Descending | Select-Object -First 1
            $logs = @(Get-ChildItem $latest.FullName -Filter '*.log' -File | Where-Object Name -ne 'installer.log')
            if (@($logs | Where-Object Name -NotLike "windowsdesktop-$($package.channel)-*.log").Count) {
                throw 'Selective Desktop repair ran an unselected package.'
            }
            foreach ($arch in @('x86', 'x64')) {
                if (-not (Test-Path (Join-Path $latest.FullName "windowsdesktop-$($package.channel)-$arch.log"))) {
                    throw "Selected Desktop architecture was not processed: $arch"
                }
            }
            Write-Host "PASS: selected Desktop $($package.channel) only, x86 and x64"
        } else { Invoke-TestProcess $path '/install /quiet /norestart' }
        Invoke-DesktopProbe $package
    }

    # Remove exactly the shipped MSI products, in reverse dependency order.
    $removed = @()
    for ($i = $msis.Count - 1; $i -ge 0; $i--) {
        $package = $msis[$i]
        if ($engine.ProductState($package.productCode) -ne 5) { throw "MSI lifecycle not covered: $($package.id)" }
        Invoke-TestProcess 'msiexec.exe' "/x $($package.productCode) /qn /norestart /L*v `"$work\remove-$($package.id).log`""
        if ($engine.ProductState($package.productCode) -eq 5) {
            $log = Get-Content "$work\remove-$($package.id).log" -Raw
            if ($log -notmatch 'Found dependent "') { throw "Unexpected MSI retention: $($package.id)" }
            Write-Host "PASS: Windows Installer preserved $($package.id) for registered dependents"
            # Only on this disposable runner: also exercise actual MSI removal.
            Invoke-TestProcess 'msiexec.exe' "/x $($package.productCode) /qn /norestart IGNOREDEPENDENCIES=ALL /L*v `"$work\remove-forced-$($package.id).log`""
        }
        if ($engine.ProductState($package.productCode) -eq 5) { throw "MSI removal failed: $($package.id)" }
        $removed += $package
        Write-Host "PASS: MSI removed $($package.id)"
    }
    Invoke-TestProcess $exe '/ai1 /gm2' 900
    foreach ($package in $removed) {
        if ($engine.ProductState($package.productCode) -eq 5) { throw "Update restored an absent MSI: $($package.id)" }
    }
    Invoke-TestProcess 'powershell.exe' "-NoProfile -ExecutionPolicy Bypass -File `"$payload\Install.ps1`" -Components vc2005 -Quiet"
    foreach ($package in $removed) {
        $installed = $engine.ProductState($package.productCode) -eq 5
        if ($installed -ne ($package.family -eq '2005')) { throw "Component selection was not respected: $($package.id)" }
    }
    Write-Host 'PASS: selected VC++ 2005 only; every other removed MSI remains absent'
    Invoke-TestProcess 'powershell.exe' "-NoProfile -ExecutionPolicy Bypass -File `"$payload\Install.ps1`" -Components unknown-component -Quiet" -ExpectFailure
    Invoke-TestProcess $exe '/ai /gm2' 900
    Assert-Installed
    Assert-Applications

    # Offer lower versions without changing the machine: all must be skipped.
    $originalManifest = [IO.File]::ReadAllBytes($manifestPath)
    try {
        foreach ($package in $manifest.packages) { $package.version = '0.0' }
        $manifest | ConvertTo-Json -Depth 12 | Set-Content $manifestPath -Encoding utf8
        Invoke-TestProcess 'powershell.exe' "-NoProfile -ExecutionPolicy Bypass -File `"$payload\Install.ps1`" -Quiet"
        $latest = Get-ChildItem "$env:ProgramData\civisrom\VisualCppRedist\logs" -Directory | Sort-Object Name -Descending | Select-Object -First 1
        if (@(Get-ChildItem $latest.FullName -Filter '*.log' -File | Where-Object Name -ne 'installer.log').Count) { throw 'Downgrade attempted to run a package.' }
    } finally { [IO.File]::WriteAllBytes($manifestPath, $originalManifest) }
    $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
    $packages = @($manifest.packages | Where-Object { $_.family -ne 'vstor' -or $_.arch -eq 'x64' })

    $target = Get-PayloadPath $payload $packages[0].path
    $original = [IO.File]::ReadAllBytes($target)
    try {
        [IO.File]::WriteAllBytes($target, [byte[]] @(0, 1, 2))
        Invoke-TestProcess 'powershell.exe' "-NoProfile -ExecutionPolicy Bypass -File `"$payload\Install.ps1`" -Quiet" -ExpectFailure
    } finally { [IO.File]::WriteAllBytes($target, $original) }
    Assert-Installed
    Write-Host "PASS: lifecycle on $env:ImageOS; $($msis.Count) MSI and $($desktop.Count) Desktop bundles."
} finally { $null = [Runtime.InteropServices.Marshal]::FinalReleaseComObject($engine) }
