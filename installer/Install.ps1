param(
    [ValidateSet('install', 'update', 'repair', 'check')]
    [string] $Mode = 'install',
    [switch] $Quiet
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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
    # Enumerate StringList explicitly: PowerShell's array conversion of this COM
    # collection can throw NullReferenceException, including on an empty list.
    $related = $Engine.RelatedProducts($Package.upgradeCode)
    $codes = @($Package.productCode)
    for ($i = 0; $i -lt $related.Count; $i++) { $codes += $related.Item($i) }
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
    try { $result = Invoke-Installation; exit $result }
    catch { Write-Error $_ -ErrorAction Continue; exit 1 }
}
