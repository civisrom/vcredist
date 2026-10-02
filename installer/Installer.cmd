@echo off
setlocal
set "ps=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "ps=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
"%ps%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install.ps1" %*
exit /b %errorlevel%
