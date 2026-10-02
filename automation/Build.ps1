param(
    [string] $WorkDirectory = (Join-Path (Split-Path $PSScriptRoot) '.build'),
    [switch] $Force
)
. "$PSScriptRoot/Common.ps1"
if (-not $IsWindows) { throw 'Build requires Windows and PowerShell 7.' }
$root = Split-Path $PSScriptRoot
$work = [IO.Path]::GetFullPath($WorkDirectory)
# Reusing a dirty build could silently mix two runtime versions.
if (Test-Path -LiteralPath $work) { throw "Use an empty work directory: $work" }
$downloads = Join-Path $work 'downloads'
$payload = Join-Path $work 'payload'
$dist = Join-Path $work 'dist'
foreach ($directory in @($downloads, $payload, $dist)) { $null = New-Item -ItemType Directory -Path $directory -Force }
$catalog = Get-Content "$PSScriptRoot/sources.json" -Raw | ConvertFrom-Json -AsHashtable
$sources = [Collections.Generic.List[object]]::new()

function Receive-Source($Source, [switch] $Legacy) {
    $url = $Source['url']
    if ($Source['page']) {
        $page = Join-Path $downloads ($Source.id + '.html')
        $null = Save-Download $Source.page $page -Microsoft
        $url = Get-DownloadLink (Get-Content $page -Raw) $Source.file
    }
    $extension = if ($Source['file'] -like '*.msi') { '.msi' } else { '.exe' }
    $path = Join-Path $downloads ($Source.id + $extension)
    $resolved = Save-Download $url $path -Microsoft
    $hash = Get-Sha256 $path
    if ($Legacy) {
        if ($hash -ne $Source.sha256) {
            throw "Microsoft changed legacy source $($Source.id). Review its contents and update the legacy recipe/baseline before releasing. Do not just accept the new hash."
        }
    } else {
        Assert-MicrosoftSignature $path
    }
    $version = [Diagnostics.FileVersionInfo]::GetVersionInfo($path).FileVersion
    if ($Source['minimumVersion']) {
        if ($version -notmatch '\d+\.\d+\.\d+(?:\.\d+)?') { throw "No file version: $path" }
        $version = $Matches[0]
        if ([version] $version -lt [version] $Source.minimumVersion) { throw "Microsoft returned an older package: $($Source.id) $version" }
    }
    $sources.Add([ordered]@{ id = $Source.id; url = $resolved; sha256 = $hash; version = $version; policy = $(if ($Legacy) { 'pinned-legacy-monitor' } else { 'microsoft-current' }) })
    Write-Host "$($Source.id): $version, SHA256 $hash"
}

foreach ($source in $catalog.current) { Receive-Source $source }
foreach ($source in $catalog.legacyMonitors) { Receive-Source $source -Legacy }

$indexPath = Join-Path $downloads 'dotnet-index.json'
$null = Save-Download 'https://dotnetcli.blob.core.windows.net/dotnet/release-metadata/releases-index.json' $indexPath -Microsoft
$channels = @(Get-DotNetChannels (Get-Content $indexPath -Raw | ConvertFrom-Json))
$desktopPackages = [Collections.Generic.List[object]]::new()
foreach ($channel in $channels) {
    $line = $channel.'channel-version'
    $metadata = Join-Path $downloads "dotnet-$line.json"
    $null = Save-Download $channel.'releases.json' $metadata -Microsoft
    $releases = Get-Content $metadata -Raw | ConvertFrom-Json
    $release = @($releases.releases | Where-Object { $_.'release-version' -eq $channel.'latest-release' })
    if ($release.Count -ne 1) { throw "Ambiguous latest .NET release: $line" }
    $desktop = $release[0].windowsdesktop
    if ($desktop.version -notmatch ('^' + [regex]::Escape($line) + '\.\d+$')) { throw "Invalid stable Desktop Runtime version: $line" }
    foreach ($arch in @('x86', 'x64')) {
        $file = @($desktop.files | Where-Object { $_.rid -eq "win-$arch" -and $_.name -eq "windowsdesktop-runtime-win-$arch.exe" })
        if ($file.Count -ne 1 -or $file[0].hash -notmatch '^[a-fA-F0-9]{128}$') { throw "Missing .NET $line $arch installer or SHA512" }
        $id = "windowsdesktop-$line-$arch"
        $path = Join-Path $downloads "$id.exe"
        $url = Save-Download $file[0].url $path -Microsoft
        if ((Get-FileHash $path -Algorithm SHA512).Hash -ne $file[0].hash) { throw ".NET SHA512 mismatch: $id" }
        Assert-MicrosoftSignature $path
        $sources.Add([ordered]@{ id = $id; url = $url; sha256 = Get-Sha256 $path; version = $desktop.version; policy = 'microsoft-current' })
        $desktopPackages.Add([ordered]@{ id = $id; type = 'windowsdesktop'; family = 'windowsdesktop'; arch = $arch; channel = $line; version = $desktop.version; name = ".NET Windows Desktop Runtime $line"; path = "dotnet/$id.exe" })
        Write-Host "$id`: $($desktop.version) ($($channel.'support-phase'))"
    }
}

