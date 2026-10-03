$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/Common.ps1"
. "$PSScriptRoot/../installer/Install.ps1"
$checks = 0
function Assert-Equal($Actual, $Expected, [string] $Message) {
    if ($Actual -cne $Expected) { throw "$Message`: expected [$Expected], got [$Actual]" }
    $script:checks++
}
function Assert-Throws([scriptblock] $Action, [string] $Message) {
    $threw = $false
    try { & $Action | Out-Null } catch { $threw = $true }
    if (-not $threw) { throw "Expected rejection: $Message" }
    $script:checks++
}

$scripts = @('automation', 'installer') | ForEach-Object {
    Get-ChildItem (Join-Path (Split-Path $PSScriptRoot) $_) -Filter '*.ps1' -File -Recurse |
        Where-Object Extension -eq '.ps1'
}
# Windows PowerShell's file filter can also match .ps1xml; scan only our scripts.
foreach ($path in $scripts) {
    if ([IO.File]::ReadAllText($path.FullName) -match '[^\x00-\x7F]') {
        $bytes = [IO.File]::ReadAllBytes($path.FullName)
        Assert-Equal ([BitConverter]::ToString($bytes, 0, 3)) 'EF-BB-BF' "UTF-8 BOM required by Windows PowerShell 5.1: $($path.Name)"
    }
    $tokens = $null; $errors = $null
    $null = [Management.Automation.Language.Parser]::ParseFile($path.FullName, [ref] $tokens, [ref] $errors)
    if ($errors) { throw "$($path.Name): $errors" }
    $checks++
}
foreach ($url in @('https://aka.ms/vc14/vc_redist.x64.exe', 'https://builds.dotnet.microsoft.com/dotnet/file.exe', 'https://dotnetcli.blob.core.windows.net/dotnet/release-metadata/releases-index.json')) {
    Assert-MicrosoftUrl $url
    $checks++
}
foreach ($url in @('http://download.microsoft.com/file.exe', 'https://microsoft.com.attacker.invalid/file.exe', 'https://user:pass@download.microsoft.com/file.exe', 'file:///tmp/file.exe', 'https://unrelated.blob.core.windows.net/file.exe')) {
    Assert-Throws { Assert-MicrosoftUrl $url } $url
}
Assert-Equal (Get-DownloadLink '<a href="https://download.microsoft.com/a/vstor_redist.exe">x</a>' 'vstor_redist.exe') 'https://download.microsoft.com/a/vstor_redist.exe' 'Download Center parsing'
Assert-Throws { Get-DownloadLink '<html>Unavailable</html>' 'vstor_redist.exe' } 'missing Microsoft download'
Assert-Throws { Get-DownloadLink 'https://download.microsoft.com/a/file.exe https://download.microsoft.com/b/file.exe' 'file.exe' } 'ambiguous Microsoft download'

$index = '{"releases-index":[
 {"channel-version":"5.0","latest-release":"5.0.17","support-phase":"eol"},
 {"channel-version":"6.0","latest-release":"6.0.36","support-phase":"eol"},
 {"channel-version":"7.0","latest-release":"7.0.20","support-phase":"eol"},
 {"channel-version":"9.0","latest-release":"9.0.20","support-phase":"maintenance"},
 {"channel-version":"10.0","latest-release":"10.0.12","support-phase":"active"},
 {"channel-version":"11.0","latest-release":"11.0.0-rc.1","support-phase":"go-live"},
 {"channel-version":"12.0","latest-release":"12.0.0","support-phase":"active"}
]}' | ConvertFrom-Json
Assert-Equal ((Get-DotNetChannels $index | ForEach-Object { $_.'channel-version' }) -join ',') '6.0,7.0,9.0,10.0,12.0' 'Keep legacy and discover future stable .NET, exclude preview'
Assert-Throws { Get-DotNetChannels ('{"releases-index":[]}' | ConvertFrom-Json) } 'empty channel metadata'
$futureReleases = '{"releases":[{"windowsdesktop":{"version":"12.0.0"}},{"windowsdesktop":{"version":"12.0.0-rc.1"}},{"windowsdesktop":{"version":"10.0.12"}}]}' | ConvertFrom-Json
Assert-Equal (Get-PreviousDesktopRelease $futureReleases ([version]'12.0.0')) $null 'A first stable branch needs fresh-install tests without a nonexistent previous patch'
Assert-Equal (Get-PreviousDesktopRelease $futureReleases ([version]'12.0.1')).windowsdesktop.version '12.0.0' 'The next patch must upgrade from the first stable release'
Assert-Throws { Get-PreviousDesktopRelease ('{"releases":[]}' | ConvertFrom-Json) ([version]'12.0.1') } 'Missing history for an existing branch must not silently skip upgrade coverage'

