#!/usr/bin/env bash
# La app en modo nativo (sin Docker) en macOS: un solo proceso, el binario de Go, que sirve la web
# y arranca/apaga Whisper y Ollama. Lo lanza launchd (com.transcriptor.app) para que no dependa de
# la Terminal que lo encendió ni de permisos de la carpeta del proyecto: binario y web se copian a
# ~/.transcriptor al compilar.
# Uso: scripts/app.sh {build|up|down|status|logs|autostart|autostart-off}
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STATE_DIR="${TRANSCRIPTOR_HOME:-$HOME/.transcriptor}"
BIN="$STATE_DIR/bin/transcriptor"
WEB="$STATE_DIR/web"
LABEL="com.transcriptor.app"
PLIST="${LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}/$LABEL.plist"
DOMAIN="gui/$(id -u)"
AUTOSTART_FLAG="$STATE_DIR/autostart"
export PATH="${PATH:-/usr/bin:/bin}:/opt/homebrew/bin:/usr/local/bin:/usr/sbin:/sbin"

PORT="${PORT:-4747}"
DATA_PATH="${DATA_PATH:-$HOME/TranscriptorAudios}"
INBOX_PATH="${INBOX_PATH:-$DATA_PATH/entrada}"
WHISPER_PORT="${WHISPER_PORT:-8178}"
OLLAMA_PORT="${OLLAMA_PORT:-11434}"

xml() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' <<<"$1"; }
health() { curl -fs -m 2 -o /dev/null "http://127.0.0.1:$PORT/api/health"; }
loaded() { launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; }

# Compila solo si algo cambió desde la última vez (por ejemplo tras un git pull): `up` lo llama siempre.
build() {
  local newer
  if [[ ! -x "$BIN" ]]; then newer=1; else
    newer="$(find "$ROOT/backend" -name '*.go' -newer "$BIN" -print -quit)"
  fi
  if [[ -n "$newer" ]]; then
    command -v go >/dev/null || { echo "Falta Go: ejecuta make setup" >&2; exit 1; }
    echo "Compilando la app…"
    mkdir -p "$STATE_DIR/bin"
    (cd "$ROOT/backend" && CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o "$BIN.new" .) && mv "$BIN.new" "$BIN"
  fi
  if [[ ! -f "$WEB/index.html" ]]; then newer=1; else
    newer="$(find "$ROOT/web/src" "$ROOT/web/index.html" "$ROOT/web/package-lock.json" "$ROOT/web/vite.config.ts" -newer "$WEB/index.html" -print -quit)"
  fi
  if [[ -n "$newer" ]]; then
    command -v npm >/dev/null || { echo "Falta Node.js: ejecuta make setup" >&2; exit 1; }
    echo "Compilando la web…"
    (cd "$ROOT/web" && npm ci --no-audit --no-fund --silent && npm run build --silent)
    rm -rf "$WEB.new" && cp -R "$ROOT/web/dist" "$WEB.new" && rm -rf "$WEB" && mv "$WEB.new" "$WEB"
  fi
}

env_entries() {
  local whisper ollama ffmpeg_dir k v
  whisper="$(command -v "${WHISPER_BIN:-whisper-server}" || echo "${WHISPER_BIN:-whisper-server}")"
  ollama="$(command -v ollama || echo ollama)"
  ffmpeg_dir="$(dirname "$(command -v ffmpeg || echo /opt/homebrew/bin/ffmpeg)")"
  {
    echo "ADDR=127.0.0.1:$PORT"
    echo "DATA_DIR=$DATA_PATH"
    echo "INBOX_DIR=$INBOX_PATH"
    echo "WEB_DIR=$WEB"
    echo "TMP_DIR=$STATE_DIR/tmp"
    echo "LOG_DIR=$STATE_DIR"
    echo "MANAGE_SERVICES=1"
    echo "WHISPER_URL=http://127.0.0.1:$WHISPER_PORT"
    echo "OLLAMA_URL=http://127.0.0.1:$OLLAMA_PORT"
    echo "WHISPER_BIN=$whisper"
    echo "WHISPER_MODEL=$STATE_DIR/models/${WHISPER_MODEL_FILE:-ggml-large-v3.bin}"
    echo "OLLAMA_BIN=$ollama"
    echo "PATH=$ffmpeg_dir:/usr/bin:/bin:/usr/sbin:/sbin"
    for k in OLLAMA_MODEL WHISPER_THREADS WHISPER_FLAGS RETENTION_DAYS TZ WHISPER_LANG WHISPER_PROMPT OLLAMA_NUM_CTX \
      WHATSAPP_CHATS WHATSAPP_BACKLOG_MIN BACKGROUND_ENABLED BACKGROUND_IDLE_MIN BACKGROUND_QUIT_DOCKER; do
      v="${!k:-}"; [[ -n "$v" ]] && echo "$k=$v"
    done
  } | while IFS='=' read -r k v; do printf '    <key>%s</key><string>%s</string>\n' "$k" "$(xml "$v")"; done
}

