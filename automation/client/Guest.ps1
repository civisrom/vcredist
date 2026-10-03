$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$share = '\\host.lan\Data'
for ($i = 0; $i -lt 60 -and -not (Test-Path "$share\platform.txt"); $i++) { Start-Sleep 5 }
if (-not (Test-Path "$share\platform.txt")) { throw 'The isolated test share is unavailable.' }
$platform = (Get-Content "$share\platform.txt" -Raw).Trim()
$root = 'C:\RuntimeTests'
$resumed = Test-Path "$root\reboot-pending.txt"
$null = New-Item -ItemType Directory -Path $root -Force
$null = Start-Transcript -Path "$share\guest.log" -Append
$success = $false
$rebootReady = $false
try {
    if (-not $resumed) {
        Copy-Item "$share\automation", "$share\installer" $root -Recurse -Force
        $null = New-Item -ItemType Directory "$root\.build\dist" -Force
        Copy-Item "$share\dist\*" "$root\.build\dist" -Force
        Set-Content "$root\disposable-vm.txt" $platform
        foreach ($tool in @(
            @{ url = 'https://github.com/PowerShell/PowerShell/releases/download/v7.6.6/PowerShell-7.6.6-win-x64.zip'; file = 'pwsh.zip'; hash = '02fe458be20493fbdf43f61ea20610b811ee6c738ab1676c61b9cfcd1a33c860' },
            @{ url = 'https://github.com/ip7z/7zip/releases/download/26.03/7z2603-x64.exe'; file = '7zip.exe'; hash = '0859c524b8a63551848f0c246abddcb1d0b7b656b0fbfe879f8d85e61a9e6edd' }
        )) {
            $path = Join-Path $root $tool.file
            Invoke-WebRequest -UseBasicParsing $tool.url -OutFile $path
            if ((Get-FileHash $path -Algorithm SHA256).Hash -ne $tool.hash) { throw "Test tool hash mismatch: $path" }
        }
        Expand-Archive "$root\pwsh.zip" "$root\pwsh" -Force
        $process = Start-Process "$root\7zip.exe" -ArgumentList '/S' -Wait -PassThru
        if ($process.ExitCode -ne 0) { throw '7-Zip installation failed.' }
    }
    $env:PATH = "$env:ProgramFiles\7-Zip;$env:PATH"
    $env:VCR_DISPOSABLE_VM = $platform
    $env:ImageOS = $platform
    Set-Location $root
    if ($resumed) {
        & "$root\pwsh\pwsh.exe" -NoProfile -File "$root\automation\client\After-Reboot.ps1" | Out-Host
        if ($LASTEXITCODE -ne 0) { throw 'Runtime verification after reboot failed.' }
        $success = $true
    } else {
        & "$root\pwsh\pwsh.exe" -NoProfile -File "$root\automation\Test.ps1" | Out-Host
        if ($LASTEXITCODE -ne 0) { throw 'PowerShell 7 tests failed.' }
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$root\automation\Test.ps1" | Out-Host
        if ($LASTEXITCODE -ne 0) { throw 'Windows PowerShell tests failed.' }
        & "$root\pwsh\pwsh.exe" -NoProfile -File "$root\automation\Smoke.ps1" -ClientWindows $platform | Out-Host
        if ($LASTEXITCODE -ne 0) { throw 'Client lifecycle tests failed.' }
        Set-Content "$root\reboot-pending.txt" (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')
        # Resume under the same interactive test account after a real reboot.
        Set-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce' 'RuntimeVerification' 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\OEM\Guest.ps1'
        $rebootReady = $true
        Write-Host 'Lifecycle passed; rebooting the test VM.'
    }
} catch {
    Write-Host $_
    Write-Host $_.ScriptStackTrace
    if (Test-Path "$root\automation\Diagnostics.ps1") { & "$root\automation\Diagnostics.ps1" }
} finally {
    $null = Stop-Transcript
}
if ($rebootReady) { Restart-Computer -Force; exit }
$result = @{ platform = $platform; success = $success; rebootVerified = ($resumed -and $success) }
$result | ConvertTo-Json | Set-Content "$share\result.tmp" -Encoding ascii
Move-Item "$share\result.tmp" "$share\result.json" -Force
