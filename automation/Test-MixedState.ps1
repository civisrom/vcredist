# Helpers for Smoke.ps1, after its disposable-machine guard.
function Get-LatestInstallationReport {
    $file = Get-ChildItem "$env:ProgramData/civisrom/VisualCppRedist/logs" -Filter report.json -Recurse |
        Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
    if (-not $file) { throw 'The installer did not save a report.' }
    [pscustomobject]@{ path = $file.FullName; data = (Get-Content $file.FullName -Raw | ConvertFrom-Json) }
}

function Assert-NoPackageProcess($Report) {
    $logs = @(Get-ChildItem (Split-Path $Report.path) -Filter '*.log' -File | Where-Object Name -ne 'installer.log')
    if ($logs.Count -or @($Report.data.packages | Where-Object { $null -ne $_.exitCode }).Count) {
        throw 'An installer was launched for a package that should have been skipped.'
    }
}

function Install-MixedBaseline {
    if (-not $ClientWindows) { throw 'The mixed baseline requires a clean disposable client Windows.' }
    $directory = Join-Path $work 'mixed-baseline'
    $null = New-Item -ItemType Directory $directory -Force
    $catalog = Get-Content "$PSScriptRoot/sources.json" -Raw | ConvertFrom-Json
    $sources = @(Get-Content "$PSScriptRoot/upgrade-sources.json" -Raw | ConvertFrom-Json)
    $sources += @($catalog.legacyMonitors | Where-Object { $_.id -match '^vc(2005|2008)-' -or $_.id -eq 'vc2013-x64' })
    $vc14 = @()
    foreach ($source in $sources) {
        $url = if ($source.PSObject.Properties['url']) { $source.url } else {
            $page = Join-Path $directory ($source.id + '.html')
            $null = Save-Download $source.page $page -Microsoft
            Get-DownloadLink (Get-Content $page -Raw) $source.file
        }
        $path = Join-Path $directory ($source.id + '.exe')
        $null = Save-Download $url $path -Microsoft -Sha256 $source.sha256
        # VC2005 wraps its MSI in IExpress; forward silent flags to msiexec.
        $arguments = switch -Regex ($source.id) {
            '^vc2005-' { '/Q /C:"msiexec /i vcredist.msi /qn /norestart"'; break }
            '^vc2008-' { '/qn /norestart'; break }
            '^vc2010-' { '/q /norestart'; break }
            default { '/install /quiet /norestart' }
        }
        if ($source.id -like 'vc14-*') {
            Assert-MicrosoftSignature $path
            $vc14 += [pscustomobject]@{ path = $path; arch = $source.id.Split('-')[1] }
        }
        Invoke-TestProcess $path $arguments 600
        $family = if ($source.id -like 'vc14-*') { '2026' } else { $source.id.Substring(2, 4) }
        $architecture = $source.id.Split('-')[1]
        foreach ($package in $msis | Where-Object { $_.family -eq $family -and $_.arch -eq $architecture }) {
            $actual = Get-InstalledVersion $engine $package
            if (-not $actual -or $actual -gt [version]$package.version) { throw "Invalid mixed baseline: $($package.id) $actual" }
            Write-Host "PASS: genuine preinstalled MSI $($package.id) $actual"
        }
    }
    $previous = @()
    foreach ($group in $desktop | Group-Object channel) {
        $metadataPath = Join-Path $directory ("desktop-$($group.Name).json")
        $null = Save-Download "https://builds.dotnet.microsoft.com/dotnet/release-metadata/$($group.Name)/releases.json" $metadataPath -Microsoft
        $metadata = Get-Content $metadataPath -Raw | ConvertFrom-Json
        $older = Get-PreviousDesktopRelease $metadata ([version]$group.Group[0].version)
        if (-not $older) {
            Write-Host "First stable Desktop release $($group.Group[0].version): test fresh installation; no earlier stable patch exists."
            continue
        }
        foreach ($package in $group.Group) {
            $file = @($older.windowsdesktop.files | Where-Object { $_.rid -eq "win-$($package.arch)" -and $_.name -eq "windowsdesktop-runtime-win-$($package.arch).exe" })
            if ($file.Count -ne 1 -or $file[0].hash -notmatch '^[a-fA-F0-9]{128}$') { throw 'Invalid previous Desktop package.' }
            $path = Join-Path $directory ($package.id + '.exe')
            $null = Save-Download $file[0].url $path -Microsoft
            if ((Get-FileHash $path -Algorithm SHA512).Hash -ne $file[0].hash) { throw 'Previous Desktop SHA512 mismatch.' }
            Assert-MicrosoftSignature $path
            $previous += [pscustomobject]@{ package = $package; path = $path; version = $older.windowsdesktop.version }
            # Mix missing, equal and older patches on the same machine.
            if ($package.id -eq 'windowsdesktop-7.0-x86') { continue }
            $installPath = if ($package.id -eq 'windowsdesktop-9.0-x86') { Get-PayloadPath $payload $package.path } else { $path }
            Invoke-TestProcess $installPath '/install /quiet /norestart' 600
            $expected = if ($package.id -eq 'windowsdesktop-9.0-x86') { $package.version } else { $older.windowsdesktop.version }
            if ((Get-DesktopVersion $package) -ne [version]$expected) { throw "Previous Desktop patch not installed: $($package.id)" }
            Write-Host "PASS: genuine preinstalled Desktop $($package.id) $expected"
        }
    }
    [pscustomobject]@{ directory = $directory; previous = $previous; vc14 = $vc14; before = @{} }
}

