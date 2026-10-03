@echo off
rem Собирает C:\temp\outpost_war.gma из папки outpost_war (запускать двойным кликом)
chcp 65001 >nul
if not exist "C:\temp" mkdir "C:\temp"
"C:\SteamLibrary\steamapps\common\GarrysMod\bin\win64\gmad.exe" create -folder "%~dp0outpost_war" -out "C:\temp\outpost_war.gma"
echo.
dir "C:\temp\outpost_war.gma"
pause
