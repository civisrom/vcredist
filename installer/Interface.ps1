function Get-ComponentLabel([string] $Id) {
    switch ($Id) {
        'vc14' { 'Visual C++ v14 (2015 и новее)' }
        'vbc' { 'Visual Basic / Visual C++ 2002–2003' }
        'vstor' { 'Visual Studio Tools for Office Runtime' }
        default {
            if ($Id -like 'dotnet-*') { ".NET Windows Desktop Runtime $($Id.Substring(7))" }
            else { "Visual C++ $($Id.Substring(2))" }
        }
    }
}

function Get-ResultLabel([string] $Status) {
    switch ($Status) {
        'installed' { 'Установлено' }
        'updated' { 'Обновлено' }
        'repaired' { 'Восстановлено' }
        'pending-reboot' { 'Ожидает перезагрузки' }
        'skipped' { 'Пропущено' }
        'not-selected' { 'Не выбрано' }
        'not-applicable' { 'Не требуется' }
        'failed' { 'Ошибка' }
        'planned-install' { 'Будет установлено' }
        'planned-update' { 'Будет обновлено' }
        default { 'Не выполнено' }
    }
}

function New-RuntimeWindow([string] $Title, [int] $Width, [int] $Height) {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [Windows.Forms.Application]::EnableVisualStyles()
    $form = New-Object Windows.Forms.Form
    $form.SuspendLayout()
    $form.Text = "$Title — Runtimes AIO"
    $form.Font = New-Object Drawing.Font('Segoe UI', 10)
    $form.AutoScaleDimensions = New-Object Drawing.SizeF(96, 96)
    $form.AutoScaleMode = 'Dpi'
    $area = [Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $form.ClientSize = New-Object Drawing.Size([Math]::Min($Width, $area.Width - 64), [Math]::Min($Height, $area.Height - 80))
    $form.MinimumSize = New-Object Drawing.Size(680, 400)
    $form.StartPosition = 'CenterScreen'
    $layout = New-Object Windows.Forms.TableLayoutPanel
    $layout.Name = 'WindowLayout'
    $layout.Dock = 'Fill'
    $layout.Padding = New-Object Windows.Forms.Padding(18)
    $layout.ColumnCount = 1
    $layout.RowCount = 3
    $null = $layout.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent', 100)))
    $null = $layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('AutoSize')))
    $null = $layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent', 100)))
    $null = $layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('AutoSize')))
    $form.Controls.Add($layout)
    $form.Tag = @{ Layout = $layout }
    $form.ResumeLayout($true)
    $form
}

function New-RuntimeLabel([string] $Name, [string] $Text) {
    $label = New-Object Windows.Forms.Label
    $label.Name = $Name
    $label.Text = $Text
    $label.UseMnemonic = $false
    $label.AutoSize = $true
    $label.Dock = 'Fill'
    $label.Margin = New-Object Windows.Forms.Padding(0, 0, 0, 14)
    $label
}

function New-RuntimeButtons {
    $panel = New-Object Windows.Forms.FlowLayoutPanel
    $panel.AutoSize = $true
    $panel.Dock = 'Fill'
    $panel.WrapContents = $true
    $panel.Margin = New-Object Windows.Forms.Padding(0, 12, 0, 0)
    $panel
}

function New-RuntimeButton([string] $Name, [string] $Text) {
    $button = New-Object Windows.Forms.Button
    $button.Name = $Name
    $button.Text = $Text
    $button.AutoSize = $true
    $button.MinimumSize = New-Object Drawing.Size(120, 36)
    $button.Padding = New-Object Windows.Forms.Padding(8, 3, 8, 3)
    $button.Margin = New-Object Windows.Forms.Padding(0, 0, 10, 0)
    $button
}

function Show-PackageSelection([object[]] $Packages, [hashtable] $States = @{}) {
    $form = New-RuntimeWindow 'Выбор библиотек' 760 560
    $layout = $form.Tag.Layout
    $description = New-RuntimeLabel 'SelectionDescription' "Выберите библиотеки для установки. Уже установленные такие же или более новые версии будут сохранены.`r`nНа Windows x64 устанавливаются библиотеки обеих архитектур; для VSTO — только x64."
    $layout.Controls.Add($description, 0, 0)
    $list = New-Object Windows.Forms.CheckedListBox
    $list.Name = 'ComponentList'
    $list.Dock = 'Fill'
    $list.IntegralHeight = $false
    $list.CheckOnClick = $true
    $list.HorizontalScrollbar = $true
    $ids = @($Packages | ForEach-Object { Get-ComponentId $_ } | Select-Object -Unique)
    foreach ($id in $ids) {
        $label = Get-ComponentLabel $id
        if ($States[$id]) { $label += " — $($States[$id])" }
        $null = $list.Items.Add($label, $true)
    }
    $layout.Controls.Add($list, 0, 1)
    $buttons = New-RuntimeButtons
    $all = New-RuntimeButton 'SelectAll' 'Выбрать всё'
    $all.Add_Click({ for ($i = 0; $i -lt $list.Items.Count; $i++) { $list.SetItemChecked($i, $true) } })
    $none = New-RuntimeButton 'ClearSelection' 'Снять выбор'
    $none.Add_Click({ for ($i = 0; $i -lt $list.Items.Count; $i++) { $list.SetItemChecked($i, $false) } })
    $install = New-RuntimeButton 'InstallSelected' 'Установить'
    $install.Add_Click({
        if ($list.CheckedIndices.Count -eq 0) { return }
        $form.DialogResult = 'OK'
        $form.Close()
    })
    $list.Add_ItemCheck({ $install.Enabled = ($list.CheckedItems.Count + $(if ($_.NewValue -eq 'Checked') { 1 } else { -1 })) -gt 0 })
    $cancel = New-RuntimeButton 'CancelSelection' 'Отмена'
    $cancel.DialogResult = 'Cancel'
    $buttons.Controls.AddRange(@($all, $none, $install, $cancel))
    $layout.Controls.Add($buttons, 0, 2)
    $form.CancelButton = $cancel
    $form.AcceptButton = $install
    try {
        if ($form.ShowDialog() -ne 'OK') { return $null }
        (@($list.CheckedIndices | ForEach-Object { $ids[$_] }) -join ',')
    } finally { $form.Dispose() }
}

