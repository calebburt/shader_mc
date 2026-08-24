@echo off
setlocal enabledelayedexpansion

REM Resolve script directory without trailing backslash
set "SRC_DIR=%~dp0"
if "%SRC_DIR:~-1%"=="\" set "SRC_DIR=%SRC_DIR:~0,-1%"

REM Prefer MINECRAFT_DIR if set (kept for parity, not required by the WSL script)
if defined MINECRAFT_DIR (
  set "MC_DIR=%MINECRAFT_DIR%"
) else (
  set "MC_DIR=%USERPROFILE%\AppData\Roaming\.minecraft"
)

REM Convert Windows repo path to a WSL path
for /f "usebackq delims=" %%A in (`wsl wslpath -a "%SRC_DIR%"`) do set "SRC_WSL=%%A"
for /f "usebackq delims=" %%A in (`wsl wslpath -a "%MC_DIR%"`) do set "MC_WSL=%%A"

echo Running shader validation in WSL at: %SRC_WSL%

REM Run the existing check_shaders.sh inside WSL; normalize line endings and export MC_VERSION if provided
if defined MC_VERSION (
  wsl bash -lc "cd '%SRC_WSL%' && sed -i 's/\r$//' ./check_shaders.sh 2>/dev/null || true; chmod +x ./check_shaders.sh || true; export MINECRAFT_DIR='%MC_WSL%'; export MC_VERSION='%MC_VERSION%'; ./check_shaders.sh"
) else (
  wsl bash -lc "cd '%SRC_WSL%' && sed -i 's/\r$//' ./check_shaders.sh 2>/dev/null || true; chmod +x ./check_shaders.sh || true; export MINECRAFT_DIR='%MC_WSL%'; ./check_shaders.sh"
)

endlocal
