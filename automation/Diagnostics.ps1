# Output only installation diagnostics, not the runner environment.
$roots = @("$env:ProgramData\civisrom\VisualCppRedist\logs", "$PSScriptRoot/../.build")
foreach ($root in $roots) {
    if (-not (Test-Path $root)) { continue }
    Get-ChildItem $root -Filter '*.log' -Recurse | Sort-Object LastWriteTime -Descending | Select-Object -First 6 | ForEach-Object {
        Write-Host "--- $($_.Name) ---"
        Get-Content $_.FullName -Tail 35 | Write-Host
    }
}
Get-Process | Where-Object MainWindowTitle | Select-Object ProcessName, MainWindowTitle | Format-Table
