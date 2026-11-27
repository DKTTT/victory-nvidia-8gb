@echo off
chcp 936 >nul 2>nul
setlocal EnableExtensions
title GTA6 CN - 预热（火力全开）

rem ================= 参数：第一个是游戏目录就拿来用，其余当脚本参数 =================
set "GAME_DIR="
set "PASS="
:args
if "%~1"=="" goto args_done
if exist "%~1\game_scarlett_master.exe" goto args_gamedir
set "PASS=%PASS% "%~1""
goto args_next
:args_gamedir
if not defined GAME_DIR for %%I in ("%~1") do set "GAME_DIR=%%~fI"
:args_next
shift
goto args
:args_done

rem ================= 没给游戏目录就自动找 =================
if not defined GAME_DIR if exist "%~dp0game_scarlett_master.exe" for %%I in ("%~dp0.") do set "GAME_DIR=%%~fI"
if not defined GAME_DIR if exist "%~dp0game-path.txt" (
  for /f "usebackq delims=" %%L in ("%~dp0game-path.txt") do (
    if not defined GAME_DIR if exist "%%~L\game_scarlett_master.exe" for %%J in ("%%~L") do set "GAME_DIR=%%~fJ"
  )
)
if not defined GAME_DIR if defined VICTORY_GAME_DIR if exist "%VICTORY_GAME_DIR%\game_scarlett_master.exe" set "GAME_DIR=%VICTORY_GAME_DIR%"
for %%p in (
  "E:\GTA6.Xbox.v1.0.2.1-CYBERLEEK"
  "D:\GTA6.Xbox.v1.0.2.1-CYBERLEEK"
  "C:\GTA6.Xbox.v1.0.2.1-CYBERLEEK"
) do if not defined GAME_DIR if exist "%%~p\game_scarlett_master.exe" set "GAME_DIR=%%~p"
if not defined GAME_DIR (
  for %%D in (C D E F G H I J) do (
    if exist "%%D:\" (
      for /d %%F in ("%%D:\*GTA6*") do (
        if not defined GAME_DIR if exist "%%~fF\game_scarlett_master.exe" set "GAME_DIR=%%~fF"
      )
    )
  )
)
if not defined GAME_DIR (
  echo.
  echo 找不到游戏文件夹（里面要有 game_scarlett_master.exe）
  echo   1^) 把本文件夹放进游戏目录后再运行
  echo   2^) 把游戏文件夹拖到本 bat 上
  echo   3^) 先运行「设置游戏目录.bat」选一次
  echo.
  pause
  exit /b 1
)

rem 和 启动.bat 相同的存档/缓存目录（缓存要一致，预热才有效）
set "SAVE_DIR=E:\gta6\work\perf-data"
if not exist "%SAVE_DIR%" set "SAVE_DIR=%LOCALAPPDATA%\victory\data"
set "CACHE_DIR=E:\gta6\cache-vf-cn"
if not exist "%CACHE_DIR%" set "CACHE_DIR=%~dp0cache"
if not exist "%CACHE_DIR%" mkdir "%CACHE_DIR%" >nul 2>nul
set "VICTORY_GAME_DIR=%GAME_DIR%"
set "VICTORY_DATA_DIR=%SAVE_DIR%"
set "VICTORY_CACHE_DIR=%CACHE_DIR%"

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0预热-火力全开.ps1" -GameDir "%GAME_DIR%" %PASS%
echo.
pause
