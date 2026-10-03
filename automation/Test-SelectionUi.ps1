param([Parameter(Mandatory)] [string] $PayloadRoot)
$env:PSModulePath = Join-Path $PSHOME 'Modules'
. (Join-Path $PayloadRoot 'Install.ps1')
Add-Type -AssemblyName System.Windows.Forms
$fixture = @(
    [pscustomobject]@{ type = 'msi'; family = '2026' },
    [pscustomobject]@{ type = 'windowsdesktop'; channel = '8.0' }
)

# Drive the real modal form through its event loop, including on service desktops.
# Exceptions stay in this process and are reported by the lifecycle test.
foreach ($scenario in @('cancel', 'select')) {
    $script:uiFailure = $null
    $script:callbackRan = $false
    $timer = New-Object Windows.Forms.Timer
    $timer.Interval = 200
    $timer.Add_Tick({
        $timer.Stop()
        $script:callbackRan = $true
        $window = [Windows.Forms.Application]::OpenForms[0]
        try {
            if (-not $window -or -not $window.Visible) { throw 'The package selection dialog did not open.' }
            $list = $window.Controls['ComponentList']
            if ($list.Items.Count -ne 2 -or $list.CheckedItems.Count -ne 2) { throw 'Expected two checked components.' }
            if ($scenario -eq 'cancel') {
                $window.Controls['CancelSelection'].PerformClick()
            } else {
                $window.Controls['ClearSelection'].PerformClick()
                if ($list.CheckedItems.Count -ne 0) { throw 'Clear selection failed.' }
                $window.Controls['SelectAll'].PerformClick()
                if ($list.CheckedItems.Count -ne 2) { throw 'Select all failed.' }
                $window.Controls['ClearSelection'].PerformClick()
                $list.SetItemChecked(0, $true)
                if ($list.CheckedItems.Count -ne 1) { throw 'Individual selection failed.' }
                $window.Controls['InstallSelected'].PerformClick()
            }
        } catch {
            $script:uiFailure = $_
            if ($window) { $window.Close() }
        }
    })
    try {
        $timer.Start()
        $selected = Show-PackageSelection $fixture
        if ($script:uiFailure) { throw $script:uiFailure }
        if (-not $script:callbackRan) { throw 'The form event loop did not run.' }
        if ($scenario -eq 'cancel' -and $selected) { throw 'Cancel selected packages.' }
        if ($scenario -eq 'select' -and $selected -ne 'vc14') { throw "Wrong GUI selection: $selected" }
        Write-Host "PASS: selection dialog $scenario"
    } finally { $timer.Stop(); $timer.Dispose() }
}
