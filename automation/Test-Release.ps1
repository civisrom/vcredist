# Exercise publishing against a local CLI double; no GitHub requests or writes.
. "$PSScriptRoot/Common.ps1"
$directory = Join-Path ([IO.Path]::GetTempPath()) ('runtime-publish-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory $directory
$savedRef = $env:GITHUB_REF
$savedTemp = $env:RUNNER_TEMP
$global:RuntimeReleaseTestState = @{ exists = $false; draft = $true; assets = @(); uploads = 0; badDigest = $false }
function gh {
    $global:LASTEXITCODE = 0
    if ($args[0] -eq 'api') {
        # A draft is deliberately unavailable through /releases/tags/{tag}.
        if ($args[1] -notmatch '/releases/123$' -or -not $global:RuntimeReleaseTestState.exists) { $global:LASTEXITCODE = 1; return }
        @{ id = 123; draft = $global:RuntimeReleaseTestState.draft; assets = $global:RuntimeReleaseTestState.assets } | ConvertTo-Json -Depth 5
        return
    }
    if ($args[0] -ne 'release') { throw 'Unexpected CLI command in release test.' }
    switch ($args[1]) {
        'view' {
            if (-not $global:RuntimeReleaseTestState.exists) { $global:LASTEXITCODE = 1; return }
            '{"databaseId":123}'
        }
        'create' { $global:RuntimeReleaseTestState.exists = $true }
        'upload' {
            if (-not $global:RuntimeReleaseTestState.draft) { throw 'A published release must not be overwritten.' }
            $global:RuntimeReleaseTestState.uploads++
            $global:RuntimeReleaseTestState.assets = @($args | Select-Object -Last 3 | ForEach-Object {
                $digest = if ($global:RuntimeReleaseTestState.badDigest) { 'sha256:invalid' } else { 'sha256:' + (Get-Sha256 $_) }
                @{ name = [IO.Path]::GetFileName($_); state = 'uploaded'; digest = $digest }
            })
        }
        'edit' { if ('--draft=false' -in $args) { $global:RuntimeReleaseTestState.draft = $false } }
        'download' {
            $target = $args[-1]
            $null = New-Item -ItemType Directory $target -Force
            Copy-Item (Join-Path $directory 'manifest.json') $target
        }
        default { throw 'Unexpected release command in test.' }
    }
}
try {
    $env:GITHUB_REF = 'refs/heads/master'
    $env:RUNNER_TEMP = $directory
    @{
        fingerprint = ('a' * 64); builtAt = '2026-01-02T03:04:05Z'
        sources = @(@{ id = 'vc14-x64'; version = '14.51.36247.0' })
        packages = @(@{ type = 'windowsdesktop'; arch = 'x64'; version = '8.0.31' })
    } | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $directory 'manifest.json') -Encoding UTF8
    $exe = Join-Path $directory 'Runtimes_AIO_x86_x64.exe'
    'test payload' | Set-Content $exe
    ((Get-Sha256 $exe) + '  Runtimes_AIO_x86_x64.exe') | Set-Content (Join-Path $directory 'SHA256SUMS')
    & "$PSScriptRoot/Release.ps1" -Directory $directory 6>$null
    if ($global:RuntimeReleaseTestState.draft -or $global:RuntimeReleaseTestState.uploads -ne 1) { throw 'First publication failed.' }
    & "$PSScriptRoot/Release.ps1" -Directory $directory 6>$null
    if ($global:RuntimeReleaseTestState.uploads -ne 1) { throw 'Repeat publication changed existing assets.' }
    $global:RuntimeReleaseTestState.draft = $true
    & "$PSScriptRoot/Release.ps1" -Directory $directory 6>$null
    if ($global:RuntimeReleaseTestState.draft -or $global:RuntimeReleaseTestState.uploads -ne 2) { throw 'Draft resumption failed.' }
    $global:RuntimeReleaseTestState.draft = $true
    $global:RuntimeReleaseTestState.badDigest = $true
    $rejected = $false
    try { & "$PSScriptRoot/Release.ps1" -Directory $directory 6>$null } catch { $rejected = $true }
    if (-not $rejected -or -not $global:RuntimeReleaseTestState.draft) { throw 'Bad uploaded digest was published.' }
    4
} finally {
    $env:GITHUB_REF = $savedRef
    $env:RUNNER_TEMP = $savedTemp
    Remove-Item $directory -Recurse -Force
    $global:LASTEXITCODE = 0
    Remove-Variable RuntimeReleaseTestState -Scope Global -ErrorAction SilentlyContinue
}