write_plist() { # devuelve 0 si cambió
  local tmp; tmp="$(mktemp)"
  mkdir -p "$(dirname "$PLIST")" "$STATE_DIR/tmp"
  cat >"$tmp" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>$(xml "$BIN")</string></array>
  <key>EnvironmentVariables</key>
  <dict>
$(env_entries)
  </dict>
  <key>WorkingDirectory</key><string>$(xml "$STATE_DIR")</string>
  <key>RunAtLoad</key><$([[ -f "$AUTOSTART_FLAG" ]] && echo true || echo false)/>
  <key>KeepAlive</key><false/>
  <key>ExitTimeOut</key><integer>15</integer>
  <key>StandardOutPath</key><string>$(xml "$STATE_DIR/app.log")</string>
  <key>StandardErrorPath</key><string>$(xml "$STATE_DIR/app.log")</string>
</dict>
</plist>
PLIST
  if cmp -s "$tmp" "$PLIST"; then rm -f "$tmp"; return 1; fi
  mv "$tmp" "$PLIST"; return 0
}

# Carga (o recarga, si cambió la configuración) el trabajo de launchd sin arrancarlo.
install_job() {
  if write_plist; then
    if loaded; then launchctl bootout "$DOMAIN/$LABEL" >/dev/null 2>&1 || true; sleep 1; fi
    launchctl bootstrap "$DOMAIN" "$PLIST"
  elif ! loaded; then
    launchctl bootstrap "$DOMAIN" "$PLIST"
  fi
}

up() {
  build
  [[ -f "$STATE_DIR/models/${WHISPER_MODEL_FILE:-ggml-large-v3.bin}" ]] || { echo "Falta el modelo de Whisper. Ejecuta: make setup" >&2; exit 1; }
  mkdir -p "$DATA_PATH" "$INBOX_PATH"
  install_job
  if health; then echo "Ya estaba encendido"; return 0; fi
  launchctl kickstart "$DOMAIN/$LABEL"
  echo "Encendiendo (Whisper tarda unos segundos en cargar el modelo)…"
  local i
  for ((i = 0; i < 150; i++)); do
    if health; then return 0; fi
    if ! launchctl print "$DOMAIN/$LABEL" 2>/dev/null | grep -q "state = running"; then
      echo "La app se cerró al arrancar. Últimas líneas de $STATE_DIR/app.log:" >&2; tail -n 15 "$STATE_DIR/app.log" >&2; exit 1
    fi
    sleep 1
  done
  echo "La app no respondió en 150 s; mira $STATE_DIR/app.log" >&2; exit 1
}

down() {
  loaded || return 0
  launchctl kill SIGTERM "$DOMAIN/$LABEL" >/dev/null 2>&1 || true
  local i
  for ((i = 0; i < 20; i++)); do
    launchctl print "$DOMAIN/$LABEL" 2>/dev/null | grep -q "state = running" || { echo "App, Whisper y Ollama detenidos"; return 0; }
    sleep 1
  done
  echo "La app no se detuvo a tiempo; mira $STATE_DIR/app.log" >&2
}

status() {
  curl -fs -m 2 -o /dev/null "http://127.0.0.1:$WHISPER_PORT/" && echo "whisper-server: listo" || echo "whisper-server: parado"
  curl -fs -m 2 -o /dev/null "http://127.0.0.1:$OLLAMA_PORT/api/tags" && echo "ollama:         listo" || echo "ollama:         parado"
  health && echo "app:            encendida (http://localhost:$PORT)" || echo "app:            apagada"
}

case "${1:-}" in
  build) build ;;
  up) up ;;
  down) down ;;
  status) status ;;
  logs) tail -n 100 -f "$STATE_DIR/app.log" ;;
  autostart) mkdir -p "$STATE_DIR"; touch "$AUTOSTART_FLAG"; build; install_job
    echo "Arranque automático activado: se enciende solo al iniciar sesión. Desactivar: make autostart-off" ;;
  autostart-off) rm -f "$AUTOSTART_FLAG"; if [[ -f "$PLIST" ]]; then install_job; fi; echo "Arranque automático desactivado." ;;
  *) echo "Uso: $0 {build|up|down|status|logs|autostart|autostart-off}" >&2; exit 2 ;;
esac
