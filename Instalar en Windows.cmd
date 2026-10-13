@echo off
rem Doble clic: instala todo (la primera vez tarda: descarga ~6 GB), crea el icono «Transcriptor» y abre la app.
rem Se puede volver a ejecutar sin problema: lo que ya está instalado no se repite.
chcp 65001 >nul
cd /d "%~dp0"
echo Instalando el Transcriptor de audios. No cierres esta ventana; la primera vez tarda un rato.
echo.
call "%~dp0transcriptor.cmd" instalar
if errorlevel 1 (
  echo.
  echo Algo falló. Copia lo que aparece arriba y pásaselo a quien te ayuda.
) else (
  echo.
  echo Listo. Desde ahora abre la app con el icono «Transcriptor» del Escritorio.
)
echo.
pause
