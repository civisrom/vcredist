param([Parameter(Mandatory)] [string] $PayloadRoot, [string] $ScreenshotDirectory)
$env:PSModulePath = Join-Path $PSHOME 'Modules'
. (Join-Path $PayloadRoot 'Install.ps1')
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -Path "$PSScriptRoot/probes/WindowProbe.cs" -ReferencedAssemblies System, System.Drawing, System.Windows.Forms
if ($ScreenshotDirectory) { $null = New-Item -ItemType Directory $ScreenshotDirectory -Force }

function Assert-Layout($Control) {
    foreach ($child in $Control.Controls) {
        if (-not $child.Visible) { continue }
        if ($child -is [Windows.Forms.Label] -or $child -is [Windows.Forms.Button]) {
            if ($child.Left -lt 0 -or $child.Top -lt 0 -or $child.Right -gt $Control.ClientSize.Width + 1 -or $child.Bottom -gt $Control.ClientSize.Height + 1) {
                throw "Control outside its parent: $($child.Name) $($child.Bounds) / $($Control.ClientSize)"
            }
            $size = $child.GetPreferredSize((New-Object Drawing.Size($child.Width, 0)))
            if ($size.Height -gt $child.Height + 1) { throw "Clipped text height: $($child.Name), $size / $($child.Size)" }
            if ($child -is [Windows.Forms.Button] -and $child.GetPreferredSize([Drawing.Size]::Empty).Width -gt $child.Width + 1) {
                throw "Clipped button text: $($child.Name)"
            }
        }
        if ($child -is [Windows.Forms.TableLayoutPanel] -or $child -is [Windows.Forms.FlowLayoutPanel]) { Assert-Layout $child }
    }
}

function Save-Window($Window, [string] $Name) {
    $Window.PerformLayout()
    [Windows.Forms.Application]::DoEvents()
    $native = [RuntimeWindowProbe]::Windows([IntPtr]::Zero) | Where-Object Handle -eq $Window.Handle
    if (-not $native) { throw 'The tested window is not visible.' }
    if ($ScreenshotDirectory) {
        $bitmap = New-Object Drawing.Bitmap($Window.Width, $Window.Height)
        try {
            $Window.DrawToBitmap($bitmap, (New-Object Drawing.Rectangle(0, 0, $bitmap.Width, $bitmap.Height)))
            $bitmap.Save((Join-Path $ScreenshotDirectory "$Name.png"), [Drawing.Imaging.ImageFormat]::Png)
        } finally { $bitmap.Dispose() }
    }
    [RuntimeWindowProbe]::AssertTextFits($native)
    Assert-Layout $Window
}

