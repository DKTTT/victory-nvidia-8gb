@echo off
chcp 936 >nul 2>nul
setlocal EnableExtensions
title GTA6 CN - 预热（快速模式）
if "%~1"=="" (
  call "%~dp0预热-火力全开.bat" -Fast
) else (
  call "%~dp0预热-火力全开.bat" "%~1" -Fast
)
