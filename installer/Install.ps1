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

. "$PSScriptRoot/Interface.ps1"

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
    if ($best -and $Package.PSObject.Properties['runtimeFiles']) {
        $folder = if ($Package.arch -eq 'x86' -and [Environment]::Is64BitOperatingSystem) { 'SysWOW64' } else { 'System32' }
        $versions = foreach ($name in $Package.runtimeFiles) {
            $path = Get-PayloadPath (Join-Path $env:SystemRoot $folder) $name
            if (-not (Test-Path -LiteralPath $path)) { return [version]'0.0' }
            $info = [Diagnostics.FileVersionInfo]::GetVersionInfo($path)
            [version]::new($info.FileMajorPart, $info.FileMinorPart, $info.FileBuildPart, $info.FilePrivatePart)
        }
        return ($versions | Sort-Object | Select-Object -First 1)
    }
    $best
}

function Get-SupersededMsiPatches($Engine, $Package) {
    if (-not $Package.PSObject.Properties['supersededPatches']) { return }
    $patches = $Engine.Patches($Package.productCode)
    try {
        foreach ($code in $patches) {
            if ([string]$code -in $Package.supersededPatches) { [string]$code }
        }
    } finally {
        if ($null -ne $patches -and [Runtime.InteropServices.Marshal]::IsComObject($patches)) {
            $null = [Runtime.InteropServices.Marshal]::FinalReleaseComObject($patches)
        }
    }
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

function Get-SkipReason([version] $Available, [version] $Installed, [string] $Mode) {
    if ($Installed -and $Installed -gt $Available) { return 'Уже установлена более новая версия.' }
    if ($Mode -eq 'update' -and -not $Installed) { return 'Компонент отсутствует; режим обновления не добавляет новые компоненты.' }
    'Такая версия уже установлена; повторная установка не требуется.'
}

function New-InstallationResult($Package) {
    [pscustomobject][ordered]@{
        id = $Package.id; name = $Package.name; arch = $Package.arch
        available = $Package.version; before = ''; after = ''
        status = 'not-run'; reason = 'Установка ещё не выполнялась.'; exitCode = $null
    }
}

function Complete-InstallationResult($Result, [version] $Actual, [version] $Installed, [string] $Action, [string] $Log) {
    $Result.after = if ($Actual) { "$Actual" } else { '' }
    if (-not $Actual -or $Actual -lt [version] $Result.available) {
        if ($Result.exitCode -ne 3010) { throw "Не подтверждена установка $($Result.id). Журнал: $Log" }
        $Result.status = 'pending-reboot'
        $Result.reason = 'Установщик запросил перезагрузку; новая версия пока не подтверждена. Перезагрузите Windows и запустите пакет повторно для проверки.'
        return
    }
    $Result.status = if ($Action -eq 'repair') { 'repaired' } elseif ($Installed) { 'updated' } else { 'installed' }
    $Result.reason = if ($Action -eq 'repair') { 'Компонент восстановлен; версия проверена.' } else { 'Установка завершена; версия проверена.' }
}

function Save-InstallationReport([object[]] $Results, [string] $Directory, [bool] $Reboot, [string] $Failure) {
    $null = New-Item -ItemType Directory -Path $Directory -Force
    $report = [ordered]@{
        schema = 1; completedAt = [DateTime]::Now.ToString('o'); mode = $Mode
        success = (-not $Failure); rebootRequired = $Reboot; error = $Failure; packages = @($Results)
    }
    $report | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $Directory 'report.json') -Encoding UTF8
    $lines = @('Runtimes AIO — результат установки', "Дата: $($report.completedAt)", "Режим: $Mode")
    if ($Failure) { $lines += "Ошибка: $Failure" }
    if ($Reboot) { $lines += 'Для завершения установки требуется перезагрузка Windows.' }
    foreach ($item in $Results) {
        $before = if ($item.before) { $item.before } else { 'не установлено' }
        $after = if ($item.after) { $item.after } else { 'не подтверждено' }
        $lines += @('', "$($item.name) [$($item.arch)] — $(Get-ResultLabel $item.status)",
            "В пакете: $($item.available); до: $before; после: $after.", $item.reason)
    }
    $lines | Set-Content (Join-Path $Directory 'report.txt') -Encoding UTF8
}

function Invoke-Installation {
    $interactive = -not $Quiet -and $Mode -ne 'check' -and [Environment]::OSVersion.Platform -eq 'Win32NT'
    $progress = $null
    $engine = $null
    $transcribing = $false
    $cancelled = $false
    $reboot = $false
    $failure = ''
    $exitCode = 0
    $currentResult = $null
    $results = New-Object 'Collections.Generic.List[object]'
    $logDir = Join-Path $env:ProgramData ('civisrom\VisualCppRedist\logs\' + [DateTime]::Now.ToString('yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N'))
    try {
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
        if ($SelectPackages -and ($Quiet -or $Components -or $Mode -ne 'install')) {
            throw 'Окно выбора используется только для обычной установки без -Quiet и -Components.'
        }
        $manifest = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'manifest.json') -Raw | ConvertFrom-Json
        if ($manifest.schema -ne 1) { throw 'Неизвестный формат manifest.json.' }
        if ($interactive) { $progress = New-InstallationProgress }
        $verified = 0
        # Verify the entire payload before changing the system.
        foreach ($file in $manifest.files) {
            Set-InstallationProgress $progress 'Проверка файлов' "Проверяется целостность установочного пакета.`r`nФайл: $($file.path)" $verified $manifest.files.Count
            $path = Get-PayloadPath $PSScriptRoot $file.path
            if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $file.sha256) { throw "Повреждён файл: $($file.path)" }
            $verified++
        }
        if ($progress) { $progress.Dispose(); $progress = $null }
        $arch = if ([Environment]::Is64BitOperatingSystem) { 'x64' } else { 'x86' }
        $packages = @($manifest.packages | Where-Object {
            if ($_.family -eq 'vstor') { $_.arch -eq $arch }
            else { $_.arch -eq 'x86' -or $_.arch -eq $arch }
        })
        if ($SelectPackages) {
            $Components = Show-PackageSelection $packages
            if (-not $Components) { $cancelled = $true; Write-Host 'Установка отменена.'; return 0 }
        }
        $selected = if ($Components) { @(Select-Components $packages $Components) } else { $packages }
        if ($Mode -ne 'check') {
            $null = New-Item -ItemType Directory -Path $logDir -Force
            $null = Start-Transcript -Path (Join-Path $logDir 'installer.log')
            $transcribing = $true
        }
        if ($interactive) { $progress = New-InstallationProgress }
        $engine = New-Object -ComObject WindowsInstaller.Installer
        $byId = @{}
        foreach ($package in $manifest.packages) {
            $item = New-InstallationResult $package
            $results.Add($item)
            $byId[$package.id] = $item
            if ($package.id -notin $packages.id) {
                $item.status = 'not-applicable'
                $item.reason = "Для этой системы используется другой вариант архитектуры ($arch)."
                continue
            }
            Set-InstallationProgress $progress 'Проверка установленных версий' "$($package.name)`r`nАрхитектура: $($package.arch). Версия в пакете: $($package.version)."
            $installed = Get-InstalledVersion $engine $package
            $item.before = if ($installed -eq [version]'0.0') { 'Неполный набор' } elseif ($installed) { "$installed" } else { '' }
            $item.after = $item.before
            if ($package.id -notin $selected.id) { $item.status = 'not-selected'; $item.reason = 'Компонент не выбран пользователем.' }
        }
        $completed = 0
        foreach ($package in $selected) {
            $currentResult = $byId[$package.id]
            # Re-read after each installation: bundles can change shared components.
            $installed = Get-InstalledVersion $engine $package
            $exact = if ($package.type -eq 'msi') { $engine.ProductState($package.productCode) -eq 5 } else { $true }
            $action = Get-PackageAction ([version] $package.version) $installed $Mode $exact
            Write-Host "$($package.name) [$($package.arch)] $($package.version): $action"
            if ($Mode -eq 'check') { continue }
            if ($action -eq 'skip') {
                $currentResult.status = 'skipped'
                $currentResult.reason = Get-SkipReason ([version] $package.version) $installed $Mode
                $currentResult.after = if ($installed) { "$installed" } else { '' }
                $completed++
                continue
            }
            $operationText = if ($action -eq 'repair') { 'Восстановление' } elseif ($installed) { 'Обновление' } else { 'Установка' }
            Set-InstallationProgress $progress "$operationText — компонент $($completed + 1) из $($selected.Count)" "$($package.name)`r`nАрхитектура: $($package.arch). Версия: $($package.version).`r`nДождитесь завершения обработки компонента." $completed $selected.Count
            $path = Get-PayloadPath $PSScriptRoot $package.path
            $log = Join-Path $logDir ($package.id + '.log')
            $installSteps = @()
            if ($package.type -eq 'msi') {
                $executable = "$env:SystemRoot\System32\msiexec.exe"
                $arguments = "/i `"$path`" /qn /norestart /L*v `"$log`""
                # Both minor upgrades (for example VC2005) and DLL-only patches
                # (VC2010) keep ProductCode. Recache their new MSI and update files.
                if ($exact) {
                    $arguments += ' REINSTALL=ALL REINSTALLMODE=vomus'
                    $patches = @(Get-SupersededMsiPatches $engine $package)
                    if ($patches.Count) {
                        # Patch removal restores its baseline cache, even when a
                        # newer MSI is supplied. Complete it before the upgrade.
                        $patchLog = Join-Path $logDir ($package.id + '-remove-patch.log')
                        $installSteps += @{ log = $patchLog; arguments = "/i $($package.productCode) /qn /norestart /L*v `"$patchLog`" MSIPATCHREMOVE=`"$($patches -join ';')`"" }
                    }
                }
            } else {
                $executable = $path
                $operation = if ($action -eq 'repair') { '/repair' } else { '/install' }
                $arguments = "$operation /quiet /norestart /log `"$log`""
            }
            $installSteps += @{ log = $log; arguments = $arguments }
            $currentResult.after = ''
            foreach ($step in $installSteps) {
                $log = $step.log
                if ($interactive) {
                    $process = Start-Process -FilePath $executable -ArgumentList $step.arguments -PassThru
                    while (-not $process.WaitForExit(100)) { [Windows.Forms.Application]::DoEvents() }
                    $process.Refresh()
                } else { $process = Start-Process -FilePath $executable -ArgumentList $step.arguments -Wait -PassThru }
                if ($null -eq $currentResult.exitCode -or $process.ExitCode -ne 0) { $currentResult.exitCode = $process.ExitCode }
                if ($process.ExitCode -notin @(0, 3010)) { throw "Ошибка установки $($package.id): $($process.ExitCode). Журнал: $log" }
                if ($process.ExitCode -eq 3010) { $reboot = $true }
            }
            $actual = Get-InstalledVersion $engine $package
            Complete-InstallationResult $currentResult $actual $installed $action $log
            $completed++
        }
        if ($Mode -ne 'check') { Write-Host "Установка завершена. Отчёт и журналы: $logDir" }
        if ($reboot) { Write-Host 'Для завершения требуется перезагрузка.'; $exitCode = 3010 }
    } catch {
        $failure = $_.Exception.Message
        $exitCode = 1
        if ($currentResult -and $currentResult.status -eq 'not-run') {
            $currentResult.status = 'failed'
            $currentResult.reason = $failure
            try { $actual = Get-InstalledVersion $engine $package; $currentResult.after = if ($actual) { "$actual" } else { '' } }
            catch { $currentResult.after = '' }
        }
        foreach ($item in $results | Where-Object status -eq 'not-run') { $item.reason = 'Не выполнено из-за предыдущей ошибки.' }
        Write-Error ("$_`n" + $_.ScriptStackTrace) -ErrorAction Continue
    } finally {
        if ($progress) { $progress.Dispose() }
        if ($engine) { $null = [Runtime.InteropServices.Marshal]::FinalReleaseComObject($engine) }
        if ($transcribing) { $null = Stop-Transcript }
        if ($Mode -ne 'check' -and -not $cancelled) {
            try { Save-InstallationReport $results.ToArray() $logDir $reboot $failure }
            catch { $failure += " Не удалось сохранить отчёт: $($_.Exception.Message)"; $exitCode = 1; Write-Error $failure -ErrorAction Continue }
            if ($interactive) { Show-InstallationResult $results.ToArray() $logDir $reboot $failure }
        }
    }
    $exitCode
}

if ($MyInvocation.InvocationName -ne '.') {
    # A launch from PowerShell 7 can pass its incompatible module path to 5.1.
    # This installer needs only the modules bundled with the executing shell.
    $env:PSModulePath = Join-Path $PSHOME 'Modules'
    try { $result = Invoke-Installation; exit $result }
    catch { Write-Error ("$_`n" + $_.ScriptStackTrace) -ErrorAction Continue; exit 1 }
}
