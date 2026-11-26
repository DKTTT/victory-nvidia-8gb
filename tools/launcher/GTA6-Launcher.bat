@echo off
chcp 936 >nul
title GTA VI 自动启动器
powershell -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0GTA6-Launcher.ps1"
if errorlevel 1 (
  echo 启动器出错，按任意键退出。
  pause >nul
)