@echo off
setlocal
call "%~dp0vendor\imgui\build.bat"
if errorlevel 1 exit /b 1
rem Optimized by default: unoptimized CPU work (texture/HDR mip generation)
rem roughly triples startup time. Extra arguments are passed through to Odin.
odin build "%~dp0src" -out:"%~dp0dx12_renderer.exe" -subsystem:windows -o:speed %*
exit /b %errorlevel%
