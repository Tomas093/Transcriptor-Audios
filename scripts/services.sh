#!/usr/bin/env bash
# Arranca/para los servicios nativos (con Metal): whisper-server y Ollama.
# Uso: scripts/services.sh {start|stop|status}
set -euo pipefail

STATE_DIR="${TRANSCRIPTOR_HOME:-$HOME/.transcriptor}"
MODEL_FILE="${WHISPER_MODEL_FILE:-ggml-large-v3-turbo-q5_0.bin}"
MODEL="$STATE_DIR/models/$MODEL_FILE"
WHISPER_PORT="${WHISPER_PORT:-8178}"
OLLAMA_PORT="${OLLAMA_PORT:-11434}"
OLLAMA_MODEL="${OLLAMA_MODEL:-qwen2.5:7b}"
WHISPER_THREADS="${WHISPER_THREADS:-4}"
WHISPER_BIN="${WHISPER_BIN:-whisper-server}"   # ruta al binario si lo compilaste a mano
WHISPER_FLAGS="${WHISPER_FLAGS:--fa}"           # -fa: flash attention (menos cómputo en GPU)
mkdir -p "$STATE_DIR"

up() { curl -fsS -m 2 -o /dev/null "$1" 2>/dev/null; }
wait_for() { # url, segundos
  local i; for ((i = 0; i < $2; i++)); do up "$1" && return 0; sleep 1; done; return 1
}
alive() { [[ -f "$1" ]] && kill -0 "$(cat "$1")" 2>/dev/null; }

start_whisper() {
  if up "http://127.0.0.1:$WHISPER_PORT/"; then echo "whisper-server ya está en marcha"; return; fi
  command -v "$WHISPER_BIN" >/dev/null || { echo "Falta $WHISPER_BIN. Ejecuta: make setup" >&2; exit 1; }
  [[ -f "$MODEL" ]] || { echo "Falta el modelo $MODEL. Ejecuta: make setup" >&2; exit 1; }
  echo "Arrancando whisper-server (modelo $MODEL_FILE)…"
  # nice: prioridad baja, así el Mac sigue fluido mientras transcribe.
  # shellcheck disable=SC2086  # WHISPER_FLAGS son varios flags a propósito
  nohup nice -n 10 "$WHISPER_BIN" -m "$MODEL" --host 127.0.0.1 --port "$WHISPER_PORT" -t "$WHISPER_THREADS" $WHISPER_FLAGS \
    >>"$STATE_DIR/whisper.log" 2>&1 &
  echo $! >"$STATE_DIR/whisper.pid"
  wait_for "http://127.0.0.1:$WHISPER_PORT/" 90 || { echo "whisper-server no arrancó; mira $STATE_DIR/whisper.log" >&2; exit 1; }
}

start_ollama() {
  if up "http://127.0.0.1:$OLLAMA_PORT/api/tags"; then echo "Ollama ya está en marcha"; return; fi
  command -v ollama >/dev/null || { echo "Falta Ollama. Ejecuta: make setup" >&2; exit 1; }
  echo "Arrancando Ollama…"
  # Un solo modelo en memoria, sin paralelismo y descarga rápida cuando no se usa.
  OLLAMA_KEEP_ALIVE=30s OLLAMA_MAX_LOADED_MODELS=1 OLLAMA_NUM_PARALLEL=1 \
    nohup ollama serve >>"$STATE_DIR/ollama.log" 2>&1 &
  echo $! >"$STATE_DIR/ollama.pid"
  wait_for "http://127.0.0.1:$OLLAMA_PORT/api/tags" 30 || { echo "Ollama no arrancó; mira $STATE_DIR/ollama.log" >&2; exit 1; }
}

stop_whisper() {
  if alive "$STATE_DIR/whisper.pid"; then kill "$(cat "$STATE_DIR/whisper.pid")" && echo "whisper-server detenido"; fi
  rm -f "$STATE_DIR/whisper.pid"
}

stop_ollama() {
  # Si lo lanzamos nosotros, lo paramos. Si ya estaba (app/servicio de brew), solo descargamos el modelo de la RAM.
  if alive "$STATE_DIR/ollama.pid"; then
    kill "$(cat "$STATE_DIR/ollama.pid")" && echo "Ollama detenido"
  elif up "http://127.0.0.1:$OLLAMA_PORT/api/tags" && command -v ollama >/dev/null; then
    ollama stop "$OLLAMA_MODEL" >/dev/null 2>&1 || true
    echo "Modelo descargado de la memoria (Ollama sigue activo porque no lo arrancó este proyecto)"
  fi
  rm -f "$STATE_DIR/ollama.pid"
}

status() {
  up "http://127.0.0.1:$WHISPER_PORT/" && echo "whisper-server: listo" || echo "whisper-server: parado"
  up "http://127.0.0.1:$OLLAMA_PORT/api/tags" && echo "ollama:         listo" || echo "ollama:         parado"
}

case "${1:-}" in
  start) start_whisper; start_ollama ;;
  stop) stop_whisper; stop_ollama ;;
  status) status ;;
  *) echo "Uso: $0 {start|stop|status}" >&2; exit 2 ;;
esac
