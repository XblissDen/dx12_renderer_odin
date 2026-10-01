@echo off
setlocal
call "%~dp0vendor\imgui\build.bat"
if errorlevel 1 exit /b 1
odin build "%~dp0src" -out:"%~dp0dx12_renderer.exe" -subsystem:windows %*
exit /b %errorlevel%
