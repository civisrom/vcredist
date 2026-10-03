param([Parameter(Mandatory)] [string] $Installer, [Parameter(Mandatory)] [string] $ScreenshotDirectory, [switch] $Repeat)
$ErrorActionPreference = 'Stop'
$env:PSModulePath = Join-Path $PSHOME 'Modules'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -Path "$PSScriptRoot/probes/WindowProbe.cs" -ReferencedAssemblies System, System.Drawing, System.Windows.Forms
$null = New-Item -ItemType Directory $ScreenshotDirectory -Force
$script:captures = New-Object 'Collections.Generic.List[object]'

function Save-Stage($Window, [string] $Name) {
    [RuntimeWindowProbe]::Capture($Window, (Join-Path $ScreenshotDirectory "$Name.png"))
    $children = @([RuntimeWindowProbe]::Windows($Window.Handle))
    $script:captures.Add([ordered]@{ file = "$Name.png"; title = $Window.Title; bounds = "$($Window.Bounds)"; text = @($children.Title | Where-Object { $_ }) })
    $script:captures | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $ScreenshotDirectory 'stages.json') -Encoding UTF8
    [RuntimeWindowProbe]::AssertTextFits($Window)
}

function Click-Button($Window, [string[]] $Titles) {
    $button = @([RuntimeWindowProbe]::Windows($Window.Handle) | Where-Object {
        $_.ClassName -match 'BUTTON' -and $_.Title.Replace('&', '') -in $Titles
    })
    if ($button.Count -ne 1) { throw "Button not found: $($Titles -join '/')" }
    [RuntimeWindowProbe]::Click($button[0].Handle)
}

$scenarios = if ($Repeat) { @('install') } else { @('help', 'cancel', 'install') }
foreach ($scenario in $scenarios) {
    # /y suppresses the extraction cancellation prompt; exercise the normal launch.
    $process = if ($scenario -eq 'help') { Start-Process $Installer -ArgumentList '/?' -PassThru }
        else { Start-Process $Installer -PassThru }
    $deadline = [DateTime]::UtcNow.AddMinutes(25)
    $seen = @{}
    $lastDetail = ''
    $packageIndex = 0
    try {
        while (-not $process.HasExited -and [DateTime]::UtcNow -lt $deadline) {
            foreach ($window in @([RuntimeWindowProbe]::Windows([IntPtr]::Zero) | Where-Object Title -Like '*Runtimes AIO*')) {
                $text = @([RuntimeWindowProbe]::Windows($window.Handle).Title) -join "`n"
                if ($scenario -eq 'help' -and -not $seen.help) {
                    Save-Stage $window '01-help'
                    $seen.help = $true
                    Click-Button $window @('OK', 'ОК')
                } elseif ($window.Title -like 'Распаковка*' -and -not $seen.extract) {
                    Save-Stage $window "$scenario-02-extraction"
                    $seen.extract = $true
                    if ($scenario -eq 'cancel') { Click-Button $window @('Отмена', 'Cancel') }
                } elseif ($scenario -eq 'cancel' -and $text -like '*Отменить распаковку*' -and -not $seen.cancel) {
                    Save-Stage $window '03-cancel-confirmation'
                    $seen.cancel = $true
                    Click-Button $window @('Yes', 'Да')
                } elseif ($scenario -eq 'install' -and $window.Title -like 'Выбор библиотек*' -and -not $seen.selection) {
                    Save-Stage $window '05-package-selection'
                    $seen.selection = $true
                    Click-Button $window @('Установить')
                } elseif ($scenario -eq 'install' -and $window.Title -like 'Установка библиотек*') {
                    if ($text -like '*Проверка файлов*' -and -not $seen.verify) {
                        Save-Stage $window '04-file-verification'
                        $seen.verify = $true
                    } elseif ($text -match 'компонент \d+ из \d+' -and $text -ne $lastDetail) {
                        $packageIndex++
                        Save-Stage $window ('06-package-{0:D2}' -f $packageIndex)
                        $lastDetail = $text
                    }
                } elseif ($scenario -eq 'install' -and $window.Title -like 'Результат установки*' -and -not $seen.result) {
                    Save-Stage $window '07-installation-result'
                    $seen.result = $true
                    Click-Button $window @('Закрыть')
                }
            }
            Start-Sleep -Milliseconds 100
            $process.Refresh()
        }
        if (-not $process.HasExited) { throw "Interactive $scenario timed out." }
        if ($scenario -eq 'help' -and -not $seen.help) { throw 'Help was not shown.' }
        if ($scenario -eq 'cancel' -and (-not $seen.extract -or -not $seen.cancel)) { throw 'Extraction cancellation was not exercised.' }
        if ($scenario -eq 'install') {
            foreach ($stage in @('extract', 'verify', 'selection', 'result')) { if (-not $seen[$stage]) { throw "Missing installation stage: $stage" } }
            if (-not $Repeat -and $packageIndex -lt 2) { throw 'No package installation progress was captured.' }
            $reportFile = Get-ChildItem "$env:ProgramData/civisrom/VisualCppRedist/logs" -Filter report.json -Recurse |
                Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
            $report = Get-Content $reportFile.FullName -Raw | ConvertFrom-Json
            Copy-Item $reportFile.FullName (Join-Path $ScreenshotDirectory 'installation-report.json')
            if (-not $report.success) { throw "Interactive installation failed: $($report.error)" }
            if ($Repeat -and (@($report.packages | Where-Object { $_.status -notin @('skipped', 'not-applicable') -or $null -ne $_.exitCode }).Count -or $packageIndex)) {
                throw 'The repeated interactive installation did not skip all equal versions.'
            }
        }
        Write-Host "PASS: interactive $scenario"
    } finally {
        if (-not $process.HasExited) { & taskkill.exe /pid $process.Id /t /f | Out-Host }
    }
}
