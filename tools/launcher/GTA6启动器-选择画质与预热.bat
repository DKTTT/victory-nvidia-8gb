@echo off
chcp 936 >nul
setlocal EnableExtensions
title GTA VI PC 移植 - 启动器

set "GAME=E:\GTA6.Xbox.v1.0.2.1-CYBERLEEK\game_scarlett_master.exe"
set "NVDIR=E:\gta6\work\vf-nvidia"
set "NVCACHE=E:\gta6\cache-nvidia"
set "NVDATA=E:\gta6\work\perf-data"
set "MNDIR=E:\gta6\work\vf-main"
set "MNCACHE=E:\gta6\cache-upstream"
set "MNDATA=E:\gta6\work\perf-data-up"

:menu
cls
echo ================================================================
echo                GTA VI PC 移植 - 启动器
echo ================================================================
echo.
echo   [构建 1] NVIDIA 分支  （最快 12-15 fps）
echo     1. 540p 均衡      ^(推荐^)
echo     2. 720p 画质      ^(较慢^)
echo     3. 480p 流畅      ^(最快^)
echo.
echo   [构建 2] 最新上游 668 提交  （已修白屏）
echo     4. 540p 均衡
echo     5. 720p 画质
echo     6. 1080p 原生画质
echo.
echo   [预热工具]
echo     7. 预翻译全部着色器 ^(构建 1^)
echo     8. 预编译全部管线 warm ^(构建 1^)
echo     9. 预翻译 + 预编译 + 启动 540p ^(构建 1^)
echo     A. 预翻译全部着色器 ^(构建 2^)
echo     B. 预编译全部管线 warm ^(构建 2^)
echo     C. 预翻译 + 预编译 + 启动 540p ^(构建 2^)
echo.
echo     0. 退出
echo ================================================================
set "c="
set /p "c=请输入选择: "
if "%c%"=="1" goto nv540
if "%c%"=="2" goto nv720
if "%c%"=="3" goto nv480
if "%c%"=="4" goto mn540
if "%c%"=="5" goto mn720
if "%c%"=="6" goto mn1080
if /i "%c%"=="7" goto pre_nv_shaders
if /i "%c%"=="8" goto pre_nv_warm
if /i "%c%"=="9" goto pre_nv_all
if /i "%c%"=="a" goto pre_mn_shaders
if /i "%c%"=="b" goto pre_mn_warm
if /i "%c%"=="c" goto pre_mn_all
if "%c%"=="0" goto bye
goto menu

rem ==================== 构建 1（NVIDIA 分支）====================
:nv540
set "SCALE=0.5"
goto nv_run

:nv720
set "SCALE=0.6667"
goto nv_run

:nv480
set "SCALE=0.4444"
goto nv_run

:nv_run
call :env_common
set "VICTORY_CACHE_DIR=%NVCACHE%"
set "VICTORY_DATA_DIR=%NVDATA%"
set "VICTORY_RENDER_SCALE=%SCALE%"
set "VICTORY_OWN_UPSCALER=1"
set "VICTORY_COMPOSE=1"
call :load_skip "%NVDIR%\scripts\rt_off_hashes.txt"
cls
echo ================================================================
echo   构建 1（NVIDIA 分支）  渲染缩放 = %SCALE%
echo   窗口关闭即游戏结束
echo ================================================================
cd /d "%NVDIR%"
"%NVDIR%\target\diag\victory.exe" run "%GAME%" --execute --console series-s
echo.
echo 游戏已退出。
pause
goto menu

rem ==================== 构建 2（最新上游）====================
:mn540
set "SCALE=0.5"
goto mn_run

:mn720
set "SCALE=0.6667"
goto mn_run

:mn1080
set "SCALE=1.0"
goto mn_run

