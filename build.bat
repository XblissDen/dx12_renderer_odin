@echo off
setlocal
call "%~dp0vendor\imgui\build.bat"
if errorlevel 1 exit /b 1
rem Optimized by default: unoptimized CPU work (texture decoding, HDR mip
rem generation) slows startup considerably. Extra arguments go to Odin.
odin build "%~dp0src" -out:"%~dp0dx12_renderer.exe" -subsystem:windows -o:speed %*
exit /b %errorlevel%