# Include all build/install recipes, not timestamps, in the artifact identity.
$recipe = @('automation', 'installer', 'build_tools', '.github/workflows') | ForEach-Object {
    Get-ChildItem (Join-Path $root $_) -File -Recurse | Sort-Object FullName | ForEach-Object {
        $_.FullName.Substring($root.Length).Replace('\', '/') + ':' + (Get-Sha256 $_.FullName)
    }
}
$identity = ($recipe -join "`n") + "`n" + (($sources | ForEach-Object { "$($_.id):$($_.sha256)" }) -join "`n")
$fingerprint = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($identity))).ToLowerInvariant()
$artifactName = "Runtimes_AIO_x86_x64-$fingerprint"
if ($env:GITHUB_OUTPUT) { Add-Content $env:GITHUB_OUTPUT "artifact=$artifactName" }
if (-not $Force -and $env:GITHUB_REPOSITORY -and $env:GH_TOKEN) {
    $response = & gh api "repos/$env:GITHUB_REPOSITORY/actions/artifacts?name=$artifactName&per_page=100"
    if ($LASTEXITCODE -ne 0) { throw 'Could not check previous build artifacts.' }
    $artifacts = $response | ConvertFrom-Json
    if (@($artifacts.artifacts | Where-Object { -not $_.expired }).Count) {
        Write-Host "Verified package already exists: $artifactName"
        Add-Content $env:GITHUB_OUTPUT 'changed=false'
        exit 0
    }
}
if ($env:GITHUB_OUTPUT) { Add-Content $env:GITHUB_OUTPUT 'changed=true' }

$sevenZipCommand = Get-Command 7z.exe -ErrorAction SilentlyContinue
$sevenZip = if ($sevenZipCommand) { $sevenZipCommand.Source } else { "$env:ProgramFiles\7-Zip\7z.exe" }
if (-not (Test-Path $sevenZip)) { throw '7-Zip is required.' }
$baseline = Join-Path $downloads 'baseline.exe'
$null = Save-Download $catalog.baseline.url $baseline -Sha256 $catalog.baseline.sha256
$seed = Join-Path $work 'baseline'
Invoke-Checked $sevenZip @('x', '-y', '-bso0', "-o$seed", $baseline)
foreach ($family in @('2005', '2008', '2010', '2012', '2013', 'vbc')) {
    Copy-Item -LiteralPath (Join-Path $seed $family) -Destination $payload -Recurse
}
# Unused MSI variants must not install the same legacy files twice.
Remove-Item (Join-Path $payload 'vbc/vbrun.msi'), (Join-Path $payload 'vbc/vcrun.msi')
Get-ChildItem $payload -Filter '*.inf' -Recurse | Remove-Item

$wixZip = Join-Path $downloads 'wix.zip'
$null = Save-Download $catalog.wix.url $wixZip -Sha256 $catalog.wix.sha256
$wix = Join-Path $work 'wix'
Expand-Archive -LiteralPath $wixZip -DestinationPath $wix

function New-AdministrativePackage([string] $Msi, [string] $Destination, [string] $Modifier) {
    if ($Modifier) { Invoke-Checked 'cscript.exe' @('//nologo', $Modifier, $Msi) }
    $null = New-Item -ItemType Directory -Path $Destination -Force
    $process = Start-Process msiexec.exe -ArgumentList "/a `"$Msi`" /qn /norestart TARGETDIR=`"$Destination`"" -Wait -PassThru
    if ($process.ExitCode -ne 0) { throw "Administrative MSI extraction failed: $Msi ($($process.ExitCode))" }
}

foreach ($arch in @('x86', 'x64')) {
    $extract = Join-Path $work "vc14-$arch"
    Invoke-Checked "$wix/dark.exe" @('-nologo', (Join-Path $downloads "vc14-$arch.exe"), '-x', $extract)
    foreach ($part in @('Minimum', 'Additional')) {
        $msis = @(Get-ChildItem $extract -Recurse -Filter "vc_runtime${part}_$arch.msi")
        if ($msis.Count -ne 1) { throw "Unexpected VC++ layout: $arch $part" }
        Assert-MicrosoftSignature $msis[0].FullName
        New-AdministrativePackage $msis[0].FullName (Join-Path $payload "2026/$arch") "$root/build_tools/_m14/vc14.vbs"
    }
}

