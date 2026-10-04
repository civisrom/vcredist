@echo off
setlocal
set "ps=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "ps=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
rem Install.ps1 creates this file once it has shown or logged its own outcome.
set "RUNTIMES_AIO_REPORTED=%TEMP%\runtimes-aio-%RANDOM%%RANDOM%.tmp"
if exist "%RUNTIMES_AIO_REPORTED%" del "%RUNTIMES_AIO_REPORTED%"
"%ps%" -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0Install.ps1" %*
set "code=%errorlevel%"
if exist "%RUNTIMES_AIO_REPORTED%" del "%RUNTIMES_AIO_REPORTED%" & exit /b %code%
rem The script could not start (for example, blocked by an execution policy).
rem Its console is hidden by the SFX, so tell the user unless the run is silent.
set "silent="
set "plan="
for %%A in (%*) do (
    if /i "%%~A"=="-Quiet" set "silent=1"
    if /i "%%~A"=="check" set "silent=1"
    if /i "%%~A"=="-ShowPlan" set "plan=1"
)
if defined silent if not defined plan exit /b %code%
set "RUNTIMES_AIO_HOME=%~dp0"
set "RUNTIMES_AIO_CODE=%code%"
"%ps%" -NoLogo -NoProfile -Command "$text = [IO.File]::ReadAllText((Join-Path $env:RUNTIMES_AIO_HOME 'StartFailure.txt')).Trim().Replace('{0}', $env:RUNTIMES_AIO_CODE); $null = (New-Object -ComObject WScript.Shell).Popup($text, 120, 'Runtimes AIO', 16)"
exit /b %code%