Assert-Equal (Get-PackageAction ([version]'14.51.1') $null 'install' $false) 'install' 'missing runtime'
Assert-Equal (Get-PackageAction ([version]'14.51.1') ([version]'14.44.1') 'install' $false) 'install' 'older runtime'
foreach ($mode in @('install', 'update', 'repair')) {
    Assert-Equal (Get-PackageAction ([version]'14.51.1') ([version]'14.52.1') $mode $true) 'skip' "Never downgrade in $mode mode"
}
Assert-Equal (Get-PackageAction ([version]'14.51.1') $null 'update' $false) 'skip' 'update must not add missing runtime'
Assert-Equal (Get-PackageAction ([version]'14.51.1') ([version]'14.51.1') 'install' $true) 'skip' 'repeat installation'
Assert-Equal (Get-PackageAction ([version]'14.51.1') ([version]'14.51.1') 'repair' $true) 'repair' 'repair registered package'
Assert-Equal (Get-PackageAction ([version]'14.51.1') ([version]'14.51.1') 'repair' $false) 'skip' 'do not repair a different product with this MSI'
Assert-Equal (Get-PackageAction ([version]'10.0.40219.473') ([version]'10.0.40219.325') 'install' $true) 'install' 'VC2010 DLL patch update despite identical MSI metadata'
$selectionFixture = @(
    [pscustomobject]@{ id = 'vc14-x86'; type = 'msi'; family = '2026' },
    [pscustomobject]@{ id = 'vc14-x64'; type = 'msi'; family = '2026' },
    [pscustomobject]@{ id = 'vc2005-x86'; type = 'msi'; family = '2005' },
    [pscustomobject]@{ id = 'net8'; type = 'windowsdesktop'; channel = '8.0' },
    [pscustomobject]@{ id = 'net12'; type = 'windowsdesktop'; channel = '12.0' }
)
Assert-Equal ((Select-Components $selectionFixture 'vc14, dotnet-8.0' | ForEach-Object id) -join ',') 'vc14-x86,vc14-x64,net8' 'Select only requested families and both architectures'
Assert-Equal ((Select-Components $selectionFixture 'dotnet-12.0' | ForEach-Object id) -join ',') 'net12' 'Select a future stable Desktop branch'
Assert-Equal @(Select-Components $selectionFixture 'VC14,vc14').Count 2 'Duplicate and case-insensitive selection'
Assert-Throws { Select-Components $selectionFixture '' } 'empty component selection'
Assert-Throws { Select-Components $selectionFixture 'vc14,unknown' } 'unknown component selection must fail before any installation'
$temp = [IO.Path]::GetTempPath()
$reportDirectory = Join-Path $temp ('runtime-report-test-' + [guid]::NewGuid().ToString('N'))
try {
    $result = New-InstallationResult ([pscustomobject]@{ id = '2010-x86'; name = 'Visual C++ 2010'; arch = 'x86'; version = '10.0.40219.473' })
    $result.before = '10.0.40219.325'; $result.after = '10.0.40219.473'; $result.status = 'updated'; $result.exitCode = 3010
    $pending = New-InstallationResult ([pscustomobject]@{ id = 'pending'; name = 'Unprocessed package'; arch = 'x64'; version = '1.0' })
    Save-InstallationReport @($result, $pending) $reportDirectory $true 'A later package failed'
    $report = Get-Content (Join-Path $reportDirectory 'report.json') -Raw | ConvertFrom-Json
    Assert-Equal $report.success $false 'An incomplete installation must not be reported as successful'
    Assert-Equal $report.rebootRequired $true 'Preserve a reboot request when a later package fails'
    Assert-Equal $report.packages[0].before '10.0.40219.325' 'Preserve original installed version in report'
    Assert-Equal $report.packages[0].after '10.0.40219.473' 'Preserve confirmed resulting version in report'
    Assert-Equal $report.packages[1].status 'not-run' 'Do not claim installation of unprocessed packages'
    Assert-Equal $report.packages[0].exitCode 3010 'Preserve the native installer exit code'
    Assert-Equal ((Get-Content (Join-Path $reportDirectory 'report.txt') -Raw).Contains('10.0.40219.473')) $true 'Readable report retains the complete patch version'
    Complete-InstallationResult $result ([version]'10.0.40219.325') ([version]'10.0.40219.325') 'install' 'test.log'
    Assert-Equal $result.status 'pending-reboot' 'A deferred replacement is pending rather than confirmed or failed'
    Assert-Equal $result.after '10.0.40219.325' 'Do not claim the new DLL version before reboot'
    Complete-InstallationResult $result $null ([version]'10.0.40219.325') 'install' 'test.log'
    Assert-Equal $result.after '' 'Do not invent a version when replacement is pending'
    $result.exitCode = 0
    Assert-Throws { Complete-InstallationResult $result ([version]'10.0.40219.325') ([version]'10.0.40219.325') 'install' 'test.log' } 'Without a reboot request, an unconfirmed update is an error'
    Complete-InstallationResult $result ([version]'10.0.40219.473') ([version]'10.0.40219.325') 'install' 'test.log'
    Assert-Equal $result.status 'updated' 'Confirm a completed DLL patch update'
    $result.exitCode = 3010
    Complete-InstallationResult $result ([version]'10.0.40219.473') ([version]'10.0.40219.473') 'repair' 'test.log'
    Assert-Equal $result.status 'repaired' 'A confirmed repair can still request a reboot'
} finally { Remove-Item $reportDirectory -Recurse -Force }
Assert-Throws { Get-PayloadPath $temp '../outside.exe' } 'path traversal'
Assert-Throws { Get-PayloadPath $temp ([IO.Path]::GetFullPath($temp)) } 'absolute payload path'
Assert-Equal (Get-PayloadPath $temp 'payload/file.msi') ([IO.Path]::GetFullPath((Join-Path $temp 'payload/file.msi'))) 'safe payload path'
# Automation methods can return DBNull rather than PowerShell's null. These
# return values must not contaminate the single string read from an MSI table.
$record = New-Object psobject
$record | Add-Member ScriptMethod StringData { param($index) '8.0.61186' }
$view = New-Object psobject -Property @{ Record = $record }
$view | Add-Member ScriptMethod Execute { [DBNull]::Value }
$view | Add-Member ScriptMethod Close { [DBNull]::Value }
$view | Add-Member ScriptMethod Fetch { $this.Record }
$database = New-Object psobject -Property @{ View = $view }
$database | Add-Member ScriptMethod OpenView { param($query) $this.View }
Assert-Equal (Get-MsiProperty $database 'ProductVersion') '8.0.61186' 'MSI property must be a scalar string'

