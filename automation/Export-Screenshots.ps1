param([Parameter(Mandatory)] [string] $Directory, [Parameter(Mandatory)] [string] $Output)
$ErrorActionPreference = 'Stop'
if (-not $env:SCREENSHOT_CERTIFICATE) { throw 'A public encryption certificate is required.' }
$images = @(Get-ChildItem $Directory -Filter '*.png' -File -Recurse)
if (-not $images.Count) { throw 'No screenshots were captured.' }
$certificate = Join-Path $env:RUNNER_TEMP 'screenshot-recipient.pem'
$archive = Join-Path $env:RUNNER_TEMP 'screenshots.zip'
try {
    $env:SCREENSHOT_CERTIFICATE | Set-Content $certificate -Encoding ascii
    Compress-Archive -Path "$Directory/*" -DestinationPath $archive -Force
    $openssl = Get-Command openssl -ErrorAction SilentlyContinue
    $executable = if ($openssl) { $openssl.Source } else { 'C:\Program Files\Git\usr\bin\openssl.exe' }
    & $executable cms -encrypt -binary -aes-256-cbc -in $archive -outform DER -out $Output $certificate
    if ($LASTEXITCODE -ne 0) { throw 'Screenshot encryption failed.' }
    Write-Host "Encrypted $($images.Count) screenshots for local review."
} finally {
    Remove-Item $archive, $certificate -Force -ErrorAction SilentlyContinue
}
