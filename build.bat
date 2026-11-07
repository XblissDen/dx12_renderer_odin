@echo off
setlocal
call "%~dp0vendor\imgui\build.bat"
if errorlevel 1 exit /b 1
rem Optimized by default: unoptimized CPU work (texture decoding, HDR mip
rem generation) slows startup considerably. Extra arguments go to Odin.
odin build "%~dp0src" -out:"%~dp0kilu.exe" -subsystem:windows -o:speed %*
if errorlevel 1 exit /b 1
rem The shaders are compiled at run time by DXC, whose DLLs come with Odin:
rem dxcompiler.dll, and dxil.dll, which validates and signs its output.
for /f "delims=" %%r in ('odin root') do set "ODIN_ROOT=%%r"
for %%d in (dxcompiler.dll dxil.dll) do (
    xcopy /d /y /q "%ODIN_ROOT%\vendor\directx\dxc\%%d" "%~dp0" >nul
    if errorlevel 1 exit /b 1
)
exit /b 0
