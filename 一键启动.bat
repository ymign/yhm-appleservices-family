@echo off
setlocal
chcp 65001 >nul
pushd "%~dp0"
if errorlevel 1 exit /b 1
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0run-ui.ps1" %*
set "launchExit=%errorlevel%"
popd
if not "%launchExit%"=="0" (
    echo.
    echo 启动失败，请查看上面的错误信息。
    pause
)
exit /b %launchExit%
