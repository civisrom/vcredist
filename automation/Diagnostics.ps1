# Output only installation diagnostics, not the runner environment.
$roots = @("$env:ProgramData\civisrom\VisualCppRedist\logs", "$PSScriptRoot/../.build")
foreach ($root in $roots) {
    if (-not (Test-Path $root)) { continue }
    Get-ChildItem $root -Filter '*.log' -Recurse | Sort-Object LastWriteTime -Descending | Select-Object -First 6 | ForEach-Object {
        Write-Host "--- $($_.Name) ---"
        Select-String -LiteralPath $_.FullName -Pattern 'Found dependent|Disallow|WixDependencyCheck|Return value 3|error 0x|Will not uninstall' |
            Select-Object -Last 20 | ForEach-Object { Write-Host $_.Line }
        Get-Content $_.FullName -Tail 35 | Write-Host
    }
}
foreach ($directory in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
    $fxr = Join-Path $directory 'dotnet/host/fxr'
    if (Test-Path $fxr) {
        Get-ChildItem $fxr -Recurse | Select-Object FullName, Length | Format-Table -AutoSize
    }
}
Get-Process | Where-Object MainWindowTitle | Select-Object ProcessName, MainWindowTitle | Format-Table
