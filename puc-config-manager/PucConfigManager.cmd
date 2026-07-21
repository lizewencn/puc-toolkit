@echo off
setlocal
if not "%~1"=="" (
  echo Command-line parameters are not supported. Edit manager_config.json instead.
  exit /b 2
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Invoke-PucConfigManager.ps1"
exit /b %errorlevel%
