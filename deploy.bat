@echo off
REM Installs the pack into a Minecraft installation's resourcepacks directory.
setlocal

set "PACK_NAME=vibrant-java"
set "SRC_DIR=%~dp0"

REM An explicit MINECRAFT_DIR wins, otherwise fall back to the default profile.
if defined MINECRAFT_DIR (
    set "MC_DIR=%MINECRAFT_DIR%"
) else (
    set "MC_DIR=%APPDATA%\.minecraft"
)

if not exist "%MC_DIR%" (
    echo No Minecraft directory at %MC_DIR%
    echo Set MINECRAFT_DIR to point at it and try again.
    exit /b 1
)

set "DEST_DIR=%MC_DIR%\resourcepacks\%PACK_NAME%"

if exist "%DEST_DIR%" rmdir /s /q "%DEST_DIR%"
mkdir "%DEST_DIR%"

REM Only the pack itself. The validation script stays behind.
copy /y "%SRC_DIR%pack.mcmeta" "%DEST_DIR%\" >nul
xcopy /e /i /h /y "%SRC_DIR%assets" "%DEST_DIR%\assets" >nul

echo Installed %PACK_NAME% to %DEST_DIR%
echo Enable it in Options ^> Video Settings ^> Shader Packs.

endlocal
