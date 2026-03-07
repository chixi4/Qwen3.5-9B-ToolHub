@echo off
setlocal
set SCRIPT_DIR=%~dp0
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%install_q8.ps1" %*
if errorlevel 1 (
  echo.
  echo [bootstrap_q8] Q8 install failed.
  exit /b 1
)
echo.
echo [bootstrap_q8] Q8 install started or completed.
echo [bootstrap_q8] Start command: .\start_8080_toolhub_stack.cmd start
exit /b 0
