#!/usr/bin/env bash
# Arranque desatendido (el agente, el ícono): con RUNTIME=docker espera a que Docker Desktop esté
# listo (lo abre si hace falta); después levanta todo.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="${PATH:-/usr/bin:/bin}:/opt/homebrew/bin:/usr/local/bin:/Applications/Docker.app/Contents/Resources/bin:/usr/sbin:/sbin"
LOG_DIR="${TRANSCRIPTOR_HOME:-$HOME/.transcriptor}"
mkdir -p "$LOG_DIR"

echo "[$(date '+%F %T')] arranque automático"
RUNTIME="${RUNTIME:-$(sed -n 's/^RUNTIME=//p' "$ROOT/.env" 2>/dev/null | tail -1)}"
if [[ "${RUNTIME:-native}" != docker ]]; then cd "$ROOT" && exec make up NO_OPEN=1; fi   # sin Docker: nada que esperar
if ! docker info >/dev/null 2>&1; then
  echo "Docker no está listo: abriendo Docker Desktop…"
  open -a Docker 2>/dev/null || true
  for _ in $(seq 1 "${BOOT_WAIT_TRIES:-120}"); do
    docker info >/dev/null 2>&1 && break
    sleep "${BOOT_WAIT_SLEEP:-2}"
  done
fi
docker info >/dev/null 2>&1 || { echo "Docker no arrancó a tiempo; abre Docker Desktop y ejecuta: make up"; exit 1; }

cd "$ROOT" && exec make up NO_OPEN=1