$vstorExtract = Join-Path $work 'vstor-extract'
$process = Start-Process (Join-Path $downloads 'vstor.exe') -ArgumentList "/quiet /extract:`"$vstorExtract`"" -Wait -PassThru
if ($process.ExitCode -ne 0) { throw "VSTO extraction failed: $($process.ExitCode)" }
foreach ($arch in @('x86', 'x64')) {
    $nested = @(Get-ChildItem $vstorExtract -Recurse -Filter "vstor40_$arch.exe")
    if ($nested.Count -ne 1) { throw "Unexpected VSTO layout: $arch" }
    $extract = Join-Path $work "vstor-$arch"
    $process = Start-Process $nested[0].FullName -ArgumentList "/quiet /extract:`"$extract`"" -Wait -PassThru
    if ($process.ExitCode -ne 0) { throw "VSTO $arch extraction failed: $($process.ExitCode)" }
    $msis = @(Get-ChildItem $extract -Recurse -Filter "vstor40_$arch.msi")
    if ($msis.Count -ne 1) { throw "Unexpected VSTO MSI layout: $arch" }
    New-AdministrativePackage $msis[0].FullName (Join-Path $payload "vstor/$arch") "$root/build_tools/_vstor/vstor40.vbs"
}

$null = New-Item -ItemType Directory -Path (Join-Path $payload 'dotnet')
foreach ($package in $desktopPackages) { Copy-Item (Join-Path $downloads "$($package.id).exe") (Join-Path $payload $package.path) }
Copy-Item "$root/installer/Installer.cmd", "$root/installer/Install.ps1" $payload
$packages = [Collections.Generic.List[object]]::new()
foreach ($msi in Get-ChildItem $payload -Recurse -Filter '*.msi' | Sort-Object DirectoryName, @{ Expression = { if ($_.Name -like '*Additional*') { 1 } else { 0 } } }, Name) {
    $relative = $msi.FullName.Substring($payload.Length + 1).Replace('\', '/')
    $parts = $relative.Split('/')
    $metadata = Get-MsiMetadata $msi.FullName
    $metadata['id'] = $relative.Replace('/', '-').Replace('.msi', '')
    $metadata['type'] = 'msi'
    $metadata['family'] = $parts[0]
    $metadata['arch'] = if ($parts[0] -eq 'vbc') { 'x86' } else { $parts[1] }
    $metadata['path'] = $relative
    $packages.Add($metadata)
}
if ($packages.Count -ne 21) { throw "Expected 21 MSI packages, got $($packages.Count)" }
foreach ($package in $desktopPackages) { $packages.Add($package) }
$files = @(Get-ChildItem $payload -File -Recurse | Sort-Object FullName | ForEach-Object {
    [ordered]@{ path = $_.FullName.Substring($payload.Length + 1).Replace('\', '/'); sha256 = Get-Sha256 $_.FullName }
})
$manifest = [ordered]@{
    schema = 1
    fingerprint = $fingerprint
    builtAt = [DateTime]::UtcNow.ToString('o')
    baseline = $catalog.baseline
    legacyVersions = $catalog.legacyVersions
    sources = @($sources.ToArray())
    packages = @($packages.ToArray())
    files = $files
}
$manifest | ConvertTo-Json -Depth 12 | Set-Content (Join-Path $payload 'manifest.json') -Encoding utf8
$archive = Join-Path $work 'payload.7z'
Push-Location $payload
try { Invoke-Checked $sevenZip @('a', $archive, '.', '-t7z', '-m0=LZMA2', '-mx=9', '-ms=on', '-mmt=2', '-bso0') }
finally { Pop-Location }
$exe = Join-Path $dist 'Runtimes_AIO_x86_x64.exe'
$output = [IO.File]::Create($exe)
try {
    foreach ($part in @("$root/build_tools/_AIO/7zSfxMod.sfx", "$root/installer/7zSfxConfig.txt", $archive)) {
        $inputStream = [IO.File]::OpenRead($part)
        try { $inputStream.CopyTo($output) } finally { $inputStream.Dispose() }
    }
} finally { $output.Dispose() }
Invoke-Checked $sevenZip @('t', $exe, '-bso0')
Copy-Item (Join-Path $payload 'manifest.json') $dist
((Get-Sha256 $exe) + '  Runtimes_AIO_x86_x64.exe') | Set-Content (Join-Path $dist 'SHA256SUMS') -Encoding ascii
Write-Host "Built $exe ($((Get-Item $exe).Length) bytes)"
