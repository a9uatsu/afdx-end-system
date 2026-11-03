@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0run_lib_modelsim.ps1" %*
if errorlevel 1 pause
