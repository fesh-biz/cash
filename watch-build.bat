@echo off
chcp 65001 >nul
title Cash auto-build
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\watch-build.ps1" %*
pause
