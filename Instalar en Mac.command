#!/bin/bash
# Doble clic en el Finder: instala todo (la primera vez tarda: descarga ~6 GB), crea el ícono
# «Transcriptor» y abre la app. Se puede volver a ejecutar: lo que ya está instalado no se repite.
cd "$(dirname "$0")" || exit 1
echo "Instalando el Transcriptor de audios. No cierres esta ventana; la primera vez tarda un rato."
echo

# Homebrew en Apple Silicon vive en /opt/homebrew, que un doble clic no siempre tiene en el PATH.
if ! command -v brew >/dev/null && [ -x /opt/homebrew/bin/brew ]; then eval "$(/opt/homebrew/bin/brew shellenv)"; fi
if ! command -v brew >/dev/null; then
  echo "Falta Homebrew. En la página que se abre, copia el comando de instalación, pégalo en la Terminal"
  echo "y, cuando termine, vuelve a abrir este archivo."
  open https://brew.sh
  read -r -p "Pulsa Enter para cerrar…"
  exit 1
fi

if make setup && make app && make up; then
  echo
  echo "Listo. Desde ahora abre la app con el ícono «Transcriptor» (Escritorio o Launchpad)."
else
  echo
  echo "Algo falló. Copia lo que aparece arriba y pásaselo a quien te ayuda."
fi
read -r -p "Pulsa Enter para cerrar…"
