@echo off
title Night City Online
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Atualizar.ps1" %*
if errorlevel 1 pause
