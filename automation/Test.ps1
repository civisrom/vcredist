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
if ([Environment]::OSVersion.Platform -eq 'Win32NT') {
    $engine = New-Object -ComObject WindowsInstaller.Installer
    try {
        $absent = [pscustomobject]@{ type = 'msi'; upgradeCode = [guid]::NewGuid().ToString('B'); productCode = [guid]::NewGuid().ToString('B') }
        Assert-Equal (Get-InstalledVersion $engine $absent) $null 'Empty Windows Installer COM collection'
    } finally { $null = [Runtime.InteropServices.Marshal]::FinalReleaseComObject($engine) }
}
Write-Host "$checks checks passed."
