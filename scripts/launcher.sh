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
    echo "=== $(date '+%F %T') up (PORT=$PORT) ===" >>"$LOG_DIR/launcher.log"
    if ! "$ROOT/scripts/boot.sh" >>"$LOG_DIR/launcher.log" 2>&1; then
      echo "Falló el arranque. Últimas líneas del registro:" >&2
      tail -n 12 "$LOG_DIR/launcher.log" >&2
      exit 1
    fi
    # make up puede volver antes de que la app responda: espera hasta 90 s
    for _ in $(seq 1 45); do
      curl -fs -m 2 -o /dev/null "http://localhost:$PORT/api/health" && { open "http://localhost:$PORT"; exit 0; }
      sleep 2
    done
    echo "La app no responde en el puerto $PORT. Últimas líneas del registro:" >&2
    { docker ps -a --format '{{.Names}}: {{.Status}} {{.Ports}}'; tail -n 8 "$LOG_DIR/launcher.log"; } >&2
    exit 1 ;;
  down)
    cd "$ROOT" && make down >>"$LOG_DIR/launcher.log" 2>&1 ;;
  *) echo "uso: $0 {estado|up|down}" >&2; exit 2 ;;
esac
