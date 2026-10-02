#!/usr/bin/env bash
# Lo usa la app "Transcriptor" (doble clic, sin Terminal).
# Uso: scripts/launcher.sh {estado|up|down}
#   estado -> imprime "on" u "off"
#   up     -> levanta todo (abre Docker Desktop si hace falta) y abre el navegador
#   down   -> apaga todo y libera la memoria
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="${PATH:-/usr/bin:/bin}:/opt/homebrew/bin:/usr/local/bin:/Applications/Docker.app/Contents/Resources/bin:/usr/sbin:/sbin"
PORT="${PORT:-4747}"
LOG_DIR="${TRANSCRIPTOR_HOME:-$HOME/.transcriptor}"
mkdir -p "$LOG_DIR"

case "${1:-}" in
  estado)
    if curl -fs -m 2 -o /dev/null "http://localhost:$PORT/api/health"; then echo on; else echo off; fi ;;
  up)
    "$ROOT/scripts/boot.sh" >>"$LOG_DIR/launcher.log" 2>&1 || exit 1
    open "http://localhost:$PORT" ;;
  down)
    cd "$ROOT" && make down >>"$LOG_DIR/launcher.log" 2>&1 ;;
  *) echo "uso: $0 {estado|up|down}" >&2; exit 2 ;;
esac