:mn_run
call :env_common
set "VICTORY_CACHE_DIR=%MNCACHE%"
set "VICTORY_DATA_DIR=%MNDATA%"
set "VICTORY_RENDER_SCALE=%SCALE%"
set "VICTORY_OWN_UPSCALER=1"
set "VICTORY_COMPOSE=1"
call :load_skip "%MNDIR%\scripts\rt_off_hashes.txt"
cls
echo ================================================================
echo   构建 2（最新上游 668 提交）  渲染缩放 = %SCALE%
echo   窗口关闭即游戏结束
echo ================================================================
cd /d "%MNDIR%"
"%MNDIR%\target\diag\victory.exe" run "%GAME%" --execute --console series-s
echo.
echo 游戏已退出。
pause
goto menu

rem ==================== 公共环境 ====================
:env_common
set "VICTORY_GAME_DIR=E:\GTA6.Xbox.v1.0.2.1-CYBERLEEK"
set "VICTORY_TEXTURE_NO_WAIT=0"
set "VICTORY_TEXTURE_STAGE_MS=500"
set "VICTORY_RELAY=2"
set "VICTORY_WIDE_BACK=1"
set "VICTORY_CARD_REHASH_RUNS=1"
set "VICTORY_JOIN_COPIES=1"
set "VICTORY_INDIRECT_WINDOW=1"
set "VICTORY_RELAY_COPY=1"
set "VICTORY_CARD_STEPS=2"
set "VICTORY_INDIRECT_BATCH=2"
set "VICTORY_MAP_THREADS=1"
set "VICTORY_TITLE_PRIORITIES=0"
set "VICTORY_CARD_AWAKE=1"
set "VICTORY_SHOW_AFTER=1"
set "VICTORY_AMBIENT=0.8"
set "VICTORY_AMBIENT_AIR=1.5"
set "VICTORY_AMBIENT_MOST=2"
set "VICTORY_NAN_SCRUB=1"
set "VICTORY_THIN=1"
set "VICTORY_JOIN_PARTS=8"
set "VICTORY_UPLOAD_AHEAD=1"
set "VICTORY_D3D12_DRED=light"
set "VICTORY_DYNAMIC_SLOTS=524288"
set "VICTORY_BVH_MISS=1"
set "VICTORY_PIPELINE_WAIT_MS=10000"
set "VICTORY_CARD_BUFFERS_MIN_MB=1"
set "VICTORY_CARD_BUFFERS_MB=1536"
goto :eof

:load_skip
set "VICTORY_SKIP_PIPELINES="
for /f "usebackq delims=" %%a in ("%~1") do set "VICTORY_SKIP_PIPELINES=%%a"
goto :eof

rem ==================== 预热：构建 1 ====================
:pre_nv_shaders
call :prewarm_shaders "%NVDIR%" "%NVCACHE%"
goto menu

:pre_nv_warm
call :prewarm_warm "%NVDIR%" "%NVCACHE%"
goto menu

:pre_nv_all
call :prewarm_shaders "%NVDIR%" "%NVCACHE%"
if errorlevel 1 goto menu
call :prewarm_warm "%NVDIR%" "%NVCACHE%"
set "SCALE=0.5"
goto nv_run

rem ==================== 预热：构建 2 ====================
:pre_mn_shaders
call :prewarm_shaders "%MNDIR%" "%MNCACHE%"
goto menu

:pre_mn_warm
call :prewarm_warm "%MNDIR%" "%MNCACHE%"
goto menu

:pre_mn_all
call :prewarm_shaders "%MNDIR%" "%MNCACHE%"
if errorlevel 1 goto menu
call :prewarm_warm "%MNDIR%" "%MNCACHE%"
set "SCALE=0.5"
goto mn_run

:prewarm_shaders
call :env_common
set "VICTORY_CACHE_DIR=%~2"
cls
echo ================================================================
echo   预翻译全部着色器（约 2-5 分钟，可中断后继续）
echo   构建: %~1
echo ================================================================
cd /d "%~1"
"%~1\target\diag\victory.exe" shaders "%GAME%"
echo.
pause
goto :eof

:prewarm_warm
call :env_common
set "VICTORY_CACHE_DIR=%~2"
cls
echo ================================================================
echo   预编译全部管线 warm（约 3-10 分钟，可中断后继续）
echo   构建: %~1
echo ================================================================
cd /d "%~1"
"%~1\target\diag\victory.exe" warm --used
echo.
pause
goto :eof

:bye
exit /b 0