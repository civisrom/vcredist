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

foreach ($path in Get-ChildItem (Split-Path $PSScriptRoot) -Filter '*.ps1' -Recurse | Where-Object { $_.FullName -notmatch '[/\\]\.build[/\\]' }) {
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

Assert-Equal (Get-PackageAction ([version]'14.51.1') $null 'install' $false) 'install' 'missing runtime'
Assert-Equal (Get-PackageAction ([version]'14.51.1') ([version]'14.44.1') 'install' $false) 'install' 'older runtime'
foreach ($mode in @('install', 'update', 'repair')) {
    Assert-Equal (Get-PackageAction ([version]'14.51.1') ([version]'14.52.1') $mode $true) 'skip' "Never downgrade in $mode mode"
}
Assert-Equal (Get-PackageAction ([version]'14.51.1') $null 'update' $false) 'skip' 'update must not add missing runtime'
Assert-Equal (Get-PackageAction ([version]'14.51.1') ([version]'14.51.1') 'install' $true) 'skip' 'repeat installation'
Assert-Equal (Get-PackageAction ([version]'14.51.1') ([version]'14.51.1') 'repair' $true) 'repair' 'repair registered package'
Assert-Equal (Get-PackageAction ([version]'14.51.1') ([version]'14.51.1') 'repair' $false) 'skip' 'do not repair a different product with this MSI'
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
if ([Environment]::OSVersion.Platform -eq 'Win32NT') {
    $engine = New-Object -ComObject WindowsInstaller.Installer
    try {
        $absent = [pscustomobject]@{ type = 'msi'; upgradeCode = [guid]::NewGuid().ToString('B'); productCode = [guid]::NewGuid().ToString('B') }
        Assert-Equal (Get-InstalledVersion $engine $absent) $null 'Empty Windows Installer COM collection'
    } finally { $null = [Runtime.InteropServices.Marshal]::FinalReleaseComObject($engine) }
}
Write-Host "$checks checks passed."