function Test-MixedUpdateOnly($State) {
    $initial = @{}
    foreach ($package in $packages) { $initial[$package.id] = Get-InstalledVersion $engine $package }
    Invoke-TestProcess 'powershell.exe' "-NoProfile -ExecutionPolicy Bypass -File `"$payload\Install.ps1`" -Mode update -Components vc14,dotnet-8.0,vc2013 -Quiet" 900
    $report = (Get-LatestInstallationReport).data
    if (-not $report.success) { throw 'Mixed update-only run failed.' }
    Assert-RemovedBundles $report '^Microsoft Visual C\+\+ .+ Redistributable \((x86|x64)\) - 14\.44\.' 2
    foreach ($package in $packages) {
        $row = $report.packages | Where-Object id -eq $package.id
        if ($package.family -eq '2026' -or ($package.type -eq 'windowsdesktop' -and $package.channel -eq '8.0')) {
            if ($row.status -ne 'updated' -or (Get-InstalledVersion $engine $package) -lt [version]$package.version) { throw "Older component was not updated: $($package.id)" }
        } elseif ($package.family -eq '2013') {
            if ($row.status -ne 'skipped' -or $null -ne $row.exitCode) { throw "Equal or missing VC2013 was not skipped: $($package.id)" }
            if ($package.arch -eq 'x86' -and (Get-InstalledVersion $engine $package)) { throw 'Update-only installed an absent component.' }
        } elseif ($row.status -ne 'not-selected') { throw "Update-only changed an unselected component: $($package.id)" }
        $actual = Get-InstalledVersion $engine $package
        if ($row.status -in @('skipped', 'not-selected') -and $actual -ne $initial[$package.id]) {
            throw "Update-only changed a preserved version: $($package.id), $($initial[$package.id]) -> $actual"
        }
        $State.before[$package.id] = $actual
    }
    Write-Host 'PASS: mixed update-only; older VC14/.NET8 updated, equal and absent VC2013 skipped, unselected versions preserved'
}

function Assert-MixedUpgradeReport($State) {
    $report = (Get-LatestInstallationReport).data
    if (-not $report.success -or $report.packages.Count -ne $manifest.packages.Count) { throw 'Incomplete installation report.' }
    Assert-RemovedBundles $report '^Microsoft Visual C\+\+ 2012 Redistributable \((x86|x64)\) - 11\.0\.61030' 2
    $equal = @(Get-RegisteredBundles | Where-Object name -Like 'Microsoft Visual C++ 2013 Redistributable (x64)*' | Sort-Object id -Unique)
    if ($equal.Count -ne 1) { throw 'The Microsoft bundle of an equal version must stay registered.' }
    Write-Host 'PASS: obsolete Microsoft bundle records removed; the bundle of an equal version preserved'
    foreach ($package in $packages) {
        $row = @($report.packages | Where-Object id -eq $package.id)
        if ($row.Count -ne 1) { throw "Missing report row: $($package.id)" }
        $before = $State.before[$package.id]
        if ($row[0].before -ne [string]$before) { throw "Wrong initial version in report: $($package.id)" }
        $expected = if (-not $before) { 'installed' } elseif ($before -lt [version]$package.version) { 'updated' } else { 'skipped' }
        if ($row[0].status -ne $expected) { throw "Wrong mixed result $($package.id): $($row[0].status), expected $expected" }
        $after = Get-InstalledVersion $engine $package
        if ([version]$row[0].after -ne $after -or $after -lt [version]$package.version) { throw "Wrong version in report: $($package.id)" }
        if ($expected -eq 'skipped' -and $null -ne $row[0].exitCode) { throw "Equal version was reinstalled: $($package.id)" }
        Write-Host "PASS: mixed upgrade $($package.id): $before -> $after, $expected"
    }
    foreach ($arch in @('x86', 'x64')) {
        $folder = if ($arch -eq 'x86') { 'SysWOW64' } else { 'System32' }
        foreach ($dll in @('msvcr100.dll', 'msvcp100.dll', 'mfc100.dll')) {
            $version = (Get-Item "$env:SystemRoot/$folder/$dll").VersionInfo.FileVersionRaw
            if ($version -lt [version]'10.0.40219.473') { throw "VC2010 retained an old DLL despite an equal MSI version: $arch $dll $version" }
        }
    }
    Write-Host 'PASS: VC2010 .325 -> .473 shared DLL patch upgrade with the same MSI ProductVersion and ProductCode'
}

function Assert-RemovedBundles($Report, [string] $Pattern, [int] $Count) {
    $removed = @($Report.removedBundles | Where-Object { $_ -match $Pattern })
    if ($removed.Count -ne $Count -or @($Report.removedBundles).Count -ne $Count) {
        throw "Expected $Count removed bundle records matching $Pattern, got: $($Report.removedBundles -join '; ')"
    }
    $left = @(Get-RegisteredBundles | Where-Object { $_.name -match $Pattern })
    if ($left.Count) { throw "Obsolete bundle is still registered: $($left.name -join '; ')" }
}

# A second wave on a machine without any shipped MSI: the most common old
# VC++ 2013 release, installed by its original Microsoft EXE.
function Install-LegacyBaseline {
    $source = Get-Content "$PSScriptRoot/extra-upgrade-sources.json" -Raw | ConvertFrom-Json | Where-Object id -eq 'vc2013-x86'
    $path = Join-Path $work 'legacy-vc2013-x86.exe'
    $null = Save-Download $source.url $path -Microsoft -Sha256 $source.sha256
    Invoke-TestProcess $path '/install /quiet /norestart' 600
    $legacy = @($msis | Where-Object { $_.family -eq '2013' -and $_.arch -eq 'x86' })
    foreach ($package in $legacy) {
        $actual = Get-InstalledVersion $engine $package
        if ($actual -ne [version] $source.version) { throw "Legacy baseline was not established: $($package.id) $actual" }
        Write-Host "PASS: genuine preinstalled MSI $($package.id) $actual"
    }
    [pscustomobject]@{ packages = $legacy; version = $source.version }
}

function Assert-LegacyUpgrade($State) {
    $report = (Get-LatestInstallationReport).data
    if (-not $report.success) { throw 'Legacy upgrade failed.' }
    foreach ($package in $State.packages) {
        $row = $report.packages | Where-Object id -eq $package.id
        if ($row.status -ne 'updated' -or $row.before -ne $State.version -or [version] $row.after -ne [version] $package.version) {
            throw "Wrong legacy upgrade $($package.id): $($row.status), $($row.before) -> $($row.after)"
        }
    }
    Assert-RemovedBundles $report '^Microsoft Visual C\+\+ 2013 Redistributable \(x86\) - 12\.0\.30501' 1
    # With the obsolete record gone, ordinary removal works without overrides.
    for ($i = $State.packages.Count - 1; $i -ge 0; $i--) {
        $package = $State.packages[$i]
        Invoke-TestProcess 'msiexec.exe' "/x $($package.productCode) /qn /norestart /L*v `"$work\remove-legacy-$($package.id).log`""
        if ($engine.ProductState($package.productCode) -eq 5) { throw "Ordinary removal is still blocked: $($package.id)" }
    }
    Invoke-TestProcess 'powershell.exe' "-NoProfile -ExecutionPolicy Bypass -File `"$payload\Install.ps1`" -Components vc2013 -Quiet"
    Write-Host 'PASS: VC2013 12.0.30501 upgraded, its obsolete Microsoft record removed, ordinary removal and reinstallation work'
}

function Test-RealOlderOffer($State) {
    $offer = Join-Path $work 'older-offer'
    $null = New-Item -ItemType Directory $offer
    Copy-Item "$payload/Install.ps1", "$payload/Interface.ps1", "$payload/Installer.cmd", "$payload/StartFailure.txt" $offer
    $old = $State.previous | Where-Object { $_.package.channel -eq '6.0' -and $_.package.arch -eq 'x86' }
    $package = $old.package.PSObject.Copy()
    $package.version = $old.version
    $package.path = 'previous-desktop.exe'
    Copy-Item $old.path (Join-Path $offer $package.path)
    $offered = @($package)
    $catalog = Get-Content "$PSScriptRoot/sources.json" -Raw | ConvertFrom-Json
    $wixArchive = Join-Path $State.directory 'wix.zip'
    $null = Save-Download $catalog.wix.url $wixArchive -Sha256 $catalog.wix.sha256
    $wix = Join-Path $State.directory 'wix'
    Expand-Archive $wixArchive $wix
    $bundle = $State.vc14 | Where-Object arch -eq 'x86'
    $extracted = Join-Path $offer 'vc14'
    Invoke-Checked "$wix/dark.exe" @('-nologo', $bundle.path, '-x', $extracted)
    foreach ($msi in Get-ChildItem $extracted -Filter '*.msi' -Recurse) {
        $metadata = Get-MsiMetadata $msi.FullName
        $metadata['id'] = 'previous-' + $msi.BaseName
        $metadata['type'] = 'msi'; $metadata['family'] = '2026'; $metadata['arch'] = 'x86'
        $metadata['path'] = $msi.FullName.Substring($offer.Length + 1).Replace('\', '/')
        $offered += [pscustomobject]$metadata
    }
    if ($offered.Count -ne 3) { throw 'Expected two old VC14 MSI packages and one old Desktop bundle.' }
    $files = @(Get-ChildItem $offer -File -Recurse | ForEach-Object { @{ path = $_.FullName.Substring($offer.Length + 1).Replace('\', '/'); sha256 = Get-Sha256 $_.FullName } })
    @{ schema = 1; packages = $offered; files = $files } | ConvertTo-Json -Depth 10 | Set-Content "$offer/manifest.json" -Encoding UTF8
    Invoke-TestProcess 'powershell.exe' "-NoProfile -ExecutionPolicy Bypass -File `"$offer\Install.ps1`" -Quiet"
    $report = Get-LatestInstallationReport
    if (-not $report.data.success -or @($report.data.packages | Where-Object status -ne 'skipped').Count) { throw 'Real older packages were not all skipped.' }
    Assert-NoPackageProcess $report
    Assert-Installed
    Assert-Applications
    Write-Host 'PASS: real older VC14 and Desktop payloads skipped without launching installers or downgrading installed versions'
}
