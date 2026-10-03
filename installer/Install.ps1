param(
    [ValidateSet('install', 'update', 'repair', 'check')]
    [string] $Mode = 'install',
    [switch] $Quiet,
    [ValidateNotNullOrEmpty()]
    [string] $Components,
    [switch] $SelectPackages
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-ComponentId($Package) {
    if ($Package.type -eq 'windowsdesktop') { return "dotnet-$($Package.channel)" }
    switch ($Package.family) {
        '2026' { 'vc14' }
        'vbc' { 'vbc' }
        'vstor' { 'vstor' }
        default { "vc$($Package.family)" }
    }
}

function Select-Components([object[]] $Packages, [string] $Selection) {
    $ids = @($Selection.Split(',') | ForEach-Object { $_.Trim().ToLowerInvariant() } | Select-Object -Unique)
    $known = @($Packages | ForEach-Object { Get-ComponentId $_ } | Select-Object -Unique)
    foreach ($id in $ids) { if ($id -notin $known) { throw "Неизвестный компонент: '$id'. Доступны: $($known -join ', ')" } }
    @($Packages | Where-Object { (Get-ComponentId $_) -in $ids })
}

function Show-PackageSelection([object[]] $Packages) {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [Windows.Forms.Application]::EnableVisualStyles()
    $form = New-Object Windows.Forms.Form
    $form.Text = 'Выбор библиотек — Runtimes AIO'
    $form.ClientSize = New-Object Drawing.Size(560, 480)
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.Font = New-Object Drawing.Font('Segoe UI', 10)
    $description = New-Object Windows.Forms.Label
    $description.SetBounds(16, 12, 528, 64)
    $description.Text = "Выберите библиотеки для установки. Более новые версии сохранятся.`r`nНа 64-битной Windows устанавливаются варианты x86 и x64."
    $list = New-Object Windows.Forms.CheckedListBox
    $list.Name = 'ComponentList'
    $list.SetBounds(16, 80, 528, 332)
    $list.CheckOnClick = $true
    $ids = @($Packages | ForEach-Object { Get-ComponentId $_ } | Select-Object -Unique)
    foreach ($id in $ids) {
        $label = switch ($id) {
            'vc14' { 'Visual C++ 2015–2026 (v14)' }
            'vbc' { 'Старые Visual Basic / Visual C++ 2002–2003' }
            'vstor' { 'Visual Studio Tools for Office Runtime' }
            default {
                if ($id -like 'dotnet-*') { ".NET Windows Desktop Runtime $($id.Substring(7))" }
                else { "Visual C++ $($id.Substring(2))" }
            }
        }
        $null = $list.Items.Add($label, $true)
    }
    $all = New-Object Windows.Forms.Button
    $all.Name = 'SelectAll'
    $all.Text = 'Выбрать всё'
    $all.SetBounds(16, 432, 120, 32)
    $all.Add_Click({ for ($i = 0; $i -lt $list.Items.Count; $i++) { $list.SetItemChecked($i, $true) } })
    $none = New-Object Windows.Forms.Button
    $none.Name = 'ClearSelection'
    $none.Text = 'Снять выбор'
    $none.SetBounds(144, 432, 120, 32)
    $none.Add_Click({ for ($i = 0; $i -lt $list.Items.Count; $i++) { $list.SetItemChecked($i, $false) } })
    $install = New-Object Windows.Forms.Button
    $install.Name = 'InstallSelected'
    $install.Text = 'Установить'
    $install.SetBounds(304, 432, 120, 32)
    $install.Add_Click({
        if ($list.CheckedIndices.Count -eq 0) { [Windows.Forms.MessageBox]::Show('Выберите хотя бы один компонент.', $form.Text) | Out-Null; return }
        $form.DialogResult = 'OK'
        $form.Close()
    })
    $cancel = New-Object Windows.Forms.Button
    $cancel.Name = 'CancelSelection'
    $cancel.Text = 'Отмена'
    $cancel.SetBounds(432, 432, 112, 32)
    $cancel.DialogResult = 'Cancel'
    $form.CancelButton = $cancel
    $form.AcceptButton = $install
    $form.Controls.AddRange(@($description, $list, $all, $none, $install, $cancel))
    try {
        if ($form.ShowDialog() -ne 'OK') { return $null }
        (@($list.CheckedIndices | ForEach-Object { $ids[$_] }) -join ',')
    } finally { $form.Dispose() }
}

function Get-PackageAction([version] $Available, [version] $Installed, [string] $Mode, [bool] $ExactProduct) {
    if ($Installed -and $Installed -gt $Available) { return 'skip' }
    if ($Mode -eq 'update' -and -not $Installed) { return 'skip' }
    if ($Installed -and $Installed -eq $Available) {
        if ($Mode -eq 'repair' -and $ExactProduct) { return 'repair' }
        return 'skip'
    }
    return 'install'
}

function Get-PayloadPath([string] $Root, [string] $Relative) {
    $prefix = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if ([IO.Path]::IsPathRooted($Relative)) { throw "Недопустимый путь: $Relative" }
    $path = [IO.Path]::GetFullPath((Join-Path $Root $Relative))
    if (-not $path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw "Недопустимый путь: $Relative" }
    $path
}

function Get-InstalledVersion($Engine, $Package) {
    if ($Package.type -eq 'windowsdesktop') { return Get-DesktopVersion $Package }
    $best = $null
    # The native API provides explicit error codes for malformed MSI metadata.
    if (-not ('RuntimeMsi' -as [type])) {
        Add-Type @'
using System.Text;
using System.Runtime.InteropServices;
public static class RuntimeMsi {
    [DllImport("msi.dll", CharSet = CharSet.Unicode)]
    public static extern uint MsiEnumRelatedProducts(string code, uint reserved, uint index, StringBuilder product);
}
'@
    }
    $codes = @($Package.productCode)
    for ([uint32] $i = 0; ; $i++) {
        $buffer = [Text.StringBuilder]::new(39)
        $status = [RuntimeMsi]::MsiEnumRelatedProducts($Package.upgradeCode, 0, $i, $buffer)
        if ($status -eq 259) { break }
        if ($status -ne 0) { throw "MsiEnumRelatedProducts $($Package.id): $status" }
        $codes += $buffer.ToString()
    }
    foreach ($code in $codes) {
        if ($Engine.ProductState($code) -ne 5) { continue }
        $version = [version] $Engine.ProductInfo($code, 'VersionString')
        if (-not $best -or $version -gt $best) { $best = $version }
    }
    $best
}

function Get-DesktopVersion($Package) {
    $programFiles = $env:ProgramFiles
    if ($Package.arch -eq 'x86' -and [Environment]::Is64BitOperatingSystem) { $programFiles = ${env:ProgramFiles(x86)} }
    $dotnet = Join-Path $programFiles 'dotnet\dotnet.exe'
    if (-not (Test-Path -LiteralPath $dotnet)) { return $null }
    $runtimes = @(& $dotnet --list-runtimes)
    if ($LASTEXITCODE -ne 0) { throw "Не удалось проверить библиотеки: $dotnet" }
    $versions = @()
    foreach ($framework in @('Microsoft.NETCore.App', 'Microsoft.WindowsDesktop.App')) {
        $pattern = '^' + [regex]::Escape($framework) + ' (' + [regex]::Escape($Package.channel) + '\.\d+) '
        $found = @($runtimes | ForEach-Object { if ($_ -match $pattern) { [version] $Matches[1] } } | Sort-Object -Descending)
        if ($found.Count) { $versions += $found[0] }
    }
    if ($versions.Count -eq 0) { return $null }
    if ($versions.Count -lt 2) { return [version] '0.0' }
    ($versions | Sort-Object)[0]
}

function Invoke-Installation {
    if ([Environment]::OSVersion.Platform -ne 'Win32NT' -or [Environment]::OSVersion.Version.Major -lt 10) {
        throw 'Требуется Windows 10/11.'
    }
    if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64' -or $env:PROCESSOR_ARCHITEW6432 -eq 'ARM64') {
        throw 'Этот пакет предназначен для Windows x86/x64.'
    }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if ($Mode -ne 'check' -and -not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Запустите установщик от имени администратора.'
    }
    $manifest = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'manifest.json') -Raw | ConvertFrom-Json
    if ($manifest.schema -ne 1) { throw 'Неизвестный формат manifest.json.' }
    # Verify the entire payload before changing the system.
    foreach ($file in $manifest.files) {
        $path = Get-PayloadPath $PSScriptRoot $file.path
        if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $file.sha256) {
            throw "Повреждён файл: $($file.path)"
        }
    }
    $arch = if ([Environment]::Is64BitOperatingSystem) { 'x64' } else { 'x86' }
    $packages = @($manifest.packages | Where-Object {
        if ($_.family -eq 'vstor') { $_.arch -eq $arch }
        else { $_.arch -eq 'x86' -or $_.arch -eq $arch }
    })
    if ($SelectPackages -and ($Quiet -or $Components -or $Mode -ne 'install')) {
        throw 'Окно выбора используется только для обычной установки без -Quiet и -Components.'
    }
    if ($SelectPackages) {
        $Components = Show-PackageSelection $packages
        if (-not $Components) { Write-Host 'Установка отменена.'; return 0 }
    }
    if ($Components) {
        $packages = @(Select-Components $packages $Components)
    }
    $engine = New-Object -ComObject WindowsInstaller.Installer
    $reboot = $false
    $logDir = Join-Path $env:ProgramData ('civisrom\VisualCppRedist\logs\' + [DateTime]::Now.ToString('yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N'))
    try {
        if ($Mode -ne 'check') {
            $null = New-Item -ItemType Directory -Path $logDir -Force
            $null = Start-Transcript -Path (Join-Path $logDir 'installer.log')
        }
        foreach ($package in $packages) {
            $installed = Get-InstalledVersion $engine $package
            $exact = if ($package.type -eq 'msi') { $engine.ProductState($package.productCode) -eq 5 } else { $true }
            $action = Get-PackageAction ([version] $package.version) $installed $Mode $exact
            Write-Host "$($package.name) [$($package.arch)] $($package.version): $action"
            if ($Mode -eq 'check' -or $action -eq 'skip') { continue }
            $path = Get-PayloadPath $PSScriptRoot $package.path
            $log = Join-Path $logDir ($package.id + '.log')
            if ($package.type -eq 'msi') {
                $executable = "$env:SystemRoot\System32\msiexec.exe"
                $arguments = "/i `"$path`" /qn /norestart /L*v `"$log`""
                if ($action -eq 'repair') { $arguments += ' REINSTALL=ALL REINSTALLMODE=vomus' }
            } else {
                $executable = $path
                $operation = if ($action -eq 'repair') { '/repair' } else { '/install' }
                $arguments = "$operation /quiet /norestart /log `"$log`""
            }
            $process = Start-Process -FilePath $executable -ArgumentList $arguments -Wait -PassThru
            if ($process.ExitCode -notin @(0, 3010)) {
                throw "Ошибка установки $($package.id): $($process.ExitCode). Журнал: $log"
            }
            if ($process.ExitCode -eq 3010) { $reboot = $true }
            $actual = Get-InstalledVersion $engine $package
            if (-not $actual -or $actual -lt [version] $package.version) {
                throw "Windows Installer не подтвердил установку $($package.id). Журнал: $log"
            }
        }
        if ($Mode -ne 'check') { Write-Host "Установка завершена. Журналы: $logDir" }
        if ($reboot) { Write-Host 'Для завершения требуется перезагрузка.'; return 3010 }
        return 0
    } finally {
        if ($Mode -ne 'check') { $null = Stop-Transcript }
        $null = [Runtime.InteropServices.Marshal]::FinalReleaseComObject($engine)
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    # A launch from PowerShell 7 can pass its incompatible module path to 5.1.
    # This installer needs only the modules bundled with the executing shell.
    $env:PSModulePath = Join-Path $PSHOME 'Modules'
    try { $result = Invoke-Installation; exit $result }
    catch { Write-Error ("$_`n" + $_.ScriptStackTrace) -ErrorAction Continue; exit 1 }
}
