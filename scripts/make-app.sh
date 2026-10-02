#!/usr/bin/env bash
# Crea "Transcriptor.app" (en ~/Applications y en el Escritorio): doble clic y se enciende
# todo sin abrir la Terminal; si ya está encendido, ofrece Abrir o Apagar.
# Uso: scripts/make-app.sh {install|uninstall}
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIRS=("${APP_DIR:-$HOME/Applications}" "${DESKTOP_DIR:-$HOME/Desktop}")
NAME="Transcriptor.app"
PORT="${PORT:-4747}"

# AppleScript: comillas dobles de la ruta escapadas
q() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

install() {
  command -v osacompile >/dev/null || { echo "osacompile no existe: esto solo funciona en macOS" >&2; exit 1; }
  local tmp src; tmp="$(mktemp -d)"; src="$tmp/transcriptor.applescript"
  cat >"$src" <<APPLESCRIPT
set launcher to "$(q "$ROOT/scripts/launcher.sh")"
set theUrl to "http://localhost:$PORT"
set prefix to "PORT=$PORT "

set estado to do shell script prefix & quoted form of launcher & " estado"
if estado is "on" then
  set r to button returned of (display dialog "Transcriptor está encendido." buttons {"Apagar", "Abrir"} default button "Abrir" with title "Transcriptor")
  if r is "Apagar" then
    display notification "Apagando…" with title "Transcriptor"
    do shell script prefix & quoted form of launcher & " down"
    display notification "Apagado. Memoria liberada." with title "Transcriptor"
  else
    open location theUrl
  end if
else
  display notification "Encendiendo… tarda unos segundos (la primera vez, más)." with title "Transcriptor"
  try
    do shell script prefix & quoted form of launcher & " up"
  on error
    display dialog "No pude encenderlo. Revisa que Docker Desktop esté instalado. Detalles en ~/.transcriptor/launcher.log" buttons {"OK"} default button "OK" with icon caution with title "Transcriptor"
  end try
end if
APPLESCRIPT
  local d
  for d in "${APP_DIRS[@]}"; do
    mkdir -p "$d"
    rm -rf "${d:?}/$NAME"
    osacompile -o "$d/$NAME" "$src"
    echo "Creada: $d/$NAME"
  done
  rm -rf "$tmp"
  echo "Listo: doble clic en «Transcriptor» (Escritorio o Launchpad) para encender o apagar todo."
}

uninstall() {
  local d
  for d in "${APP_DIRS[@]}"; do rm -rf "${d:?}/$NAME" && echo "Borrada: $d/$NAME"; done
}

case "${1:-}" in
  install) install ;;
  uninstall) uninstall ;;
  *) echo "uso: $0 {install|uninstall}" >&2; exit 2 ;;
esac
