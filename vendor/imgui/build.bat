@echo off
setlocal

rem This pinned dependency is compiled once; --rebuild refreshes the cache.
if exist "%~dp0lib\dx12_debug_ui.lib" if /i not "%~1"=="--rebuild" exit /b 0

set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
if not exist "%VSWHERE%" (
    echo MSVC Build Tools were not found. Install the Desktop development with C++ workload.
    exit /b 1
)
for /f "usebackq delims=" %%I in (`"%VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set "VSINSTALL=%%I"
if not defined VSINSTALL (
    echo An x64 MSVC compiler was not found by vswhere.
    exit /b 1
)
call "%VSINSTALL%\VC\Auxiliary\Build\vcvars64.bat" >nul
if errorlevel 1 exit /b 1

if not exist "%~dp0build" mkdir "%~dp0build"
if not exist "%~dp0lib" mkdir "%~dp0lib"

cl /nologo /O2 /MT /EHsc /std:c++17 /utf-8 /W3 ^
    /I"%~dp0src" /I"%~dp0src\backends" /c /Fo"%~dp0build/" ^
    "%~dp0bridge.cpp" ^
    "%~dp0src\imgui.cpp" "%~dp0src\imgui_draw.cpp" ^
    "%~dp0src\imgui_tables.cpp" "%~dp0src\imgui_widgets.cpp" ^
    "%~dp0src\imgui_demo.cpp" ^
    "%~dp0src\backends\imgui_impl_dx12.cpp" ^
    "%~dp0src\backends\imgui_impl_win32.cpp"
if errorlevel 1 exit /b 1

lib /nologo /OUT:"%~dp0lib\dx12_debug_ui.lib" ^
    "%~dp0build\bridge.obj" "%~dp0build\imgui.obj" ^
    "%~dp0build\imgui_draw.obj" "%~dp0build\imgui_tables.obj" ^
    "%~dp0build\imgui_widgets.obj" "%~dp0build\imgui_demo.obj" ^
    "%~dp0build\imgui_impl_dx12.obj" "%~dp0build\imgui_impl_win32.obj"
exit /b %errorlevel%
