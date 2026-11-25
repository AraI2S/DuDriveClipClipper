@echo off
chcp 65001 >nul
title Baidu Pan Clipboard Cleaner - Self Test
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0Main.ps1" -SelfTest
set "result=%errorlevel%"
echo.
if "%result%"=="0" (echo All self-tests passed.) else (echo Some self-tests FAILED. Exit code: %result%)
pause
exit /b %result%
