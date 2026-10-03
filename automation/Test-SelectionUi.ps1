param([Parameter(Mandatory)] [string] $PayloadRoot)
$env:PSModulePath = Join-Path $PSHOME 'Modules'
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
$directory = Join-Path ([IO.Path]::GetTempPath()) ('runtime-ui-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory $directory
$childScript = Join-Path $directory 'dialog.ps1'
@'
param($PayloadRoot, $OutputPath)
$env:PSModulePath = Join-Path $PSHOME 'Modules'
. (Join-Path $PayloadRoot 'Install.ps1')
$fixture = @(
    [pscustomobject]@{ type = 'msi'; family = '2026' },
    [pscustomobject]@{ type = 'windowsdesktop'; channel = '8.0' }
)
$selection = Show-PackageSelection $fixture
ConvertTo-Json -InputObject $selection | Set-Content $OutputPath
'@ | Set-Content $childScript -Encoding UTF8

function Find-Control($Window, [string] $Id) {
    $condition = New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::AutomationIdProperty, $Id)
    $control = $Window.FindFirst([Windows.Automation.TreeScope]::Descendants, $condition)
    if (-not $control) { throw "UI control missing: $Id" }
    $control
}
function Click-Control($Window, [string] $Id) {
    $control = Find-Control $Window $Id
    $control.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
}
function Assert-Toggles($Items, [string[]] $Expected) {
    for ($attempt = 0; $attempt -lt 50; $attempt++) {
        $actual = @($Items | ForEach-Object { $_.GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern).Current.ToggleState.ToString() })
        if (($actual -join ',') -eq ($Expected -join ',')) { return }
        Start-Sleep -Milliseconds 100
    }
    throw "Wrong checkbox state: $($actual -join ',')"
}
try {
    foreach ($scenario in @('cancel', 'select')) {
        $output = Join-Path $directory "$scenario.json"
        $process = Start-Process powershell.exe -ArgumentList "-NoProfile -STA -ExecutionPolicy Bypass -File `"$childScript`" `"$PayloadRoot`" `"$output`"" -PassThru -WindowStyle Hidden
        try {
            $window = $null
            $condition = New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::ProcessIdProperty, $process.Id)
            for ($attempt = 0; $attempt -lt 100 -and -not $window; $attempt++) {
                Start-Sleep -Milliseconds 100
                $window = [Windows.Automation.AutomationElement]::RootElement.FindFirst([Windows.Automation.TreeScope]::Children, $condition)
            }
            if (-not $window) { throw 'The package selection dialog did not open.' }
            if ($scenario -eq 'cancel') {
                Click-Control $window 'CancelSelection'
            } else {
                $list = Find-Control $window 'ComponentList'
                $toggles = $list.FindAll([Windows.Automation.TreeScope]::Descendants,
                    (New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::IsTogglePatternAvailableProperty, $true)))
                if ($toggles.Count -ne 2) { throw "Expected two accessible package checkboxes, got $($toggles.Count)" }
                Assert-Toggles $toggles @('On', 'On')
                Click-Control $window 'ClearSelection'
                Assert-Toggles $toggles @('Off', 'Off')
                Click-Control $window 'SelectAll'
                Assert-Toggles $toggles @('On', 'On')
                Click-Control $window 'ClearSelection'
                Assert-Toggles $toggles @('Off', 'Off')
                $toggles[0].GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern).Toggle()
                Assert-Toggles $toggles @('On', 'Off')
                Click-Control $window 'InstallSelected'
            }
            if (-not $process.WaitForExit(15000)) { throw 'The package selection dialog did not close.' }
            if ($process.ExitCode -ne 0 -or -not (Test-Path $output)) { throw 'Selection dialog failed.' }
            $selected = Get-Content $output -Raw | ConvertFrom-Json
            if ($scenario -eq 'cancel' -and $selected) { throw 'Cancel selected packages.' }
            if ($scenario -eq 'select' -and $selected -ne 'vc14') { throw "Wrong GUI selection: $selected" }
            Write-Host "PASS: selection dialog $scenario"
        } finally { if (-not $process.HasExited) { $process.Kill() }; $process.Dispose() }
    }
} finally { Remove-Item $directory -Recurse -Force }
