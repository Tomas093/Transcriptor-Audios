@echo off
rem Transcriptor en Windows. Ayuda: transcriptor.cmd help
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\transcriptor.ps1" %*
exit /b %ERRORLEVEL%
