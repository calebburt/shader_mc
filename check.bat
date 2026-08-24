@echo off
setlocal enabledelayedexpansion

REM Resolve script directory without a trailing backslash so cmd.exe passes it as a clean path argument
set "SRC_DIR=%~dp0"
if "%SRC_DIR:~-1%"=="\" set "SRC_DIR=%SRC_DIR:~0,-1%"

REM Minecraft directory (prefer MINECRAFT_DIR)
if defined MINECRAFT_DIR (
    set "MC_DIR=%MINECRAFT_DIR%"
) else (
    set "MC_DIR=%USERPROFILE%\AppData\Roaming\.minecraft"
)

REM Cache + venv paths
set "CACHE=%LOCALAPPDATA%\shader_mc-glslcheck"
set "VENV=%CACHE%\venv"
set "PYOPENGL_PLATFORM=egl"

REM Find a working Python 3 command
where py >nul 2>nul
if not errorlevel 1 (
    set "PYTHON_CMD=py -3"
) else (
    where python >nul 2>nul
    if errorlevel 1 (
        echo Python 3 is required to run shader validation.
        exit /b 1
    )
    set "PYTHON_CMD=python"
)

REM Create venv if missing
if not exist "%VENV%\Scripts\python.exe" (
    echo Creating check venv in %VENV% ...
    mkdir "%CACHE%" 2>nul
    %PYTHON_CMD% -m venv "%VENV%"
    "%VENV%\Scripts\python.exe" -m pip install --disable-pip-version-check -q PyOpenGL
)

REM Run the actual shader check script with arguments
if defined MC_VERSION (
    "%VENV%\Scripts\python.exe" "%SRC_DIR%\check_shaders_embedded.py" "%SRC_DIR%" "%MC_DIR%" "%MC_VERSION%"
) else (
    "%VENV%\Scripts\python.exe" "%SRC_DIR%\check_shaders_embedded.py" "%SRC_DIR%" "%MC_DIR%"
)

endlocal
