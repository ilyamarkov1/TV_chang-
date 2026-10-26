@echo off
chcp 65001 >nul
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0ApolloTV.ps1" -Mode Check %*
set "result=%ERRORLEVEL%"
echo.
echo Exit code: %result%.
pause
exit /b %result%