$packages = @()
foreach ($family in @('2005', '2008', '2010', '2012', '2013', '2026', 'vbc', 'vstor')) {
    $packages += [pscustomobject]@{ id = "vc-$family"; type = 'msi'; family = $family; arch = 'x64'; version = '14.51.36247'; name = "Microsoft Visual C++ $family Additional Runtime - 14.51.36247 (x64)" }
}
foreach ($channel in @('6.0', '7.0', '8.0', '9.0', '10.0', '12.0')) {
    $packages += [pscustomobject]@{ id = "desktop-$channel"; type = 'windowsdesktop'; family = 'dotnet'; channel = $channel; arch = 'x64'; version = "$channel.31"; name = ".NET Windows Desktop Runtime $channel" }
}
$statuses = @('installed', 'updated', 'repaired', 'skipped', 'not-selected', 'not-applicable', 'failed', 'not-run', 'pending-reboot')
$rows = @()
for ($index = 0; $index -lt 32; $index++) {
    $row = New-InstallationResult $packages[$index % $packages.Count]
    $row.before = '14.44.35211'
    $row.after = '14.51.36247'
    $row.status = $statuses[$index % $statuses.Count]
    $row.reason = 'Компонент обработан. Проверяется перенос длинного описания результата установки и сохранение всех цифр в номерах версий.'
    $rows += $row
}
$temp = Join-Path ([IO.Path]::GetTempPath()) ('runtime-ui-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory $temp
try {
    foreach ($fontSize in @(10, 12.5, 15, 20)) {
        foreach ($scenario in @('selection', 'result', 'reboot', 'failure')) {
            $script:uiFailure = $null
            $script:callbackRan = $false
            $timer = New-Object Windows.Forms.Timer
            $timer.Interval = 250
            $timer.Add_Tick({
                $timer.Stop()
                $script:callbackRan = $true
                $window = [Windows.Forms.Application]::OpenForms[0]
                try {
                    $window.Font = New-Object Drawing.Font('Segoe UI', $fontSize)
                    Save-Window $window "$scenario-$fontSize-top"
                    if ($scenario -eq 'selection') {
                        $list = $window.Controls.Find('ComponentList', $true)[0]
                        if ($list.Items.Count -ne $packages.Count) { throw 'The selector lost components.' }
                        $list.TopIndex = $list.Items.Count - 1
                        Save-Window $window "$scenario-$fontSize-bottom"
                        $window.Controls.Find('CancelSelection', $true)[0].PerformClick()
                    } else {
                        $grid = $window.Controls.Find('ResultTable', $true)[0]
                        $detail = $window.Controls.Find('ResultDetail', $true)[0]
                        if (-not $detail.Text.Contains($displayRows[0].reason)) { throw 'Initial result details are missing.' }
                        if ($grid.Rows.Count -ne $rows.Count) { throw 'The report lost rows.' }
                        for ($rowIndex = 0; $rowIndex -lt $grid.Rows.Count; $rowIndex++) {
                            $grid.CurrentCell = $grid.Rows[$rowIndex].Cells[0]
                            if (-not $detail.Text.Contains($displayRows[$rowIndex].name) -or -not $detail.Text.Contains($displayRows[$rowIndex].reason)) { throw "Missing result details for row $rowIndex" }
                            $grid.FirstDisplayedScrollingRowIndex = $rowIndex
                            $grid.AutoResizeRow($rowIndex, [Windows.Forms.DataGridViewAutoSizeRowMode]::AllCells)
                        }
                        Save-Window $window "$scenario-$fontSize-bottom"
                        $window.Controls.Find('CloseResult', $true)[0].PerformClick()
                    }
                } catch {
                    $script:uiFailure = $_
                    if ($window) { $window.Dispose() }
                }
            })
            try {
                $timer.Start()
                if ($scenario -eq 'selection') { $null = Show-PackageSelection $packages }
                else {
                    $failure = if ($scenario -eq 'failure') { 'Ошибка установки компонента. Не удалось завершить обработку пакета; остальные выбранные компоненты не устанавливались.' } else { '' }
                    $displayRows = @($rows | ForEach-Object { $_.PSObject.Copy() })
                    if ($scenario -ne 'failure') {
                        foreach ($row in $displayRows | Where-Object { $_.status -in @('failed', 'not-run') }) { $row.status = 'skipped' }
                    }
                    if ($scenario -ne 'reboot') {
                        foreach ($row in $displayRows | Where-Object status -eq 'pending-reboot') { $row.status = 'skipped' }
                    }
                    Save-InstallationReport $displayRows $temp ($scenario -eq 'reboot') $failure
                    Show-InstallationResult $displayRows $temp ($scenario -eq 'reboot') $failure
                }
                if ($script:uiFailure) { throw $script:uiFailure }
                if (-not $script:callbackRan) { throw 'The visual test did not run.' }
                Write-Host "PASS: interface $scenario, font $fontSize"
            } finally { $timer.Stop(); $timer.Dispose() }
        }
        $progress = New-InstallationProgress
        try {
            $progress.Font = New-Object Drawing.Font('Segoe UI', $fontSize)
            Set-InstallationProgress $progress 'Восстановление — компонент 12 из 31' 'Microsoft Visual Studio 2010 Tools for Office Runtime (x64). Версия: 10.0.60922. Дождитесь завершения обработки выбранного компонента.' 12 31
            Save-Window $progress "progress-$fontSize"
        } finally { $progress.Dispose() }
    }
} finally { Remove-Item $temp -Recurse -Force }
