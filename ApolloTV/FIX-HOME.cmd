@echo off
chcp 65001 >nul
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0ApolloTV.ps1" -Mode Switch %*
set "result=%ERRORLEVEL%"
echo.
echo Exit code: %result%. See the messages and log above.
pause
exit /b %result%
