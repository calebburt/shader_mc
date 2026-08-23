@echo off
setlocal enabledelayedexpansion

REM Resolve directory of this script
set "SRC_DIR=%~dp0"
set "PACK_NAME=shader_mc"

REM Determine Minecraft directory (prefer MINECRAFT_DIR if set)
if defined MINECRAFT_DIR (
    set "TARGET_PARENT=%MINECRAFT_DIR%\resourcepacks"
) else (
    set "TARGET_PARENT=%USERPROFILE%\AppData\Roaming\.minecraft\resourcepacks"
)

set "DEST_DIR=%TARGET_PARENT%\%PACK_NAME%"

REM Check Minecraft directory exists
if not exist "%TARGET_PARENT%\.." (
    echo No Minecraft directory at %TARGET_PARENT%\..
    echo Set MINECRAFT_DIR to override.
    exit /b 1
)

REM Create parent directory
if not exist "%TARGET_PARENT%" (
    mkdir "%TARGET_PARENT%"
)

REM Remove existing destination (file, dir, or symlink)
if exist "%DEST_DIR%" (
    rmdir /s /q "%DEST_DIR%" 2>nul
    del /f /q "%DEST_DIR%" 2>nul
)

mkdir "%DEST_DIR%"

REM Copy pack.mcmeta and assets directory
copy "%SRC_DIR%pack.mcmeta" "%DEST_DIR%" >nul
xcopy "%SRC_DIR%assets" "%DEST_DIR%\assets" /e /i /h >nul

echo Installed shader pack to: %DEST_DIR%
endlocal
