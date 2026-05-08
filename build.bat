@echo off
setlocal enableextensions enabledelayedexpansion
pushd "%~dp0"

echo === Initialising MSVC environment...
call "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat" >nul
if errorlevel 1 (
    echo Failed to source vcvars64.bat
    popd & exit /b 1
)

echo === Compiling buddhabrot.exe ^(sm_89, Ada Lovelace^)...
nvcc -O3 -arch=sm_89 -std=c++17 ^
     -Xcompiler "/O2 /MD /EHsc /wd4819" ^
     -diag-suppress 20012 ^
     -o buddhabrot.exe ^
     src\main.cu src\lodepng.cpp
if errorlevel 1 (
    echo Build FAILED
    popd & exit /b 1
)

echo === Build OK
popd
endlocal
