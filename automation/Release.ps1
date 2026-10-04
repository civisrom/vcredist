param([string] $Directory = (Join-Path (Split-Path $PSScriptRoot) 'dist'), [switch] $Preview)
. "$PSScriptRoot/Common.ps1"
$manifest = Get-Content (Join-Path $Directory 'manifest.json') -Raw | ConvertFrom-Json
if ($manifest.fingerprint -notmatch '^[a-f0-9]{64}$') { throw 'Invalid release fingerprint.' }
$tag = 'runtimes-' + $manifest.fingerprint.Substring(0, 12)
# The build time in UTC: the same verified package keeps its name on a repeated run.
$title = 'v' + ([datetime] $manifest.builtAt).ToUniversalTime().ToString('yyyy.MM.dd-HH.mm', [Globalization.CultureInfo]::InvariantCulture)
$vc = ($manifest.sources | Where-Object id -eq 'vc14-x64').version
$net = ($manifest.packages | Where-Object { $_.type -eq 'windowsdesktop' -and $_.arch -eq 'x64' } | ForEach-Object version) -join ', '
$testRun = if ($env:VERIFIED_RUN_ID) { $env:VERIFIED_RUN_ID } else { $env:GITHUB_RUN_ID }
$body = @"
Офлайн-установщик библиотек для Windows 10/11 x86/x64 с выбором компонентов и итоговым отчётом о версиях и результатах установки.

- Visual C++ 2005–2013, актуальный v14 ($vc), VSTO и старые VB/C.
- .NET Windows Desktop Runtime: $net.
- Проверены установка, восстановление и удаление на Windows 10 22H2, Windows 11 25H2 и Windows Server 2022/2025; на клиентских Windows — обновление смешанного набора старых версий, защита от понижения, интерфейс и повторный запуск после перезагрузки.

Visual C++ упакован компактно; .NET включён оригинальными установщиками Microsoft. Для тихой установки всего набора: ``/ai /gm2``. Состав и SHA256 приложены к релизу.

[Инструкция](https://github.com/$env:GITHUB_REPOSITORY#readme) · [Проверки](https://github.com/$env:GITHUB_REPOSITORY/actions/runs/$testRun)
"@
if ($Preview) { [pscustomobject]@{ tag = $tag; title = $title; body = $body }; return }
if ($env:GITHUB_REF -ne 'refs/heads/master') { throw 'Releases are only published from master.' }
$files = @('Runtimes_AIO_x86_x64.exe', 'manifest.json', 'SHA256SUMS')
foreach ($file in $files) { if (-not (Test-Path (Join-Path $Directory $file))) { throw "Missing release asset: $file" } }
$expectedHash = ((Get-Content (Join-Path $Directory 'SHA256SUMS') -Raw).Trim() -split '\s+')[0]
if ((Get-Sha256 (Join-Path $Directory $files[0])) -ne $expectedHash) { throw 'Release installer SHA256 mismatch.' }

function Get-RepositoryRelease {
    # The REST tag endpoint returns published releases only. The CLI also finds drafts.
    $metadata = & gh release view $tag --json databaseId 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    $releaseId = ($metadata | ConvertFrom-Json).databaseId
    $json = & gh api "repos/$env:GITHUB_REPOSITORY/releases/$releaseId"
    if ($LASTEXITCODE -ne 0) { throw 'Could not read release metadata.' }
    $json | ConvertFrom-Json
}
$existing = Get-RepositoryRelease
$releaseExists = $null -ne $existing
if ($releaseExists -and -not $existing.draft) {
    foreach ($file in $files) {
        if (@($existing.assets | Where-Object { $_.name -eq $file -and $_.state -eq 'uploaded' }).Count -ne 1) {
            throw "Published release is missing an asset: $file"
        }
    }
    $previous = Join-Path $env:RUNNER_TEMP ('release-' + [guid]::NewGuid().ToString('N'))
    Invoke-Checked 'gh' @('release', 'download', $tag, '--pattern', 'manifest.json', '--dir', $previous)
    $published = Get-Content (Join-Path $previous 'manifest.json') -Raw | ConvertFrom-Json
    if ($published.fingerprint -ne $manifest.fingerprint) { throw 'Release tag belongs to a different package.' }
    Write-Host "Release already published: $tag"
    return
}
$notes = Join-Path $env:RUNNER_TEMP 'runtime-release-notes.md'
$body | Set-Content $notes -Encoding utf8
if (-not $releaseExists) {
    Invoke-Checked 'gh' @('release', 'create', $tag, '--draft', '--target', $env:GITHUB_SHA, '--title', $title, '--notes-file', $notes)
} else {
    Invoke-Checked 'gh' @('release', 'edit', $tag, '--title', $title, '--notes-file', $notes)
}
Invoke-Checked 'gh' (@('release', 'upload', $tag, '--clobber') + @($files | ForEach-Object { Join-Path $Directory $_ }))
$release = Get-RepositoryRelease
if (-not $release) { throw 'Could not verify draft assets.' }
foreach ($file in $files) {
    $asset = @($release.assets | Where-Object { $_.name -eq $file -and $_.state -eq 'uploaded' })
    if ($asset.Count -ne 1 -or $asset[0].digest -ne ('sha256:' + (Get-Sha256 (Join-Path $Directory $file)))) {
        throw "Uploaded release asset hash mismatch: $file"
    }
}
Invoke-Checked 'gh' @('release', 'edit', $tag, '--draft=false', '--latest')
Write-Host "Published https://github.com/$env:GITHUB_REPOSITORY/releases/tag/$tag"
