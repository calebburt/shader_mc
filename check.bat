@echo off
setlocal enabledelayedexpansion

REM Resolve script directory
set "SRC_DIR=%~dp0"

REM Minecraft directory (prefer MINECRAFT_DIR)
if defined MINECRAFT_DIR (
    set "MC_DIR=%MINECRAFT_DIR%"
) else (
    set "MC_DIR=%USERPROFILE%\.minecraft"
)

REM Cache + venv paths
set "CACHE=%LOCALAPPDATA%\shader_mc-glslcheck"
set "VENV=%CACHE%\venv"

REM Create venv if missing
if not exist "%VENV%\Scripts\python.exe" (
    echo Creating check venv in %VENV% ...
    mkdir "%CACHE%" 2>nul
    python -m venv "%VENV%"
    "%VENV%\Scripts\pip.exe" install -q PyOpenGL
)

REM Run Python block
"%VENV%\Scripts\python.exe" - "%SRC_DIR%" "%MC_DIR%" "%MC_VERSION%" ^
    < "%SRC_DIR%\check_shaders_embedded.py"

endlocal
