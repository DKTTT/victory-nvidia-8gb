@echo off
chcp 936 >nul
title GTA VI 启动器
powershell -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "E:\gta6\GTA6启动器-GUI.ps1"
if errorlevel 1 (
  echo.
  echo 启动器出错，按任意键退出。
  pause >nul
)