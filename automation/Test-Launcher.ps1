param([Parameter(Mandatory)] [string] $ScreenshotDirectory)
# Installer.cmd runs with a hidden console. A failure that the script cannot
# report itself must still reach the user, and must never block a silent run.
$ErrorActionPreference = 'Stop'
$env:PSModulePath = Join-Path $PSHOME 'Modules'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -Path "$PSScriptRoot/probes/WindowProbe.cs" -ReferencedAssemblies System, System.Drawing, System.Windows.Forms
$null = New-Item -ItemType Directory $ScreenshotDirectory -Force
$root = Join-Path ([IO.Path]::GetTempPath()) ('runtime-launcher-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory $root
Copy-Item "$PSScriptRoot/../installer/*" $root

# Returns the exit code, or $null when the launcher is still waiting.
function Invoke-Launcher([string] $Arguments, [string] $Title, [string] $Button, [string] $Capture) {
    $process = Start-Process $env:ComSpec -ArgumentList "/c `"`"$root\Installer.cmd`" $Arguments`"" -WindowStyle Hidden -PassThru
    $null = $process.Handle
    $deadline = [DateTime]::UtcNow.AddSeconds(90)
    $clicked = $false
    try {
        while (-not $process.HasExited -and [DateTime]::UtcNow -lt $deadline) {
            $window = if ($Title -and -not $clicked) { [RuntimeWindowProbe]::Windows([IntPtr]::Zero) | Where-Object Title -Like $Title | Select-Object -First 1 }
            if ($window) {
                [RuntimeWindowProbe]::Capture($window, (Join-Path $ScreenshotDirectory "$Capture.png"))
                [RuntimeWindowProbe]::AssertTextFits($window)
                $script:shown = @([RuntimeWindowProbe]::Windows($window.Handle).Title) -join "`n"
                $target = @([RuntimeWindowProbe]::Windows($window.Handle) | Where-Object { $_.ClassName -match 'BUTTON' -and $_.Title.Replace('&', '') -in @($Button, 'OK', 'ОК') })
                if ($target.Count -ne 1) { throw "Button not found in $($window.Title)" }
                [RuntimeWindowProbe]::Click($target[0].Handle)
                $clicked = $true
            }
            Start-Sleep -Milliseconds 100
            $process.Refresh()
        }
        if (-not $process.HasExited) { return $null }
        if ($Title -and -not $clicked) { throw "The window '$Title' was not shown for: $Arguments" }
        $process.ExitCode
    } finally { if (-not $process.HasExited) { & taskkill.exe /pid $process.Id /t /f | Out-Host } }
}

try {
    # The script runs but has no package: it reports the failure by itself.
    $script:shown = ''
    $code = Invoke-Launcher '-Mode check -ShowPlan' 'Проверка состава*' 'Закрыть' 'check-failure'
    if ($code -ne 1) { throw "A failed package check must return 1 after its own window, got $code" }
    Write-Host 'PASS: a failure handled by the script is shown once, in its own window'
    $code = Invoke-Launcher '-Quiet'
    if ($code -ne 1) { throw "A silent handled failure must return 1 without windows, got $code" }
    Write-Host 'PASS: a silent handled failure returns its code without windows'

    # The script cannot start at all, as under a restrictive execution policy.
    $script = Join-Path $root 'Install.ps1'
    [IO.File]::WriteAllText($script, '}' + [IO.File]::ReadAllText($script), (New-Object Text.UTF8Encoding($true)))
    $script:shown = ''
    $code = Invoke-Launcher '-SelectPackages' 'Runtimes AIO' 'OK' 'start-failure'
    if ($null -eq $code -or $code -eq 0) { throw "A start failure must return its error code, got $code" }
    if ($script:shown -notlike '*Installer.cmd*' -or $script:shown -notlike "*$code*") { throw "The start failure message is incomplete: $script:shown" }
    Write-Host 'PASS: a start failure behind the hidden console is shown to the user'
    foreach ($arguments in @('-Quiet', '-Mode check', '-Mode update -Quiet -Components "vc14,dotnet-8.0"')) {
        $code = Invoke-Launcher $arguments
        if ($null -eq $code -or $code -eq 0) { throw "A silent start failure must return an error at once: $arguments, got $code" }
    }
    Write-Host 'PASS: a start failure never opens a window in silent and console modes'
} finally { Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue }
