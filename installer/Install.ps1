param(
    [ValidateSet('install', 'update', 'repair', 'check')]
    [string] $Mode = 'install',
    [switch] $Quiet,
    [ValidateNotNullOrEmpty()]
    [string] $Components,
    [switch] $SelectPackages,
    [switch] $ShowPlan
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

# What the selection window says about each component before anything is installed.
function Get-SelectionState([object[]] $Packages, [hashtable] $Installed) {
    $states = @{}
    foreach ($group in $Packages | Group-Object { Get-ComponentId $_ }) {
        $present = @($group.Group | Where-Object { $Installed[$_.id] })
        $current = @($group.Group | Where-Object { (Get-PackageAction ([version] $_.version) $Installed[$_.id] 'install' $false) -eq 'skip' })
        $states[$group.Name] = if (-not $present.Count) { 'не установлено' }
            elseif ($current.Count -eq $group.Count) { 'установлено, обновление не требуется' }
            else { 'доступно обновление' }
    }
    $states
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
            if (-not (Test-Path -LiteralPath $path)) { [version]'0.0' }
            else {
                $info = [Diagnostics.FileVersionInfo]::GetVersionInfo($path)
                [version]::new($info.FileMajorPart, $info.FileMinorPart, $info.FileBuildPart, $info.FilePrivatePart)
            }
        }
        return ($versions | Sort-Object | Select-Object -First 1)
    }
    $best
}

function Get-BinaryVersion([string] $Path) {
    $info = [Diagnostics.FileVersionInfo]::GetVersionInfo($Path)
    [version]::new($info.FileMajorPart, $info.FileMinorPart, $info.FileBuildPart, $info.FilePrivatePart)
}

# Windows Installer keeps a file of the same version even when its contents
# differ, so a repair has to be told to rewrite equal versions.
function Test-DamagedRuntimeFile($Package, [object[]] $Files, [string] $Root, [hashtable] $Folders) {
    $directory = (Split-Path $Package.path).Replace('\', '/') + '/'
    foreach ($file in $Files) {
        if (-not $file.path.StartsWith($directory, [StringComparison]::OrdinalIgnoreCase)) { continue }
        $folder = Split-Path (Split-Path $file.path) -Leaf
        if (-not $Folders.ContainsKey($folder)) { continue }
        $installed = Join-Path $Folders[$folder] (Split-Path $file.path -Leaf)
        if (-not (Test-Path -LiteralPath $installed)) { continue }
        if ((Get-FileHash -LiteralPath $installed -Algorithm SHA256).Hash -eq $file.sha256) { continue }
        if ((Get-BinaryVersion $installed) -eq (Get-BinaryVersion (Get-PayloadPath $Root $file.path))) { return $true }
    }
    $false
}

function Get-SupersededMsiPatches($Engine, $Package, [switch] $All) {
    if (-not $All -and -not $Package.PSObject.Properties['supersededPatches']) { return }
    $patches = $Engine.Patches($Package.productCode)
    try {
        foreach ($code in $patches) {
            if ($All -or [string]$code -in $Package.supersededPatches) { [string]$code }
        }
    } finally {
        if ($null -ne $patches -and [Runtime.InteropServices.Marshal]::IsComObject($patches)) {
            $null = [Runtime.InteropServices.Marshal]::FinalReleaseComObject($patches)
        }
    }
}

function Get-FullVersion([version] $Version) {
    [version]::new($Version.Major, $Version.Minor, [Math]::Max($Version.Build, 0), [Math]::Max($Version.Revision, 0))
}

function Get-RegisteredBundles {
    foreach ($view in @('Registry64', 'Registry32')) {
        $hive = [Microsoft.Win32.RegistryKey]::OpenBaseKey('LocalMachine', $view)
        $uninstall = $hive.OpenSubKey('SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall')
        try {
            if (-not $uninstall) { continue }
            foreach ($name in $uninstall.GetSubKeyNames()) {
                $key = $uninstall.OpenSubKey($name)
                if (-not $key) { continue }
                try {
                    if ($key.GetValue('BundleCachePath')) {
                        [pscustomobject]@{
                            view = $view; id = $name; name = [string] $key.GetValue('DisplayName'); publisher = [string] $key.GetValue('Publisher')
                            version = [string] $key.GetValue('BundleVersion'); cachePath = [string] $key.GetValue('BundleCachePath')
                            providerKey = [string] $key.GetValue('BundleProviderKey')
                        }
                    }
                } finally { $key.Dispose() }
            }
        } finally { if ($uninstall) { $uninstall.Dispose() }; $hive.Dispose() }
    }
}

function Get-DependencyProviders {
    $root = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SOFTWARE\Classes\Installer\Dependencies')
    if (-not $root) { return }
    try {
        foreach ($name in $root.GetSubKeyNames()) {
            $key = $root.OpenSubKey($name)
            if (-not $key) { continue }
            try {
                $dependents = $key.OpenSubKey('Dependents')
                if (-not $dependents) { continue }
                try { [pscustomobject]@{ key = $name; product = [string] $key.GetValue(''); dependents = @($dependents.GetSubKeyNames()) } }
                finally { $dependents.Dispose() }
            } finally { $key.Dispose() }
        }
    } finally { $root.Dispose() }
}

# An original Microsoft EXE stays registered after its MSI packages have been
# upgraded. Its record then shows an old version and blocks their removal.
# Only a Microsoft Visual C++ bundle whose every package was replaced by a
# newer installed product of this set is obsolete; anything else is kept.
function Select-ObsoleteBundles([object[]] $Bundles, [object[]] $Providers, [hashtable] $Products) {
    foreach ($bundle in $Bundles) {
        if ($bundle.publisher -ne 'Microsoft Corporation' -or
            $bundle.name -notmatch '^Microsoft Visual C\+\+ .+ Redistributable \((x86|x64)\)') { continue }
        $version = $null
        if (-not [version]::TryParse($bundle.version, [ref] $version)) { continue }
        $packages = @($Providers | Where-Object { $bundle.id -in $_.dependents -and $_.key -ne $bundle.providerKey -and $_.product -ne $bundle.id })
        if (-not $packages.Count) { continue }
        $replaced = @($packages | Where-Object {
            $Products.ContainsKey($_.product) -and (Get-FullVersion $Products[$_.product]) -gt (Get-FullVersion $version)
        })
        if ($replaced.Count -eq $packages.Count) { $bundle }
    }
}

# The bundle's own uninstaller would also remove the newer packages that now
# own its provider keys, so only its stale registration and cache are deleted.
function Remove-ObsoleteBundle($Bundle, [object[]] $Providers) {
    $dependencies = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SOFTWARE\Classes\Installer\Dependencies', $true)
    try {
        foreach ($provider in $Providers | Where-Object { $Bundle.id -in $_.dependents }) {
            if ($provider.product -eq $Bundle.id -or $provider.key -eq $Bundle.providerKey) { $dependencies.DeleteSubKeyTree($provider.key, $false) }
            else { $dependencies.DeleteSubKeyTree("$($provider.key)\Dependents\$($Bundle.id)", $false) }
        }
    } finally { $dependencies.Dispose() }
    $hive = [Microsoft.Win32.RegistryKey]::OpenBaseKey('LocalMachine', $Bundle.view)
    try {
        $uninstall = $hive.OpenSubKey('SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', $true)
        try { $uninstall.DeleteSubKeyTree($Bundle.id, $false) } finally { $uninstall.Dispose() }
    } finally { $hive.Dispose() }
    $cache = Split-Path $Bundle.cachePath
    if ((Split-Path $cache -Leaf) -eq $Bundle.id -and (Test-Path -LiteralPath $cache)) {
        Remove-Item -LiteralPath $cache -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-InstallerProcess([string] $File, [string] $Arguments, [bool] $Interactive) {
    if ($Interactive) {
        $process = Start-Process -FilePath $File -ArgumentList $Arguments -PassThru
        while (-not $process.WaitForExit(100)) { [Windows.Forms.Application]::DoEvents() }
        $process.Refresh()
    } else { $process = Start-Process -FilePath $File -ArgumentList $Arguments -Wait -PassThru }
    $process.ExitCode
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

function Save-InstallationReport([object[]] $Results, [string] $Directory, [bool] $Reboot, [string] $Failure, [string[]] $RemovedBundles = @()) {
    $null = New-Item -ItemType Directory -Path $Directory -Force
    $report = [ordered]@{
        schema = 1; completedAt = [DateTime]::Now.ToString('o'); mode = $Mode
        success = (-not $Failure); rebootRequired = $Reboot; error = $Failure; packages = @($Results)
        removedBundles = @($RemovedBundles)
    }
    $report | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $Directory 'report.json') -Encoding UTF8
    $lines = @('Runtimes AIO — результат установки', "Дата: $($report.completedAt)", "Режим: $Mode")
    if ($Failure) { $lines += "Ошибка: $Failure" }
    if ($Reboot) { $lines += 'Для завершения установки требуется перезагрузка Windows.' }
    foreach ($bundle in $RemovedBundles) { $lines += "Удалена устаревшая запись установщика Microsoft: $bundle" }
    foreach ($item in $Results) {
        $before = if ($item.before) { $item.before } else { 'не установлено' }
        $after = if ($item.after) { $item.after } else { 'не подтверждено' }
        $lines += @('', "$($item.name) [$($item.arch)] — $(Get-ResultLabel $item.status)",
            "В пакете: $($item.available); до: $before; после: $after.", $item.reason)
    }
    $lines | Set-Content (Join-Path $Directory 'report.txt') -Encoding UTF8
}

function Invoke-Installation {
    $interactive = -not $Quiet -and ($Mode -ne 'check' -or $ShowPlan) -and [Environment]::OSVersion.Platform -eq 'Win32NT'
    $progress = $null
    $engine = $null
    $transcribing = $false
    $cancelled = $false
    $reboot = $false
    $failure = ''
    $exitCode = 0
    $currentResult = $null
    $results = New-Object 'Collections.Generic.List[object]'
    $removedBundles = New-Object 'Collections.Generic.List[string]'
    $logDir = Join-Path $env:ProgramData ('civisrom\VisualCppRedist\logs\' + [DateTime]::Now.ToString('yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N'))
    try {
        if ([Environment]::OSVersion.Platform -ne 'Win32NT' -or [Environment]::OSVersion.Version.Major -lt 10) {
            throw 'Требуется Windows 10/11.'
        }
        if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64' -or $env:PROCESSOR_ARCHITEW6432 -eq 'ARM64') {
            throw 'Этот пакет предназначен для Windows x86/x64.'
        }
        # A 32-bit process is redirected to SysWOW64 and Program Files (x86),
        # so the x64 libraries would be detected by their x86 files.
        if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
            throw 'Запустите Installer.cmd или 64-разрядный PowerShell: из 32-разрядного процесса версии x64 определяются неверно.'
        }
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = [Security.Principal.WindowsPrincipal]::new($identity)
        if ($Mode -ne 'check' -and -not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
            throw 'Запустите установщик от имени администратора.'
        }
        if ($SelectPackages -and ($Quiet -or $Components -or $Mode -ne 'install')) {
            throw 'Окно выбора используется только для обычной установки без -Quiet и -Components.'
        }
        if ($ShowPlan -and ($Quiet -or $Mode -ne 'check')) { throw 'Окно проверки состава используется только с -Mode check без -Quiet.' }
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
        $arch = if ([Environment]::Is64BitOperatingSystem) { 'x64' } else { 'x86' }
        $packages = @($manifest.packages | Where-Object {
            if ($_.family -eq 'vstor') { $_.arch -eq $arch }
            else { $_.arch -eq 'x86' -or $_.arch -eq $arch }
        })
        $detected = @{}
        if ($SelectPackages) {
            $engine = New-Object -ComObject WindowsInstaller.Installer
            foreach ($package in $packages) {
                Set-InstallationProgress $progress 'Проверка установленных версий' "$($package.name)`r`nАрхитектура: $($package.arch). Версия в пакете: $($package.version)."
                $detected[$package.id] = Get-InstalledVersion $engine $package
            }
        }
        if ($progress) { $progress.Dispose(); $progress = $null }
        if ($SelectPackages) {
            $Components = Show-PackageSelection $packages (Get-SelectionState $packages $detected)
            if (-not $Components) { $cancelled = $true; Write-Host 'Установка отменена.'; return 0 }
        }
        $selected = if ($Components) { @(Select-Components $packages $Components) } else { $packages }
        if ($Mode -ne 'check') {
            $null = New-Item -ItemType Directory -Path $logDir -Force
            $null = Start-Transcript -Path (Join-Path $logDir 'installer.log')
            $transcribing = $true
        }
        if ($interactive) { $progress = New-InstallationProgress }
        if (-not $engine) { $engine = New-Object -ComObject WindowsInstaller.Installer }
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
        $systemFolders = @{
            System64 = "$env:SystemRoot\System32"
            System = $(if ([Environment]::Is64BitOperatingSystem) { "$env:SystemRoot\SysWOW64" } else { "$env:SystemRoot\System32" })
        }
        foreach ($package in $selected) {
            $currentResult = $byId[$package.id]
            # Re-read after each installation: bundles can change shared components.
            $installed = Get-InstalledVersion $engine $package
            $exact = if ($package.type -eq 'msi') { $engine.ProductState($package.productCode) -eq 5 } else { $true }
            $action = Get-PackageAction ([version] $package.version) $installed $Mode $exact
            Write-Host "$($package.name) [$($package.arch)] $($package.version): $action"
            if ($Mode -eq 'check') {
                $currentResult.status = if ($action -eq 'skip') { 'skipped' } elseif ($installed) { 'planned-update' } else { 'planned-install' }
                $currentResult.reason = if ($action -eq 'skip') { Get-SkipReason ([version] $package.version) $installed $Mode }
                    else { 'Будет обработано при обычной установке.' }
                continue
            }
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
                $arguments = "/i `"$path`" /qn /norestart"
                # Both minor upgrades (for example VC2005) and DLL-only patches
                # (VC2010) keep ProductCode. Recache their new MSI and update files.
                if ($exact) {
                    $damaged = $Mode -eq 'repair' -and (Test-DamagedRuntimeFile $package $manifest.files $PSScriptRoot $systemFolders)
                    $arguments += ' REINSTALL=ALL REINSTALLMODE=' + $(if ($damaged) { 'vemus' } else { 'vomus' })
                    $patches = @(Get-SupersededMsiPatches $engine $package)
                    if ($patches.Count) {
                        # Patch removal restores its baseline cache, even when a
                        # newer MSI is supplied. Complete it before the upgrade.
                        $patchLog = Join-Path $logDir ($package.id + '-remove-patch.log')
                        $installSteps += @{ log = $patchLog; arguments = "/i $($package.productCode) /qn /norestart /L*v `"$patchLog`" MSIPATCHREMOVE=`"$($patches -join ';')`"" }
                    }
                }
                $installSteps += @{ log = $log; arguments = "$arguments /L*v `"$log`"" }
            } else {
                $executable = $path
                $operation = if ($action -eq 'repair') { '/repair' } else { '/install' }
                $installSteps += @{ log = $log; arguments = "$operation /quiet /norestart /log `"$log`"" }
            }
            $currentResult.after = ''
            $retried = $false
            do {
                foreach ($step in $installSteps) {
                    $log = $step.log
                    $code = Invoke-InstallerProcess $executable $step.arguments $interactive
                    if ($null -eq $currentResult.exitCode -or $code -ne 0) { $currentResult.exitCode = $code }
                    if ($code -notin @(0, 3010)) { throw "Ошибка установки $($package.id): $code. Журнал: $log" }
                    if ($code -eq 3010) { $reboot = $true }
                }
                $actual = Get-InstalledVersion $engine $package
                $installSteps = @()
                # A patch outside the known list reapplies its older files over
                # the new package. Retire every remaining patch and repeat once.
                if (-not $retried -and $package.type -eq 'msi' -and $exact -and $currentResult.exitCode -ne 3010 -and
                    (-not $actual -or $actual -lt [version] $package.version)) {
                    $patches = @(Get-SupersededMsiPatches $engine $package -All)
                    if ($patches.Count) {
                        $retried = $true
                        $patchLog = Join-Path $logDir ($package.id + '-remove-patch-2.log')
                        $log = Join-Path $logDir ($package.id + '-2.log')
                        $installSteps = @(
                            @{ log = $patchLog; arguments = "/i $($package.productCode) /qn /norestart /L*v `"$patchLog`" MSIPATCHREMOVE=`"$($patches -join ';')`"" },
                            @{ log = $log; arguments = "$arguments /L*v `"$log`"" }
                        )
                    }
                }
            } while ($installSteps.Count)
            Complete-InstallationResult $currentResult $actual $installed $action $log
            $completed++
        }
        if ($Mode -ne 'check') {
            $products = @{}
            foreach ($candidate in $selected | Where-Object type -eq 'msi') {
                if ($engine.ProductState($candidate.productCode) -eq 5) {
                    $products[$candidate.productCode] = [version] $engine.ProductInfo($candidate.productCode, 'VersionString')
                }
            }
            $providers = @(Get-DependencyProviders)
            foreach ($bundle in @(Select-ObsoleteBundles @(Get-RegisteredBundles | Sort-Object id -Unique) $providers $products)) {
                try {
                    Remove-ObsoleteBundle $bundle $providers
                    $removedBundles.Add($bundle.name)
                    Write-Host "Удалена устаревшая запись: $($bundle.name)"
                } catch { Write-Host "Устаревшая запись сохранена: $($bundle.name). $($_.Exception.Message)" }
            }
            Write-Host "Установка завершена. Отчёт и журналы: $logDir"
        }
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
            try { Save-InstallationReport $results.ToArray() $logDir $reboot $failure $removedBundles.ToArray() }
            catch { $failure += " Не удалось сохранить отчёт: $($_.Exception.Message)"; $exitCode = 1; Write-Error $failure -ErrorAction Continue }
            if ($interactive) { Show-InstallationResult $results.ToArray() $logDir $reboot $failure }
        } elseif ($ShowPlan) { Show-InstallationResult $results.ToArray() '' $false $failure -Plan }
    }
    $exitCode
}

if ($MyInvocation.InvocationName -ne '.') {
    # A launch from PowerShell 7 can pass its incompatible module path to 5.1.
    # This installer needs only the modules bundled with the executing shell.
    $env:PSModulePath = Join-Path $PSHOME 'Modules'
    try {
        $result = Invoke-Installation
        # Tells Installer.cmd that the outcome was shown or logged by this script.
        if ($env:RUNTIMES_AIO_REPORTED) { try { [IO.File]::WriteAllText($env:RUNTIMES_AIO_REPORTED, '') } catch { } }
        exit $result
    }
    catch { Write-Error ("$_`n" + $_.ScriptStackTrace) -ErrorAction Continue; exit 1 }
}