$releaseDirectory = Join-Path $temp ('runtime-release-test-' + [guid]::NewGuid().ToString('N'))
$savedTestRun = $env:VERIFIED_RUN_ID
try {
    $null = New-Item -ItemType Directory $releaseDirectory
    $env:VERIFIED_RUN_ID = '123456'
    $releaseFixture = @{
        fingerprint = ('a' * 64); builtAt = '2026-01-02T03:04:05Z'
        sources = @(@{ id = 'vc14-x64'; version = '14.51.36247.0' })
        packages = @(@{ type = 'windowsdesktop'; arch = 'x64'; version = '8.0.31' })
    }
    $releaseFixture | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $releaseDirectory 'manifest.json') -Encoding UTF8
    $notes = & "$PSScriptRoot/Release.ps1" -Directory $releaseDirectory -Preview
    Assert-Equal $notes.tag 'runtimes-aaaaaaaaaaaa' 'Release identity follows the verified fingerprint'
    Assert-Equal $notes.body.Contains('14.51.36247.0') $true 'Release lists the actual VC++ version'
    Assert-Equal $notes.body.Contains('8.0.31') $true 'Release lists the actual Desktop version'
    Assert-Equal $notes.body.Contains('/actions/runs/123456)') $true 'Release links to the verified run'
    Assert-Equal $notes.body.Contains('`/ai /gm2`') $true 'Release preserves the silent-install command'
    $releaseFixture.fingerprint = 'invalid'
    $releaseFixture | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $releaseDirectory 'manifest.json') -Encoding UTF8
    Assert-Throws { & "$PSScriptRoot/Release.ps1" -Directory $releaseDirectory -Preview } 'Reject an invalid release identity'
} finally {
    $env:VERIFIED_RUN_ID = $savedTestRun
    Remove-Item $releaseDirectory -Recurse -Force
}
$checks += & "$PSScriptRoot/Test-Release.ps1"
if ([Environment]::OSVersion.Platform -eq 'Win32NT') {
    $engine = New-Object -ComObject WindowsInstaller.Installer
    try {
        $absent = [pscustomobject]@{ type = 'msi'; upgradeCode = [guid]::NewGuid().ToString('B'); productCode = [guid]::NewGuid().ToString('B') }
        Assert-Equal (Get-InstalledVersion $engine $absent) $null 'Empty Windows Installer COM collection'
    } finally { $null = [Runtime.InteropServices.Marshal]::FinalReleaseComObject($engine) }
    $fixture = Join-Path $temp ('runtime-package-code-' + [guid]::NewGuid().ToString('N') + '.msi')
    $engine = New-Object -ComObject WindowsInstaller.Installer
    $database = $null; $summary = $null
    try {
        $database = $engine.OpenDatabase($fixture, 3)
        $null = $database.Commit()
        $null = [Runtime.InteropServices.Marshal]::FinalReleaseComObject($database)
        $database = $null
        $first = Reset-MsiPackageCode $fixture
        $second = Reset-MsiPackageCode $fixture
        Assert-Equal ($first -ne $second) $true 'Each repack gets a distinct package identity'
        Assert-Equal $second $second.ToUpperInvariant() 'MSI package GUID uses uppercase letters'
        $null = [guid]::Parse($second)
        $summary = $engine.SummaryInformation($fixture, 0)
        Assert-Equal $summary.Property(9) $second 'Package identity is persisted in the MSI summary stream'
    } finally {
        if ($summary) { $null = [Runtime.InteropServices.Marshal]::FinalReleaseComObject($summary) }
        if ($database) { $null = [Runtime.InteropServices.Marshal]::FinalReleaseComObject($database) }
        $null = [Runtime.InteropServices.Marshal]::FinalReleaseComObject($engine)
        Remove-Item $fixture -ErrorAction SilentlyContinue
    }
}
Write-Host "$checks checks passed."