function New-InstallationProgress {
    $form = New-RuntimeWindow 'Установка библиотек' 760 400
    $form.ControlBox = $false
    $form.Add_FormClosing({ if ($_.CloseReason -eq 'UserClosing') { $_.Cancel = $true } })
    $heading = New-RuntimeLabel 'ProgressHeading' 'Подготовка установки'
    $heading.Font = New-Object Drawing.Font('Segoe UI', 13, [Drawing.FontStyle]::Bold)
    $detail = New-RuntimeLabel 'ProgressDetail' 'Проверка файлов и установленных версий...'
    $detail.TextAlign = 'MiddleLeft'
    $bar = New-Object Windows.Forms.ProgressBar
    $bar.Name = 'InstallationProgress'
    $bar.Dock = 'Fill'
    $bar.Height = 26
    $bar.Style = 'Marquee'
    $form.Tag.Layout.Controls.Add($heading, 0, 0)
    $form.Tag.Layout.Controls.Add($detail, 0, 1)
    $form.Tag.Layout.Controls.Add($bar, 0, 2)
    $form.Tag.Heading = $heading
    $form.Tag.Detail = $detail
    $form.Tag.Bar = $bar
    $form.Show()
    [Windows.Forms.Application]::DoEvents()
    $form
}

function Set-InstallationProgress($Window, [string] $Heading, [string] $Detail, [int] $Completed = 0, [int] $Total = 0) {
    if (-not $Window) { return }
    $Window.Tag.Heading.Text = $Heading
    $Window.Tag.Detail.Text = $Detail
    if ($Total -gt 0) {
        $Window.Tag.Bar.Style = 'Continuous'
        $Window.Tag.Bar.Maximum = $Total
        $Window.Tag.Bar.Value = [Math]::Min($Completed, $Total)
    }
    [Windows.Forms.Application]::DoEvents()
}

