@echo off
chcp 65001 > nul
title Escaneo Paulatino de Mercado y Catalogos Mayoristas (Trendy + Bloomshell)
echo =========================================================================
echo   INICIANDO ESCANEO PAULATINO DE PROVEEDORES: TRENDY + BLOOMSHELL
echo   Foco Regional: Roldanillo, Cartago y Valle del Cauca (Clima Calido)
echo =========================================================================
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0escanear_mercado_proveedores.ps1"
echo.
echo Abriendo Centro de Inteligencia de Mercado (estudio_mercado.html)...
start "" "%~dp0estudio_mercado.html"
pause
