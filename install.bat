@echo off
rem Installs the mod; see README.md
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0installer\kakt_mod.ps1" install %*
set KAKT_EXIT=%ERRORLEVEL%
if not defined KAKT_NOPAUSE pause
exit /b %KAKT_EXIT%