# With -Plan the same window lists what a normal installation would do.
function Show-InstallationResult([object[]] $Results, [string] $LogDirectory, [bool] $Reboot, [string] $Failure, [switch] $Plan) {
    $form = New-RuntimeWindow $(if ($Plan) { 'Проверка состава' } else { 'Результат установки' }) 1120 680
    $counts = @{}
    foreach ($status in @('installed', 'updated', 'repaired', 'pending-reboot', 'skipped', 'not-selected', 'not-applicable', 'failed', 'not-run', 'planned-install', 'planned-update')) {
        $counts[$status] = @($Results | Where-Object status -eq $status).Count
    }
    $unchanged = $counts.skipped + $counts.'not-selected' + $counts.'not-applicable'
    if ($Plan) {
        $heading = if ($Failure) { 'Проверка завершилась с ошибкой. Подробности приведены ниже.' } else { 'Файлы пакета исправны. Система не изменялась.' }
        $summary = "$heading`r`nБудет установлено: $($counts.'planned-install'). Будет обновлено: $($counts.'planned-update'). Без изменений: $unchanged."
    } else {
        $heading = if ($Failure) { 'Установка завершилась с ошибкой. Подробности приведены ниже.' } else { 'Обработка выбранных библиотек завершена.' }
        $summary = "$heading`r`nУстановлено: $($counts.installed). Обновлено: $($counts.updated). Восстановлено: $($counts.repaired). Пропущено: $unchanged. Ошибок: $($counts.failed). Не выполнено: $($counts.'not-run')."
    }
    if ($Reboot) { $summary += "`r`nДля завершения установки перезагрузите Windows. Ожидают перезагрузки: $($counts.'pending-reboot')." }
    $form.Tag.Layout.Controls.Add((New-RuntimeLabel 'ResultSummary' $summary), 0, 0)
    $grid = New-Object Windows.Forms.DataGridView
    $grid.Name = 'ResultTable'
    $grid.Dock = 'Fill'
    $grid.ReadOnly = $true
    $grid.AllowUserToAddRows = $false
    $grid.AllowUserToDeleteRows = $false
    $grid.AllowUserToResizeRows = $false
    $grid.RowHeadersVisible = $false
    $grid.SelectionMode = 'FullRowSelect'
    $grid.MultiSelect = $false
    $grid.BackgroundColor = [Drawing.SystemColors]::Window
    $grid.BorderStyle = 'FixedSingle'
    $grid.AutoSizeRowsMode = 'AllCells'
    $grid.DefaultCellStyle.WrapMode = 'True'
    $grid.DefaultCellStyle.Padding = New-Object Windows.Forms.Padding(4)
    $grid.ColumnHeadersDefaultCellStyle.WrapMode = 'True'
    $grid.ColumnHeadersHeightSizeMode = 'AutoSize'
    foreach ($column in @(
        @('name', 'Компонент'), @('arch', 'Арх.'), @('versions', 'Версии'), @('outcome', $(if ($Plan) { 'Действие' } else { 'Результат' }))
    )) {
        $null = $grid.Columns.Add($column[0], $column[1])
        $item = $grid.Columns[$column[0]]
        $item.SortMode = 'NotSortable'
        if ($column[0] -ne 'arch') { $item.AutoSizeMode = 'Fill'; $item.MinimumWidth = 170 }
        else { $item.AutoSizeMode = 'AllCells' }
    }
    $colors = @{
        failed = 'Firebrick'; 'pending-reboot' = 'DarkOrange'; installed = 'DarkGreen'; updated = 'DarkGreen'
        repaired = 'DarkGreen'; 'planned-install' = 'DarkGreen'; 'planned-update' = 'DarkGreen'
    }
    foreach ($result in $Results) {
        $before = if ($result.before) { $result.before } else { '—' }
        $after = if ($result.after) { $result.after } else { '—' }
        $versions = if ($Plan) { "В пакете: $($result.available)`r`nУстановлено: $before" }
            else { "В пакете: $($result.available)`r`nДо: $before`r`nПосле: $after" }
        $outcome = Get-ResultLabel $result.status
        $row = $grid.Rows.Add([object[]] @($result.name, $result.arch, $versions, $outcome))
        if ($colors[$result.status] -and -not [Windows.Forms.SystemInformation]::HighContrast) {
            $grid.Rows[$row].Cells['outcome'].Style.ForeColor = [Drawing.Color]::FromName($colors[$result.status])
        }
    }
    $form.Tag.Layout.Controls.Add($grid, 0, 1)
    $form.Tag.Layout.RowCount = 4
    $form.Tag.Layout.RowStyles[2].SizeType = 'Absolute'
    $form.Tag.Layout.RowStyles[2].Height = 100
    $null = $form.Tag.Layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('AutoSize')))
    $detail = New-Object Windows.Forms.TextBox
    $detail.Name = 'ResultDetail'
    $detail.ReadOnly = $true
    $detail.Multiline = $true
    $detail.WordWrap = $true
    $detail.ScrollBars = 'Vertical'
    $detail.Dock = 'Fill'
    $detail.Margin = New-Object Windows.Forms.Padding(0, 10, 0, 0)
    $detail.Text = $Failure
    $updateDetail = {
        if ($grid.CurrentRow) {
            $item = $Results[$grid.CurrentRow.Index]
            $detail.Text = $(if ($Failure) { "$Failure`r`n" }) + $item.name + "`r`n" + $item.reason
        }
    }
    $grid.Add_CurrentCellChanged($updateDetail)
    $form.Add_Shown({
        # Open on the component that failed rather than on the first row.
        for ($index = 0; $index -lt $Results.Count; $index++) {
            if ($Results[$index].status -eq 'failed') { $grid.CurrentCell = $grid.Rows[$index].Cells[0]; break }
        }
        & $updateDetail
    })
    $form.Tag.Layout.Controls.Add($detail, 0, 2)
    $buttons = New-RuntimeButtons
    if (-not $Plan) {
        $report = New-RuntimeButton 'OpenReport' 'Открыть отчёт'
        $report.Enabled = Test-Path (Join-Path $LogDirectory 'report.txt')
        $report.Add_Click({ Start-Process notepad.exe -ArgumentList ('"' + (Join-Path $LogDirectory 'report.txt') + '"') })
        $logs = New-RuntimeButton 'OpenLogs' 'Открыть журналы'
        $logs.Enabled = Test-Path $LogDirectory
        $logs.Add_Click({ Start-Process explorer.exe -ArgumentList ('"' + $LogDirectory + '"') })
        $buttons.Controls.AddRange(@($report, $logs))
    }
    $close = New-RuntimeButton 'CloseResult' 'Закрыть'
    $close.DialogResult = 'OK'
    $buttons.Controls.Add($close)
    $form.Tag.Layout.Controls.Add($buttons, 0, 3)
    $form.AcceptButton = $close
    $form.CancelButton = $close
    try { $null = $form.ShowDialog() } finally { $form.Dispose() }
}
