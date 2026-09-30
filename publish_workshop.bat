@echo off
chcp 65001 >nul
set GMOD=C:\SteamLibrary\steamapps\common\GarrysMod
set ICON=%GMOD%\garrysmod\addons\outpost_war_icon.jpg
set GMA=C:\temp\outpost_war.gma

if not exist C:\temp mkdir C:\temp

rem 64-bit tools (x86-64 branch) if present, otherwise 32-bit
set TOOLS=%GMOD%\bin
if exist "%GMOD%\bin\win64\gmpublish.exe" set TOOLS=%GMOD%\bin\win64
echo Using tools from: %TOOLS%
cd /d "%TOOLS%"

rem Steam App ID of Garry's Mod, needed by gmpublish
echo 4000>steam_appid.txt
set GMAD=%TOOLS%\gmad.exe
if not exist "%GMAD%" set GMAD=%GMOD%\bin\gmad.exe

echo.
echo === Packing addon ===
"%GMAD%" create -folder "%GMOD%\garrysmod\addons\outpost_war" -out "%GMA%"
if errorlevel 1 (
    echo gmad failed.
    pause
    exit /b 1
)

echo.
echo === Publishing to Workshop (64-bit) ===
cd /d "%GMOD%\bin\win64"
echo 4000>steam_appid.txt
gmpublish.exe create -addon "%GMA%" -icon "%ICON%"
if not errorlevel 1 goto done
echo.
echo === 64-bit failed, trying 32-bit ===
cd /d "%GMOD%\bin"
echo 4000>steam_appid.txt
gmpublish.exe create -addon "%GMA%" -icon "%ICON%"
:done

echo.
echo Done. If you see an ID above - save it, it is needed for updates.
pause
