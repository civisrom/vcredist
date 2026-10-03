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
        $arguments = if ($source.id -match '^vc(2005|2008|2010)-') { '/q /norestart' } else { '/install /quiet /norestart' }
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
        $null = Save-Download "https://dotnetcli.blob.core.windows.net/dotnet/release-metadata/$($group.Name)/releases.json" $metadataPath -Microsoft
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
    Invoke-TestProcess 'powershell.exe' "-NoProfile -ExecutionPolicy Bypass -File `"$payload\Install.ps1`" -Mode update -Components vc14,dotnet-8.0,vc2013 -Quiet" 900
    $report = (Get-LatestInstallationReport).data
    if (-not $report.success) { throw 'Mixed update-only run failed.' }
    foreach ($package in $packages) {
        $row = $report.packages | Where-Object id -eq $package.id
        if ($package.family -eq '2026' -or ($package.type -eq 'windowsdesktop' -and $package.channel -eq '8.0')) {
            if ($row.status -ne 'updated' -or (Get-InstalledVersion $engine $package) -lt [version]$package.version) { throw "Older component was not updated: $($package.id)" }
        } elseif ($package.family -eq '2013') {
            if ($row.status -ne 'skipped' -or $null -ne $row.exitCode) { throw "Equal or missing VC2013 was not skipped: $($package.id)" }
            if ($package.arch -eq 'x86' -and (Get-InstalledVersion $engine $package)) { throw 'Update-only installed an absent component.' }
        } elseif ($row.status -ne 'not-selected') { throw "Update-only changed an unselected component: $($package.id)" }
        $State.before[$package.id] = Get-InstalledVersion $engine $package
    }
    Write-Host 'PASS: mixed update-only; older VC14/.NET8 updated, equal and absent VC2013 skipped, unselected versions preserved'
}

function Assert-MixedUpgradeReport($State) {
    $report = (Get-LatestInstallationReport).data
    if (-not $report.success -or $report.packages.Count -ne $manifest.packages.Count) { throw 'Incomplete installation report.' }
    foreach ($package in $packages) {
        $row = @($report.packages | Where-Object id -eq $package.id)
        if ($row.Count -ne 1) { throw "Missing report row: $($package.id)" }
        $before = $State.before[$package.id]
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

function Test-RealOlderOffer($State) {
    $offer = Join-Path $work 'older-offer'
    $null = New-Item -ItemType Directory $offer
    Copy-Item "$payload/Install.ps1", "$payload/Interface.ps1", "$payload/Installer.cmd" $offer
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
